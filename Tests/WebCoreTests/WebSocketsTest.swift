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
		newLogger.logLevel = .trace
		let newURL = URL("wss://relay.damus.io")
		var caughtError:Swift.Error? = nil
		do {
			let newClient = try WebSocket.Client(url:newURL, configuration:WebSocket.Configuration(), on:newEventLoop, log:newLogger)
			try await newClient.connect()
			try await newClient.initiateSafeClosure()
			try await newClient.waitForClosure()
		} catch let error {
			caughtError = error
		}
		XCTAssertNil(caughtError)
	}

	func testServerConnect() async throws {
		
	}
}