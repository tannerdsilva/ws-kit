import WebCore
import NIOCore
import NIOHTTP1
import Logging

extension WebSocket.Client {
	
	/// writes the initial HTTP request to the channel. this is a channel handler that is designed to be removed after the request is written.
	internal final class InitialHTTPRequestWriter:ChannelInboundHandler, RemovableChannelHandler {
		typealias InboundIn = Never
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

		internal func handlerAdded(context:ChannelHandlerContext) {
			self.logger.debug("handler added")
		}

		/// called when the channel becomes active.
		internal func channelActive(context:ChannelHandlerContext) {

			let promise = context.eventLoop.makePromise(of:Void.self)
			promise.futureResult.cascadeFailure(to:self.upgradePromise)

			// writes the HTTP request to the channel immediately.
			let requestHead = HTTPRequestHead(version:.init(major:1, minor:1), method: .GET, uri:self.urlPath, headers:initialHeaders)
			context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)
			context.write(self.wrapOutboundOut(.body(.byteBuffer(.init()))), promise:nil)
			context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise:promise)			
			promise.futureResult.whenSuccess({
				self.logger.debug("initial HTTP request written")
			})
			promise.futureResult.whenFailure({ error in
				self.logger.critical("error writing initial HTTP request. '\(error)'")
			})

			let removeHandler = context.eventLoop.makePromise(of:Void.self)
			context.pipeline.removeHandler(context:context, promise:removeHandler)
			removeHandler.futureResult.cascadeFailure(to:self.upgradePromise)
			removeHandler.futureResult.whenSuccess({
				self.logger.debug("removed initial HTTP request writer")
			})
		}

		/// close the channel if there is an issue.
		internal func errorCaught(context:ChannelHandlerContext, error:Error) {
			self.logger.critical("error caught in initial HTTP request writer. '\(error)'")
			self.upgradePromise.fail(error)
			context.close(promise:nil)
		}
	}
}