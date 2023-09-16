// (c) tanner silva 2023. all rights reserved.

import WebCore
import NIOCore
import NIOHTTP1
import Logging

extension WebSocket.Client {
	
	/// writes the initial HTTP request to the channel. this is a channel handler that is designed to be removed after the request is written.
	internal final class InitialHTTPRequestWriter:ChannelInboundHandler, RemovableChannelHandler {
		fileprivate static let loggerLabel = "ws-client.protoboot.http-request-writer"

		// nio stuff
		internal typealias InboundIn = Never
		internal typealias OutboundOut = HTTPClientRequestPart

		/// the logger for this handler to use when logging messages.
		internal let logger:Logger?

		/// the path of the URL to request
		internal let urlPath:String

		/// the upgrade promise to fail if anything goes wrong.
		/// - this is not fulfilled by this handler, since this handler only facilitates the first step.
		internal let upgradePromise:EventLoopPromise<Void>

		/// the headers to send with the request.
		internal let initialHeaders:HTTPHeaders

		/// initialize with a URL.
		internal init(log:Logger?, url:URL.Split, headers:HTTPHeaders, upgradePromise:EventLoopPromise<Void>) {
			var modLogger = log
			if log != nil {
				modLogger![metadataKey:"ctx"] = "http-request-writer"
			}
			self.logger = modLogger
			self.urlPath = url.pathQuery
			self.upgradePromise = upgradePromise
			self.initialHeaders = headers
		}
		
		/// initialize the handler with a URL.
		internal func handlerAdded(context:ChannelHandlerContext) {
			self.logger?.trace("added to pipeline.")
		}

		/// called when the handler is removed from the pipeline.
		internal func handlerRemoved(context:ChannelHandlerContext) {
			self.logger?.trace("removed from pipeline.")
		}

		/// called when the channel becomes active.
		internal func channelActive(context:ChannelHandlerContext) {
			self.logger?.trace("channel became active. starting to write HTTP request.")

			// it is now time to do our primary job...write the HTTP request to the channel.
			// this is the promise that will represent the completion of the HTTP request.
			let writePromise = context.eventLoop.makePromise(of:Void.self)
			// cascade the promise to the upgrade promise.
			writePromise.futureResult.cascadeFailure(to:self.upgradePromise)

			// build the request head
			let requestHead = HTTPRequestHead(version:.init(major:1, minor:1), method: .GET, uri:self.urlPath, headers:initialHeaders)
			// write the request head and the rest of the body.
			context.write(self.wrapOutboundOut(.head(requestHead))).cascadeFailure(to:writePromise)
			context.write(self.wrapOutboundOut(.body(.byteBuffer(.init())))).cascadeFailure(to:writePromise)
			// the end will be flushed and attached to the promise.
			context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise:writePromise)		
			// log the results	
			writePromise.futureResult.whenSuccess({
				self.logger?.debug("http request successfully sent.")
			})
			writePromise.futureResult.whenFailure({ error in
				self.logger?.critical("failed to send http request. '\(error)'.")
			})

			// remove this handler from the pipeline.
			// if this fails, the upgrade promise needs to be failed.
			context.pipeline.removeHandler(context:context).cascadeFailure(to:self.upgradePromise)

			// success does not cascade to the upgrade promise, because the upgrade promise is fulfilled by the upgrade handler.
		}

		/// close the channel if there is an issue.
		internal func errorCaught(context:ChannelHandlerContext, error:Error) {
			self.logger?.critical("error caught '\(error)'.")
			self.upgradePromise.fail(error)
			context.close(promise:nil)
		}
	}
}