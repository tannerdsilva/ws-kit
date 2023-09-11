import WebCore
import NIOCore
import NIOHTTP1
import Logging

extension WebSocket.Client {
	
	/// writes the initial HTTP request to the channel. this is a channel handler that is designed to be removed after the request is written.
	internal final class InitialHTTPRequestWriter:ChannelInboundHandler, RemovableChannelHandler {
		
		fileprivate static let loggerLabel = "ws-client.bootstrap.http-request-writer"

		typealias InboundIn = Never
		typealias OutboundOut = HTTPClientRequestPart

		/// the logger for this handler to use when logging messages.
		internal let logger:Logger

		/// the path of the URL to request
		internal let urlPath:String

		/// the upgrade promise to fail if anything goes wrong.
		internal let upgradePromise:EventLoopPromise<Void>

		/// the headers to send with the request.
		internal let initialHeaders:HTTPHeaders

		/// initialize with a URL.
		internal init(log:Logger, url:URL.Split, headers:HTTPHeaders, upgradePromise:EventLoopPromise<Void>) {
			var modLog:Logger
			if log.metadataProvider != nil {
				modLog = Logger(label:Self.loggerLabel, metadataProvider:log.metadataProvider!)
			} else {
				modLog = Logger(label:Self.loggerLabel)
			}
			modLog.logLevel = log.logLevel

			self.logger = modLog
			self.urlPath = url.pathQuery
			self.upgradePromise = upgradePromise
			self.initialHeaders = headers
		}

		internal func handlerAdded(context:ChannelHandlerContext) {
			self.logger.trace("added to pipeline.")
		}

		internal func handlerRemoved(context:ChannelHandlerContext) {
			self.logger.trace("removed from pipeline.")
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
				self.logger.debug("http request successfully sent.")
			})
			promise.futureResult.whenFailure({ error in
				self.logger.critical("failed to send http request. '\(error)'.")
			})

			let removeHandler = context.eventLoop.makePromise(of:Void.self)
			context.pipeline.removeHandler(context:context, promise:removeHandler)
			removeHandler.futureResult.cascadeFailure(to:self.upgradePromise)
		}

		/// close the channel if there is an issue.
		internal func errorCaught(context:ChannelHandlerContext, error:Error) {
			self.logger.critical("error caught in initial HTTP request writer. '\(error)'")
			self.upgradePromise.fail(error)
			context.close(promise:nil)
		}
	}
}