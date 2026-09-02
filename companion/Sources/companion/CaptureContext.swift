import AppKit
import ApplicationServices

/// What the user was doing when a capture started: the frontmost app, its
/// focused window, and — when the window exposes its document — the file
/// and git branch behind it. Stamped onto every memo and meeting so the
/// archive can answer "what was I working on when I said this".
struct CaptureContext {
	let app: String?
	let window: String?
	let document: URL?
	let branch: String?

	@MainActor
	static func current() async -> CaptureContext {
		guard let frontmost = NSWorkspace.shared.frontmostApplication else {
			return CaptureContext(app: nil, window: nil, document: nil, branch: nil)
		}
		let element = AXUIElementCreateApplication(frontmost.processIdentifier)
		let window = focusedWindow(of: element)
		let document = window.flatMap { attribute($0, kAXDocumentAttribute) as? String }
			.flatMap(URL.init(string:))
			.flatMap { $0.isFileURL ? $0 : nil }
		var branch: String?
		if let document {
			branch = await Subprocess.run([
				"git", "-C", document.deletingLastPathComponent().path,
				"rev-parse", "--abbrev-ref", "HEAD",
			])?.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return CaptureContext(
			app: frontmost.localizedName,
			window: window.flatMap { attribute($0, kAXTitleAttribute) as? String },
			document: document,
			branch: branch.flatMap { $0.isEmpty ? nil : $0 })
	}

	var markdownLines: [String] {
		var lines: [String] = []
		if let app { lines.append("- app: \(app)") }
		if let window, !window.isEmpty { lines.append("- window: \(window)") }
		if let document { lines.append("- document: \(document.path)") }
		if let branch { lines.append("- branch: \(branch)") }
		return lines
	}

	/// One-line form for the memo journal heading.
	var summary: String? {
		guard let app else { return nil }
		if let window, !window.isEmpty { return "\(app) — \(window)" }
		return app
	}

	private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
		guard let value = attribute(app, kAXFocusedWindowAttribute) else { return nil }
		guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
		return unsafeDowncast(value, to: AXUIElement.self)
	}

	private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
		var value: AnyObject?
		guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
		else { return nil }
		return value
	}
}
