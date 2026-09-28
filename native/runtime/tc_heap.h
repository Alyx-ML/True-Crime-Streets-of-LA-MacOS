#ifndef TC_HEAP_H
#define TC_HEAP_H
#include <stdint.h>
struct tc_heap_process;
/* The caller supplies a committed, exclusively owned guest arena. */
struct tc_heap_process *tc_heap_process_create(uintptr_t base, uint32_t start, uint32_t size);
void tc_heap_process_destroy(struct tc_heap_process *process);
uint32_t tc_heap_create(struct tc_heap_process *process, uint32_t options, uint32_t initial, uint32_t maximum);
int tc_heap_destroy(struct tc_heap_process *process, uint32_t handle);
uint32_t tc_heap_alloc(struct tc_heap_process *process, uint32_t handle, uint32_t flags, uint32_t size);
uint32_t tc_heap_realloc(struct tc_heap_process *process, uint32_t handle, uint32_t flags, uint32_t address, uint32_t size);
int tc_heap_free(struct tc_heap_process *process, uint32_t handle, uint32_t address);
uint32_t tc_heap_size(struct tc_heap_process *process, uint32_t handle, uint32_t address);
#endif
