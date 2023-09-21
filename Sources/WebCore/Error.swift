// (c) tanner silva 2023. all rights reserved.
import NIOHTTP1
import NIO

/// default HTTP error. provides an HTTP status and a message is so desired
public struct HTTPError:Swift.Error, Sendable {
	/// status code for the error
	public let status:HTTPResponseStatus
	/// any addiitional headers required
	public let headers:HTTPHeaders
	/// error payload, assumed to be a string
	public let body:String?

	/// initialize HTTPError with a given response status
	public init(_ status:HTTPResponseStatus) {
		self.status = status
		self.headers = [:]
		self.body = nil
	}
}
