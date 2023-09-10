import cweb
import RAW

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
		let enclen = base64_encoded_length(bytes.count) + 1
		let newBytes = malloc(enclen)
		defer {
			free(newBytes)
		}
		let encodedLength = bytes.asRAW_val({ rv in
			base64_encode(newBytes, enclen, rv.mv_data, bytes.count)
		})
		assert(encodedLength >= 0)
		return String(cString:newBytes!.assumingMemoryBound(to:Int8.self))
	}
	
	/// decode a base64 string to a byte array
	/// - parameter dataEncoding: the base64 string to decode
	public static func decode(_ dataEncoding:String) throws -> [UInt8] {
		let newBytes = malloc(base64_decoded_length(dataEncoding.count))
		defer {
			free(newBytes)
		}
		let decodeResult = base64_decode(newBytes, base64_decoded_length(dataEncoding.count), dataEncoding, dataEncoding.count)
		guard decodeResult >= 0 else {
			fatalError("could not decode base64 string")
		}
		return Array(unsafeUninitializedCapacity:decodeResult, initializingWith: { (buffer, count) in
			memcpy(buffer.baseAddress!, newBytes, decodeResult)
			count = decodeResult
		})
	}
}