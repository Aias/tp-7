import AVFoundation
import Foundation
import Speech

/// One memo-hold dictation: captures the TP-7 mic, streams it through the
/// on-device SpeechTranscriber, forwards live hypotheses to the inserter,
/// and archives the audio plus final transcript.
@MainActor
final class DictationSession {
	private let capture = AudioCapture()
	private let inserter: TextInserter
	private var analyzer: SpeechAnalyzer?
	private var transcriber: SpeechTranscriber?
	private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
	private var resultsTask: Task<Void, Never>?
	private var finalizedText = ""
	private var volatileText = ""
	private var previousVolatile = ""
	private let audioURL: URL

	init(inserter: TextInserter) {
		self.inserter = inserter
		let audioDir = Paths.memosDir.appendingPathComponent("audio")
		try? FileManager.default.createDirectory(
			at: audioDir, withIntermediateDirectories: true)
		audioURL = audioDir.appendingPathComponent("\(Self.timestamp())-dictation.wav")
	}

	/// Ensures the on-device transcription model is installed.
	static func prepareModel() async throws {
		let locale = Locale.current
		let supported = await SpeechTranscriber.supportedLocales
		Log.d(
			"model: locale \(locale.identifier), supported: "
				+ supported.map(\.identifier).joined(separator: " "))
		let transcriber = SpeechTranscriber(
			locale: locale, transcriptionOptions: [],
			reportingOptions: [.volatileResults], attributeOptions: [])
		if let request = try await AssetInventory.assetInstallationRequest(
			supporting: [transcriber])
		{
			Log.d("model: downloading…")
			try await request.downloadAndInstall()
			Log.d("model: installed")
		} else {
			Log.d("model: already installed")
		}
	}

	func start() async throws {
		guard let device = AudioCapture.findTP7Device() else {
			throw DictationError.deviceNotFound
		}
		let transcriber = SpeechTranscriber(
			locale: Locale.current, transcriptionOptions: [],
			reportingOptions: [.volatileResults], attributeOptions: [])
		self.transcriber = transcriber
		let analyzer = SpeechAnalyzer(modules: [transcriber])
		self.analyzer = analyzer
		guard
			let format = await SpeechAnalyzer.bestAvailableAudioFormat(
				compatibleWith: [transcriber])
		else {
			throw DictationError.noCompatibleFormat
		}
		let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
		inputContinuation = continuation
		inserter.beginUtterance()
		resultsTask = Task { [weak self] in
			do {
				for try await result in transcriber.results {
					guard let self else { return }
					let text = String(result.text.characters)
					Log.d(
						"transcriber: \(result.isFinal ? "final" : "volatile") "
							+ "\"\(text.prefix(60))\"")
					if result.isFinal {
						self.finalizedText += text
						self.volatileText = ""
						self.previousVolatile = ""
						self.inserter.update(to: self.finalizedText, isFinal: true)
					} else {
						self.volatileText = text
						// Only stream the hypothesis prefix that survived two
						// consecutive updates, cut at a word boundary — the
						// churn lives in the last word or two.
						let stable = Self.wordBoundaryPrefix(
							self.previousVolatile.commonPrefix(with: text))
						self.previousVolatile = text
						self.inserter.update(
							to: self.finalizedText + stable, isFinal: false)
					}
				}
				Log.d("transcriber: results stream ended")
			} catch {
				Log.d("transcriber: results stream error: \(error)")
			}
		}
		try await analyzer.start(inputSequence: stream)
		Log.d("dictation: analyzer started")
		try capture.start(device: device, outputFormat: format, archiveURL: audioURL) {
			buffer in
			continuation.yield(AnalyzerInput(buffer: buffer))
		}
	}

	/// Stops capture, finalizes the transcript, and archives it. Returns the
	/// final text.
	func finish() async -> String {
		capture.stop()
		inputContinuation?.finish()
		do {
			try await analyzer?.finalizeAndFinishThroughEndOfInput()
		} catch {
			Log.d("dictation: finalize failed: \(error)")
		}
		resultsTask?.cancel()
		let text = (finalizedText + volatileText)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		Log.d("dictation: finished, \(text.count) chars → \(audioURL.lastPathComponent)")
		inserter.endUtterance()
		if !text.isEmpty {
			appendToDailyJournal(text)
		}
		return text
	}

	/// Memos accumulate into one markdown file per day; audio lives in the
	/// audio/ subfolder.
	private func appendToDailyJournal(_ text: String) {
		let day = Self.dayStamp()
		let journalURL = Paths.memosDir.appendingPathComponent("\(day).md")
		let time = Self.timeStamp()
		let entry = "## \(time)\n\n\(text)\n\n"
		do {
			if let handle = try? FileHandle(forWritingTo: journalURL) {
				handle.seekToEndOfFile()
				if let data = entry.data(using: .utf8) {
					handle.write(data)
				}
				try handle.close()
			} else {
				try entry.write(to: journalURL, atomically: true, encoding: .utf8)
			}
		} catch {
			Log.d("dictation: journal append failed: \(error)")
		}
	}

	private static func dayStamp() -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter.string(from: Date())
	}

	private static func timeStamp() -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm"
		return formatter.string(from: Date())
	}

	/// Trims to the last complete word so half-typed words never appear.
	private static func wordBoundaryPrefix(_ text: String) -> String {
		guard let lastSpace = text.lastIndex(of: " ") else { return "" }
		return String(text[...lastSpace])
	}

	private static func timestamp() -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd_HHmmss"
		return formatter.string(from: Date())
	}

	enum DictationError: Error {
		case deviceNotFound
		case noCompatibleFormat
	}
}
