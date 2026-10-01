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

	/// Opened for appending so the child's stderr and this process's own
	/// writes interleave instead of overwriting one another.
	private static func openLog() -> FileHandle? {
		let descriptor = open(Paths.logFile.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
		guard descriptor >= 0 else { return nil }
		return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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
		await runLogged(arguments, currentDirectory: currentDirectory) { _ in }
	}

	private enum Output: Sendable {
		case event(PipelineEvent)
		case drained
		case exited(succeeded: Bool)
	}

	/// Runs a command streaming all output to the companion log file, and
	/// hands `onEvent` each `@tp7 ` event line as it arrives. Returns true
	/// on exit status 0, after every event has been delivered.
	///
	/// A thread reads stdout to its end and the termination handler reports
	/// the exit status, both through one stream, so `onEvent` runs on the
	/// main actor, one event at a time, in the order the command printed
	/// them. The exit status comes from the termination handler because
	/// `waitUntilExit`, called from the reading thread, can hang after the
	/// process has exited.
	static func runLogged(
		_ arguments: [String],
		currentDirectory: URL? = nil,
		onEvent: @MainActor (PipelineEvent) -> Void
	) async -> Bool {
		guard let log = openLog() else { return false }
		let process = makeProcess(arguments, currentDirectory: currentDirectory)
		let stdout = Pipe()
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = stdout
		process.standardError = log
		let (output, continuation) = AsyncStream<Output>.makeStream()
		process.terminationHandler = { process in
			continuation.yield(.exited(succeeded: process.terminationStatus == 0))
		}
		do {
			try process.run()
		} catch {
			try? log.close()
			return false
		}
		let reader = stdout.fileHandleForReading
		DispatchQueue.global().async {
			var pending = Data()
			func forward(_ line: Data) {
				let text = String(decoding: line, as: UTF8.self)
				if let event = PipelineEvent.parse(text) {
					continuation.yield(.event(event))
				}
			}
			while case let chunk = reader.availableData, !chunk.isEmpty {
				try? log.write(contentsOf: chunk)
				pending.append(chunk)
				while let newline = pending.firstIndex(of: 0x0A) {
					forward(pending[..<newline])
					pending.removeSubrange(...newline)
				}
			}
			if !pending.isEmpty {
				forward(pending)
			}
			continuation.yield(.drained)
		}
		var succeeded = false
		var outstanding = 2
		for await item in output {
			switch item {
			case .event(let event):
				await onEvent(event)
			case .drained:
				outstanding -= 1
			case .exited(let ok):
				succeeded = ok
				outstanding -= 1
			}
			if outstanding == 0 { break }
		}
		try? log.close()
		return succeeded
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
