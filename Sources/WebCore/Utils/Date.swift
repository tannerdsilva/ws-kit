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

    /// initialize with the current time
    public init() {
        var makeTime = time_t()
        time(&makeTime)
        let gmt = gmtime(&makeTime)!
        gmt.pointee.tm_isdst = 0
        makeTime = timegm(gmt)

        var Cnow = time_t()
        let loc = localtime(&Cnow).pointee
        var offset = Double(loc.tm_gmtoff)
        if loc.tm_isdst > 0 {
            offset -= 3600
        }

        self.rawVal = difftime(makeTime, encDate) - offset
    }

    /// Initialize with a Unix epoch interval (seconds since 00:00:00 UTC on 1 January 1970)
    public init(unixInterval:Double) {
        rawVal = unixInterval
    }

    /// Basic initializer based on the primitive (seconds since 00:00:00 UTC on 1 January 1970)
    public init(referenceInterval:Double) {
        self.rawVal = referenceInterval + 978307200
    }

    /// Returns the difference in time between the called instance and passed date
    public func timeIntervalSince(_ other:Self) -> Double {
        return self.rawVal - other.rawVal
    }

    /// Returns a new value that is the sum of the current value and the passed interval
    public func addingTimeInterval(_ interval:Double) -> Self {
        return Self(referenceInterval:self.rawVal + interval)
    }

    /// Returns the time interval since Unix date
    public func timeIntervalSinceUnixDate() -> Double {
        return self.rawVal
    }

    /// Returns the time interval since the reference date (00:00:00 UTC on 1 January 2001)
    public func timeIntervalSinceReferenceDate() -> Double {
        return self.rawVal - 978307200
    }
}
