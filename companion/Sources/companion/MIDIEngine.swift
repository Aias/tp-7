import CoreMIDI
import Foundation

enum MIDIEvent: Sendable {
	/// Fired whenever the set of TP-7 MIDI sources changes.
	case presenceChanged(present: Bool, sourceNames: [String])
	case gesture(Gesture)
}

/// Owns the CoreMIDI client: watches for TP-7 sources (USB "TP-7" or
/// "TP-7 Bluetooth"), connects an input port to them, and parses ctrl-mode
/// gesture events out of the MIDI 1.0 UMP stream.
final class MIDIEngine: @unchecked Sendable {
	private var client = MIDIClientRef()
	private var inputPort = MIDIPortRef()
	private var connectedSources: Set<MIDIEndpointRef> = []
	private let onEvent: @Sendable (MIDIEvent) -> Void

	init(onEvent: @escaping @Sendable (MIDIEvent) -> Void) {
		self.onEvent = onEvent
	}

	/// Must run on the main thread: CoreMIDI delivers setup-change
	/// notifications via the runloop current at client-creation time, and a
	/// GCD worker thread has none — notifications would silently never fire.
	func start() {
		DispatchQueue.main.async { self.setUp() }
	}

	private func setUp() {
		MIDIClientCreateWithBlock("tp7companion" as CFString, &client) { [weak self] _ in
			// Any setup change (device added/removed, mode re-enumeration)
			// triggers a rescan; connecting is idempotent.
			guard let self else { return }
			DispatchQueue.main.async { self.rescanSources() }
		}
		MIDIInputPortCreateWithProtocol(
			client, "tp7companion-in" as CFString, ._1_0, &inputPort
		) { [weak self] eventList, _ in
			guard let self else { return }
			let gestures = Self.parseGestures(eventList)
			for gesture in gestures {
				self.onEvent(.gesture(gesture))
			}
		}
		rescanSources()
	}

	private func rescanSources() {
		var current: Set<MIDIEndpointRef> = []
		var names: [String] = []
		for index in 0..<MIDIGetNumberOfSources() {
			let source = MIDIGetSource(index)
			guard let name = displayName(of: source), name.hasPrefix("TP-7") else { continue }
			current.insert(source)
			names.append(name)
		}
		for source in current.subtracting(connectedSources) {
			MIDIPortConnectSource(inputPort, source, nil)
		}
		for source in connectedSources.subtracting(current) {
			MIDIPortDisconnectSource(inputPort, source)
		}
		let changed = current != connectedSources
		connectedSources = current
		if changed {
			onEvent(.presenceChanged(present: !current.isEmpty, sourceNames: names))
		}
	}

	private func displayName(of endpoint: MIDIEndpointRef) -> String? {
		var name: Unmanaged<CFString>?
		guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr
		else { return nil }
		return name?.takeRetainedValue() as String?
	}

	/// Parses MIDI 1.0 channel-voice messages out of a UMP event list.
	/// Word layout: mt(4) group(4) status(4) channel(4) data1(8) data2(8).
	private static func parseGestures(
		_ eventList: UnsafePointer<MIDIEventList>
	) -> [Gesture] {
		var gestures: [Gesture] = []
		for packet in eventList.unsafeSequence() {
			for word in packet.words() {
				guard word >> 28 == 0x2 else { continue }
				let status = UInt8((word >> 20) & 0xF)
				let data1 = UInt8((word >> 8) & 0x7F)
				let data2 = UInt8(word & 0x7F)
				switch status {
				case 0xB where data1 == 30:
					// Relative two's-complement wheel delta; 0 is a no-op.
					let delta = data2 < 64 ? Int(data2) : Int(data2) - 128
					if delta != 0 {
						gestures.append(.wheel(delta: delta))
					}
				case 0xB:
					if let button = TP7Button(rawValue: data1) {
						gestures.append(.button(button, pressed: data2 >= 64))
					}
				case 0xE:
					let value = (Int(data2) << 7 | Int(data1)) - 8192
					gestures.append(.rocker(value: value))
				default:
					break
				}
			}
		}
		return gestures
	}
}
