@preconcurrency import AVFoundation
import Foundation

/// One gesture-driven meeting capture, mirroring the device's own transport
/// grammar: Rec arms, Play starts, Play toggles pause, Stop ends. The TP-7
/// mic and Mac system audio record as separate tracks, mixed only for
/// transcription so speaker bleed into the room mic can't double voices.
/// +/− presses drop elapsed-time markers.
@MainActor
final class MeetingSession {
	enum Phase {
		case armed
		case recording
		case paused
	}

	private(set) var phase: Phase = .armed
	private var cancelled = false

	private static let sampleRate = 48_000.0
	/// Captures shorter than this are kept as raw tracks but not transcribed.
	private static let minTranscribeSeconds = 10.0

	private let capture = AudioCapture()
	private let systemAudio = SystemAudioCapture()
	private let stamp: String
	private let micURL: URL
	private let systemURL: URL
	private let mixedURL: URL
	private let markersURL: URL
	private var markers: [(time: TimeInterval, label: String)] = []

	// Files are each touched from a single capture thread; the flags are
	// written on the main actor and read from those threads (benign races).
	private nonisolated(unsafe) var micFile: AVAudioFile?
	private nonisolated(unsafe) var systemFile: AVAudioFile?
	private nonisolated(unsafe) var micFramesWritten: AVAudioFramePosition = 0
	private nonisolated(unsafe) var dropBuffers = false

	init() {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd_HHmmss"
		stamp = formatter.string(from: Date())
		micURL = Paths.meetingsDir.appendingPathComponent("\(stamp)_meeting-mic.wav")
		systemURL = Paths.meetingsDir.appendingPathComponent("\(stamp)_meeting-system.wav")
		mixedURL = Paths.meetingsDir.appendingPathComponent("\(stamp)_meeting.wav")
		markersURL = Paths.meetingsDir.appendingPathComponent("\(stamp)_meeting-markers.md")
	}

	/// Elapsed captured audio (pauses excluded).
	var elapsed: TimeInterval {
		Double(micFramesWritten) / Self.sampleRate
	}

	/// Disarms the session. If a Play-triggered start is in flight, the
	/// start unwinds its own capture when it reaches the flag.
	func cancel() {
		cancelled = true
	}

	func start() async throws {
		guard !cancelled else { return }
		guard let device = AudioCapture.findTP7Device() else {
			throw MeetingError.deviceNotFound
		}
		guard
			let micFormat = AVAudioFormat(
				standardFormatWithSampleRate: Self.sampleRate, channels: 1)
		else {
			throw MeetingError.formatUnavailable
		}
		try FileManager.default.createDirectory(
			at: Paths.meetingsDir, withIntermediateDirectories: true)
		micFile = try AVAudioFile(
			forWriting: micURL,
			settings: [
				AVFormatIDKey: kAudioFormatLinearPCM,
				AVSampleRateKey: Self.sampleRate,
				AVNumberOfChannelsKey: 1,
				AVLinearPCMBitDepthKey: 16,
			])
		try capture.start(device: device, outputFormat: micFormat, archiveURL: nil) {
			[weak self] buffer in
			guard let self, !self.dropBuffers else { return }
			try? self.micFile?.write(from: buffer)
			self.micFramesWritten += AVAudioFramePosition(buffer.frameLength)
		}
		// System audio is best-effort: a missing Screen Recording permission
		// degrades to mic-only capture rather than blocking the meeting.
		do {
			try await systemAudio.start { [weak self] buffer in
				guard let self, !self.dropBuffers else { return }
				if self.systemFile == nil {
					self.systemFile = try? AVAudioFile(
						forWriting: self.systemURL,
						settings: [
							AVFormatIDKey: kAudioFormatLinearPCM,
							AVSampleRateKey: buffer.format.sampleRate,
							AVNumberOfChannelsKey: buffer.format.channelCount,
							AVLinearPCMBitDepthKey: 16,
						],
						commonFormat: buffer.format.commonFormat,
						interleaved: buffer.format.isInterleaved)
				}
				try? self.systemFile?.write(from: buffer)
			}
		} catch {
			Log.d("meeting: system audio unavailable: \(error)")
			Notifier.post(
				title: "Meeting is mic-only",
				message: "System audio needs the Screen Recording permission.")
		}
		// Stop/Rec/unplug may have disarmed while system audio was starting.
		if cancelled {
			capture.stop()
			await systemAudio.stop()
			micFile = nil
			systemFile = nil
			try? FileManager.default.removeItem(at: micURL)
			try? FileManager.default.removeItem(at: systemURL)
			return
		}
		phase = .recording
		Log.d("meeting: recording → \(micURL.lastPathComponent)")
	}

	func pause() {
		guard phase == .recording else { return }
		dropBuffers = true
		phase = .paused
		Log.d("meeting: paused at \(Self.hms(elapsed))")
	}

	func resume() {
		guard phase == .paused else { return }
		dropBuffers = false
		phase = .recording
		Log.d("meeting: resumed")
	}

	func marker(_ label: String) {
		guard phase == .recording else { return }
		markers.append((time: elapsed, label: label))
		Log.d("meeting: marker \(label) at \(Self.hms(elapsed))")
	}

	/// Stops both tracks, mixes them, and runs the batch transcription
	/// pipeline; artifacts group into the pipeline's titled folder.
	func finish() async {
		let duration = elapsed
		capture.stop()
		await systemAudio.stop()
		micFile = nil
		systemFile = nil
		writeMarkers()
		Log.d("meeting: finished, \(Self.hms(duration)) captured, \(markers.count) markers")
		guard duration >= Self.minTranscribeSeconds else {
			Notifier.post(
				title: "Meeting too short",
				message: "Kept the raw tracks in meetings/, skipped transcription.")
			return
		}
		Notifier.post(
			title: "Meeting captured",
			message: "Transcribing \(Self.hms(duration)) of audio…")
		let input = await mixTracks()
		let ok = await Subprocess.runLogged(
			["bun", "src/cli.ts", "transcribe", input.path],
			currentDirectory: Paths.repoRoot)
		guard ok else {
			Notifier.post(
				title: "Meeting transcription failed",
				message: "Raw tracks are in meetings/; see tp7companion.log")
			return
		}
		try? FileManager.default.removeItem(at: mixedURL)
		let folder = groupArtifacts()
		Notifier.post(title: "Meeting transcribed", message: folder ?? stamp)
	}

	/// Downmixes system audio to mono and mixes it with the mic track.
	/// Returns the pipeline input: the mix, or the mic track alone when
	/// system audio was never captured (or the mix failed).
	private func mixTracks() async -> URL {
		guard FileManager.default.fileExists(atPath: systemURL.path) else {
			return micURL
		}
		let mixed = await Subprocess.runLogged(
			[
				"ffmpeg", "-y", "-i", micURL.path, "-i", systemURL.path,
				"-filter_complex",
				"[1:a]pan=mono|c0=0.5*c0+0.5*c1[sys];"
					+ "[0:a][sys]amix=inputs=2:duration=longest[out]",
				"-map", "[out]", mixedURL.path,
			])
		if !mixed {
			Log.d("meeting: mix failed, transcribing mic track only")
		}
		return mixed ? mixedURL : micURL
	}

	private func writeMarkers() {
		guard !markers.isEmpty else { return }
		let lines = markers.map { "- \(Self.hms($0.time)) \($0.label)" }
		let content = "# Markers\n\n" + lines.joined(separator: "\n") + "\n"
		try? content.write(to: markersURL, atomically: true, encoding: .utf8)
	}

	/// The pipeline names its output folder `YYYY-MM-DD_HHMM-<title>` from
	/// the input filename; move the raw tracks and markers in with it.
	private func groupArtifacts() -> String? {
		let prefix = String(stamp.prefix("yyyy-MM-dd_HHmm".count))
		let manager = FileManager.default
		guard
			let entries = try? manager.contentsOfDirectory(
				at: Paths.meetingsDir, includingPropertiesForKeys: [.isDirectoryKey]),
			let folder = entries.first(where: { url in
				url.hasDirectoryPath && url.lastPathComponent.hasPrefix(prefix)
			})
		else {
			Log.d("meeting: no pipeline folder matching \(prefix), leaving tracks flat")
			return nil
		}
		for url in [micURL, systemURL, markersURL] where manager.fileExists(atPath: url.path) {
			try? manager.moveItem(
				at: url, to: folder.appendingPathComponent(url.lastPathComponent))
		}
		return folder.lastPathComponent
	}

	private static func hms(_ seconds: TimeInterval) -> String {
		let total = Int(seconds)
		return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
	}

	enum MeetingError: Error {
		case deviceNotFound
		case formatUnavailable
	}
}
