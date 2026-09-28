#import <Foundation/Foundation.h>
#include "tc_modern.h"
#include "tc_heap.h"
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>
#include <math.h>
#include <assert.h>

typedef struct {
    atomic_uint values[TC_MODERN_COUNT], bindings[TC_KEYBOARD_ACTION_COUNT];
    atomic_int waiting;
    uint32_t heap, controlsScreen, previousButtons;
    unsigned editAction,bindingPage,targetFrames;
    int targetDirection,targetPulse;
    BOOL bindingVisible, axisVisible;
    uint32_t nameScreen, nameButtons, nameReleaseButtons;
    unsigned nameSelection;
    int nameSource;
    BOOL nameLower;
    double nameRepeat;
    int connected, controllerActive;
    uint32_t virtualSize[2], outputSize[2];
    char controllerName[96];
} Modern;
static const tc_keyboard_action actions[]={
#include "tc_keyboard_bindings.inc"
};
static const char *buttonNames[]={"A / Cross", "B / Circle", "X / Square", "Y / Triangle",
    "LB / L1", "RB / R1", "LT / L2", "RT / R2", "L3", "R3", "D-pad Up", "D-pad Down",
    "D-pad Left", "D-pad Right", "Menu / Options", "Back / Share"};
_Static_assert(sizeof(buttonNames)/sizeof(*buttonNames)==TC_PAD_BUTTON_COUNT,"Controller label count");
/* PC actions keep their original scan codes; driving actions are context gated.
   Fire/Aim (tap: auto-aimed shot, hold: precision aim and fire) is on R2, Reload on R1. */
static const unsigned defaultBindings[TC_KEYBOARD_ACTION_COUNT]={
    UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX,
    TC_PAD_RIGHT_STICK,TC_PAD_RIGHT_TRIGGER,UINT32_MAX,TC_PAD_LEFT_SHOULDER,TC_PAD_OPTIONS,
    TC_PAD_LEFT,TC_PAD_UP,TC_PAD_RIGHT,TC_PAD_Y,TC_PAD_A,TC_PAD_X,TC_PAD_LEFT_TRIGGER,
    TC_PAD_B,UINT32_MAX,TC_PAD_LEFT_STICK,UINT32_MAX,TC_PAD_LEFT_TRIGGER,TC_PAD_RIGHT_SHOULDER,
    TC_PAD_A,TC_PAD_X,TC_PAD_B,TC_PAD_LEFT,TC_PAD_RIGHT,TC_PAD_Y,TC_PAD_UP,TC_PAD_DOWN
};
static const unsigned limits[]={0,30,60,90,120,144,165,240};
static const unsigned defaults[]={60,1,0,15,100,0,0,0,0,0,0,0,1,1};
static NSString *const keys[]={@"FrameLimit",@"VSync",@"MetalFX",@"Deadzone",@"LookSpeed",@"CameraInvertY",@"CameraInvertX",@"InvertMoveX",@"InvertMoveY",@"SwapSticks",@"ConfirmB",@"HDR",@"MSAA",@"UIScale"};
static BOOL valid(unsigned key,unsigned value) {
    switch(key) {
        case TC_FRAME_LIMIT:for(unsigned i=0;i<sizeof(limits)/sizeof(*limits);i++)if(value==limits[i])return YES;return NO;
        case TC_VSYNC:case TC_INVERT_LOOK:case TC_INVERT_LOOK_X:case TC_INVERT_MOVE_X:case TC_INVERT_MOVE_Y:
        case TC_SWAP_STICKS:case TC_CONFIRM_B:return value<=1;
        case TC_MSAA:return value<=2;
        case TC_UI_SCALE:return value<=1;
        case TC_HDR:return value<=3;
        case TC_METALFX:return value<=3;
        case TC_DEADZONE:return value<=40&&value%5==0;
        case TC_LOOK_SPEED:return value>=50&&value<=200&&value%25==0;
        default:return NO;
    }
}
void tc_modern_init(tc_cpu *c) {
    if(c->modern)return;
    Modern *m=calloc(1,sizeof(*m));if(!m)abort();
    m->heap=tc_heap_create(c->heap_process,0,0,0);if(!m->heap)abort();
    /* New camera keys default to the corrected direction on existing installs,
       without inheriting the earlier raw-axis workaround. */
    NSDictionary *saved=[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ModernGameOptions"];
    for(unsigned i=0;i<TC_MODERN_COUNT;i++) {
        id v=saved[keys[i]];unsigned value=[v isKindOfClass:NSNumber.class]?[v unsignedIntValue]:defaults[i];
        atomic_init(&m->values[i],valid(i,value)?value:defaults[i]);
    }
    NSArray *bindings=[[NSUserDefaults standardUserDefaults]arrayForKey:@"ModernControllerBindings"];
    for(unsigned i=0;i<TC_KEYBOARD_ACTION_COUNT;i++) {
        id value=bindings.count==TC_KEYBOARD_ACTION_COUNT?bindings[i]:nil;
        unsigned button=[value isKindOfClass:NSNumber.class]?[value unsignedIntValue]:defaultBindings[i];
        atomic_init(&m->bindings[i],button<TC_PAD_BUTTON_COUNT?button:UINT32_MAX);
    }
    atomic_init(&m->waiting,-1);c->modern=m;
}
void tc_modern_close(tc_cpu *c) {
    Modern *m=c->modern;if(!m)return;
    tc_heap_destroy(c->heap_process,m->heap);free(m);c->modern=NULL;
}
static uint32_t word(tc_cpu *c,uint32_t address);
static void put(tc_cpu *c,uint32_t address,uint32_t v);
uint32_t tc_modern_virtual_screen(tc_cpu *c,int height,uint32_t width_value,uint32_t height_value) {
    Modern *m=c->modern;
    if(!m||!tc_modern_get(c,TC_UI_SCALE)||height_value<=480||!width_value||width_value>16384||height_value>16384)
        return height?height_value:width_value;
    uint32_t w=(uint32_t)llround(480.0*width_value/height_value);
    m->virtualSize[0]=w;m->virtualSize[1]=480;m->outputSize[0]=width_value;m->outputSize[1]=height_value;
    /* The renderer looks up the configured size in its 15 width/height/depth
       records (0x68d5a8); give the output size's records the virtual size. */
    for(uint32_t record=0x68d5a8;record<0x68d5a8+15*12;record+=12)
        if(word(c,record)==width_value&&word(c,record+4)==height_value){put(c,record,w);put(c,record+4,480);}
    return height?480:w;
}
void tc_modern_virtual_mode(tc_cpu *c,uint32_t *width,uint32_t *height) {
    Modern *m=c->modern;
    if(m&&m->outputSize[0]&&*width==m->outputSize[0]&&*height==m->outputSize[1]){*width=m->virtualSize[0];*height=m->virtualSize[1];}
}
uint32_t tc_modern_real_screen(tc_cpu *c,int height,uint32_t value) {
    Modern *m=c->modern;
    return m&&m->outputSize[0]&&value==m->virtualSize[height!=0]?m->outputSize[height!=0]:value;
}
void tc_modern_output(tc_cpu *c,uint32_t width,uint32_t height,uint32_t *out_width,uint32_t *out_height) {
    Modern *m=c->modern;*out_width=width;*out_height=height;
    if(m&&m->outputSize[0]&&width==m->virtualSize[0]&&height==m->virtualSize[1]) {
        *out_width=m->outputSize[0];*out_height=m->outputSize[1];
    }
}
unsigned tc_modern_get(tc_cpu *c,unsigned key) {
    Modern *m=c->modern;return key<TC_MODERN_COUNT?(m?atomic_load(&m->values[key]):defaults[key]):0;
}
void tc_modern_set(tc_cpu *c,unsigned key,unsigned value) {
    Modern *m=c->modern;if(!m||!valid(key,value))return;
    atomic_store(&m->values[key],value);
    NSMutableDictionary *saved=[NSMutableDictionary new];
    for(unsigned i=0;i<TC_MODERN_COUNT;i++)saved[keys[i]]=@(atomic_load(&m->values[i]));
    [[NSUserDefaults standardUserDefaults]setObject:saved forKey:@"ModernGameOptions"];
}
static void save_bindings(Modern *m) {
    NSMutableArray *bindings=[NSMutableArray new];
    for(unsigned i=0;i<TC_KEYBOARD_ACTION_COUNT;i++)[bindings addObject:@(atomic_load(&m->bindings[i]))];
    [[NSUserDefaults standardUserDefaults]setObject:bindings forKey:@"ModernControllerBindings"];
}
int tc_modern_button_bound(tc_cpu *c,unsigned button) {
    Modern *m=c->modern;if(!m)return 0;
    if(atomic_load(&m->waiting)>=0)return 1;
    for(unsigned i=0;i<TC_KEYBOARD_ACTION_COUNT;i++)if(atomic_load(&m->bindings[i])==button)return 1;
    return 0;
}
static uint32_t word(tc_cpu *c,uint32_t address);
/* Grid below the licence plate; SP/DEL/OK/ESC get wider cells. */
static unsigned cell_x(unsigned r) {return r>=40?32:r>=36?224+48*(r-36):32+32*(r%10);}
static unsigned cell_y(unsigned r) {return r<40?150+18*(r/10):230+14*(r-40);}
static uint32_t find_item(tc_cpu *c,uint32_t list,unsigned event);
static uint32_t invoke(tc_cpu *c,uint32_t fn,uint32_t self,const uint32_t *args,unsigned count);
static BOOL name_input(tc_cpu *c,tc_input *input,uint32_t screen);
void tc_modern_input(tc_cpu *c,tc_input *input) {
    if(getenv("TC_MENU_TRACE")) {
        static uint32_t previous;
        uint32_t manager=word(c,0x728320);
        uint32_t screen=manager?word(c,manager):0;
        if(screen&&screen!=previous) {
            previous=screen;
            fprintf(stderr,"[menu] active=%08x vtable=%08x\n",screen,word(c,screen));
            for(unsigned i=0;i<50;i++)if(word(c,manager+0x10+4*i)==screen)fprintf(stderr,"[menu] screen id=%u\n",i);
        }
    }
    if(c->headless&&getenv("TC_MISSION_MENU_CHECK")) {
        static unsigned frames;
        uint32_t manager=word(c,0x728320);
        if(manager&&word(c,manager+0x18)) {
            if(!frames){const uint32_t args[]={2,0};invoke(c,0x558670,manager,args,2);}
            if(++frames==180){fprintf(stderr,"Mission menu survived 180 input/render updates.\n");exit(0);}
        }
    }
    /* Opt-in headless screenshot of an original screen with the added rows:
       TC_CAPTURE_SCREEN=graphics|name TC_HEADLESS_FRAME=/path.png (no saves written). */
    const char *capture=c->headless?getenv("TC_CAPTURE_SCREEN"):NULL,*frame=getenv("TC_HEADLESS_FRAME");
    if(capture&&frame&&c->modern) {
        static unsigned frames;uint32_t manager=word(c,0x728320);
        if(manager&&word(c,manager)&&word(c,manager+0x14)) {
            if(frames==60) {
                if(!strcmp(capture,"name")){const uint32_t open[]={1,15};invoke(c,0x558670,manager,open,2);}
                else for(unsigned id=0;id<50;id++) {
                    uint32_t screen=word(c,manager+0x10+4*id);
                    if(screen&&word(c,screen)==0x683218){const uint32_t open[]={id,0};invoke(c,0x558670,manager,open,2);break;}
                }
            }
            if(++frames==150){char request[1024];snprintf(request,sizeof(request),"%s.request",frame);fclose(fopen(request,"w"));}
            if(frames==180)exit(0);
        }
    }
    if(c->headless&&getenv("TC_MEMMOVE_CHECK")&&c->modern) {
        Modern *m=c->modern;uint32_t buffer=tc_heap_alloc(c->heap_process,m->heap,0,256);
        if(!buffer)abort();
        unsigned char expected[256];
        for(unsigned align=0;align<4;align++)for(int distance=-40;distance<=40;distance++)
            for(unsigned length=0;length<=64;length++) {
                for(unsigned i=0;i<256;i++)expected[i]=(unsigned char)(i*37+11);
                memcpy((void *)(c->scalar._pointer_offset+buffer),expected,sizeof(expected));
                unsigned source=80+align,destination=source+distance;
                memmove(expected+destination,expected+source,length);
                const uint32_t args[]={buffer+destination,buffer+source,length};
                uint32_t result=invoke(c,0x663250,0,args,3);
                if(result!=args[0]||memcmp(expected,(void *)(c->scalar._pointer_offset+buffer),sizeof(expected))) {
                    fprintf(stderr,"Original memmove check failed: alignment=%u distance=%d length=%u\n",align,distance,length);abort();
                }
            }
        tc_heap_free(c->heap_process,m->heap,buffer);
        fprintf(stderr,"Original memmove check passed: 21060 aligned, unaligned, overlapping and zero-length copies.\n");
        exit(0);
    }
    if(c->headless&&getenv("TC_NAME_ENTRY_CHECK")) {
        uint32_t manager=word(c,0x728320);
        if(manager&&word(c,manager+0x14)&&c->modern) {
            const uint32_t open[]={1,15};invoke(c,0x558670,manager,open,2);
            uint32_t screen=word(c,manager);tc_input probe={0};
            if(!(name_input(c,&probe,screen))){fprintf(stderr,"Name entry check failed at line %d\n",__LINE__);abort();}
            if(!(word(c,0x7511b4)==screen+0xb18)){fprintf(stderr,"Name entry check failed at line %d\n",__LINE__);abort();}
            for(const char *p="Nick12345";*p;p++) {
                const uint32_t message[]={0,0x102,(unsigned char)*p,1};
                invoke(c,0x612a90,0,message,4);
            }
            if(!(word(c,screen+0xb30)==7)){fprintf(stderr,"Name entry check failed at line %d\n",__LINE__);abort();}
            if(!(!memcmp((void *)(c->scalar._pointer_offset+screen+0xb18),"Nick123",7))){fprintf(stderr,"Name entry check failed at line %d\n",__LINE__);abort();}
            probe.controller[TC_PAD_X]=1;name_input(c,&probe,screen);
            if(!(word(c,screen+0xb30)==6)){fprintf(stderr,"Name entry check failed at line %d\n",__LINE__);abort();}
            memset(&probe,0,sizeof(probe));name_input(c,&probe,screen);
            probe.controller[TC_PAD_A]=1;name_input(c,&probe,screen);
            if(!(word(c,screen+0xb30)==7)){fprintf(stderr,"Name entry check failed at line %d\n",__LINE__);abort();}
            if(!(*((char *)(c->scalar._pointer_offset+screen+0xb18+6))=='A')){fprintf(stderr,"Name entry check failed at line %d\n",__LINE__);abort();}
            uint32_t list=word(c,screen+0x88);
            for(unsigned i=0;i<42;i++) {
                uint32_t item=find_item(c,list,1200+i);
                if(!(item&&!(word(c,item+8)&0x800)&&word(c,item+0x110))){fprintf(stderr,"Name entry check failed at line %d\n",__LINE__);abort();}
                if(!(word(c,item+0x24)==cell_x(i)&&word(c,item+0x28)==cell_y(i))){fprintf(stderr,"Name entry check failed at line %d\n",__LINE__);abort();}
                unsigned width=invoke(c,0x559330,item+0x98,NULL,0);
                if(width>(i<36?30u:i<40?46u:560u)){fprintf(stderr,"Name entry cell %u is %u px wide\n",i,width);abort();}
            }
            memset(&probe,0,sizeof(probe));name_input(c,&probe,screen);
            probe.controller[TC_PAD_MENU]=1;name_input(c,&probe,screen);
            if(!(!word(c,0x7511bc)&&word(c,screen+0xb30)==7)){fprintf(stderr,"Name entry check failed at line %d\n",__LINE__);abort();}
            /* Reopen before a game update can create a save, then cancel. */
            const uint32_t reopen[]={15,0};invoke(c,0x563800,screen,reopen,2);
            memset(&probe,0,sizeof(probe));name_input(c,&probe,screen);
            probe.controller[TC_PAD_B]=1;name_input(c,&probe,screen);
            if(!(!word(c,0x7511bc)&&word(c,screen+0xb30)==UINT32_MAX)){fprintf(stderr,"Name entry check failed at line %d\n",__LINE__);abort();}
            fprintf(stderr,"Name entry check passed: characters, limit, controller select/delete/confirm/cancel, original widget positions. No save written.\n");
            exit(0);
        }
    }
    if(c->headless&&getenv("TC_MENU_TRACE_OPEN")) {
        static BOOL opened;
        uint32_t manager=word(c,0x728320);
        if(!opened&&manager&&word(c,manager)&&word(c,manager+0x24)) {
            opened=YES;const uint32_t args[]={5,0};
            invoke(c,0x558670,manager,args,2);
            uint32_t list=word(c,word(c,manager+0x24)+0x88);
            uint32_t first=word(c,word(c,list+0x74)+8);
            const uint32_t openBindings[]={1100,0};invoke(c,0x575e30,word(c,manager+0x24),openBindings,2);
            for(unsigned event=1105;event<=1108;event++) {
                uint32_t item=find_item(c,list,event);
                if(!item||(word(c,item+0xa0)&7)!=(word(c,first+0xa0)&7)||
                   word(c,item+0x110)!=word(c,first+0x110)||
                   word(c,item+0x24)!=word(c,first+0x24)||
                   !word(c,item+0x90)||!word(c,item+0x94)||(word(c,item+8)&0x900)||
                   word(c,item+0x28)>188) {
                    fprintf(stderr,"Menu row check failed: %u\n",event);abort();
                }
            }
        }
    }
    Modern *m=c->modern;
    memset(input->controller_actions,0,sizeof(input->controller_actions));
    memset(input->controller_keys,0,sizeof(input->controller_keys));
    if(!m){memset(input->controller,0,sizeof(input->controller));return;}
    if(m->connected!=input->controller_connected||m->controllerActive!=input->controller_active||strcmp(m->controllerName,input->controller_name)) {
        m->controllerActive=input->controller_active;
        m->connected=input->controller_connected;
        snprintf(m->controllerName,sizeof(m->controllerName),"%s",input->controller_name);
        uint32_t manager=word(c,0x728320);
        if(manager&&m->controlsScreen&&word(c,manager)==m->controlsScreen)
            tc_menu_refresh(&c->scalar,m->controlsScreen,1);
    }
    input->stick_deadzone_percent=tc_modern_get(c,TC_DEADZONE);
    if(tc_modern_get(c,TC_SWAP_STICKS)) {
        float left[2]={input->sticks[0],input->sticks[1]};
        input->sticks[0]=input->sticks[2];input->sticks[1]=input->sticks[3];
        input->sticks[2]=left[0];input->sticks[3]=left[1];
    }
    if(tc_modern_get(c,TC_INVERT_MOVE_X))input->sticks[0]=-input->sticks[0];
    if(tc_modern_get(c,TC_INVERT_MOVE_Y))input->sticks[1]=-input->sticks[1];
    uint32_t manager=word(c,0x728320),screen=manager?word(c,manager):0;
    /* Any active manager screen is a menu (gameplay has none). The byte at
       screen+0x74 is clear in some states, e.g. file select 0x681ee0. */
    BOOL menu=screen!=0;
    if(name_input(c,input,screen))return;
    uint32_t player=word(c,0x6d9578);
    unsigned mode=player?*((unsigned char *)(c->scalar._pointer_offset+player+9)):0;
    /* Right stick drives the camera exactly like the mouse on both axes: right
       looks right and up looks up by default (the original, like the PS2 release,
       felt inverted). User Invert options remain available. */
    if(tc_modern_get(c,TC_INVERT_LOOK_X))input->sticks[2]=-input->sticks[2];
    uint32_t pressed=0;
    for(unsigned i=0;i<TC_PAD_BUTTON_COUNT;i++)if(input->controller[i])pressed|=1u<<i;
    int action=atomic_load(&m->waiting);
    if(action>=0) {
        uint32_t fresh=pressed&~m->previousButtons;
        if(input->keyboard[1]||fresh) {
            if(!input->keyboard[1]) {
                unsigned button=0;while(!(fresh&(1u<<button)))button++;
                atomic_store(&m->bindings[action],button);save_bindings(m);
            }
            atomic_store(&m->waiting,-1);
            if(m->controlsScreen)tc_menu_refresh(&c->scalar,m->controlsScreen,1);
        }
        memset(input->controller,0,sizeof(input->controller));
        memset(input->sticks,0,sizeof(input->sticks));
    } else if(menu) {
        if(input->sticks[0]<-0.5f)input->controller[TC_PAD_LEFT]=1;
        if(input->sticks[0]>0.5f)input->controller[TC_PAD_RIGHT]=1;
        if(input->sticks[1]>0.5f)input->controller[TC_PAD_UP]=1;
        if(input->sticks[1]<-0.5f)input->controller[TC_PAD_DOWN]=1;
        BOOL swap=tc_modern_get(c,TC_CONFIRM_B)!=0;
        input->controller_keys[swap?TC_PAD_B:TC_PAD_A]=28;
        input->controller_keys[swap?TC_PAD_A:TC_PAD_B]=input->controller_keys[TC_PAD_Y]=1;
        input->controller_keys[TC_PAD_UP]=200;input->controller_keys[TC_PAD_DOWN]=208;
        input->controller_keys[TC_PAD_LEFT]=203;input->controller_keys[TC_PAD_RIGHT]=205;
        memset(input->sticks,0,sizeof(input->sticks));
    } else {
        for(unsigned i=0;i<TC_KEYBOARD_ACTION_COUNT;i++) {
            BOOL common=i==9||i==11||i==12||i==25;
            if(!common&&((mode==5)!=(i>=26)))continue;
            if(i==19&&mode!=1)continue;
            if(i==24&&mode!=2&&mode!=4)continue;
            unsigned button=atomic_load(&m->bindings[i]);
            if(button<TC_PAD_BUTTON_COUNT)input->controller_actions[button]|=UINT64_C(1)<<i;
        }
        /* PC mouse steering also consumes camera motion. Use left-stick keys
           for steering, and reserve right-stick mouse motion for on-foot look. */
        if(mode==5)input->sticks[2]=input->sticks[3]=0;
        /* Lock-on aim: while Fire/Aim is held, flick the right stick to switch
           targets through the game's own Pan Left/Right actions (6/7). */
        unsigned aim=atomic_load(&m->bindings[9]);
        /* Precision aim (player+0xd68 == 3) keeps free right-stick aiming. */
        BOOL aiming=mode!=5&&aim<TC_PAD_BUTTON_COUNT&&input->controller[aim]&&!(player&&word(c,player+0xd68)==3);
        int flick=input->sticks[2]<-0.7f?-1:input->sticks[2]>0.7f?1:0;
        if(aiming&&flick&&flick!=m->targetDirection){m->targetFrames=4;m->targetPulse=flick;}
        m->targetDirection=aiming?flick:0;
        if(m->targetFrames) {
            m->targetFrames--;
            uint32_t scan=word(c,actions[m->targetPulse<0?6:7].guest_address);
            if(scan&&scan<256)input->keyboard[scan]=0x80;
        }
        if(aiming)input->sticks[2]=0;
    }
    /* Confirm always also sends Enter: some original menus (pause, save screens) are
       not flagged at screen+0x74, and no game action uses Enter. */
    if(action<0&&!input->controller_keys[TC_PAD_A]&&!input->controller_keys[TC_PAD_B])
        input->controller_keys[tc_modern_get(c,TC_CONFIRM_B)?TC_PAD_B:TC_PAD_A]=28;
    if(action<0)input->controller_keys[TC_PAD_MENU]=1;
    m->previousButtons=pressed;
}
static void *memory(tc_cpu *c,uint32_t address,size_t size) {
    if(!address||(uint64_t)address+size>c->memory_size)abort();
    return (void *)(c->scalar._pointer_offset+address);
}
static uint32_t word(tc_cpu *c,uint32_t address) {uint32_t v;memcpy(&v,memory(c,address,4),4);return v;}
static void put(tc_cpu *c,uint32_t address,uint32_t v) {memcpy(memory(c,address,4),&v,4);}
/* Invoke the original statically translated widget methods with their x86 ABI. */
static uint32_t invoke(tc_cpu *c,uint32_t fn,uint32_t self,const uint32_t *args,unsigned count) {
    _cpu saved=c->scalar;uint32_t xmm[8][4];memcpy(xmm,c->xmm,sizeof(xmm));
    if(!c->guest_invoke||saved._esp<1024+4*count)abort();
    c->scalar._esp-=1024+4*(count+1);c->scalar._ecx=self;
    put(c,c->scalar._esp,UINT32_MAX);
    if(count)memcpy(memory(c,c->scalar._esp+4,count*4),args,count*4);
    c->guest_invoke(&c->scalar,fn);uint32_t result=c->scalar._eax;
    c->scalar=saved;memcpy(c->xmm,xmm,sizeof(xmm));return result;
}
static void label(tc_cpu *c,uint32_t item,const char *text) {
    Modern *m=c->modern;uint32_t p=tc_heap_alloc(c->heap_process,m->heap,0,(uint32_t)strlen(text)+1);
    if(!p)abort();strcpy(memory(c,p,strlen(text)+1),text);
    invoke(c,0x559230,item+0x98,&p,1);
    tc_heap_free(c->heap_process,m->heap,p);
}
static uint32_t find_item(tc_cpu *c,uint32_t list,unsigned event) {
    uint32_t node=word(c,list+0x74);
    for(unsigned n=0;node&&word(c,node)&&n<128;n++,node=word(c,node)) {
        uint32_t item=word(c,node+8);
        if(item&&word(c,item+0x78)==0x557dc0&&word(c,item+0x7c)==event)return item;
    }
    return 0;
}
static void row(tc_cpu *c,uint32_t list,unsigned event,const char *text) {
    uint32_t item=find_item(c,list,event);
    if(!item) {
        Modern *m=c->modern;uint32_t p=tc_heap_alloc(c->heap_process,m->heap,0,(uint32_t)strlen(text)+1);
        if(!p)abort();strcpy(memory(c,p,strlen(text)+1),text);
        const uint32_t args[]={p,0};item=invoke(c,0x55e4f0,list,args,2);
        tc_heap_free(c->heap_process,m->heap,p);if(!item)abort();
        put(c,item+0x78,0x557dc0);put(c,item+0x7c,event);put(c,item+0x80,0);
        /* 55E4F0 normally receives a larger popup list with a font at +0x150.
           Main menus are only 0xbc bytes: inherit their first row's text font. */
        uint32_t first=word(c,word(c,list+0x74)+8);
        put(c,item+0x110,word(c,first+0x110));
        /* Popup labels default to right alignment; main-menu labels do not. */
        put(c,item+0xa0,(word(c,item+0xa0)&~7u)|(word(c,first+0xa0)&7u));
        uint32_t visible=0;invoke(c,word(c,word(c,item)+0xc),item,&visible,1);
    } else label(c,item,text);
}
static void action_name(unsigned action,char *out,size_t size) {
    size_t used=0;const char *name=actions[action].name;
    for(size_t i=0;name[i]&&used+2<size;i++) {
        if(i&&isupper((unsigned char)name[i])&&islower((unsigned char)name[i-1]))out[used++]=' ';
        out[used++]=name[i];
    }
    out[used]=0;
}
/* The PC editor registers its buffer, length and active flag at 7511b4..bc.
   Keep its seven-character validation and save/cancel path for both inputs. */
static void name_character(tc_cpu *c,unsigned character) {
    const uint32_t args[]={0,0x102,character,1};
    invoke(c,0x612a90,0,args,4);
}
static uint32_t menu_font(tc_cpu *c) {
    uint32_t manager=word(c,0x728320);
    for(unsigned id=0;manager&&id<50;id++) {
        uint32_t screen=word(c,manager+0x10+4*id),list=screen&&word(c,screen)==0x683218?word(c,screen+0x88):0;
        uint32_t node=list?word(c,list+0x74):0,item=node?word(c,node+8):0;
        if(item&&word(c,item+0x110))return word(c,item+0x110);
    }
    return 0;
}
static void name_rows(tc_cpu *c,uint32_t screen,BOOL visible) {
    Modern *m=c->modern;uint32_t list=word(c,screen+0x88);
    static const char letters[]="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for(unsigned r=0;r<42;r++) {
        char text[128];
        if(r<40) {
            char key[8];
            if(r<36)snprintf(key,sizeof(key),"%c",m->nameLower?tolower(letters[r]):letters[r]);
            else snprintf(key,sizeof(key),"%s",(const char *const[]){"SP","DEL","OK","ESC"}[r-36]);
            snprintf(text,sizeof(text),r==m->nameSelection?"[%s]":"%s",key);
        } else if(m->controllerActive)snprintf(text,sizeof(text),"%s",r==40?
            "D-PAD / STICK: MOVE   CROSS/A: SELECT":"SQUARE/X: DELETE   TRIANGLE/Y: CASE");
        else snprintf(text,sizeof(text),"%s",r==40?
            "TYPE YOUR NAME (7 CHARACTERS)":"ENTER: CONFIRM   BACKSPACE: DELETE   ESC: CANCEL");
        unsigned event=1200+r;
        if(visible)row(c,list,event,text);
        uint32_t item=find_item(c,list,event);if(!item)continue;
        put(c,item+8,visible?(word(c,item+8)&~0x800u)|0x100u:word(c,item+8)|0x900u);
        if(visible) {
            /* The original menu font (from the Options list) renders at menu size;
               the licence-plate font is far larger than a keyboard cell. */
            uint32_t font=menu_font(c);
            put(c,item+0x110,font?font:word(c,0x6d959c));
            put(c,item+0xa0,0x10);
            const uint32_t position[]={cell_x(r),cell_y(r),0};
            uint32_t p=tc_heap_alloc(c->heap_process,m->heap,0,sizeof(position));
            memcpy(memory(c,p,sizeof(position)),position,sizeof(position));
            invoke(c,word(c,word(c,item)+4),item,&p,1);
            tc_heap_free(c->heap_process,m->heap,p);
        }
    }
}
static BOOL name_input(tc_cpu *c,tc_input *input,uint32_t screen) {
    Modern *m=c->modern;uint32_t flag=word(c,0x7511bc);
    BOOL active=screen&&word(c,screen)==0x681ee0&&word(c,screen+0xad4)==16&&
        flag&&*(unsigned char *)memory(c,flag,1);
    if(!active) {
        if(m->nameScreen){
            name_rows(c,m->nameScreen,NO);m->nameScreen=0;
            m->nameReleaseButtons=m->nameButtons;
        }
        for(unsigned i=0;i<TC_PAD_BUTTON_COUNT;i++) {
            if(!input->controller[i])m->nameReleaseButtons&=~(1u<<i);
            if(m->nameReleaseButtons&(1u<<i))input->controller[i]=0;
        }
        return NO;
    }
    uint32_t buttons=0;
    for(unsigned i=0;i<TC_PAD_BUTTON_COUNT;i++)if(input->controller[i])buttons|=1u<<i;
    if(input->sticks[0]<-0.5f)buttons|=1u<<TC_PAD_LEFT;
    if(input->sticks[0]>0.5f)buttons|=1u<<TC_PAD_RIGHT;
    if(input->sticks[1]>0.5f)buttons|=1u<<TC_PAD_UP;
    if(input->sticks[1]<-0.5f)buttons|=1u<<TC_PAD_DOWN;
    if(tc_modern_get(c,TC_CONFIRM_B)&&((buttons>>TC_PAD_A)&1)!=((buttons>>TC_PAD_B)&1))
        buttons^=(1u<<TC_PAD_A)|(1u<<TC_PAD_B);
    BOOL entering=m->nameScreen!=screen;
    BOOL changed=entering||m->nameSource!=input->controller_active;
    m->nameSource=input->controller_active;
    if(entering){m->nameScreen=screen;m->nameSelection=0;m->nameButtons=buttons;}
    uint32_t fresh=buttons&~m->nameButtons;
    double now=NSProcessInfo.processInfo.systemUptime;
    uint32_t directions=(1u<<TC_PAD_UP)|(1u<<TC_PAD_DOWN)|(1u<<TC_PAD_LEFT)|(1u<<TC_PAD_RIGHT);
    if(fresh&directions)m->nameRepeat=now+0.4;
    else if((buttons&directions)&&now>=m->nameRepeat){fresh|=buttons&directions;m->nameRepeat=now+0.15;}
    if(fresh&(1u<<TC_PAD_LEFT)){m->nameSelection=(m->nameSelection/10)*10+(m->nameSelection+9)%10;changed=YES;}
    if(fresh&(1u<<TC_PAD_RIGHT)){m->nameSelection=(m->nameSelection/10)*10+(m->nameSelection+1)%10;changed=YES;}
    if(fresh&(1u<<TC_PAD_UP)){m->nameSelection=(m->nameSelection+30)%40;changed=YES;}
    if(fresh&(1u<<TC_PAD_DOWN)){m->nameSelection=(m->nameSelection+10)%40;changed=YES;}
    if(fresh&(1u<<TC_PAD_Y)){m->nameLower=!m->nameLower;changed=YES;}
    unsigned character=0;
    if(fresh&(1u<<TC_PAD_A)) {
        if(m->nameSelection<36) {
            character="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"[m->nameSelection];
            if(m->nameLower)character=tolower(character);
        } else character=(const unsigned[]){32,8,13,27}[m->nameSelection-36];
    }
    if(fresh&(1u<<TC_PAD_X))character=8;
    if(fresh&(1u<<TC_PAD_B))character=27;
    if(fresh&(1u<<TC_PAD_MENU))character=13;
    if(character)name_character(c,character);
    if(changed)name_rows(c,screen,YES);
    m->nameButtons=buttons;m->previousButtons=buttons;
    /* Prevent an edit/confirm press from also navigating the underlying menu. */
    memset(input->controller,0,sizeof(input->controller));
    memset(input->sticks,0,sizeof(input->sticks));
    memset(input->keyboard,0,sizeof(input->keyboard));
    return YES;
}
void tc_menu_refresh(_cpu *cpu,uint32_t screen,uint32_t controls) {
    tc_cpu *c=(tc_cpu *)cpu;
    if(getenv("TC_MENU_TRACE"))fprintf(stderr,"[menu] refresh screen=%08x controls=%u modern=%p\n",screen,controls,c->modern);
    if(!c->modern)return;
    uint32_t list=word(c,screen+0x88);if(!list)return;
    char text[96];
    if(!controls) {
        unsigned fps=tc_modern_get(c,TC_FRAME_LIMIT);
        if(fps)snprintf(text,sizeof(text),"Frame Rate Limit: %u FPS",fps);
        else snprintf(text,sizeof(text),"Frame Rate Limit: Unlimited");
        row(c,list,1000,text);
        row(c,list,1001,tc_modern_get(c,TC_VSYNC)?"V-Sync: On":"V-Sync: Off");
        const char *names[]={"MetalFX Spatial: Off","MetalFX Spatial: Quality (67%)","MetalFX Spatial: Balanced (59%)","MetalFX Spatial: Performance (50%)"};
        row(c,list,1002,names[tc_modern_get(c,TC_METALFX)]);
        const char *hdr[]={"HDR: Off","HDR: On (Brightness Low)","HDR: On (Brightness Medium)","HDR: On (Brightness High)"};
        row(c,list,1003,hdr[tc_modern_get(c,TC_HDR)]);
        row(c,list,1005,tc_modern_get(c,TC_UI_SCALE)?"Menu & HUD Scale: Auto (restart to apply)":"Menu & HUD Scale: Original (restart to apply)");
        row(c,list,1004,(const char *[]){"Anti-Aliasing: Off","Anti-Aliasing: 2x MSAA","Anti-Aliasing: 4x MSAA"}[tc_modern_get(c,TC_MSAA)]);
    } else {
        Modern *m=c->modern;m->controlsScreen=screen;
        /* The original constructor disables the custom profile unconditionally. */
        uint32_t node=word(c,screen+0x50c+0x74);
        for(unsigned n=0;node&&word(c,node)&&n<16;n++,node=word(c,node)) {
            uint32_t item=word(c,node+8);
            if(item&&word(c,item+0x80)==0xd94) {
                put(c,item+8,word(c,item+8)&~0x100u);put(c,item+0x7c,1100);
            }
        }
        row(c,list,1100,m->bindingVisible||m->axisVisible?"Back to Controls":"Controller Bindings");
        row(c,list,1113,"Controller Stick Settings");
        snprintf(text,sizeof(text),"%s: %.55s",m->controllerActive?"Active Controller":"Controller",m->connected?m->controllerName:"Not detected");row(c,list,1109,text);
        /* The original Keyboard Bindings row already opens screen 0x27. */
        snprintf(text,sizeof(text),"Stick Deadzone: %u%%",tc_modern_get(c,TC_DEADZONE));row(c,list,1101,text);
        snprintf(text,sizeof(text),"Look Sensitivity: %u%%",tc_modern_get(c,TC_LOOK_SPEED));row(c,list,1102,text);
        row(c,list,1103,tc_modern_get(c,TC_INVERT_LOOK)?"Invert Look Y: On":"Invert Look Y: Off");
        row(c,list,1110,tc_modern_get(c,TC_INVERT_LOOK_X)?"Invert Look X: On":"Invert Look X: Off");
        row(c,list,1111,tc_modern_get(c,TC_INVERT_MOVE_X)?"Invert Move / Steering X: On":"Invert Move / Steering X: Off");
        row(c,list,1112,tc_modern_get(c,TC_INVERT_MOVE_Y)?"Invert Move Y: On":"Invert Move Y: Off");
        row(c,list,1115,tc_modern_get(c,TC_SWAP_STICKS)?"Swap Sticks: On (move right, look left)":"Swap Sticks: Off");
        row(c,list,1116,tc_modern_get(c,TC_CONFIRM_B)?"Menu Confirm: B / Circle":"Menu Confirm: A / Cross");
        if(m->bindingVisible) {
            /* Every action on paged rows: select one, then press any button. */
            unsigned pages=(TC_KEYBOARD_ACTION_COUNT+7)/8;int waiting=atomic_load(&m->waiting);
            for(unsigned r=0;r<8;r++) {
                unsigned action=m->bindingPage*8+r;if(action>=TC_KEYBOARD_ACTION_COUNT)break;
                char name[64];action_name(action,name,sizeof(name));
                unsigned button=atomic_load(&m->bindings[action]);
                if(waiting==(int)action)snprintf(text,sizeof(text),"%s: press a button (Esc cancels)",name);
                else snprintf(text,sizeof(text),"%s%s: %s",action==m->editAction?"> ":"",name,button<TC_PAD_BUTTON_COUNT?buttonNames[button]:"Unassigned");
                row(c,list,1120+r,text);
            }
            snprintf(text,sizeof(text),"Next Page (%u/%u)",m->bindingPage+1,pages);row(c,list,1105,text);
            row(c,list,1107,"Previous Page");
            char name[64];action_name(m->editAction,name,sizeof(name));
            snprintf(text,sizeof(text),"Clear Binding: %s",name);row(c,list,1108,text);
            row(c,list,1114,"Restore Controller Defaults");
        }
    }
    /* Keep the original menu anchor, then lay out and link the added rows. */
    uint32_t first=word(c,word(c,list+0x74)+8);
    memcpy(memory(c,list+0x24,12),memory(c,first+0x24,12),12);
    /* Bit 0 links Up/Down; bit 1 positions every row. Zero does neither. */
    uint32_t layout=3;invoke(c,word(c,word(c,list)+0x2c),list,&layout,1);
    if(controls) {
        Modern *m=c->modern;uint32_t selectable[32],count=0;
        uint32_t position=tc_heap_alloc(c->heap_process,m->heap,0,12);if(!position)abort();
        memcpy(memory(c,position,12),memory(c,list+0x24,12),12);
        for(uint32_t node=word(c,list+0x74),n=0;node&&word(c,node)&&n<32;node=word(c,node),n++) {
            uint32_t item=word(c,node+8),event=word(c,item+0x7c);
            BOOL visible=m->bindingVisible?(event==1100||event==1109||event==1114||event==1105||event==1107||event==1108||
                    (event>=1120&&event<1128&&m->bindingPage*8+event-1120<TC_KEYBOARD_ACTION_COUNT)):
                m->axisVisible?(event==1100||event==1109||(event>=1101&&event<=1103)||(event>=1110&&event<=1112)||event==1115||event==1116):
                (event<1000||event==1100||event==1109||event==1113);
            put(c,item+8,(word(c,item+8)&~0x900u)|(visible?(event==1109?0x100u:0):0x900u));
            if(!visible)continue;
            invoke(c,word(c,word(c,item)+4),item,&position,1);
            put(c,position+4,word(c,position+4)+16);
            if(event!=1109)selectable[count++]=item;
        }
        tc_heap_free(c->heap_process,m->heap,position);
        for(unsigned i=0;i<count;i++) {
            put(c,selectable[i]+0x90,selectable[(i+count-1)%count]);
            put(c,selectable[i]+0x94,selectable[(i+1)%count]);
        }
        uint32_t focus=word(c,list+0x84);
        if(count&&(!focus||(word(c,focus+8)&0x900)))invoke(c,0x55cd20,list,selectable,1);
    }
    if(getenv("TC_MENU_TRACE")) {
        fprintf(stderr,"[menu] layout list=%08x flags=%08x method=%08x\n",list,word(c,list+8),word(c,word(c,list)+0x2c));
        for(uint32_t node=word(c,list+0x74),n=0;node&&word(c,node)&&n<32;node=word(c,node),n++) {
            uint32_t item=word(c,node+8);
            fprintf(stderr,"[menu] row %u event=%u flags=%08x font=%08x xy=%d,%d\n",n,word(c,item+0x7c),word(c,item+8),word(c,item+0x110),(int)word(c,item+0x24),(int)word(c,item+0x28));
        }
    }
}
void tc_menu_event(_cpu *cpu,uint32_t screen) {
    tc_cpu *c=(tc_cpu *)cpu;unsigned event=word(c,cpu->_esp+4);cpu->_eax=0;
    if(!c->modern)return;
    Modern *m=c->modern;
    if(!((event>=1000&&event<=1005)||(event>=1100&&event<=1127))) {
        if(word(c,screen)==0x683168)atomic_store(&((Modern *)c->modern)->waiting,-1);
        return;
    }
    unsigned key=0,value=0;
    switch(event) {
        case 1000: {
            unsigned current=tc_modern_get(c,TC_FRAME_LIMIT),i=0;
            while(i+1<sizeof(limits)/sizeof(*limits)&&limits[i]!=current)i++;
            key=TC_FRAME_LIMIT;value=limits[(i+1)%(sizeof(limits)/sizeof(*limits))];break;
        }
        case 1001:key=TC_VSYNC;value=!tc_modern_get(c,key);break;
        case 1002:key=TC_METALFX;value=(tc_modern_get(c,key)+1)%4;break;
        case 1003:key=TC_HDR;value=(tc_modern_get(c,key)+1)%4;break;
        case 1005:key=TC_UI_SCALE;value=!tc_modern_get(c,key);break;
        case 1004:key=TC_MSAA;value=(tc_modern_get(c,key)+1)%3;break;
        case 1100: {
            Modern *m=c->modern;
            m->bindingVisible=!(m->bindingVisible||m->axisVisible);m->axisVisible=NO;
            atomic_store(&m->waiting,-1);
            const uint32_t cancelPopup[]={3,0};invoke(c,0x575e30,screen,cancelPopup,2);
            tc_menu_refresh(cpu,screen,1);cpu->_eax=1;return;
        }
        case 1114:
            for(unsigned i=0;i<TC_KEYBOARD_ACTION_COUNT;i++)atomic_store(&m->bindings[i],defaultBindings[i]);
            atomic_store(&m->waiting,-1);save_bindings(m);tc_menu_refresh(cpu,screen,1);cpu->_eax=1;return;
        case 1113:m->axisVisible=YES;m->bindingVisible=NO;atomic_store(&m->waiting,-1);tc_menu_refresh(cpu,screen,1);cpu->_eax=1;return;
        case 1109:cpu->_eax=1;return;
        case 1110:key=TC_INVERT_LOOK_X;value=!tc_modern_get(c,key);break;
        case 1111:key=TC_INVERT_MOVE_X;value=!tc_modern_get(c,key);break;
        case 1112:key=TC_INVERT_MOVE_Y;value=!tc_modern_get(c,key);break;
        case 1104: {
            const uint32_t args[]={4,0};invoke(c,0x575e30,screen,args,2);cpu->_eax=1;return;
        }
        case 1105:case 1107:case 1108:
        case 1120:case 1121:case 1122:case 1123:case 1124:case 1125:case 1126:case 1127: {
            unsigned pages=(TC_KEYBOARD_ACTION_COUNT+7)/8;atomic_store(&m->waiting,-1);
            if(event==1105)m->bindingPage=(m->bindingPage+1)%pages;
            if(event==1107)m->bindingPage=(m->bindingPage+pages-1)%pages;
            if(event==1108){atomic_store(&m->bindings[m->editAction],UINT32_MAX);save_bindings(m);}
            if(event>=1120) {
                unsigned action=m->bindingPage*8+event-1120;
                if(action<TC_KEYBOARD_ACTION_COUNT){m->editAction=action;atomic_store(&m->waiting,(int)action);}
            }
            tc_menu_refresh(cpu,screen,1);cpu->_eax=1;return;
        }
        case 1115:key=TC_SWAP_STICKS;value=!tc_modern_get(c,key);break;
        case 1116:key=TC_CONFIRM_B;value=!tc_modern_get(c,key);break;
        case 1101:key=TC_DEADZONE;value=(tc_modern_get(c,key)+5)%45;break;
        case 1102:key=TC_LOOK_SPEED;value=tc_modern_get(c,key)+25;if(value>200)value=50;break;
        case 1103:key=TC_INVERT_LOOK;value=!tc_modern_get(c,key);break;
    }
    tc_modern_set(c,key,value);tc_menu_refresh(cpu,screen,event>=1100);cpu->_eax=1;
}
#ifdef TC_MODERN_SELF_CHECK
#include <assert.h>
int main(void) {
    assert(valid(TC_FRAME_LIMIT,0)&&valid(TC_FRAME_LIMIT,144)&&!valid(TC_FRAME_LIMIT,61));
    assert(valid(TC_METALFX,3)&&!valid(TC_METALFX,4));
    assert(valid(TC_MSAA,2)&&!valid(TC_MSAA,3)&&defaults[TC_MSAA]==1);
    _Static_assert(sizeof(defaults)/sizeof(*defaults)==TC_MODERN_COUNT&&sizeof(keys)/sizeof(*keys)==TC_MODERN_COUNT,"Modern option tables");
    assert(valid(TC_DEADZONE,40)&&!valid(TC_DEADZONE,100));
    assert(valid(TC_LOOK_SPEED,200)&&!valid(TC_LOOK_SPEED,0));
    Modern m={0};atomic_init(&m.waiting,-1);
    for(unsigned i=0;i<TC_KEYBOARD_ACTION_COUNT;i++)atomic_init(&m.bindings[i],UINT32_MAX);
    unsigned char *memory=calloc(1,0x800000);assert(memory);
    tc_cpu c={.modern=&m,.memory_size=0x800000};c.scalar._pointer_offset=(uintptr_t)memory;
    tc_input input={0};
    input.keyboard[17]=0x80;input.controller[TC_PAD_A]=1;
    atomic_store(&m.bindings[9],TC_PAD_A);
    tc_modern_input(&c,&input);
    assert(input.controller_actions[TC_PAD_A]==(UINT64_C(1)<<9));
    assert(input.keyboard[17]==0x80&&tc_modern_button_bound(&c,TC_PAD_A));
    assert(!tc_modern_button_bound(&c,TC_PAD_B));
    atomic_store(&m.bindings[9],UINT32_MAX);tc_modern_input(&c,&input);
    assert(!input.controller_actions[TC_PAD_A]&&!tc_modern_button_bound(&c,TC_PAD_A));
    atomic_store(&m.values[TC_INVERT_MOVE_X],1);input.sticks[0]=0.5f;
    tc_modern_input(&c,&input);assert(input.sticks[0]==-0.5f);
    input.sticks[2]=input.sticks[3]=0.5f;tc_modern_input(&c,&input);
    assert(input.sticks[2]==0.5f&&input.sticks[3]==0.5f);
    atomic_store(&m.values[TC_INVERT_LOOK_X],1);input.sticks[2]=0.5f;
    tc_modern_input(&c,&input);assert(input.sticks[2]==-0.5f);
    uint32_t manager=0x1000,screen=0x2000;memcpy(memory+0x728320,&manager,4);
    memcpy(memory+manager,&screen,4);memory[screen+0x74]=1;
    tc_modern_input(&c,&input);
    assert(input.controller_keys[TC_PAD_A]==28&&input.controller_keys[TC_PAD_UP]==200);
    assert(input.sticks[0]==0);free(memory);
    return 0;
}
#endif
