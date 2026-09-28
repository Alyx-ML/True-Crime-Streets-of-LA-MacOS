#include "tc_dinput.h"
#include "tc_heap.h"
#include <stdlib.h>
#include <string.h>

#define INVALID 0x80070057u
#define UNSUPPORTED 0x80004001u
#define NOTACQUIRED 0x8007000cu
#define ACQUIRED 0x800700aau
#define OOM 0x8007000eu

typedef struct device {
    struct device *next;
    uint32_t address, references, kind, size, cooperative;
    int acquired, formatted;
    uint32_t offsets[256];
    int32_t minimum[8],maximum[8];
    uint32_t deadzone[8];
} device;
typedef struct { uint32_t heap,tables[2];device *objects; } process;
static const unsigned char root_iid[16]={0x30,0x80,0x79,0xbf,0x3a,0x48,0xa2,0x4d,0xaa,0x99,0x5d,0x64,0xed,0x36,0x97,0};
static const unsigned char device_iid[16]={0x80,0x10,0xd4,0x54,0x15,0xdc,0x33,0x48,0xa4,0x1b,0x74,0x8f,0x73,0xa3,0x81,0x79};
static const unsigned char keyboard_guid[16]={0x61,0x2b,0x1d,0x6f,0xa0,0xd5,0xcf,0x11,0xbf,0xc7,0x44,0x45,0x53,0x54,0,0};
static const unsigned char mouse_guid[16]={0x60,0x2b,0x1d,0x6f,0xa0,0xd5,0xcf,0x11,0xbf,0xc7,0x44,0x45,0x53,0x54,0,0};
static const unsigned char controller_guid[16]={0x54,0x43,0x4d,0x41,0x43,0x50,0x41,0x44,0x80,0,0,0,0,0,0,1};
static void *mem(tc_cpu *c,uint64_t a,uint64_t n) {
    if(!a||a>UINT32_MAX||n>c->memory_size||a>c->memory_size-n||c->scalar._pointer_offset>UINTPTR_MAX-a-n)abort();
    return (void *)(uintptr_t)(c->scalar._pointer_offset+a);
}
static uint32_t arg(tc_cpu *c,unsigned i) {uint32_t v;memcpy(&v,mem(c,(uint64_t)c->scalar._esp+4+i*4,4),4);return v;}
static void put(tc_cpu *c,uint32_t a,uint32_t v){memcpy(mem(c,a,4),&v,4);}
static device *new_device(tc_cpu *c,process *p,unsigned kind) {
    device *d=calloc(1,sizeof(*d));if(!d)return NULL;
    d->address=tc_heap_alloc(c->heap_process,p->heap,8,4);
    if(!d->address){free(d);return NULL;}
    d->kind=kind;d->references=1;d->next=p->objects;p->objects=d;
    for(unsigned i=0;i<8;i++)d->maximum[i]=65535;
    memset(d->offsets,255,sizeof(d->offsets));put(c,d->address,p->tables[kind!=0]);return d;
}
void tc_di_close(tc_cpu *c) {
    if(!c||!c->directinput)return;
    process *p=c->directinput;device *d=p->objects;
    while(d){device *next=d->next;free(d);d=next;}
    tc_heap_destroy(c->heap_process,p->heap);free(p);c->directinput=NULL;
}
void tc_direct_input_create(_cpu *cpu) {
    tc_cpu *c=(tc_cpu *)cpu;cpu->_eax=INVALID;
    if(!arg(c,3))return;put(c,arg(c,3),0);
    if(arg(c,1)!=0x800||arg(c,4)||memcmp(mem(c,arg(c,2),16),root_iid,16))return;
    process *p=c->directinput;
    if(!p) {
        p=calloc(1,sizeof(*p));if(!p){cpu->_eax=OOM;return;}
        p->heap=tc_heap_create(c->heap_process,0,0,0);
        if(!p->heap){free(p);cpu->_eax=OOM;return;}
        c->directinput=p;
        const unsigned counts[]={11,32};
        for(unsigned k=0;k<2;k++) {
            p->tables[k]=tc_heap_alloc(c->heap_process,p->heap,8,counts[k]*4);
            if(!p->tables[k]){tc_di_close(c);cpu->_eax=OOM;return;}
            for(unsigned m=0;m<counts[k];m++)put(c,p->tables[k]+m*4,0xf0020000u+k*0x1000+m*16);
        }
    }
    device *d=new_device(c,p,0);if(!d){cpu->_eax=OOM;return;}
    put(c,arg(c,3),d->address);cpu->_eax=0;
}
/* Validate and retain the actual data-format offsets, rather than assuming that
 * every caller uses c_dfDIKeyboard or c_dfDIMouse. Unmapped objects stay zero. */
static uint32_t set_format(tc_cpu *c,device *d,uint32_t address) {
    if(d->acquired)return ACQUIRED;
    uint32_t f[6];memcpy(f,mem(c,address,24),24);
    if(f[0]!=24||f[1]!=16||!f[3]||f[3]>65536||f[4]>256||(d->kind==2&&f[2]!=2)||(d->kind==3&&f[2]!=1)||
       (d->kind==1&&f[2]!=1&&f[2]!=2))return INVALID;
    uint32_t offsets[256];memset(offsets,255,sizeof(offsets));
    unsigned char used[65536]={0};
    const unsigned char *objects= f[4]?mem(c,f[5],(uint64_t)f[4]*16):NULL;
    for(unsigned i=0;i<f[4];i++) {
        uint32_t o[4];memcpy(o,objects+i*16,16);
        unsigned type=o[2]&255,instance=(o[2]>>8)&65535,slot,size;
        if(d->kind==3) {
            if((type==2||type==3)&&instance==65535&&o[0]) {
                static const unsigned char axes[]={0xe0,0xe1,0xe2,0xf4,0xf5,0xe3,0xe4,0xe4};
                const unsigned char *guid=mem(c,o[0],16);
                static const unsigned char tail[15]={2,0x6d,0xa3,0xf3,0xc9,0xcf,0x11,0xbf,0xc7,0x44,0x45,0x53,0x54,0,0};
                if(!memcmp(guid+1,tail,15))for(unsigned j=0;j<8;j++)if(guid[0]==axes[j]&&offsets[j]==UINT32_MAX){instance=j;break;}
            }
            if(instance==65535&&(type==4||type==12||type==16)) {
                unsigned base=type==16?8:12,limit=type==16?4:128;
                for(instance=0;instance<limit&&offsets[base+instance]!=UINT32_MAX;instance++){}
            }
            if((type==2||type==3)&&instance<8){slot=instance;size=4;}
            else if(type==16&&instance<4){slot=8+instance;size=4;}
            else if((type==4||type==12)&&instance<128){slot=12+instance;size=1;}
            else if(o[2]&0x80000000u)continue;
            else return UNSUPPORTED;
            if((o[3]&~0x100u)||o[1]>f[3]||size>f[3]-o[1]||offsets[slot]!=UINT32_MAX)return INVALID;
            for(unsigned j=0;j<size;j++){if(used[o[1]+j])return INVALID;used[o[1]+j]=1;}
            offsets[slot]=o[1];continue;
        }
        if(d->kind==2&&(type==1||type==3)&&instance==65535&&o[0]) {
            const unsigned char *guid=mem(c,o[0],16);
            static const unsigned char tail[15]={2,0x6d,0xa3,0xf3,0xc9,0xcf,0x11,0xbf,0xc7,0x44,0x45,0x53,0x54,0,0};
            if(guid[0]>=0xe0&&guid[0]<=0xe2&&!memcmp(guid+1,tail,15))instance=guid[0]-0xe0;
        }
        if((type==4||type==12)&&instance==65535) {
            unsigned limit=d->kind==1?256:8,start=d->kind==1?0:3;
            for(instance=0;instance<limit&&offsets[start+instance]!=UINT32_MAX;instance++){}
        }
        if(d->kind==1) { if((type!=4&&type!=12)||instance>255)return UNSUPPORTED;slot=instance;size=1; }
        else if((type==1||type==3)&&instance<3){slot=instance;size=4;}
        else if((type==4||type==12)&&instance<8){slot=3+instance;size=1;}
        else return UNSUPPORTED;
        if(o[3]||o[1]>f[3]||size>f[3]-o[1]||offsets[slot]!=UINT32_MAX)return INVALID;
        for(unsigned j=0;j<size;j++){if(used[o[1]+j])return INVALID;used[o[1]+j]=1;}
        offsets[slot]=o[1];
    }
    memcpy(d->offsets,offsets,sizeof(offsets));d->size=f[3];d->formatted=1;return 0;
}
static void controller_info(unsigned char info[580]) {
    memset(info,0,580);uint32_t size=580,type=0x15;memcpy(info,&size,4);
    memcpy(info+4,controller_guid,16);memcpy(info+20,controller_guid,16);memcpy(info+36,&type,4);
    strcpy((char *)info+40,"Mac Controller");strcpy((char *)info+300,"Mac Controller");
    uint16_t usage[]={1,5};memcpy(info+576,usage,4);
}
static uint32_t controller_property(tc_cpu *c,device *d,uint32_t property,uint32_t address,int setting) {
    uint32_t h[4];memcpy(h,mem(c,address,16),16);
    if(h[1]!=16||h[3]>2||h[0]!=(property==4?24u:20u))return INVALID;
    unsigned first=0,last=8;
    if(h[3]) {
        if(h[3]==1){for(first=0;first<8&&d->offsets[first]!=h[2];first++){};}
        else first=(h[2]>>8)&65535;
        if(first>=8)return 0x80070002u;last=first+1;
    }
    if(property==4) {
        int32_t range[2];
        if(setting){memcpy(range,mem(c,address+16,8),8);if(range[0]>=range[1])return INVALID;
            for(unsigned i=first;i<last;i++){d->minimum[i]=range[0];d->maximum[i]=range[1];}}
        else {range[0]=d->minimum[first];range[1]=d->maximum[first];memcpy(mem(c,address+16,8),range,8);}
        return 0;
    }
    if(property==5) {
        if(setting){uint32_t value;memcpy(&value,mem(c,address+16,4),4);if(value>10000)return INVALID;
            for(unsigned i=first;i<last;i++)d->deadzone[i]=value;}
        else put(c,address+16,d->deadzone[first]);return 0;
    }
    return UNSUPPORTED;
}
static int32_t controller_axis(device *d,unsigned axis,int32_t raw) {
    int32_t magnitude=raw<0?-raw:raw,threshold=d->deadzone[axis]/10;
    int64_t scaled=magnitude<=threshold?0:(int64_t)(magnitude-threshold)*1000/(1000-threshold);
    if(raw<0)scaled=-scaled;
    return (int32_t)(d->minimum[axis]+((int64_t)d->maximum[axis]-d->minimum[axis])*(scaled+1000)/2000);
}
static uint32_t call(tc_cpu *c,process *p,device *d,unsigned m) {
#define A(n) arg(c,n)
    if(m==0) {
        static const unsigned char unknown[16]={0,0,0,0,0,0,0,0,0xc0,0,0,0,0,0,0,0x46};
        put(c,A(2),0);const void *iid=mem(c,A(1),16);
        if(memcmp(iid,unknown,16)&&memcmp(iid,d->kind?device_iid:root_iid,16))return 0x80004002u;
        ++d->references;put(c,A(2),d->address);return 0;
    }
    if(m==1)return ++d->references;
    if(m==2) {
        if(--d->references)return d->references;
        device **link=&p->objects;while(*link!=d)link=&(*link)->next;*link=d->next;
        tc_heap_free(c->heap_process,p->heap,d->address);free(d);return 0;
    }
    if(!d->kind) {
        if(m==3) {
            put(c,A(2),0);if(A(3))return INVALID;
            const void *guid=mem(c,A(1),16);
            unsigned kind=!memcmp(guid,keyboard_guid,16)?1:!memcmp(guid,mouse_guid,16)?2:!memcmp(guid,controller_guid,16)?3:0;
            if(!kind)return 0x80070002u;
            device *next=new_device(c,p,kind);if(!next)return OOM;put(c,A(2),next->address);return 0;
        }
        if(m==4) {
            if(!A(2))return INVALID;
            if((A(1)==4||A(1)==0||A(1)==0x15)&&A(4)<=1) {
                /* One virtual Mac controller remains available across physical
                 * connection changes, so the original remapping menu stays usable. */
                if(!p||!c->guest_invoke)return UNSUPPORTED;
                uint32_t info=tc_heap_alloc(c->heap_process,p->heap,8,580);if(!info)return OOM;
                unsigned char description[580];controller_info(description);memcpy(mem(c,info,580),description,580);
                uint32_t callback=A(2),context=A(3),frame[]={UINT32_MAX,info,context};_cpu saved=c->scalar;
                if(c->scalar._esp<12){tc_heap_free(c->heap_process,p->heap,info);return INVALID;}
                c->scalar._esp-=12;memcpy(mem(c,c->scalar._esp,12),frame,12);
                c->guest_invoke(&c->scalar,callback);c->scalar=saved;
                tc_heap_free(c->heap_process,p->heap,info);return 0;
            }
            return UNSUPPORTED;
        }
        if(m==5) {const void *guid=mem(c,A(1),16);return !memcmp(guid,keyboard_guid,16)||!memcmp(guid,mouse_guid,16)||!memcmp(guid,controller_guid,16)?0:0x80070002u;}
        if(m==7)return A(2)==0x800?0:INVALID;
        return UNSUPPORTED;
    }
    switch(m) {
    case 3: {
        uint32_t size;memcpy(&size,mem(c,A(1),4),4);if(size!=24&&size!=44)return INVALID;
        uint32_t caps[11]={size,1,d->kind==1?0x413u:d->kind==3?0x15u:0x212u,d->kind==1?0:d->kind==3?6:3,d->kind==1?256:d->kind==3?16:8,d->kind==3?1:0};
        memcpy(mem(c,A(1),size),caps,size);return 0;
    }
    case 5:case 6:return d->kind==3?controller_property(c,d,A(1),A(2),m==6):UNSUPPORTED;
    case 7:if(!d->formatted)return INVALID;if(d->acquired)return 1;d->acquired=1;return 0;
    case 8:{int was=d->acquired;d->acquired=0;return was?0:1;}
    case 9: {
        if(!d->acquired)return NOTACQUIRED;if(A(1)!=d->size)return INVALID;
        unsigned char *out=mem(c,A(2),d->size);memset(out,0,d->size);
        if(d->kind==1) {
            if(!c->frame_input)return UNSUPPORTED;c->frame_input(&c->scalar);
            for(unsigned i=0;i<256;i++)if(d->offsets[i]!=UINT32_MAX)out[d->offsets[i]]=c->input_keyboard[i];
        } else if(d->kind==3) {
            if(!c->read_controller)return UNSUPPORTED;
            int32_t axes[8]={0};uint32_t pov[4];unsigned char buttons[128]={0};
            memset(pov,255,sizeof(pov));c->read_controller(&c->scalar,axes,pov,buttons);
            for(unsigned i=0;i<8;i++)if(d->offsets[i]!=UINT32_MAX){int32_t value=controller_axis(d,i,axes[i]);memcpy(out+d->offsets[i],&value,4);}
            for(unsigned i=0;i<4;i++)if(d->offsets[8+i]!=UINT32_MAX)memcpy(out+d->offsets[8+i],&pov[i],4);
            for(unsigned i=0;i<128;i++)if(d->offsets[12+i]!=UINT32_MAX)out[d->offsets[12+i]]=buttons[i];
        } else {
            if(!c->read_mouse)return UNSUPPORTED;int32_t axes[3]={0};unsigned char buttons[8]={0};
            c->read_mouse(&c->scalar,axes,buttons);
            for(unsigned i=0;i<3;i++)if(d->offsets[i]!=UINT32_MAX)memcpy(out+d->offsets[i],&axes[i],4);
            for(unsigned i=0;i<8;i++)if(d->offsets[3+i]!=UINT32_MAX)out[d->offsets[3+i]]=buttons[i];
        }return 0;
    }
    case 11:return set_format(c,d,A(1));
    case 12:return A(1)?UNSUPPORTED:0;
    case 13:
        if(d->acquired)return ACQUIRED;
        if((A(2)&~31u)||((A(2)&3)!=1&&(A(2)&3)!=2)||((A(2)&12)!=4&&(A(2)&12)!=8))return INVALID;
        if((A(2)&1)&&d->kind!=3)return UNSUPPORTED;
        d->cooperative=A(2);return 0;
    case 15: {
        if(d->kind!=3)return UNSUPPORTED;
        uint32_t size;memcpy(&size,mem(c,A(1),4),4);if(size!=580&&size!=560)return INVALID;
        unsigned char info[580];controller_info(info);memcpy(info,&size,4);memcpy(mem(c,A(1),size),info,size);return 0;
    }
    case 25:return d->acquired?0:NOTACQUIRED;
    default:return UNSUPPORTED;
    }
#undef A
}
void tc_di_dispatch(_cpu *cpu,uint32_t method) {
    tc_cpu *c=(tc_cpu *)cpu;process *p=c->directinput;cpu->_eax=INVALID;if(!p)return;
    uint32_t address=arg(c,0);device *d=p->objects;
    while(d&&d->address!=address)d=d->next;
    if(!d || (method>>8)!=(d->kind!=0))return;
    cpu->_eax=call(c,p,d,method&255);
}
#ifdef TC_DI_SELF_CHECK
#include <assert.h>
int main(void) {
    unsigned char bytes[4096]={0};tc_cpu c={0};c.scalar._pointer_offset=(uintptr_t)bytes;c.memory_size=sizeof(bytes);
    device d={.kind=1};uint32_t f[]={24,16,2,256,1,128},o[]={0,31,(31<<8)|12,0};
    memcpy(bytes+64,f,24);memcpy(bytes+128,o,16);
    assert(set_format(&c,&d,64)==0&&d.offsets[31]==31&&d.offsets[0]==UINT32_MAX);
    o[1]=256;memcpy(bytes+128,o,16);assert(set_format(&c,&d,64)==INVALID&&d.offsets[31]==31);
    d.acquired=1;assert(set_format(&c,&d,64)==ACQUIRED);
    device mouse={.kind=2};uint32_t mf[]={24,16,2,16,1,128},axis[]={256,0,0x00ffff03,0};
    const unsigned char guid[]={0xe0,2,0x6d,0xa3,0xf3,0xc9,0xcf,0x11,0xbf,0xc7,0x44,0x45,0x53,0x54,0,0};
    memcpy(bytes+64,mf,24);memcpy(bytes+128,axis,16);memcpy(bytes+256,guid,16);
    assert(set_format(&c,&mouse,64)==0&&mouse.offsets[0]==0);
    axis[2]=0x00ffff02;memcpy(bytes+128,axis,16);assert(set_format(&c,&mouse,64)==UNSUPPORTED);
    device root={0};c.scalar._esp=32;
    uint32_t enumeration[]={16,4,0x1234,0,1};memcpy(bytes+36,enumeration,sizeof(enumeration));
    assert(call(&c,NULL,&root,4)==UNSUPPORTED);
    enumeration[2]=0;memcpy(bytes+36,enumeration,sizeof(enumeration));assert(call(&c,NULL,&root,4)==INVALID);
    device pad={.kind=3};for(unsigned i=0;i<8;i++)pad.maximum[i]=65535;
    uint32_t pf[]={24,16,1,80,3,128},po[]={256,0,0x80ffff03,0x100,0,32,0x80ffff10,0,0,48,0x80ffff0c,0};
    memcpy(bytes+64,pf,24);memcpy(bytes+128,po,sizeof(po));memcpy(bytes+256,guid,16);
    assert(set_format(&c,&pad,64)==0&&pad.offsets[0]==0&&pad.offsets[8]==32&&pad.offsets[12]==48);
    assert(controller_axis(&pad,0,-1000)==0&&controller_axis(&pad,0,1000)==65535);
    uint32_t range[]={24,16,0,1,(uint32_t)-1000,1000};memcpy(bytes+300,range,sizeof(range));
    assert(controller_property(&c,&pad,4,300,1)==0&&controller_axis(&pad,0,0)==0);
    unsigned char info[580];controller_info(info);assert(!memcmp(info+4,controller_guid,16)&&!strcmp((char *)info+300,"Mac Controller"));
    return 0;
}
#endif
