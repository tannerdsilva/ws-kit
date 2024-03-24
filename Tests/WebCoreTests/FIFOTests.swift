import XCTest
@testable import WebCore

final class FifoTests: XCTestCase {

    // Test pushing and then popping data to ensure FIFO behavior
    func testPushAndPop() {
        let dataSequence = FIFO<[UInt8]>()
        let testData: [UInt8] = [1, 2, 3, 4, 5]
        dataSequence.push(testData)

        let poppedData = dataSequence.pop()
        XCTAssertEqual(poppedData, testData, "Popped data should match the pushed data")
    }
    
    // Test popping from an empty FIFO should return nil
    func testPopEmptyFifo() {
        let dataSequence = FIFO<[UInt8]>()
        let poppedData = dataSequence.pop()
        XCTAssertNil(poppedData, "Popping from an empty FIFO should return nil")
    }
    
    // Test the FIFO order is maintained with multiple push and pop operations
    func testFifoOrder() {
        let dataSequence = FIFO<[UInt8]>()
        let testData1: [UInt8] = [1, 2]
        let testData2: [UInt8] = [3, 4]
        
        dataSequence.push(testData1)
        dataSequence.push(testData2)
        
        XCTAssertEqual(dataSequence.pop(), testData1, "First popped data should match the first pushed data")
        XCTAssertEqual(dataSequence.pop(), testData2, "Second popped data should match the second pushed data")
		XCTAssertNil(dataSequence.pop(), "Popping from an empty FIFO should return nil")
    }

    // Test pushing and popping with large data sets
    func testLargeData() {
        let dataSequence = FIFO<[UInt8]>()

		var testAgaaint = [[UInt8]]()
        for i in 0..<1000 {
			let testData: [UInt8] = // random bytes
				(0..<100).map { _ in UInt8.random(in: 0...255) }
			dataSequence.push(testData)
			testAgaaint.append(testData)
		}
		for i in 0..<1000 {
			XCTAssertEqual(dataSequence.pop(), testAgaaint[i], "Popped data should match the pushed data")
		}
    }
}