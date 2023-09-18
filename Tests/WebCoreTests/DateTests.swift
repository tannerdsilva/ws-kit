
import XCTest
@testable import WebCore
import Foundation

final class DateTests:XCTestCase {
	func testInitMatchesFoundationDate() {
		let myDate = WebCore.Date(localTime:true)
		
		// Create a new Foundation.Date from the components, which is timezone-independent (UTC)
		let foundationDate = Foundation.Date()
		
		let myDateReferenceInterval = myDate.timeIntervalSinceReferenceDate()
		let foundationDateReferenceInterval = foundationDate.timeIntervalSinceReferenceDate

		// Assert they are approximately equal, allowing for up to 1 second difference due to init time difference
		XCTAssertEqual(myDateReferenceInterval, foundationDateReferenceInterval, accuracy: 1.0)
	}
	
	func testSubSecondPrecision() {
		let interval: Double = 0.123456789
		let myDate = WebCore.Date(unixInterval: interval)
		
		// Using Unix epoch for comparison
		let myDateUnixInterval = myDate.timeIntervalSinceUnixDate()
		
		XCTAssertEqual(myDateUnixInterval, interval, accuracy: 0.000000001)
	}
	
	func testArithmeticOperationsAtSubSecondPrecision() {
		let interval: Double = 0.54321
		let myDate = WebCore.Date(unixInterval: interval)
		
		let addedDate = myDate.addingTimeInterval(interval)
		let addedDateUnixInterval = addedDate.timeIntervalSinceUnixDate()
		
		XCTAssertEqual(addedDateUnixInterval, 978307200 + interval * 2, accuracy: 0.000000001)
	}
	
	func testRapidSuccessionDateCreation() {
		let date1 = WebCore.Date(localTime:true)
		let date2 = WebCore.Date(localTime:false)
		// Ensuring the two dates created in rapid succession have a difference
		XCTAssertTrue(abs(date1.timeIntervalSince(date2)) > 0)
	}

	func testGMTInitialization() {
		let localDate = WebCore.Date(localTime:true)
		let gmtDate = WebCore.Date(localTime:false)
		
		// Get the current GMT offset
		var Cnow = time_t()
		let loc = localtime(&Cnow).pointee
		var offset = Double(loc.tm_gmtoff)
		if loc.tm_isdst > 0 {
			offset -= 3600
		}
		
		// The difference between the two dates should be approximately equal to the GMT offset
		XCTAssertEqual(gmtDate.timeIntervalSince(localDate), offset, accuracy: 1.0)
	}

	func testCrossCompare() {
		let one = WebCore.Date(localTime:false)
		let two = WebCore.Date(localTime:false)

		XCTAssertEqual(one.timeIntervalSince(two), 0, accuracy: 1.0)
	}

	func testCrossCompare2() {
		let one = WebCore.Date(localTime:true)
		let two = WebCore.Date(localTime:true)

		XCTAssertEqual(one.timeIntervalSince(two), 0, accuracy: 1.0)
	}
}
