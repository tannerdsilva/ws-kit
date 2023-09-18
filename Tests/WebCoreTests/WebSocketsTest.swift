import XCTest
@testable import WebSocket
import NIO
import Logging
import NIOHTTP1
import NIOSSL
import WebCore

final class WebSocketClientTests:XCTestCase {
	func testClientConnect() async throws {
		let newLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads:1)
		let newEventLoop = newLoopGroup.next()
		var newLogger = Logger(label:"test")
		newLogger.logLevel = .info
		let newURL = URL("wss://relay.damus.io")
		let newClient = try WebSocket.Client(url:newURL, configuration:WebSocket.Client.Configuration(), on:newEventLoop, log:newLogger)
		try await newClient.run()
	}
}