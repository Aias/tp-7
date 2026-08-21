import Foundation

enum Paths {
	private struct Config: Decodable {
		let repoRoot: String
	}

	/// The tp7sync repo root. The installed app (bundled, so it has a
	/// bundle identifier) reads `~/.config/tp7companion/config.json`,
	/// written by the packaging script; a bare `swift run` build uses its
	/// own checkout, derived from this source file's location, so
	/// development always runs against the code it was built from.
	static let repoRoot: URL = {
		let configURL = FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".config/tp7companion/config.json")
		if Bundle.main.bundleIdentifier != nil,
			let data = try? Data(contentsOf: configURL),
			let config = try? JSONDecoder().decode(Config.self, from: data)
		{
			return URL(fileURLWithPath: config.repoRoot)
		}
		return URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()  // companion/Sources/companion
			.deletingLastPathComponent()  // companion/Sources
			.deletingLastPathComponent()  // companion
			.deletingLastPathComponent()  // repo root
	}()

	static let recordingsDir = FileManager.default
		.homeDirectoryForCurrentUser
		.appendingPathComponent("Music/recordings")

	static let memosDir = recordingsDir.appendingPathComponent("memos")

	static let meetingsDir = recordingsDir.appendingPathComponent("meetings")

	static let logFile = FileManager.default
		.homeDirectoryForCurrentUser
		.appendingPathComponent("Library/Logs/tp7companion.log")
}
