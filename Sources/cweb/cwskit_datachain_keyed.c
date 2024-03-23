#include "cwskit_datachain_keyed.h"
#include "cwskit_types.h"
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

/// internal function. returns the next key that should be used for a new element in the atomic list. assumes that the returned key will be used, as such, this function steps the internal key counter for the next call.
/// @param list pointer to the atomic list pair instance.
/// @param value_out pointer to a uint64_t that will be written to with the next key value.
/// @return true if the key was successfully written to the pointer, false if the key could not be written.
bool _cwskit_al_next_key(const _cwskit_atomiclistpair_keyed_ptr_t list, uint64_t *value_out) {
	// load the existing value.
	uint64_t acquireValue = atomic_load_explicit(&list->_id_increment_internal, memory_order_acquire);
	
	// check if the integer is about to overflow
	if (__builtin_expect(acquireValue < ULLONG_MAX, true)) {
		// no overflow anticipated. increment the existing value and attempt to write it to the atomic location where this value is stored.
		if (__builtin_expect(atomic_compare_exchange_weak_explicit(&list->_id_increment_internal, &acquireValue, acquireValue + 1, memory_order_release, memory_order_acquire), true)) {
			// successful case. write the new value to the passed uint64_t pointer
			(*value_out) = acquireValue;
			return true; // successful write.
		} else {
			// unsuccessful case. write couldn't be successfully completed.
			return false; // unsuccessful write.
		}
	} else {
		// overflow anticipated. zero value or bust.
		if (__builtin_expect(atomic_compare_exchange_strong_explicit(&list->_id_increment_internal, &acquireValue, 0, memory_order_release, memory_order_acquire), true)) {
			(*value_out) = acquireValue;
			return true; // successful write.
		} else {
			return false; // unsuccessful write.
		}
	}
}

/// internal function that installs a packaged data element into the atomic list.
/// @param list pointer to the atomic list pair instance.
/// @param item pointer to the atomic list element to be installed.
/// @return true if the element was successfully installed, false if the element could not be installed.
bool _cwskit_al_insert_internal(const _cwskit_atomiclistpair_keyed_ptr_t list, const _cwskit_atomiclist_keyed_ptr_t item) {

	// load the current base
    _cwskit_atomiclist_keyed_ptr_t expectedbase = atomic_load_explicit(list->base, memory_order_acquire);
	
	// write the new item to the list
	if (__builtin_expect(atomic_compare_exchange_strong_explicit(list->base, &expectedbase, item, memory_order_release, memory_order_acquire), true)) {
		// make sure that the next item in this base correctly references the old base value
		atomic_store_explicit(&item->next, expectedbase, memory_order_release);
		return true;
	} else {
		return false;
	}
}

/// inserts a new data pointer into the atomic list for storage and future processing.
/// @param list pointer to the atomic list pair instance.
/// @param ptr pointer to the data to be stored in the atomic list.
/// @param new_id pointer to a uint64_t that will be written to with the key value of the new element.
/// @return true if the element was successfully inserted, false if the element could not be inserted.
bool _cwskit_al_insert(const _cwskit_atomiclistpair_keyed_ptr_t list, const _cwskit_ptr_t ptr, uint64_t *new_id) {
	// acquire an unused key for the new element. if this fails, return false, but we expect it to succeed.
	if (__builtin_expect(_cwskit_al_next_key(list, new_id) == false, false)) {
		return false;
	}
	// package the new item on stack memory, with the new key and the pointer to the data.
    const struct _cwskit_atomiclist_keyed link_on_stack = {
        .key = *new_id,
        .ptr = ptr,
        .next = NULL
    };
	// copy the stack memory to heap memory, and insert the heap memory into the atomic list.
    const _cwskit_atomiclist_keyed_ptr_t link_on_heap = memcpy(malloc(sizeof(link_on_stack)), &link_on_stack, sizeof(link_on_stack));
   	if (__builtin_expect(_cwskit_al_insert_internal(list, link_on_heap), true)) {
		// successful insertion
		return true;
	} else {
		// unsuccessful insertion. free the heap memory and return false.
		free(link_on_heap);
		return false;
	}
}

/// internal function that removes an element from the atomic list.
bool _cwskit_al_remove(const _cwskit_atomiclistpair_keyed_ptr_t chain, const uint64_t key, const _cwskit_atomiclist_consumer_keyed_ptr_f consumer_f, const _cwskit_bool_optr_t existed) {
    _cwskit_atomiclist_keyed_ptr_t current = atomic_load_explicit(chain->base, memory_order_acquire);
    _cwskit_atomiclist_keyed_ptr_t prev = NULL;
    while (current != NULL) {
		// load the next item of current
        _cwskit_atomiclist_keyed_ptr_t next = atomic_load_explicit(&current->next, memory_order_acquire);
		// compare the key of current
        if (current->key == key) {
			// document that the pointer existed
			if (existed != NULL) {
				(*existed) = true;
			}
			
			// remove the current item from the list
            if (__builtin_expect(atomic_compare_exchange_strong_explicit(chain->base, &current, next, memory_order_release, memory_order_relaxed), true)) {
				// remove successful. fire the consumer and handle the removal here
				consumer_f(current->ptr);
				chain->dealloc_f(current->ptr);
				free(current);
				return true;
			} else {
				return false;
			}
        }
		// increment for next iteration
        prev = current;
        current = next;
    }
    return true; // return unsuccessful removal
}
