#ifndef CWEB
#define CWEB

#include "time.h"
#include <string.h>
#include <stdlib.h>
#include "stdint.h"
#include "csha1.h"

/// @brief Get the error number. Swift can't access errno directly so this function is just a wrapper.
int _cwskit_geterrno();

/// optional pointer type.
typedef void*_Nullable _cwskit_optr_t;

/// nonoptional pointer type.
typedef void*_Nonnull _cwskit_ptr_t;

#endif // CWEB