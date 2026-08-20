import Foundation

/// Posts macOS notifications via osascript — UNUserNotificationCenter
/// requires an app bundle, which a SwiftPM executable doesn't have.
enum Notifier {
	static func post(title: String, message: String) {
		Task {
			let script =
				"display notification \(quoted(message)) with title \(quoted(title))"
			_ = await Subprocess.run(["osascript", "-e", script])
		}
	}

	private static func quoted(_ text: String) -> String {
		"\"\(text.replacingOccurrences(of: "\"", with: "\\\""))\""
	}
}
