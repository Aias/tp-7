import Foundation

/// A pipeline output folder, named `YYYY-MM-DD_HHMM-<title>` with the
/// title's words joined by hyphens ("untitled" and "no-speech" included).
struct TranscriptFolder {
	let date: String
	let time: String
	let title: String

	init?(name: String) {
		guard let match = name.wholeMatch(of: #/(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})-(.+)/#) else {
			return nil
		}
		date = String(match.1)
		time = "\(match.2):\(match.3)"
		let words = match.4.replacingOccurrences(of: "-", with: " ")
		title = words.prefix(1).uppercased() + words.dropFirst()
	}

	var menuTitle: String {
		"\(date) \(time) · \(title)"
	}
}
