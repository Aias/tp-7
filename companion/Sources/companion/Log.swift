import Foundation

/// Debug logging to stdout (visible under `swift run`) and the companion
/// log file (readable after the fact).
enum Log {
	private static let lock = NSLock()

	static func d(_ message: String) {
		let stamp = ISO8601DateFormatter().string(from: Date())
		let line = "[\(stamp)] \(message)\n"
		print(line, terminator: "")
		lock.lock()
		defer { lock.unlock() }
		guard let data = line.data(using: .utf8) else { return }
		if let handle = try? FileHandle(forWritingTo: Paths.logFile) {
			handle.seekToEndOfFile()
			handle.write(data)
			try? handle.close()
		} else {
			FileManager.default.createFile(atPath: Paths.logFile.path, contents: data)
		}
	}
}
