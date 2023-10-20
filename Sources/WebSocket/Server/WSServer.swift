import NIO
import NIOWebSocket

public final class Server {
	private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
	private var channel:Channel?
	private let configuration:Configuration

	init(configuration:Configuration) {
		self.configuration = configuration
	}

	func start(host:String, port:UInt16) throws {
		// let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { channel, reqHead in 
			
		// })
	}
}