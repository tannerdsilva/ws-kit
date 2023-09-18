/// represents the various types of latencies that are measured.
public enum MeasuredLatency {
	/// measures the amount of time it takes for the remote peer to deliver a pong response after sending it a ping request.
	case remoteResponseTime(Double)
	/// measures the amount of time it takes for this system to send a pong response after receiving a ping request from the peer.
	case ourWriteTime(Double)
}