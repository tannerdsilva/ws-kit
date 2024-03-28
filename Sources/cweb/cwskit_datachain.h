#ifndef _WSKIT_DATACHAIN_H
#define _WSKIT_DATACHAIN_H

#include "cwskit_types.h"
#include <sys/types.h>
#include <pthread.h>

/// forward declaration of the datachain link structure. represents a single link in a sequential chain of data elements.
struct _cwskit_datachainlink;
/// defines a nullable pointer to a datachain link structure, allowing for the construction of linked chains.
typedef struct _cwskit_datachainlink* _Nullable _cwskit_datachainlink_ptr_t;
/// defines an atomic version of `_cwskit_datachainlink_ptr_t` to ensure thread-safe manipulation of the datachain links.
typedef _Atomic _cwskit_datachainlink_ptr_t _cwskit_datachainlink_aptr_t;
/// function prototype for consuming data from the chain. does not free the memory of the consumed pointer.
typedef void (^_Nonnull _cwskit_datachainlink_ptr_consume_f)(const _cwskit_ptr_t);

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
	_cwskit_datachainlink_aptr_t base;
	/// pointer to the tail of the chain, enabling efficient addition of new elements.
	_cwskit_datachainlink_aptr_t tail;
	
	/// atomic counter representing the number of elements in the chain.
	_Atomic uint64_t element_count;

	/// atomic boolean flag indicating whether blocking is enabled on the chain.
	_Atomic bool _is_capped;
	/// atomic pointer to the cap pointer, which is the final element in the chain.
	_Atomic _cwskit_optr_t _cap_ptr;

	/// the condition variable used for blocking on the chain when no data is available.
	pthread_cond_t cond;
	/// pthread_cond_t dependent mutex for the condition variable.
	pthread_mutex_t mutex;
} _cwskit_datachainpair_t;

/// defines a non-null pointer to a datachain pair structure, facilitating operations on the entire chain.
typedef _cwskit_datachainpair_t*_Nonnull _cwskit_datachainpair_ptr_t;

// initialization and deinitialization

/// initializes a new datachain pair, setting up the structure for use.
/// @return initialized datachain pair structure.
_cwskit_datachainpair_t _cwskit_dc_init();

/// deinitializes a datachain, freeing all associated memory and resources.
/// @param chain pointer to the datachain to be deinitialized.
/// @param deallocator_f function used for deallocating memory of data pointers.
/// @return the deallocated cap pointer if the chain was capped; NULL if the chain was not capped.
_cwskit_optr_t _cwskit_dc_close(const _cwskit_datachainpair_ptr_t chain, const _cwskit_datachainlink_ptr_consume_f deallocator_f);

// data handling

/// cap off the datachain with a final element. any elements passed into the chain after capping it off will be stored and handled by the deallocator when this instance is closed (they will not be passed to a consumer).
/// @param chain pointer to the datachain to be capped.
/// @param ptr pointer to the final element to be added to the chain.
/// @return true if the cap pointer was successfully added; false if the cap could not be added.
bool _cwskit_dc_pass_cap(const _cwskit_datachainpair_ptr_t chain, const _cwskit_optr_t ptr);

/// inserts a new data pointer into the chain for storage and future processing. if the chain is capped, the data will be stored and handled by the deallocator when this instance is closed (it will not be passed to a consumer).
/// @param chain pointer to the datachain where data will be inserted.
/// @param ptr data pointer to be stored in the chain.
void _cwskit_dc_pass(const _cwskit_datachainpair_ptr_t chain, const _cwskit_ptr_t ptr);

/// blocks the current thread until a new fifo item is available or the chain becomes capped.
void _cwskit_dc_block_thread(const _cwskit_datachainpair_ptr_t chain);

/// returns the next item in the chain. if no items are remaining and the chain is capped, the cap pointer will be returned (not for consumption, leave in memory). if no items are remaining and the chain is not capped, the function will block until an item is available (if specified by argument).
/// @param chain pointer to the datachain to consume from.
/// @param consumed_ptr pointer to the consumed data pointer, if any.
/// @return 0 if the function was successful and `consumed_ptr` was assigned to the next fifo entry to consume (consider this the last time you'll see this pointer - deallocate apropriately); -1 if the function would block
int8_t _cwskit_dc_consume_nonblocking(const _cwskit_datachainpair_ptr_t chain, _cwskit_optr_t*_Nonnull consumed_ptr);

#endif // _WSKIT_DATACHAIN_H