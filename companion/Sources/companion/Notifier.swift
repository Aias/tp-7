import AppKit
import UserNotifications

/// Posts macOS notifications. The installed app (bundled) uses
/// UNUserNotificationCenter so a click can open the capture's transcript;
/// a bare `swift run` build has no bundle identity, which that framework
/// requires, so it falls back to osascript and clicks do nothing.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
	private static let shared = Notifier()
	private static let bundled = Bundle.main.bundleIdentifier != nil

	static func prepare() {
		guard bundled else { return }
		let center = UNUserNotificationCenter.current()
		center.delegate = shared
		center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
			Log.d("notifications granted: \(granted)")
		}
	}

	static func post(title: String, message: String, opening url: URL? = nil) {
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
		let request = UNNotificationRequest(
			identifier: UUID().uuidString, content: content, trigger: nil)
		UNUserNotificationCenter.current().add(request)
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
		guard let raw = response.notification.request.content.userInfo["url"] as? String,
			let url = URL(string: raw)
		else { return }
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
