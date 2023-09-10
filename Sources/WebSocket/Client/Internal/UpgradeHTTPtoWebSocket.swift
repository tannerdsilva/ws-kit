// (c) tanner silva 2023. all rights reserved.

import NIOCore
import NIOHTTP1
import NIOWebSocket

import WebCore
import Logging

fileprivate let magicWebSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

extension WebSocket.Client {

	/// this is the class that is used to upgrade the HTTP connection to a WebSocket connection.
	internal final class HTTPToWebSocketUpgrader:NIOHTTPClientProtocolUpgrader {

		/// errors that may be throwin into an instance's `upgradePromise
		internal enum Error:Swift.Error {
			/// the part of the response that the error is concerned with
			enum ResponsePart:UInt8 {
				case httpStatus
				case websocketAcceptValue
			}
			/// a general error that is thrown when the upgrade could not be completed
			case invalidResponse(ResponsePart)

			/// a specific error that is thrown when a redirect error is encountered
			case requestRedirected(String)
		}

		internal let logger:Logger

		/// required for NIOHTTPClientProtocolUpgrader - defines the protocol that this upgrader supports.
		internal let supportedProtocol: String = "websocket"

		/// required by NIOHTTPClientProtocolUpgrader - defines the headers that must be present in the upgrade response for the upgrade to be successful.
		/// - this is needed for certain protocols, but not for websockets, so we can leave this alone.
		internal let requiredUpgradeHeaders: [String] = []

		/// the split url that this channel is connected to
		private let surl:URL.Split
		/// request key to be assigned to the `Sec-WebSocket-Key` HTTP header.
		private let requestKey:String
		/// largest incoming `WebSocketFrame` size in bytes. This is used to set the `maxFrameSize` on the `WebSocket` channel handler upon a successful upgrade.
		private let maxWebSocketFrameSize: Int
		/// called once the upgrade was successful or unsuccessful.
		private let upgradePromise:EventLoopPromise<Void>
		/// called once the upgrade was successful. This is the owners opportunity to add any needed handlers to the channel pipeline.
		private let handlers:[NIOCore.ChannelHandler]

		internal init(log:Logger, surl:URL.Split, requestKey:String, maxWebSocketFrameSize:Int, upgradePromise:EventLoopPromise<Void>, handlers:[NIOCore.ChannelHandler]) {
			self.surl = surl
			self.requestKey = requestKey
			self.maxWebSocketFrameSize = maxWebSocketFrameSize
			self.upgradePromise = upgradePromise
			self.handlers = handlers
			var modLog = log
			modLog[metadataKey: "url"] = "\(surl.host)\(surl.pathQuery)"
			self.logger = modLog
		}

		/// adds additional headers that are needed for a WebSocket upgrade request. It is important that it is done this way, as to have the "final say" in the values of these headers before they are written.
		internal func addCustom(upgradeRequestHeaders:inout HTTPHeaders) {
			let initialHeaderValues = upgradeRequestHeaders.count
			upgradeRequestHeaders.replaceOrAdd(name: "Sec-WebSocket-Key", value: self.requestKey)
			upgradeRequestHeaders.replaceOrAdd(name: "Sec-WebSocket-Version", value: "13")
			// RFC 6455 requires this to be case-insensitively compared. However, many server sockets check explicitly for == "Upgrade", and SwiftNIO will (by default) send a header that is "upgrade" if not for this custom implementation with the NIOHTTPProtocolUpgrader protocol.
			upgradeRequestHeaders.replaceOrAdd(name: "Connection", value: "Upgrade")
			upgradeRequestHeaders.replaceOrAdd(name: "Upgrade", value: "websocket")
			upgradeRequestHeaders.replaceOrAdd(name: "Host", value: self.surl.host)
			self.logger.trace("applied upgrade-specific HTTP headers to outbound request. final request containing \(initialHeaderValues) headers.")
		}
		
		/// allow or deny the upgrade based on the upgrade HTTP response headers containing the correct accept key.
		internal func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool {
			return self._shouldAllowUpgrade(upgradeResponse: upgradeResponse)
		}
		
		/// the internal allow upgrade function. the most critical part of this code is how the result of this upgrade is handled.
		/// - if the upgrade is allowed, the `upgradePromise` is NOT fulfilled in this code.
		/// - if the upgrade is denied, the `upgradePromise` is filfilled with a FAILURE in this code.
		private func _shouldAllowUpgrade(upgradeResponse:HTTPResponseHead) -> Bool {
			self.logger.trace("evaluating response to HTTP upgrade request...")
			// determine a basic path forward based on the HTTP response status code
			switch upgradeResponse.status {
				case .movedPermanently, .found, .seeOther, .notModified, .useProxy, .temporaryRedirect, .permanentRedirect:
					// redirect response likely
					guard let hasNewLocation = (upgradeResponse.headers["Location"].first ?? upgradeResponse.headers["location"].first) else {
						self.logger.error("failed to upgrade protocol from https to wws. no redirect location found in response.")
						self.upgradePromise.fail(Error.invalidResponse(.httpStatus))
						return false
					}
					self.upgradePromise.fail(Error.requestRedirected(hasNewLocation))
					return false
				case .switchingProtocols:
					// this is the only path forward. lets go.
					self.logger.trace("remote peer successfully responded to HTTP upgrade request with valid status code \"switchingProtocols\". continuing with upgrad...")
					break
				default:
					// unknown response
					self.logger.error("failed to upgrade protocol from https to wws. unknown response status code: \(upgradeResponse.status)")
					self.upgradePromise.fail(Error.invalidResponse(.httpStatus))
					return false
			}

			// validate the response key in 'Sec-WebSocket-Accept'
			let acceptValueHeader = upgradeResponse.headers["Sec-WebSocket-Accept"]
			guard acceptValueHeader.count == 1 else {
				self.logger.error("failed to upgrade protocol from https to wws. invalid number of Sec-WebSocket-Accept headers in response: \(acceptValueHeader.count)")
				return false
			}

			// validate the response key in 'Sec-WebSocket-Accept'.
			var hasher = SHA1()
			hasher.update(string: self.requestKey)
			hasher.update(string: magicWebSocketGUID)
			let expectedAcceptValue:String
			do {
				expectedAcceptValue = try Base64.encode(bytes:hasher.finish())
			} catch {
				self.logger.critical("failed to upgrade protocol from https to wws. failed to encode SHA1 hash of request key: \(error)")
				self.upgradePromise.fail(error)
				return false
			}

			guard acceptValueHeader[0] == expectedAcceptValue else {
				self.logger.error("failed to upgrade protocol from https to wss. invalid Sec-WebSocket-Accept header value in response: \(acceptValueHeader[0])")
				self.upgradePromise.fail(Error.invalidResponse(.websocketAcceptValue))
				return false
			}
			self.logger.trace("response evaluation complete. upgrade to websocket protocol allowed.")
			return true
		}

		/// called when the upgrade response has been flushed and it is safe to mutate the channel pipeline. Adds channel handlers for websocket frame encoding, decoding and errors.
		internal func upgrade(context:ChannelHandlerContext, upgradeResponse:HTTPResponseHead) -> EventLoopFuture<Void> {
			var useHandlers:[NIOCore.ChannelHandler] = [WebSocketFrameEncoder(), ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize:self.maxWebSocketFrameSize))]
			useHandlers.append(contentsOf: self.handlers)
			context.pipeline.addHandlers(useHandlers).cascade(to:self.upgradePromise)
			return upgradePromise.futureResult
		}
	}
}