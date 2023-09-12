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
	public typealias InboundOut = Message.Inbound
	public typealias OutboundIn = Message.Outbound
	public typealias OutboundOut = WebSocketFrame
	
	// ping/pong & health related variables and controls
	/// assigned to a given ByteBuffer when a ping is sent. when this the case, the contained data represents the data sent in the ping, and expected to be returned.
	private var waitingOnPong:[UInt8]? = nil
	/// the task that is used to schedule the next ping. this also as a timeout handler. this should never be nil when the handler is added to the channel (although tasks may be cancelled)
	private var autoPingTask:Scheduled<Void>?
	
	// frame parsing mechanics
	private enum FrameParsingState {
		/// there is no existing frame fragments in the channel.
		case idle
		/// the channel contains existing frame sequence fragments that new data should append to.
		case existingFrameFragments(Message)
		/// switches to this mode when the maximum frame size is exceeded and parsing should pause until a fin is received.
		case waitingForNextFrame
	}
	private var frameParsingMode:FrameParsingState = .idle

	/// used to track the dates that pings were sent. this is used to calculate the round trip time of a ping.
	private var pingDates:[[UInt8]:WebCore.Date]
	/// used to track the promises that are waiting on a pong response. this is used to fulfill the promise when the pong is received.
	private var pongPromises:[[UInt8]:EventLoopPromise<Double>]
	
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
		self.pingDates = [:]
		self.pongPromises = [:]
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
				self.logger.critical("did not receive pong from previous ping sent. closing channel...", metadata:["prev_ping_id": "\(self.waitingOnPong.hashValue))"])
				// we never received a pong from our last ping, so the connection has timed out
				context.fireErrorCaught(Error.WebSocket.connectionTimeout)
			} else {
				self.sendPing(context:context, pongPromise:nil).whenFailure { err in
					self.logger.critical("failed to send ping: '\(err)'")
					_ = context.close()
				}
				self.initiateAutoPing(context:context, interval: interval)
			}
		}
		self.logger.debug("scheduled next ping to send in \(interval.nanoseconds / (1000 * 1000 * 1000))s.")
	}

	private func sendUnsolicitedPong(context:ChannelHandlerContext) -> EventLoopFuture<Void> {
		// define a new random byte sequence to use for this ping. this will define the "ping id"
		let rdat = (0..<Self.pingDataSize).map { _ in UInt8.random(in: 0...255) }
		
		// the new ping data should only be applied if the ping was successfully sent
		var newPingID = context.channel.allocator.buffer(capacity:Self.pingDataSize)
		newPingID.writeBytes(rdat)

		// create a new frame with the masking key
		let wsMask = WebSocketMaskingKey.random()
		let responsePong = WebSocketFrame(fin:true, opcode:.pong, maskKey:wsMask, data:newPingID)

		// write it
		let writePromise = context.eventLoop.makePromise(of:Void.self)
		context.writeAndFlush(self.wrapOutboundOut(responsePong), promise:writePromise)

		// debug it
		writePromise.futureResult.whenComplete({
			switch $0 {
			case .success:
				self.logger.debug("sent pong.", metadata:["pong_id": "\(rdat.hashValue)"])
			case .failure(let error):
				self.logger.error("failed to send pong: '\(error)'", metadata:["pong_id": "\(rdat.hashValue)"])
			}
		})
		return writePromise.futureResult
	}
	
	/// the only valid way to send a ping to the remote peer.
	private func sendPing(context:ChannelHandlerContext, pongPromise:EventLoopPromise<Double>?) -> EventLoopFuture<Void> {
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
				if (self.waitingOnPong == nil) {
					self.logger.trace("upcoming ping will be used to evaluate connection health.", metadata:["ping_id":"\(rdat.hashValue)"])
					self.waitingOnPong = rdat
				}
				let newDate = WebCore.Date(localTime:false)
				self.pingDates[rdat] = newDate
				if pongPromise != nil {
					self.pongPromises[rdat] = pongPromise!
				}
				self.logger.info("sent ping.", metadata:["ping_id":"\(rdat.hashValue)"])
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
						let combinedResult = existingFrame.exportInboundMessage()
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
				var newFrame = Message(type:Message.SequenceType(opcode:frame.opcode)!)
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
						let combinedResult = newFrame.exportInboundMessage()
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
		self.logger.info("connected.")
		self.waitingOnPong = nil
		self.sendPing(context:context, pongPromise:nil).whenFailure { initialPingFailure in
			self.logger.critical("failed to send initial ping.", metadata:["error": "\(initialPingFailure)"])
			context.fireErrorCaught(Error.WebSocket.failedToWriteInitialPing(initialPingFailure))
		}
		self.initiateAutoPing(context: context, interval:self.healthyConnectionTimeout)
		self.frameParsingMode = .idle
	}

	internal func handlerRemoved(context:ChannelHandlerContext) {
		self.logger.info("disconnected.")
		self.autoPingTask?.cancel()
		self.autoPingTask = nil
		self.waitingOnPong = nil
		self.pingDates = [:]
		self.pongPromises = [:]
	}

	/// read hook
	internal func channelRead(context:ChannelHandlerContext, data:NIOAny) {
		// get the frame
		let frame:InboundIn = self.unwrapInboundIn(data)
				
		// handle the frame
		switch frame.opcode {

			// pong data. this is a control frame and is handled differently than a data frame.
			case .pong:
				// capture the time that this pong was received
				let captureDate = WebCore.Date(localTime:false)

				guard frame.fin == true else {
					self.logger.critical("got fragmented pong frame.")
					context.fireErrorCaught(Error.WebSocket.rfc6455Violation(.fragmentControlViolation(.fragmentedPongReceived)))
					return
				}

				// get the ping id
				let pongID = Array(frame.data.readableBytesView)

				// this may or may not be an unsolicited pong. so the handling here is conditional based on greater context of the connection.
				switch self.pingDates.removeValue(forKey:pongID) {
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

						// handle a future if it exists
						let checkPromise = self.pongPromises[pongID]
						if checkPromise != nil {
							// checkPromise!.succeed(())
							self.pongPromises.removeValue(forKey:pongID)
						}

						// create a new message for the next member in the pipeline
						let newMessage = Message.Inbound.unsolicitedPong(pongID.hashValue)
						context.fireChannelRead(self.wrapInboundOut(newMessage))

					case .some(let sendDate):

						// announce and clear.
						self.logger.debug("got pong (solicited).", metadata:["ping_id": "\(pongID.hashValue)"])
						if (self.waitingOnPong == pongID) {
							self.logger.trace("this pong was in response to the routine ping that is used to evaluate connection health.")
							self.waitingOnPong = nil
						}

						// calculate the round trip time
						let rtt = captureDate.timeIntervalSince(sendDate)

						// handle a future if it exists
						let checkPromise = self.pongPromises[pongID]
						if checkPromise != nil {
							// checkPromise!.succeed(())
							self.pongPromises.removeValue(forKey:pongID)
						}

						// create a new message for the next member in the pipeline
						let newMessage = Message.Inbound.solicitedPong(rtt, pongID.hashValue)
						context.fireChannelRead(self.wrapInboundOut(newMessage))
				}

			// ping data. this is a control frame and is handled differently than a data frame.
			case .ping:
				// capture the time that this pong was received
				let captureDate = WebCore.Date(localTime:false)

				guard frame.fin == true else {
					self.logger.critical("got fragmented ping frame.")
					context.fireErrorCaught(Error.WebSocket.rfc6455Violation(.fragmentControlViolation(.fragmentedPingReceived)))
					return
				}

				// create a new frame with the masking key
				let wsMask = WebSocketMaskingKey.random()
				let responsePong = WebSocketFrame(fin:true, opcode:.pong, maskKey:wsMask, data:frame.unmaskedData)

				// write it
				let writePromise = context.eventLoop.makePromise(of:Void.self)
				context.writeAndFlush(self.wrapOutboundOut(responsePong), promise:writePromise)

				let writeCompletePromise = context.eventLoop.makePromise(of:Double.self)

				// debug it
				let asArray = Array(frame.unmaskedData.readableBytesView)
				self.logger.debug("got ping.", metadata:["ping_id": "\(asArray.hashValue)"])
				writePromise.futureResult.whenComplete({ [wcp = writeCompletePromise] in
					switch $0 {
					case .success:
						let writeTime = WebCore.Date(localTime:false)
						let rtt = captureDate.timeIntervalSince(writeTime)
						wcp.succeed(rtt)
						self.logger.debug("sent pong.", metadata:["ping_id": "\(asArray.hashValue)"])
					case .failure(let error):
						wcp.fail(error)
						self.logger.error("failed to send pong: '\(error)'", metadata:["ping_id": "\(asArray.hashValue)"])
					}
				})

				// create a new message for the next member in the pipeline
				let newMessage = Message.Inbound.ping(writeCompletePromise.futureResult)
				context.fireChannelRead(self.wrapInboundOut(newMessage))

			// text or binary stream
			case .text:
				fallthrough;
			case .binary:
				self.handleFrame(frame, context:context)

			case .continuation:
				switch self.frameParsingMode {
					case .existingFrameFragments(var existingFrame):

						// verify that the current fragment matches the existing frame type.
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

						// this is a valid continuation. so now, handle it apropriately.
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
		// let writeBytes:[UInt8]
		// switch message {
		// 	case .text(let textToSend):

				
		// 	case .data(let datToSend):

		// 	case .unsolicitedPong:
		// 		self.sendPong(context:context).cascade(to:promise)
		// 		break;
			
		// 	case .newPing(let continuation):

		// }
		// /// validate the message size
		// guard mesBytes.count <= self.maxMessageSize else {
		// 	self.logger.warning("message size of \(mesBytes.count) exceeds byte limit of \(self.maxMessageSize).")
		// 	promise?.fail(Error.WebSocket.messageTooLarge)
		// 	return
		// }
		// while mesBytes.count > 0 {
		// 	// get the next chunk
		// 	let chunkSize = min(mesBytes.count, self.maxFrameSize)
		// 	let chunk = mesBytes.prefix(chunkSize)
		// 	mesBytes.removeFirst(chunkSize)
			
		// 	// write the chunk to a new bytebuffer
		// 	var chunkBuffer = context.channel.allocator.buffer(capacity: chunkSize)
		// 	chunkBuffer.writeBytes(chunk)

		// 	// create a new websocket frame with the chunk
		// 	let isFin = mesBytes.count == 0
		// 	let maskingKey = WebSocketMaskingKey.random()
		// 	let frame = WebSocketFrame(fin:isFin, opcode:op, maskKey:maskingKey, data:chunkBuffer)
		// 	if isFin == false {
		// 		// write the frame without flushing. any failures will cascade to the promise.
		// 		context.write(self.wrapOutboundOut(frame)).cascadeFailure(to:promise)
		// 	} else {
		// 		// this is the final frame. flush it and cascade the result to the promise.
		// 		context.writeAndFlush(self.wrapOutboundOut(frame), promise:promise)
		// 	}
		// }
	}
}