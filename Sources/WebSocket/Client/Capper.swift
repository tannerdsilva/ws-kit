import NIO
import Logging
import WebCore

extension Client {
	
	/// this is a client utility that enables the "frontend convenience client" for this library.
	/// this "capper" effectively "caps" data and events from the NIO pipeline and sends them to the frontend using native Swift async streams.
	internal final class Capper:ChannelInboundHandler {

		/// used to convey the current connection state of the channel the ``Capper`` is connected to.
		private enum ConnectionStage {
			/// the channel is not connected
			case notConnected
			/// the channel is connected
			case connected
			/// the channel closed with the following result
			case closed(Result<Void, Swift.Error>)
		}

		// nio stuff
		internal typealias InboundIn = Message.Inbound
		
		// main infrastructure stuff
		private let logger:Logger?
		private var eventLoop:EventLoop? = nil

		/// the closure expectation status for this capper.
		private var caughtError:Swift.Error? = nil
		private var closureHandler:((Result<Void, Swift.Error>) -> Void)? = nil

		// variables that are configured by the implementers of this class.
		/// handles text messages that are received from the remote peer.
		private let textStream:AsyncStream2<String>
		/// handles binary messages that are received from the remote peer.
		private let binaryStream:AsyncStream2<[UInt8]>
		/// handles latency measurements that are received from the remote peer.
		private let latencyStream:AsyncStream2<MeasuredLatency>

		internal init(log:Logger?, textStream:AsyncStream2<String>, binaryStream:AsyncStream2<[UInt8]>, latencyStream:AsyncStream2<MeasuredLatency>) {
			var modLogger = log
			if log != nil {
				modLogger![metadataKey:"type"] = "Client.Capper"
			}
			self.logger = modLogger
			self.textStream = textStream
			self.binaryStream = binaryStream
			self.latencyStream = latencyStream
		}

		/// **WARNING**: this function MUST be called on the same event loop that this handler is running on.
		internal func registerClosureHandler(_ closureHandler:@escaping(Result<Void, Swift.Error>) -> Void) {
			self.closureHandler = closureHandler
			self.logger?.trace("registered closure handler")
		}

		/// called when the handler is added to the pipeline.
		internal func handlerAdded(context:ChannelHandlerContext) {
			self.logger?.trace("handler added")
			self.eventLoop = context.eventLoop
			
			context.channel.closeFuture.whenComplete { _ in
				self.logger?.info("channel closed")
				switch self.caughtError {
					case .some(let error):
						self.logger?.error("channel closed with error", metadata:["error":"\(String(describing:error))"])
						self.closureHandler?(.failure(error))
					case .none:
						self.logger?.info("channel closed without error")
						self.closureHandler?(.success(()))
				}
			}
		}
		
		/// called when the handler is removed from the pipeline.
		internal func handlerRemoved(context:ChannelHandlerContext) {
			self.logger?.trace("handler removed")
			// handle each of the three async
			self.textStream.finish()
			self.binaryStream.finish()
			self.latencyStream.finish()
		}

		public func channelRead(context:ChannelHandlerContext, data:NIOAny) {
			let frame = self.unwrapInboundIn(data)
			switch frame {
				case .text(let text):
					self.logger?.debug("got text message", metadata:["byte_count":"\(text.count)"])
					self.textStream.yield(text)
				case .data(let data):
					self.logger?.debug("got binary message", metadata:["byte_count":"\(data.count)"])
					self.binaryStream.yield(data)
				case .unsolicitedPong(let sig):
					self.logger?.debug("got unsolicited pong from system", metadata:["signature":"\(sig)"])
					break;
				case .solicitedPong(let responseTime, let sig):
					self.logger?.debug("measured \(responseTime)s latency to remote peer", metadata:["signature":"\(sig)", "latency_type":"their_pong_rx"])
					self.latencyStream.yield(MeasuredLatency.remoteResponseTime(responseTime))
				case .ping(let future):
					self.logger?.debug("got ping from remote peer")
					future.whenSuccess { responseTime in
						self.logger?.info("measured \(responseTime)s latency to remote peer", metadata:["latency_type":"our_pong_tx"])
						self.latencyStream.yield(MeasuredLatency.ourWriteTime(responseTime))
					}
				case .gracefulDisconnect(_, _, let future):
					self.logger?.notice("got graceful disconnect from remote peer. initiating close")
					future.completeWith(.success(()));
			}
		}

		public func errorCaught(context:ChannelHandlerContext, error:Swift.Error) {
			self.logger?.critical("error caught in pipeline", metadata:["error":"\(String(describing:error))"])
			self.caughtError = error
			context.close(mode:.all, promise:nil)
		}
	}
}