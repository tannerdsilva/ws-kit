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
			try await withThrowingTaskGroup(of:Void.self) { group in
				group.addTask {
					try await newClient.run()
				}
				group.addTask {
					await Task.sleep(5 * 1000 * 1000 * 1000)
					try await newClient.initiateSafeClosure()
				}
				try await group.waitForAll()
			}
		} catch let error {
			caughtError = error
		}
		XCTAssertNil(caughtError)
	}
}