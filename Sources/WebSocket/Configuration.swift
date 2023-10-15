import struct NIO.TimeAmount
import struct cweb.size_t
import struct NIOSSL.TLSConfiguration

/// configuration for the client
public struct Configuration:Sendable {
	/// specifies the various timeout parameters that can be configured for the client.
	public var timeouts:Timeouts
	/// specifies the various data limits that can be configured for the client.
	public var limits:Limits
	/// specifies the TLS configuration for the client.
	public var tlsConfiguration:TLSConfiguration

	/// initialize a `Configuration` struct with default values.
	public init() {
		self.init(timeouts:Timeouts(), limits:Limits(), tlsConfiguration:TLSConfiguration.makeClientConfiguration())
	}

	/// initialize a `Configuration` struct with custom values.
	public init(
		timeouts:Timeouts,
		limits:Limits,
		tlsConfiguration:TLSConfiguration
	) {
		self.timeouts = timeouts
		self.limits = limits
		self.tlsConfiguration = tlsConfiguration
	}
}

/// contains the timeout parameters for the relay connection
public struct Timeouts:Sendable {

	/// how much time is allowed to pass as the client attempts to establish a TCP connection to the relay?
	public var tcpConnectionTimeout:TimeAmount
	/// how much time is allowed up pass as the client attempts to upgrade the connection to a WebSocket?
	public var websocketUpgradeTimeout:TimeAmount
	/// how much time is allowed to pass without a symmetric data exchange being sent between the user and the remote peer?
	/// - this is not a timeout based strictly on an amount of time since the last message was received. this is a timeout interval specifically for the amount of time that can pass without a symmetric data exchange.
	public var healthyConnectionTimeout:TimeAmount

	/// initialize a `Timeouts` struct with default values.
	public init() {
		self.init(tcpConnectionTimeout: .seconds(3), websocketUpgradeTimeout:.seconds(5), healthyConnectionTimeout:.seconds(15))
	}

	/// initialize a `Timeouts` struct with custom values.
	public init(
		tcpConnectionTimeout:TimeAmount,
		websocketUpgradeTimeout:TimeAmount,
		healthyConnectionTimeout:TimeAmount
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

	/// initialize a `Limits` struct with default values.
	public init() {
		self.init(maxWebSocketFrameSize:16777216, maxMessageSize:16777216)
	}

	/// initialize a `Limits` struct with custom values.
	public init(
		maxWebSocketFrameSize:size_t,
		maxMessageSize:size_t
	) {
		self.maxIndividualWebSocketFrameSize = maxWebSocketFrameSize
		self.maxMessageSize = maxWebSocketFrameSize
	}
}