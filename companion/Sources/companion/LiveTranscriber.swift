@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Streams a meeting's audio — the mic mixed with system audio when it is
/// captured — through the transcriber CLI to AssemblyAI, and keeps the
/// diarized turns that come back. Feeds the rolling meeting transcript; the
/// batch pipeline remains the transcript of record.
@MainActor
final class LiveTranscriber {
	struct Turn: Decodable {
		let order: Int
		let start: TimeInterval
		let end: TimeInterval
		let speaker: String?
		let text: String
	}

	/// Mic and system samples pair by position, the way the recorded tracks
	/// line up when the batch pipeline mixes them. Mic audio waits this long
	/// (500 ms at 16 kHz) for its system counterpart before going out alone.
	private nonisolated static let systemWait = 8_000
	private nonisolated static let systemBacklogLimit = 160_000

	private struct Pending {
		var mic: [Float] = []
		var system: [Float] = []
		var systemCaptured = false
	}

	private var turnsByOrder: [Int: Turn] = [:]
	private var process: Process?
	private var reader: Task<Void, Never>?
	private let stdin = Pipe()
	private let stdout = Pipe()
	private nonisolated let writer = DispatchQueue(label: "tp7companion.live-transcriber")
	private nonisolated let pending = Mutex(Pending())
	private nonisolated(unsafe) var mixFormat: AVAudioFormat?
	private nonisolated(unsafe) var micConverter: AVAudioConverter?
	private nonisolated(unsafe) var systemConverter: AVAudioConverter?

	var turns: [Turn] {
		turnsByOrder.values.sorted { $0.order < $1.order }
	}

	func start(micFormat: AVAudioFormat) throws {
		guard
			let format = AVAudioFormat(
				commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
				interleaved: false),
			let converter = AVAudioConverter(from: micFormat, to: format)
		else {
			throw LiveTranscriberError.noCompatibleFormat
		}
		converter.channelMap = [0]
		// A sidecar that exits early must fail the write, not kill the app.
		_ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
		process = try Subprocess.spawn(
			["bun", "src/cli.ts", "live"], currentDirectory: Paths.repoRoot,
			stdin: stdin, stdout: stdout)
		mixFormat = format
		micConverter = converter
		let output = stdout.fileHandleForReading
		reader = Task { [weak self] in
			do {
				for try await line in output.bytes.lines {
					guard let turn = try? JSONDecoder().decode(Turn.self, from: Data(line.utf8))
					else { continue }
					self?.turnsByOrder[turn.order] = turn
				}
			} catch {
				Log.d("live transcriber: read failed: \(error)")
			}
		}
	}

	/// Called from the mic capture thread. The mic paces the stream; system
	/// audio mixes in at equal weight whenever it is being captured.
	nonisolated func feedMic(_ buffer: AVAudioPCMBuffer) {
		guard let micConverter, let samples = convert(buffer, with: micConverter) else { return }
		let (mixed, gain) = pending.withLock { pending -> ([Float], Float) in
			pending.mic.append(contentsOf: samples)
			let count = max(
				min(pending.mic.count, pending.system.count), pending.mic.count - Self.systemWait)
			guard count > 0 else { return ([], 1) }
			var mixed = Array(pending.mic.prefix(count))
			let paired = min(count, pending.system.count)
			for index in 0..<paired {
				mixed[index] += pending.system[index]
			}
			pending.mic.removeFirst(count)
			pending.system.removeFirst(paired)
			return (mixed, pending.systemCaptured ? 0.5 : 1)
		}
		guard !mixed.isEmpty else { return }
		var pcm = Data(count: mixed.count * MemoryLayout<Int16>.size)
		pcm.withUnsafeMutableBytes { raw in
			let samples = raw.bindMemory(to: Int16.self)
			for (index, sample) in mixed.enumerated() {
				samples[index] = Int16(max(-1, min(1, sample * gain)) * Float(Int16.max))
			}
		}
		let input = stdin.fileHandleForWriting
		let chunk = pcm
		writer.async {
			try? input.write(contentsOf: chunk)
		}
	}

	/// Called from the system-audio queue.
	nonisolated func feedSystem(_ buffer: AVAudioPCMBuffer) {
		if systemConverter == nil, let mixFormat {
			systemConverter = AVAudioConverter(from: buffer.format, to: mixFormat)
			systemConverter?.channelMap = [0]
		}
		guard let systemConverter, let samples = convert(buffer, with: systemConverter)
		else { return }
		pending.withLock { pending in
			pending.system.append(contentsOf: samples)
			pending.systemCaptured = true
			let overflow = pending.system.count - Self.systemBacklogLimit
			if overflow > 0 {
				pending.system.removeFirst(overflow)
			}
		}
	}

	/// Ends the current turn so everything said so far comes back final.
	func endTurn() {
		guard let process, process.isRunning else { return }
		kill(process.processIdentifier, SIGUSR1)
	}

	/// Closes the stream and waits for the final turns.
	func stop() async {
		let input = stdin.fileHandleForWriting
		writer.async {
			try? input.close()
		}
		let process = process
		let deadline = Task {
			try? await Task.sleep(for: .seconds(15))
			process?.terminate()
		}
		await reader?.value
		deadline.cancel()
	}

	/// Turns that overlap the span, joined.
	func text(from start: TimeInterval, to end: TimeInterval) -> String {
		turns
			.filter { $0.end >= start && $0.start <= end }
			.map(\.text)
			.joined(separator: " ")
	}

	private nonisolated func convert(
		_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter
	) -> [Float]? {
		guard let mixFormat else { return nil }
		let ratio = mixFormat.sampleRate / buffer.format.sampleRate
		let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
		guard let converted = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: capacity)
		else { return nil }
		nonisolated(unsafe) var consumed = false
		var error: NSError?
		converter.convert(to: converted, error: &error) { _, outStatus in
			if consumed {
				outStatus.pointee = .noDataNow
				return nil
			}
			consumed = true
			outStatus.pointee = .haveData
			return buffer
		}
		guard error == nil, let channel = converted.floatChannelData?.pointee else { return nil }
		return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
	}

	enum LiveTranscriberError: Error {
		case noCompatibleFormat
	}
}
