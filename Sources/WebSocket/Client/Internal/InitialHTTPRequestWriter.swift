import WebCore
import NIOCore
import NIOHTTP1
import Logging

extension WebSocket.Client {
	
	/// writes the initial HTTP request to the channel. this is a channel handler that is designed to be removed after the request is written.
	internal final class InitialHTTPRequestWriter:ChannelInboundHandler, RemovableChannelHandler {
		
		typealias InboundIn = HTTPClientResponsePart
		typealias OutboundOut = HTTPClientRequestPart

		/// the logger for this handler to use when logging messages.
		internal let logger:Logger

		// the path of the URL to request
		internal let urlPath:String

		internal let upgradePromise:EventLoopPromise<Void>

		internal let initialHeaders:HTTPHeaders

		/// initialize with a URL.
		/// - throws: if the URL is invalid
		internal init(log:Logger, url:URL.Split, headers:HTTPHeaders, upgradePromise:EventLoopPromise<Void>) {
			var modLog = log
			modLog[metadataKey: "url"] = "\(url.host)\(url.pathQuery)"
			self.logger = modLog
			self.urlPath = url.pathQuery
			self.upgradePromise = upgradePromise
			self.initialHeaders = headers
		}

		/// called when the channel becomes active.
		internal func channelActive(context:ChannelHandlerContext) {
			let promise = context.eventLoop.makePromise(of:Void.self)

			// writes the HTTP request to the channel immediately.
			let requestHead = HTTPRequestHead(version:.init(major: 1, minor: 1), method: .GET, uri: self.urlPath, headers:initialHeaders)
			context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)
			context.write(self.wrapOutboundOut(.body(.byteBuffer(.init()))), promise:nil)
			context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise:promise)
			promise.futureResult.whenSuccess { [logFac = self.logger] in
				logFac.debug("wrote initial HTTP upgrade request.")
			}
			promise.futureResult.whenFailure { [ugp = self.upgradePromise, logFac = self.logger] error in
				logFac.error("failed to write initial HTTP upgrade request. '\(error)'")
				ugp.fail(Error.WebSocket.UpgradeError.failedToWriteInitialRequest(error))
			}
		}

		/// close the channel if there is an issue.
		internal func errorCaught(context:ChannelHandlerContext, error:Error) {
			self.logger.error("error caught in initial HTTP request writer. '\(error)'")
			self.upgradePromise.fail(error)
		}
	}
}