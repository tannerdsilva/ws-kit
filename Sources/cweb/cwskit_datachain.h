#ifndef _WSKIT_DATACHAIN_H
#define _WSKIT_DATACHAIN_H

#include "cwskit_types.h"
#include <sys/types.h>

/// datachain link structure. this is a forward declaration. think of this as a single link in a chain of events.
struct _cwskit_datachainlink;

/// a nullable pointer to a datachain structure.
typedef struct _cwskit_datachainlink*_Nullable _cwskit_datachainlink_ptr_t;

/// an atomic ``_cwskit_datachainlink_ptr_t``
typedef _Atomic _cwskit_datachainlink_ptr_t _cwskit_datachainlink_aptr_t;

/// a non-null pointer to a ``_cwskit_datachainlink_aptr_t``
typedef _cwskit_datachainlink_aptr_t*_Nonnull _cwskit_datachainlink_aptr_ptr_t;

/// a function type that deallocates memory for a datachainlink.
typedef void(*_Nonnull _cwskit_datachainlink_ptr_dealloc_f)(_cwskit_ptr_t);

/// single chain link.
typedef struct _cwskit_datachainlink {
	/// the data item that this chain item is holding
	const _cwskit_ptr_t ptr;
	/// the next chain item in the list.
	_cwskit_datachainlink_aptr_t next;
} _cwskit_datachainlink_t;

/// the "pair" that allows the entire expanse of chain links to be storable and accessible
typedef struct _cwskit_datachainpair {
	/// the element base of the chain
	_cwskit_datachainlink_aptr_ptr_t base;
	/// the element tail of the chain
	_cwskit_datachainlink_aptr_ptr_t tail;
	/// the number of elements in the chain
	_Atomic uint64_t element_count;
	/// the deallocator function that will free memory at the specified pointers when needed.
	const _cwskit_datachainlink_ptr_dealloc_f dealloc_f;
} _cwskit_datachainpair_t;

typedef _cwskit_datachainpair_t*_Nonnull _cwskit_datachainpair_ptr_t;


// MARK: init and deinit

/// initializes a new datachainpair.
/// returns: new datachainpair structure to use.
_cwskit_datachainpair_t _cwskit_dc_init(const _cwskit_datachainlink_ptr_dealloc_f);

/// deinitialize a datachain and any of the contents that may be within it.
/// - parameters:
///		- chain: a pointer to the chain that this operation will act on.
///		- deallocator_f: the deallocator function that will free memory at the specified pointers when needed.
void _cwskit_dc_close(const _cwskit_datachainpair_ptr_t chain);


// MARK: passing data in
/// passes a pointer to be stored into the data chain.
void _cwskit_dc_pass(const _cwskit_datachainpair_ptr_t chain, const _cwskit_ptr_t ptr);

typedef void(^_Nonnull _cwskit_datachainlink_ptr_consume_f)(_cwskit_ptr_t);

/// consume the next item in the chain.
/// - parameters:
///		- chain: the chain that this operation will act on.
///		- consumer_f: the function that will consume the data from the chain.
/// - returns: true if the consumer function was called, false if the datachain is empty and nothing could be consumed.
bool _cwskit_dc_consume(const _cwskit_datachainpair_ptr_t chain, const _cwskit_datachainlink_ptr_consume_f);

#endif // _WSKIT_DATACHAIN_H
