// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ws-kit",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ws-kit",
            targets: ["WebCore"]),
    ],
	dependencies: [
		Package.Dependency.package(url:"https://github.com/apple/swift-nio.git", from:"2.57.0"),
		Package.Dependency.package(url:"https://github.com/apple/swift-nio-ssl.git", from:"2.24.0"),
		Package.Dependency.package(url:"https://github.com/apple/swift-log.git", from:"1.0.0"),
		Package.Dependency.package(url:"https://github.com/apple/swift-crypto.git", from:"2.5.0"),
	],
    targets: [
		.target(name:"cweb"),
		.target(
			name: "WebCore",
			dependencies: [
				.product(name:"NIOSSL", package:"swift-nio-ssl"),
				.product(name:"NIO", package:"swift-nio"),
				.product(name:"NIOWebSocket", package:"swift-nio"),
				.product(name:"Logging", package:"swift-log"),
				.product(name:"Crypto", package:"swift-crypto"),
				"cweb",
			]),
		.target(name:"WebSocketCore", dependencies:["WebCore"])

    ]
)
