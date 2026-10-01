import AVFoundation
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private var statusItem: StatusItemController?
	private var midi: MIDIEngine?
	private var devicePresent = false
	private var gesturesSeen = false
	private var ingesting = false
	private var identity: DeviceInfo?
	private var lastGesture: String?
	private let inserter = TextInserter()
	private var dictation: DictationSession?
	private var meeting: MeetingSession?
	private var clock: Timer?
	private var pendingRequest: (verb: AgentVerb, context: CaptureContext)?
	private var requestTimer: Timer?
	private var instruction: DictationSession?
	/// A pipeline run the menu reports on while it works.
	@MainActor
	private final class Job {
		let activity: String
		var stage: PipelineEvent.Stage?

		init(activity: String) {
			self.activity = activity
		}
	}

	/// Meetings being mixed and transcribed after Stop (or recovered at
	/// launch) and recordings transcribed after a pull, oldest first.
	private var jobs: [Job] = []
	private var manifestTail: Task<Void, Never>?
	private var wired = false
	/// Launch counts as a dock, so it starts long unwired.
	private var unwiredSince: Date? = .distantPast
	private var dockTimer: Timer?

	/// After a side-button tap, a memo hold within this window attaches a
	/// spoken instruction; otherwise the request goes out as-is.
	private static let requestSpeakWindow = 4.0
	/// Finalized speech trails a memo release by a moment.
	private static let noteSettleSeconds = 1.5
	/// Shorter gaps in the wired connection are the device re-enumerating
	/// (someone else's MTP switch, a cable wiggle), not a return to the desk.
	private static let dockAbsenceSeconds = 30.0
	/// Wait between dock-ingest attempts, the first included: the device
	/// needs a moment after attaching before an MTP switch succeeds.
	private static let dockRetrySeconds = 20.0

	func applicationDidFinishLaunching(_ notification: Notification) {
		statusItem = StatusItemController(
			onIngestNow: { [weak self] in self?.ingest() },
			onBrowseDevice: { [weak self] in self?.browseDevice() })
		let midi = MIDIEngine { [weak self] event in
			Task { @MainActor in self?.handle(event) }
		}
		self.midi = midi
		midi.start()
		Notifier.prepare { [weak self] file, time in self?.redate(file: file, to: time) }
		if !TextInserter.accessibilityGranted {
			TextInserter.requestAccessibility()
		}
		Task {
			let granted = await AVCaptureDevice.requestAccess(for: .audio)
			Log.d("mic permission granted: \(granted)")
			do {
				try await DictationSession.prepareModel()
			} catch {
				Log.d("model preparation failed: \(error)")
			}
		}
		process("transcribing meeting") { report in
			await MeetingSession.recoverOrphans(onStage: report)
		}
	}

	private func handle(_ event: MIDIEvent) {
		switch event {
		case .presenceChanged(let present, let sourceNames):
			let wired = sourceNames.contains { !$0.hasSuffix("Bluetooth") }
			if wired != self.wired {
				self.wired = wired
				wiredChanged(wired)
			}
			// The device drops off MIDI while it re-enumerates for MTP, so
			// detach handling is suppressed mid-ingest.
			if !present, let meeting {
				self.meeting = nil
				if meeting.phase == .armed {
					meeting.cancel()
				} else {
					Notifier.post(
						title: "TP-7 unplugged",
						message: "Meeting capture ended.")
					process("transcribing meeting") { report in
						await meeting.finish(onStage: report)
					}
				}
			}
			if !present && devicePresent && gesturesSeen && !ingesting {
				Notifier.post(
					title: "TP-7 unplugged in ctrl mode",
					message:
						"Flip MIDI off for long recordings — memos work regardless when powered off."
				)
			}
			devicePresent = present
			if present {
				refreshIdentity()
			} else if !ingesting {
				gesturesSeen = false
				identity = nil
			}
		case .gesture(let gesture):
			gesturesSeen = true
			lastGesture = describe(gesture)
			if case .button(let button, let pressed) = gesture {
				handle(button, pressed: pressed)
			}
		}
		render()
	}

	private func handle(_ button: TP7Button, pressed: Bool) {
		switch (button, pressed) {
		case (.memo, true): memoPressed()
		case (.memo, false): memoReleased()
		case (.up, true): beginRequest(.act)
		case (.down, true): beginRequest(.research)
		case (.rec, true): recPressed()
		case (.play, true): playPressed()
		case (.stop, true): stopPressed()
		case (.plus, true): meeting?.marker("+")
		case (.minus, true): meeting?.marker("−")
		default: break
		}
	}

	/// Memo is always "my voice": dictation to the cursor when idle, a
	/// spoken note during a meeting, and the instruction for a pending
	/// agent request in either case.
	private func memoPressed() {
		if pendingRequest != nil {
			requestTimer?.invalidate()
			requestTimer = nil
			if let meeting {
				meeting.noteBegan()
			} else {
				startInstruction()
			}
		} else if let meeting {
			meeting.noteBegan()
		} else {
			startDictation()
		}
	}

	private func memoReleased() {
		if pendingRequest != nil {
			if let meeting {
				meeting.noteEnded()
				Task {
					try? await Task.sleep(for: .seconds(Self.noteSettleSeconds))
					completeRequest(instruction: meeting.lastNoteText())
				}
			} else if let session = instruction {
				instruction = nil
				Task {
					let text = await session.finish()
					completeRequest(instruction: text.isEmpty ? nil : text)
				}
			} else {
				completeRequest(instruction: nil)
			}
		} else if let meeting {
			meeting.noteEnded()
		} else {
			stopDictation()
		}
	}

	/// The side buttons ask the agent: one to act, one to research. The
	/// request carries the moment's context (selection, window, meeting
	/// transcript so far) and any words spoken on memo within the window.
	private func beginRequest(_ verb: AgentVerb) {
		if let pending = pendingRequest {
			guard instruction == nil else { return }
			if pending.verb == verb {
				pendingRequest = nil
				requestTimer?.invalidate()
				requestTimer = nil
				Log.d("agent: request cancelled")
				render()
			} else {
				pendingRequest = (verb, pending.context)
				Log.d("agent: request switched to \(verb.rawValue)")
				armRequestTimer()
				render()
			}
			return
		}
		guard dictation == nil, !ingesting else { return }
		Task {
			let context = await CaptureContext.current(forRequest: true)
			pendingRequest = (verb, context)
			Log.d("agent: \(verb.rawValue) request pending, hold memo to add words")
			armRequestTimer()
			render()
		}
	}

	/// Within the window, the other side button switches the verb and
	/// restarts the clock; the same button again cancels the request.
	private func armRequestTimer() {
		requestTimer?.invalidate()
		requestTimer = Timer.scheduledTimer(
			withTimeInterval: Self.requestSpeakWindow, repeats: false
		) { [weak self] _ in
			Task { @MainActor in self?.completeRequest(instruction: nil) }
		}
	}

	private func completeRequest(instruction: String?) {
		guard let pending = pendingRequest else { return }
		pendingRequest = nil
		requestTimer?.invalidate()
		requestTimer = nil
		let snapshot = meeting?.snapshot()
		render()
		Task {
			await AgentRequest.launch(
				verb: pending.verb, instruction: instruction, context: pending.context,
				meeting: snapshot)
		}
	}

	/// Runs pipeline work as a job the menu shows, with the stage the work
	/// reports.
	private func process(
		_ activity: String, _ work: @escaping @MainActor (@escaping StageReport) async -> Void
	) {
		let job = Job(activity: activity)
		jobs.append(job)
		render()
		Task {
			await work { stage in
				job.stage = stage
				self.render()
			}
			jobs.removeAll { $0 === job }
			render()
		}
	}

	private func startInstruction() {
		let session = DictationSession(inserter: nil)
		instruction = session
		Task {
			do {
				try await session.start()
			} catch {
				if instruction === session {
					instruction = nil
				}
				Log.d("agent: instruction capture failed: \(error)")
				completeRequest(instruction: nil)
			}
		}
	}

	private func recPressed() {
		if let meeting, meeting.phase == .armed {
			meeting.cancel()
			self.meeting = nil
		} else if meeting == nil && dictation == nil && !ingesting {
			meeting = MeetingSession()
		}
	}

	private func playPressed() {
		guard let meeting else { return }
		switch meeting.phase {
		case .armed:
			Task {
				do {
					try await meeting.start()
				} catch {
					if self.meeting === meeting {
						self.meeting = nil
					}
					Notifier.post(
						title: "Meeting capture failed",
						message: "Could not capture from the TP-7: \(error)")
				}
				render()
			}
		case .recording:
			meeting.pause()
		case .paused:
			meeting.resume()
		}
	}

	private func stopPressed() {
		guard let meeting else { return }
		self.meeting = nil
		if meeting.phase == .armed {
			meeting.cancel()
		} else {
			process("transcribing meeting") { report in
				await meeting.finish(onStage: report)
			}
		}
	}

	private func startDictation() {
		guard dictation == nil, !ingesting, meeting == nil else { return }
		let session = DictationSession(inserter: inserter)
		dictation = session
		Task {
			do {
				try await session.start()
			} catch {
				if dictation === session {
					dictation = nil
				}
				Notifier.post(
					title: "Dictation failed",
					message: "Could not capture from the TP-7: \(error)")
				render()
			}
		}
		render()
	}

	private func stopDictation() {
		guard let session = dictation else { return }
		dictation = nil
		render()
		Task {
			_ = await session.finish()
		}
	}

	/// Only the pull needs the device, which leaves audio mode while it
	/// runs, so only the pull holds off meetings and dictation;
	/// transcription follows in the background.
	private func ingest() {
		guard !ingesting else { return }
		dockTimer?.invalidate()
		dockTimer = nil
		ingesting = true
		render()
		Task {
			let pulled = await Subprocess.runLogged(
				["bun", "src/cli.ts", "pull"], currentDirectory: Paths.repoRoot
			) { event in
				if case .misdated(let file) = event {
					Notifier.postUnsetClock(file: file)
				}
			}
			ingesting = false
			if !pulled {
				Notifier.post(
					title: "TP-7 ingest failed",
					message: "See ~/Library/Logs/tp7companion.log")
			}
			render()
			process("transcribing recordings") { report in
				await self.inManifestLane {
					await self.transcribePulled(report: report)
				}
			}
		}
	}

	private func transcribePulled(report: StageReport) async {
		let transcribed = await Subprocess.runLogged(
			["bun", "src/cli.ts", "transcribe-pulled"], currentDirectory: Paths.repoRoot
		) { event in
			switch event {
			case .stage(let stage, _):
				report(stage)
			case .result(let result):
				report(nil)
				Notifier.announce(
					result, silence: "No words in \(result.input.lastPathComponent).")
			default:
				break
			}
		}
		if !transcribed {
			Notifier.post(
				title: "TP-7 transcription failed",
				message: "See ~/Library/Logs/tp7companion.log")
		}
	}

	/// Transcription and redating both rewrite the manifest entries a
	/// recording moves through, so they run one at a time. A start time
	/// typed while a recording is still transcribing therefore applies once
	/// it has a folder to rename.
	private func inManifestLane(_ work: @escaping @MainActor () async -> Void) async {
		let previous = manifestTail
		let task = Task {
			await previous?.value
			await work()
		}
		manifestTail = task
		await task.value
	}

	/// Sets the start time of a recording the device dated 1980 and reports
	/// the folder it ended up in.
	private func redate(file: String, to time: String) {
		let time = time.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !time.isEmpty else { return }
		Task {
			await inManifestLane {
				var filed: URL?
				let redated = await Subprocess.runLogged(
					["bun", "src/cli.ts", "redate", file, time], currentDirectory: Paths.repoRoot
				) { event in
					if case .redated(_, let folder) = event {
						filed = folder
					}
				}
				guard redated else {
					Notifier.post(
						title: "Could not set the start time",
						message: "\(file) was not set to \"\(time)\". Use YYYY-MM-DD HH:MM or "
							+ "HH:MM; see ~/Library/Logs/tp7companion.log.")
					return
				}
				guard let filed else {
					Notifier.post(
						title: "Start time set",
						message: "\(file) will be filed by it once transcribed.")
					return
				}
				Notifier.post(
					title: "Start time set",
					message: TranscriptFolder(name: filed.lastPathComponent)?.menuTitle
						?? filed.lastPathComponent,
					opening: filed)
			}
		}
	}

	/// Docking ingests once. The device drops off MIDI while its own pull
	/// re-enumerates it, so absences that begin mid-ingest don't count.
	private func wiredChanged(_ wired: Bool) {
		if wired {
			if let unwiredSince, Date().timeIntervalSince(unwiredSince) >= Self.dockAbsenceSeconds {
				Log.d("dock: ingesting once the TP-7 is free")
				dockTimer?.invalidate()
				dockTimer = Timer.scheduledTimer(
					withTimeInterval: Self.dockRetrySeconds, repeats: true
				) { [weak self] _ in
					Task { @MainActor in self?.dockIngest() }
				}
			}
			unwiredSince = nil
		} else if !ingesting {
			unwiredSince = Date()
			dockTimer?.invalidate()
			dockTimer = nil
		}
	}

	/// Waits out anything the switch to MTP mode would cut off: a capture
	/// here, or another app (a call) running the TP-7's audio.
	private func dockIngest() {
		guard meeting == nil, dictation == nil, instruction == nil, pendingRequest == nil,
			let device = AudioCapture.findTP7Device(),
			!AudioCapture.isRunningSomewhere(device)
		else { return }
		ingest()
	}

	/// Snapshots the device tree over MTP (briefly flips the device out of
	/// audio mode) and opens the listing.
	private func browseDevice() {
		guard !ingesting else { return }
		ingesting = true
		render()
		Task {
			let tree = await Subprocess.run(["tp7", "-a", "tree", "/"])
			ingesting = false
			render()
			guard let tree else {
				Notifier.post(
					title: "TP-7 listing failed",
					message: "Could not open an MTP session with the device.")
				return
			}
			let file = FileManager.default.temporaryDirectory
				.appendingPathComponent("tp7-device-files.txt")
			try? tree.write(to: file, atomically: true, encoding: .utf8)
			NSWorkspace.shared.open(file)
		}
	}

	private func refreshIdentity() {
		Task {
			identity = await TP7CLI.devices().first
			render()
		}
	}

	private func describe(_ gesture: Gesture) -> String {
		switch gesture {
		case .button(let button, let pressed):
			"\(button.label) \(pressed ? "pressed" : "released")"
		case .wheel(let delta):
			"wheel \(delta > 0 ? "+" : "")\(delta)"
		case .rocker(let value):
			"rocker \(value)"
		}
	}

	private var state: DeviceState {
		if let pending = pendingRequest { return .agentRequest(pending.verb) }
		if dictation != nil { return .dictating }
		if ingesting { return .ingesting }
		if let job = jobs.last { return .processing(activity: job.activity, stage: job.stage) }
		if let meeting {
			switch meeting.phase {
			case .armed: return .meetingArmed
			case .recording: return .meetingRecording
			case .paused: return .meetingPaused
			}
		}
		if !devicePresent { return .absent }
		return gesturesSeen ? .control : .recorder
	}

	/// Elapsed capture time shows beside the icon while a meeting is
	/// recording or paused; a one-second timer keeps it ticking.
	private func render() {
		let elapsed = meeting.flatMap { $0.phase == .armed ? nil : $0.elapsed }
		statusItem?.update(
			state: state, identity: identity, lastGesture: lastGesture, elapsed: elapsed)
		let ticking = meeting?.phase == .recording
		if ticking && clock == nil {
			clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
				Task { @MainActor in self?.render() }
			}
		} else if !ticking, let clock {
			clock.invalidate()
			self.clock = nil
		}
	}
}
