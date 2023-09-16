/// represents the various types of latencies that are measured.
public enum MeasuredLatency {
	/// represents a measured response time from the peer to a ping request from this system.
	case peerPongResponseTime(Double)
	/// represents a measured response time from this system to a pong request from the peer.
	case myPongResponseTime(Double)
}