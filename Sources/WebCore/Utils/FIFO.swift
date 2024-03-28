import cweb

public struct AsyncStream<T>:AsyncSequence {
	public typealias Element = T
	public final class AsyncIterator:AsyncIteratorProtocol {
		public func next() async throws -> T? {
			return try await fifo.next()
		}

		public typealias Element = T

		private let key:UInt64
		private let fifo:FIFO<T>.AsyncIterator
		private let al:AtomicList<FIFO<T>.Continuation>
		internal init(al:AtomicList<FIFO<T>.Continuation>, fifo:FIFO<T>) {
			self.key = al.insert(fifo.makeContinuation())
			self.fifo = fifo.makeAsyncIterator()
			self.al = al
		}
		deinit {
			_ = al.remove(key)
		}
	}
	public func makeAsyncIterator() -> AsyncIterator {
		return AsyncIterator(al:al, fifo: FIFO<T>())
	}
	private let al = AtomicList<FIFO<T>.Continuation>()

	public init() {}

	public func yield(_ data:T) {
		al.forEach({ _, continuation in
			continuation.push(data)
		})
	}

	public func finish() {
		al.forEach({ _, continuation in
			continuation.finish()
		})
	}

	public func finish(throwing:Swift.Error) {
		al.forEach({ _, continuation in
			continuation.finish(throwing:throwing)
		})
	}
}

internal final class AtomicList<T>:@unchecked Sendable {
	private var list_store = _cwskit_al_init_keyed()
	deinit {
		_cwskit_al_close_keyed(&list_store, { key, ptr in
			Unmanaged<Contained>.fromOpaque(ptr).release()
		})
	}

	internal init() {}

	private final class Contained {
		private let store:T
		internal init(store:T) {
			self.store = store
		}
		internal func takeStored() -> T {
			return store
		}
	}

	internal func forEach(_ body:@escaping (UInt64, T) -> Void) {
		_cwskit_al_iterate(&list_store, { key, ptr in
			let um = Unmanaged<Contained>.fromOpaque(ptr).retain()
			defer {
				um.release()
			}
			body(key, um.takeUnretainedValue().takeStored())
		})
	}

	internal func insert(_ data:T) -> UInt64 {
		return _cwskit_al_insert(&list_store, Unmanaged.passRetained(Contained(store:data)).toOpaque())
	}

	@discardableResult internal func remove(_ key:UInt64) -> T? {
		switch (_cwskit_al_remove(&list_store, key)) {
			case .some(let contained):
				return Unmanaged<Contained>.fromOpaque(contained).takeRetainedValue().takeStored()
			case .none:
				return nil
		}
	}
}

public final class FIFO<T>:AsyncSequence, @unchecked Sendable {
	#if DEBUG
	private var deployInfo = _cwskit_datachainpair_deploy_guarantees_t()
	#endif
	public func makeAsyncIterator() -> AsyncIterator {
		#if DEBUG
		guard _cwskit_can_issue_consumer(&deployInfo) == true else {
			fatalError("fifo class cannot have multiple consumers")
		}
		#endif
		return AsyncIterator(dataSequence:copy self)
	}

	public func makeContinuation() -> Continuation {
		#if DEBUG
		guard _cwskit_can_issue_continuation(&deployInfo) == true else {
			fatalError("fifo class cannot have multiple producers")
		}
		#endif
		return Continuation(dataSequence:copy self)
	}

	public struct AsyncIterator:AsyncIteratorProtocol {
		private let dataSequence:FIFO<T>
		internal init(dataSequence:FIFO<T>) {
			self.dataSequence = dataSequence
		}
		public func next() async throws -> T? {
			repeat {
				switch dataSequence._pop_internal_sync() {
					case .cappedError(let error):
						throw error
					case .cappedNil:
						return nil
					case .fifo(let item):
						return item
					case .wouldBlock:
						await withUnsafeContinuation({
							_cwskit_dc_block_thread(&dataSequence.fifo)
							$0.resume()
						})
				}
			} while true
		}
	}

	public struct Continuation {
		private let dataSequence:FIFO<T>
		internal init(dataSequence:FIFO<T>) {
			self.dataSequence = dataSequence
		}
		public func push(_ data:T) {
			dataSequence.push(data)
		}
		public func finish() {
			dataSequence.finish()
		}
		public func finish(throwing:Swift.Error) {
			dataSequence.finish(throwing:throwing)
		}
	} 

	public typealias Element = T

	private var fifo = _cwskit_dc_init()
	private final class Contained {
		private let store:T
		internal init(store:T) {
			self.store = store
		}
		internal func takeStored() -> T {
			return store
		}
	}
	private final class ContainedError {
		private let storedError:Swift.Error
		internal init(_ err:Swift.Error) {
			self.storedError = err
		}
		internal func takeError() -> Swift.Error {
			return storedError
		}
	}

	internal func push(_ data:T) {
		_cwskit_dc_pass(&fifo, Unmanaged.passRetained(Contained(store:data)).toOpaque())
	}

	private enum _pop_internal_sync_result {
		case wouldBlock
		case fifo(T)
		case cappedError(Swift.Error)
		case cappedNil
	}
	private func _pop_internal_sync() -> _pop_internal_sync_result {
		// handles a fifo pointer from the c library
		func scenarioFIFO(_ op:UnsafeRawPointer) -> T {
			let op = Unmanaged<Contained>.fromOpaque(op)
			defer {
				op.release()
			}
			return op.takeUnretainedValue().takeStored()
		}
		// handles a cap pointer from the c library
		func scenarioCap(_ op:UnsafeRawPointer) -> Swift.Error {
			let op = Unmanaged<ContainedError>.fromOpaque(op).retain()
			defer {
				op.release()
			}
			return op.takeUnretainedValue().takeError()
		}

		var cptr:_cwskit_optr_t? = nil

		// consume the next item without blocking
		switch _cwskit_dc_consume_nonblocking(&fifo, &cptr) {
			case -1: // would block - try again in a continuation if the task is not currently cancelled
				return .wouldBlock
			case 0: // normal fifo - we are responsible for releasing the memory
				switch cptr {
					case .some(let ptr):
						return .fifo(scenarioFIFO(ptr))
					case .none:
						fatalError("_cwskit_dc_consume returned a normal fifo exit code but nil ptr was encountered")
				}
			case 1: // the chain is capped. in this case, we do not release the error from memory - the capper item is released on deinit
				switch cptr {
					case .some(let ptr): // the chain was capped with a pointer, this is an error
						return .cappedError(scenarioCap(ptr))
					case .none: // the chain was capped with a nil pointer, this is a normal exit
						return .cappedNil
				}
			default:
				// no code should ever take us here
				fatalError("unknown return code from _cwskit_dc_consume")
		}
	}

	internal func finish(throwing:Swift.Error) {
		// unbalanced retain on the error - it is released in deinit
		let um = Unmanaged.passRetained(ContainedError(throwing))
		guard _cwskit_dc_pass_cap(&fifo, um.toOpaque()) == true else {
			um.release()
			return
		}
	}

	internal func finish() {
		// no need to account for success here since the passed pointer is nil
		_ = _cwskit_dc_pass_cap(&fifo, nil)
	}

	deinit {
		switch (_cwskit_dc_close(&fifo, { ptr in
			// release a fifo item that wsa passed after it was capped
			Unmanaged<Contained>.fromOpaque(ptr).release()
		})) {
			case .some(let ptr):
				// release the capping error
				Unmanaged<ContainedError>.fromOpaque(ptr).release()
			case .none:
				break
		}
	}
}