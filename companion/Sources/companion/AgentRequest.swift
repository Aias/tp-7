import AppKit
import Foundation

enum AgentVerb: String {
	case act
	case research

	var instruction: String {
		switch self {
		case .act: "act: do the work described"
		case .research: "research: investigate and report back; change nothing"
		}
	}
}

/// A side-button request hands the current moment to Claude Code: a brief
/// is written next to the recordings and an interactive session opens in
/// Ghostty so the conversation stays visible and steerable. The target
/// project is never known up front; the session infers it from the brief
/// and confirms before touching a repo. Ghostty's `-e` runs the command
/// bare, so a login-interactive zsh supplies the user's PATH.
@MainActor
enum AgentRequest {
	private static let briefsDir = Paths.recordingsDir.appendingPathComponent("agent")

	static func launch(
		verb: AgentVerb, instruction: String?, context: CaptureContext,
		meeting: MeetingSession.MeetingSnapshot?
	) async {
		let stamp = timestamp()
		let brief = briefsDir.appendingPathComponent("\(stamp)-\(verb.rawValue).md")
		let body = render(
			verb: verb, instruction: instruction, context: context, meeting: meeting)
		do {
			try FileManager.default.createDirectory(
				at: briefsDir, withIntermediateDirectories: true)
			try body.write(to: brief, atomically: true, encoding: .utf8)
		} catch {
			Log.d("agent: could not write brief: \(error)")
			Notifier.post(title: "Agent request failed", message: "Could not write the brief.")
			return
		}
		let prompt = """
			You've been summoned from the TP-7 companion. Read the brief at \(brief.path) \
			and carry it out. The request kind is \(verb.instruction). \
			The target project is not known: infer it from the brief's context and \
			candidate projects, confirm with me before touching a repo, and never work \
			directly on a main branch.
			"""
		let opened = await Subprocess.run([
			"open", "-na", "Ghostty.app", "--args",
			"-e", "zsh", "-lic", "cd \"$HOME\" && exec claude \"$1\"", "tp7-agent", prompt,
		])
		Log.d("agent: \(verb.rawValue) request → \(brief.lastPathComponent)")
		Notifier.post(
			title: opened != nil ? "Sent to Claude" : "Could not open Ghostty",
			message: instruction ?? "\(verb.rawValue) request from \(context.app ?? "the desktop")",
			opening: brief)
	}

	private static func render(
		verb: AgentVerb, instruction: String?, context: CaptureContext,
		meeting: MeetingSession.MeetingSnapshot?
	) -> String {
		var sections: [String] = []
		let when = ISO8601DateFormatter().string(from: Date())
		sections.append(
			"# \(verb.rawValue.capitalized) request\n\n"
				+ (["- when: \(when)"] + context.markdownLines).joined(separator: "\n"))
		sections.append("## Instruction\n\n" + (instruction ?? "(no spoken instruction)"))
		if let selection = context.selection {
			sections.append("## Selected text\n\n```\n\(selection)\n```")
		}
		if let meeting {
			let transcript = meeting.transcript.isEmpty ? "(nothing transcribed yet)" : meeting.transcript
			sections.append(
				"## Meeting in progress (\(meeting.elapsed) elapsed)\n\n"
					+ "The diarized transcript will land in "
					+ "\(Paths.meetingsDir.path)/\(meeting.stamp.prefix(15))-<title>/ "
					+ "when the meeting ends.\n\n"
					+ "### Live transcript so far\n\n\(transcript)")
			if !meeting.annotations.isEmpty {
				sections.append("### Markers and notes\n\n" + meeting.annotations.joined(separator: "\n"))
			}
		}
		sections.append("## Candidate projects\n\n" + candidateProjects().joined(separator: "\n"))
		return sections.joined(separator: "\n\n") + "\n"
	}

	private static func candidateProjects() -> [String] {
		let home = FileManager.default.homeDirectoryForCurrentUser
		let roots = [
			home.appendingPathComponent("conductor/repos"), home.appendingPathComponent("Code"),
		]
		return roots.flatMap { root -> [String] in
			let entries = (try? FileManager.default.contentsOfDirectory(
				at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
			return entries
				.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
				.map { "- \($0.path)" }
				.sorted()
		}
	}

	private static func timestamp() -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd_HHmmss"
		return formatter.string(from: Date())
	}
}
