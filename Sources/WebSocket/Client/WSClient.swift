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
	public static func setupChannelForWebSocketClient(log:Logger, splitURL:URL.Split, handlers:[NIOCore.ChannelHandler], headers:HTTPHeaders, channel:Channel, wsPromise:EventLoopPromise<Void>, on eventLoop:EventLoop, wsUpgradeTimeout:TimeAmount, healthyTimeout:TimeAmount, maxMessageSize:size_t, maxFrameSize:size_t) -> EventLoopFuture<Void> {
		
		// light up the timeout task.
		let timeoutTask = channel.eventLoop.scheduleTask(in:wsUpgradeTimeout) {
			// the timeout task fired. fail the upgrade promise.
			wsPromise.fail(Error.WebSocket.UpgradeError.upgradeTimedOut)
		}

		// create a random key for the upgrade request
		let requestKey = (0..<16).map { _ in UInt8.random(in: .min ..< .max) }
		let base64Key:String
		do {
			base64Key = try Base64.encode(bytes:requestKey)
		} catch let error {
			// the key could not be encoded. fail the upgrade promise.
			wsPromise.fail(error)
			return channel.eventLoop.makeFailedFuture(error)
		}

		let requestEncoder = HTTPRequestEncoder()
        let responseDecoder = HTTPResponseDecoder(leftOverBytesStrategy:.forwardBytes)
		let initialRequestWriter = InitialHTTPRequestWriter(log:log, url:splitURL, headers:headers, upgradePromise:wsPromise)
        var hndlers: [RemovableChannelHandler] = [requestEncoder, ByteToMessageHandler(responseDecoder)]

		// build the websocket handler.
		let webSocketHandler = Handler(log:log, surl:splitURL, maxMessageSize:maxMessageSize, maxFrameSize:maxFrameSize, healthyConnectionThreshold:healthyTimeout)
		var buildHandlers:[NIOCore.ChannelHandler] = [webSocketHandler];
		buildHandlers.append(contentsOf:handlers)

		// build the websocket upgrader.
		let websocketUpgrader = HTTPToWebSocketUpgrader(log:log, surl:splitURL, requestKey:base64Key, maxWebSocketFrameSize:maxFrameSize, upgradePromise:wsPromise, handlers:buildHandlers)
		let newupg = NIOHTTPClientUpgradeHandler(upgraders:[websocketUpgrader], httpHandlers:hndlers, upgradeCompletionHandler: { context in
			timeoutTask.cancel()
		})

		// add the upgrade handler to the pipeline.
		hndlers.append(newupg)
		hndlers.append(initialRequestWriter)

		// add the upgrade and initial request write handlers.
		return channel.pipeline.addHandlers(hndlers)
	}

	public static func connect(log:Logger, url:URL, headers:HTTPHeaders = [:], configuration:Configuration, on eventLoop:EventLoop, handlers:[NIOCore.ChannelHandler]) -> EventLoopFuture<Void> {
		guard let splitURL = URL.Split(url:url) else {
			return eventLoop.makeFailedFuture(Error.invalidURL(url))
		}
		let promise = eventLoop.makePromise(of:Void.self)
		do {
			let bootstrap = try self.bootstrap(url:splitURL, headers:headers, configuration:configuration, on:eventLoop, logger:nil)
				.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value:1)
				.channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value:1)
				.channelInitializer({ channel in
					self.setupChannelForWebSocketClient(log:log, splitURL:splitURL, handlers:handlers, headers:headers, channel:channel, wsPromise:promise, on:eventLoop, wsUpgradeTimeout:configuration.timeouts.websocketUpgradeTimeout, healthyTimeout:configuration.timeouts.healthyConnectionTimeout, maxMessageSize:configuration.limits.maxMessageSize, maxFrameSize:configuration.limits.maxIndividualWebSocketFrameSize)
				})
				.connectTimeout(configuration.timeouts.tcpConnectionTimeout)
			bootstrap.connect(host:splitURL.host, port:Int(splitURL.port)).cascadeFailure(to:promise)
		} catch let error {
			promise.fail(error)
		}
		return promise.futureResult
	}
}

