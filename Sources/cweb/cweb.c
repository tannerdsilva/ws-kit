#include "include/cweb.h"

#include <stdio.h>
#include <errno.h>

int geterrno() {
	return errno;
}