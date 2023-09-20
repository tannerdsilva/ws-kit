import NIOHTTP1
import WebCore
import NIO
import NIOSSL

import Logging

import ServiceLifecycle

/// a websocket client.
public final actor Client:Sendable, Service {
	public struct InvalidState:Sendable, Swift.Error {}
	
	/// represents the various stages the client may be in 
	public enum State:Sendable, Equatable {
		
		/// the client is currently connecting to the remote peer.
		case connecting
		/// the client is connected to the remote peer.
		case connected(Channel)
		/// the client is currently disconnecting from the remote peer.
		case disconnecting
		/// the client is disconnected from the remote peer.
		case disconnected

		/// equality operator implementation.
		public static func == (lhs:Self, rhs:Self) -> Bool {
			switch (lhs, rhs) {
				case (.connecting, .connecting):
					return true
				case (.connected, .connected):
					return true
				case (.disconnecting, .disconnecting):
					return true
				case (.disconnected, .disconnected):
					return true
				default:
					return false
			}
		}
	}

	// immutable essentials.
	/// the URL that this client is connected to.
	public let url:URL

	/// the configuration for this client.
	public let configuration:Configuration
	
	/// the logger that this client will use to log messages.
	public let logger:Logger?
	public let eventLoop:EventLoop
	
	// using the structure.
	// - the various continuations that this client will use to send data to the user.
	/// the continuation that will be used to send text data to the user.
	public var textContinuation:AsyncStream<String>.Continuation? = nil
	/// the continuation that will be used to send binary data to the user.
	public var binaryContinuation:AsyncStream<[UInt8]>.Continuation? = nil
	/// the continuation that will be used to send latency data to the user (latency as measured by ping and pong messages)
	public var latencyContinuation:AsyncStream<MeasuredLatency>.Continuation? = nil
	/// the continuation that will be used to send connection stage data to the user.
	public var stateContinuation:AsyncStream<State>.Continuation? = nil

	/// the current state of this client.
	public internal(set) var currentState:State = .disconnected {
		// automatically yield the new stage value to the continuation.
		didSet {
			// i chose not to check if the new value is the same as the old value, because i do not want to add the overhead of a comparison to this code.
			if self.stateContinuation != nil {
				self.logger?.trace("yielding async connection stage: \(currentState)")
				self.stateContinuation!.yield(currentState)
			}
		}
	}

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
		
		// verify the state
		switch self.currentState {
			case .disconnected:
				break
			default:
				throw InvalidState()
		}

		// build the logger for this client.
		let useLogger:Logger
		switch self.logger {
			case .some(let logger):
				useLogger = logger
			case .none:
				useLogger = Logger(label:"ws-client")
		}

		// now at stage connecting
		self.currentState = .connecting

		defer {
			// when this function exits, the connection is disconnected. always.
			self.currentState = .disconnected
		}

		// first, we much connect to the remote peer.
		let (c, connectedClient) = try await Client.protoboot(log:useLogger, url:url, headers:[:], configuration:configuration, on:eventLoop, handlerBuilder: { logger, pipeline in
			// this is where we need to build the data pipeline for this network connection. the base interface here is the Message type.
			let makeCapper = Capper(log:logger)
			if self.textContinuation != nil {
				makeCapper.registerTextStreamContinuation(self.textContinuation!)
			}
			if self.binaryContinuation != nil {
				makeCapper.registerBinaryStreamContinuation(self.binaryContinuation!)
			}
			if self.latencyContinuation != nil {
				makeCapper.registerLatencyStreamContinuation(self.latencyContinuation!)
			}
			pipeline.append(makeCapper)
			return makeCapper
		})

		self.logger?.trace("successfully connected to remote peer")

		self.currentState = .connected(c)
		try await withUnsafeThrowingContinuation({ (connectionResult:UnsafeContinuation<Void, Swift.Error>) in
			connectedClient.registerClosureHandler({ result in
				connectionResult.resume(with: result)
			})
		})
	}

	public func initiateSafeClosure() async throws {
		guard case .connected(let channel) = self.currentState else {
			throw InvalidState()
		}
		try await channel.writeAndFlush(Message.Outbound.gracefulDisconnect(nil, nil)).get()
	}

	public func initiateImmediateClosure() async throws {
		guard case .connected(let channel) = self.currentState else {
			throw InvalidState()
		}
		try await channel.close(mode:.all).get()
	}

	public func writeBytes(_ bytes:[UInt8]) async throws {
		guard case .connected(let channel) = self.currentState else {
			throw InvalidState()
		}
		try await channel.writeAndFlush(Message.Outbound.data(bytes)).get()
	}

	public func writeText(_ text:String) async throws {
		guard case .connected(let channel) = self.currentState else {
			throw InvalidState()
		}
		try await channel.writeAndFlush(Message.Outbound.text(text)).get()
	}
}
