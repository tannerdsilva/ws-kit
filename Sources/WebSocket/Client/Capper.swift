import NIO
import Logging

extension Client {
	
	/// this is a client utility that enables the "frontend convenience client" for this library.
	/// this "capper" effectively "caps" data and events from the NIO pipeline and sends them to the frontend using native Swift async streams.
	internal final class Capper:ChannelInboundHandler {
		internal enum ConnectionResult {
			case expected
			case failureOccurred(Swift.Error)
			case unexpected
		}

		// nio stuff
		internal typealias InboundIn = Message.Inbound
		
		// main infrastructure stuff
		private let logger:Logger?
		internal let channel:Channel

		/// the closure expectation status for this capper.
		private var currentExpectation:ConnectionResult = .unexpected
		private var closureHandler:((ConnectionResult) -> Void)? = nil

		// variables that are configured by the implementers of this class.
		/// handles text messages that are received from the remote peer.
		private var textStream:AsyncStream<String>.Continuation? = nil
		/// handles binary messages that are received from the remote peer.
		private var binaryStream:AsyncStream<[UInt8]>.Continuation? = nil
		/// handles latency measurements that are received from the remote peer.
		private var latencyStream:AsyncStream<MeasuredLatency>.Continuation? = nil

		internal init(log:Logger?, channel:Channel) {
			var modLogger = log
			if log != nil {
				modLogger![metadataKey:"ctx"] = "capper"
			}
			self.logger = modLogger
			self.channel = channel
		}

		@discardableResult internal func registerClosureHandler(_ closureHandler:@escaping (ConnectionResult) -> Void) -> EventLoopFuture<Void> {
			let subFuture = channel.eventLoop.submit({
				self.logger?.trace("registered closure handler")
				self.closureHandler = closureHandler
			})
			subFuture.whenComplete { result in
				switch result {
					case .success(_):
						self.logger?.trace("successfully registered closure handler")
					case .failure(let error):
						self.logger?.error("failed to register closure handler", metadata:["error":"\(error.localizedDescription)"])
				}
			}
			return subFuture
		}

		/// allows a user of this class to register the text stream continuation that will be used to handle text messages.
		@discardableResult internal func registerTextStreamContinuation(_ textStream:AsyncStream<String>.Continuation) -> EventLoopFuture<Void> {
			let subFuture = channel.eventLoop.submit({
				self.logger?.trace("registered text stream")
				self.textStream = textStream
			})
			subFuture.whenComplete { result in
				switch result {
					case .success(_):
						self.logger?.trace("successfully registered text stream")
					case .failure(let error):
						self.logger?.error("failed to register text stream", metadata:["error":"\(error.localizedDescription)"])
				}
			}
			return subFuture
		}

		@discardableResult internal func registerBinaryStreamContinuation(_ binaryStream:AsyncStream<[UInt8]>.Continuation) -> EventLoopFuture<Void> {
			let subFuture = channel.eventLoop.submit({
				self.logger?.trace("registered binary stream")
				self.binaryStream = binaryStream
			})
			subFuture.whenComplete {
				switch $0 {
					case .success(_):
						self.logger?.trace("successfully registered binary stream")
					case .failure(let error):
						self.logger?.error("failed to register binary stream", metadata:["error":"\(error.localizedDescription)"])
				}
			}
			return subFuture
		}

		@discardableResult internal func registerLatencyStreamContinuation(_ latencyStream:AsyncStream<MeasuredLatency>.Continuation) -> EventLoopFuture<Void> {
			let subFuture = channel.eventLoop.submit({
				self.logger?.trace("registered latency stream")
				self.latencyStream = latencyStream
			})
			subFuture.whenComplete {
				switch $0 {
					case .success(_):
						self.logger?.trace("successfully registered latency stream")
					case .failure(let error):
						self.logger?.error("failed to register latency stream", metadata:["error":"\(error.localizedDescription)"])
				}
			}
			return subFuture
		}
		
		internal func handlerAdded(context:ChannelHandlerContext) {
			self.logger?.trace("handler added")
			context.channel.closeFuture.whenComplete { result in
				switch result {
					case .success(_):
						self.logger?.info("channel closed.")
						self.closureHandler?(self.currentExpectation)
					case .failure(let error):
						self.logger?.critical("channel closed with error. this should never happen.", metadata:["error":"\(error.localizedDescription)"])
				}
			}
		}

		internal func handlerRemoved(context:ChannelHandlerContext) {
			self.logger?.trace("handler removed")
			if textStream != nil {
				self.logger?.trace("finishing registered text stream")
				textStream!.finish()
			}
			if binaryStream != nil {
				self.logger?.trace("finishing registered binary stream")
				binaryStream!.finish()
			}
			if latencyStream != nil {
				self.logger?.trace("finishing registered latency stream")
				latencyStream!.finish()
			}
			textStream = nil
			binaryStream = nil
			latencyStream = nil
		}

		public func channelRead(context:ChannelHandlerContext, data:NIOAny) {
			let frame = self.unwrapInboundIn(data)
			switch frame {
				case .text(let text):
					self.logger?.debug("got text message: \(text.count) bytes")
					if textStream != nil {
						self.logger?.trace("yielding text message to registered stream")
						self.textStream!.yield(text)
					} else {
						self.logger?.warning("no registered text stream, dropping message")
					}
				case .data(let data):
					self.logger?.debug("got binary message: \(data.count) bytes")
					if binaryStream != nil {
						self.logger?.trace("yielding binary message to registered stream")
						self.binaryStream!.yield(data)
					} else {
						self.logger?.warning("no registered binary stream, dropping message")
					}
				case .unsolicitedPong(let sig):
					self.logger?.info("got unsolicited pong from system", metadata:["signature":"\(sig)"])
					break;
				case .solicitedPong(let responseTime, let sig):
					self.logger?.info("measured \(responseTime)s latency to remote peer.", metadata:["signature":"\(sig)", "latency_type":"their_pong_rx"])
					if latencyStream != nil {
						self.logger?.trace("yielding latency measurement to registered stream")
						self.latencyStream!.yield(MeasuredLatency.remoteResponseTime(responseTime))
					} else {
						self.logger?.trace("no registered latency stream, dropping measurement")
					}
				case .ping(let future):
					self.logger?.debug("got ping from remote peer.")
					future.whenSuccess { responseTime in
						self.logger?.info("measured \(responseTime)s latency to remote peer.", metadata:["latency_type":"our_pong_tx"])
						if self.latencyStream != nil {
							self.logger?.trace("yielding latency measurement to registered stream")
							self.latencyStream!.yield(MeasuredLatency.ourWriteTime(responseTime))
						} else {
							self.logger?.trace("no registered latency stream, dropping measurement")
						}
					}
				case .gracefulDisconnect(let code, let reason, let future):
					self.logger?.notice("got graceful disconnect from system. initiating close.")
					self.currentExpectation = .expected
					channel.writeAndFlush(Message.Outbound.gracefulDisconnect(code, reason), promise:nil)
			}
		}

		public func initiateClosure() -> EventLoopFuture<Void> {
			self.logger?.trace("closing connection")
			self.currentExpectation = .expected
			return channel.writeAndFlush(Message.Outbound.gracefulDisconnect(nil, nil))
		}

		public func errorCaught(context:ChannelHandlerContext, error:Error) {
			self.logger?.critical("error caught in pipeline", metadata:["error":"\(error.localizedDescription)"])
			self.currentExpectation = .failureOccurred(error)
			context.close(mode:.all, promise:nil)
		}
	}
}