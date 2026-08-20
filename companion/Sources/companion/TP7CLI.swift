import Foundation

struct DeviceInfo: Decodable, Sendable {
	let product: String?
	let serialNumber: String?
	let mode: String
	let deviceVersion: String?

	enum CodingKeys: String, CodingKey {
		case product
		case serialNumber = "serial_number"
		case mode
		case deviceVersion = "device_version"
	}
}

/// Shells out to the patched tp7 CLI for device identity. MIDI presence is
/// the live signal; this fills in serial/firmware for the menu.
enum TP7CLI {
	static func devices() async -> [DeviceInfo] {
		let output = await Subprocess.run(["tp7", "-j", "devices"])
		guard let data = output?.data(using: .utf8),
			let devices = try? JSONDecoder().decode([DeviceInfo].self, from: data)
		else { return [] }
		return devices
	}
}
