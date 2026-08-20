import Foundation

/// Physical controls in ctrl mode, keyed by their MIDI CC number.
enum TP7Button: UInt8 {
	case up = 20
	case down = 21
	case rec = 22
	case play = 23
	case stop = 24
	case minus = 25
	case plus = 26
	case memo = 27
	case mode = 28

	var label: String {
		switch self {
		case .up: "up"
		case .down: "down"
		case .rec: "rec"
		case .play: "play"
		case .stop: "stop"
		case .minus: "minus"
		case .plus: "plus"
		case .memo: "memo"
		case .mode: "mode"
		}
	}
}

enum Gesture: Sendable {
	case button(TP7Button, pressed: Bool)
	/// Signed relative delta from the tape wheel (CC 30, two's complement).
	case wheel(delta: Int)
	/// Rocker position, -8192...8191, zero at center.
	case rocker(value: Int)
}
