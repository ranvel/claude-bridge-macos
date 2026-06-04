// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "ClaudeBridge",
	platforms: [
		.macOS(.v13)
	],
	targets: [
		.executableTarget(
			name: "ClaudeBridge",
			path: "Sources/ClaudeBridge"
		)
	]
)
