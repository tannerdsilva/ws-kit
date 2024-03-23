#ifndef _WSKIT_DATACHAIN_H
#define _WSKIT_DATACHAIN_H

#include "cwskit_types.h"
#include <sys/types.h>

/// forward declaration of the datachain link structure. represents a single link in a sequential chain of data elements.
struct _cwskit_datachainlink;
/// defines a nullable pointer to a datachain link structure, allowing for the construction of linked chains.
typedef struct _cwskit_datachainlink* _Nullable _cwskit_datachainlink_ptr_t;
/// defines an atomic version of `_cwskit_datachainlink_ptr_t` to ensure thread-safe manipulation of the datachain links.
typedef _Atomic _cwskit_datachainlink_ptr_t _cwskit_datachainlink_aptr_t;
/// defines a non-null pointer to an atomic datachain link pointer, ensuring thread safety and non-nullability.
typedef _cwskit_datachainlink_aptr_t* _Nonnull _cwskit_datachainlink_aptr_ptr_t;
/// defines a function prototype for deallocating memory associated with a datachain link, enabling customizable cleanup logic.
typedef void (*_Nonnull _cwskit_datachainlink_ptr_dealloc_f)(const _cwskit_ptr_t);

/// structure representing a single link within the datachain, holding a data item and a pointer to the next chain item.
typedef struct _cwskit_datachainlink {
	/// the data item held by this link in the chain.
	const _cwskit_ptr_t ptr;
	/// pointer to the next item in the chain, facilitating the link structure.
	_cwskit_datachainlink_aptr_t next;
} _cwskit_datachainlink_t;

/// structure representing a pair of pointers to the head and tail of a datachain, enabling efficient management and access to the chain.
typedef struct _cwskit_datachainpair {
	/// pointer to the base (head) of the chain, serving as the entry point.
	_cwskit_datachainlink_aptr_ptr_t base;
	/// pointer to the tail of the chain, enabling efficient addition of new elements.
	_cwskit_datachainlink_aptr_ptr_t tail;
	/// atomic counter representing the number of elements in the chain.
	_Atomic uint64_t element_count;
	/// function pointer for deallocating memory of the stored pointers.
	const _cwskit_datachainlink_ptr_dealloc_f dealloc_f;
} _cwskit_datachainpair_t;

/// defines a non-null pointer to a datachain pair structure, facilitating operations on the entire chain.
typedef _cwskit_datachainpair_t* _Nonnull _cwskit_datachainpair_ptr_t;

// initialization and deinitialization

/// initializes a new datachain pair, setting up the structure for use.
/// @param deallocator_f function for deallocating memory of data pointers.
/// @return initialized datachain pair structure.
_cwskit_datachainpair_t _cwskit_dc_init(const _cwskit_datachainlink_ptr_dealloc_f);

/// deinitializes a datachain, freeing all associated memory and resources.
/// @param chain pointer to the datachain to be deinitialized.
/// @param deallocator_f function used for deallocating memory of data pointers.
void _cwskit_dc_close(const _cwskit_datachainpair_ptr_t chain);

// data handling

/// inserts a new data pointer into the chain for storage and future processing.
/// @param chain pointer to the datachain where data will be inserted.
/// @param ptr data pointer to be stored in the chain.
void _cwskit_dc_pass(const _cwskit_datachainpair_ptr_t chain, const _cwskit_ptr_t ptr);

/// function prototype for consuming data from the chain. does not free the memory of the consumed pointer.
typedef void (^_Nonnull _cwskit_datachainlink_ptr_consume_f)(const _cwskit_ptr_t);

/// consumes the next item in the chain, using the provided function to process the data.
/// @param chain pointer to the datachain to consume from.
/// @param consumer_f function used to process the consumed data.
/// @return true if a data item was consumed; false if the chain is empty and the .
bool _cwskit_dc_consume(_cwskit_datachainpair_ptr_t chain, const _cwskit_datachainlink_ptr_consume_f);

#endif // _WSKIT_DATACHAIN_H