import NIO
import NIOHTTP1
import NIOWebSocket
import Logging

extension Server {
	internal static func bootstrap(log:Logger?, configuration:Configuration, eventLoop:EventLoop) throws -> ServerBootstrap {
		let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, reqHead in
                // In this basic example, always agree to upgrade. In a real application,
                // you might want to inspect the `reqHead` to make a decision.
                return channel.eventLoop.makeSucceededFuture([:])
            },
            upgradePipelineHandler: { channel, req in
                // This is called after the upgrade has been completed.
                // Here you can insert your symmetric WebSocket handler.
                channel.pipeline.addHandler(Handler(log:log, maxMessageSize:configuration.limits.maxMessageSize, maxFrameSize:configuration.limits.maxIndividualWebSocketFrameSize, healthyConnectionThreshold:configuration.timeouts.healthyConnectionTimeout))
            }
        )
		
		let bootstrap = ServerBootstrap(group:eventLoop)
			.serverChannelOption(ChannelOptions.backlog, value:256)
			.serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value:1)
			.childChannelInitializer({ channel in 
				channel.pipeline.configureHTTPServerPipeline(withServerUpgrade:[
					("websocket", upgrader)
				])
			})
	}
}