#include "tc_bink.h"
#include "tc_video.h"
#include "tc_heap.h"
#include "tc_files.h"
#include "tc_d3d8.h"
#include "tc_dsound.h"
#include <pthread.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct movie {
    struct movie *next;
    struct tc_video *decoder;
    tc_cpu *cpu;
    tc_video_info info;
    char *path;
    uint32_t address,frame,decoded,stride,flags;
    const uint8_t *pixels;
    double origin,pause_time;
    int paused,video,sound;
} movie;
typedef struct {pthread_mutex_t mutex;uint32_t heap,error;movie *movies;int sound;} process;
static void *mem(tc_cpu *c,uint64_t a,uint64_t n) {
    if(!a||a>UINT32_MAX||n>c->memory_size||a>c->memory_size-n||c->scalar._pointer_offset>UINTPTR_MAX-a-n)abort();
    return (void *)(uintptr_t)(c->scalar._pointer_offset+a);
}
static uint32_t arg(tc_cpu *c,unsigned n){uint32_t v;memcpy(&v,mem(c,(uint64_t)c->scalar._esp+4+n*4,4),4);return v;}
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void error(tc_cpu *c,process *p,const char *text){snprintf(mem(c,p->error,256),256,"%s",text);}
static movie *find(process *p,uint32_t address){for(movie *m=p->movies;m;m=m->next)if(m->address==address)return m;return NULL;}
static void publish(tc_cpu *c,movie *m) {
    uint32_t fields[]={m->info.width,m->info.height,m->info.frames,m->frame,m->decoded,
        m->info.rate,m->info.rate_divisor,0,m->flags,0,0,0,0};
    memcpy(mem(c,m->address,sizeof(fields)),fields,sizeof(fields));
}
int tc_bink_init(tc_cpu *c) {
    process *p=calloc(1,sizeof(*p));if(!p)return 0;
    if(pthread_mutex_init(&p->mutex,NULL)){free(p);return 0;}
    p->heap=tc_heap_create(c->heap_process,0,0,0);
    if(p->heap)p->error=tc_heap_alloc(c->heap_process,p->heap,8,256);
    if(!p->error){if(p->heap)tc_heap_destroy(c->heap_process,p->heap);pthread_mutex_destroy(&p->mutex);free(p);return 0;}
    p->sound=1;c->bink=p;return 1;
}
static void dispose(tc_cpu *c,process *p,movie *m) {
    tc_ds_movie_clear(c,m,1);
    tc_video_close(m->decoder);free(m->path);
    if(m->address)tc_heap_free(c->heap_process,p->heap,m->address);free(m);
}
void tc_bink_destroy(tc_cpu *c) {
    process *p=c?c->bink:NULL;if(!p)return;
    for(movie *m=p->movies;m;){movie *next=m->next;dispose(c,p,m);m=next;}
    tc_heap_destroy(c->heap_process,p->heap);pthread_mutex_destroy(&p->mutex);free(p);c->bink=NULL;
}
/* The native mixer replaces the supplied Windows sound factory. Selecting
 * the backend never starts an audio device; only normal-mode PCM writes do. */
void tc_bink_sound(_cpu *cpu) {
    tc_cpu *c=(tc_cpu *)cpu;process *p=c->bink;cpu->_eax=0;if(!p)return;
    pthread_mutex_lock(&p->mutex);
    p->sound=arg(c,0)!=0;cpu->_eax=1;
    pthread_mutex_unlock(&p->mutex);
}
static int audio_samples(void *opaque,uint32_t track,uint32_t rate,uint32_t channels,
    int planar,const float *const *samples,uint32_t count) {
    movie *m=opaque;
    return tc_ds_movie_write(m->cpu,m,track,rate,channels,planar,samples,count,m->paused);
}
void tc_bink_open(_cpu *cpu) {
    tc_cpu *c=(tc_cpu *)cpu;process *p=c->bink;cpu->_eax=0;if(!p)return;
    pthread_mutex_lock(&p->mutex);
    uint32_t flags=arg(c,1);
    if(flags&~0x08180000u){error(c,p,"Unsupported Bink open flags or memory-backed movie");goto done;}
    movie *m=calloc(1,sizeof(*m));if(!m){error(c,p,"Cannot allocate movie state");goto done;}
    m->path=tc_file_native_path(cpu,arg(c,0));
    if(!m->path){error(c,p,"Invalid movie path");dispose(c,p,m);goto done;}
    m->decoder=tc_video_open(m->path,&m->info,mem(c,p->error,256),256);
    if(!m->decoder){dispose(c,p,m);goto done;}
    m->sound=p->sound&&!c->headless&&!c->audio_disabled;
    if(m->sound)tc_video_set_audio(m->decoder,audio_samples,m);
    m->address=tc_heap_alloc(c->heap_process,p->heap,8,52);
    if(!m->address){error(c,p,"Cannot allocate guest movie header");dispose(c,p,m);goto done;}
    m->frame=1;m->flags=flags;m->video=1;m->origin=now();publish(c,m);
    m->next=p->movies;p->movies=m;cpu->_eax=m->address;
done:pthread_mutex_unlock(&p->mutex);
}
static int decode(tc_cpu *c,process *p,movie *m) {
    if(m->decoded==m->frame)return 1;
    m->cpu=c; /* The synchronous sink uses the current calling thread's CPU. */
    int result=tc_video_next(m->decoder,&m->pixels,&m->stride,mem(c,p->error,256),256);
    if(result==1){m->decoded=m->frame;publish(c,m);return 1;}
    uint32_t failed=1;memcpy(mem(c,m->address+28,4),&failed,4);
    if(!result)error(c,p,"Unexpected end of Bink video");return 0;
}
static void copy_row(uint8_t *out,const uint8_t *in,uint32_t width,uint32_t format) {
    for(uint32_t column=0;column<width;column++) {
        out[0]=in[format==4||format==6?2:0];out[1]=in[1];out[2]=in[format==4||format==6?0:2];
        out[3]=format>=5?in[3]:255;out+=4;in+=4;
    }
}
static void call(tc_cpu *c,unsigned op) {
    process *p=c->bink;c->scalar._eax=0;if(!p)return;
    pthread_mutex_lock(&p->mutex);movie *m=find(p,arg(c,0));
    if(!m){error(c,p,"Invalid movie handle");c->scalar._eax=UINT32_MAX;goto done;}
    switch(op) {
    case 0:{movie **link=&p->movies;while(*link!=m)link=&(*link)->next;*link=m->next;dispose(c,p,m);break;}
    case 1:c->scalar._eax=decode(c,p,m)?0:UINT32_MAX;break;
    case 2:
        /* Decode skipped frames too: Bink video uses inter-frame references. */
        if(!decode(c,p,m)){c->scalar._eax=UINT32_MAX;break;}
        if(m->frame==m->info.frames){
            tc_video_info info;struct tc_video *decoder=tc_video_open(m->path,&info,mem(c,p->error,256),256);
            if(!decoder){c->scalar._eax=UINT32_MAX;break;}
            tc_ds_movie_clear(c,m,0);
            if(m->sound)tc_video_set_audio(decoder,audio_samples,m);
            tc_video_close(m->decoder);m->decoder=decoder;m->frame=1;m->decoded=0;m->pixels=NULL;m->origin=now();
            if(m->paused)m->pause_time=m->origin;
        }else ++m->frame;
        publish(c,m);break;
    case 3:c->scalar._eax=m->paused||now()-m->origin<(double)(m->frame-1)*m->info.rate_divisor/m->info.rate;break;
    case 4:{int paused=arg(c,1)!=0;double t=now();if(paused&&!m->paused)m->pause_time=t;
        if(!paused&&m->paused)m->origin+=t-m->pause_time;m->paused=paused;c->scalar._eax=paused;
        if(!tc_ds_movie_pause(c,m,paused)){error(c,p,"Cannot resume native movie audio");c->scalar._eax=UINT32_MAX;}break;}
    case 5:m->video=arg(c,1)!=0;c->scalar._eax=m->video;break;
    case 6:
        if(!tc_ds_movie_volume(c,m,arg(c,1),arg(c,2))){error(c,p,"Invalid movie volume or audio allocation failure");c->scalar._eax=UINT32_MAX;}
        break;
    case 7:{
        uint32_t destination=arg(c,1),height=arg(c,3),x=arg(c,4),y=arg(c,5),flags=arg(c,6),format=flags&15;
        int32_t pitch=(int32_t)arg(c,2);
        if(!m->video)break;
        if((format!=3&&format!=4&&format!=5&&format!=6)||(flags&~0x8c08000fu)||!pitch||pitch==INT32_MIN||
            y>height||m->info.height>height-y||(uint64_t)x*4+(uint64_t)m->info.width*4>(uint32_t)abs(pitch)){
            error(c,p,"Unsupported or invalid movie destination");c->scalar._eax=UINT32_MAX;break;
        }
        if(!m->pixels||m->decoded!=m->frame){error(c,p,"Movie frame has not been decoded");c->scalar._eax=UINT32_MAX;break;}
        int64_t first=(int64_t)destination+(int64_t)y*pitch+(int64_t)x*4;
        int64_t last=first+(int64_t)(m->info.height-1)*pitch;
        int64_t low=first<last?first:last,high=first>last?first:last;
        if(low<=0||high>UINT32_MAX||(uint64_t)high+(uint64_t)m->info.width*4>c->memory_size){
            error(c,p,"Movie destination overflow");c->scalar._eax=UINT32_MAX;break;
        }
        for(uint32_t row=0;row<m->info.height;row++) {
            int64_t address=(int64_t)destination+(int64_t)(y+row)*pitch+(int64_t)x*4;
            if(address<=0||address>UINT32_MAX){error(c,p,"Movie destination overflow");c->scalar._eax=UINT32_MAX;goto done;}
            uint8_t *out=mem(c,address,(uint64_t)m->info.width*4);const uint8_t *in=m->pixels+(size_t)row*m->stride;
            copy_row(out,in,m->info.width,format);
        }
        c->scalar._eax=1;break;
    }
    }
done:pthread_mutex_unlock(&p->mutex);
}
void tc_bink_close(_cpu *c){call((tc_cpu *)c,0);}
void tc_bink_frame(_cpu *c){call((tc_cpu *)c,1);}
void tc_bink_next(_cpu *c){call((tc_cpu *)c,2);}
void tc_bink_wait(_cpu *c){call((tc_cpu *)c,3);}
void tc_bink_pause(_cpu *c){call((tc_cpu *)c,4);}
void tc_bink_video(_cpu *c){call((tc_cpu *)c,5);}
void tc_bink_volume(_cpu *c){call((tc_cpu *)c,6);}
void tc_bink_copy(_cpu *c){call((tc_cpu *)c,7);}
void tc_bink_error(_cpu *cpu){process *p=((tc_cpu *)cpu)->bink;cpu->_eax=p?p->error:0;}
void tc_bink_surface(_cpu *cpu){uint32_t f=tc_d3d_surface_format((tc_cpu *)cpu,arg((tc_cpu *)cpu,0));cpu->_eax=f==21?5:f==22?3:UINT32_MAX;}
void tc_bink_logo(_cpu *cpu) {
    tc_cpu *c=(tc_cpu *)cpu;process *p=c->bink;cpu->_eax=0;if(!p)return;
    pthread_mutex_lock(&p->mutex);error(c,p,"Embedded Bink SDK logo is unavailable");pthread_mutex_unlock(&p->mutex);
}
void tc_bink_directsound(_cpu *cpu) {
    tc_cpu *c=(tc_cpu *)cpu;process *p=c->bink;cpu->_eax=0;if(!p)return;
    pthread_mutex_lock(&p->mutex);error(c,p,"Bink DirectSound callback is disabled in the native bridge");pthread_mutex_unlock(&p->mutex);
}

#ifdef TC_BINK_SELF_CHECK
#include <assert.h>
int main(void) {
    uint8_t input[]={1,2,3,4,5,6,7,8},output[8];
    copy_row(output,input,2,5);assert(!memcmp(output,input,8));
    copy_row(output,input,2,3);assert(output[0]==1&&output[4]==5&&output[3]==255&&output[7]==255);
    copy_row(output,input,2,6);assert(output[0]==3&&output[2]==1&&output[3]==4&&output[4]==7&&output[6]==5&&output[7]==8);
    return 0;
}
#endif
