import struct NIOWebSocket.WebSocketOpcode
import enum NIOHTTP1.HTTPResponseStatus
import struct NIOHTTP1.HTTPHeaders
import struct NIO.ByteBufferAllocator
import struct NIO.ByteBuffer

/// these are all the front-facing errors that a developer may encouter when using the websocket handler.
public enum Error:Swift.Error {
	/// various types of RFC 6455 violations that may occur at any point during a connection lifecycle.
	public enum RFC6455Violation:Swift.Error {
		/// describes various ways that a websocket can violate the fragment control rules defined in RFC 6455 section 5.4.
		public enum FragmentControlViolation {
			/// a ping frame was received from the remote peer, but the ping data was to be delivered with a fragment flag, which is invalid.
			/// - NOTE: see RFC 6455 section 5.4 & 5.5 for more information.
			case fragmentedPingReceived

			/// a pong frame was received from the remote peer, but the pong data was to be delivered with a fragment flag, which is invalid.
			/// - NOTE: see RFC 6455 section 5.4 & 5.5 for more information.
			case fragmentedPongReceived

			/// continued data was received from the remote peer, but the continued data fragments were not of the same type as the initial data fragment.
			/// - NOTE: see RFC 6455 section 5.4 for more information.
			case streamOpcodeMismatch(WebSocketOpcode, WebSocketOpcode)

			/// a continued frame was received from the remote peer, but there was no previous frame to continue.
			/// - NOTE: see RFC 6455 section 5.4 for more information.
			case continuationWithoutContext

			/// a new websocket data stream was initated from the remote peer, but there was already existing data being handled by the connection.
			/// - NOTE: see RFC 6455 section 5.4 for more information.
			case initiationWithUnfinishedContext
		}

		/// the remote peer sent a ping that was longer than the required maximum of 125 bytes.
		/// - NOTE: see RFC 6455 section 5.5 for more information.
		case pingPayloadTooLong

		/// the remote peer sent a pong that was longer than the required maximum of 125 bytes.
		/// - NOTE: see RFC 6455 section 5.5 for more information.
		case pongPayloadTooLong

		/// thrown when a pong response from the remote peer did not contain the expected payload. this is considered an internal and unexpected failure.
		///	- argument 1: the expected payload that was sent to the remote peer.
		///	- argument 2: the pong response that was received after sending the ping.
		/// - NOTE: see RFC 6455 section 5.5 for more information.
		// case pongPayloadMismatch([UInt8], [UInt8])

		/// thrown when the fragment control rules defined in RFC 6455 section 5.4 are violated.
		case fragmentControlViolation(FragmentControlViolation)

		/// thrown when a close frame is received from the remote peer, but the reciprocating close frame could not be written to the remote peer.
		case failedToReciprocateClose(UInt16?, String?)
	}

	/// thrown when a websocket connection is successfully initiated with a relay, but the initial ping could not be written. this is considered an internal and unexpected failure. it is not expected to be thrown under healthy and normal system conditions.
	/// - argument: contains the underlying error that caused the failure.
	case failedToWriteInitialPing(Swift.Error)

	/// thrown when a websocket handles an opcode that it does not know how to handle.
	case opcodeNotSupported(WebSocketOpcode)

	/// thrown when trying to handle a message that is larger than the configured maximum message size.
	case messageTooLarge

	/// thrown when a critical failure prevents the ping pong loop from continuing as expected.
	case pingPongCriticalFailure

	/// thrown when a TCP connection fails to upgrade to a websocket connection.
	public enum UpgradeError:Swift.Error {
		/// a tcp connection was successfully created to the remote peer, however, the HTTP request to upgrade to websockets protocol failed to be written to the remote peer.
		case failedToWriteInitialRequest(Swift.Error)

		/// the remote peer responded to the HTTP upgrade request with a non-101 status code.
		case invalidUpgradeResponse(HTTPResponseStatus)
		
		/// the remote peer failed to respond to the HTTP upgrade request within the configured timeout interval.
		case upgradeTimedOut
	}

	/// the configured timeout interval for the established connection could not be sustained with websocket pings.
	case connectionTimeout

	/// an event occurred that fell out of line with RFC 6455 specifications.
	case rfc6455Violation(RFC6455Violation)
}
