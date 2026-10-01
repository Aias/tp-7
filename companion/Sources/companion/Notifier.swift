import AppKit
import UserNotifications

/// Posts macOS notifications. The installed app (bundled) uses
/// UNUserNotificationCenter so a click can open the capture's transcript
/// and a notification can take a typed reply; a bare `swift run` build has
/// no bundle identity, which that framework requires, so it falls back to
/// osascript, where clicks and replies do nothing.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
	private static let shared = Notifier()
	private static let bundled = Bundle.main.bundleIdentifier != nil
	private static var startTimeReply: (@MainActor (_ file: String, _ time: String) -> Void)?

	private nonisolated static let setStartTimeAction = "set-start-time"

	private static let unsetClockCategory = UNNotificationCategory(
		identifier: "unset-clock",
		actions: [
			UNTextInputNotificationAction(
				identifier: setStartTimeAction, title: "Set start time", options: [],
				textInputButtonTitle: "Set",
				textInputPlaceholder: "2026-09-30 11:15 or 11:15")
		],
		intentIdentifiers: [])

	/// `onStartTime` receives the reply to an unset-clock notification: the
	/// device file it was posted for and the start time typed.
	static func prepare(
		onStartTime: @escaping @MainActor (_ file: String, _ time: String) -> Void
	) {
		guard bundled else { return }
		startTimeReply = onStartTime
		let center = UNUserNotificationCenter.current()
		center.delegate = shared
		center.setNotificationCategories([unsetClockCategory])
		center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
			Log.d("notifications granted: \(granted)")
		}
	}

	/// A notification posted again under the same identifier replaces the
	/// one already shown.
	static func post(
		title: String, message: String, opening url: URL? = nil, identifier: String? = nil
	) {
		guard bundled else {
			Task {
				let script =
					"display notification \(quoted(message)) with title \(quoted(title))"
				_ = await Subprocess.run(["osascript", "-e", script])
			}
			return
		}
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = message
		if let url {
			content.userInfo = ["url": url.absoluteString]
		}
		add(content, identifier: identifier)
	}

	/// A recording the device dated 1980 has no real start time. The bundled
	/// app's notification takes one as a typed reply; a `swift run` build
	/// can't, so its notification says how to set it by hand.
	static func postUnsetClock(file: String) {
		let title = "TP-7 clock was unset"
		guard bundled else {
			post(
				title: title,
				message: "\(file) is dated 1980. Replying here needs the installed app; "
					+ "run bun src/cli.ts redate \(file) <time> instead.")
			return
		}
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = "\(file) is dated 1980. Choose Set start time to correct it."
		content.categoryIdentifier = unsetClockCategory.identifier
		content.userInfo = ["file": file]
		add(content, identifier: "unset-clock-\(file)")
	}

	private static func add(_ content: UNMutableNotificationContent, identifier: String?) {
		let request = UNNotificationRequest(
			identifier: identifier ?? UUID().uuidString, content: content, trigger: nil)
		UNUserNotificationCenter.current().add(request)
	}

	/// Announces a finished recording with its title and the summary's lead,
	/// opening the transcript on click. A recording with no speech opens its
	/// folder instead, which may hold no transcript.
	static func announce(
		_ result: PipelineResult, silence: String, identifier: String? = nil
	) {
		guard result.speech else {
			post(
				title: "No speech captured", message: silence, opening: result.folder,
				identifier: identifier)
			return
		}
		let title =
			result.title ?? TranscriptFolder(name: result.folder.lastPathComponent)?.title
			?? "Transcript ready"
		post(
			title: title, message: lead(of: result.summary) ?? "Transcript ready.",
			opening: result.transcript, identifier: identifier)
	}

	/// The first paragraph of a summary, short enough for a notification.
	static func lead(of summary: String?) -> String? {
		let paragraph = summary?.components(separatedBy: "\n\n")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.first { !$0.isEmpty }
		guard let paragraph else { return nil }
		return paragraph.count > 240 ? String(paragraph.prefix(237)) + "…" : paragraph
	}

	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		willPresent notification: UNNotification
	) async -> UNNotificationPresentationOptions {
		[.banner, .sound]
	}

	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse
	) async {
		let userInfo = response.notification.request.content.userInfo
		if response.actionIdentifier == Self.setStartTimeAction,
			let reply = response as? UNTextInputNotificationResponse,
			let file = userInfo["file"] as? String
		{
			let time = reply.userText
			await MainActor.run { Self.startTimeReply?(file, time) }
			return
		}
		guard let raw = userInfo["url"] as? String, let url = URL(string: raw) else { return }
		_ = await MainActor.run { NSWorkspace.shared.open(url) }
	}

	private static func quoted(_ text: String) -> String {
		"\"\(text.replacingOccurrences(of: "\"", with: "\\\""))\""
	}

	/// Warns that a capture's mic channel stayed below the silence floor.
	/// `macMicrophone` is for captures from the Mac's default input rather
	/// than the TP-7, where THRU is irrelevant.
	static func postSilentMic(macMicrophone: Bool = false) {
		if macMicrophone {
			post(
				title: "Mac mic is silent",
				message: "Nothing is coming from the default input. Check that it isn't muted.")
		} else {
			post(
				title: "TP-7 mic is silent",
				message: "Nothing reached the Mac. Check that THRU is on.")
		}
	}
}
