import Foundation

enum Subprocess {
	private static let path =
		"\(NSHomeDirectory())/.bun/bin:"
		+ "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

	private static func makeProcess(_ arguments: [String], currentDirectory: URL?) -> Process {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = arguments
		process.environment = ProcessInfo.processInfo.environment
			.merging(["PATH": path]) { _, new in new }
		if let currentDirectory {
			process.currentDirectoryURL = currentDirectory
		}
		return process
	}

	private static func openLog() -> FileHandle? {
		if !FileManager.default.fileExists(atPath: Paths.logFile.path) {
			FileManager.default.createFile(atPath: Paths.logFile.path, contents: nil)
		}
		let log = try? FileHandle(forWritingTo: Paths.logFile)
		log?.seekToEndOfFile()
		return log
	}

	/// Runs a command, returning stdout on success and nil on failure.
	static func run(
		_ arguments: [String],
		currentDirectory: URL? = nil
	) async -> String? {
		await withCheckedContinuation { continuation in
			let process = makeProcess(arguments, currentDirectory: currentDirectory)
			let stdout = Pipe()
			// Never inherit the terminal's stdin: a tool that reads it
			// (ffmpeg) gets suspended by job control and hangs the caller.
			process.standardInput = FileHandle.nullDevice
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
		guard let log = openLog() else { return false }
		return await withCheckedContinuation { continuation in
			let process = makeProcess(arguments, currentDirectory: currentDirectory)
			process.standardInput = FileHandle.nullDevice
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

	/// Starts a long-running command fed through `stdin` and read through
	/// `stdout`; its stderr goes to the companion log file.
	static func spawn(
		_ arguments: [String],
		currentDirectory: URL? = nil,
		stdin: Pipe,
		stdout: Pipe
	) throws -> Process {
		let process = makeProcess(arguments, currentDirectory: currentDirectory)
		process.standardInput = stdin
		process.standardOutput = stdout
		process.standardError = openLog() ?? FileHandle.nullDevice
		try process.run()
		return process
	}
}
