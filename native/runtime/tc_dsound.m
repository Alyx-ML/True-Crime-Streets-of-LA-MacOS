#import <AVFoundation/AVFoundation.h>
#include "tc_dsound.h"
#include "tc_heap.h"
#include <pthread.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

#define INVALID 0x80070057u
#define UNSUPPORTED 0x80004001u
#define OOM 0x8007000eu
#define CONTROL 0x8878001eu
/* The software mixer owns native PCM snapshots; the render thread never reads
 * guest memory. Only Unlock publishes guest writes to playback. */
typedef struct { float x,y,z; } vector;
typedef struct { uint32_t size;vector position,velocity,front,top;float distance,rolloff,doppler; } listener;
typedef struct { uint32_t size;vector position,velocity;uint32_t inside,outside;vector direction;int32_t outsideVolume;float minimum,maximum;uint32_t mode; } spatial;
_Static_assert(sizeof(listener)==64&&sizeof(spatial)==64,"DirectSound 3D ABI");
typedef struct sound {
    struct sound *next, *owner;
    listener listenerNow,listenerPending;
    spatial spatialNow,spatialPending;
    uint32_t address, references, kind, flags, data, size, cooperative;
    uint32_t rate, frequency, channels, bits, align;
    int32_t volume, pan;
    double cursor, silentTime;
    int playing, looping, locked, allocated;
    uint32_t lock[4];
    unsigned char *pcm;
} sound;
typedef struct movie_audio {
    struct movie_audio *next;
    void *key;
    uint32_t track,rate,capacity,read,count;
    float *pcm,gain;
    double fraction;
    int paused;
} movie_audio;
typedef struct {
    pthread_mutex_t mutex;
    uint32_t heap, tables[4];
    sound *objects;
    movie_audio *movies;
    void *engine;
    unsigned char reportedFailure[4][21];
} audio;
static void *mem(tc_cpu *c,uint64_t a,uint64_t n) {
    if(!a||a>UINT32_MAX||n>c->memory_size||a>c->memory_size-n||c->scalar._pointer_offset>UINTPTR_MAX-a-n)abort();
    return (void *)(uintptr_t)(c->scalar._pointer_offset+a);
}
static uint32_t arg(tc_cpu *c,unsigned i){uint32_t v;memcpy(&v,mem(c,(uint64_t)c->scalar._esp+4+i*4,4),4);return v;}
static void put(tc_cpu *c,uint32_t a,uint32_t v){memcpy(mem(c,a,4),&v,4);}
static sound *lookup(audio *p,uint32_t a){for(sound *s=p->objects;s;s=s->next)if(s->address==a||((s->flags&16)&&s->address+4==a))return s;return NULL;}
static float sample(sound *s,uint32_t frame,unsigned channel) {
    const unsigned char *v=s->pcm+frame*s->align+(channel%s->channels)*(s->bits/8);
    if(s->bits==8)return ((int)*v-128)/128.f;
    int16_t value;memcpy(&value,v,2);return value/32768.f;
}
static vector sub(vector a,vector b){return (vector){a.x-b.x,a.y-b.y,a.z-b.z};}
static float dot(vector a,vector b){return a.x*b.x+a.y*b.y+a.z*b.z;}
static vector cross(vector a,vector b){return (vector){a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
static float length(vector v){return sqrtf(dot(v,v));}
static vector unit(vector v){float n=length(v);return n>0?(vector){v.x/n,v.y/n,v.z/n}:(vector){0};}
static int finite_vector(vector v){return isfinite(v.x)&&isfinite(v.y)&&isfinite(v.z)&&fabsf(v.x)<=1e15f&&fabsf(v.y)<=1e15f&&fabsf(v.z)<=1e15f;}
static float decibels(int32_t volume){return volume<=-10000?0:powf(10,volume/2000.f);}
static void spatial_gain(sound *s,float *left,float *right,double *step) {
    if(!(s->flags&16)||s->spatialNow.mode==2)return;
    spatial *b=&s->spatialNow;listener *l=&s->owner->listenerNow;
    vector relative=b->mode==1?b->position:sub(b->position,l->position);
    float distance=length(relative),attenuation=1;
    if((s->flags&0x20000)&&distance>=b->maximum)attenuation=0;
    else if(distance>b->minimum)attenuation=b->minimum/(b->minimum+l->rolloff*(fminf(distance,b->maximum)-b->minimum));
    vector direction=unit(relative);
    vector rightAxis=b->mode==1?(vector){1,0,0}:unit(cross(l->top,l->front));
    float pan=fmaxf(-1,fminf(1,dot(direction,rightAxis)));
    if(b->inside<360&&distance>0){
        float cosine=fmaxf(-1,fminf(1,-dot(unit(b->direction),direction)));
        float angle=acosf(cosine)*360/M_PI;
        if(angle>b->inside){float factor=b->outside>b->inside?fminf(1,(angle-b->inside)/(b->outside-b->inside)):1;attenuation*=decibels((int32_t)(b->outsideVolume*factor));}
    }
    *left*=attenuation*sqrtf((1-pan)*.5f);*right*=attenuation*sqrtf((1+pan)*.5f);
    if(distance>0&&l->doppler>0){
        float listenerSpeed=b->mode==1?0:dot(l->velocity,direction)*l->distance*l->doppler;
        float sourceSpeed=dot(b->velocity,direction)*l->distance*l->doppler;
        /* Bound sonic crossings; avoid negative or unbounded playback rates. */
        float ratio=(343+fmaxf(-300,fminf(300,listenerSpeed)))/(343+fmaxf(-300,fminf(300,sourceSpeed)));
        *step*=fmaxf(.125f,fminf(8,ratio));
    }
}
static void mix(audio *p,uint32_t count,float *left,float *right) {
    for(sound *s=p->objects;s;s=s->next) {
        if(s->kind!=1||!s->playing||!s->size)continue;
        uint32_t frames=s->size/s->align;
        float gain=decibels(s->volume);
        /* ponytail: scan for the primary once per active voice; cache it on
         * the owner if large voice counts make this quadratic scan material. */
        for(sound *primary=p->objects;primary;primary=primary->next)if((primary->flags&1)&&primary->owner==s->owner)gain*=decibels(primary->volume);
        float lg=gain*(s->pan>0?powf(10,-s->pan/2000.f):1);
        float rg=gain*(s->pan<0?powf(10,s->pan/2000.f):1);
        double step=s->frequency/48000.;
        spatial_gain(s,&lg,&rg,&step);
        for(uint32_t i=0;i<count;i++) {
            if(s->cursor>=frames){if(s->looping)s->cursor=fmod(s->cursor,frames);else{s->playing=0;s->cursor=0;break;}}
            uint32_t f=(uint32_t)s->cursor,n=f+1;float t=s->cursor-f;
            if(n==frames)n=s->looping?0:f;
            left[i]+=(sample(s,f,0)*(1-t)+sample(s,n,0)*t)*lg;
            right[i]+=(sample(s,f,1)*(1-t)+sample(s,n,1)*t)*rg;
            s->cursor+=step;
        }
        if(s->cursor>=frames){if(s->looping)s->cursor=fmod(s->cursor,frames);else{s->playing=0;s->cursor=0;}}
    }
    for(movie_audio *s=p->movies;s;s=s->next) {
        if(s->paused)continue;
        for(uint32_t i=0;i<count&&s->count;i++) {
            uint32_t next=s->count>1?(s->read+1)%s->capacity:s->read;
            float t=(float)s->fraction;
            left[i]+=(s->pcm[s->read*2]*(1-t)+s->pcm[next*2]*t)*s->gain;
            right[i]+=(s->pcm[s->read*2+1]*(1-t)+s->pcm[next*2+1]*t)*s->gain;
            s->fraction+=s->rate/48000.;
            uint32_t consumed=(uint32_t)s->fraction;if(consumed>s->count)consumed=s->count;
            s->read=(s->read+consumed)%s->capacity;s->count-=consumed;
            s->fraction=s->count?s->fraction-consumed:0;
        }
    }
    for(uint32_t i=0;i<count;i++){left[i]=fmaxf(-1,fminf(1,left[i]));right[i]=fmaxf(-1,fminf(1,right[i]));}
}
static double monotonic_time(void) {
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;
}
/* Headless runs advance software cursors without constructing AVAudioEngine,
 * querying output devices, or sending samples to CoreAudio. */
static void silent_advance(sound *s,double now) {
    if(s->playing&&s->size&&s->silentTime) {
        s->cursor+=fmax(0,now-s->silentTime)*s->frequency;
        uint32_t frames=s->size/s->align;
        if(s->cursor>=frames){if(s->looping)s->cursor=fmod(s->cursor,frames);else{s->cursor=0;s->playing=0;}}
    }
    s->silentTime=now;
}
static uint32_t start(audio *p,int headless) {
    if(headless)return 0;
    AVAudioEngine *engine=(__bridge AVAudioEngine *)p->engine;
    if(!engine) {
        engine=[[AVAudioEngine alloc] init];
        AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        AVAudioSourceNode *source=[[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *silent,const AudioTimeStamp *time,AVAudioFrameCount count,AudioBufferList *output){
            (void)time;
            for(unsigned i=0;i<output->mNumberBuffers;i++)memset(output->mBuffers[i].mData,0,output->mBuffers[i].mDataByteSize);
            *silent=YES;
            /* ponytail: one mixer lock; contention emits silence. Replace with
             * command snapshots only if runtime profiling shows audio dropouts. */
            if(output->mNumberBuffers==2&&!pthread_mutex_trylock(&p->mutex)){
                mix(p,count,output->mBuffers[0].mData,output->mBuffers[1].mData);*silent=NO;
                pthread_mutex_unlock(&p->mutex);
            }
            return noErr;
        }];
        if(!engine||!source||!format)return OOM;
        [engine attachNode:source];[engine connect:source to:engine.mainMixerNode format:format];
        p->engine=(__bridge_retained void *)engine;
    }
    if(engine.running)return 0;
    NSError *error=nil;
    if(![engine startAndReturnError:&error]){fprintf(stderr,"Native audio: %s\n",error.localizedDescription.UTF8String);return 0x88780078u;}
    return 0;
}
int tc_ds_open(tc_cpu *c) {
    audio *p=calloc(1,sizeof(*p));if(!p)return 0;
    if(pthread_mutex_init(&p->mutex,NULL)){free(p);return 0;}
    c->audio=p;return 1;
}
static movie_audio *movie_track(audio *p,void *key,uint32_t track) {
    unsigned count=0;
    for(movie_audio *s=p->movies;s;s=s->next)if(s->key==key){if(s->track==track)return s;count++;}
    if(count>=256)return NULL; /* Bink's maximum track count. */
    movie_audio *s=calloc(1,sizeof(*s));if(!s)return NULL;
    s->key=key;s->track=track;s->gain=1;s->next=p->movies;p->movies=s;return s;
}
int tc_ds_movie_write(tc_cpu *c,void *key,uint32_t track,uint32_t rate,
    uint32_t channels,int planar,const float *const *samples,uint32_t count,int paused) {
    if(c->headless||c->audio_disabled)return 1;
    audio *p=c->audio;if(!p||!key||!rate||rate>192000||channels<1||channels>2||
        !samples||!samples[0]||(planar&&channels==2&&!samples[1]))return 0;
    pthread_mutex_lock(&p->mutex);int result=0;
    movie_audio *s=movie_track(p,key,track);if(!s)goto done;
    if(!s->pcm) {
        /* ponytail: four seconds per track, fail explicitly on overrun;
         * use a timestamped queue if movies need greater decode-ahead. */
        s->capacity=rate*4;s->pcm=calloc(s->capacity,2*sizeof(float));
        if(!s->pcm)goto done;s->rate=rate;
    }
    if(rate!=s->rate||count>s->capacity-s->count)goto done;
    for(uint32_t i=0;i<count;i++)for(unsigned channel=0;channel<2;channel++) {
        unsigned source=channel%channels;
        float value=planar?samples[source][i]:samples[0][(size_t)i*channels+source];
        s->pcm[((s->read+s->count+i)%s->capacity)*2+channel]=isfinite(value)?value:0;
    }
    s->count+=count;s->paused=paused;
    result=paused||!count||start(p,0)==0;
done:pthread_mutex_unlock(&p->mutex);return result;
}
int tc_ds_movie_volume(tc_cpu *c,void *key,uint32_t track,uint32_t volume) {
    if(volume>65536)return 0;
    if(c->headless||c->audio_disabled)return 1;
    audio *p=c->audio;if(!p||!key)return 0;
    pthread_mutex_lock(&p->mutex);movie_audio *s=movie_track(p,key,track);
    if(s)s->gain=volume/32768.f;
    pthread_mutex_unlock(&p->mutex);return s!=NULL;
}
int tc_ds_movie_pause(tc_cpu *c,void *key,int paused) {
    if(c->headless||c->audio_disabled)return 1;
    audio *p=c->audio;if(!p)return 0;
    pthread_mutex_lock(&p->mutex);int queued=0;
    for(movie_audio *s=p->movies;s;s=s->next)if(s->key==key){s->paused=paused;queued|=s->count!=0;}
    int result=paused||!queued||start(p,0)==0;
    pthread_mutex_unlock(&p->mutex);return result;
}
void tc_ds_movie_clear(tc_cpu *c,void *key,int remove) {
    audio *p=c->audio;if(!p)return;
    pthread_mutex_lock(&p->mutex);movie_audio **link=&p->movies;
    while(*link) {
        movie_audio *s=*link;
        if(s->key==key){
            if(remove){*link=s->next;free(s->pcm);free(s);continue;}
            s->count=s->read=0;s->fraction=0;
        }
        link=&s->next;
    }
    pthread_mutex_unlock(&p->mutex);
}
void tc_ds_close(tc_cpu *c) {
    audio *p=c?c->audio:NULL;if(!p)return;
    if(p->engine){AVAudioEngine *engine=CFBridgingRelease(p->engine);[engine stop];[engine reset];p->engine=NULL;}
    for(sound *s=p->objects;s;){sound *next=s->next;free(s->pcm);free(s);s=next;}
    for(movie_audio *s=p->movies;s;){movie_audio *next=s->next;free(s->pcm);free(s);s=next;}
    if(p->heap)tc_heap_destroy(c->heap_process,p->heap);
    pthread_mutex_destroy(&p->mutex);free(p);c->audio=NULL;
}
static sound *create(tc_cpu *c,audio *p,unsigned kind) {
    sound *s=calloc(1,sizeof(*s));if(!s)return NULL;
    s->address=tc_heap_alloc(c->heap_process,p->heap,8,8);
    if(!s->address){free(s);return NULL;}
    s->kind=kind;s->references=1;s->rate=s->frequency=48000;s->channels=2;s->bits=16;s->align=4;
    s->listenerNow=(listener){.size=64,.front={0,0,1},.top={0,1,0},.distance=1,.rolloff=1,.doppler=1};
    s->listenerPending=s->listenerNow;
    s->spatialNow=(spatial){.size=64,.inside=360,.outside=360,.direction={0,0,1},.minimum=1,.maximum=1e9};
    s->spatialPending=s->spatialNow;
    s->next=p->objects;p->objects=s;put(c,s->address,p->tables[kind]);return s;
}
static void destroy(tc_cpu *c,audio *p,sound *s) {
    sound **link=&p->objects;while(*link!=s)link=&(*link)->next;*link=s->next;
    tc_heap_free(c->heap_process,p->heap,s->address);
    if(s->data)tc_heap_free(c->heap_process,p->heap,s->data);
    sound *owner=s->owner;free(s->pcm);free(s);
    if(owner&&!--owner->references)destroy(c,p,owner);
}
void tc_direct_sound_create(_cpu *cpu) {
    tc_cpu *c=(tc_cpu *)cpu;audio *p=c->audio;cpu->_eax=INVALID;
    if(!arg(c,1))return;put(c,arg(c,1),0);
    if(arg(c,0)||arg(c,2)){cpu->_eax=UNSUPPORTED;return;}
    if(!p){cpu->_eax=OOM;return;}
    pthread_mutex_lock(&p->mutex);
    if(!p->heap){
        p->heap=tc_heap_create(c->heap_process,0,0,0);
        if(!p->heap){cpu->_eax=OOM;goto done;}
        unsigned counts[]={12,24,18,21};
        for(unsigned k=0;k<4;k++){
            p->tables[k]=tc_heap_alloc(c->heap_process,p->heap,8,counts[k]*4);
            if(!p->tables[k]){tc_heap_destroy(c->heap_process,p->heap);p->heap=0;cpu->_eax=OOM;goto done;}
            for(unsigned m=0;m<counts[k];m++)put(c,p->tables[k]+m*4,0xf0030000u+k*0x1000+m*16);
        }
    }
    sound *s=create(c,p,0);cpu->_eax=s?0:OOM;if(s)put(c,arg(c,1),s->address);
done:pthread_mutex_unlock(&p->mutex);
}
static uint32_t format(tc_cpu *c,sound *s,uint32_t a) {
    unsigned char f[16];memcpy(f,mem(c,a,16),16);
    uint16_t tag,channels,bits,align;uint32_t rate,average;
    memcpy(&tag,f,2);memcpy(&channels,f+2,2);memcpy(&rate,f+4,4);memcpy(&average,f+8,4);memcpy(&align,f+12,2);memcpy(&bits,f+14,2);
    if(tag!=1||(channels!=1&&channels!=2)||(bits!=8&&bits!=16)||rate<100||rate>200000||align!=channels*bits/8||average!=rate*align)return 0x88780064u;
    s->rate=s->frequency=rate;s->channels=channels;s->bits=bits;s->align=align;return 0;
}
static int valid_listener(listener l) {
    return l.size==64&&finite_vector(l.position)&&finite_vector(l.velocity)&&finite_vector(l.front)&&finite_vector(l.top)&&
        length(cross(l.top,l.front))>0&&isfinite(l.distance)&&l.distance>0&&
        isfinite(l.rolloff)&&l.rolloff>=0&&l.rolloff<=10&&isfinite(l.doppler)&&l.doppler>=0&&l.doppler<=10;
}
static int valid_spatial(spatial b) {
    return b.size==64&&finite_vector(b.position)&&finite_vector(b.velocity)&&finite_vector(b.direction)&&length(b.direction)>0&&
        b.inside<=b.outside&&b.outside<=360&&b.outsideVolume<=0&&b.outsideVolume>=-10000&&
        isfinite(b.minimum)&&b.minimum>0&&isfinite(b.maximum)&&b.maximum>=b.minimum&&b.mode<=2;
}
static uint32_t spatial_call(tc_cpu *c,audio *p,sound *s,unsigned kind,unsigned m) {
    int isListener=kind==2;unsigned offset=0,size=0,applyIndex=0;
    void *now=isListener?(void *)&s->owner->listenerNow:(void *)&s->spatialNow;
    void *pending=isListener?(void *)&s->owner->listenerPending:(void *)&s->spatialPending;
    if(isListener&&m==17){
        s->owner->listenerNow=s->owner->listenerPending;
        for(sound *b=p->objects;b;b=b->next)if(b->owner==s->owner)b->spatialNow=b->spatialPending;
        return 0;
    }
    unsigned firstSetter=isListener?10:12;
    /* Field offsets are the packed 32-bit DirectSound ABI, not host pointers. */
    static const unsigned listenerOffsets[]={0,52,60,28,4,56,16};
    static const unsigned listenerSizes[]={64,4,4,24,12,4,12};
    static const unsigned bufferOffsets[]={0,28,36,48,56,52,60,4,16};
    static const unsigned bufferSizes[]={64,8,12,4,4,4,4,12,12};
    if(m<3||m>=(isListener?17:21))return UNSUPPORTED;
    unsigned index=m<firstSetter?m-3:m-firstSetter;
    offset=isListener?listenerOffsets[index]:bufferOffsets[index];
    size=isListener?listenerSizes[index]:bufferSizes[index];
    if(m<firstSetter){
        if(!arg(c,1))return INVALID;
        if(index==0){uint32_t requested;memcpy(&requested,mem(c,arg(c,1),4),4);if(requested!=64)return INVALID;}
        if((isListener&&index==3)||(!isListener&&index==1)){
            if(!arg(c,2))return INVALID;
            memcpy(mem(c,arg(c,1),size/2),(char *)now+offset,size/2);
            memcpy(mem(c,arg(c,2),size/2),(char *)now+offset+size/2,size/2);
        }else memcpy(mem(c,arg(c,1),size),(char *)now+offset,size);
        return 0;
    }
    applyIndex=index==0?2:size/4+1;uint32_t apply=arg(c,applyIndex);if(apply>1)return INVALID;
    union {listener l;spatial b;} value;
    memcpy(&value,apply?pending:now,64);
    if(index==0){if(!arg(c,1))return INVALID;memcpy(&value,mem(c,arg(c,1),64),64);}
    else for(unsigned i=0;i<size/4;i++){uint32_t v=arg(c,i+1);memcpy((char *)&value+offset+i*4,&v,4);}
    if(!(isListener?valid_listener(value.l):valid_spatial(value.b)))return INVALID;
    if(!apply)memcpy((char *)now+offset,(char *)&value+offset,size);
    memcpy((char *)pending+offset,(char *)&value+offset,size);return 0;
}
static uint32_t play_options(uint32_t caps,uint32_t reserved,uint32_t priority,uint32_t flags) {
    if(reserved||(flags&~0x3fu)||(!(caps&0x40000)&&(priority||(flags&~1u)))||
       ((flags&4)&&(flags&0x3a))||((caps&1)&&!(flags&1)))return INVALID;
    /* Software mixing has no hardware voices to allocate or steal. A forced
       hardware request must fail; unrestricted requests use software. */
    if(flags&2)return 0x8878000au; /* DSERR_ALLOCATED */
    return 0;
}
static uint32_t call(tc_cpu *c,audio *p,sound *s,unsigned kind,unsigned m) {
#define A(n) arg(c,n)
    if(m==0){
        static const unsigned char unknown[16]={0,0,0,0,0,0,0,0,0xc0,0,0,0,0,0,0,0x46};
        static const unsigned char old[2][16]={{0x83,0xfa,0x9a,0x27,0x81,0x49,0xce,0x11,0xa5,0x21,0,0x20,0xaf,0x0b,0xe5,0x60},{0x85,0xfa,0x9a,0x27,0x81,0x49,0xce,0x11,0xa5,0x21,0,0x20,0xaf,0x0b,0xe5,0x60}};
        static const unsigned char newer[2][16]={{0x93,0x7e,0x0a,0xc5,0x95,0xf3,0x34,0x48,0x9e,0xf6,0x7f,0xa9,0x9d,0xe5,9,0x66},{0x49,0xa4,0x25,0x68,0x24,0x75,0x82,0x4d,0x92,0x0f,0x50,0xe3,0x6a,0xb3,0xab,0x1e}};
        if(!A(2)||!A(1))return INVALID;put(c,A(2),0);void *iid=mem(c,A(1),16);
        uint32_t address=s->address;
        if(memcmp(iid,unknown,16)&&memcmp(iid,old[s->kind],16)&&memcmp(iid,newer[s->kind],16)){
            unsigned char spatialIID[16]={0x84,0xfa,0x9a,0x27,0x81,0x49,0xce,0x11,0xa5,0x21,0,0x20,0xaf,0x0b,0xe5,0x60};
            if(!(s->flags&1))spatialIID[0]=0x86;
            if(!(s->flags&16)||memcmp(iid,spatialIID,16))return 0x80004002u;
            address+=4;
        }
        ++s->references;put(c,A(2),address);return 0;
    }
    if(m==1)return ++s->references;
    if(m==2){if(--s->references)return s->references;destroy(c,p,s);return 0;}
    if(kind>=2)return spatial_call(c,p,s,kind,m);
    if(!s->kind){
        switch(m){
        case 3:{
            if(!A(2)||!A(1))return INVALID;put(c,A(2),0);uint32_t d[9]={0};memcpy(d,mem(c,A(1),20),20);
            if((d[0]!=20&&d[0]!=36)||d[3]||A(3))return INVALID;
            /* Notifications and effects are not implemented. */
            if(d[1]&~0x7c0fbu)return UNSUPPORTED;
            if((d[1]&0x40000)&&(d[1]&0xdu))return INVALID;
            if((d[1]&16)&&(d[1]&64))return INVALID;
            if(d[1]&4)return UNSUPPORTED;
            int primary=d[1]&1;if(primary&&(d[2]||d[4]))return INVALID;
            if(!primary&&(!d[2]||d[2]>0x0fffffff||!d[4]))return INVALID;
            if(primary)for(sound *b=p->objects;b;b=b->next)if((b->flags&1)&&b->owner==s){
                if(b->flags!=d[1])return INVALID;++b->references;put(c,A(2),b->address);return 0;
            }
            sound *b=create(c,p,1);if(!b)return OOM;b->flags=d[1];b->owner=s;++s->references;
            if(d[1]&16)put(c,b->address+4,p->tables[primary?2:3]);
            uint32_t result=primary?0:format(c,b,d[4]);
            if(!result&&!primary&&(d[2]%b->align||((d[1]&16)&&b->channels!=1)))result=INVALID;
            if(!result&&!primary){
                b->size=d[2];b->pcm=malloc(b->size);b->data=tc_heap_alloc(c->heap_process,p->heap,0,b->size);
                if(!b->pcm||!b->data)result=OOM;
                else{memset(b->pcm,b->bits==8?128:0,b->size);memcpy(mem(c,b->data,b->size),b->pcm,b->size);}
            }
            if(result){destroy(c,p,b);return result;}put(c,A(2),b->address);return 0;
        }
        case 4:{uint32_t caps[24]={96,0xf1f,100,200000,1};uint32_t size;memcpy(&size,mem(c,A(1),4),4);if(size!=96)return INVALID;memcpy(mem(c,A(1),96),caps,96);return 0;}
        case 6:if(A(1)!=0xe4000001||A(2)<1||A(2)>3)return INVALID;s->cooperative=A(2);return 0;
        case 7:return s->cooperative>=2?0:0x88780046u;
        case 8:put(c,A(1),4);return 0;
        case 9:return A(1)==4?0:UNSUPPORTED;
        case 10:return 0x88780082u;
        case 11:put(c,A(1),1);return 0; /* DSUNCERTIFIED */
        default:return UNSUPPORTED;
        }
    }
    switch(m){
    case 3:{uint32_t size;memcpy(&size,mem(c,A(1),4),4);if(size!=20)return INVALID;uint32_t caps[5]={20,s->flags|((!(s->flags&0x40000)||s->allocated)?8:0),s->size,0,0};memcpy(mem(c,A(1),20),caps,20);return 0;}
    case 4:{uint32_t pos=(uint32_t)s->cursor*s->align;if(A(1))put(c,A(1),pos);if(A(2))put(c,A(2),s->size?(pos+s->frequency/100*s->align)%s->size:0);return 0;}
    case 5:{
        if(A(3))put(c,A(3),18);if(!A(1))return A(3)?0:INVALID;if(A(2)<18)return INVALID;
        unsigned char f[18]={0};uint16_t tag=1,ch=s->channels,align=s->align,bits=s->bits;uint32_t average=s->rate*s->align;
        memcpy(f,&tag,2);memcpy(f+2,&ch,2);memcpy(f+4,&s->rate,4);memcpy(f+8,&average,4);memcpy(f+12,&align,2);memcpy(f+14,&bits,2);memcpy(mem(c,A(1),18),f,18);return 0;
    }
    case 6:if(!(s->flags&0x80))return CONTROL;put(c,A(1),s->volume);return 0;
    case 7:if(!(s->flags&0x40))return CONTROL;put(c,A(1),s->pan);return 0;
    case 8:if(!(s->flags&0x20))return CONTROL;put(c,A(1),s->frequency);return 0;
    case 9:put(c,A(1),s->playing?(1|(s->looping?4:0)):0);return 0;
    case 10:return 0x88780082u;
    case 11:{
        if(!s->size||s->locked||!A(3)||!A(4)||((A(5)==0)!=(A(6)==0))||(A(7)&~3u))return INVALID;
        uint32_t offset=A(1),size=A(2);
        if(A(7)&1)offset=((uint32_t)s->cursor*s->align+s->frequency/100*s->align)%s->size;
        if(A(7)&2){offset=0;size=s->size;}
        if(offset>=s->size||!size||size>s->size)return INVALID;
        uint32_t first=size<s->size-offset?size:s->size-offset,second=size-first;
        if(second&&!A(5))return INVALID;
        s->lock[0]=s->data+offset;s->lock[1]=first;s->lock[2]=second?s->data:0;s->lock[3]=second;s->locked=1;
        put(c,A(3),s->lock[0]);put(c,A(4),first);if(A(5)){put(c,A(5),s->lock[2]);put(c,A(6),second);}return 0;
    }
    case 12:{uint32_t result=play_options(s->flags,A(1),A(2),A(3));if(result)return result;
        result=start(p,c->headless||c->audio_disabled);if(result)return result;s->allocated=1;s->playing=1;s->looping=A(3)&1;return 0;}
    case 13:if(!s->size||A(1)>=s->size)return INVALID;s->cursor=A(1)/s->align;return 0;
    case 14:if(!(s->flags&1))return 0x88780032u;if(s->owner->cooperative<2)return 0x88780046u;return format(c,s,A(1));
    case 15:if(!(s->flags&0x80))return CONTROL;if((int32_t)A(1)>0||(int32_t)A(1)<-10000)return INVALID;s->volume=A(1);return 0;
    case 16:if(!(s->flags&0x40))return CONTROL;if((int32_t)A(1)>10000||(int32_t)A(1)<-10000)return INVALID;s->pan=A(1);return 0;
    case 17:if(!(s->flags&0x20))return CONTROL;if(A(1)&&(A(1)<100||A(1)>200000))return INVALID;s->frequency=A(1)?A(1):s->rate;return 0;
    case 18:s->playing=0;return 0;
    case 19:if(!s->locked)return INVALID;for(unsigned i=0;i<4;i++)if(A(i+1)!=s->lock[i])return INVALID;
        memcpy(s->pcm+s->lock[0]-s->data,mem(c,s->lock[0],s->lock[1]),s->lock[1]);
        if(s->lock[3])memcpy(s->pcm,mem(c,s->lock[2],s->lock[3]),s->lock[3]);s->locked=0;return 0;
    case 20:return 0; /* Native snapshots cannot be lost by a Windows focus change. */
    default:return UNSUPPORTED;
    }
#undef A
}
void tc_ds_dispatch(_cpu *cpu,uint32_t method) {
    tc_cpu *c=(tc_cpu *)cpu;audio *p=c->audio;cpu->_eax=INVALID;if(!p)return;
    pthread_mutex_lock(&p->mutex);sound *s=lookup(p,arg(c,0));
    if(s&&(c->headless||c->audio_disabled))silent_advance(s,monotonic_time());
    unsigned kind=method/256;
    if(s&&((arg(c,0)==s->address&&s->kind==kind)||(arg(c,0)==s->address+4&&kind==((s->flags&1)?2:3))))cpu->_eax=call(c,p,s,kind,method%256);
    unsigned slot=method%256;
    if(c->headless&&kind<4&&slot<21&&slot!=1&&slot!=2&&
       (cpu->_eax&0x80000000u)&&!p->reportedFailure[kind][slot]) {
        p->reportedFailure[kind][slot]=1;
        fprintf(stderr,"Headless DirectSound: method=%#x rejected, HRESULT=%#x\n",method,cpu->_eax);
    }
    pthread_mutex_unlock(&p->mutex);
}
#ifdef TC_DS_SELF_CHECK
/* Optional PCM/cursor check; compile this file with TC_DS_SELF_CHECK and call
 * the resulting executable. No audio device or guest image is required. */
#include <assert.h>
int main(void) {
    assert(!play_options(0x400e0,0,7,4));
    assert(play_options(0xe0,0,7,0)==INVALID);
    assert(play_options(0x400e0,0,0,6)==INVALID);
    assert(play_options(0x400e0,0,0,2)==0x8878000au);
    unsigned char pcm[]={0,128,255};sound s={.kind=1,.size=3,.rate=48000,.frequency=48000,.channels=1,.bits=8,.align=1,.playing=1,.pcm=pcm};
    audio p={.objects=&s};float l[4]={0},r[4]={0};mix(&p,4,l,r);
    assert(l[0]==-1&&l[1]==0&&l[2]==127/128.f&&l[3]==0&&!s.playing&&s.cursor==0);
    s.playing=1;s.looping=1;memset(l,0,sizeof(l));memset(r,0,sizeof(r));mix(&p,4,l,r);
    assert(l[3]==-1&&s.playing&&s.cursor==1);
    sound owner={.listenerNow={.size=64,.front={0,0,1},.top={0,1,0},.distance=1,.rolloff=1,.doppler=1}};
    s.owner=&owner;s.flags=16;s.spatialNow=(spatial){.size=64,.position={1,0,0},.inside=360,.outside=360,.direction={0,0,1},.minimum=1,.maximum=100};
    float left=1,right=1;double step=1;spatial_gain(&s,&left,&right,&step);
    assert(left==0&&right==1&&step==1&&valid_listener(owner.listenerNow)&&valid_spatial(s.spatialNow));
    s.flags=0;s.cursor=0;s.playing=1;s.looping=0;s.silentTime=1;
    silent_advance(&s,2);assert(!s.playing&&s.cursor==0);
    assert(start(NULL,1)==0); /* Must return before dereferencing audio state. */
    /* Interpolation, wraparound, gain and pause without an audio device. */
    float movie_pcm[]={.5f,-.5f,1,-1};
    movie_audio movie={.pcm=movie_pcm,.capacity=2,.read=1,.count=2,.rate=24000,.gain=.5f};
    p.objects=NULL;p.movies=&movie;memset(l,0,sizeof(l));memset(r,0,sizeof(r));
    movie.paused=1;mix(&p,4,l,r);assert(l[0]==0&&movie.count==2);
    movie.paused=0;mix(&p,4,l,r);
    assert(l[0]==.5f&&l[1]==.375f&&l[2]==.25f&&l[3]==.25f&&r[1]==-.375f&&!movie.count);
    tc_cpu muted={.audio_disabled=1};
    assert(tc_ds_movie_write(&muted,NULL,0,0,0,0,NULL,0,0)==1&&!muted.audio);
    tc_cpu headless={.headless=1};
    assert(tc_ds_movie_write(&headless,NULL,0,0,0,0,NULL,0,0)==1);
    assert(tc_ds_movie_volume(&headless,NULL,0,32768)==1);
    assert(tc_ds_movie_pause(&headless,NULL,0)==1&&!headless.audio);
    return 0;
}
#endif
