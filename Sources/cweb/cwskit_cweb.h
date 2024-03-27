#ifndef CWSKIT_CWEB
#define CWSKIT_CWEB

#include "time.h"
#include <string.h>
#include <stdlib.h>
#include "stdint.h"
#include "cwskit_csha1.h"
#include "cwskit_types.h"
#include "cwskit_debug_deploy_guarantees.h"

/// @brief Get the error number. Swift can't access errno directly so this function is just a wrapper.
int _cwskit_geterrno();

#endif // CWSKIT_CWEB