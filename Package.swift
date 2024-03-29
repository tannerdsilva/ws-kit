// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "ws-kit",
	platforms: [
		.macOS(.v14),
	],
	products: [
		// Products define the executables and libraries a package produces, making them visible to other packages.
		.library(
			name: "WebCore",
			targets: ["WebCore"]),
		.library(
			name: "WebSocket",
			targets: ["WebSocket"]
		)
	],
	dependencies: [
		Package.Dependency.package(url:"https://github.com/apple/swift-nio.git", from:"2.58.0"),
		Package.Dependency.package(url:"https://github.com/apple/swift-nio-ssl.git", from:"2.25.0"),
		Package.Dependency.package(url:"https://github.com/apple/swift-log.git", from:"1.0.0"),
		Package.Dependency.package(url:"https://github.com/swift-server/swift-service-lifecycle.git", from:"2.0.0"),
		Package.Dependency.package(url:"https://github.com/tannerdsilva/rawdog.git", from:"6.2.10")
	],
	targets: [
		.target(name:"cweb"),
		.target(
			name: "WebCore",
			dependencies: [
				.product(name:"NIO", package:"swift-nio"),
				"cweb",
				.product(name:"NIOHTTP1", package:"swift-nio"),
			]
		),
		.target(
			name:"WebSocket",
			dependencies: [
				"WebCore",
				"cweb",
				.product(name:"NIOSSL", package:"swift-nio-ssl"),
				.product(name:"NIO", package:"swift-nio"),
				.product(name:"NIOWebSocket", package:"swift-nio"),
				.product(name:"Logging", package:"swift-log"),
				.product(name:"ServiceLifecycle", package:"swift-service-lifecycle"),
				.product(name:"RAW_base64", package:"rawdog")
			]
		),
		.testTarget(
			name:"WebCoreTests",
			dependencies:["WebSocket"]
		)

	]
)
