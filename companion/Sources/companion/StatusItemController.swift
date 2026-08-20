import AppKit

enum DeviceState {
	case absent
	/// Device present, no gestures seen — MIDI is off or not in ctrl mode.
	case recorder
	/// Device present and gesture events are flowing (MIDI=ctrl).
	case control
	case ingesting

	var symbolName: String {
		switch self {
		case .absent: "circle.dotted"
		case .recorder: "circle"
		case .control: "record.circle"
		case .ingesting: "arrow.down.circle"
		}
	}

	var label: String {
		switch self {
		case .absent: "no device"
		case .recorder: "recorder mode"
		case .control: "control mode"
		case .ingesting: "ingesting…"
		}
	}
}

/// The menu is built once and its items are mutated in place — a rebuilt
/// menu would leave the currently open instance stale.
@MainActor
final class StatusItemController {
	private let statusItem: NSStatusItem
	private let deviceItem = NSMenuItem(title: "TP-7", action: nil, keyEquivalent: "")
	private let gestureItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
	private let ingestItem: NSMenuItem
	private let browseItem: NSMenuItem
	private let onIngestNow: () -> Void
	private let onBrowseDevice: () -> Void

	init(onIngestNow: @escaping () -> Void, onBrowseDevice: @escaping () -> Void) {
		self.onIngestNow = onIngestNow
		self.onBrowseDevice = onBrowseDevice
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		ingestItem = NSMenuItem(title: "Ingest Now", action: nil, keyEquivalent: "i")
		browseItem = NSMenuItem(title: "List Device Files", action: nil, keyEquivalent: "")
		let menu = NSMenu()
		menu.autoenablesItems = false
		deviceItem.isEnabled = false
		gestureItem.isEnabled = false
		gestureItem.isHidden = true
		menu.addItem(deviceItem)
		menu.addItem(gestureItem)
		menu.addItem(.separator())
		ingestItem.target = self
		ingestItem.action = #selector(ingestNow)
		menu.addItem(ingestItem)
		browseItem.target = self
		browseItem.action = #selector(browseDevice)
		menu.addItem(browseItem)
		let open = NSMenuItem(
			title: "Open Recordings Folder", action: #selector(openRecordings),
			keyEquivalent: "o")
		open.target = self
		menu.addItem(open)
		menu.addItem(.separator())
		menu.addItem(
			NSMenuItem(
				title: "Quit", action: #selector(NSApplication.terminate(_:)),
				keyEquivalent: "q"))
		statusItem.menu = menu
	}

	func update(state: DeviceState, identity: DeviceInfo?, lastGesture: String?) {
		if let button = statusItem.button {
			let image = NSImage(
				systemSymbolName: state.symbolName, accessibilityDescription: "TP-7")
			image?.isTemplate = true
			button.image = image
		}
		let deviceLine: String
		if let identity {
			let serial = identity.serialNumber ?? "unknown"
			let firmware = identity.deviceVersion.map { " · fw \($0)" } ?? ""
			deviceLine = "TP-7 \(serial)\(firmware)"
		} else {
			deviceLine = "TP-7"
		}
		deviceItem.title = "\(deviceLine) — \(state.label)"
		gestureItem.isHidden = lastGesture == nil
		if let lastGesture {
			gestureItem.title = "last gesture: \(lastGesture)"
		}
		let deviceAvailable = state == .recorder || state == .control
		ingestItem.isEnabled = deviceAvailable
		browseItem.isEnabled = deviceAvailable
	}

	@objc private func ingestNow() {
		onIngestNow()
	}

	@objc private func browseDevice() {
		onBrowseDevice()
	}

	@objc private func openRecordings() {
		NSWorkspace.shared.open(Paths.recordingsDir)
	}
}
