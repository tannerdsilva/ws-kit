import NIO
import Logging

extension Server {
	internal final class Capper:ChannelInboundHandler {
		
		/// used to convey the current connection state of the channel the ``Capper`` is connected to.
		private enum ConnectionState {
			/// the channel is not connected
			case notConnected
			/// the channel is connected
			case connected
			/// the channel closed with the following result
			case closed(Result<Void, Swift.Error>)
		}

		// nio stuff
		internal typealias InboundIn = Message.Inbound

		private let logger:Logger? = nil
		private var eventLoop:EventLoop? = nil
	}
}