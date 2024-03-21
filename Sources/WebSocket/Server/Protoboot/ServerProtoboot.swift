import NIO
import NIOHTTP1
import NIOWebSocket
import Logging

extension Server {
	internal static func bootstrap(log:Logger?, configuration:Configuration, eventLoop:EventLoop, decisionMaker:@escaping (HTTPRequestHead) -> HTTPHeaders?) throws -> ServerBootstrap {
		let upgrader = NIOWebSocketServerUpgrader(
			shouldUpgrade: { channel, reqHead in
				guard let gotHeaders = decisionMaker(reqHead) else {
					return channel.eventLoop.makeSucceededFuture(nil)
				}
				return channel.eventLoop.makeSucceededFuture(gotHeaders)
			},
			upgradePipelineHandler: { channel, req in
				channel.pipeline.addHandler(Handler(log:log, maxMessageSize:configuration.limits.maxMessageSize, maxFrameSize:configuration.limits.maxIndividualWebSocketFrameSize, healthyConnectionThreshold:configuration.timeouts.healthyConnectionTimeout))
			}
		)
		
		let bootstrap = ServerBootstrap(group:eventLoop)
			.serverChannelOption(ChannelOptions.backlog, value:256)
			.serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value:1)
			.childChannelInitializer({ channel in 
				channel.pipeline.configureHTTPServerPipeline(withServerUpgrade:(upgraders:[
					upgrader
				], completionHandler: { myCompHandler in
					print("this seriously needs to be handled.")
				}))
			})
		return bootstrap
	}
}