// (c) tanner silva 2023. all rights reserved.

import NIOWebSocket
import NIOCore

import cweb

public struct Message {
	/// represents a complete binary message
	public enum Outbound:Sendable {
		/// represents a complete binary message
		case data([UInt8])

		/// represents a complete binary message
		case text(String)

		/// write an unsolicited pong frame to the websocket. this is technically not a part of the websocket spec, but nothing is stopping you from doing it.
		case unsolicitedPong

		/// write a ping frame to the remote peer
		/// - parameter 1: the promise to fulfill when the corresponding pong frame is received
		case newPing(EventLoopPromise<Double>?)

		/// request that the remote peer close the connection gracefully
		case gracefulDisconnect(UInt16?, String?)
	}

	/// represents a complete binary message
	public enum Inbound:Sendable {
		
		/// represents a complete binary message.
		case data([UInt8])

		/// represents a complete binary message.
		case text(String)

		/// represents an unsolicited pong frame that was received.
		/// - parameter 1: the hash of the unsolicited pong signature.
		case unsolicitedPong(Int)

		/// represents a complete binary message.
		/// - parameter 1: the amount of time (in seconds) that elapsed between the ping and pong frames
		/// - parameter 2: the hash of the pong signature
		case solicitedPong(Double, Int)

		/// represents a ping frame that was received from the remote peer.
		/// - parameter 1: the promise that will fulfill when the corresponding pong frame is successfully sent
		case ping(EventLoopFuture<Double>)

		/// the remote peer has requested that the connection be closed gracefully.
		case gracefulDisconnect(UInt16?, String?)
	}
	
	/// type of sequence
	internal enum SequenceType:Sendable {
		
		/// text frame
		case text
		/// binary frame
		case binary

		/// initialize a sequence type based on a raw websocket opcode.
		/// - WARNING: this function will throw a fatal error and crash your program immediately if an invalid opcode is passed.
		/// - valid opcodes:
		/// 	- ``.text``
		/// 	- ``.binary``
		internal init?(opcode:WebSocketOpcode) {
			switch opcode {
				case .text:
				self = .text
				case .binary:
				self = .binary
				default:
				return nil
			}
		}

		/// returns the websocket opcode for sequence type
		internal func opcode() -> WebSocketOpcode {
			switch self {
				case .text:
				return .text
				case .binary:
				return .binary
			}
		}
	}
	
	/// buffers containing frames
	internal var buffers:[ByteBuffer]
	/// total size of sequence
	internal var size:size_t
	/// type of sequence
	internal var type:SequenceType

	/// create a new sequence
	/// - parameter type: the type of sequence
	internal init(type:SequenceType) {
		self.buffers = []
		self.type = type
		self.size = 0
	}
	
	/// append a frame to the sequence
	internal mutating func append(_ frame: WebSocketFrame) {
		self.buffers.append(frame.unmaskedData)
		self.size += frame.unmaskedData.readableBytes
	}

	/// combines all of the frames into a single buffer
	internal func exportInboundMessage() -> Message.Inbound {
		var result = ByteBufferAllocator().buffer(capacity: self.size)
		for var buffer in self.buffers {
			result.writeBuffer(&buffer)
		}
		let allBytes = Array(result.readableBytesView)
		switch self.type {
			case .text:
			return Message.Inbound.data(allBytes)
			case .binary:
			return Message.Inbound.text(String(bytes:allBytes, encoding:.utf8)!)
		}
	}
}
