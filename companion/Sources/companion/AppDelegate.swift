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

	/// After a side-button tap, a memo hold within this window attaches a
	/// spoken instruction; otherwise the request goes out as-is.
	private static let requestSpeakWindow = 4.0
	/// Finalized speech trails a memo release by a moment.
	private static let noteSettleSeconds = 1.5

	func applicationDidFinishLaunching(_ notification: Notification) {
		statusItem = StatusItemController(
			onIngestNow: { [weak self] in self?.ingestNow() },
			onBrowseDevice: { [weak self] in self?.browseDevice() })
		let midi = MIDIEngine { [weak self] event in
			Task { @MainActor in self?.handle(event) }
		}
		self.midi = midi
		midi.start()
		Notifier.prepare()
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
		Task { await MeetingSession.recoverOrphans() }
	}

	private func handle(_ event: MIDIEvent) {
		switch event {
		case .presenceChanged(let present, _):
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
					Task { await meeting.finish() }
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
			guard pending.verb != verb, instruction == nil else { return }
			pendingRequest = (verb, pending.context)
			Log.d("agent: request switched to \(verb.rawValue)")
			armRequestTimer()
			return
		}
		guard dictation == nil, !ingesting else { return }
		Task {
			let context = await CaptureContext.current()
			pendingRequest = (verb, context)
			Log.d("agent: \(verb.rawValue) request pending, hold memo to add words")
			armRequestTimer()
			render()
		}
	}

	/// Tapping the other side button within the window switches the verb
	/// and restarts the clock.
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

	private func startInstruction() {
		let session = DictationSession(inserter: nil)
		instruction = session
		Task {
			do {
				try await session.start()
			} catch {
				instruction = nil
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
			Task { await meeting.finish() }
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
				dictation = nil
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

	private func ingestNow() {
		guard !ingesting else { return }
		ingesting = true
		render()
		Task {
			let ok = await Subprocess.runLogged(
				["bun", "src/cli.ts", "now"], currentDirectory: Paths.repoRoot)
			ingesting = false
			if !ok {
				Notifier.post(
					title: "TP-7 ingest failed",
					message: "See ~/Library/Logs/tp7companion.log")
			}
			render()
		}
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
		if pendingRequest != nil { return .agentRequest }
		if dictation != nil { return .dictating }
		if ingesting { return .ingesting }
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
