// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "companion",
	platforms: [.macOS(.v15)],
	targets: [
		.executableTarget(name: "companion", path: "Sources/companion")
	]
)
