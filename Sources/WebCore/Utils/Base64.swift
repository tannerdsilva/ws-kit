import cweb

public struct Base64 {
	/// error thrown by Base64 encoding/decoding functions
	public enum Error:Swift.Error {
		/// the provided string could not be decoded
		case decodingError(String, Int32)

		/// the provided string could not be encoded
		case encodingError([UInt8], Int32)
	}

	/// encode a byte array to a base64 string
	/// - parameter bytes: the byte array to encode
	public static func encode(bytes:[UInt8]) throws -> String {
		let newLength = base64_encoded_length(bytes.count)
		let encodedBytes = try Array<UInt8>(unsafeUninitializedCapacity:newLength, initializingWith: { bytePtr, byteLength in
			let decResult = base64_encode(bytePtr.baseAddress, newLength, bytes, bytes.count)
			guard decResult >= 0 else {
				throw Error.encodingError(bytes, geterrno())
			}
		})
		return String(cString:encodedBytes)
	}
	
	/// decode a base64 string to a byte array
	/// - parameter dataEncoding: the base64 string to decode
	public static func decode(_ dataEncoding:String) throws -> [UInt8] {
		let newLength = base64_decoded_length(dataEncoding.count)
		let encodedBytes = Array<UInt8>(dataEncoding.utf8)
		let decodedBytes = try Array<UInt8>(unsafeUninitializedCapacity:newLength, initializingWith: { bytePtr, byteLength in
			let decResult = base64_decode(bytePtr.baseAddress, newLength, encodedBytes, encodedBytes.count)
			guard decResult >= 0 else {
				throw Error.decodingError(dataEncoding, geterrno())
			}
		})
		return decodedBytes
	}
}