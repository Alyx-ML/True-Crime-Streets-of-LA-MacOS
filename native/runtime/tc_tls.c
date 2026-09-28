#include "tc_tls.h"
#include <pthread.h>
#include <stdlib.h>

struct tc_tls_process {
    /* ponytail: one process mutex serializes TLS calls; split allocation and
       value synchronization if measured contention warrants it. */
    pthread_mutex_t mutex;
    uint64_t generation[TC_TLS_SLOTS];
    unsigned char allocated[TC_TLS_SLOTS];
};

struct tc_tls_process *tc_tls_create(void)
{
    struct tc_tls_process *process = calloc(1, sizeof(*process));
    if (!process) return NULL;
    if (pthread_mutex_init(&process->mutex, NULL)) { free(process); return NULL; }
    return process;
}

void tc_tls_destroy(struct tc_tls_process *process)
{
    if (!process) return;
    if (pthread_mutex_destroy(&process->mutex)) abort();
    free(process);
}

static struct tc_tls_process *lock(tc_cpu *cpu)
{
    if (!cpu || !cpu->tls_process || pthread_mutex_lock(&cpu->tls_process->mutex)) abort();
    return cpu->tls_process;
}

static void unlock(struct tc_tls_process *process)
{
    if (pthread_mutex_unlock(&process->mutex)) abort();
}

uint32_t tc_tls_alloc(tc_cpu *cpu)
{
    struct tc_tls_process *process = lock(cpu);
    for (uint32_t index = 0; index < TC_TLS_SLOTS; ++index) {
        if (!process->allocated[index]) {
            if (process->generation[index] == UINT64_MAX) abort();
            ++process->generation[index];
            process->allocated[index] = 1;
            unlock(process);
            return index;
        }
    }
    unlock(process);
    tc_write_fs(&cpu->scalar, 0x34, 8); /* ERROR_NOT_ENOUGH_MEMORY */
    return UINT32_MAX;
}

int tc_tls_free(tc_cpu *cpu, uint32_t index)
{
    struct tc_tls_process *process = lock(cpu);
    int valid = index < TC_TLS_SLOTS && process->allocated[index];
    if (valid) process->allocated[index] = 0;
    unlock(process);
    if (!valid) tc_write_fs(&cpu->scalar, 0x34, 87); /* ERROR_INVALID_PARAMETER */
    return valid;
}

uint32_t tc_tls_get(tc_cpu *cpu, uint32_t index)
{
    struct tc_tls_process *process = lock(cpu);
    uint32_t value = 0;
    if (index < TC_TLS_SLOTS && cpu->tls_generation[index] == process->generation[index])
        value = cpu->tls_value[index];
    unlock(process);
    tc_write_fs(&cpu->scalar, 0x34, index < TC_TLS_SLOTS ? 0 : 87);
    return value;
}

int tc_tls_set(tc_cpu *cpu, uint32_t index, uint32_t value)
{
    struct tc_tls_process *process = lock(cpu);
    if (index < TC_TLS_SLOTS) {
        cpu->tls_generation[index] = process->generation[index];
        cpu->tls_value[index] = value;
    }
    unlock(process);
    if (index >= TC_TLS_SLOTS) tc_write_fs(&cpu->scalar, 0x34, 87);
    return index < TC_TLS_SLOTS;
}

#ifdef TC_TLS_SELF_CHECK
#include <assert.h>
int main(void)
{
    unsigned char memory[128] = {0};
    tc_cpu a = {0}, b = {0};
    a.scalar._pointer_offset = b.scalar._pointer_offset = (uintptr_t)memory;
    a.memory_size = b.memory_size = sizeof(memory);
    a.fs_base = 4;
    b.fs_base = 64;
    a.fs_size = b.fs_size = 56;
    a.tls_process = b.tls_process = tc_tls_create();
    assert(a.tls_process);
    uint32_t index = tc_tls_alloc(&a);
    assert(index != UINT32_MAX && tc_tls_get(&b, index) == 0);
    assert(tc_tls_set(&a, index, 123) && tc_tls_set(&b, index, 456));
    assert(tc_tls_get(&a, index) == 123 && tc_tls_get(&b, index) == 456);
    assert(tc_tls_free(&a, index) && tc_tls_alloc(&b) == index);
    assert(tc_tls_get(&a, index) == 0 && tc_tls_get(&b, index) == 0);
    assert(!tc_tls_set(&a, TC_TLS_SLOTS, 1) && tc_read_fs(&a.scalar, 0x34) == 87);
    assert(tc_tls_get(&a, index) == 0 && tc_read_fs(&a.scalar, 0x34) == 0);
    tc_tls_destroy(a.tls_process);
    return 0;
}
#endif
