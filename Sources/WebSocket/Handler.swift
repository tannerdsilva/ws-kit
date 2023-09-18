// (c) tanner silva 2023. all rights reserved.

import NIOCore
import NIOWebSocket
import Logging

import cweb
import struct WebCore.Date
import struct WebCore.URL

/// handles the merging of WebSocket frames into a single data type for the user
/// - abstracts ping/pong logic entirely.
/// - abstracts away the fragmentation of WebSocket frames
/// - abstracts away frame types. a default written frame type can be specified, however, all inbound data is treated the same (as a ByteBuffer)
internal final class Handler:ChannelDuplexHandler {
	/// represents an internal error that should never be thrown. this is used to represent a fatal error that should never be thrown.
	internal struct WSHandlerInternalError:Sendable, Swift.Error {}

	/// how long is the randomly generated ping data sent by ?
	private static let pingDataSize:size_t = 4

	/// the label for the logger that is used by this handler
	private static let loggerLabel = "ws-client.ctx-active.handler"

	// io types for nio
	internal typealias InboundIn = WebSocketFrame
	internal typealias InboundOut = Message.Inbound
	internal typealias OutboundIn = Message.Outbound
	internal typealias OutboundOut = WebSocketFrame
	
	// ping/pong & health related variables and controls
	/// assigned to a given ByteBuffer when a ping is sent. when this the case, the contained data represents the data sent in the ping, and expected to be returned.
	private var waitingOnPong:Int? = nil
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
	// the connection stage of this handler. this is used to determine if certain actions are valid, and the memory associated.
	private enum ConnectionStage {
		case awaitingConnection
		case connected(FrameParsingState)
		case remoteClosing(UInt16?, String?)
		case userClosing(FrameParsingState, UInt16?, String?)
		case disconnected
	}
	// the current connection stage of this handler.
	private var stage = ConnectionStage.awaitingConnection {
		didSet {
			self.logger?.trace("connection stage changed from \(oldValue) to \(stage).")
		}
	}

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
	internal let logger:Logger?

	/// initialize a new handler for use above a websocket channel handler
	internal init(log:Logger?, surl:URL.Split, maxMessageSize:size_t, maxFrameSize:size_t, healthyConnectionThreshold:TimeAmount) {
		self.maxMessageSize = maxMessageSize
		self.maxFrameSize = maxFrameSize
		self.healthyConnectionTimeout = healthyConnectionThreshold
		var modLogger = log
		if log != nil {
			modLogger![metadataKey:"ctx"] = "handler"
		}
		self.logger = modLogger
		self.pingDates = [:]
		self.pongPromises = [:]
	}

	/// initiates auto ping functionality on the connection. 
	private func _initiateAutoPing(context:ChannelHandlerContext, interval:TimeAmount) {
		// cancel the existing task, if it exists.
		if self.autoPingTask != nil {
			self.logger?.trace("cancelling previously scheduled ping.")
			self.autoPingTask!.cancel()
		}

		// schedule the next ping task
		self.autoPingTask = context.eventLoop.scheduleTask(in: interval) {
			if self.waitingOnPong != nil {
				self.logger?.notice("did not receive pong from previous ping sent. closing channel...", metadata:["prev_ping_id": "\(self.waitingOnPong.hashValue))"])
				// we never received a pong from our last ping, so the connection has timed out
				context.fireErrorCaught(Error.connectionTimeout)
			} else {
				switch self.stage {
					case .awaitingConnection:
						self.logger?.critical("attempted to fire auto ping while awaiting connection. this is indicative of a fatal internal error.")
						context.fireErrorCaught(WSHandlerInternalError())
						return
					case .connected(_):
						self._sendPing(context:context, registerCorrespondingPongPromise:nil).whenFailure { err in
							self.logger?.critical("failed to send ping: '\(err)'")
							_ = context.close()
						}
						self._initiateAutoPing(context:context, interval:interval)
					case .userClosing(_, _, _):
						// auto ping should not proceed when closing is in progress.
						fallthrough;
					case .remoteClosing(_, _):
						// auto ping should not proceed when closing is in progress.
						self.logger?.notice("attempted to fire auto ping while closing connection. ping will not be sent.")
						break;
					case .disconnected:
						self.logger?.critical("attempted to fire auto ping while disconnected.")
						context.fireErrorCaught(WSHandlerInternalError())
						return
				}
			}
		}

		self.logger?.debug("scheduled next ping to send in \(interval.nanoseconds / (1000 * 1000 * 1000))s.")
	}

	private func _sendUnsolicitedPong(context:ChannelHandlerContext) -> EventLoopFuture<Void> {
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
					self.logger?.debug("sent pong.", metadata:["pong_id": "\(rdat.hashValue)"])
				case .failure(let error):
					self.logger?.error("failed to send pong: '\(error)'", metadata:["pong_id": "\(rdat.hashValue)"])
			}
		})
		return writePromise.futureResult
	}
	
	/// the only valid way to send a ping to the remote peer.
	private func _sendPing(context:ChannelHandlerContext, registerCorrespondingPongPromise:EventLoopPromise<Double>?) -> EventLoopFuture<Void> {
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
		writeAndFlushFuture.whenComplete { result in
			switch result {
			case .success:
				if (self.waitingOnPong == nil) {
					self.logger?.trace("upcoming pong will be used to evaluate connection health.", metadata:["ping_id":"\(rdat.hashValue)"])
					self.waitingOnPong = rdat.hashValue
				}
				let newDate = WebCore.Date()
				self.pingDates[rdat] = newDate
				if registerCorrespondingPongPromise != nil {
					self.pongPromises[rdat] = registerCorrespondingPongPromise!
				}
				self.logger?.debug("sent ping.", metadata:["ping_id":"\(rdat.hashValue)"])
				break;
			case .failure(let error):
				self.logger?.error("failed to send ping: '\(error)'")
				break;
			}
		}
		return writeAndFlushFuture
	}

	/// the only way to handle data frames from the remote peer. this function is only designed to support frames that are TEXT or BINARY based.
	/// - WARNING: this function will throw a fatal error and crash your program immediately if an invalid frame type is passed
	private func _handleFrame(_ frame:InboundIn, parsingMode:inout FrameParsingState, context:ChannelHandlerContext) {
		switch parsingMode {
			// there are existing frame fragments in the channel.
			case .existingFrameFragments(var existingFrame):
				// verify that the current fragment matches the existing frame type.
				guard existingFrame.type.opcode() == frame.opcode else {
					self.logger?.notice("received frame with opcode \(frame.opcode) but existing frame is of type \(existingFrame.type).")
					// throw an informative error based on the RFC 6455 violation.
					switch frame.fin {
						case false:
							context.fireErrorCaught(Error.rfc6455Violation(.fragmentControlViolation(.streamOpcodeMismatch(existingFrame.type.opcode(), frame.opcode))))
						case true:
							context.fireErrorCaught(Error.rfc6455Violation(.fragmentControlViolation(.initiationWithUnfinishedContext)))
					}
					return
				}
				// this is a valid continuation. so now, handle it apropriately.
				switch frame.fin {
					case true:
						// flush the data because the continued data stream has been finished
						existingFrame.append(frame)
						parsingMode = .idle
						let combinedResult = existingFrame.exportInboundMessage()
						context.fireChannelRead(self.wrapInboundOut(combinedResult))
						return
					case false:
						// append the data to the existing frame
						existingFrame.append(frame)
						guard existingFrame.size <= self.maxMessageSize else {
							self.logger?.notice("frame sequence exceeded byte limit of \(self.maxMessageSize). waiting for next frame sequence before continuing.")
							parsingMode = .waitingForNextFrame
							return
						}
						parsingMode = .existingFrameFragments(existingFrame)
				}
				break;

			// this is the first frame in a (possible) sequence).
			case .idle:
				// make a new frame
				var newFrame = Message(type:Message.SequenceType(opcode:frame.opcode)!)

				// append the contents of the frame
				newFrame.append(frame)

				guard newFrame.size <= self.maxMessageSize else {
					self.logger?.notice("frame sequence exceeded byte limit of \(self.maxMessageSize). waiting for next frame sequence before continuing.")
					switch frame.fin {
						case true:
							parsingMode = .idle
						case false:
							parsingMode = .waitingForNextFrame
					}
					return
				}
				switch frame.fin {
					case true:
						let combinedResult = newFrame.exportInboundMessage()
						context.fireChannelRead(self.wrapInboundOut(combinedResult))
						return
					case false:
						parsingMode = .existingFrameFragments(newFrame)
				}
				break;
			// the maximum data length for this stream has been tripped
			case .waitingForNextFrame:
				switch frame.fin {
					case true:
						parsingMode = .idle
					case false:
						break;
				}
				break;
		}
	}

	internal func handlerAdded(context:ChannelHandlerContext) {
		switch stage {
			// this is the only valid path forward
			case .awaitingConnection:
				self.logger?.info("connected.")
				self.stage = .connected(.idle)
				self.waitingOnPong = nil
				self._initiateAutoPing(context:context, interval:self.healthyConnectionTimeout)
				break;

			// all invalid paths - all indicate a fatal internal error
			case .connected(_):
				fallthrough;
			case .userClosing(_, _, _):
				fallthrough;
			case .remoteClosing(_, _):
				fallthrough;
			case .disconnected:
				self.logger?.critical("handler added while in an invalid stage. this is indicative of a fatal internal error.", metadata:["stage":"\(stage)"])
				context.fireErrorCaught(WSHandlerInternalError())
				break;
		}
	}

	internal func handlerRemoved(context:ChannelHandlerContext) {
		switch stage {
			// invalid path, this is indicative of a fatal internal error
			case .awaitingConnection:
				self.logger?.critical("handler removed while awaiting connection. this is indicative of a fatal internal error.")
				context.fireErrorCaught(WSHandlerInternalError())

			case .connected(_):
				self.logger?.notice("disconnected unexpectedly.")
				stage = .disconnected
				self.autoPingTask?.cancel()
				self.autoPingTask = nil
				self.waitingOnPong = nil
				self.pingDates = [:]
				self.pongPromises = [:]

			case .userClosing(_, _, _):
				self.logger?.info("disconnected gracefully by user.")
				stage = .disconnected
				self.autoPingTask?.cancel()
				self.autoPingTask = nil
				self.waitingOnPong = nil
				self.pingDates = [:]
				self.pongPromises = [:]
			
			case .remoteClosing(_, _):
				self.logger?.info("disconnected gracefully by remote.")
				stage = .disconnected
				self.autoPingTask?.cancel()
				self.autoPingTask = nil
				self.waitingOnPong = nil
				self.pingDates = [:]
				self.pongPromises = [:]

			// invalid path. this is indicative of a fatal internal error
			case .disconnected:
				self.logger?.critical("handler removed while disconnected. this is indicative of a fatal internal error.")
				context.fireErrorCaught(WSHandlerInternalError())
		}
	}

	/// read hook
	internal func channelRead(context:ChannelHandlerContext, data:NIOAny) {
		// get the frame
		let frame:InboundIn = self.unwrapInboundIn(data)
		// the function that will process the frame	based on the current parsing mode.
		enum ClosingState {
			case notClosing
			case userClosing(UInt16?, String?)
		}
		// the function that will process the frame under "normal operating procedures". 
		// it is assumed the stage will remain the same and the function can only write to the inout parsingMode unless a completely different stage is returned.
		func _parse(mode parsingMode:inout FrameParsingState, closeState:ClosingState) -> ConnectionStage? {
			// handle the frame
			switch frame.opcode {

				// pong data. this is a control frame and is handled differently than a data frame.
				case .pong:
					// capture the time that this pong was received
					let captureDate = WebCore.Date()

					guard frame.fin == true else {
						self.logger?.critical("got fragmented pong frame.")
						context.fireErrorCaught(Error.rfc6455Violation(.fragmentControlViolation(.fragmentedPongReceived)))
						return nil
					}

					// get the ping id
					let pongID = Array(frame.data.readableBytesView)

					// this may or may not be an unsolicited pong. so the handling here is conditional based on greater context of the connection.
					switch self.pingDates.removeValue(forKey:pongID) {
						case nil:
							// we were not waiting for a pong but we got one anyways. RFC 6455 allows for unsolicited pongs with no guidelines on body content.
							// in this case, we will (of course) support RFC 6455's possibility of unsolicited pongs. we will require that this pong be empty or less than 125 bytes.
							guard frame.data.readableBytes <= 125 else {
								self.logger?.critical("received unsolicited pong with payload larger than 125 bytes.")
								context.fireErrorCaught(Error.RFC6455Violation.pongPayloadTooLong)
								return nil
							}
							
							self.logger?.debug("got pong (unsolicited).")
							
							// unsolicited pongs will reset the internal timeout mechanism
							if self.autoPingTask != nil {
								self._initiateAutoPing(context:context, interval:self.healthyConnectionTimeout)
							}

							// handle a future if it exists
							let checkPromise = self.pongPromises[pongID]
							if checkPromise != nil {
								// checkPromise!.succeed()
								self.pongPromises.removeValue(forKey:pongID)
							}

							// create a new message for the next member in the pipeline
							let newMessage = Message.Inbound.unsolicitedPong(pongID.hashValue)
							context.fireChannelRead(self.wrapInboundOut(newMessage))

						case .some(let sendDate):

							// announce and clear.
							self.logger?.debug("got pong (solicited).", metadata:["ping_id": "\(pongID.hashValue)"])
							if (self.waitingOnPong == pongID.hashValue) {
								self.logger?.trace("this pong was in response to the routine ping that is used to evaluate connection health.", metadata:["ping_id": "\(pongID.hashValue)"])
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

					return nil // do not change stage

				// ping data. this is a control frame and is handled differently than a data frame.
				case .ping:
					// capture the time that this pong was received
					let captureDate = WebCore.Date()
					guard frame.fin == true else {
						self.logger?.critical("got fragmented ping frame.")
						context.fireErrorCaught(Error.rfc6455Violation(.fragmentControlViolation(.fragmentedPingReceived)))
						return nil
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
					self.logger?.debug("got ping.", metadata:["ping_id": "\(asArray.hashValue)"])
					writePromise.futureResult.whenComplete({ [wcp = writeCompletePromise] in
						switch $0 {
						case .success:
							let writeTime = WebCore.Date()
							let rtt = captureDate.timeIntervalSince(writeTime)
							wcp.succeed(rtt)
							self.logger?.debug("sent pong.", metadata:["ping_id": "\(asArray.hashValue)"])
						case .failure(let error):
							wcp.fail(error)
							self.logger?.error("failed to send pong: '\(error)'", metadata:["ping_id": "\(asArray.hashValue)"])
						}
					})

					// create a new message for the next member in the pipeline
					let newMessage = Message.Inbound.ping(writeCompletePromise.futureResult)
					context.fireChannelRead(self.wrapInboundOut(newMessage))

					return nil // do not change stage

				// text or binary stream
				case .text:
					fallthrough;
				case .binary:
					self._handleFrame(frame, parsingMode:&parsingMode, context:context)
					return nil // do not change stage
				
				case .continuation:
					switch parsingMode {
						case .existingFrameFragments(var existingFrame):
							// verify that the current fragment matches the existing frame type.
							guard existingFrame.type.opcode() == frame.opcode else {
								self.logger?.critical("received frame with opcode \(frame.opcode) but existing frame is of type \(existingFrame.type).")
								// throw an informative error based on the RFC 6455 violation.
								switch frame.fin {
									case false:
										context.fireErrorCaught(Error.rfc6455Violation(.fragmentControlViolation(.streamOpcodeMismatch(existingFrame.type.opcode(), frame.opcode))))
									case true:
										context.fireErrorCaught(Error.rfc6455Violation(.fragmentControlViolation(.initiationWithUnfinishedContext)))
								}
								return nil
							}

							// this is a valid continuation. so now, handle it apropriately.
							existingFrame.append(frame)
							parsingMode = .existingFrameFragments(existingFrame)
							self.logger?.trace("appended continuation frame to existing frame.")

						case .idle:
							self.logger?.critical("got continuation frame, but there is no existing frame to append to.")
							context.fireErrorCaught(Error.rfc6455Violation(.fragmentControlViolation(.continuationWithoutContext)))

						case .waitingForNextFrame:
							self.logger?.critical("got continuation frame, but there is no existing frame to append to.")
							context.fireErrorCaught(Error.rfc6455Violation(.fragmentControlViolation(.continuationWithoutContext)))
					}

					return nil // do not change stage

				case .connectionClose:
					// mutate the frame data so we can read it
					var frameData = frame.data

					// read the close code, if it exists
					let closeCode:UInt16?
					if frame.data.readableBytes >= 2 {
						closeCode = frameData.readInteger(endianness:.big, as:UInt16.self)
					} else {
						closeCode = nil
					}
					// read the close description, if it exists
					let closeDescription:String?
					if frame.data.readableBytes > 0 {
						closeDescription = frameData.readString(length:frameData.readableBytes)
					} else {
						closeDescription = nil
					}

					// determine what to do with this close frame based on the current connection stage.
					switch closeState {
						// the user has already initiated the close handshake. this should be a response to that.
						case .userClosing(let intCode, let intDesc):
							// validate that the response matches the request
							guard closeCode == intCode else {
								context.fireErrorCaught(Error.rfc6455Violation(.fragmentControlViolation(.closeCodeMismatch(closeCode, intCode))))
								return nil
							}
							guard closeDescription == intDesc else {
								context.fireErrorCaught(Error.rfc6455Violation(.fragmentControlViolation(.closeReasonMismatch(closeDescription, intDesc))))
								return nil
							}
							// the connection is now closed.
							self.logger?.info("connection closed gracefully by remote peer.")
							return .disconnected
						
						// the user has not initiated the close handshake. this is a request to close the connection, initiated by remote peer.
						case .notClosing:
							// first, determine the length of the body based on the info found in the frame.
							let writeBuffer:ByteBuffer
							switch (closeCode, closeDescription) {
								case (.some(let code), .some(let desc)):
									let length = 2 + desc.utf8.count
									var wb = context.channel.allocator.buffer(capacity:length)
									wb.writeInteger(code, endianness:.big, as:UInt16.self)
									wb.writeString(desc)
									writeBuffer = wb
								case (.some(let code), .none):
									let length = 2
									var wb = context.channel.allocator.buffer(capacity:length)
									wb.writeInteger(code, endianness:.big, as:UInt16.self)
									writeBuffer = wb
								case (.none, .some(_)):
									context.fireErrorCaught(Error.rfc6455Violation(.missingCloseCodeForDescription(closeDescription!)))
									return nil
								case (.none, .none):
									writeBuffer = context.channel.allocator.buffer(capacity:0)
							}

							self.logger?.debug("got disconnect signal from remote peer. initiating close (no more data will be writable). waiting on downstream peers to continue with closure...", metadata:["close_code": "\(String(describing:closeCode))", "close_description": "\(String(describing:closeDescription))"])
							
							// make the promise that will be fulfilled when the peers downstream are ready for the closure handshake to complete.
							let responsePromise = context.eventLoop.makePromise(of:Void.self)
							responsePromise.futureResult.whenComplete { _ in
								self.logger?.trace("...downstream peers are ready for the connection to close. sending corresponding close frame.")
								
								// build the response frame that will be sent later.
								let maskingFrame = WebSocketMaskingKey.random()
								let responseFrame = WebSocketFrame(fin:true, opcode:.connectionClose, maskKey:maskingFrame, data:writeBuffer)
								let outboundOut = self.wrapOutboundOut(responseFrame)
								
								// after the response frame is sent, close the channel.
								context.writeAndFlush(outboundOut).whenComplete { writeRes in
									switch writeRes {
										case .success:
											self.logger?.trace("sent close frame.")
											context.close(promise:nil)
										case .failure(let error):
											self.logger?.error("failed to send close frame: '\(error)'")
											context.close(promise:nil)
									}
								}
							}

							// create a new message for the next member in the pipeline so that they can prepare the channel for closing.
							let newMessage = Message.Inbound.gracefulDisconnect(closeCode, closeDescription, responsePromise)
							context.fireChannelRead(self.wrapInboundOut(newMessage))

							return .remoteClosing(closeCode, closeDescription)
					}
					
					// stage always changes
			default:
				context.fireErrorCaught(Error.opcodeNotSupported(frame.opcode))
				return nil // do not change stage
			}
		}

		switch stage {
			case .awaitingConnection:
				context.fireErrorCaught(WSHandlerInternalError())
				return
			
			case .connected(var parsingMode):
				let changeStage = _parse(mode:&parsingMode, closeState:.notClosing)
				if changeStage != nil {
					// change the stage
					self.stage = changeStage!
				} else {
					// write the new parsing mode back to storage of the same stage
					self.stage = .connected(parsingMode)
				}
				break

			case .remoteClosing(_, _):
				self.logger?.critical("received frame while remote peer is closing.")
				context.fireErrorCaught(WSHandlerInternalError())
				return

			case .userClosing(var parsingMode, let closeCode, let closeDesc):
				// the user has initiated a close on the connection but there is still some latent data that is coming in from the remote peer.
				// we will intake the data as usual, in this circumstance.
				let changeStage = _parse(mode:&parsingMode, closeState:.userClosing(closeCode, closeDesc))
				if changeStage != nil {
					self.stage = changeStage!
				} else {
					// write the new parsing mode back to storage of the same stage
					self.stage = .userClosing(parsingMode, closeCode, closeDesc)
				}
				break

			case .disconnected:
				context.fireErrorCaught(WSHandlerInternalError())
				return;
		}
	}

	private func _writeFrameData(context:ChannelHandlerContext, opcode:WebSocketOpcode, data bytesToWrite:inout [UInt8], promise:EventLoopPromise<Void>?) {
		guard bytesToWrite.count <= self.maxMessageSize else {
			self.logger?.error("message size of \(bytesToWrite.count) exceeds byte limit of \(self.maxMessageSize).")
			promise?.fail(Error.messageTooLarge)
			return
		}
		var writeTotal = bytesToWrite.count
		if writeTotal == 0 {
			self.logger?.trace("no data to write.")
			promise?.succeed(())
			return
		}
		repeat {
			// capture the next chunk
			let chunkSize = min(writeTotal, self.maxFrameSize)
			let chunk = bytesToWrite.prefix(chunkSize)
			bytesToWrite.removeFirst(chunkSize)
			writeTotal -= chunkSize
			
			// write the chunk to a new bytebuffer
			var chunkBuffer = context.channel.allocator.buffer(capacity: chunkSize)
			chunkBuffer.writeBytes(chunk)

			// package the chunk into a frame
			let isFin = writeTotal == 0
			let maskingKey = WebSocketMaskingKey.random()
			let frame = WebSocketFrame(fin:isFin, opcode:.binary, maskKey:maskingKey, data:chunkBuffer)

			// write the frame with the appropriate promise handling and flushing based on the fin state.
			if (isFin == true) {
				context.writeAndFlush(self.wrapOutboundOut(frame)).cascade(to:promise)
				self.logger?.trace("wrote and flushed final chunk.")
			} else {
				context.write(self.wrapOutboundOut(frame)).cascadeFailure(to:promise)
				self.logger?.trace("writing frame chunk.")
			}
		} while writeTotal > 0
	}

	// write hook
	internal func write(context:ChannelHandlerContext, data:NIOAny, promise:EventLoopPromise<Void>?) {
		let message = self.unwrapOutboundIn(data)
		switch self.stage {
			case .awaitingConnection:
				self.logger?.critical("attempted to write data while awaiting connection.")
				context.fireErrorCaught(WSHandlerInternalError())
				promise?.fail(WSHandlerInternalError())
				return
			case .connected(let frameData):
				// get the message and export it so that it can be assembled and written.
				switch message {
					case .data(var bytesToWrite):
						self._writeFrameData(context:context, opcode:.binary, data:&bytesToWrite, promise:promise)
					case .text(let textToSendAndEncode):
						var bytesToWrite = Array(textToSendAndEncode.utf8)
						self._writeFrameData(context:context, opcode:.text, data:&bytesToWrite, promise:promise)
					case .unsolicitedPong:
						self._sendUnsolicitedPong(context:context).cascade(to:promise)
					case .newPing(let pongResponsePromiseRegister):
						self._sendPing(context:context, registerCorrespondingPongPromise:pongResponsePromiseRegister).cascade(to:promise)
					case .gracefulDisconnect(let closeCode, let closeDescription):
						// determine the length of the complete body
						let writeBuffer:ByteBuffer
						switch (closeCode, closeDescription) {
							case (.some(let code), .some(let desc)):
								let length = 2 + desc.utf8.count
								var wb = context.channel.allocator.buffer(capacity:length)
								wb.writeInteger(code, endianness:.big, as:UInt16.self)
								wb.writeString(desc)
								writeBuffer = wb
							case (.some(let code), .none):
								let length = 2
								var wb = context.channel.allocator.buffer(capacity:length)
								wb.writeInteger(code, endianness:.big, as:UInt16.self)
								writeBuffer = wb
							case (.none, .some(_)):
								context.fireErrorCaught(Error.rfc6455Violation(.missingCloseCodeForDescription(closeDescription!)))
								
								return
							case (.none, .none):
								writeBuffer = context.channel.allocator.buffer(capacity:0)
						}
						
						let maskingKey = WebSocketMaskingKey.random()
						let frame = WebSocketFrame(fin:true, opcode:.connectionClose, maskKey:maskingKey, data:writeBuffer)
						self.stage = .userClosing(frameData, closeCode, closeDescription)
						context.writeAndFlush(self.wrapOutboundOut(frame)).cascade(to:promise)
				}
			case .remoteClosing(_, _):
				fallthrough
			case .userClosing(_, _, _):
				promise?.fail(Error.connectionClosureInProgress)
				return
			case .disconnected:
				self.logger?.error("attempted to write data while disconnected.")
				context.fireErrorCaught(WSHandlerInternalError())
				promise?.fail(WSHandlerInternalError())
				return
		}
	}
}