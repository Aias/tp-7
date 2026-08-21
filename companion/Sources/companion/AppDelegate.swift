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

	func applicationDidFinishLaunching(_ notification: Notification) {
		statusItem = StatusItemController(
			onIngestNow: { [weak self] in self?.ingestNow() },
			onBrowseDevice: { [weak self] in self?.browseDevice() })
		let midi = MIDIEngine { [weak self] event in
			Task { @MainActor in self?.handle(event) }
		}
		self.midi = midi
		midi.start()
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
		case (.memo, true): startDictation()
		case (.memo, false): stopDictation()
		case (.rec, true): recPressed()
		case (.play, true): playPressed()
		case (.stop, true): stopPressed()
		case (.plus, true): meeting?.marker("+")
		case (.minus, true): meeting?.marker("−")
		default: break
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
			"\(button.label) \(pressed ? "down" : "up")"
		case .wheel(let delta):
			"wheel \(delta > 0 ? "+" : "")\(delta)"
		case .rocker(let value):
			"rocker \(value)"
		}
	}

	private var state: DeviceState {
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

	private func render() {
		statusItem?.update(state: state, identity: identity, lastGesture: lastGesture)
	}
}
