import NIOHTTP1
import WebCore
import NIO
import NIOSSL

import Logging

import ServiceLifecycle


	/// a websocket client.
	public actor Client:Sendable, Service {

		/// the URL that this client is connected to.
		public var url:URL

		/// the configuration for this client.
		public var configuration:Configuration

		/// the event loop that this client is running on.
		public let eventLoop:EventLoop

		/// the logger for this client to use when logging messages.
		public let logger:Logger?

		/// initialize a new client instance.
		/// - parameter url: the URL to connect to.
		/// - parameter configuration: the configuration for this client.
		public init(url:URL, configuration:Client.Configuration, on eventLoop:EventLoop, logger:Logger?) throws {
			self.url = url
			self.configuration = configuration
			self.eventLoop = eventLoop
			self.logger = logger
		}

		public func run() async throws {

		}
	}

extension Client {
	internal static func bootstrap(url:URL.Split, headers:HTTPHeaders = [:], configuration:Client.Configuration, on eventLoop:EventLoop, logger:Logger?) throws -> NIOClientTCPBootstrap {
		let cb = ClientBootstrap(validatingGroup:eventLoop)
		if cb != nil {
			let bootstrap: NIOClientTCPBootstrap
			if url.tlsRequired {
				let sslContext = try NIOSSLContext(configuration:configuration.tlsConfiguration)
				let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context:sslContext, serverHostname:url.host)
				bootstrap = NIOClientTCPBootstrap(cb!, tls:tlsProvider)
				bootstrap.enableTLS()
			} else {
				bootstrap = NIOClientTCPBootstrap(cb!, tls:NIOInsecureNoTLS())
			}
			return bootstrap
		} else {
			preconditionFailure("failed to create client bootstrap")
		}
	}

	/// bootstrap a websocket connection	
	public static func setupChannelForWebSockets(log:Logger, splitURL:URL.Split, headers:HTTPHeaders, channel:Channel, wsPromise:EventLoopPromise<Void>, on eventLoop:EventLoop, wsUpgradeTimeout:TimeAmount, healthyTimeout:TimeAmount, maxMessageSize:size_t, maxFrameSize:size_t) -> EventLoopFuture<Void> {
		
		// this is the promise of the HTTP to WebSocket upgrade. if the connection upgrades, this succeeds. if it fails, the failure is passed.
		let upgradePromise = eventLoop.makePromise(of: Void.self)
		upgradePromise.futureResult.cascadeFailure(to:wsPromise)

		// light up the timeout task.
		let timeoutTask = channel.eventLoop.scheduleTask(in:wsUpgradeTimeout) {
			// the timeout task fired. fail the upgrade promise.
			upgradePromise.fail(Error.WebSocket.UpgradeError.upgradeTimedOut)
		}

		// create a random key for the upgrade request
		let requestKey = (0..<16).map { _ in UInt8.random(in: .min ..< .max) }
		let base64Key:String
		do {
			base64Key = try Base64.encode(bytes:requestKey)
		} catch let error {
			// the key could not be encoded. fail the upgrade promise.
			upgradePromise.fail(error)
			return channel.eventLoop.makeFailedFuture(error)
		}

		// build the initial request writer.
		let initialRequestWriter = InitialHTTPRequestWriter(log:log, url:splitURL, headers:headers, upgradePromise:upgradePromise)
		
		// build the websocket handler.
		let webSocketHandler = Handler(log:log, surl:splitURL, maxMessageSize:maxMessageSize, maxFrameSize:maxFrameSize, healthyConnectionThreshold:healthyTimeout)

		// build the websocket upgrader.
		let websocketUpgrader = HTTPToWebSocketUpgrader(log:log, surl:splitURL, requestKey:base64Key, maxWebSocketFrameSize:maxFrameSize, upgradePromise:upgradePromise, removeHandler:initialRequestWriter, handlers:[webSocketHandler])

		let config = NIOHTTPClientUpgradeConfiguration(upgraders:[websocketUpgrader], completionHandler: { context in
			timeoutTask.cancel()
		})

		// add the upgrade and initial request write handlers.
		return channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy:.forwardBytes, withClientUpgrade:config).flatMap {
			// the HTTP client handlers were added. now add the initial request writer.
			channel.pipeline.addHandler(initialRequestWriter)
		}
	}
}