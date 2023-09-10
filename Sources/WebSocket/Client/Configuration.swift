import struct NIO.TimeAmount
import struct cweb.size_t
import struct NIOSSL.TLSConfiguration

extension Client {

	/// configuration for the client
	public struct Configuration:Sendable {

		public var timeouts:Timeouts

		public var limits:Limits

		public var tlsConfiguration:TLSConfiguration

	}
}

extension Client.Configuration {
	/// contains the timeout parameters for the relay connection
	public struct Timeouts:Sendable {

		/// how much time is allowed to pass as the client attempts to establish a TCP connection to the relay?
		public let tcpConnectionTimeout:TimeAmount
		/// how much time is allowed up pass as the client attempts to upgrade the connection to a WebSocket?
		public let websocketUpgradeTimeout:TimeAmount
		/// how much time is allowed to pass without a symmetric data exchange being sent between the user and the remote peer?
		/// - this is not a timeout based strictly on an amount of time since the last message was received. this is a timeout interval specifically for the amount of time that can pass without a symmetric data exchange.
		public let healthyConnectionTimeout:TimeAmount

		/// initialize a `Timeouts` struct.
		public init(
			tcpConnectionTimeout:TimeAmount = .seconds(3),
			websocketUpgradeTimeout:TimeAmount = .seconds(5),
			healthyConnectionTimeout:TimeAmount = .seconds(15)
		) {
			self.tcpConnectionTimeout = tcpConnectionTimeout
			self.websocketUpgradeTimeout = websocketUpgradeTimeout
			self.healthyConnectionTimeout = healthyConnectionTimeout
		}
	}

	/// contains the data limit parameters for a relay connection
	public struct Limits:Sendable {

		/// the maximum size of an individual websocket frame.
		public var maxIndividualWebSocketFrameSize:size_t

		/// the maximum size of a single message that one or more websocket frames can build.
		public var maxMessageSize:size_t

		public init(maxWebSocketFrameSize:size_t = 16777216, maxMessageSize:size_t = 16777216) {
			self.maxIndividualWebSocketFrameSize = maxWebSocketFrameSize
			self.maxMessageSize = maxWebSocketFrameSize
		}
	}
}