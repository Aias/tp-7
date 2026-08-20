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

	func applicationDidFinishLaunching(_ notification: Notification) {
		statusItem = StatusItemController(
			onIngestNow: { [weak self] in self?.ingestNow() },
			onBrowseDevice: { [weak self] in self?.browseDevice() })
		let midi = MIDIEngine { [weak self] event in
			Task { @MainActor in self?.handle(event) }
		}
		self.midi = midi
		midi.start()
	}

	private func handle(_ event: MIDIEvent) {
		switch event {
		case .presenceChanged(let present, _):
			// The device drops off MIDI while it re-enumerates for MTP, so
			// detach handling is suppressed mid-ingest.
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
		}
		render()
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
		if ingesting { return .ingesting }
		if !devicePresent { return .absent }
		return gesturesSeen ? .control : .recorder
	}

	private func render() {
		statusItem?.update(state: state, identity: identity, lastGesture: lastGesture)
	}
}
