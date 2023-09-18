import NIOHTTP1
import WebCore
import NIO
import NIOSSL

import Logging

import ServiceLifecycle

	/// a websocket client.
	public final actor Client:Sendable, Service {
		
		// immutable essentials.
		/// the URL that this client is connected to.
		public let url:URL
		/// the event loop that this client is running on.
		public let eventLoop:EventLoop

		/// the configuration for this client.
		public let configuration:Configuration
		
		/// the logger that this client will use to log messages.
		public let logger:Logger?
		
		// using the structure.
		// - the various continuations that this client will use to send data to the user.
		/// the continuation that will be used to send text data to the user.
		public var textContinuation:AsyncStream<String>.Continuation? = nil
		/// the continuation that will be used to send binary data to the user.
		public var binaryContinuation:AsyncStream<[UInt8]>.Continuation? = nil
		/// the continuation that will be used to send latency data to the user (latency as measured by ping and pong messages)
		public var latencyContinuation:AsyncStream<MeasuredLatency>.Continuation? = nil

		/// initialize a new client instance.
		/// - parameter url: the URL to connect to.
		/// - parameter configuration: the configuration for this client.
		/// - parameter eventLoop: the event loop to use when running this client.
		/// - parameter logger: the logger to use when logging messages.
		public init(url:URL, configuration:Client.Configuration, on eventLoop:EventLoop, log:Logger?) throws {
			self.url = url
			self.configuration = configuration
			self.eventLoop = eventLoop
			self.logger = log
		}

		/// runs the client websocket service. includes integrated healthchecking, data handling, graceful shutdown, etc.
		/// this client will immediately read the continuation variables and start sending data to them.
		/// - NOTE: continuations registered after this method is called will not be used.
		public func run() async throws {
			let useLogger:Logger
			switch self.logger {
				case .some(let logger):
					useLogger = logger
				case .none:
					useLogger = Logger(label:"ws-client")
			}

			// first, we much connect to the remote peer.
			let connectedClient = try await Client.protoboot(log:useLogger, url:url, headers:[:], configuration:configuration, on:eventLoop, handlerBuilder: { channel, logger, pipeline in
				let makeCapper = Capper(log:logger, channel:channel)
				if self.textContinuation != nil {
					makeCapper.registerTextStreamContinuation(self.textContinuation!)
				}
				if self.binaryContinuation != nil {
					makeCapper.registerBinaryStreamContinuation(self.binaryContinuation!)
				}
				if self.latencyContinuation != nil {
					makeCapper.registerLatencyStreamContinuation(self.latencyContinuation!)
				}
				makeCapper.registerClosureHandler({ closer in
					switch closer {
						case .expected:
							useLogger.info("connection closed gracefully")
						case .unexpected:
							useLogger.info("connection closed unexpectedly")
						case .failureOccurred(let error):
							useLogger.error("connection closed due to error: \(error)")
					}
				})
				// this is where we need to build the data pipeline for this network connection. the base interface here is the Message type.
				pipeline.append(makeCapper)
				return makeCapper
			})

			let result = try await withUnsafeThrowingContinuation { (exitCont:UnsafeContinuation<Capper.ConnectionResult, Swift.Error>) in
				connectedClient.registerClosureHandler({ closureResult in
					switch closureResult {
						case .expected:
							exitCont.resume(returning:.expected)
						case .unexpected:
							exitCont.resume(returning:.unexpected)
						case .failureOccurred(let error):
							exitCont.resume(throwing:error)
					}
				})
			}
			
			self.logger?.info("connection closed with result: \(result)")
		}
	}
