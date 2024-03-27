import NIOHTTP1
import WebCore
import NIO
import NIOSSL

import Logging

import ServiceLifecycle

/// a websocket client.
public final actor Client:Sendable {
	/// thrown when the client is in an invalid state for the requested operation.
	public struct InvalidState:Sendable, Swift.Error {}
	
	/// represents the various stages the client may be in 
	public enum State:Sendable, Equatable {
		case initialized
		/// the client is currently connecting to the remote peer.
		case connecting
		/// the client is connected to the remote peer.
		case connected(Channel)
		/// the client is currently disconnecting from the remote peer.
		case disconnecting
		/// the client is disconnected from the remote peer.
		case terminated(Result<Void, Swift.Error>)

		/// equality operator implementation.
		public static func == (lhs:Self, rhs:Self) -> Bool {
			switch (lhs, rhs) {
				case (.connecting, .connecting):
					return true
				case (.connected, .connected):
					return true
				case (.disconnecting, .disconnecting):
					return true
				case (.terminated, .terminated):
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
	public let textStream:AsyncStream<String> = AsyncStream<String>()
	/// the continuation that will be used to send binary data to the user.
	public let binaryStream:AsyncStream<[UInt8]> = AsyncStream<[UInt8]>()
	/// the continuation that will be used to send latency data to the user (latency as measured by ping and pong messages)
	public let latencyStream:AsyncStream<MeasuredLatency> = AsyncStream<MeasuredLatency>()
	/// the continuation that will be used to send connection stage data to the user.
	public let stateStream:AsyncStream<State> = AsyncStream<State>()

	/// the current state of this client.
	fileprivate var disconnectionWaiters:[UnsafeContinuation<Void, Swift.Error>] = []

	fileprivate var currentState:State = .initialized {
		// automatically yield the new stage value to the continuation.
		didSet {
			self.stateStream.yield(currentState)
		}
	}
	fileprivate func disconnectionEvent(result:Result<Void, Swift.Error>) {
		// set the state as appropriate
		self.currentState = .terminated(result)
		// release each of the disconnection waiters
		for waiter in self.disconnectionWaiters {
			waiter.resume(with:result)
		}
		self.stateStream.finish()
		self.latencyStream.finish()
		self.binaryStream.finish()
		self.textStream.finish()
	}
	
	/// the work that must be done when the client successfully 

	/// initialize a new client instance.
	/// - parameter url: the URL to connect to.
	/// - parameter configuration: the configuration for this client.
	/// - parameter eventLoop: the event loop to use when running this client.
	/// - parameter logger: the logger to use when logging messages.
	public init(url:URL, configuration:Configuration, on eventLoop:EventLoop, log:Logger?) throws {
		self.url = url
		self.configuration = configuration
		self.eventLoop = eventLoop
		self.logger = log
	}

	/// establishes a connection to the configured websocket endpoint
	/// - NOTE: continuations registered after this method is called will not be used.
	public func connect() async throws {
		// verify the state
		switch self.currentState {
			case .initialized:
				break
			default:
				throw InvalidState()
		}

		// build the logger for this client
		let useLogger:Logger? = self.logger

		// now at stage connecting
		self.currentState = .connecting

		// first, we much connect to the remote peer
		let (c, _) = try await Client.protoboot(log:useLogger, url:url, headers:[:], configuration:configuration, on:eventLoop, handlerBuilder: { logger, pipeline in
			// this is where we need to build the data pipeline for this network connection. the base interface here is the Message type.
			let makeCapper = Capper(log:logger, textStream:self.textStream, binaryStream:self.binaryStream, latencyStream:self.latencyStream)
			makeCapper.registerClosureHandler({ closureResult in
				Task.detached {
					await self.disconnectionEvent(result:closureResult)
				}
			})
			pipeline.append(makeCapper)
			return makeCapper
		})
		self.currentState = .connected(c)
		self.logger?.trace("successfully connected to remote peer")
	}
	
	public func waitForClosure() async throws {
		switch self.currentState {
			case .connected:
				try await withUnsafeThrowingContinuation({ (continuation:UnsafeContinuation<Void, Swift.Error>) in
					self.disconnectionWaiters.append(continuation)
				})
			case .terminated(let result):
				try result.get()
			default:
				throw InvalidState()
		}
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

extension Client:Service {
	public func run() async throws {
		try await self.connect()
		try await self.waitForClosure()
	}
}