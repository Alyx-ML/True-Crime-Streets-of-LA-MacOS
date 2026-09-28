#ifndef TC_SOFTFLOAT_PLATFORM_H
#define TC_SOFTFLOAT_PLATFORM_H

/* SoftFloat's integer implementation, compiled for little-endian ARM64. */
#define LITTLEENDIAN 1
#define INLINE inline
#define SOFTFLOAT_BUILTIN_CLZ 1
#include "opts-GCC.h"

#endif
