#include "tc_heap.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct block { uint32_t address, capacity, size, owner; struct block *next; };
struct heap { uint32_t handle, maximum, used, fixed; struct heap *next; };
struct tc_heap_process {
    uintptr_t base;
    uint32_t capacity, next_handle;
    pthread_mutex_t mutex;
    struct block *blocks;
    struct heap *heaps;
};

static void lock(struct tc_heap_process *p) { if (!p || pthread_mutex_lock(&p->mutex)) abort(); }
static void unlock(struct tc_heap_process *p) { if (pthread_mutex_unlock(&p->mutex)) abort(); }
static struct heap *find_heap(struct tc_heap_process *p, uint32_t handle)
{
    for (struct heap *h = p->heaps; h; h = h->next) if (h->handle == handle) return h;
    return NULL;
}
static struct block *find_block(struct tc_heap_process *p, uint32_t handle, uint32_t address)
{
    for (struct block *b = p->blocks; b; b = b->next)
        if (b->owner == handle && b->address == address) return b;
    return NULL;
}
static void coalesce(struct tc_heap_process *p)
{
    for (struct block *b = p->blocks; b && b->next;) {
        if (!b->owner && !b->next->owner) {
            struct block *next = b->next;
            b->capacity += next->capacity;
            b->next = next->next;
            free(next);
        } else b = b->next;
    }
}
static uint32_t capacity(uint32_t size)
{
    if (size > UINT32_MAX - 15) return 0;
    return size ? (size + 15) & ~15u : 16;
}
struct tc_heap_process *tc_heap_process_create(uintptr_t base, uint32_t start, uint32_t size)
{
    if (!start || !size || (start & 15) || (size & 15) || size > UINT32_MAX - start ||
        base > UINTPTR_MAX - start - size) return NULL;
    struct tc_heap_process *p = calloc(1, sizeof(*p));
    struct block *b = calloc(1, sizeof(*b));
    if (!p || !b) { free(p); free(b); return NULL; }
    if (pthread_mutex_init(&p->mutex, NULL)) { free(p); free(b); return NULL; }
    p->base = base;
    p->capacity = size;
    p->next_handle = 0xe1000000u;
    p->blocks = b;
    b->address = start;
    b->capacity = size;
    return p;
}
void tc_heap_process_destroy(struct tc_heap_process *p)
{
    if (!p) return;
    while (p->blocks) { struct block *next = p->blocks->next; free(p->blocks); p->blocks = next; }
    while (p->heaps) { struct heap *next = p->heaps->next; free(p->heaps); p->heaps = next; }
    if (pthread_mutex_destroy(&p->mutex)) abort();
    free(p);
}
uint32_t tc_heap_create(struct tc_heap_process *p, uint32_t options, uint32_t initial, uint32_t maximum)
{
    /* Executable heaps and guest exception generation need separate support. */
    if (options & ~1u) abort();
    lock(p);
    uint32_t result = 0;
    uint64_t rounded_initial = ((uint64_t)(initial ? initial : 1) + 4095) & ~UINT64_C(4095);
    uint64_t rounded_maximum = ((uint64_t)maximum + 4095) & ~UINT64_C(4095);
    if (rounded_initial <= p->capacity && (!maximum || (rounded_initial <= rounded_maximum && rounded_maximum <= p->capacity)) &&
        p->next_handle != UINT32_MAX) {
        struct heap *h = calloc(1, sizeof(*h));
        if (h) {
            h->handle = p->next_handle++;
            h->maximum = maximum ? (uint32_t)rounded_maximum : p->capacity;
            h->fixed = maximum != 0;
            h->next = p->heaps;
            p->heaps = h;
            result = h->handle;
        }
    }
    unlock(p);
    return result;
}
static struct block *allocate(struct tc_heap_process *p, struct heap *h, uint32_t flags, uint32_t size)
{
    uint32_t needed = capacity(size);
    if (!needed || needed > h->maximum - h->used || (h->fixed && size >= 0x80000u)) return NULL;
    /* ponytail: first-fit list and one process lock; use size bins if measured
       allocation volume makes scanning costly. The arena never moves. */
    for (struct block *b = p->blocks; b; b = b->next) {
        if (b->owner || b->capacity < needed) continue;
        if (b->capacity > needed) {
            struct block *rest = calloc(1, sizeof(*rest));
            if (!rest) return NULL;
            rest->address = b->address + needed;
            rest->capacity = b->capacity - needed;
            rest->next = b->next;
            b->next = rest;
            b->capacity = needed;
        }
        b->owner = h->handle;
        b->size = size;
        h->used += b->capacity;
        if (flags & 8) memset((void *)(p->base + b->address), 0, size);
        return b;
    }
    return NULL;
}
uint32_t tc_heap_alloc(struct tc_heap_process *p, uint32_t handle, uint32_t flags, uint32_t size)
{
    if (flags & ~9u) abort();
    lock(p);
    struct heap *h = find_heap(p, handle);
    struct block *b = h ? allocate(p, h, flags, size) : NULL;
    uint32_t result = b ? b->address : 0;
    unlock(p);
    return result;
}
int tc_heap_free(struct tc_heap_process *p, uint32_t handle, uint32_t address)
{
    lock(p);
    struct heap *h = find_heap(p, handle);
    struct block *b = h ? find_block(p, handle, address) : NULL;
    int valid = b != NULL;
    if (b) { h->used -= b->capacity; b->owner = 0; b->size = 0; coalesce(p); }
    unlock(p);
    return valid;
}
uint32_t tc_heap_size(struct tc_heap_process *p, uint32_t handle, uint32_t address)
{
    lock(p);
    struct block *b = find_heap(p, handle) ? find_block(p, handle, address) : NULL;
    uint32_t result = b ? b->size : UINT32_MAX;
    unlock(p);
    return result;
}
int tc_heap_destroy(struct tc_heap_process *p, uint32_t handle)
{
    lock(p);
    struct heap **link = &p->heaps;
    while (*link && (*link)->handle != handle) link = &(*link)->next;
    int valid = *link != NULL;
    if (valid) {
        struct heap *h = *link;
        *link = h->next;
        free(h);
        for (struct block *b = p->blocks; b; b = b->next)
            if (b->owner == handle) { b->owner = 0; b->size = 0; }
        coalesce(p);
    }
    unlock(p);
    return valid;
}
uint32_t tc_heap_realloc(struct tc_heap_process *p, uint32_t handle, uint32_t flags, uint32_t address, uint32_t size)
{
    if (flags & ~25u) abort();
    lock(p);
    struct heap *h = find_heap(p, handle);
    struct block *b = h ? find_block(p, handle, address) : NULL;
    uint32_t result = 0, needed = capacity(size);
    if (b && needed && (!h->fixed || size < 0x80000u)) {
        uint32_t old_size = b->size;
        if (needed > b->capacity && b->next && !b->next->owner &&
            needed - b->capacity <= b->next->capacity && needed - b->capacity <= h->maximum - h->used) {
            struct block *next = b->next;
            uint32_t extra = needed - b->capacity;
            next->address += extra; next->capacity -= extra;
            h->used += extra; b->capacity = needed;
            if (!next->capacity) { b->next = next->next; free(next); }
        }
        if (needed <= b->capacity) {
            if ((flags & 8) && size > old_size) memset((void *)(p->base + address + old_size), 0, size - old_size);
            b->size = size;
            result = address;
        } else if (!(flags & 16)) {
            struct block *replacement = allocate(p, h, flags, size);
            if (replacement) {
                memcpy((void *)(p->base + replacement->address), (void *)(p->base + address), old_size < size ? old_size : size);
                result = replacement->address;
                h->used -= b->capacity; b->owner = 0; b->size = 0;
                coalesce(p);
            }
        }
    }
    unlock(p);
    return result;
}

#ifdef TC_HEAP_SELF_CHECK
#include <assert.h>
int main(void)
{
    unsigned char memory[8192] = {0};
    struct tc_heap_process *p = tc_heap_process_create((uintptr_t)memory, 16, 8176);
    assert(p);
    uint32_t h = tc_heap_create(p, 0, 16, 0);
    assert(h);
    uint32_t first = tc_heap_alloc(p, h, 8, 32), blocker = tc_heap_alloc(p, h, 0, 32);
    assert(first && blocker && tc_heap_size(p, h, first) == 32);
    for (unsigned i = 0; i < 32; ++i) { assert(memory[first + i] == 0); memory[first + i] = 42; }
    assert(tc_heap_realloc(p, h, 16, first, 96) == 0);
    assert(tc_heap_size(p, h, first) == 32 && memory[first] == 42);
    uint32_t moved = tc_heap_realloc(p, h, 8, first, 96);
    assert(moved && moved != first);
    for (unsigned i = 0; i < 96; ++i) assert(memory[moved + i] == (i < 32 ? 42 : 0));
    assert(!tc_heap_free(p, h, first));
    assert(tc_heap_free(p, h, blocker) && tc_heap_free(p, h, moved));
    assert(tc_heap_alloc(p, h, 0, 8160) == 16);
    assert(tc_heap_destroy(p, h) && !tc_heap_destroy(p, h));
    tc_heap_process_destroy(p);
    return 0;
}
#endif
