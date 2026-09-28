#include "tc_vm.h"
#include <pthread.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

/* A readability snapshot only; another thread can change protections later. */
int tc_memory_readable(uintptr_t address,size_t size) {
    if(!size)return 1;
    if(!address||size>UINTPTR_MAX-address)return 0;
    mach_vm_address_t cursor=address,end=address+size;
    while(cursor<end) {
        mach_vm_address_t region=cursor;mach_vm_size_t length=0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object=MACH_PORT_NULL;
        kern_return_t result=mach_vm_region(mach_task_self(),&region,&length,VM_REGION_BASIC_INFO_64,
            (vm_region_info_t)&info,&count,&object);
        if(MACH_PORT_VALID(object))mach_port_deallocate(mach_task_self(),object);
        if(result!=KERN_SUCCESS||region>cursor||!length||length>UINT64_MAX-region||
            region+length<=cursor||!(info.protection&VM_PROT_READ))return 0;
        cursor=region+length;
    }
    return 1;
}

#define PAGE 4096u
#define GRANULARITY 65536u
struct region { uint32_t address, size; unsigned char *protection; struct region *next; };
/* ponytail: one process lock and a linear region list; use an interval map if
 * allocation count makes lookup or contention material. */
struct tc_vm_process { uintptr_t base; uint32_t start, size, host_page; pthread_mutex_t mutex; struct region *regions; };
static void lock(struct tc_vm_process *p) { if (!p || pthread_mutex_lock(&p->mutex)) abort(); }
static void unlock(struct tc_vm_process *p) { if (pthread_mutex_unlock(&p->mutex)) abort(); }
static uint64_t round_up(uint64_t value, uint32_t alignment) { return (value + alignment - 1) & ~((uint64_t)alignment - 1); }
static int host_protection(uint32_t protection)
{
    switch (protection) {
    case 1: return PROT_NONE;
    case 2: return PROT_READ;
    case 4: return PROT_READ | PROT_WRITE;
    default: return -1; /* Guard, executable and cache-control pages need further support. */
    }
}
static struct region *containing(struct tc_vm_process *p, uint32_t address, uint64_t end)
{
    for (struct region *r = p->regions; r; r = r->next)
        if (address >= r->address && end <= (uint64_t)r->address + r->size) return r;
    return NULL;
}
static int reset(struct tc_vm_process *p, uint32_t address, uint32_t size)
{
    void *target = (void *)(p->base + address);
    return mmap(target, size, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0) != MAP_FAILED;
}
struct tc_vm_process *tc_vm_create(uintptr_t base, uint32_t start, uint32_t size)
{
    long page = sysconf(_SC_PAGESIZE);
    if (page < PAGE || page > GRANULARITY || (page & (page - 1)) || !start || !size ||
        start % GRANULARITY || size % GRANULARITY || size > UINT32_MAX - start ||
        base > UINTPTR_MAX - start - size) return NULL;
    struct tc_vm_process *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    if (pthread_mutex_init(&p->mutex, NULL)) { free(p); return NULL; }
    p->base = base; p->start = start; p->size = size; p->host_page = (uint32_t)page;
    return p;
}
void tc_vm_destroy(struct tc_vm_process *p)
{
    if (!p) return;
    while (p->regions) { struct region *next = p->regions->next; free(p->regions->protection); free(p->regions); p->regions = next; }
    if (pthread_mutex_destroy(&p->mutex)) abort();
    free(p); /* The image owner releases the guest mapping after all CPUs stop. */
}
uint32_t tc_vm_alloc(struct tc_vm_process *p, uint32_t address, uint32_t size, uint32_t type, uint32_t protection, uint32_t *error)
{
    *error = 87;
    if (!size || !(type & 0x3000) || (type & ~0x3000u)) return 0;
    int host = host_protection(protection);
    if (host < 0) { *error = 50; return 0; }
    lock(p);
    uint32_t result = 0;
    int reserve = (type & 0x2000) || !address;
    uint64_t start = address & ~(uint64_t)(reserve ? GRANULARITY - 1 : PAGE - 1);
    uint64_t end = round_up((uint64_t)address + size, PAGE);
    struct region *r = NULL;
    if (reserve) {
        uint64_t length = address ? end - start : round_up(size, PAGE);
        if (!address) {
            start = p->start;
            for (struct region *it = p->regions; it; it = it->next) {
                if (start + length <= it->address) break;
                start = round_up((uint64_t)it->address + it->size, GRANULARITY);
            }
            end = start + length;
        }
        *error = 487;
        if (start < p->start || end > (uint64_t)p->start + p->size || end <= start) goto done;
        struct region **position = &p->regions;
        while (*position && (*position)->address < start) {
            if ((uint64_t)(*position)->address + (*position)->size > start) goto done;
            position = &(*position)->next;
        }
        if (*position && end > (*position)->address) goto done;
        if ((type & 0x1000) && (start % p->host_page || (end - start) % p->host_page)) { *error = 50; goto done; }
        r = calloc(1, sizeof(*r));
        if (r) r->protection = calloc((end - start) / PAGE, 1);
        if (!r || !r->protection) { free(r); *error = 8; goto done; }
        r->address = (uint32_t)start; r->size = (uint32_t)(end - start);
        if ((type & 0x1000) && mprotect((void *)(p->base + start), r->size, host)) {
            free(r->protection); free(r); *error = 8; goto done;
        }
        if (type & 0x1000) memset(r->protection, protection, r->size / PAGE);
        r->next = *position; *position = r;
    } else {
        *error = 487;
        r = containing(p, (uint32_t)start, end);
        if (!r) goto done;
        /* Do not silently make neighboring 4 KiB guest pages accessible on
           a 16 KiB host. Sub-host-page protection requires instrumented access. */
        if (start % p->host_page || (end - start) % p->host_page) { *error = 50; goto done; }
        if (mprotect((void *)(p->base + start), end - start, host)) { *error = 8; goto done; }
        memset(r->protection + (start - r->address) / PAGE, protection, (end - start) / PAGE);
    }
    result = (uint32_t)start;
    *error = 0;
done:
    unlock(p);
    return result;
}
int tc_vm_free(struct tc_vm_process *p, uint32_t address, uint32_t size, uint32_t type, uint32_t *error)
{
    *error = 87;
    if (type != 0x8000 && type != 0x4000) return 0;
    lock(p);
    int result = 0;
    uint32_t start = address & ~(PAGE - 1);
    uint64_t end = round_up((uint64_t)address + size, PAGE);
    struct region *r = containing(p, start, size ? end : (uint64_t)start + 1);
    *error = 487;
    if (!r) goto done;
    if (type == 0x8000 || !size) {
        if (address != r->address || (type == 0x8000 && size)) { *error = 87; goto done; }
        start = r->address;
        end = (uint64_t)start + r->size;
    }
    if (type == 0x4000 && (start % p->host_page || (end - start) % p->host_page)) { *error = 50; goto done; }
    uint32_t length = (uint32_t)round_up(end - start, p->host_page);
    if (!reset(p, start, length)) { *error = 8; goto done; }
    if (type == 0x8000) {
        struct region **link = &p->regions;
        while (*link != r) link = &(*link)->next;
        *link = r->next; free(r->protection); free(r);
    } else memset(r->protection + (start - r->address) / PAGE, 0, (end - start) / PAGE);
    result = 1; *error = 0;
done:
    unlock(p);
    return result;
}
int tc_vm_protect(struct tc_vm_process *p, uint32_t address, uint32_t size, uint32_t protection, uint32_t *old, uint32_t *error)
{
    *error = 87;
    if (!size || !old) return 0;
    int host = host_protection(protection);
    if (host < 0) { *error = 50; return 0; }
    lock(p);
    int result = 0;
    uint32_t start = address & ~(PAGE - 1);
    uint64_t end = round_up((uint64_t)address + size, PAGE);
    struct region *r = containing(p, start, end);
    *error = 487;
    if (!r) goto done;
    if (start % p->host_page || (end - start) % p->host_page) { *error = 50; goto done; }
    uint32_t first = (start - r->address) / PAGE, count = (uint32_t)(end - start) / PAGE;
    for (uint32_t i = 0; i < count; ++i) if (!r->protection[first + i]) goto done;
    if (mprotect((void *)(p->base + start), end - start, host)) { *error = 8; goto done; }
    *old = r->protection[first];
    memset(r->protection + first, protection, count);
    result = 1; *error = 0;
done:
    unlock(p);
    return result;
}

#ifdef TC_VM_SELF_CHECK
#include <assert.h>
int main(void)
{
    size_t capacity=4*GRANULARITY;
    unsigned char *mapping=mmap(NULL,capacity,PROT_NONE,MAP_PRIVATE|MAP_ANON,-1,0);
    assert(mapping!=MAP_FAILED);
    assert(tc_memory_readable(0,0)&&!tc_memory_readable((uintptr_t)mapping,1));
    struct tc_vm_process *p=tc_vm_create((uintptr_t)mapping,GRANULARITY,2*GRANULARITY);
    assert(p);
    uint32_t error,old;
    uint32_t address=tc_vm_alloc(p,0,GRANULARITY,0x2000,4,&error);
    assert(address==GRANULARITY&&!error);
    assert(tc_vm_alloc(p,address,GRANULARITY,0x1000,4,&error)==address);
    mapping[address]=0xab;
    assert(tc_memory_readable((uintptr_t)mapping+address,GRANULARITY));
    assert(!tc_memory_readable((uintptr_t)mapping+address,GRANULARITY+1));
    assert(tc_vm_protect(p,address,GRANULARITY,2,&old,&error)&&old==4);
    assert(mapping[address]==0xab);
    assert(tc_vm_free(p,address,GRANULARITY,0x4000,&error));
    assert(tc_vm_alloc(p,address,GRANULARITY,0x1000,4,&error)==address);
    assert(mapping[address]==0);
    assert(tc_vm_free(p,address,0,0x8000,&error));
    assert(!tc_vm_free(p,address,0,0x8000,&error)&&error==487);
    tc_vm_destroy(p);assert(!munmap(mapping,capacity));return 0;
}
#endif
