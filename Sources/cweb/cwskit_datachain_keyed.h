#ifndef _WSKIT_DATACHAIN_KEYED_H
#define _WSKIT_DATACHAIN_KEYED_H

#include "cwskit_types.h"
#include <sys/types.h>
#include <stdint.h>

/// forward declaration of the atomiclist structure. represents a single element in the atomic list.
struct _cwskit_atomiclist_keyed;
/// defines a nullable pointer to a single element in the atomic list.
typedef struct _cwskit_atomiclist_keyed* _Nullable _cwskit_atomiclist_keyed_ptr_t;
/// defines an atomic pointer to a single element in the atomic list.
typedef _Atomic _cwskit_atomiclist_keyed_ptr_t _cwskit_atomiclist_keyed_aptr_t;
/// defines a non-null pointer to an atomic pointer to a single element in the atomic list.
typedef _cwskit_atomiclist_keyed_aptr_t* _Nonnull _cwskit_atomiclist_keyed_aptr_ptr_t;
/// defines a function prototype for deallocating memory of the stored pointers.
typedef void (*_Nonnull _cwskit_atomiclist_keyed_ptr_dealloc_f)(const _cwskit_ptr_t);

/// structure representing a single element within the atomic list.
typedef struct _cwskit_atomiclist_keyed {
	/// the unique key value associated with the data pointer.
	const uint64_t key;
	/// the data pointer that the element instance is storing.
	const _cwskit_ptr_t ptr;
	/// the next element in the atomic list.
	_cwskit_atomiclist_keyed_aptr_t next;
} _cwskit_atomiclist_keyed_t;

/// primary storage container for the atomic list.
typedef struct _cwskit_atomiclistpair_keyed {
	/// the base storage slot for the list instance.
	_cwskit_atomiclist_keyed_aptr_t base;
	/// the tail of the list, used for efficient addition of new elements.
	_Atomic size_t element_count;
	/// an internal value that increments with each new item added. this essentially represents the "next item's key"
	_Atomic uint64_t _id_increment_internal;
	/// function pointer for deallocating memory of the stored pointers.
	const _cwskit_atomiclist_keyed_ptr_dealloc_f dealloc_f;
	/// callers that are removing fron the atomic list will increment this value (from zero to one) to ensure that each new item has a unique key. consumers will decrement this value from zero to any n number of readers. appending is allowed regardless of the value of this variable.
	_Atomic int16_t _mutation_delta;
} _cwskit_atomiclistpair_keyed_t;

/// defines a non-null pointer to an atomic list pair.
typedef _cwskit_atomiclistpair_keyed_t*_Nonnull _cwskit_atomiclistpair_keyed_ptr_t;

// initialization and deinitialization.

/// initializes a new atomic list pair instance.
/// @param dealloc_f function pointer for deallocating memory of the stored pointers.
/// @return a new atomic list pair instance. this instance must be deallocated with ``_cwskit_al_close_keyed``
_cwskit_atomiclistpair_keyed_t _cwskit_al_init_keyed(const _cwskit_atomiclist_keyed_ptr_dealloc_f dealloc_f);

/// deallocates memory of the atomic list pair instance. any remaining elements in the list will be deallocated.
/// @param list pointer to the atomic list pair instance to be deallocated.
bool _cwskit_al_close_keyed(const _cwskit_atomiclistpair_keyed_ptr_t list);

// data handling.

/// inserts a new data pointer into the atomic list for storage and future processing.
/// @param list pointer to the atomic list pair instance.
/// @param ptr pointer to the data to be stored in the atomic list.
/// @param new_id pointer to a uint64_t that will be written to with the key value of the new element.
/// @return true if the element was successfully inserted, false if the element could not be inserted.
bool _cwskit_al_insert(const _cwskit_atomiclistpair_keyed_ptr_t list, const _cwskit_ptr_t ptr, const _cwskit_uint64_ptr_t new_id);

/// consumer function prototype for processing data pointers in the atomic list. this is essentially the "last point of contact" for the data pointer before it is passed to the deallocator.
typedef void (^_Nonnull _cwskit_atomiclist_consumer_keyed_ptr_f)(const uint64_t, const _cwskit_ptr_t);

/// removes a key (and its corresponding stored pointer) from the atomic list.
/// @param chain pointer to the atomic list pair instance.
/// @param key the key value of the element to be removed.
/// @param consumer_f function used to process the data pointer before it is deallocated.
/// @param existed pointer to a boolean value that will be written to with the result of the operation. this pointer may be nil if the result is not needed.
/// @return true if the element was removed or if the element did not exist, false if the element could not be removed and a retry is recommended.
bool _cwskit_al_remove(const _cwskit_atomiclistpair_keyed_ptr_t chain, const uint64_t key, const _cwskit_atomiclist_consumer_keyed_ptr_f consumer_f);

/// iterate through all elements in the atomic list, processing each data pointer with the provided consumer function.
/// @param list pointer to the atomic list pair instance.
/// @param consumer_f function used to process each data pointer in the atomic list.
/// @return true if the iteration was successful, false if the iteration was unsuccessful due to a mutation in progress.
bool _cwskit_al_iterate(const _cwskit_atomiclistpair_keyed_ptr_t list, const _cwskit_atomiclist_consumer_keyed_ptr_f consumer_f);

#endif // _WSKIT_DATACHAIN_KEYED_H