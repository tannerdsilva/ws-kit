import cweb

public final class AsyncStream2<T>:AsyncSequence {
	public typealias Element = T

	public final class AsyncIterator:AsyncIteratorProtocol {
		public borrowing func next() async throws -> T? {
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

	internal init() {}

	public func yield(_ data:consuming T) -> Int {
		var i = 0
		al.forEach({ _, continuation in
			i += 1
			continuation.push(data)
		})
		return i
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

internal final class AtomicList<T> {
	private var list_store = _cwskit_al_init_keyed()
	deinit {
		_cwskit_al_close_keyed(&list_store, { key, ptr in
			Unmanaged<Contained>.fromOpaque(ptr).release()
		})
	}

	internal init() {}

	private final class Contained {
		private let store:T
		internal init(store:consuming T) {
			self.store = store
		}
		internal consuming func takeStored() -> T {
			return store
		}
	}

	internal borrowing func forEach(_ body:@escaping (UInt64, T) -> Void) {
		_cwskit_al_iterate(&list_store, { key, ptr in
			let um = Unmanaged<Contained>.fromOpaque(ptr).takeUnretainedValue()
			body(key, um.takeStored())
		})
	}

	internal borrowing func insert(_ data:consuming T) -> UInt64 {
		_cwskit_al_insert(&list_store, Unmanaged.passRetained(Contained(store:data)).toOpaque())
	}

	internal borrowing func remove(_ key:UInt64) -> T? {
		switch (_cwskit_al_remove(&list_store, key)) {
			case .some(let contained):
				let um = Unmanaged<Contained>.fromOpaque(contained)
				defer {
					um.release()
				}
				return um.takeUnretainedValue().takeStored()
			case .none:
				return nil
		}
	}
}

public final class FIFO<T>:AsyncSequence, @unchecked Sendable {
	#if DEBUG
	private var deployInfo = _cwskit_datachainpair_deploy_guarantees_t()
	#endif
	public borrowing func makeAsyncIterator() -> AsyncIterator {
		#if DEBUG
		guard _cwskit_can_issue_consumer(&deployInfo) == true else {
			fatalError("fifo class cannot have multiple consumers")
		}
		#endif
		return AsyncIterator(dataSequence:copy self)
	}

	public borrowing func makeContinuation() -> Continuation {
		#if DEBUG
		guard _cwskit_can_issue_continuation(&deployInfo) == true else {
			fatalError("fifo class cannot have multiple producers")
		}
		#endif
		return Continuation(dataSequence:copy self)
	}

	public struct AsyncIterator:AsyncIteratorProtocol {
		private let dataSequence:FIFO<T>
		internal init(dataSequence:consuming FIFO<T>) {
			self.dataSequence = dataSequence
		}
		public borrowing func next() async throws -> T? {
			return try await dataSequence.pop()
		}
	}

	public struct Continuation {
		private let dataSequence:FIFO<T>
		internal init(dataSequence:consuming FIFO<T>) {
			self.dataSequence = dataSequence
		}
		public borrowing func push(_ data:consuming T) {
			dataSequence.push(data)
		}
		public borrowing func finish() {
			dataSequence.finish()
		}
		public borrowing func finish(throwing:Swift.Error) {
			dataSequence.finish(throwing:throwing)
		}
	} 

	public typealias Element = T

	private var fifo = _cwskit_dc_init()
	private final class Contained {
		private let store:T
		internal init(store:consuming T) {
			self.store = store
		}
		internal consuming func takeStored() -> T {
			return store
		}
	}
	private final class ContainedError {
		private let storedError:Swift.Error
		internal init(_ err:consuming Swift.Error) {
			self.storedError = err
		}
		internal consuming func takeError() -> Swift.Error {
			return storedError
		}
	}

	internal borrowing func push(_ data:consuming T) {
		_cwskit_dc_pass(&fifo, Unmanaged.passRetained(Contained(store:data)).toOpaque())
	}
	internal borrowing func pop() async throws -> T? {
		// handles a fifo pointer from the c library
		func scenarioFIFO(_ op:UnsafeRawPointer) -> T {
			let um = Unmanaged<Contained>.fromOpaque(op)
			defer {
				um.release()
			}
			return um.takeUnretainedValue().takeStored()
		}
		// handles a cap pointer from the c library
		func scenarioCap(_ op:UnsafeRawPointer) -> Swift.Error {
			let um = Unmanaged<ContainedError>.fromOpaque(op)
			return um.takeUnretainedValue().takeError()
		}

		var cptr:_cwskit_optr_t? = nil

		// consume the next item without blocking
		switch _cwskit_dc_consume(&fifo, false, &cptr) {
			case -1: // would block - try again in a continuation if the task is not currently cancelled
				return try await withUnsafeThrowingContinuation({ (cont:UnsafeContinuation<T?, Swift.Error>) in
					switch _cwskit_dc_consume(&fifo, true, &cptr) {
						case -1:
							fatalError("_cwskit_dc_consume returned -1 twice in a row")
						case 0:
							return cont.resume(returning:scenarioFIFO(cptr!))
						case 1:
							switch cptr {
								case .some(let ptr):
									return cont.resume(throwing:scenarioCap(ptr))
								case .none:
									return cont.resume(returning:nil)
							}
						default:
							fatalError("unknown return code from _cwskit_dc_consume")
					}
				})
			case 0: // normal fifo - we are responsible for releasing the memory
				switch cptr {
					case .some(let ptr):
						return scenarioFIFO(ptr)
					case .none:
						fatalError("_cwskit_dc_consume returned a normal fifo exit code but nil ptr was encountered")
				}
			case 1: // the chain is capped. in this case, we do not release the error from memory - the capper item is released on deinit
				switch cptr {
					case .some(let ptr): // the chain was capped with a pointer, this is an error
						throw scenarioCap(ptr)
					case .none: // the chain was capped with a nil pointer, this is a normal exit
						return nil
				}
			default:
				// no code should ever take us here
				fatalError("unknown return code from _cwskit_dc_consume")
		}
	}

	internal borrowing func finish(throwing:Swift.Error) {
		// unbalanced retain on the error - it is released in deinit
		let um = Unmanaged.passRetained(ContainedError(throwing))
		guard _cwskit_dc_pass_cap(&fifo, um.toOpaque()) == true else {
			um.release()
			return
		}
	}

	internal borrowing func finish() {
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