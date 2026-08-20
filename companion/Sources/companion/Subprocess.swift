import Foundation

enum Subprocess {
	private static let path =
		"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

	/// Runs a command, returning stdout on success and nil on failure.
	static func run(
		_ arguments: [String],
		currentDirectory: URL? = nil
	) async -> String? {
		await withCheckedContinuation { continuation in
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
			process.arguments = arguments
			process.environment = ProcessInfo.processInfo.environment
				.merging(["PATH": path]) { _, new in new }
			if let currentDirectory {
				process.currentDirectoryURL = currentDirectory
			}
			let stdout = Pipe()
			process.standardOutput = stdout
			process.standardError = FileHandle.nullDevice
			process.terminationHandler = { process in
				let data = stdout.fileHandleForReading.readDataToEndOfFile()
				let output = String(data: data, encoding: .utf8)
				continuation.resume(
					returning: process.terminationStatus == 0 ? output : nil)
			}
			do {
				try process.run()
			} catch {
				continuation.resume(returning: nil)
			}
		}
	}

	/// Runs a command streaming all output to the companion log file.
	/// Returns true on exit status 0.
	static func runLogged(
		_ arguments: [String],
		currentDirectory: URL? = nil
	) async -> Bool {
		FileManager.default.createFile(atPath: Paths.logFile.path, contents: nil)
		guard let log = try? FileHandle(forWritingTo: Paths.logFile) else {
			return false
		}
		log.seekToEndOfFile()
		return await withCheckedContinuation { continuation in
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
			process.arguments = arguments
			process.environment = ProcessInfo.processInfo.environment
				.merging(["PATH": path]) { _, new in new }
			if let currentDirectory {
				process.currentDirectoryURL = currentDirectory
			}
			process.standardOutput = log
			process.standardError = log
			process.terminationHandler = { process in
				try? log.close()
				continuation.resume(returning: process.terminationStatus == 0)
			}
			do {
				try process.run()
			} catch {
				try? log.close()
				continuation.resume(returning: false)
			}
		}
	}
}
