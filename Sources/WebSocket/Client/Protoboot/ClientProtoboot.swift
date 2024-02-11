import NIO
import NIOSSL
import NIOHTTP1
import WebCore
import Logging
import RAW_base64

extension Client {

	/// builds a basic client bootstrapper for the given URL and configuration.
	/// - parameter url: the ``URL.Split`` to connect to.
	/// - parameter configuration: the configuration for this client.
	/// - parameter eventLoop: the event loop to use when creating the bootstrap.
	internal static func bootstrap(url:URL.Split, configuration:Configuration, eventLoop:EventLoop) throws -> NIOClientTCPBootstrap {
		
		// this is the client bootstrapper
		let cb = ClientBootstrap(validatingGroup:eventLoop)
		guard cb != nil else {
			preconditionFailure("failed to create client bootstrap")
		}
		
		// the only thing that we need to do is enable TLS if the URL requires it.
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
	}

	/// bootstrap a websocket connection to the given URL.
	/// - parameter log: the logger to use when logging messages.
	/// - parameter url: the URL to connect to.
	/// - parameter handlers: the NIO channel handlers to add to the pipeline after the websocket upgrade is complete.
	/// - parameter headers: the headers to send with the initial HTTP request.
	/// - parameter channel: the channel to add the handlers to.
	/// - parameter upgradePromise: the promise that will be fulfilled when the upgrade is complete.
	/// - parameter eventLoop: the event loop to use when adding handlers to the pipeline.
	/// - parameter wsUpgradeTimeout: the amount of time to wait for the websocket upgrade to complete before failing the upgrade promise.
	/// - parameter healthyTimeout: the amount of time to wait for a healthy connection before closing the connection as "failed"
	/// - parameter maxMessageSize: the maximum size of a websocket message in bytes.
	/// - parameter maxFrameSize: the maximum size of a websocket frame in bytes.
	/// - returns: a future that will be fulfilled when the websocket upgrade infrastructure is fully configured and ready to go.
	internal static func setupChannel(log:Logger?, splitURL:URL.Split, handlers:[NIOCore.ChannelHandler], headers:HTTPHeaders, channel:Channel, upgradePromise:EventLoopPromise<Void>, on eventLoop:EventLoop, wsUpgradeTimeout:TimeAmount, healthyTimeout:TimeAmount, maxMessageSize:size_t, maxFrameSize:size_t) -> EventLoopFuture<Void> {
		// light up the timeout task.
		let timeoutTask = channel.eventLoop.scheduleTask(in:wsUpgradeTimeout) {
			// the timeout task fired. fail the upgrade promise.
			upgradePromise.fail(Error.connectionTimeout)
		}

		// create a random key for the upgrade request. base64 encode the random bytes.
		let requestKey = (0..<16).map { _ in UInt8.random(in: .min ..< .max) }
		let base64Key:String = String(RAW_base64.encode(requestKey))

		// bootstrap http handlers from scratch.
		let requestEncoder = HTTPRequestEncoder()
		let responseDecoder = HTTPResponseDecoder(leftOverBytesStrategy:.forwardBytes)

		let initialRequestWriter = InitialHTTPRequestWriter(log:log, url:splitURL, headers:headers, upgradePromise:upgradePromise)
		var hndlers:[RemovableChannelHandler] = [requestEncoder, ByteToMessageHandler(responseDecoder)]

		// build the websocket handlers that will be added after the protocol upgrade is completed.
		let webSocketHandler = Handler(log:log, maxMessageSize:maxMessageSize, maxFrameSize:maxFrameSize, healthyConnectionThreshold:healthyTimeout)
		var buildHandlers:[NIOCore.ChannelHandler] = [webSocketHandler];
		buildHandlers.append(contentsOf:handlers)

		// build the websocket upgrader.
		let websocketUpgrader = Upgrader(log:log, surl:splitURL, requestKey:base64Key, maxWebSocketFrameSize:maxFrameSize, upgradePromise:upgradePromise, handlers:buildHandlers)
		let newupg = NIOHTTPClientUpgradeHandler(upgraders:[websocketUpgrader], httpHandlers:hndlers, upgradeCompletionHandler: { context in
			timeoutTask.cancel()
		})

		// add the upgrade handler to the pipeline.
		hndlers.append(newupg)
		hndlers.append(initialRequestWriter)

		// add the upgrade and initial request write handlers.
		return channel.pipeline.addHandlers(hndlers)
	}

	/// bootstrap the protocol pipeline as a websocket client. connects to the specified URL with the specified configuration, and then allows the caller to build an additional pipeline and claim the return type.
	public static func protoboot<R>(log logIn:Logger?, url:URL, headers:HTTPHeaders, configuration:Configuration, on eventLoop:EventLoop, handlerBuilder buildHandlersFunc:@escaping((Logger?, inout [NIOCore.ChannelHandler]) -> R)) async throws -> (Channel, R) {
		// mutate the logger and burn a new metadata item to it.
		var modLogger = logIn
		modLogger?[metadataKey:"url"] = "\(url)"
		let log = modLogger

		// parse the url.
		let splitURL = try URL.Split(url:url)

		// this is the return type promise. it is essentially just like the upgrade promise (which fufills when the pipeline is fully upgraded and configured), but it also contains the return type/instance that the user wants.
		let returnTypePromise = eventLoop.makePromise(of:R.self)

		// this is the promise that will be fulfilled when the upgrade to websockets is complete and the full pipeline is ready.
		let upgradePromise = eventLoop.makePromise(of:Void.self)
		upgradePromise.futureResult.cascadeFailure(to:returnTypePromise)
		
		// build the bootstrap.
		let bootstrap = try Self.bootstrap(url:splitURL, configuration:configuration, eventLoop:eventLoop)
			.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value:1)
			.channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value:1)
			.channelInitializer({ channel in

				modLogger?.debug("beginning channel pipeline initialization", metadata:["ctx":"protoboot"])

				// allow the caller to build their pipeline and claim the return type.
				var buildPipeline = [NIOCore.ChannelHandler]()
				let retResult = buildHandlersFunc(log, &buildPipeline)

				// briefly augment the upgrade promise with the return promise that will contain the elements that the user wants.
				upgradePromise.futureResult.whenSuccess({ [ml = modLogger, rInstPass = retResult] in
					ml?.debug("websocket upgrade complete. yielding return type from pipeline initializer", metadata:["ctx":"protoboot"])
					returnTypePromise.succeed(rInstPass)
				})

				// return the channel pipeline.
				return Client.setupChannel(log:log, splitURL:splitURL, handlers:buildPipeline, headers:headers, channel:channel, upgradePromise:upgradePromise, on:eventLoop, wsUpgradeTimeout:configuration.timeouts.websocketUpgradeTimeout, healthyTimeout:configuration.timeouts.healthyConnectionTimeout, maxMessageSize:configuration.limits.maxMessageSize, maxFrameSize:configuration.limits.maxIndividualWebSocketFrameSize)
			})
			.connectTimeout(configuration.timeouts.tcpConnectionTimeout)

		// connect.
		log?.trace("attempting to establish tcp connection...", metadata:["ctx":"protoboot"])
		let connectionFuture = try await bootstrap.connect(host:splitURL.host, port:Int(splitURL.port)).get()
		log?.debug("tcp connection established")

		// launch the async task to acquire the return type. this should be completed when the websocket upgrade is complete.
		return (connectionFuture, try await withTaskCancellationHandler(operation: {
			return try await withUnsafeThrowingContinuation({ (myContinuation:UnsafeContinuation<R, Swift.Error>) in 
				returnTypePromise.futureResult.whenComplete({ result in
					switch result {
						case .success(let rInst):
							myContinuation.resume(returning:(rInst))
						case .failure(let error):
							myContinuation.resume(throwing:error)
					}
				})
				log?.trace("successfully synchronized swift continuation with return type promise", metadata:["ctx":"protoboot"])
			})
		}, onCancel: {
			// the task was cancelled. fail the upgrade promise.
			upgradePromise.fail(CancellationError())
		}))
	}
}