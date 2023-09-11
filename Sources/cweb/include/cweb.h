#ifndef CWEB
#define CWEB

#include "base64.h"
#include "time.h"

/// @brief Get the error number. Swift can't access errno directly so this function is just a wrapper.
int geterrno();

#endif // CWEB