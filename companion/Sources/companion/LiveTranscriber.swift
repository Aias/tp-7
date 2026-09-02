@preconcurrency import AVFoundation
import Foundation
import Speech

/// On-device transcription of one audio source, finalized segments only,
/// each stamped with its position in the source's own timeline. Feeds the
/// rolling meeting transcript; the batch pipeline remains the transcript
/// of record.
@MainActor
final class LiveTranscriber {
	struct Segment {
		let start: TimeInterval
		let text: String
	}

	private var analyzer: SpeechAnalyzer?
	private nonisolated(unsafe) var continuation: AsyncStream<AnalyzerInput>.Continuation?
	private var resultsTask: Task<Void, Never>?
	private nonisolated(unsafe) var converter: AVAudioConverter?
	private nonisolated(unsafe) var analyzerFormat: AVAudioFormat?
	private(set) var segments: [Segment] = []

	func start(inputFormat: AVAudioFormat) async throws {
		let transcriber = SpeechTranscriber(
			locale: Locale.current, transcriptionOptions: [],
			reportingOptions: [], attributeOptions: [])
		guard
			let format = await SpeechAnalyzer.bestAvailableAudioFormat(
				compatibleWith: [transcriber]),
			let converter = AVAudioConverter(from: inputFormat, to: format)
		else {
			throw LiveTranscriberError.noCompatibleFormat
		}
		converter.channelMap = [0]
		self.converter = converter
		analyzerFormat = format
		let analyzer = SpeechAnalyzer(modules: [transcriber])
		self.analyzer = analyzer
		let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
		self.continuation = continuation
		resultsTask = Task { [weak self] in
			do {
				for try await result in transcriber.results {
					let text = String(result.text.characters)
						.trimmingCharacters(in: .whitespacesAndNewlines)
					guard !text.isEmpty else { continue }
					self?.segments.append(Segment(start: result.range.start.seconds, text: text))
				}
			} catch {
				Log.d("live transcriber: results stream error: \(error)")
			}
		}
		try await analyzer.start(inputSequence: stream)
	}

	/// Called from the capture thread with buffers in `inputFormat`.
	nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
		guard let converter, let format = analyzerFormat else { return }
		let ratio = format.sampleRate / buffer.format.sampleRate
		let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
		guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
		else { return }
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
		guard error == nil, converted.frameLength > 0 else { return }
		continuation?.yield(AnalyzerInput(buffer: converted))
	}

	func stop() async {
		continuation?.finish()
		do {
			try await analyzer?.finalizeAndFinishThroughEndOfInput()
		} catch {
			Log.d("live transcriber: finalize failed: \(error)")
		}
		resultsTask?.cancel()
	}

	/// Segments that start inside the span, joined.
	func text(from start: TimeInterval, to end: TimeInterval) -> String {
		segments
			.filter { $0.start >= start && $0.start <= end }
			.map(\.text)
			.joined(separator: " ")
	}

	enum LiveTranscriberError: Error {
		case noCompatibleFormat
	}
}
