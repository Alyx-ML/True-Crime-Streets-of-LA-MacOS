#ifndef TC_TLS_H
#define TC_TLS_H
#include "tc_sse.h"

/* Shared by CPUs in one guest process; destroy only after its threads stop. */
struct tc_tls_process *tc_tls_create(void);
void tc_tls_destroy(struct tc_tls_process *process);
uint32_t tc_tls_alloc(tc_cpu *cpu);
int tc_tls_free(tc_cpu *cpu, uint32_t index);
uint32_t tc_tls_get(tc_cpu *cpu, uint32_t index);
int tc_tls_set(tc_cpu *cpu, uint32_t index, uint32_t value);
#endif
