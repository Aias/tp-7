import Foundation

enum Paths {
	/// The tp7sync repo root, derived from this source file's location.
	/// Suitable for development builds run via `swift run`; a bundled app
	/// will carry an explicit configuration instead.
	static let repoRoot = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()  // companion/Sources/companion
		.deletingLastPathComponent()  // companion/Sources
		.deletingLastPathComponent()  // companion
		.deletingLastPathComponent()  // repo root

	static let recordingsDir = FileManager.default
		.homeDirectoryForCurrentUser
		.appendingPathComponent("Music/recordings")

	static let memosDir = recordingsDir.appendingPathComponent("memos")

	static let logFile = FileManager.default
		.homeDirectoryForCurrentUser
		.appendingPathComponent("Library/Logs/tp7companion.log")
}
