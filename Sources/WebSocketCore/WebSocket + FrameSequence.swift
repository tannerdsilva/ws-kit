// (c) tanner silva 2023. all rights reserved.

import NIOWebSocket
import NIOCore

import cweb

/// sequence of fragmented WebSocket frames. ``WebSocket.Handler`` uses this to combine fragmented frames into a single buffer
internal struct FrameSequence {
	
	/// type of sequence
	internal enum SequenceType {
		
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
	internal init(type:SequenceType = .binary) {
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
	internal func exportCombinedResult() -> ByteBuffer {
		var result = ByteBufferAllocator().buffer(capacity: self.size)
		for var buffer in self.buffers {
			result.writeBuffer(&buffer)
		}
		return result
	}
}