#ifndef _WSKIT_DATACHAIN_KEYED_H
#define _WSKIT_DATACHAIN_KEYED_H

#include "cwskit_types.h"
#include <sys/types.h>
#include <stdint.h>

struct _cwskit_datachainlink_keyed;

typedef struct _cwskit_datachainlink_keyed* _Nullable _cwskit_datachainlink_keyed_ptr_t;

typedef _Atomic _cwskit_datachainlink_keyed_ptr_t _cwskit_datachainlink_keyed_aptr_t;

typedef _cwskit_datachainlink_keyed_aptr_t* _Nonnull _cwskit_datachainlink_keyed_aptr_ptr_t;

typedef void (*_Nonnull _cwskit_datachainlink_keyed_ptr_dealloc_f)(const _cwskit_ptr_t);

typedef struct _cwskit_datachainlink_keyed {
	const uint64_t key;
	const _cwskit_ptr_t ptr;
	_cwskit_datachainlink_keyed_aptr_t next;
} _cwskit_datachainlink_keyed_t;

typedef struct _cwskit_datachainpair_keyed {
	_cwskit_datachainlink_keyed_aptr_ptr_t base;
	_cwskit_datachainlink_keyed_aptr_ptr_t tail;
	_Atomic uint64_t element_count;
	const _cwskit_datachainlink_keyed_ptr_dealloc_f dealloc_f;
} _cwskit_datachainpair_keyed_t;

typedef _cwskit_datachainpair_keyed_t* _Nonnull _cwskit_datachainpair_keyed_ptr_t;

// initialization and deinitialization

_cwskit_datachainpair_keyed_t _cwskit_dc_init_keyed(const _cwskit_datachainlink_keyed_ptr_dealloc_f);

void _cwskit_dc_close_keyed(const _cwskit_datachainpair_keyed_ptr_t chain);

// data handling

/// inserts a new data pointer into the chain for storage and future processing.
/// @param chain pointer to the datachain where data will be inserted.
/// @param ptr data pointer to be stored in the chain.
/// @return the unique key value associated with the data pointer.
uint64_t _cwskit_dc_pass_keyed(const _cwskit_datachainpair_keyed_ptr_t chain, const _cwskit_ptr_t ptr);

typedef void (*_Nonnull _cwskit_datachainlink_keyed_ptr_f)(const _cwskit_datachainlink_keyed_t);

bool _cwskit_dc_consume_keyed(const _cwskit_datachainpair_keyed_ptr_t chain, const _cwskit_datachainlink_keyed_ptr_f f);

#endif // _WSKIT_DATACHAIN_KEYED_H