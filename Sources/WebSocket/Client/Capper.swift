import NIO
import Logging

internal final class Capper:ChannelInboundHandler {
	typealias InboundIn = Frame
	
	let logger:Logger

	var textStream:AsyncStream<String>.Continuation? = nil
	var binaryStream:AsyncStream<[UInt8]>.Continuation? = nil

	init(log:Logger) {
		self.logger = log
	}

	internal func registerTextStream(_ textStream:AsyncStream<String>.Continuation) {
		self.logger.trace("registering text stream")
		self.textStream = textStream
	}

	internal func registerBinaryStream(_ binaryStream:AsyncStream<[UInt8]>.Continuation) {
		self.logger.trace("registering binary stream")
		self.binaryStream = binaryStream
	}

	internal func handlerAdded(context:ChannelHandlerContext) {
		self.logger.trace("handler added")
	}
	internal func handlerRemoved(context: ChannelHandlerContext) {
		self.logger.trace("handler removed")
		textStream?.finish()
		binaryStream?.finish()
		textStream = nil
		binaryStream = nil
	}

	internal func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		self.logger.trace("channel read")
		let frame = self.unwrapInboundIn(data)
		switch frame {
			case .text(let text):
				self.textStream?.yield(text)
			case .data(let data):
				self.binaryStream?.yield(data)
		}
	}
}