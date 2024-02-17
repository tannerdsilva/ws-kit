#ifndef CWSKIT_CWEB
#define CWSKIT_CWEB

#include "time.h"
#include <string.h>
#include <stdlib.h>
#include "stdint.h"
#include "csha1.h"
#include "types.h"

/// @brief Get the error number. Swift can't access errno directly so this function is just a wrapper.
int _cwskit_geterrno();

#endif // CWSKIT_CWEB