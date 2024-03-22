#include "cwskit_datachain.h"
#include "cwskit_types.h"
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

/// internal function that initializes a chain pair.
/// - parameters:
///		- deallocator_f: the function that will be used to free the memory of the pointers in the chain.
_cwskit_datachainpair_t _cwskit_dc_init(const _cwskit_datachainlink_ptr_dealloc_f deallocator_f) {
	return (_cwskit_datachainpair_t){
		.base = NULL,
		.tail = NULL,
		.element_count = 0,
		.dealloc_f = deallocator_f
	};
}

/// internal function that closes a chain and frees all entries.
/// - parameters:
///		- chain: the chain that this operation will act on.
void _cwskit_dc_close(const _cwskit_datachainpair_ptr_t chain) {
	// load the base entry.
	_cwskit_datachainlink_ptr_t getbase = atomic_load_explicit(chain->base, memory_order_acquire);
	
	if (getbase == NULL) {
		// there are no entries to free or handle so we can return.
		return;
	} else {
		// place NULL at the base and tail so that others aren't able to manipulate the chain while we work to free it.
		atomic_store_explicit(chain->base, NULL, memory_order_release);
		atomic_store_explicit(chain->tail, NULL, memory_order_release);
	}
	
	// iterate through the chain and free all entries
	_cwskit_datachainlink_ptr_t current = getbase;
	while (current != NULL) {
		_cwskit_datachainlink_ptr_t next = atomic_load_explicit(&current->next, memory_order_acquire);
		chain->dealloc_f(current->ptr);
		free(current);
		current = next;
	}
}

// internal function that attempts to install a link in the chain.
// - parameters:
//		- chain: the chain that this operation will act on.
//		- link: the link that will be installed into the chain.
// - returns: true if the install was successful and the element count could be incremented. false if the install was not successful.
bool _cwskit_dc_pass_link(const _cwskit_datachainpair_ptr_t chain, const _cwskit_datachainlink_ptr_t link) {
	// defines the value that we expect to find on the element we will append to...
	_cwskit_datachainlink_ptr_t expected = NULL;
	// load the current tail entry. it may exist, or it may not.
	_cwskit_datachainlink_ptr_t gettail = atomic_load_explicit(chain->tail, memory_order_acquire);

	// determine where to try and write the new entry based on whether or not there is a tail entry.
	_cwskit_datachainlink_aptr_t*_Nonnull writeptr;
	if (gettail == NULL) {
		writeptr = chain->tail;
	} else {
		writeptr = &gettail->next;
	}

	// attempt to write the new entry to the chain.
	bool storeResult = atomic_compare_exchange_strong_explicit(writeptr, &expected, link, memory_order_release, memory_order_acquire);
	if (storeResult == true) {
		// update the base and tail pointers based on how the store was applied.
		if (gettail == NULL) {
			atomic_store_explicit(chain->base, link, memory_order_release);
		} else {
			atomic_store_explicit(chain->tail, link, memory_order_release);
		}

		// increment the atomic count to reflect the new entry.
		atomic_fetch_add_explicit(&chain->element_count, 1, memory_order_acq_rel);
	}
	return storeResult;
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
	} while (current == false);
}

/// internal function that flushes a single writerchain entry.
/// - parameters:
///		- preloaded_atomic_base: the pre-loaded atomic base pointer of the chain.
///		- chain: the chain that this operation will act on.
///		- consumed_ptr: the pointer that will be set to the consumed pointer.
/// - returns: true if the operation was successful and the element count could be decremented. false if the operation was not successful.
bool _cwskit_dc_consume_next(_cwskit_datachainlink_ptr_t preloaded_atomic_base, const _cwskit_datachainpair_ptr_t chain, _cwskit_ptr_t *consumed_ptr) {
	// load the next entry from the base.
	_cwskit_datachainlink_ptr_t next = atomic_load_explicit(&preloaded_atomic_base->next, memory_order_acquire);
	
	bool success = false;
	if (next == NULL) {
		// we are currently processing the last entry in the chain, meaning it was stored at both the base and tail. swap the base and then write the tail unconditionally if successful.
		success = atomic_compare_exchange_strong_explicit(chain->base, &preloaded_atomic_base, NULL, memory_order_release, memory_order_relaxed);
		if (success == true) {
			atomic_store_explicit(chain->tail, NULL, memory_order_release);
		}
	} else {
		// there is at least one more entry in the chain, so we can just update the base pointer.
		success = atomic_compare_exchange_strong_explicit(chain->base, &preloaded_atomic_base, next, memory_order_release, memory_order_relaxed);
	}

	if (success == true) {
		// decrement the atomic count to reflect the new entry.
		atomic_fetch_sub_explicit(&chain->element_count, 1, memory_order_acq_rel);
		*consumed_ptr = preloaded_atomic_base->ptr;
		free((void*)preloaded_atomic_base);
	}
	return success;
}

/// user function that allows a user to consume a pointer from the chain for processing.
/// - parameters:
///		- chain: the chain that this operation will act on.
///		- consumer_f: the function that will be used to consume the pointer.
bool _cwskit_dc_consume(const _cwskit_datachainpair_ptr_t chain, const _cwskit_datachainlink_ptr_consume_f consumer_f) {
	// load the base entry.
	bool consume_success = false;
	_cwskit_ptr_t consumed;
	do {
		consume_success = _cwskit_dc_consume_next(atomic_load_explicit(chain->base, memory_order_acquire), chain, &consumed);
	} while (consume_success == false && atomic_load_explicit(&chain->element_count, memory_order_acquire) > 0);
	if (consume_success == true) {
		consumer_f(consumed);
		chain->dealloc_f(consumed);
	}
	return consume_success;
}
