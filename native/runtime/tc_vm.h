#ifndef TC_VM_H
#define TC_VM_H
#include <stdint.h>
#include <stddef.h>
int tc_memory_readable(uintptr_t address,size_t size);
struct tc_vm_process;
struct tc_vm_process *tc_vm_create(uintptr_t base, uint32_t start, uint32_t size);
void tc_vm_destroy(struct tc_vm_process *process);
uint32_t tc_vm_alloc(struct tc_vm_process *, uint32_t address, uint32_t size, uint32_t type, uint32_t protection, uint32_t *error);
int tc_vm_free(struct tc_vm_process *, uint32_t address, uint32_t size, uint32_t type, uint32_t *error);
int tc_vm_protect(struct tc_vm_process *, uint32_t address, uint32_t size, uint32_t protection, uint32_t *old, uint32_t *error);
#endif
