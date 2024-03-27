import XCTest
@testable import WebCore

final class FifoTests: XCTestCase {

    // Test pushing and then popping data to ensure FIFO behavior
    func testPushAndPop() async throws {
        let dataSequence = FIFO<[UInt8]>()
        let testData: [UInt8] = [1, 2, 3, 4, 5]
        dataSequence.push(testData)

        let poppedData = try await dataSequence.pop()
        XCTAssertEqual(poppedData, testData, "Popped data should match the pushed data")
    }

    // Test the FIFO order is maintained with multiple push and pop operations
    func testFifoOrder() async throws {
        let dataSequence = FIFO<[UInt8]>()
        let testData1: [UInt8] = [1, 2]
        let testData2: [UInt8] = [3, 4]
        
        dataSequence.push(testData1)
        dataSequence.push(testData2)

		let td1 = try await dataSequence.pop()
		let td2 = try await dataSequence.pop()
		// let td3 = await dataSequence.pop()
        
        XCTAssertEqual(td1, testData1, "First popped data should match the first pushed data")
        XCTAssertEqual(td2, testData2, "Second popped data should match the second pushed data")
		// XCTAssertNil(dataSequence.pop(), "Popping from an empty FIFO should return nil")
    }

	 func testFinishVoid() async throws {
        let dataSequence = FIFO<[UInt8]>()
        let testData1: [UInt8] = [1, 2]
        let testData2: [UInt8] = [3, 4]
        
        dataSequence.push(testData1)
        dataSequence.push(testData2)
		dataSequence.finish()

		let td1 = try await dataSequence.pop()
		let td2 = try await dataSequence.pop()
		let td3 = try await dataSequence.pop()
        
        XCTAssertEqual(td1, testData1, "First popped data should match the first pushed data")
        XCTAssertEqual(td2, testData2, "Second popped data should match the second pushed data")
		XCTAssertNil(td3, "Popping from an empty FIFO should return nil")
    }

	func testFinishThrowingCancellationError() async throws {
		let dataSequence = FIFO<[UInt8]>()
		let testData1: [UInt8] = [1, 2]
		let testData2: [UInt8] = [3, 4]
		
		dataSequence.push(testData1)
		dataSequence.push(testData2)
		dataSequence.finish(throwing:CancellationError())

		let td1 = try await dataSequence.pop()
		let td2 = try await dataSequence.pop()
		let td3:[UInt8]?
		do {
			td3 = try await dataSequence.pop()
		} catch is CancellationError {
			td3 = nil
		}
		

		XCTAssertEqual(td1, testData1, "First popped data should match the first pushed data")
		XCTAssertEqual(td2, testData2, "Second popped data should match the second pushed data")
		XCTAssertNil(td3, "Popping from an empty FIFO should return nil")
	}

    // Test pushing and popping with large data sets
    func testLargeData() async throws {
        let dataSequence = FIFO<[UInt8]>()

		var testAgaaint = [[UInt8]]()
        for _ in 0..<1000 {
			let testData: [UInt8] = // random bytes
				(0..<100).map { _ in UInt8.random(in: 0...255) }
			dataSequence.push(testData)
			testAgaaint.append(testData)
		}
		for i in 0..<1000 {
			let poppedData = try await dataSequence.pop()
			XCTAssertEqual(poppedData, testAgaaint[i], "Popped data should match the pushed data")
		}
    }
}