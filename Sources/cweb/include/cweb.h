#ifndef CWEB
#define CWEB

#include "time.h"
#include <string.h>
#include <stdlib.h>

/// @brief Get the error number. Swift can't access errno directly so this function is just a wrapper.
int geterrno();

#endif // CWEB