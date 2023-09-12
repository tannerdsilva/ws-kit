import cweb

/// returns a ``time_t`` struct representing the reference date for this Date type.
/// **NOTE**: the reference date is 00:00:00 UTC on 1 January 2001.
fileprivate func systemReferenceDate() -> time_t {
	var timeStruct = tm()
	memset(&timeStruct, 0, MemoryLayout<tm>.size)
	timeStruct.tm_mday = 1
	timeStruct.tm_mon = 0
	timeStruct.tm_year = 101
	return mktime(&timeStruct)
}
internal let refDate = systemReferenceDate()

/// returns a ``time_t`` struct representing the reference date for this Date type.
/// **NOTE**: the reference date is 00:00:00 UTC on 1 January 1970.
fileprivate func encodingReferenceDate() -> time_t {
	var timeStruct = tm()
	memset(&timeStruct, 0, MemoryLayout<tm>.size)
	timeStruct.tm_mday = 1
	timeStruct.tm_mon = 0
	timeStruct.tm_year = 70
	return mktime(&timeStruct)
}
internal let encDate = encodingReferenceDate()

@frozen public struct Date:Sendable {
	/// the primitive value of this instance.
	/// represents the seconds elapsed since `00:00:00` UTC on 1 January 1970
	private let rawVal:Double

	public init(localTime:Bool) {
		var ts = timespec()
		clock_gettime(CLOCK_REALTIME, &ts)
		let seconds = Double(ts.tv_sec)
		let nanoseconds = Double(ts.tv_nsec)
		let total_time = seconds + (nanoseconds / 1_000_000_000)
		switch localTime {
			case false:
				var Cnow = time_t()
				let loc = localtime(&Cnow).pointee
				var offset = Double(loc.tm_gmtoff)
				// correct for daylight savings time if it is in effect
				if loc.tm_isdst > 0 {
					offset += 3600
				}
				
				self.rawVal = (total_time + offset)
			case true:
				self.rawVal = total_time
		}
	}

	// /// initialize with the current time
	// public init(localTime:Bool) {
		
	// 	var makeTime = time_t()
	// 	time(&makeTime)
	// 	let gmt = gmtime(&makeTime)!
	// 	gmt.pointee.tm_isdst = 0
	// 	makeTime = timegm(gmt)

	// 	var Cnow = time_t()
	// 	let loc = localtime(&Cnow).pointee
	// 	var offset = Double(loc.tm_gmtoff)

	// 	switch localTime {
	// 		case false:
	// 			self.rawVal = (difftime(makeTime, encDate)) * 1_000_000_000
	// 		case true:
	// 			if loc.tm_isdst > 0 {
	// 				offset += 3600
	// 			}
	// 			self.rawVal = (difftime(makeTime, encDate) - offset) * 1_000_000_000
	// 	}
	// }

	/// Initialize with a Unix epoch interval (seconds since 00:00:00 UTC on 1 January 1970)
	public init(unixInterval:Double) {
		rawVal = unixInterval * 1_000_000_000
	}

	/// Basic initializer based on the primitive (seconds since 00:00:00 UTC on 1 January 1970)
	public init(referenceInterval:Double) {
		self.rawVal = (referenceInterval + 978307200) * 1_000_000_000
	}

	/// Returns the difference in time between the called instance and passed date
	public func timeIntervalSince(_ other:Self) -> Double {
		return (self.rawVal - other.rawVal) / 1_000_000_000
	}

	/// Returns a new value that is the sum of the current value and the passed interval
	public func addingTimeInterval(_ interval:Double) -> Self {
		return Self(referenceInterval:(self.rawVal + interval * 1_000_000_000) / 1_000_000_000)
	}

	/// Returns the time interval since Unix date
	public func timeIntervalSinceUnixDate() -> Double {
		return self.rawVal / 1_000_000_000
	}

	/// Returns the time interval since the reference date (00:00:00 UTC on 1 January 2001)
	public func timeIntervalSinceReferenceDate() -> Double {
		return self.rawVal / 1_000_000_000 - 978307200
	}
}
