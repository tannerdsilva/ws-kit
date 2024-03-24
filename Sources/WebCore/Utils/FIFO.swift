import cweb

public class FIFO<T>:AsyncSequence {
    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(dataSequence:self)
    }

	struct Continuation {
		private let fifo:FIFO<T>
		private let continuation:UnsafeContinuation<T?, Never>
		internal init(fifo:FIFO<T>, continuation:UnsafeContinuation<T?, Never>) {
			self.fifo = fifo
			self.continuation = continuation
		}
		internal func resume() {
			continuation.resume(returning:fifo.pop())
		}
	
	}

	// public func makeContinuation() -> Continuation {

	// }

    public class AsyncIterator:AsyncIteratorProtocol {
		private let dataSequence:FIFO<T>
		internal init(dataSequence:consuming FIFO<T>) {
			self.dataSequence = dataSequence
		}
		public func next() async -> T? {
			return await withTaskCancellationHandler(operation: {
				return self.dataSequence.pop()
			}, onCancel: {
				// nothing to do
			})
		}
	}

    public typealias Element = T

	private var fifo = _cwskit_dc_init()
	private class Contained {
		private let store:T
		internal init(store:consuming T) {
			self.store = store
		}
		internal consuming func takeStored() -> T {
			return store
		}
	}

	public func push(_ data:T) {
		_cwskit_dc_pass(&fifo, Unmanaged.passRetained(Contained(store:data)).toOpaque())
	}

	internal func pop() -> T? {
		switch (_cwskit_dc_consume(&fifo)) {
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

	deinit {
		_cwskit_dc_close(&fifo)
	}
}