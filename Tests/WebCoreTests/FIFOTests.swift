import XCTest
@testable import WebCore

final class FifoTests: XCTestCase {

    // Test pushing and then popping data to ensure FIFO behavior
    func testPushAndPop() async throws {
        let dataSequence = FIFO<[UInt8]>()
        let testData: [UInt8] = [1, 2, 3, 4, 5]
        dataSequence.push(testData)
		let seq = dataSequence.makeAsyncIterator()
        let poppedData = try await seq.next()
        XCTAssertEqual(poppedData, testData, "Popped data should match the pushed data")
    }

    // Test the FIFO order is maintained with multiple push and pop operations
    func testFifoOrder() async throws {
        let dataSequence = FIFO<[UInt8]>()
        let testData1: [UInt8] = [1, 2]
        let testData2: [UInt8] = [3, 4]
        
        dataSequence.push(testData1)
        dataSequence.push(testData2)

		let seq = dataSequence.makeAsyncIterator()
		let td1 = try await seq.next()
		let td2 = try await seq.next()
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

		let consumer = dataSequence.makeAsyncIterator()
		let td1 = try await consumer.next()
		let td2 = try await consumer.next()
		let td3 = try await consumer.next()
        
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

		let seq = dataSequence.makeAsyncIterator()
		let td1 = try await seq.next()
		let td2 = try await seq.next()
		let td3:[UInt8]?
		do {
			td3 = try await seq.next()
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
		let fifoSequence = dataSequence.makeAsyncIterator()
		for i in testAgaaint {
			let poppedData = try await fifoSequence.next()
			XCTAssertEqual(poppedData, i, "Popped data should match the pushed data")
		}
    }

	func testBlockingForFirstElement() async throws {
		let returnResult = try await withThrowingTaskGroup(of:Void.self) { tg in
			let fifo = FIFO<Int>()
			let expectedItem = 42
			tg.addTask {
				fifo.push(expectedItem)
				fifo.finish()
			}
			var i = 0
			for try await item in fifo {
				i += 1
				XCTAssertEqual(item, expectedItem)
			}
			XCTAssertEqual(i, 1)
			try await tg.waitForAll()
			return true
		}
		XCTAssertEqual(returnResult, true)
	}



	// // Test the behavior of AsyncStream2 with one consumer
    func testComplexConsumption() async throws {
        let consumerCount = 12
        let expectedData = 42

		try await withThrowingTaskGroup(of:Void.self) { tg in
			let stream = AsyncStream<Int>()
			for _ in 0..<consumerCount {
				tg.addTask { [consumer = stream.makeAsyncIterator()] in
					var i = 0
					while let data = try await consumer.next() {
						XCTAssertEqual(data, expectedData, "Consumer should receive the expected data")
						i += 1
					}
					XCTAssertEqual(i, 1, "Consumer should receive the expected data")
				}
			}
			
			tg.addTask {
				stream.yield(expectedData)
				stream.finish()
			}
			try await tg.waitForAll()
		}
    }

    // // Test the behavior of AsyncStream2 with multiple consumers
    // func testMultipleConsumers() async throws {
    //     let stream = AsyncStream2<Int>()
    //     let consumerCount = 5
    //     let expectedData = 42

    //     for _ in 0..<consumerCount {
    //         Task { [consumer = stream.makeAsyncIterator()] in
    //             while let data = try await consumer.next() {
    //                 XCTAssertEqual(data, expectedData, "Consumer should receive the expected data")
    //             }
    //         }
    //     }

    //     Task {
	// 		stream.yield(expectedData)
    //         // for _ in 0..<consumerCount {
    //         //     stream.yield(expectedData)
    //         // }
    //         stream.finish()
    //     }

    //     await Task.sleep(1) // Wait for the tasks to complete
    // }

	func testInsertAndRemove() {
		let atomicList = AtomicList<Int>()
		
		let key1 = atomicList.insert(1)
		let key2 = atomicList.insert(2)
		let key3 = atomicList.insert(3)
		
		XCTAssertEqual(atomicList.remove(key1), 1, "Removed value should match the inserted value")
		XCTAssertEqual(atomicList.remove(key2), 2, "Removed value should match the inserted value")
		XCTAssertEqual(atomicList.remove(key3), 3, "Removed value should match the inserted value")
		XCTAssertNil(atomicList.remove(key1), "Removing a non-existent key should return nil")
	}
	
	func testForEach() {
		let atomicList = AtomicList<String>()
		
		atomicList.insert("Apple")
		atomicList.insert("Banana")
		atomicList.insert("Orange")
		
		var result = Set<String>()
		atomicList.forEach { _, value in
			result.update(with:value)
		}
		
		XCTAssertEqual(result, ["Apple", "Banana", "Orange"], "ForEach should iterate over all inserted values")
	}
}