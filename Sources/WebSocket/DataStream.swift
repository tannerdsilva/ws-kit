///// event pipeline. used to provide elements from a producing service to any number of consumers (0...n)
///// - consumers of this AsyncSequence are identified by their unique AsyncIterators. These identifier tags are used to ensure that the consumer does not miss any data between loop cycles.
///// - new subscribers will immediately receive the last element that was send through the event pipeline.
//public final actor EventPipeline<T>:AsyncSequence {
//	/// the element type that the pipeline is handling
//	public typealias Element = T
//	
//	/// the async iterator type that the event pipeline is handling
//	public typealias AsyncIterator = EventPipelineIterator
//	
//	/// used to convey the current data intake state of a given consumer.
//	fileprivate enum DataConsumptionState {
//		/// indicates that the following elements are awaiting consumption from the user.
//		case waitingConsumption([T])
//		
//		/// indicates that a consumer is currently engaged and waiting for the next produced item.
//		case waitingProduction(UnsafeContinuation<T?, Never>)
//		
//		/// there are no users waiting for elements and there are none to provide.
//		case empty
//	}
//	
//	/// used to convey the current operating mode of a ``EventPipeline<T>`` instance.
//	fileprivate enum OpMode {
//		/// normal operating mode. users may consume and wait for data as it is being produced.
//		/// - parameters:
//		///		- parameter 1: the last element that was passed through the ``EventPipeline``
//		///		- parameter 2: a dictionary containing the consumer identifiers and their current consumption states
//		case normal(T?, [UInt16:DataConsumptionState])
//		
//		/// terminated operating mode. the AsyncSequence has been terminated and cannot produce any more items.
//		case terminated
//	}
//	
//	// current operating mode of this instance
//	private var opMode:OpMode = .normal(nil, [:])
//	
//	/// initialize a new ``EventPipeline<T>`` for immediate use.
//	public init() {}
//	
//	/// returns: the latest element that the pipeline has passed. `nil` will be passed if the ``EventPipeline`` is terminated or if no items have been passed yet.
//	public func getLatestElement() -> T? {
//		switch opMode {
//			case .normal(let lastItem, _):
//				return lastItem
//			default:
//				return nil
//		}
//	}
//	
//	/// the primary AsyncIteratorProtocol implementation for the ``EventPipeline` actor. consumers are expected to hold an instance of this type for the duration of their consumption period.
//	/// - users that drop their ownership of this instance will no longer have items buffered on their behalf. by dropping this object, you are conveying that you are no longer interested in consuming from the pipeline.
//	public final class EventPipelineIterator:AsyncIteratorProtocol {
//		/// the pipeline that the iterator is taking elements from
//		private let pipeline:EventPipeline
//		
//		/// the element type that this iterator handles
//		public typealias Element = T
//		
//		// the UID that this instance is using to identify itself as a consumer
//		private let myID:UInt16
//		
//		/// initialize a new pipeline iterator for immediate use.
//		internal init(_ pipeline:EventPipeline) {
//			self.myID = UInt16.random(in:0...UInt16.max)
//			self.pipeline = pipeline
//		}
//		
//		/// wait for the next entry in the pipeline
//		public func next() async -> T? {
//			return await pipeline.waitForNext(myID)
//		}
//		
//		// use deinit as the trigger to tell the pipeline to disable buffering for our ID (do no store elements that will never be consumed/removed)
//		deinit {
//			Task.detached { [pip = pipeline, id = myID] in
//				await pip.removeWaiter(id)
//			}
//		}
//	}
//	
//	/// returns the pipeline back to its initial state without the need to initialize a new one.
//	/// - NOTE: this function will throw a fatalError if it is called while operating in a non-finished state.
//	public func reset() {
//		switch opMode {
//			case .normal():
//				fatalError("cannot call reset while in opmode normal")
//			case .terminated:
//				opMode = .normal(nil, [:])
//		}
//	}
//	
//	/// passes a new element into the pipeline for consumers to receive and handle as necessary.
//	public func pass(_ element:T) {
//		switch opMode {
//			// normal operating mode. handle each of the waiters.
//			case .normal(_, var waiters):
//				// loop through each waiter
//				for (curID, curState) in waiters {
//				
//					switch curState {
//					
//						case .waitingConsumption(var buffer):
//							// there are existing items also waiting for consumption. add this element to the back of the list.
//							buffer.append(element)
//							waiters[curID] = .waitingConsumption(buffer)
//							
//						case .waitingProduction(let cont):
//							// the user is waiting for this element. pass it to the continuation and mark the UID as empty (since the user will no longer be waiting and we will have no elements to pass)
//							cont.resume(returning:element)
//							waiters[curID] = .empty
//							
//						case .empty:
//							// the buffer is empty. add this element as the first entry in the buffer for consumption.
//							waiters[id] = .waitingConsumption([element])
//					}
//				}
//				self.opMode = .normal(element, waiters)
//			default:
//				return
//		}
//	}
//	
//	
//}