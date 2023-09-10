// (c) tanner silva 2023. all rights reserved.

import NIOCore
import NIOWebSocket
import Logging

import cweb
import WebCore

/// handles the merging of WebSocket frames into a single data type for the user
/// - abstracts ping/pong logic entirely.
/// - abstracts away the fragmentation of WebSocket frames
/// - abstracts away frame types. a default written frame type can be specified, however, all inbound data is treated the same (as a ByteBuffer)
internal final class Handler:ChannelDuplexHandler {
	/// how long is the randomly generated ping data?
	private static let pingDataSize:size_t = 4

	// io types for nio
	public typealias InboundIn = WebSocketFrame
	public typealias InboundOut = Frame
	public typealias OutboundIn = Frame
	public typealias OutboundOut = WebSocketFrame
	
	// ping/pong & health related variables and controls
	/// assigned to a given ByteBuffer when a ping is sent. when this the case, the contained data represents the data sent in the ping, and expected to be returned.
	private var waitingOnPong:ByteBuffer? = nil
	/// the task that is used to schedule the next ping. this also as a timeout handler. this should never be nil when the handler is added to the channel (although tasks may be cancelled)
	private var autoPingTask:Scheduled<Void>?
	
	// frame parsing mechanics
	private enum FrameParsingState {
		/// there is no existing frame fragments in the channel.
		case idle
		/// the channel contains existing frame sequence fragments that new data should append to.
		case existingFrameFragments(Frame.Partial)
		/// switches to this mode when the maximum frame size is exceeded and parsing should pause until a fin is received.
		case waitingForNextFrame
	}
	private var frameParsingMode:FrameParsingState = .idle
	
	/// the maximum number of bytes that are allowed to pass through the handler for a single data event.
	internal let maxMessageSize:size_t
	internal let maxFrameSize:size_t

	/// the amount of time this handler will wait for a pong response before closing the channel.
	internal let healthyConnectionTimeout:TimeAmount

	/// logger for this instance
	internal let logger:Logger

	/// initialize a new handler for use above a websocket channel handler
	internal init(log:Logger, surl:URL.Split, maxMessageSize:size_t, maxFrameSize:size_t, healthyConnectionThreshold:TimeAmount) {
		self.maxMessageSize = maxMessageSize
		self.maxFrameSize = maxFrameSize
		self.healthyConnectionTimeout = healthyConnectionThreshold
		var modLog = log
		modLog[metadataKey: "url"] = "\(surl.host)\(surl.pathQuery)"
		self.logger = modLog
	}

	/// initiates auto ping functionality on the connection. 
	private func initiateAutoPing(context:ChannelHandlerContext, interval:TimeAmount) {
		// cancel the existing task, if it exists.
		if self.autoPingTask != nil {
			self.logger.trace("cancelling previously scheduled ping.")
			self.autoPingTask!.cancel()
		}

		// schedule the next ping task
		self.autoPingTask = context.eventLoop.scheduleTask(in: interval) {
			if self.waitingOnPong != nil {
				self.logger.critical("did not receive pong from previous ping sent. closing channel...", metadata:["prev_ping_id": "\(Array(self.waitingOnPong!.readableBytesView.prefix(3)))"])
				// we never received a pong from our last ping, so the connection has timed out
				context.fireErrorCaught(Error.WebSocket.connectionTimeout)
			} else {
				self.sendPing(context: context).whenComplete {
					switch $0 {
						case .success():
							self.initiateAutoPing(context:context, interval: interval)
						case let .failure(err):
							self.logger.critical("failed to send ping: '\(err)'")
							_ = context.close()
					}
				}
			}
		}
		self.logger.debug("scheduled next ping to send in \(interval.nanoseconds / (1000 * 1000 * 1000))s.")
	}
	
	/// the only valid way to send a ping to the remote peer.
	private func sendPing(context:ChannelHandlerContext) -> EventLoopFuture<Void> {
		// define a new random byte sequence to use for this ping. this will define the "ping id"
		let rdat = (0..<Self.pingDataSize).map { _ in UInt8.random(in: 0...255) }
		
		// the new ping data should only be applied if the ping was successfully sent
		var newPingID = context.channel.allocator.buffer(capacity:Self.pingDataSize)
		newPingID.writeBytes(rdat)

		// create a new frame with a masking key to send.
		let maskingKey = WebSocketMaskingKey.random()
		let newFrame = WebSocketFrame(fin: true, opcode: .ping, maskKey:maskingKey, data:newPingID)

		// write it.
		let writeAndFlushFuture = context.writeAndFlush(wrapOutboundOut(newFrame))
		return writeAndFlushFuture.always { result in
			switch result {
			case .success:
				self.logger.info("sent ping.", metadata:["ping_id": "\(rdat.prefix(2))"])
				self.waitingOnPong = newPingID
				break;
			case .failure(let error):
				self.logger.error("failed to send ping: '\(error)'")
				break;
			}
		}
	}

	/// the only way to handle data frames from the remote peer. this function is only designed to support frames that are TEXT or BINARY based.
	/// - WARNING: this function will throw a fatal error and crash your program immediately if an invalid frame type is passed
	private func handleFrame(_ frame:InboundIn, context:ChannelHandlerContext) {
		switch self.frameParsingMode {
			// there are existing frame fragments in the channel.
			case .existingFrameFragments(var existingFrame):
				// verify that the current fragment matches the existing frame type.
				guard existingFrame.type.opcode() == frame.opcode else {
					self.logger.notice("received frame with opcode \(frame.opcode) but existing frame is of type \(existingFrame.type).")
					// throw an informative error based on the RFC 6455 violation.
					switch frame.fin {
						case false:
							context.fireErrorCaught(Error.WebSocket.rfc6455Violation(.fragmentControlViolation(.streamOpcodeMismatch(existingFrame.type.opcode(), frame.opcode))))
						case true:
							context.fireErrorCaught(Error.WebSocket.rfc6455Violation(.fragmentControlViolation(.initiationWithUnfinishedContext)))
					}
					return
				}
				// this is a valid continuation. so now, handle it apropriately.
				switch frame.fin {
					case true:
						// flush the data because the continued data stream has been finished
						existingFrame.append(frame)
						self.frameParsingMode = .idle
						let combinedResult = existingFrame.exportCombinedResult()
						context.fireChannelRead(self.wrapInboundOut(combinedResult))
						return
					case false:
						// append the data to the existing frame
						existingFrame.append(frame)
						guard existingFrame.size <= self.maxMessageSize else {
							self.logger.notice("frame sequence exceeded byte limit of \(self.maxMessageSize). waiting for next frame sequence before continuing.")
							self.frameParsingMode = .waitingForNextFrame
							return
						}
						self.frameParsingMode = .existingFrameFragments(existingFrame)
				}
				break;
			// this is the first frame in a (possible) sequence).
			case .idle:
				var newFrame = Frame.Partial(type:Frame.Partial.SequenceType(opcode:frame.opcode)!)
				newFrame.append(frame)

				guard newFrame.size <= self.maxMessageSize else {
					self.logger.notice("frame sequence exceeded byte limit of \(self.maxMessageSize). waiting for next frame sequence before continuing.")
					switch frame.fin {
						case true:
							self.frameParsingMode = .idle
						case false:
							self.frameParsingMode = .waitingForNextFrame
					}
					return
				}
				switch frame.fin {
					case true:
						let combinedResult = newFrame.exportCombinedResult()
						context.fireChannelRead(self.wrapInboundOut(combinedResult))
						return
					case false:
						self.frameParsingMode = .existingFrameFragments(newFrame)
				}
				break;
			// the maximum data length for this stream has been tripped
			case .waitingForNextFrame:
				switch frame.fin {
					case true:
						self.frameParsingMode = .idle
					case false:
						break;
				}
				break;
		}
	}

	internal func handlerAdded(context:ChannelHandlerContext) {
		self.logger.info("websocket connected.")
		self.waitingOnPong = nil
		self.sendPing(context:context).whenFailure { initialPingFailure in
			self.logger.critical("failed to send initial ping. closing channel.", metadata:["error": "\(initialPingFailure)"])
			context.fireErrorCaught(Error.WebSocket.failedToWriteInitialPing(initialPingFailure))
		}
		self.initiateAutoPing(context: context, interval:self.healthyConnectionTimeout)
	}

	internal func handlerRemoved(context:ChannelHandlerContext) {
		self.logger.info("websocket disconnected.")
		self.autoPingTask?.cancel()
		self.autoPingTask = nil
		self.waitingOnPong = nil
	}

	/// read hook
	internal func channelRead(context:ChannelHandlerContext, data:NIOAny) {
		// get the frame
		let frame:InboundIn = self.unwrapInboundIn(data)
				
		// handle the frame
		switch frame.opcode {

			// pong data. this is a control frame and is handled differently than a data frame.
			case .pong:
				guard frame.fin == true else {
					self.logger.critical("got fragmented pong frame.")
					context.fireErrorCaught(Error.WebSocket.rfc6455Violation(.fragmentControlViolation(.fragmentedPongReceived)))
					return
				}
				
				// this may or may not be an unsolicited pong. so the handling here is conditional based on greater context of the connection.
				switch waitingOnPong {
					case nil:
						// we were not waiting for a pong but we got one anyways. RFC 6455 allows for unsolicited pongs with no guidelines on body content.
						// in this case, we will (of course) support RFC 6455's possibility of unsolicited pongs. we will require that this pong be empty or less than 125 bytes.
						guard frame.data.readableBytes <= 125 else {
							self.logger.critical("received unsolicited pong with payload larger than 125 bytes.")
							context.fireErrorCaught(Error.WebSocket.RFC6455Violation.pongPayloadTooLong)
							return
						}
						
						self.logger.debug("got pong (unsolicited).")
						
						// unsolicited pongs will reset the internal timeout mechanism
						if self.autoPingTask != nil {
							self.initiateAutoPing(context:context, interval:self.healthyConnectionTimeout)
						}
					default:
						// this pong and its content is expected. verify that the content is correct.
						guard frame.data == self.waitingOnPong else {
							
							self.logger.critical("received solicited pong with unexpected body content.")
							
							context.fireErrorCaught(Error.WebSocket.RFC6455Violation.pongPayloadMismatch(Array(self.waitingOnPong!.readableBytesView), Array(frame.data.readableBytesView)))
							return
						}
						
						self.logger.debug("got pong (solicited).", metadata:["ping_id": "\(Array(frame.data.readableBytesView.prefix(2)))"])
						
						self.waitingOnPong = nil
				}

			// ping data. this is a control frame and is handled differently than a data frame.
			case .ping:
				guard frame.fin == true else {
					self.logger.critical("got fragmented ping frame.")
					context.fireErrorCaught(Error.WebSocket.rfc6455Violation(.fragmentControlViolation(.fragmentedPingReceived)))
					return
				}

				// generate new random data to send back
				let randBytes = (0..<Self.pingDataSize).map { _ in UInt8.random(in: 0...255) }
				var newPingData = context.channel.allocator.buffer(capacity: Self.pingDataSize)
				newPingData.writeBytes(randBytes)

				// create a new frame with the masking key
				let wsMask = WebSocketMaskingKey.random()
				let responsePong = WebSocketFrame(fin:true, opcode:.pong, maskKey:wsMask, data:frame.unmaskedData)

				// write it
				let writePromise = context.eventLoop.makePromise(of:Void.self)
				context.writeAndFlush(self.wrapOutboundOut(responsePong), promise:writePromise)

				// debug it
				let asArray = Array(frame.unmaskedData.readableBytesView)
				self.logger.debug("got ping.", metadata:["ping_id": "\(asArray.prefix(2))"])
				writePromise.futureResult.whenComplete({
					switch $0 {
					case .success:
						self.logger.debug("sent pong.", metadata:["ping_id": "\(asArray.prefix(2))"])
					case .failure(let error):
						self.logger.error("failed to send pong: '\(error)'", metadata:["ping_id": "\(asArray.prefix(2))"])
					}
				})
				

			// text or binary stream
			case .text:
				fallthrough;
			case .binary:
				self.handleFrame(frame, context:context)

			case .continuation:
				switch self.frameParsingMode {
					case .existingFrameFragments(var existingFrame):
						guard existingFrame.type.opcode() == frame.opcode else {
							self.logger.critical("received frame with opcode \(frame.opcode) but existing frame is of type \(existingFrame.type).")
							// throw an informative error based on the RFC 6455 violation.
							switch frame.fin {
								case false:
									context.fireErrorCaught(Error.WebSocket.rfc6455Violation(.fragmentControlViolation(.streamOpcodeMismatch(existingFrame.type.opcode(), frame.opcode))))
								case true:
									context.fireErrorCaught(Error.WebSocket.rfc6455Violation(.fragmentControlViolation(.initiationWithUnfinishedContext)))
							}
							return
						}
						existingFrame.append(frame)
						self.frameParsingMode = .existingFrameFragments(existingFrame)
					case .idle:
						self.logger.critical("got continuation frame, but there is no existing frame to append to.")
						context.fireErrorCaught(Error.WebSocket.rfc6455Violation(.fragmentControlViolation(.continuationWithoutContext)))
						return
					case .waitingForNextFrame:
					break;
				}

			case .connectionClose:
				context.channel.close(mode:.all, promise:nil)

		default:
			context.fireErrorCaught(Error.WebSocket.opcodeNotSupported(frame.opcode))
			break
		}
	}

	// write hook
	internal func write(context:ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
		// get the message and export it so that it can be assembled and written.
		let message = self.unwrapOutboundIn(data)
		var (mesBytes, op) = message.exportContent()

		/// validate the message size
		guard mesBytes.count <= self.maxMessageSize else {
			self.logger.warning("message size of \(mesBytes.count) exceeds byte limit of \(self.maxMessageSize).")
			promise?.fail(Error.WebSocket.messageTooLarge)
			return
		}
		while mesBytes.count > 0 {
			// get the next chunk
			let chunkSize = min(mesBytes.count, self.maxFrameSize)
			let chunk = mesBytes.prefix(chunkSize)
			mesBytes.removeFirst(chunkSize)
			
			// write the chunk to a new bytebuffer
			var chunkBuffer = context.channel.allocator.buffer(capacity: chunkSize)
			chunkBuffer.writeBytes(chunk)

			// create a new websocket frame with the chunk
			let isFin = mesBytes.count == 0
			let maskingKey = WebSocketMaskingKey.random()
			let frame = WebSocketFrame(fin:isFin, opcode:op, maskKey:maskingKey, data:chunkBuffer)
			if isFin == false {
				// write the frame without flushing. any failures will cascade to the promise.
				context.write(self.wrapOutboundOut(frame)).cascadeFailure(to:promise)
			} else {
				// this is the final frame. flush it and cascade the result to the promise.
				context.writeAndFlush(self.wrapOutboundOut(frame), promise:promise)
			}
		}
	}
}