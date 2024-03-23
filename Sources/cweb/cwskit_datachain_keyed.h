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
	_cwskit_atomiclist_keyed_aptr_ptr_t base;
		
	/// an internal value that increments with each new item added. this essentially represents the "next item's key"
	_Atomic uint64_t _id_increment_internal;
	
	/// function pointer for deallocating memory of the stored pointers.
	const _cwskit_atomiclist_keyed_ptr_dealloc_f dealloc_f;
} _cwskit_atomiclistpair_keyed_t;

/// defines a non-null pointer to an atomic list pair.
typedef _cwskit_atomiclistpair_keyed_t*_Nonnull _cwskit_atomiclistpair_keyed_ptr_t;

// initialization and deinitialization

/// initializes a new atomic list pair instance.
/// @param dealloc_f function pointer for deallocating memory of the stored pointers.
/// @return a new atomic list pair instance. this instance must be deallocated with ``_cwskit_al_close_keyed``
_cwskit_atomiclistpair_keyed_t _cwskit_al_init_keyed(const _cwskit_atomiclist_keyed_ptr_dealloc_f dealloc_f);

/// deallocates memory of the atomic list pair instance. any remaining elements in the list will be deallocated.
/// @param list pointer to the atomic list pair instance to be deallocated.
void _cwskit_al_close_keyed(const _cwskit_atomiclistpair_keyed_ptr_t list);

// data handling

/// inserts a new data pointer into the atomic list for storage and future processing.
/// @param list pointer to the atomic list pair instance.
/// @param ptr pointer to the data to be stored in the atomic list.
/// @param new_id pointer to a uint64_t that will be written to with the key value of the new element.
/// @return true if the element was successfully inserted, false if the element could not be inserted.
bool _cwskit_al_insert(const _cwskit_atomiclistpair_keyed_ptr_t list, const _cwskit_ptr_t ptr, uint64_t *new_id);

/// consumer function prototype for processing data pointers in the atomic list. this is essentially the "last point of contact" for the data pointer before it is passed to the deallocator.
typedef void (^_Nonnull _cwskit_atomiclist_consumer_keyed_ptr_f)(const _cwskit_ptr_t);

/// removes a key (and its corresponding stored pointer) from the atomic list.
bool _cwskit_al_remove(const _cwskit_atomiclistpair_keyed_ptr_t chain, const uint64_t key, const _cwskit_atomiclist_consumer_keyed_ptr_f consume, const _cwskit_bool_optr_t existed);

#endif // _WSKIT_DATACHAIN_KEYED_H