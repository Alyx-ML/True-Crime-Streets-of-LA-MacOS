#import <Foundation/Foundation.h>
#include "tc_threads.h"
#include "tc_heap.h"
#include <pthread.h>
#include <sched.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

struct thread {
    uint32_t handle,id,start,stack,fs,exit_code;int suspended,finished,open;
    int base_priority,policy,have_priority;
    pthread_t native;tc_cpu *cpu;struct tc_threads *owner;struct thread *next;
};
struct thread_alias {uint32_t handle;struct thread *target;struct thread_alias *next;};
struct tc_threads {
    /* ponytail: completed records survive until image teardown so CloseHandle
       cannot race a worker; reclaim records if thread churn becomes significant. */
    pthread_mutex_t mutex;pthread_cond_t changed;
    struct tc_heap_process *heaps;uint32_t heap,next_id,next_alias;struct thread *list;
    struct thread primary;struct thread_alias *aliases;
};
static void *memory(tc_cpu *c,uint64_t address,size_t size) {
    if(!address||address>UINT32_MAX||size>c->memory_size||address>c->memory_size-size||
       c->scalar._pointer_offset>UINTPTR_MAX-address-size)abort();
    return (void *)(uintptr_t)(c->scalar._pointer_offset+address);
}
static uint32_t arg(_cpu *cpu,unsigned index) {
    uint32_t value;memcpy(&value,memory((tc_cpu *)cpu,(uint64_t)cpu->_esp+4+index*4,4),4);return value;
}
static void error(_cpu *cpu,uint32_t result,uint32_t code) {cpu->_eax=result;tc_write_fs(cpu,0x34,code);}
static void lock(struct tc_threads *p){if(!p||pthread_mutex_lock(&p->mutex))abort();}
static void unlock(struct tc_threads *p){if(pthread_mutex_unlock(&p->mutex))abort();}
static struct thread *find(struct tc_threads *p,uint32_t handle) {
    for(struct thread_alias *a=p->aliases;a;a=a->next)if(a->handle==handle)return a->target;
    for(struct thread *t=p->list;t;t=t->next)if(t->handle==handle&&t->open)return t;
    return NULL;
}
static struct thread *current_thread(struct tc_threads *p,_cpu *cpu) {
    uint32_t id=tc_read_fs(cpu,0x24);
    if(id==1){p->primary.native=pthread_self();return &p->primary;}
    for(struct thread *t=p->list;t;t=t->next)if(t->id==id)return t;
    return NULL;
}
static int close_handle(struct tc_threads *p,uint32_t handle) {
    struct thread_alias **link=&p->aliases;
    while(*link&&(*link)->handle!=handle)link=&(*link)->next;
    if(*link){struct thread_alias *a=*link;*link=a->next;free(a);return 1;}
    for(struct thread *t=p->list;t;t=t->next)if(t->handle==handle&&t->open){t->open=0;return 1;}
    return 0;
}
struct tc_threads *tc_threads_create(struct tc_heap_process *heaps) {
    struct tc_threads *p=calloc(1,sizeof(*p));if(!p)return NULL;
    p->heaps=heaps;p->next_id=2;p->next_alias=1;p->primary.id=1;p->primary.exit_code=259;
    if(pthread_mutex_init(&p->mutex,NULL)){free(p);return NULL;}
    if(pthread_cond_init(&p->changed,NULL)){pthread_mutex_destroy(&p->mutex);free(p);return NULL;}
    p->heap=tc_heap_create(heaps,0,0,0);
    if(!p->heap){pthread_cond_destroy(&p->changed);pthread_mutex_destroy(&p->mutex);free(p);return NULL;}
    return p;
}
void tc_threads_main_returned(struct tc_threads *p,uint32_t exit_code) {
    if(!p)return;lock(p);p->primary.exit_code=exit_code;p->primary.finished=1;unlock(p);
}
int tc_threads_active(struct tc_threads *p) {
    if(!p)return 0;lock(p);int active=0;
    for(struct thread *t=p->list;t;t=t->next)if(!t->finished){active=1;break;}
    unlock(p);return active;
}
void tc_threads_destroy(struct tc_threads *p) {
    if(!p)return;if(tc_threads_active(p))abort();
    while(p->aliases){struct thread_alias *next=p->aliases->next;free(p->aliases);p->aliases=next;}
    while(p->list) {
        struct thread *t=p->list;p->list=t->next;
        if(pthread_join(t->native,NULL))abort();free(t);
    }
    if(!tc_heap_destroy(p->heaps,p->heap)||pthread_cond_destroy(&p->changed)||pthread_mutex_destroy(&p->mutex))abort();
    free(p);
}
static void *run_thread(void *opaque) {
    @autoreleasepool {
        struct thread *t=opaque;struct tc_threads *p=t->owner;
        lock(p);while(t->suspended)if(pthread_cond_wait(&p->changed,&p->mutex))abort();unlock(p);
        t->cpu->guest_invoke(&t->cpu->scalar,t->start);
        uint32_t result=t->cpu->scalar._eax;
        tc_heap_free(p->heaps,p->heap,t->stack);tc_heap_free(p->heaps,p->heap,t->fs);
        free(t->cpu);t->cpu=NULL;
        lock(p);t->exit_code=result;t->finished=1;pthread_cond_broadcast(&p->changed);unlock(p);
    }return NULL;
}
void tc_thread_create(_cpu *cpu) {
    tc_cpu *parent=(tc_cpu *)cpu;struct tc_threads *p=parent->threads;
    uint32_t security=arg(cpu,0),size=arg(cpu,1),start=arg(cpu,2),parameter=arg(cpu,3),flags=arg(cpu,4),id_output=arg(cpu,5);
    if(!p||!parent->guest_invoke||!start||(flags&~0x10004u)){error(cpu,0,87);return;}
    if(security) {
        uint32_t attributes[3];memcpy(attributes,memory(parent,security,12),12);
        if(attributes[0]!=12||attributes[1]||attributes[2]){error(cpu,0,50);return;}
    }
    if(id_output)memory(parent,id_output,4);
    uint64_t stack_size=((uint64_t)(size?size:0x100000)+65535)&~UINT64_C(65535);
    if(stack_size>64*1024*1024){error(cpu,0,8);return;}
    struct thread *t=calloc(1,sizeof(*t));tc_cpu *child=calloc(1,sizeof(*child));
    if(!t||!child){free(t);free(child);error(cpu,0,8);return;}
    t->stack=tc_heap_alloc(p->heaps,p->heap,8,(uint32_t)stack_size);t->fs=tc_heap_alloc(p->heaps,p->heap,8,4096);
    if(!t->stack||!t->fs)goto failed;
    *child=*parent;memset(&child->scalar,0,sizeof(child->scalar));memset(child->xmm,0,sizeof(child->xmm));
    memset(child->tls_value,0,sizeof(child->tls_value));memset(child->tls_generation,0,sizeof(child->tls_generation));
    child->scalar._pointer_offset=parent->scalar._pointer_offset;child->scalar._st_cw=0x037f;child->scalar._eflags=0x202;
    child->mxcsr=TC_MXCSR_DEFAULT;child->fs_base=t->fs;child->fs_size=4096;child->x87_result_address=t->fs+0x80;
    uint32_t stack_top=t->stack+(uint32_t)stack_size;child->scalar._esp=stack_top-8;
    uint32_t frame[]={UINT32_MAX,parameter};memcpy(memory(child,child->scalar._esp,8),frame,8);
    tc_write_fs(&child->scalar,0,UINT32_MAX);tc_write_fs(&child->scalar,4,stack_top);tc_write_fs(&child->scalar,8,t->stack);
    tc_write_fs(&child->scalar,0x18,t->fs);tc_write_fs(&child->scalar,0x20,tc_read_fs(cpu,0x20));
    uint32_t tls_data=t->fs+0x110;memcpy(memory(child,t->fs+0x100,4),&tls_data,4);
    memcpy(memory(child,tls_data,64),memory(parent,0x75a000,64),64);tc_write_fs(&child->scalar,0x2c,t->fs+0x100);
    t->cpu=child;t->owner=p;t->start=start;t->suspended=(flags&4)!=0;t->open=1;t->exit_code=259;
    lock(p);
    if(p->next_id>=0x00ffffffu){unlock(p);goto failed;}
    t->id=p->next_id++;t->handle=0xe6000000u+t->id;tc_write_fs(&child->scalar,0x24,t->id);
    /* Win32 workers begin at normal priority, rather than inheriting an
       explicitly boosted/idle priority from the creating pthread. */
    pthread_attr_t attributes;
    if(pthread_attr_init(&attributes)){unlock(p);goto failed;}
    int creation=pthread_attr_setinheritsched(&attributes,PTHREAD_EXPLICIT_SCHED);
    if(!creation)creation=pthread_create(&t->native,&attributes,run_thread,t);
    pthread_attr_destroy(&attributes);
    if(creation){unlock(p);goto failed;}
    t->next=p->list;p->list=t;
    if(id_output)memcpy(memory(parent,id_output,4),&t->id,4);
    cpu->_eax=t->handle;unlock(p);return;
failed:
    if(t->stack)tc_heap_free(p->heaps,p->heap,t->stack);
    if(t->fs)tc_heap_free(p->heaps,p->heap,t->fs);
    free(child);free(t);error(cpu,0,8);
}
static int priority_value(int32_t requested,int base,int minimum,int maximum,int *value) {
    if(minimum>maximum)return 0;
    if(requested==-15)*value=minimum;
    else if(requested==15)*value=maximum;
    else if(requested>=-2&&requested<=2) {
        int64_t target=(int64_t)base+requested;
        *value=target<minimum?minimum:target>maximum?maximum:(int)target;
    } else return 0;
    return 1;
}
void tc_thread_priority(_cpu *cpu) {
    uint32_t handle=arg(cpu,0);int32_t requested=(int32_t)arg(cpu,1);int unused;
    if(!priority_value(requested,0,-15,15,&unused)){error(cpu,0,requested==0x10000||requested==0x20000?50:87);return;}
    struct tc_threads *p=((tc_cpu *)cpu)->threads;lock(p);
    struct thread *t=handle==UINT32_MAX-1?current_thread(p,cpu):find(p,handle);
    if(!t||t->finished){unlock(p);error(cpu,0,6);return;}
    struct sched_param parameters={0};int result=0;
    if(!t->have_priority) {
        result=pthread_getschedparam(t->native,&t->policy,&parameters);
        if(!result){t->base_priority=parameters.sched_priority;t->have_priority=1;}
    }
    if(!result) {
        int minimum=sched_get_priority_min(t->policy),maximum=sched_get_priority_max(t->policy);
        if(minimum==-1||maximum==-1||!priority_value(requested,t->base_priority,minimum,maximum,&parameters.sched_priority))result=EINVAL;
        else result=pthread_setschedparam(t->native,t->policy,&parameters);
    }
    unlock(p);
    if(result)error(cpu,0,result==EPERM?5:result==ESRCH?6:result==EINVAL?87:50);
    else cpu->_eax=1;
}
void tc_thread_resume(_cpu *cpu) {
    struct tc_threads *p=((tc_cpu *)cpu)->threads;lock(p);struct thread *t=find(p,arg(cpu,0));
    if(!t){unlock(p);error(cpu,UINT32_MAX,6);return;}
    cpu->_eax=(uint32_t)t->suspended;t->suspended=0;pthread_cond_broadcast(&p->changed);unlock(p);
}
void tc_thread_exit_code(_cpu *cpu) {
    uint32_t handle=arg(cpu,0),destination=arg(cpu,1);
    if(!destination){error(cpu,0,87);return;}
    struct tc_threads *p=((tc_cpu *)cpu)->threads;lock(p);struct thread *t=find(p,handle);
    if(!t&&handle!=UINT32_MAX-1){unlock(p);error(cpu,0,6);return;}
    uint32_t value=t?t->exit_code:259;unlock(p);
    memcpy(memory((tc_cpu *)cpu,destination,4),&value,4);cpu->_eax=1;
}
int tc_thread_close(tc_cpu *cpu,uint32_t handle) {
    struct tc_threads *p=cpu->threads;if(!p)return 0;lock(p);
    int closed=close_handle(p,handle);unlock(p);return closed;
}
void tc_duplicate_handle(_cpu *cpu) {
    tc_cpu *c=(tc_cpu *)cpu;struct tc_threads *p=c->threads;
    uint32_t source_process=arg(cpu,0),source=arg(cpu,1),target_process=arg(cpu,2),destination=arg(cpu,3);
    uint32_t inherit=arg(cpu,5),options=arg(cpu,6);
    if(source_process!=UINT32_MAX){error(cpu,0,6);return;}
    if(destination&&target_process)memory(c,destination,4);
    lock(p);struct thread *t=source==UINT32_MAX-1?current_thread(p,cpu):find(p,source);
    /* CLOSE_SOURCE applies even when a later validation/allocation fails. The
       record survives closure, so existing aliases and workers remain valid. */
    if(options&1)close_handle(p,source);
    if(!t){unlock(p);error(cpu,0,6);return;}
    if(options&~3u){unlock(p);error(cpu,0,87);return;}
    if(!target_process&&(options&1)){unlock(p);cpu->_eax=1;return;}
    if(target_process!=UINT32_MAX){unlock(p);error(cpu,0,6);return;}
    if(!(options&2)||inherit){unlock(p);error(cpu,0,50);return;}
    if(p->next_alias>=0x00ffffffu){unlock(p);error(cpu,0,4);return;}
    struct thread_alias *alias=calloc(1,sizeof(*alias));
    if(!alias){unlock(p);error(cpu,0,8);return;}
    alias->handle=0xe7000000u+p->next_alias++;alias->target=t;alias->next=p->aliases;p->aliases=alias;
    if(destination)memcpy(memory(c,destination,4),&alias->handle,4);
    unlock(p);cpu->_eax=1;
}
void tc_current_thread_handle(_cpu *cpu){cpu->_eax=UINT32_MAX-1;}
void tc_current_process_handle(_cpu *cpu){cpu->_eax=UINT32_MAX;}

#ifdef TC_THREADS_SELF_CHECK
#include "tc_image.h"
#include <assert.h>
#include <time.h>
static void check_worker(_cpu *cpu,uint32_t address) {
    tc_cpu *c=(tc_cpu *)cpu;
    assert(address==0x401000&&tc_read_fs(cpu,0x24)==2);
    assert(tc_read_fs(cpu,8)<cpu->_esp&&cpu->_esp<tc_read_fs(cpu,4));
    assert(c->fs_base!=0x03e01000&&c->tls_value[0]==0&&c->tls_generation[0]==0);
    uint32_t frame[2];memcpy(frame,memory(c,cpu->_esp,8),8);
    assert(frame[0]==UINT32_MAX&&frame[1]==0x12345678);
    uint32_t tls;memcpy(&tls,memory(c,tc_read_fs(cpu,0x2c),4),4);
    assert(!memcmp(memory(c,tls,64),memory(c,0x75a000,64),64));
    cpu->_eax=frame[1];
}
int main(int argc,char **argv) {
    int native_priority;
    assert(priority_value(0,31,0,63,&native_priority)&&native_priority==31);
    assert(priority_value(-2,31,0,63,&native_priority)&&native_priority==29);
    assert(priority_value(2,62,0,63,&native_priority)&&native_priority==63);
    assert(priority_value(-15,31,0,63,&native_priority)&&native_priority==0);
    assert(priority_value(15,31,0,63,&native_priority)&&native_priority==63);
    assert(!priority_value(3,31,0,63,&native_priority));
    assert(argc==2);tc_image image={0};char message[128];
    assert(tc_image_open(&image,argv[1],message,sizeof(message))==0);
    tc_cpu *c=&image.cpu;c->guest_invoke=check_worker;c->tls_value[0]=42;c->tls_generation[0]=42;
    c->scalar._esp-=64;
    uint32_t args[]={0,0,0x401000,0x12345678,4,0x03e00100};
    memcpy(memory(c,c->scalar._esp+4,sizeof(args)),args,sizeof(args));tc_thread_create(&c->scalar);
    uint32_t handle=c->scalar._eax,id;memcpy(&id,memory(c,0x03e00100,4),4);
    assert(handle&&id==2&&tc_threads_active(c->threads));
    args[0]=handle;args[1]=0x03e00104;memcpy(memory(c,c->scalar._esp+4,8),args,8);
    tc_thread_exit_code(&c->scalar);uint32_t code;memcpy(&code,memory(c,args[1],4),4);
    assert(c->scalar._eax==1&&code==259);tc_thread_resume(&c->scalar);assert(c->scalar._eax==1);
    struct timespec deadline;assert(!clock_gettime(CLOCK_REALTIME,&deadline));deadline.tv_sec+=3;
    lock(c->threads);struct thread *t=find(c->threads,handle);assert(t);
    while(!t->finished)assert(!pthread_cond_timedwait(&c->threads->changed,&c->threads->mutex,&deadline));
    unlock(c->threads);tc_thread_exit_code(&c->scalar);memcpy(&code,memory(c,args[1],4),4);
    assert(code==0x12345678&&!tc_threads_active(c->threads)&&c->tls_value[0]==42);
    uint32_t duplicate_args[]={UINT32_MAX,handle,UINT32_MAX,0x03e00108,0,0,2};
    memcpy(memory(c,c->scalar._esp+4,sizeof(duplicate_args)),duplicate_args,sizeof(duplicate_args));
    tc_duplicate_handle(&c->scalar);assert(c->scalar._eax==1);
    uint32_t duplicate;memcpy(&duplicate,memory(c,0x03e00108,4),4);assert(duplicate!=handle);
    assert(tc_thread_close(c,handle)&&!tc_thread_close(c,handle));
    args[0]=duplicate;memcpy(memory(c,c->scalar._esp+4,8),args,8);tc_thread_exit_code(&c->scalar);
    memcpy(&code,memory(c,args[1],4),4);assert(c->scalar._eax==1&&code==0x12345678);
    assert(tc_thread_close(c,duplicate));args[0]=handle;memcpy(memory(c,c->scalar._esp+4,8),args,8);
    tc_thread_exit_code(&c->scalar);assert(!c->scalar._eax&&tc_read_fs(&c->scalar,0x34)==6);
    duplicate_args[1]=UINT32_MAX-1;memcpy(memory(c,c->scalar._esp+4,sizeof(duplicate_args)),duplicate_args,sizeof(duplicate_args));
    tc_duplicate_handle(&c->scalar);assert(c->scalar._eax==1);memcpy(&duplicate,memory(c,0x03e00108,4),4);
    args[0]=duplicate;memcpy(memory(c,c->scalar._esp+4,8),args,8);tc_thread_exit_code(&c->scalar);
    memcpy(&code,memory(c,args[1],4),4);assert(c->scalar._eax==1&&code==259);
    duplicate_args[1]=duplicate;duplicate_args[5]=1;duplicate_args[6]=3;
    memcpy(memory(c,c->scalar._esp+4,sizeof(duplicate_args)),duplicate_args,sizeof(duplicate_args));
    tc_duplicate_handle(&c->scalar);assert(!c->scalar._eax&&!tc_thread_close(c,duplicate));
    tc_image_close(&image);return 0;
}
#endif
