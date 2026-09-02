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
	/// Captures shorter than this are button tests, not meetings, and are deleted.
	private static let minTranscribeSeconds = 5.0

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
		micURL = Self.micURL(for: stamp)
		systemURL = Self.systemURL(for: stamp)
		mixedURL = Self.mixedURL(for: stamp)
		markersURL = Self.markersURL(for: stamp)
		Log.d("meeting: armed \(stamp)")
	}

	private static let micSuffix = "_meeting-mic.wav"

	private static func micURL(for stamp: String) -> URL {
		Paths.meetingsDir.appendingPathComponent("\(stamp)\(micSuffix)")
	}

	private static func systemURL(for stamp: String) -> URL {
		Paths.meetingsDir.appendingPathComponent("\(stamp)_meeting-system.wav")
	}

	private static func mixedURL(for stamp: String) -> URL {
		Paths.meetingsDir.appendingPathComponent("\(stamp)_meeting.wav")
	}

	private static func markersURL(for stamp: String) -> URL {
		Paths.meetingsDir.appendingPathComponent("\(stamp)_meeting-markers.md")
	}

	/// Elapsed captured audio (pauses excluded).
	var elapsed: TimeInterval {
		Double(micFramesWritten) / Self.sampleRate
	}

	/// Disarms the session. If a Play-triggered start is in flight, the
	/// start unwinds its own capture when it reaches the flag.
	func cancel() {
		cancelled = true
		Log.d("meeting: disarmed \(stamp)")
	}

	func start() async throws {
		guard !cancelled else { return }
		// The TP-7 mic when wired; over BLE (gestures only, no audio path)
		// the Mac's default input keeps the room track alive.
		let device: AudioDeviceID
		if let tp7 = AudioCapture.findTP7Device() {
			device = tp7
		} else if let fallback = AudioCapture.defaultInputDevice() {
			device = fallback
			Log.d("meeting: TP-7 not on USB, capturing the default input device")
			Notifier.post(
				title: "Recording with the Mac microphone",
				message: "The TP-7 isn't wired for audio; using the default input.")
		} else {
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
			Log.d("meeting: start cancelled, discarding \(stamp)")
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
		Log.d("meeting: finished, \(Self.hms(duration)) captured, \(markers.count) markers")
		guard duration >= Self.minTranscribeSeconds else {
			Self.discard(stamp: stamp)
			Notifier.post(
				title: "Meeting discarded",
				message: "Captures under \(Int(Self.minTranscribeSeconds)) seconds are dropped.")
			return
		}
		writeMarkers()
		Notifier.post(
			title: "Meeting captured",
			message: "Transcribing \(Self.hms(duration)) of audio…")
		await Self.process(stamp: stamp)
	}

	/// Mixes a finished capture's tracks, runs the batch transcription
	/// pipeline, and groups everything into the pipeline's titled folder.
	/// Shared by the live Stop path and the launch-time recovery sweep.
	static func process(stamp: String) async {
		let input = await mixTracks(stamp: stamp)
		let ok = await Subprocess.runLogged(
			["bun", "src/cli.ts", "transcribe", input.path],
			currentDirectory: Paths.repoRoot)
		guard ok else {
			Notifier.post(
				title: "Meeting transcription failed",
				message: "Raw tracks are in meetings/; see tp7companion.log")
			return
		}
		let folder = groupArtifacts(stamp: stamp)
		Notifier.post(title: "Meeting transcribed", message: folder ?? stamp)
	}

	/// Captures the companion never finished processing — a quit or crash
	/// mid-meeting, or a failed pipeline run — leave flat track files with
	/// no transcript folder. Sweep them through the normal path.
	static func recoverOrphans() async {
		let manager = FileManager.default
		guard
			let entries = try? manager.contentsOfDirectory(
				at: Paths.meetingsDir, includingPropertiesForKeys: nil)
		else { return }
		// Stray mixes whose capture is already fully grouped (a quit landed
		// between the move and the delete) have no mic file to key off.
		for url in entries where !url.hasDirectoryPath {
			let name = url.lastPathComponent
			guard name.hasSuffix("_meeting.wav") else { continue }
			let stamp = String(name.dropLast("_meeting.wav".count))
			if titledFolder(for: stamp) != nil, !manager.fileExists(atPath: micURL(for: stamp).path) {
				try? manager.removeItem(at: url)
			}
		}
		let stamps = entries
			.filter { !$0.hasDirectoryPath && $0.lastPathComponent.hasSuffix(micSuffix) }
			.map { String($0.lastPathComponent.dropLast(micSuffix.count)) }
			.sorted()
		for stamp in stamps {
			// Transcribed but never grouped: just finish the grouping.
			if titledFolder(for: stamp) != nil {
				_ = groupArtifacts(stamp: stamp)
				continue
			}
			// An interrupted capture's WAV header was never finalized;
			// a stream-copy remux repairs it losslessly.
			await repairHeader(micURL(for: stamp))
			await repairHeader(systemURL(for: stamp))
			guard let duration = await duration(of: micURL(for: stamp)) else {
				Log.d("meeting: orphan \(stamp) unreadable, leaving as-is")
				continue
			}
			guard duration >= minTranscribeSeconds else {
				Log.d("meeting: orphan \(stamp) too short (\(hms(duration))), discarding")
				discard(stamp: stamp)
				continue
			}
			Log.d("meeting: recovering orphaned capture \(stamp) (\(hms(duration)))")
			Notifier.post(
				title: "Recovering interrupted meeting",
				message: "Transcribing \(hms(duration)) from \(stamp)…")
			await process(stamp: stamp)
		}
	}

	private static func discard(stamp: String) {
		let urls = [
			micURL(for: stamp), systemURL(for: stamp),
			mixedURL(for: stamp), markersURL(for: stamp),
		]
		for url in urls {
			try? FileManager.default.removeItem(at: url)
		}
	}

	private static func repairHeader(_ url: URL) async {
		guard FileManager.default.fileExists(atPath: url.path) else { return }
		let temp = FileManager.default.temporaryDirectory
			.appendingPathComponent(url.lastPathComponent)
		let ok = await Subprocess.runLogged(
			["ffmpeg", "-y", "-v", "error", "-i", url.path, "-c", "copy", temp.path])
		guard ok else { return }
		try? FileManager.default.removeItem(at: url)
		try? FileManager.default.moveItem(at: temp, to: url)
	}

	private static func duration(of url: URL) async -> TimeInterval? {
		let output = await Subprocess.run([
			"ffprobe", "-v", "error", "-show_entries", "format=duration",
			"-of", "csv=p=0", url.path,
		])
		return output.flatMap {
			TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines))
		}
	}

	/// Downmixes system audio to mono and mixes it with the mic track.
	/// Returns the pipeline input: the mix, or the mic track alone when
	/// system audio was never captured (or the mix failed).
	private static func mixTracks(stamp: String) async -> URL {
		let micURL = micURL(for: stamp)
		let systemURL = systemURL(for: stamp)
		guard FileManager.default.fileExists(atPath: systemURL.path) else {
			return micURL
		}
		let mixedURL = mixedURL(for: stamp)
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
	/// the input filename.
	private static func titledFolder(for stamp: String) -> URL? {
		let prefix = String(stamp.prefix("yyyy-MM-dd_HHmm".count))
		let entries = try? FileManager.default.contentsOfDirectory(
			at: Paths.meetingsDir, includingPropertiesForKeys: [.isDirectoryKey])
		return entries?.first { url in
			url.hasDirectoryPath && url.lastPathComponent.hasPrefix(prefix)
		}
	}

	/// Moves the raw tracks and markers into the pipeline's titled folder.
	/// The mix is derived (regenerated on demand), so it's dropped rather
	/// than kept.
	private static func groupArtifacts(stamp: String) -> String? {
		try? FileManager.default.removeItem(at: mixedURL(for: stamp))
		guard let folder = titledFolder(for: stamp) else {
			Log.d("meeting: no pipeline folder for \(stamp), leaving tracks flat")
			return nil
		}
		let manager = FileManager.default
		for url in [micURL(for: stamp), systemURL(for: stamp), markersURL(for: stamp)]
		where manager.fileExists(atPath: url.path) {
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
