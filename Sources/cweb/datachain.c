#include "datachain.h"
#include <stdatomic.h>
#include <stdbool.h>

_cwskit_datachainpair_t _cwskit_dc_init(const _cwskit_datachainlink_ptr_dealloc_f deallocator_f) {
	_cwskit_datachainpair_t newpair = {
		.base = NULL,
		.tail = NULL,
		.element_count = 0,
		.dealloc_f = deallocator_f
	};
	return newpair;
}

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
// - returns: true if the install was successful and the element count could be incremented. false if the install was not successful.
bool _cwskit_dc_pass_link(const _cwskit_datachainpair_ptr_t chain, const _cwskit_datachainlink_ptr_t link) {
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

void _cwskit_dc_move_next(const _cwskit_datachainlink_ptr_t preloaded_atomic_base, const _cwskit_datachainpair_ptr_t chain, const _cwskit_datachainlink_ptr_dealloc_f deallocator_f) {
	// load the base entry.
	_cwskit_datachainlink_ptr_t next = atomic_load_explicit(&preloaded_atomic_base->next, memory_order_acquire);
	
	// update the base and tail pointers based on how the store was applied to the chain.
	if (next == NULL) {
		atomic_store_explicit(chain->tail, NULL, memory_order_release);
	} else {
		atomic_store_explicit(chain->base, next, memory_order_release);
	}

	// decrement the atomic count to reflect the new entry.
	atomic_fetch_sub_explicit(&chain->element_count, 1, memory_order_acq_rel);

	// deallocate the current entry.
	deallocator_f((void*)preloaded_atomic_base->ptr);
	free((void*)preloaded_atomic_base);
}