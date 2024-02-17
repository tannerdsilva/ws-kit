#include "include/cweb.h"
#include "include/datachain.h"
#include <stdio.h>
#include <errno.h>

int _cwskit_geterrno() {
	return errno;
}