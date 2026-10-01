import AVFoundation
import AppKit
import Speech

/// One memo-hold dictation: captures the TP-7 mic, streams it through the
/// on-device SpeechTranscriber, forwards live hypotheses to the inserter,
/// and archives the audio plus final transcript. Without an inserter the
/// speech is captured for its text alone (an agent instruction).
@MainActor
final class DictationSession {
	private let capture = AudioCapture()
	private let inserter: TextInserter?
	private var analyzer: SpeechAnalyzer?
	private var analyzerStartup: Task<Void, any Error>?
	private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
	private var resultsTask: Task<Void, Never>?
	private var finalizedText = ""
	private var volatileText = ""
	private var previousVolatile = ""
	/// Set when the memo is released. A `start()` still waiting on the Speech
	/// framework at that point must not begin capturing afterwards.
	private var finished = false
	private let audioURL: URL
	private var context: Task<CaptureContext, Never>?

	/// The analyzer's input format depends only on the locale's transcriber,
	/// so it is resolved once and capture can start before any Speech call.
	private static var analyzerFormat: AVAudioFormat?
	/// A transcriber and analyzer prepared ahead of the next dictation.
	/// Preparing speeds up only the instance prepared, and an analyzer serves
	/// one dictation, so each session takes the spare and the next is
	/// prepared behind it.
	private static var spare: (transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer)?

	init(inserter: TextInserter?) {
		self.inserter = inserter
		let audioDir = Paths.memosDir.appendingPathComponent("audio")
		try? FileManager.default.createDirectory(
			at: audioDir, withIntermediateDirectories: true)
		audioURL = audioDir.appendingPathComponent("\(Self.timestamp())-dictation.flac")
	}

	/// Installs the on-device transcription model, then prepares the first
	/// analyzer and resolves the input format.
	static func prepareModel() async throws {
		try await installModel()
		await warm()
	}

	private static func makeTranscriber() -> SpeechTranscriber {
		SpeechTranscriber(
			locale: Locale.current, transcriptionOptions: [],
			reportingOptions: [.volatileResults], attributeOptions: [])
	}

	private static func resolveFormat(for transcriber: SpeechTranscriber) async -> AVAudioFormat? {
		if analyzerFormat == nil {
			analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
				compatibleWith: [transcriber])
		}
		return analyzerFormat
	}

	/// Prepares the spare analyzer, resolving the input format on the way.
	private static func warm() async {
		guard spare == nil else { return }
		let transcriber = makeTranscriber()
		guard let format = await resolveFormat(for: transcriber) else { return }
		let analyzer = SpeechAnalyzer(modules: [transcriber])
		do {
			try await analyzer.prepareToAnalyze(in: format)
		} catch {
			Log.d("dictation: analyzer preparation failed: \(error)")
			return
		}
		if spare == nil {
			spare = (transcriber, analyzer)
		}
	}

	private static func takeAnalyzer() -> (transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer) {
		if let spare {
			self.spare = nil
			return spare
		}
		let transcriber = makeTranscriber()
		return (transcriber, SpeechAnalyzer(modules: [transcriber]))
	}

	/// Ensures the on-device transcription model is installed. The model
	/// store is system-wide; when the locale's assets are already present,
	/// skip the per-app allocation request (a bare SwiftPM executable has
	/// no persistent identity, so the request would repeat every launch).
	private static func installModel() async throws {
		let locale = Locale.current
		let installed = await SpeechTranscriber.installedLocales
		if installed.contains(where: { $0.identifier == locale.identifier }) {
			Log.d("model: ready (\(locale.identifier))")
			return
		}
		let transcriber = makeTranscriber()
		if let request = try await AssetInventory.assetInstallationRequest(
			supporting: [transcriber])
		{
			Log.d("model: downloading for \(locale.identifier)…")
			try await request.downloadAndInstall()
			Log.d("model: installed")
		} else {
			Log.d("model: ready (\(locale.identifier))")
		}
	}

	/// Captures before the analyzer starts: buffers queue in the input stream
	/// until the analyzer consumes them, so speech in the first moments of
	/// the memo is never lost to Speech framework startup.
	func start() async throws {
		guard !finished else { return }
		guard let device = AudioCapture.findTP7Device() else {
			throw DictationError.deviceNotFound
		}
		let (transcriber, analyzer) = Self.takeAnalyzer()
		guard let format = await Self.resolveFormat(for: transcriber) else {
			throw DictationError.noCompatibleFormat
		}
		guard !finished else { return }
		let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
		inputContinuation = continuation
		try capture.start(device: device, outputFormat: format, archiveURL: audioURL) {
			buffer in
			continuation.yield(AnalyzerInput(buffer: buffer))
		}
		self.analyzer = analyzer
		inserter?.beginUtterance()
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
						self.inserter?.update(to: self.finalizedText, isFinal: true)
					} else {
						self.volatileText = text
						// Only stream the hypothesis prefix that survived two
						// consecutive updates, cut at a word boundary — the
						// churn lives in the last word or two.
						let stable = Self.wordBoundaryPrefix(
							self.previousVolatile.commonPrefix(with: text))
						self.previousVolatile = text
						self.inserter?.update(
							to: self.finalizedText + stable, isFinal: false)
					}
				}
				Log.d("transcriber: results stream ended")
			} catch {
				Log.d("transcriber: results stream error: \(error)")
			}
		}
		let startup = Task { try await analyzer.start(inputSequence: stream) }
		analyzerStartup = startup
		context = Task { await CaptureContext.current() }
		do {
			try await startup.value
		} catch {
			capture.stop()
			continuation.finish()
			resultsTask?.cancel()
			throw error
		}
		Log.d("dictation: analyzer started")
	}

	/// Stops capture, finalizes the transcript, and archives it. Returns the
	/// final text. Safe while `start()` is still in flight: the engine stops
	/// at once, finalizing waits for the analyzer to finish starting, and a
	/// `start()` that has not begun capturing never will.
	func finish() async -> String {
		finished = true
		capture.stop()
		inputContinuation?.finish()
		do {
			try await analyzerStartup?.value
			try await analyzer?.finalizeAndFinishThroughEndOfInput()
		} catch {
			Log.d("dictation: analyzer failed: \(error)")
		}
		Task { await Self.warm() }
		resultsTask?.cancel()
		let text = (finalizedText + volatileText)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		Log.d("dictation: finished, \(text.count) chars → \(audioURL.lastPathComponent)")
		if capture.isSilent {
			Notifier.postSilentMic()
			inserter?.endUtterance()
			return ""
		}
		let context = await context?.value
		let cleaned = text.isEmpty ? text : await cleanup(text, context: context)
		inserter?.endUtterance()
		if !cleaned.isEmpty {
			appendToDailyJournal(cleaned, context: context)
		}
		return cleaned
	}

	/// Replaces the typed utterance with a cleaned version (fillers,
	/// stutters, punctuation) from the pipeline's editing prompt. The
	/// rewrite is skipped when focus has moved on or the call took too
	/// long, since the inserter can only retype what it just typed.
	private func cleanup(_ text: String, context: CaptureContext?) async -> String {
		let started = Date()
		guard
			let cleaned = await Subprocess.run(
				["bun", "src/cli.ts", "clean", text], currentDirectory: Paths.repoRoot)?
				.trimmingCharacters(in: .whitespacesAndNewlines),
			!cleaned.isEmpty
		else {
			Log.d("dictation: cleanup failed, keeping raw text")
			return text
		}
		let elapsed = Date().timeIntervalSince(started)
		Log.d("dictation: cleaned \(text.count) → \(cleaned.count) chars in \(String(format: "%.1f", elapsed))s")
		let focusMoved = NSWorkspace.shared.frontmostApplication?.localizedName != context?.app
		if elapsed > Self.maxCleanupSeconds || focusMoved {
			Log.d("dictation: cleanup arrived late or focus moved, leaving typed text as-is")
			return cleaned
		}
		inserter?.update(to: cleaned, isFinal: true)
		return cleaned
	}

	private static let maxCleanupSeconds = 6.0

	/// Memos accumulate into one markdown file per day; audio lives in the
	/// audio/ subfolder.
	private func appendToDailyJournal(_ text: String, context: CaptureContext?) {
		let day = Self.dayStamp()
		let journalURL = Paths.memosDir.appendingPathComponent("\(day).md")
		let time = Self.timeStamp()
		let heading = context?.summary.map { "## \(time) · \($0)" } ?? "## \(time)"
		let entry = "\(heading)\n\n\(text)\n\n"
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
