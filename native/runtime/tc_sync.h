#ifndef TC_SYNC_H
#define TC_SYNC_H
#include "tc_sse.h"
struct tc_sync_process *tc_sync_create(void);
/* All guest threads must have stopped and released their locks. */
void tc_sync_destroy(struct tc_sync_process *process);
void tc_critical_initialize(_cpu *cpu);
void tc_critical_enter(_cpu *cpu);
void tc_critical_leave(_cpu *cpu);
void tc_critical_delete(_cpu *cpu);
void tc_interlocked_exchange(_cpu *cpu);
#endif
