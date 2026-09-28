#ifndef TC_IMAGE_H
#define TC_IMAGE_H

#include "tc_sse.h"

typedef struct {
    tc_cpu cpu;
    uint32_t entry, stack_limit, stack_top;
} tc_image;

/* The destination must be zero-initialized. No guest code or imports execute. */
int tc_image_open(tc_image *image, const char *executable, char *error, size_t error_size);
void tc_image_close(tc_image *image);

#endif
