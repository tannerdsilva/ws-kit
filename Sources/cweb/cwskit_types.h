#ifndef CWSKIT_TYPES
#define CWSKIT_TYPES
#include <stdint.h>
#include <stdbool.h>

/// optional pointer type.
typedef void*_Nullable _cwskit_optr_t;

/// nonoptional pointer type.
typedef void*_Nonnull _cwskit_ptr_t;

/// optional pointer to a boolean value.
typedef bool*_Nullable _cwskit_bool_optr_t;

typedef uint64_t*_Nonnull _cwskit_uint64_ptr_t;

#endif