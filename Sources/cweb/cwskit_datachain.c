#include "cwskit_datachain.h"
#include "cwskit_types.h"
#include <pthread/pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/_pthread/_pthread_cond_t.h>

/// internal function that initializes a chain pair.
/// - parameters:
///		- deallocator_f: the function that will be used to free the memory of the pointers in the chain.
_cwskit_datachainpair_t _cwskit_dc_init() {
	_cwskit_datachainpair_t chain = {
		.base = NULL,
		.tail = NULL,
		.element_count = 0,
		._is_capped = false,
	};
	pthread_cond_init(&chain.cond, NULL);
	pthread_mutex_init(&chain.mutex, NULL);
	return chain;
}

bool _cwskit_can_issue_continuation(const _cwskit_datachainpair_deploy_guarantees_ptr_t deploys) {
	if (atomic_load_explicit(&deploys->is_continuation_issued, memory_order_acquire) == false) {
		atomic_store_explicit(&deploys->is_continuation_issued, true, memory_order_release);
		return true;
	} else {
		return false;
	}
}
bool _cwskit_can_issue_consumer(const _cwskit_datachainpair_deploy_guarantees_ptr_t deploys) {
	if (atomic_load_explicit(&deploys->is_consumer_issued, memory_order_acquire) == false) {
		atomic_store_explicit(&deploys->is_consumer_issued, true, memory_order_release);
		return true;
	} else {
		return false;
	}
}

_cwskit_optr_t _cwskit_dc_close(const _cwskit_datachainpair_ptr_t chain, const _cwskit_datachainlink_ptr_consume_f deallocator_f) {
	// load the base entry.
	_cwskit_datachainlink_ptr_t current = atomic_load_explicit(&chain->base, memory_order_acquire);
	
	// place NULL at the base and tail so that others aren't able to manipulate the chain while we work to free it.
	atomic_store_explicit(&chain->base, NULL, memory_order_release);
	atomic_store_explicit(&chain->tail, NULL, memory_order_release);
	
	// iterate through the chain and free all entries
	while (current != NULL) {
		_cwskit_datachainlink_ptr_t next = atomic_load_explicit(&current->next, memory_order_acquire);
		deallocator_f(current->ptr);
		free(current);
		current = next;
	}

	pthread_cond_destroy(&chain->cond);
	pthread_mutex_destroy(&chain->mutex);

	if (atomic_load_explicit(&chain->_is_capped, memory_order_acquire) == true) {
		return atomic_load_explicit(&chain->_cap_ptr, memory_order_acquire);
	} else {
		return NULL;
	}
}

bool _cwskit_dc_pass_cap(const _cwskit_datachainpair_ptr_t chain, const _cwskit_optr_t ptr) {
	bool expected_cap = false;	// we expect the chain to NOT be capped
	bool apply_success;			// this is where the result of the atomic operation will be stored.
	do {
		// attempt to apply the cap to the chain until it succeeds or someone beats us to it.
		apply_success = atomic_compare_exchange_weak_explicit(&chain->_is_capped, &expected_cap, true, memory_order_release, memory_order_acquire);
	} while (__builtin_expect(apply_success == false && expected_cap == false, false));
	if (__builtin_expect(apply_success == true, true)) {
		// successfully capped. now assign the capper pointer and store the number of remaining elements in the fifo.
		atomic_store_explicit(&chain->_cap_ptr, ptr, memory_order_release);
		pthread_cond_signal(&chain->cond);
	}
	return apply_success;
}

// internal function that attempts to install a link in the chain. this function does not care about the cap state of the chain and does not increment the element count.
// - returns: true if the install was successful. false if the install was not successful.
bool _cwskit_dc_pass_link(const _cwskit_datachainpair_ptr_t chain, const _cwskit_datachainlink_ptr_t link) {
	// defines the value that we expect to find on the element we will append to...
	_cwskit_datachainlink_ptr_t expected = NULL;
	// load the current tail entry. it may exist, or it may not.
	void* myvarl = chain->tail;
	_cwskit_datachainlink_ptr_t gettail = atomic_load_explicit(&chain->tail, memory_order_acquire);

	// determine where to try and write the new entry based on whether or not there is a tail entry.
	_cwskit_datachainlink_aptr_t*_Nonnull writeptr;
	_cwskit_datachainlink_aptr_t*_Nonnull secondptr;
	if (gettail == NULL) {
		writeptr = &chain->tail;
		secondptr = &chain->base;
	} else {
		writeptr = &gettail->next;
		secondptr = &chain->tail;
	}

	// attempt to write the new entry to the chain.
	if (__builtin_expect(atomic_compare_exchange_weak_explicit(writeptr, &expected, link, memory_order_release, memory_order_acquire), true)) {
		// swap successful, now write the secondary pointer if necessary.
		atomic_store_explicit(secondptr, link, memory_order_release);
		return true;
	} else {
		return false;
	}
}

/// user function that allows a user to pass a pointer to into the chain for processing.
/// - parameters:
///		- chain: the chain that this operation will act on.
///		- ptr: the pointer that will be passed into the chain for storage.
void _cwskit_dc_pass(const _cwskit_datachainpair_ptr_t chain, const _cwskit_ptr_t ptr) {
	const struct _cwskit_datachainlink link_on_stack = {
		.ptr = ptr,
		.next = NULL
	};
	const _cwskit_datachainlink_ptr_t link_on_heap = memcpy(malloc(sizeof(link_on_stack)), &link_on_stack, sizeof(link_on_stack));
	bool current = false;
	do {
		current = _cwskit_dc_pass_link(chain, link_on_heap);
	} while (__builtin_expect(current == false, false));
	if (__builtin_expect(atomic_load_explicit(&chain->_is_capped, memory_order_acquire) == false, true)) {
		// the chain is not capped so we must increment the element count.
		atomic_fetch_add_explicit(&chain->element_count, 1, memory_order_acq_rel);
		pthread_cond_signal(&chain->cond);
	}
}

/// internal function that flushes a single writerchain entry.
/// - parameters:
///		- preloaded_atomic_base: the pre-loaded atomic base pointer of the chain.
///		- chain: the chain that this operation will act on.
///		- consumed_ptr: the pointer that will be set to the consumed pointer.
/// - returns: true if the operation was successful and the element count could be decremented. false if the operation was not successful.
bool _cwskit_dc_consume_next(_cwskit_datachainlink_ptr_t preloaded_atomic_base, const _cwskit_datachainpair_ptr_t chain, _cwskit_ptr_t *_Nonnull consumed_ptr) {
	if (__builtin_expect(preloaded_atomic_base == NULL, false)) {
		// there are no entries to consume.
		return false;
	}

	// load the next entry from the base.
	_cwskit_datachainlink_ptr_t next = atomic_load_explicit(&preloaded_atomic_base->next, memory_order_acquire);

	// attempt to pop the next entry from the chain by replacing the current base with the next entry.
	if (__builtin_expect(atomic_compare_exchange_weak_explicit(&chain->base, &preloaded_atomic_base, next, memory_order_release, memory_order_relaxed), true)) {
		// successfully popped
		if (next == NULL) {
			// there are no more entries in the chain. write the tail to NULL to reflect this.
			atomic_store_explicit(&chain->tail, NULL, memory_order_release);
		}
		// decrement the atomic count to reflect the entry being consumed.
		atomic_fetch_sub_explicit(&chain->element_count, 1, memory_order_acq_rel);
		*consumed_ptr = preloaded_atomic_base->ptr;
		free((void*)preloaded_atomic_base);
		return true;
	}
	return false;
}

/// @return 0 if the operation was successful and a normal fifo element was consumed. 1 if the operation resulted in the cap element being returned. -1 if the operation would block.
int8_t _cwskit_dc_consume(const _cwskit_datachainpair_ptr_t chain, const bool try_blocking, _cwskit_optr_t*_Nonnull consumed_ptr) {

	// attempt to consume the next element while there are elements waiting in the chain.
	while (atomic_load_explicit(&chain->element_count, memory_order_acquire) > 0) {
		// attempt to consume the next entry in the chain.
		if (_cwskit_dc_consume_next(atomic_load_explicit(&chain->base, memory_order_acquire), chain, consumed_ptr)) {
			return 0; // normal fifo element
		}
	}

	// there are no more fifo elements to consume.
	
	// check if the chain is capped.
	bool is_capped = atomic_load_explicit(&chain->_is_capped, memory_order_acquire);
	if (__builtin_expect(is_capped == false, true)){
		// the chain is not capped. we can try and block if the user has requested it.
		if (try_blocking) {

			// block until a new element is available or the chain is capped.
			pthread_mutex_lock(&chain->mutex);
			bool next_result;
			do {
				// block for condition
				pthread_cond_wait(&chain->cond, &chain->mutex);

				// acquire all variables to evaluate conditions.
				next_result = _cwskit_dc_consume_next(atomic_load_explicit(&chain->base, memory_order_acquire), chain, consumed_ptr);
				is_capped = atomic_load_explicit(&chain->_is_capped, memory_order_acquire);
			} while (next_result == false && is_capped == false); 
			pthread_mutex_unlock(&chain->mutex);
			
			// at this point, either _cwskit_dc_consume_next was successful, or the chain is capped.
			
			if (is_capped == true) {
				*consumed_ptr = atomic_load_explicit(&chain->_cap_ptr, memory_order_acquire);
				return 1; // cap element
			} else {
				return 0; // normal fifo element
			}
		} else {
			return -1; // would block
		}
	} else {
		// the chain is capped. return the cap pointer.
		*consumed_ptr = atomic_load_explicit(&chain->_cap_ptr, memory_order_acquire);
		return 1; // cap element
	}
}