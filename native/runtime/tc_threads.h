#ifndef TC_THREADS_H
#define TC_THREADS_H
#include "tc_sse.h"
struct tc_threads *tc_threads_create(struct tc_heap_process *heaps);
/* Destroy only after all workers have returned. */
void tc_threads_destroy(struct tc_threads *threads);
void tc_threads_main_returned(struct tc_threads *threads,uint32_t exit_code);
int tc_threads_active(struct tc_threads *threads);
int tc_thread_close(tc_cpu *cpu,uint32_t handle);
void tc_duplicate_handle(_cpu *cpu);
void tc_thread_create(_cpu *cpu);
void tc_thread_priority(_cpu *cpu);
void tc_thread_resume(_cpu *cpu);
void tc_thread_exit_code(_cpu *cpu);
void tc_current_thread_handle(_cpu *cpu);
void tc_current_process_handle(_cpu *cpu);
#endif
