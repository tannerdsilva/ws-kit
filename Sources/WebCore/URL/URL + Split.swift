// (c) tanner silva 2023. all rights reserved.

extension URL {

	/// splits up a `URL` into its necessary components for connecting to a relay.
	public struct Split {
		
		/// the host to connect to (ipv4, ipv6, or dns name).
		public let host:String

		/// the path to connect to.
		public let pathQuery:String

		/// the port to connect to.
		public let port:UInt16

		/// is TLS required when connecting to this relay?
		public let tlsRequired:Bool

		/// initialize a `URL.Split` from a `URL`.
		public init(url:URL) throws {
			guard let host: String = url.host else { throw URL.Split.Failure(url:url) }
			self.host = host
			if let port = url.port {
				self.port = UInt16(port)
			} else {
				if url.scheme == .wss {
					self.port = 443
				} else {
					self.port = 80
				}
			}
			self.tlsRequired = url.scheme == .wss ? true : false
			self.pathQuery = url.path + (url.query.map { "?\($0)" } ?? "")
		}

		/// return "Host" header value. Only include port if it is different from the default port for the request
		public var hostHeader:String {
			if (self.tlsRequired && self.port != 443) || (!self.tlsRequired && self.port != 80) {
				return "\(self.host):\(self.port)"
			}
			return self.host
		}
	}

	/// returns a URL.Split from a given URL instance
	public func split() throws -> Self.Split {
		return try Split(url:self)
	}
}

extension URL.Split {
	/// thrown when a URL.Split cannot initialize from a given URL struct.
	public struct Failure:Swift.Error {
		/// the URL that could not be split.
		public let url:URL
	}
}