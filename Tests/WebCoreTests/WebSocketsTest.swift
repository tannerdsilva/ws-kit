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
		// let newHeaders = HTTPHeaders([("Host", "\(newURL)")])
		let newConfiguration = Client.Configuration(timeouts:Client.Configuration.Timeouts(), limits:Client.Configuration.Limits(), tlsConfiguration: TLSConfiguration.makeClientConfiguration())
		let cap = Capper(log:newLogger)
		let newHandlers:[NIOCore.ChannelHandler] = [cap]
		let connect = try await Client.connect(log:newLogger, url:newURL, headers:[:], configuration:newConfiguration, on:newEventLoop, handlers:newHandlers).get()
	}
}