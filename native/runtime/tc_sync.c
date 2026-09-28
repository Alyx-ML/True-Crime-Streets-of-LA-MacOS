#include <errno.h>
#include <stdio.h>
#include "tc_sync.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct critical { uint32_t address;pthread_mutex_t mutex;struct critical *next; };
struct tc_sync_process {
    /* ponytail: a short registry lock and linear lookup; index by guest address
     * if lock count makes lookup significant. Waiting occurs outside this lock. */
    pthread_mutex_t registry;
    struct critical *objects;
};
static void *memory(tc_cpu *c,uint64_t address,size_t size) {
    if(!address||address>UINT32_MAX||size>c->memory_size||address>c->memory_size-size||
        c->scalar._pointer_offset>UINTPTR_MAX-address-size)abort();
    return (void *)(uintptr_t)(c->scalar._pointer_offset+address);
}
static uint32_t argument(_cpu *cpu,unsigned index) {
    uint32_t value;memcpy(&value,memory((tc_cpu *)cpu,(uint64_t)cpu->_esp+4+index*4,4),4);return value;
}
struct tc_sync_process *tc_sync_create(void) {
    struct tc_sync_process *p=calloc(1,sizeof(*p));if(!p)return NULL;
    if(pthread_mutex_init(&p->registry,NULL)){free(p);return NULL;}return p;
}
void tc_sync_destroy(struct tc_sync_process *p) {
    if(!p)return;
    while(p->objects) {
        struct critical *next=p->objects->next;
        if(pthread_mutex_destroy(&p->objects->mutex))abort();
        free(p->objects);p->objects=next;
    }
    if(pthread_mutex_destroy(&p->registry))abort();free(p);
}
static struct tc_sync_process *lock(_cpu *cpu) {
    struct tc_sync_process *p=((tc_cpu *)cpu)->sync_process;
    if(!p||pthread_mutex_lock(&p->registry))abort();return p;
}
static void unlock(struct tc_sync_process *p) {if(pthread_mutex_unlock(&p->registry))abort();}
static struct critical *find(struct tc_sync_process *p,uint32_t address) {
    struct critical *it=p->objects;while(it&&it->address!=address)it=it->next;return it;
}
void tc_critical_initialize(_cpu *cpu) {
    uint32_t address=argument(cpu,0);void *storage=memory((tc_cpu *)cpu,address,24);
    if(address%4)abort();
    struct critical *object=calloc(1,sizeof(*object));if(!object)abort();
    pthread_mutexattr_t attributes;
    if(pthread_mutexattr_init(&attributes))abort();
    if(pthread_mutexattr_settype(&attributes,PTHREAD_MUTEX_RECURSIVE)||pthread_mutex_init(&object->mutex,&attributes))abort();
    if(pthread_mutexattr_destroy(&attributes))abort();
    struct tc_sync_process *p=lock(cpu);
    if(find(p,address))abort();
    object->address=address;object->next=p->objects;p->objects=object;
    /* The public API treats CRITICAL_SECTION storage as opaque. Never store
     * a 64-bit host pointer inside the 24-byte guest structure. */
    const uint32_t initial[6]={0,UINT32_MAX,0,0,0,0};memcpy(storage,initial,24);
    unlock(p);
}
void tc_critical_enter(_cpu *cpu) {
    struct tc_sync_process *p=lock(cpu);struct critical *object=find(p,argument(cpu,0));
    unlock(p);if(!object||pthread_mutex_lock(&object->mutex))abort();
}
void tc_critical_leave(_cpu *cpu) {
    struct tc_sync_process *p=lock(cpu);struct critical *object=find(p,argument(cpu,0));
    uint32_t address=argument(cpu,0);unlock(p);
    /* Leaving a deleted or never-entered section is harmless on Windows (0x750d70). */
    if(!object){static _Atomic int reported;if(!reported++)fprintf(stderr,"LeaveCriticalSection on unknown object %08x ignored\n",address);return;}
    /* Windows tolerates leaving a section the thread does not own (the game's
       audio error paths do this with sound disabled); pthreads reports EPERM. */
    int error=pthread_mutex_unlock(&object->mutex);
    if(error==EPERM){static _Atomic int reported;if(!reported++)fprintf(stderr,"LeaveCriticalSection %08x not owned by this thread; ignored as on Windows\n",address);}
    else if(error)abort();
}
void tc_critical_delete(_cpu *cpu) {
    struct tc_sync_process *p=lock(cpu);uint32_t address=argument(cpu,0);
    struct critical **link=&p->objects;while(*link&&(*link)->address!=address)link=&(*link)->next;
    if(!*link){unlock(p);return;}
    struct critical *object=*link;*link=object->next;
    /* ponytail: a section deleted while another thread still holds it is leaked, not destroyed. */
    if(!pthread_mutex_destroy(&object->mutex))free(object);
    unlock(p);
}
void tc_interlocked_exchange(_cpu *cpu) {
    uint32_t address=argument(cpu,0);if(address%4)abort();
    uint32_t *destination=memory((tc_cpu *)cpu,address,4);
    cpu->_eax=__atomic_exchange_n(destination,argument(cpu,1),__ATOMIC_SEQ_CST);
}
#ifdef TC_SYNC_SELF_CHECK
#include <assert.h>
struct worker { struct tc_sync_process *process;unsigned char *bytes;uint32_t *counter; };
static void *increment(void *opaque) {
    struct worker *w=opaque;tc_cpu c={0};c.scalar._pointer_offset=(uintptr_t)w->bytes;
    c.memory_size=256;c.scalar._esp=128;c.sync_process=w->process;
    for(unsigned i=0;i<1000;i++) {
        tc_critical_enter(&c.scalar);tc_critical_enter(&c.scalar);
        ++*w->counter;tc_critical_leave(&c.scalar);tc_critical_leave(&c.scalar);
    }
    return NULL;
}
int main(void) {
    _Alignas(4) unsigned char bytes[256]={0};uint32_t address=64,counter=0;
    memcpy(bytes+132,&address,4);tc_cpu c={0};c.scalar._pointer_offset=(uintptr_t)bytes;
    c.memory_size=sizeof(bytes);c.scalar._esp=128;c.sync_process=tc_sync_create();assert(c.sync_process);
    tc_critical_initialize(&c.scalar);
    struct worker w={c.sync_process,bytes,&counter};pthread_t other;
    assert(!pthread_create(&other,NULL,increment,&w));increment(&w);assert(!pthread_join(other,NULL));
    assert(counter==2000);tc_critical_delete(&c.scalar);tc_sync_destroy(c.sync_process);
    uint32_t value=17;memcpy(bytes+136,&value,4);tc_interlocked_exchange(&c.scalar);
    memcpy(&value,bytes+64,4);assert(c.scalar._eax==0&&value==17);return 0;
}
#endif
