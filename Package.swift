// swift-tools-version: 5.9

import PackageDescription

let package = Package(
	name: "ws-kit",
	platforms: [
		.macOS(.v14),
	],
	products: [
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
		Package.Dependency.package(url:"https://github.com/swift-server/swift-service-lifecycle.git", from:"2.0.0")
	],
	targets: [
		.target(
			name:"cweb",
			exclude:[],
			publicHeadersPath:".",
			cSettings:[],
			cxxSettings:[],
			linkerSettings:[]
		),
		.target(
			name: "WebCore",
			dependencies: [
				.product(name:"NIO", package:"swift-nio"),
				"cweb",
				.product(name:"NIOHTTP1", package:"swift-nio"),
			]
		),
		.target(
			name:"Base64",
			dependencies:[
				"cweb"
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
				"Base64"
			]
		),
		.testTarget(
			name:"WebCoreTests",
			dependencies:["WebSocket", "WebCore"]
		)

	]
)
