#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include "tc_host.h"
#include "tc_d3d8.h"
#include "tc_preferences.h"
#include "tc_controller.h"
#include "tc_modern.h"
#include <math.h>
#include <stdatomic.h>
#include <errno.h>
#include <ctype.h>

/* Physical macOS key positions -> the game's DirectInput scan codes. */
static const unsigned char keymap[128]={
 [0]=30,[1]=31,[2]=32,[3]=33,[4]=35,[5]=34,[6]=44,[7]=45,[8]=46,[9]=47,
 [11]=48,[12]=16,[13]=17,[14]=18,[15]=19,[16]=21,[17]=20,[18]=2,[19]=3,
 [20]=4,[21]=5,[22]=7,[23]=6,[24]=13,[25]=10,[26]=8,[27]=12,[28]=9,[29]=11,
 [30]=27,[31]=24,[32]=22,[33]=26,[34]=23,[35]=25,[36]=28,[37]=38,[38]=36,
 [39]=40,[40]=37,[41]=39,[42]=43,[43]=51,[44]=53,[45]=49,[46]=50,[47]=52,
 [48]=15,[49]=57,[50]=41,[51]=14,[53]=1,[54]=220,[55]=219,[56]=42,[57]=58,
 [58]=56,[59]=29,[60]=54,[61]=184,[62]=157,[65]=83,[67]=55,[69]=78,[75]=181,
 [76]=156,[78]=74,[81]=141,[82]=82,[83]=79,[84]=80,[85]=81,[86]=75,[87]=76,
 [88]=77,[89]=71,[91]=72,[92]=73,[96]=63,[97]=64,[98]=65,[99]=61,[100]=66,
 [101]=67,[103]=87,[109]=68,[111]=88,[115]=199,[116]=201,[117]=211,[118]=62,
 [119]=207,[120]=60,[121]=209,[122]=59,[123]=203,[124]=205,[125]=208,[126]=200
};
@interface TCHost : NSObject<NSWindowDelegate> {
@public tc_image *image;tc_input input;tc_preferences preferences;tc_graphics_settings startupGraphics;
    double controllerTime;
    double mouseAxes[3];unsigned char mouseButtons[8];
    uint32_t windowProcedure,windowStyle,windowExtendedStyle,classInstance;
    atomic_bool guestWindow;BOOL destroying;
    unsigned char asyncPressed[256],asyncDown[256];
    int32_t cursorCount;BOOL cursorHidden;
}
@property(strong) NSCursor *cursor;
@property(copy) NSString *className;
@property(strong) NSMutableArray<NSData *> *messages;
@property(strong) NSWindow *window;
@property(copy) NSString *path;
- (void)requestQuit:(id)sender;
@end
static const uint32_t guest_window=0xe4000001;
typedef struct {uint32_t window,message,wparam,lparam,time;int32_t x,y;} TCMessage;
_Static_assert(sizeof(TCMessage)==28,"32-bit MSG layout");
static void post_message(TCHost *host,uint32_t message,uint32_t wparam,uint32_t lparam) {
    if(!NSThread.isMainThread)abort();
    if(!host->guestWindow)return;
    NSPoint point=NSEvent.mouseLocation;NSRect screen=NSScreen.screens.firstObject.frame;
    TCMessage msg={guest_window,message,wparam,lparam,
        (uint32_t)(uint64_t)(NSProcessInfo.processInfo.systemUptime*1000),
        (int32_t)(point.x-NSMinX(screen)),(int32_t)(NSMaxY(screen)-point.y)};
    [host.messages addObject:[NSData dataWithBytes:&msg length:sizeof(msg)]];
}
static void post_size(TCHost *host) {
    NSSize size=host->image->cpu.headless?NSMakeSize(host->startupGraphics.width,host->startupGraphics.height):host.window.contentView.bounds.size;
    if(host.window.isMiniaturized)size=NSZeroSize;
    uint32_t width=(uint32_t)fmax(0,fmin(65535,size.width)),height=(uint32_t)fmax(0,fmin(65535,size.height));
    post_message(host,5,host.window.isMiniaturized?1:host.window.isZoomed?2:0,width|(height<<16));
}
static BOOL message_matches(const TCMessage *msg,uint32_t window,uint32_t first,uint32_t last) {
    if(msg->message==0x12)return YES;
    if(window==UINT32_MAX&&msg->window)return NO;
    if(window&&window!=UINT32_MAX&&window!=msg->window)return NO;
    return (!first&&!last)||(msg->message>=first&&msg->message<=last);
}
static void *host_memory(_cpu *cpu,uint64_t address,size_t size) {
    tc_cpu *c=(tc_cpu *)cpu;
    if(!address||address>UINT32_MAX||size>c->memory_size||address>c->memory_size-size||
       cpu->_pointer_offset>UINTPTR_MAX-address-size)abort();
    return (void *)(uintptr_t)(cpu->_pointer_offset+address);
}
static uint32_t host_arg(_cpu *cpu,unsigned index) {
    uint32_t value;memcpy(&value,host_memory(cpu,(uint64_t)cpu->_esp+4+index*4,4),4);return value;
}
static void host_error(_cpu *cpu,uint32_t error) {cpu->_eax=0;tc_write_fs(cpu,0x34,error);}
static NSString *host_string(_cpu *cpu,uint32_t address) {
    if(!address)return @"";
    unsigned char bytes[32768];
    for(size_t i=0;i<sizeof(bytes);i++) {
        memcpy(bytes+i,host_memory(cpu,(uint64_t)address+i,1),1);
        if(!bytes[i])return [[NSString alloc]initWithBytes:bytes length:i encoding:NSWindowsCP1252StringEncoding];
    }
    return nil;
}
static void on_main(void (^action)(void)) {
    if(NSThread.isMainThread)action();else dispatch_sync(dispatch_get_main_queue(),action);
}
static unsigned virtual_scan(unsigned key) {
    static const unsigned char letters[]={30,48,46,32,18,33,34,35,23,36,37,38,50,49,24,25,16,19,31,20,22,47,17,45,21,44};
    static const unsigned char digits[]={11,2,3,4,5,6,7,8,9,10},pad[]={82,79,80,81,75,76,77,71,72,73};
    if(key>='A'&&key<='Z')return letters[key-'A'];
    if(key>='0'&&key<='9')return digits[key-'0'];
    if(key>=0x60&&key<=0x69)return pad[key-0x60];
    if(key>=0x70&&key<=0x79)return 59+key-0x70;
    switch(key) {
        case 8:return 14;case 9:return 15;case 13:return 28;case 16:case 0xa0:return 42;
        case 17:case 0xa2:return 29;case 18:case 0xa4:return 56;case 20:return 58;
        case 27:return 1;case 32:return 57;case 33:return 201;case 34:return 209;
        case 35:return 207;case 36:return 199;case 37:return 203;case 38:return 200;
        case 39:return 205;case 40:return 208;case 45:return 210;case 46:return 211;
        case 0x5b:return 219;case 0x5c:return 220;case 0x5d:return 221;
        case 0x6a:return 55;case 0x6b:return 78;case 0x6d:return 74;case 0x6e:return 83;case 0x6f:return 181;
        case 0x7a:return 87;case 0x7b:return 88;case 0x90:return 69;case 0x91:return 70;
        case 0xa1:return 54;case 0xa3:return 157;case 0xa5:return 184;
        case 0xba:return 39;case 0xbb:return 13;case 0xbc:return 51;case 0xbd:return 12;
        case 0xbe:return 52;case 0xbf:return 53;case 0xc0:return 41;case 0xdb:return 26;
        case 0xdc:return 43;case 0xdd:return 27;case 0xde:return 40;default:return 0;
    }
}
static BOOL virtual_down(const unsigned char keys[256],unsigned key) {
    unsigned scan=virtual_scan(key);BOOL down=scan&&keys[scan];
    if(key==13)down|=keys[156]!=0;
    if(key==16)down|=keys[54]!=0;
    if(key==17)down|=keys[157]!=0;
    if(key==18)down|=keys[184]!=0;
    return down;
}
static void host_key(TCHost *host,unsigned scan,BOOL down) {
    if(!host)return;
    unsigned char previous[256];memcpy(previous,host->input.keyboard,sizeof(previous));
    tc_input_key(&host->input,scan,down);
    if(down)host->input.controller_active=0;
    if(down)for(unsigned key=0;key<256;key++)
        if(virtual_down(host->input.keyboard,key)&&!virtual_down(previous,key))host->asyncPressed[key]=1;
}
static BOOL headless_key_command(const char *line,unsigned *scan,BOOL *down) {
    const char *number;
    if(!strncmp(line,"down ",5)){*down=YES;number=line+5;}
    else if(!strncmp(line,"up ",3)){*down=NO;number=line+3;}
    else return NO;
    while(isspace((unsigned char)*number))number++;
    if(!isdigit((unsigned char)*number))return NO;
    errno=0;char *end;unsigned long value=strtoul(number,&end,10);
    if(errno||end==number||!value||value>255)return NO;
    while(isspace((unsigned char)*end))end++;
    if(*end)return NO;*scan=(unsigned)value;return YES;
}
static void headless_input(TCHost *host) {
    [NSThread detachNewThreadWithBlock:^{
        @autoreleasepool {
            char line[64];
            while(fgets(line,sizeof(line),stdin)) {
                if(!strchr(line,'\n')&&!feof(stdin)) {
                    int ch;while((ch=fgetc(stdin))!=EOF&&ch!='\n'){}
                    fprintf(stderr,"Headless input: command too long\n");continue;
                }
                unsigned scan;BOOL down;
                /* "stick <lx> <ly> <rx> <ry>" holds virtual controller sticks (-1..1, up positive). */
                float lx,ly,rx,ry;
                if(sscanf(line,"stick %f %f %f %f",&lx,&ly,&rx,&ry)==4) {
                    on_main(^{host->input.controller_connected=1;host->input.controller_active=1;
                        tc_input_sticks(&host->input,lx,ly,rx,ry);});
                    continue;
                }
                /* "pad <button> <0|1>" presses a virtual controller button (tc_pad_button order). */
                unsigned button,pressed;
                if(sscanf(line,"pad %u %u",&button,&pressed)==2) {
                    on_main(^{host->input.controller_connected=1;if(pressed)host->input.controller_active=1;
                        tc_input_button(&host->input,button,pressed!=0);});
                    continue;
                }
                /* "char <code>" types one Windows-1252 character, like a physical keyDown. */
                if(!strncmp(line,"char ",5)) {
                    unsigned long code=strtoul(line+5,NULL,10);
                    if(code&&code<256){on_main(^{post_message(host,0x102,(uint32_t)code,1);});continue;}
                }
                if(!headless_key_command(line,&scan,&down)) {
                    fprintf(stderr,"Headless input: use down <scan-code> or up <scan-code> (1..255)\n");continue;
                }
                on_main(^{host_key(host,scan,down);});
                fprintf(stderr,"Headless input: %s %u\n",down?"down":"up",scan);
            }
            on_main(^{tc_input_release_all(&host->input);});
        }
    }];
}
static void host_mouse_button(TCHost *host,unsigned button,BOOL down) {
    if(!host||button>=8)return;
    if(down)host->input.controller_active=0;
    static const unsigned char virtual_buttons[]={1,2,4,5,6,0,0,0};
    unsigned key=virtual_buttons[button];
    if(key&&down&&!host->mouseButtons[button])host->asyncPressed[key]=1;
    host->mouseButtons[button]=down?0x80:0;
}
void tc_async_key(_cpu *cpu) {
    tc_cpu *c=(tc_cpu *)cpu;TCHost *host=(__bridge TCHost *)c->platform;
    unsigned key=host_arg(cpu,0);if(!host||key>=256){cpu->_eax=0;return;}
    if(c->frame_input)c->frame_input(cpu);
    BOOL keyboardDown=virtual_down(c->input_keyboard,key);__block uint16_t result=0;
    on_main(^{
        if(!c->headless&&!host.window.isKeyWindow)return;
        BOOL down=keyboardDown;
        switch(key) {
            case 1:down=host->mouseButtons[0]!=0;break;case 2:down=host->mouseButtons[1]!=0;break;
            case 4:down=host->mouseButtons[2]!=0;break;case 5:down=host->mouseButtons[3]!=0;break;
            case 6:down=host->mouseButtons[4]!=0;break;
        }
        result=(down?0x8000:0)|((host->asyncPressed[key]||(down&&!host->asyncDown[key]))?1:0);
        host->asyncPressed[key]=0;host->asyncDown[key]=down;
    });
    cpu->_eax=(uint32_t)(int32_t)(int16_t)result;
}
static NSColor *stock_brush(uint32_t index) {
    switch(index) {
        case 0:return NSColor.whiteColor;case 1:return NSColor.lightGrayColor;
        case 2:return NSColor.grayColor;case 3:return NSColor.darkGrayColor;
        case 4:return NSColor.blackColor;case 5:return NSColor.clearColor;
        default:return nil;
    }
}
void tc_stock_object(_cpu *cpu) {
    uint32_t index=host_arg(cpu,0);
    if(index<=5)cpu->_eax=0xe8000000u|index;else host_error(cpu,50);
}
void tc_window_hook_install(_cpu *cpu) {
    /* The host delivers focused window input directly. Windows-wide hooks are
       not implemented; the game may continue after this optional call fails. */
    host_error(cpu,50);
}
void tc_icon_load(_cpu *cpu) {
    /* Custom PE icon decoding is unavailable. WNDCLASS accepts a null icon;
       report failure instead of inventing a successfully loaded icon handle. */
    host_error(cpu,50);
}
static NSCursor *stock_cursor(uint32_t identifier) {
    switch(identifier) {
        case 32512:return NSCursor.arrowCursor;case 32513:return NSCursor.IBeamCursor;
        case 32515:return NSCursor.crosshairCursor;case 32649:return NSCursor.pointingHandCursor;
        case 32644:return NSCursor.resizeLeftRightCursor;case 32645:return NSCursor.resizeUpDownCursor;
        case 32648:return NSCursor.operationNotAllowedCursor;default:return nil;
    }
}
void tc_cursor_load(_cpu *cpu) {
    uint32_t instance=host_arg(cpu,0),identifier=host_arg(cpu,1);
    if(instance||identifier>UINT16_MAX){host_error(cpu,1814);return;}
    __block BOOL available;on_main(^{available=stock_cursor(identifier)!=nil;});
    if(available)cpu->_eax=0xe5000000u|identifier;else host_error(cpu,1814);
}
static void cursor_visibility(TCHost *host) {
    if(host->image&&host->image->cpu.headless)return;
    BOOL hidden=host->guestWindow&&host.window.isKeyWindow&&(host->cursorCount<0||host->input.controller_active);
    if(hidden!=host->cursorHidden){if(hidden)[NSCursor hide];else [NSCursor unhide];host->cursorHidden=hidden;}
}
void tc_cursor_show(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    if(!host){host_error(cpu,1400);return;}
    BOOL show=host_arg(cpu,0)!=0;__block int32_t count;__block BOOL overflow=NO;
    on_main(^{
        overflow=show?host->cursorCount==INT32_MAX:host->cursorCount==INT32_MIN;
        if(!overflow)host->cursorCount+=show?1:-1;
        count=host->cursorCount;cursor_visibility(host);
    });
    cpu->_eax=(uint32_t)count;if(overflow)tc_write_fs(cpu,0x34,534);
}
static NSWindowStyleMask window_mask(uint32_t style) {
    NSWindowStyleMask mask=NSWindowStyleMaskBorderless;
    if((style&0xc00000u)==0xc00000u)mask|=NSWindowStyleMaskTitled;
    if(style&0x80000u)mask|=NSWindowStyleMaskClosable;
    if(style&0x20000u)mask|=NSWindowStyleMaskMiniaturizable;
    if(style&0x40000u)mask|=NSWindowStyleMaskResizable;
    return mask;
}
void tc_window_adjust(_cpu *cpu) {
    uint32_t address=host_arg(cpu,0),style=host_arg(cpu,1);
    if(!address){host_error(cpu,87);return;}
    if(host_arg(cpu,2)){host_error(cpu,50);return;}
    int32_t input[4];memcpy(input,host_memory(cpu,address,sizeof(input)),sizeof(input));
    int64_t width=(int64_t)input[2]-input[0],height=(int64_t)input[3]-input[1];
    if(width<0||height<0||width>INT32_MAX||height>INT32_MAX){host_error(cpu,87);return;}
    NSRect content=NSMakeRect(input[0],-(double)input[3],width,height);
    __block NSRect frame;
    on_main(^{frame=[NSWindow frameRectForContentRect:content styleMask:window_mask(style)];});
    double edges[]={floor(NSMinX(frame)),floor(-NSMaxY(frame)),ceil(NSMaxX(frame)),ceil(-NSMinY(frame))};
    int32_t output[4];
    for(unsigned i=0;i<4;i++) {
        if(!isfinite(edges[i])||edges[i]<INT32_MIN||edges[i]>INT32_MAX){host_error(cpu,87);return;}
        output[i]=(int32_t)edges[i];
    }
    memcpy(host_memory(cpu,address,sizeof(output)),output,sizeof(output));cpu->_eax=1;
}
void tc_desktop_window(_cpu *cpu) {cpu->_eax=0xe4000002;}
void tc_system_metrics(_cpu *cpu) {
    int32_t index=(int32_t)host_arg(cpu,0);__block int32_t result=0;__block BOOL supported=YES;
    on_main(^{
        NSArray<NSScreen *> *screens=NSScreen.screens;NSRect primary=screens.firstObject.frame,all=primary;
        for(NSScreen *screen in screens)all=NSUnionRect(all,screen.frame);
        NSRect content=NSMakeRect(0,0,100,100);
        NSRect frame=[NSWindow frameRectForContentRect:content styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable];
        /* Guest window coordinates are DPI-virtualized AppKit points throughout
           this bridge. Metal rendering retains its independently selected size. */
        switch(index) {
            case 0:result=primary.size.width;break;
            case 1:result=primary.size.height;break;
            case 4:result=NSMaxY(frame)-NSMaxY(content);break;
            case 5:case 7:case 32:result=NSMinX(content)-NSMinX(frame);break;
            case 6:case 8:case 33:result=NSMinY(content)-NSMinY(frame);break;
            case 16:result=screens.firstObject.visibleFrame.size.width;break;
            case 17:result=screens.firstObject.visibleFrame.size.height;break;
            case 76:result=NSMinX(all)-NSMinX(primary);break;
            case 77:result=NSMaxY(primary)-NSMaxY(all);break;
            case 78:result=all.size.width;break;
            case 79:result=all.size.height;break;
            case 80:result=(int32_t)screens.count;break;
            default:supported=NO;break;
        }
    });
    if(supported)cpu->_eax=(uint32_t)result;else host_error(cpu,50);
}
void tc_window_move(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    if(!host||!host->guestWindow||host_arg(cpu,0)!=guest_window){host_error(cpu,1400);return;}
    int32_t x=(int32_t)host_arg(cpu,1),y=(int32_t)host_arg(cpu,2);
    int32_t width=(int32_t)host_arg(cpu,3),height=(int32_t)host_arg(cpu,4);BOOL repaint=host_arg(cpu,5)!=0;
    if(width<=0||height<=0||width>16384||height>16384){host_error(cpu,87);return;}
    __block BOOL fullscreen;
    on_main(^{
        fullscreen=(host.window.styleMask&NSWindowStyleMaskFullScreen)!=0;
        if(fullscreen)return;
        NSRect screen=NSScreen.screens.firstObject.frame;
        [host.window setFrame:NSMakeRect(NSMinX(screen)+x,NSMaxY(screen)-y-height,width,height) display:repaint];
    });
    if(fullscreen)host_error(cpu,50);else cpu->_eax=1;
}
void tc_window_foreground(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    if(!host||!host->guestWindow||host_arg(cpu,0)!=guest_window){host_error(cpu,1400);return;}
    if(((tc_cpu *)cpu)->headless){cpu->_eax=1;return;}
    __block BOOL active;
    on_main(^{[NSApp activateIgnoringOtherApps:YES];[host.window makeKeyAndOrderFront:nil];active=host.window.isKeyWindow;});
    cpu->_eax=active;
}
void tc_window_activate(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    if(!host||!host->guestWindow||host_arg(cpu,0)!=guest_window){host_error(cpu,1400);return;}
    if(((tc_cpu *)cpu)->headless){cpu->_eax=guest_window;return;}
    __block BOOL previous;
    on_main(^{previous=host.window.isKeyWindow;[host.window makeKeyWindow];});
    cpu->_eax=previous?guest_window:0;
}
void tc_window_focus(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;uint32_t requested=host_arg(cpu,0);
    if(!host||!host->guestWindow||(requested&&requested!=guest_window)){host_error(cpu,1400);return;}
    if(((tc_cpu *)cpu)->headless){cpu->_eax=requested?guest_window:0;return;}
    __block BOOL previous,accepted;
    on_main(^{
        previous=host.window.isKeyWindow&&host.window.firstResponder==host.window.contentView;
        accepted=[host.window makeFirstResponder:requested?host.window.contentView:nil];
        if(accepted&&requested)[host.window makeKeyWindow];
        if(accepted&&previous!=(requested!=0))post_message(host,requested?7:8,0,0);
        if(accepted&&!requested)tc_input_release_all(&host->input);
    });
    if(!accepted)host_error(cpu,87);else cpu->_eax=previous?guest_window:0;
}
static uint32_t guest_callback(_cpu *cpu,TCHost *host,uint32_t address,const uint32_t *frame,size_t size) {
    tc_cpu *c=(tc_cpu *)cpu;
    if(!c->guest_invoke||NSThread.isMainThread||cpu->_esp<tc_read_fs(cpu,8)||
       size>cpu->_esp-tc_read_fs(cpu,8))abort();
    _cpu saved=*cpu;
    cpu->_esp-=size;memcpy(host_memory(cpu,cpu->_esp,size),frame,size);
    c->guest_invoke(cpu,address);
    uint32_t result=cpu->_eax;*cpu=saved;return result;
}
static uint32_t window_callback(_cpu *cpu,TCHost *host,uint32_t message,uint32_t wparam,uint32_t lparam) {
    const uint32_t frame[]={UINT32_MAX,guest_window,message,wparam,lparam};
    return guest_callback(cpu,host,host->windowProcedure,frame,sizeof(frame));
}
static uint32_t copy_window_string(_cpu *cpu,NSString *text,uint32_t destination,int32_t capacity) {
    if(capacity<=0||!destination){host_error(cpu,87);return 0;}
    NSData *encoded=[text dataUsingEncoding:NSWindowsCP1252StringEncoding allowLossyConversion:YES];
    if(!encoded){host_error(cpu,1113);return 0;}
    size_t length=MIN(encoded.length,(size_t)capacity-1);
    unsigned char *output=host_memory(cpu,destination,length+1);
    memcpy(output,encoded.bytes,length);output[length]=0;return (uint32_t)length;
}
void tc_window_class_name(_cpu *cpu) {
    @autoreleasepool {
        TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
        if(!host||!host->guestWindow||host_arg(cpu,0)!=guest_window){host_error(cpu,1400);return;}
        cpu->_eax=copy_window_string(cpu,host.className,host_arg(cpu,1),(int32_t)host_arg(cpu,2));
    }
}
void tc_window_text(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    if(!host||!host->guestWindow||host_arg(cpu,0)!=guest_window){host_error(cpu,1400);return;}
    uint32_t destination=host_arg(cpu,1);int32_t capacity=(int32_t)host_arg(cpu,2);
    if(!destination||capacity<=0){host_error(cpu,87);return;}
    cpu->_eax=window_callback(cpu,host,0xd,(uint32_t)capacity,destination);
}
void tc_windows_enum(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    uint32_t callback=host_arg(cpu,0),parameter=host_arg(cpu,1);
    if(!host||!callback){host_error(cpu,87);return;}
    /* Only guest-owned top-level windows have translated HWNDs. Native settings
       and other macOS applications do not belong to this guest window namespace. */
    cpu->_eax=1;
    if(host->guestWindow) {
        const uint32_t frame[]={UINT32_MAX,guest_window,parameter};
        cpu->_eax=guest_callback(cpu,host,callback,frame,sizeof(frame))!=0;
    }
}
void tc_window_register(_cpu *cpu) {
    @autoreleasepool {
        TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
        if(!host){host_error(cpu,1400);return;}
        uint32_t info[10];memcpy(info,host_memory(cpu,host_arg(cpu,0),sizeof(info)),sizeof(info));
        NSString *name=host_string(cpu,info[9]);
        if(!name.length||!info[1]){host_error(cpu,87);return;}
        if(info[2]||info[3]||info[8]){host_error(cpu,50);return;}
        if(host.className){host_error(cpu,1410);return;}
        if(info[6]&&(info[6]&0xffff0000u)!=0xe5000000u){host_error(cpu,6);return;}
        if(info[7]&&((info[7]&0xffff0000u)!=0xe8000000u||(info[7]&UINT16_MAX)>5)) {
            host_error(cpu,50);return;
        }
        uint32_t cursor=info[6]&UINT16_MAX,brush=info[7];__block BOOL cursorValid;
        on_main(^{
            NSCursor *nativeCursor=stock_cursor(cursor);cursorValid=!cursor||nativeCursor!=nil;
            if(brush)host.window.backgroundColor=stock_brush(brush&UINT16_MAX);
            if(cursorValid){host.cursor=nativeCursor;[host.window invalidateCursorRectsForView:host.window.contentView];}
        });
        if(!cursorValid){host_error(cpu,6);return;}
        host.className=name;host->windowProcedure=info[1];host->classInstance=info[4];cpu->_eax=0xc001;
    }
}
void tc_window_create(_cpu *cpu) {
    @autoreleasepool {
        TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
        if(!host||!host.className){host_error(cpu,1407);return;}
        uint32_t args[12];for(unsigned i=0;i<12;i++)args[i]=host_arg(cpu,i);
        NSString *name=args[1]>UINT16_MAX?host_string(cpu,args[1]):nil;
        if((args[1]<=UINT16_MAX&&args[1]!=0xc001)||
           (args[1]>UINT16_MAX&&(!name||[name caseInsensitiveCompare:host.className]!=NSOrderedSame))) {
            host_error(cpu,1407);return;
        }
        if(host->guestWindow||args[8]||args[9]||(args[3]&0x40000000u)){host_error(cpu,50);return;}
        NSString *title=host_string(cpu,args[2]);if(!title){host_error(cpu,87);return;}
        host->guestWindow=YES;host->windowStyle=args[3];host->windowExtendedStyle=args[0];
        uint32_t width=args[6],height=args[7];BOOL visible=(args[3]&0x10000000u)!=0;
        int32_t x=(int32_t)args[4],y=(int32_t)args[5];uint32_t style=args[3];
        /* The AppKit/Metal surface already exists. Guest creation claims that
           single main window; child windows and Win32 menus are unsupported. */
        on_main(^{
            host.window.title=title;
            if(!(host.window.styleMask&NSWindowStyleMaskFullScreen)) {
                host.window.styleMask=window_mask(style);
                if(width&&height&&width<=16384&&height<=16384) {
                    NSRect rect=host.window.frame;rect.size=NSMakeSize(width,height);
                    [host.window setFrame:rect display:YES];
                }
                if(x==INT32_MIN)[host.window center];
                else {
                    NSRect screen=NSScreen.screens.firstObject.frame;
                    [host.window setFrameTopLeftPoint:NSMakePoint(NSMinX(screen)+x,NSMaxY(screen)-y)];
                }
            }
        });
        uint32_t original_stack=cpu->_esp;
        if(original_stack<(uint64_t)tc_read_fs(cpu,8)+68)abort();
        const uint32_t create[]={args[11],args[10],args[9],args[8],args[7],args[6],args[5],args[4],args[3],args[2],args[1],args[0]};
        cpu->_esp-=sizeof(create);uint32_t address=cpu->_esp;
        memcpy(host_memory(cpu,address,sizeof(create)),create,sizeof(create));
        uint32_t accepted=window_callback(cpu,host,0x81,0,address);
        if(accepted&&window_callback(cpu,host,1,0,address)==UINT32_MAX) {
            window_callback(cpu,host,0x82,0,0);accepted=0;
        }
        cpu->_esp=original_stack;
        if(!accepted){
            host->guestWindow=NO;on_main(^{[host.messages removeAllObjects];[host.window orderOut:nil];cursor_visibility(host);});
            host_error(cpu,1407);return;
        }
        on_main(^{
            if(visible)[host.window makeKeyAndOrderFront:nil];else [host.window orderOut:nil];
            post_size(host);post_message(host,0x1c,NSApp.isActive,0);cursor_visibility(host);
        });
        cpu->_eax=guest_window;
    }
}
static uint32_t destroy_window(_cpu *cpu,TCHost *host) {
    if(!host->guestWindow||host->destroying){host_error(cpu,1400);return 0;}
    host->destroying=YES;
    window_callback(cpu,host,2,0,0);window_callback(cpu,host,0x82,0,0);
    host->guestWindow=NO;host->destroying=NO;host->windowStyle&=~0x10000000u;
    on_main(^{[host.window orderOut:nil];[host.messages removeAllObjects];tc_input_release_all(&host->input);cursor_visibility(host);});
    return 1;
}
void tc_window_destroy(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    if(!host||host_arg(cpu,0)!=guest_window){host_error(cpu,1400);return;}
    cpu->_eax=destroy_window(cpu,host);
}
void tc_window_unregister(_cpu *cpu) {
    @autoreleasepool {
        TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
        uint32_t atom=host_arg(cpu,0),instance=host_arg(cpu,1);
        NSString *name=atom>UINT16_MAX?host_string(cpu,atom):nil;
        if(!host||!host.className||instance!=host->classInstance||
           (atom<=UINT16_MAX?atom!=0xc001:!name||[name caseInsensitiveCompare:host.className]!=NSOrderedSame)) {
            host_error(cpu,1411);return;
        }
        if(host->guestWindow){host_error(cpu,1412);return;}
        host.className=nil;host->windowProcedure=0;host->classInstance=0;cpu->_eax=1;
    }
}
void tc_message_peek(_cpu *cpu) {
    @autoreleasepool {
        TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
        uint32_t destination=host_arg(cpu,0),window=host_arg(cpu,1),first=host_arg(cpu,2),last=host_arg(cpu,3),flags=host_arg(cpu,4);
        if(!host||!destination||first>last){host_error(cpu,87);return;}
        if(window&&window!=UINT32_MAX&&window!=guest_window){host_error(cpu,1400);return;}
        if(flags&~3u){host_error(cpu,50);return;}
        __block NSData *found=nil;
        on_main(^{
            /* ponytail: linear queue search/removal; use indexed queues only if
               measured event traffic makes it material. All access is on main. */
            for(NSUInteger i=0;i<host.messages.count;i++) {
                NSData *entry=host.messages[i];TCMessage msg;memcpy(&msg,entry.bytes,sizeof(msg));
                if(message_matches(&msg,window,first,last)) {
                    found=entry;if(flags&1)[host.messages removeObjectAtIndex:i];break;
                }
            }
        });
        if(found)memcpy(host_memory(cpu,destination,sizeof(TCMessage)),found.bytes,sizeof(TCMessage));
        cpu->_eax=found?1:0;
    }
}
void tc_message_dispatch(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    TCMessage msg;memcpy(&msg,host_memory(cpu,host_arg(cpu,0),sizeof(msg)),sizeof(msg));
    if(!msg.window){cpu->_eax=0;return;}
    if(!host||!host->guestWindow||msg.window!=guest_window){host_error(cpu,1400);return;}
    if(msg.message==0x113&&msg.lparam){host_error(cpu,50);return;} /* TIMERPROC not supplied. */
    cpu->_eax=window_callback(cpu,host,msg.message,msg.wparam,msg.lparam);
}
void tc_message_translate(_cpu *cpu) {
    TCMessage msg;memcpy(&msg,host_memory(cpu,host_arg(cpu,0),sizeof(msg)),sizeof(msg));
    /* Gameplay input is delivered through DirectInput. Character-message
       translation is not implemented and is not reported as successful. */
    if(msg.message>=0x100&&msg.message<=0x105)host_error(cpu,50);else cpu->_eax=0;
}
void tc_window_update(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    if(!host||!host->guestWindow||host_arg(cpu,0)!=guest_window){host_error(cpu,1400);return;}
    on_main(^{[host.window displayIfNeeded];});
    /* The Metal view has no GDI update region. Present submits actual game draws. */
    cpu->_eax=1;
}
void tc_window_show(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    uint32_t command=host_arg(cpu,1);
    if(!host||!host->guestWindow||host_arg(cpu,0)!=guest_window){host_error(cpu,1400);return;}
    if(command>11){host_error(cpu,87);return;}
    __block BOOL wasVisible;
    on_main(^{
        wasVisible=host.window.isVisible;
        switch(command) {
            case 0:[host.window orderOut:nil];break;
            case 2:case 6:case 7:case 11:[host.window miniaturize:nil];break;
            case 3:if(!host.window.isZoomed)[host.window zoom:nil];[host.window makeKeyAndOrderFront:nil];break;
            case 4:case 8:[host.window orderFront:nil];break;
            default:
                if(host.window.isMiniaturized)[host.window deminiaturize:nil];
                if(command==9&&host.window.isZoomed)[host.window zoom:nil];
                [host.window makeKeyAndOrderFront:nil];break;
        }
        if(wasVisible!=host.window.isVisible)post_message(host,0x18,host.window.isVisible,0);
    });
    if(command)host->windowStyle|=0x10000000u;else host->windowStyle&=~0x10000000u;
    cpu->_eax=wasVisible;
}
void tc_window_default(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    if(!host||host_arg(cpu,0)!=guest_window){host_error(cpu,1400);return;}
    uint32_t message=host_arg(cpu,1);
    if(message==0x81){cpu->_eax=1;return;} /* WM_NCCREATE accepts creation. */
    if(message==0xc||message==0xd||message==0xe) {
        @autoreleasepool {
            if(message==0xc) {
                NSString *title=host_string(cpu,host_arg(cpu,3));if(!title){host_error(cpu,87);return;}
                on_main(^{host.window.title=title;});cpu->_eax=1;
            } else {
                __block NSString *title;on_main(^{title=host.window.title;});
                if(message==0xd)cpu->_eax=copy_window_string(cpu,title,host_arg(cpu,3),(int32_t)host_arg(cpu,2));
                else cpu->_eax=(uint32_t)[title lengthOfBytesUsingEncoding:NSWindowsCP1252StringEncoding];
            }
        }return;
    }
    if(message==0x10)destroy_window(cpu,host);
    cpu->_eax=0;
}
void tc_window_long(_cpu *cpu) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    if(!host||!host->guestWindow||host_arg(cpu,0)!=guest_window){host_error(cpu,1400);return;}
    switch((int32_t)host_arg(cpu,1)) {
        case -4:cpu->_eax=host->windowProcedure;break;
        case -6:cpu->_eax=host->classInstance;break;
        case -16:cpu->_eax=host->windowStyle;break;
        case -20:cpu->_eax=host->windowExtendedStyle;break;
        case -8:case -12:case -21:cpu->_eax=0;break;
        default:host_error(cpu,1413);break;
    }
}
@interface TCGameView : NSView
@property(weak) TCHost *host;
@end
@implementation TCGameView
- (void)resetCursorRects {[self addCursorRect:self.bounds cursor:self.host.cursor ?: NSCursor.arrowCursor];}
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)mouseMoved:(NSEvent *)e {
    TCHost *h=self.host;if(!h||!h.window.isKeyWindow)return;
    if(fabs(e.deltaX)+fabs(e.deltaY)>0.5)h->input.controller_active=0;
    h->mouseAxes[0]+=e.deltaX;h->mouseAxes[1]+=e.deltaY;
}
- (void)mouseDragged:(NSEvent *)e { [self mouseMoved:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self mouseMoved:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self mouseMoved:e]; }
- (void)mouseDown:(NSEvent *)e {host_mouse_button(self.host,0,YES);}
- (void)mouseUp:(NSEvent *)e {host_mouse_button(self.host,0,NO);}
- (void)rightMouseDown:(NSEvent *)e {host_mouse_button(self.host,1,YES);}
- (void)rightMouseUp:(NSEvent *)e {host_mouse_button(self.host,1,NO);}
- (void)otherMouseDown:(NSEvent *)e {host_mouse_button(self.host,(unsigned)e.buttonNumber,YES);}
- (void)otherMouseUp:(NSEvent *)e {host_mouse_button(self.host,(unsigned)e.buttonNumber,NO);}
- (void)scrollWheel:(NSEvent *)e { TCHost *h=self.host;if(h)h->mouseAxes[2]+=e.scrollingDeltaY*(e.hasPreciseScrollingDeltas?1:120); }
- (void)keyDown:(NSEvent *)e {
    if(e.keyCode<128&&keymap[e.keyCode])host_key(self.host,keymap[e.keyCode],YES);
    /* AppKit already resolves the keyboard layout and Shift. The original
       save-name editor consumes WM_CHAR, independently of DirectInput. */
    if(e.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagControl))return;
    NSData *text=[e.characters dataUsingEncoding:NSWindowsCP1252StringEncoding allowLossyConversion:NO];
    const unsigned char *bytes=text.bytes;
    for(NSUInteger i=0;i<text.length;i++)
        post_message(self.host,0x102,bytes[i]==127?8:bytes[i],1);
}
- (void)keyUp:(NSEvent *)e { if(e.keyCode<128&&keymap[e.keyCode])host_key(self.host,keymap[e.keyCode],NO); }
- (void)flagsChanged:(NSEvent *)e {
    NSEventModifierFlags flags=e.modifierFlags;
    const unsigned codes[]={29,42,56,219,58};
    const NSEventModifierFlags masks[]={NSEventModifierFlagControl,NSEventModifierFlagShift,NSEventModifierFlagOption,NSEventModifierFlagCommand,NSEventModifierFlagCapsLock};
    /* Aggregate modifier flags cannot distinguish both sides. Use the event key
     * to update its side; clear both sides when the aggregate flag is released. */
    const unsigned right[]={157,54,184,220,58};
    unsigned code=e.keyCode<128?keymap[e.keyCode]:0;
    for(unsigned i=0;i<5;i++) {
        if(!(flags&masks[i])){host_key(self.host,codes[i],NO);host_key(self.host,right[i],NO);}
        else if(code==codes[i]||code==right[i])host_key(self.host,code,!self.host->input.keyboard[code]);
    }
}
@end

@implementation TCHost
- (void)applicationActivityChanged:(NSNotification *)note {post_message(self,0x1c,NSApp.isActive,0);}
- (void)windowDidBecomeKey:(NSNotification *)note {
    if(note.object==self.window){post_message(self,6,1,0);post_message(self,7,0,0);cursor_visibility(self);}
}
- (void)windowDidResignKey:(NSNotification *)note {
    if(note.object==self.window){
        tc_input_release_all(&input);memset(mouseAxes,0,sizeof(mouseAxes));memset(mouseButtons,0,sizeof(mouseButtons));
        memset(asyncPressed,0,sizeof(asyncPressed));memset(asyncDown,0,sizeof(asyncDown));cursor_visibility(self);
        post_message(self,8,0,0);post_message(self,6,0,0);
    }
}
- (void)windowDidResize:(NSNotification *)note {if(note.object==self.window)post_size(self);}
- (void)windowDidMiniaturize:(NSNotification *)note {if(note.object==self.window)post_size(self);}
- (void)windowDidDeminiaturize:(NSNotification *)note {if(note.object==self.window)post_size(self);}
- (void)requestQuit:(id)sender {
    if(guestWindow)post_message(self,0x10,0,0);else [NSApp terminate:nil];
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
    if(sender==self.window){tc_input_release_all(&input);[self requestQuit:nil];return NO;}return YES;
}

@end
static int prepare_graphics(_cpu *cpu,uint32_t parameters[13]) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;
    if(!host)return -1;
    /* The original Display menu owns reset parameters and INI persistence. */
    /* A virtual UI-scale resolution still opens the window at the output size. */
    uint32_t width,height;tc_modern_output((tc_cpu *)cpu,parameters[0],parameters[1],&width,&height);
    on_main(^{
        if(!(host.window.styleMask&NSWindowStyleMaskFullScreen))
            [host.window setContentSize:NSMakeSize(width,height)];
    });
    return 0;
}
static void frame(_cpu *cpu) {
    tc_cpu *c=(tc_cpu *)cpu;TCHost *host=(__bridge TCHost *)c->platform;
    if(!host)return;
    __block tc_input snapshot;
    void (^capture)(void)=^{
        if(!c->headless) {
            tc_controller_poll(&host->input);
            if(!host.window.isKeyWindow)tc_input_release_all(&host->input);
            cursor_visibility(host);
        }
        snapshot=host->input;

    };
    if(NSThread.isMainThread)capture();else dispatch_sync(dispatch_get_main_queue(),capture);
    tc_modern_input(c,&snapshot);
    on_main(^{
        double now=NSProcessInfo.processInfo.systemUptime,delta[2]={0};
        double elapsed=host->controllerTime?now-host->controllerTime:0;host->controllerTime=now;
        if(!tc_input_camera_delta(&snapshot,tc_modern_get(c,TC_LOOK_SPEED)*4,
            tc_modern_get(c,TC_INVERT_LOOK),elapsed,delta)) {
            host->mouseAxes[0]+=delta[0];host->mouseAxes[1]+=delta[1];
        }
    });
    /* Keep bindings edited by the original Keyboard Controls screen. */
    if(tc_input_publish(&snapshot,host->image))abort();
    if(c!=&host->image->cpu)memcpy(c->input_keyboard,host->image->cpu.input_keyboard,sizeof(c->input_keyboard));
}
static int read_controller(_cpu *cpu,int32_t axes[8],uint32_t pov[4],unsigned char buttons[128]) {
    tc_cpu *c=(tc_cpu *)cpu;TCHost *host=(__bridge TCHost *)c->platform;
    memset(axes,0,8*sizeof(*axes));memset(pov,255,4*sizeof(*pov));memset(buttons,0,128);
    if(!host||c->headless)return 0;
    __block int connected=0;
    on_main(^{
        connected=tc_controller_poll(&host->input);
        if(!host.window.isKeyWindow)return;
        /* SDL buttons, movement and camera are published through the PC
           keyboard/mouse path in frame(); do not inject duplicate legacy input. */
    });
    return connected;
}
static void read_mouse(_cpu *cpu,int32_t axes[3],unsigned char buttons[8]) {
    TCHost *host=(__bridge TCHost *)((tc_cpu *)cpu)->platform;if(!host)return;
    void (^capture)(void)=^{
        if(!host.window.isKeyWindow){memset(axes,0,12);memset(buttons,0,8);return;}
        for(unsigned i=0;i<3;i++) {
            double v=host->mouseAxes[i];if(!isfinite(v))v=0;
            v=fmax(INT32_MIN,fmin(INT32_MAX,trunc(v)));axes[i]=(int32_t)v;host->mouseAxes[i]-=v;
        }
        memcpy(buttons,host->mouseButtons,8);
    };
    if(NSThread.isMainThread)capture();else dispatch_sync(dispatch_get_main_queue(),capture);
}
int tc_host_open(tc_image *image, const char *path) {
    if(!NSThread.isMainThread||!image||!image->cpu.memory_size||image->cpu.platform||!path)return -1;
    @autoreleasepool {
        TCHost *host=[TCHost new];host->image=image;atomic_init(&host->guestWindow,false);
        host.messages=[NSMutableArray new];host.path=[NSString stringWithUTF8String:path];if(!host.path)return -1;
        host->preferences=tc_preferences_defaults();
        if([[NSFileManager defaultManager]fileExistsAtPath:host.path]&&tc_preferences_load(path,&host->preferences))return -1;
        host->startupGraphics=host->preferences.graphics;

        if(image->cpu.headless) {
            host->startupGraphics.windowed=1;
            if(tc_d3d_attach(&image->cpu,nil))return -1;
            image->cpu.platform=(__bridge_retained void *)host;image->cpu.frame_input=frame;
            image->cpu.read_mouse=read_mouse;image->cpu.read_controller=read_controller;image->cpu.prepare_graphics=prepare_graphics;
            headless_input(host);return 0;
        }
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        host.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,host->preferences.graphics.width,host->preferences.graphics.height)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        host.window.title=@"True Crime: Streets of LA";host.window.delegate=host;host.window.releasedWhenClosed=NO;
        host.window.acceptsMouseMovedEvents=YES;
        TCGameView *view=[[TCGameView alloc]initWithFrame:host.window.contentView.bounds];view.host=host;view.wantsLayer=YES;
        host.window.contentView=view;
        if(tc_d3d_attach(&image->cpu,(CAMetalLayer *)view.layer))return -1;
        NSMenu *main=[NSMenu new];NSMenuItem *app=[NSMenuItem new];[main addItem:app];app.submenu=[NSMenu new];
        NSMenuItem *quit=[app.submenu addItemWithTitle:@"Quit" action:@selector(requestQuit:) keyEquivalent:@"q"];quit.target=host;NSApp.mainMenu=main;
        image->cpu.platform=(__bridge_retained void *)host;image->cpu.frame_input=frame;
        image->cpu.read_mouse=read_mouse;image->cpu.read_controller=read_controller;image->cpu.prepare_graphics=prepare_graphics;
        [NSNotificationCenter.defaultCenter addObserver:host selector:@selector(applicationActivityChanged:)
            name:NSApplicationDidBecomeActiveNotification object:NSApp];
        [NSNotificationCenter.defaultCenter addObserver:host selector:@selector(applicationActivityChanged:)
            name:NSApplicationDidResignActiveNotification object:NSApp];
        [host.window center];[host.window makeKeyAndOrderFront:nil];[host.window makeFirstResponder:view];
        if(!host->preferences.graphics.windowed)[host.window toggleFullScreen:nil];return 0;
    }
}
void tc_host_close(tc_image *image) {
    if(!NSThread.isMainThread||!image||!image->cpu.platform)return;
    TCHost *host=(__bridge_transfer TCHost *)image->cpu.platform;
    tc_controller_close();
    host->cursorCount=0;cursor_visibility(host);
    [NSNotificationCenter.defaultCenter removeObserver:host];
    image->cpu.platform=NULL;image->cpu.frame_input=NULL;
    image->cpu.read_mouse=NULL;image->cpu.read_controller=NULL;image->cpu.prepare_graphics=NULL;
    host.window.delegate=nil;[host.window close];
}
#ifdef TC_HOST_SELF_CHECK
#include <assert.h>
static void check_window_callback(_cpu *cpu,uint32_t address) {
    assert(address==0x1234);
    const uint32_t expected[]={UINT32_MAX,guest_window,1,2,3};
    assert(!memcmp(host_memory(cpu,cpu->_esp,sizeof(expected)),expected,sizeof(expected)));
    cpu->_eax=123;cpu->_ebx=456;cpu->_esp+=sizeof(expected);
}
static void check_enum_callback(_cpu *cpu,uint32_t address) {
    assert(address==0x5678);const uint32_t expected[]={UINT32_MAX,guest_window,0xabcdef};
    assert(!memcmp(host_memory(cpu,cpu->_esp,sizeof(expected)),expected,sizeof(expected)));
    cpu->_eax=0;cpu->_ebx=987;cpu->_esp+=sizeof(expected);
}
int main(void) {
    assert(keymap[13]==17&&keymap[49]==57&&keymap[126]==200);
    unsigned scan;BOOL down;
    assert(headless_key_command("down 28\n",&scan,&down)&&scan==28&&down);
    assert(headless_key_command("up 200\n",&scan,&down)&&scan==200&&!down);
    assert(!headless_key_command("down -1",&scan,&down)&&!headless_key_command("down 256",&scan,&down));
    assert(!headless_key_command("down 99999999999999999999999",&scan,&down));
    assert(!headless_key_command("up 28 extra",&scan,&down)&&!headless_key_command("down 0",&scan,&down));
    TCHost *keyHost=[TCHost new];
    host_key(keyHost,17,YES);host_key(keyHost,17,NO);
    assert(keyHost->asyncPressed['W']&&!virtual_down(keyHost->input.keyboard,'W'));
    host_key(keyHost,54,YES);
    assert(virtual_down(keyHost->input.keyboard,16)&&virtual_down(keyHost->input.keyboard,0xa1));
    assert(!virtual_down(keyHost->input.keyboard,0xa0));
    host_mouse_button(keyHost,4,YES);host_mouse_button(keyHost,4,NO);
    assert(keyHost->asyncPressed[6]&&!keyHost->mouseButtons[4]);
    assert(window_mask(0x80000000u)==NSWindowStyleMaskBorderless);
    assert((window_mask(0x00cf0000u)&(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable))==
        (NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable));
    unsigned char geometry_memory[512]={0};tc_cpu geometry_cpu={0};
    geometry_cpu.scalar._pointer_offset=(uintptr_t)geometry_memory;geometry_cpu.memory_size=sizeof(geometry_memory);
    geometry_cpu.scalar._esp=32;geometry_cpu.fs_base=256;geometry_cpu.fs_size=64;
    uint32_t brush_argument=4;memcpy(geometry_memory+36,&brush_argument,4);
    tc_stock_object(&geometry_cpu.scalar);assert(geometry_cpu.scalar._eax==0xe8000004u);
    brush_argument=99;memcpy(geometry_memory+36,&brush_argument,4);
    tc_stock_object(&geometry_cpu.scalar);assert(!geometry_cpu.scalar._eax&&tc_read_fs(&geometry_cpu.scalar,0x34)==50);
    const uint32_t geometry_args[]={96,0x00cf0000u,0};int32_t rect[]={-10,20,790,620};
    memcpy(geometry_memory+36,geometry_args,sizeof(geometry_args));memcpy(geometry_memory+96,rect,sizeof(rect));
    tc_window_adjust(&geometry_cpu.scalar);assert(geometry_cpu.scalar._eax==1);
    memcpy(rect,geometry_memory+96,sizeof(rect));
    NSRect restored=[NSWindow contentRectForFrameRect:NSMakeRect(rect[0],-rect[3],rect[2]-rect[0],rect[3]-rect[1])
        styleMask:window_mask(0x00cf0000u)];
    assert(NSMinX(restored)==-10&&NSMaxY(restored)==-20&&NSWidth(restored)==800&&NSHeight(restored)==600);
    TCMessage message={guest_window,5,0,0,0,0,0};
    assert(message_matches(&message,guest_window,5,5));
    assert(!message_matches(&message,UINT32_MAX,0,0));
    assert(!message_matches(&message,0,6,8));
    message.window=0;message.message=0x12;
    assert(message_matches(&message,guest_window,6,8));
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
        @autoreleasepool {
            unsigned char memory[1024]={0};tc_image image={0};
            image.cpu.scalar._pointer_offset=(uintptr_t)memory;image.cpu.memory_size=sizeof(memory);
            image.cpu.scalar._esp=768;image.stack_limit=256;image.cpu.guest_invoke=check_window_callback;
            image.cpu.fs_base=128;image.cpu.fs_size=64;tc_write_fs(&image.cpu.scalar,8,256);
            TCHost *host=[TCHost new];host->image=&image;host->windowProcedure=0x1234;
            assert(window_callback(&image.cpu.scalar,host,1,2,3)==123);
            assert(image.cpu.scalar._esp==768&&image.cpu.scalar._eax==0&&image.cpu.scalar._ebx==0);
            assert(copy_window_string(&image.cpu.scalar,@"Café",100,4)==3&&!memcmp(memory+100,"Caf\0",4));
            assert(copy_window_string(&image.cpu.scalar,@"Café",100,5)==4&&!memcmp(memory+100,"Caf\xe9\0",5));
            image.cpu.platform=(__bridge void *)host;host->guestWindow=true;
            image.cpu.guest_invoke=check_enum_callback;
            const uint32_t enum_args[]={0x5678,0xabcdef};memcpy(memory+772,enum_args,sizeof(enum_args));
            tc_windows_enum(&image.cpu.scalar);
            assert(!image.cpu.scalar._eax&&image.cpu.scalar._esp==768&&!image.cpu.scalar._ebx);
            host->guestWindow=false;tc_windows_enum(&image.cpu.scalar);assert(image.cpu.scalar._eax==1);
            dispatch_semaphore_signal(done);
        }
    });
    dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);return 0;
}
#endif

/* The original key-name tables select a primary Windows language identifier. */
void tc_system_language(_cpu *cpu) {
    @autoreleasepool {
        NSLocale *locale=NSLocale.currentLocale;
        NSString *language=[locale objectForKey:NSLocaleLanguageCode];
        NSDictionary *identifiers=@{@"en":@0x0409,@"fr":@0x040c,@"de":@0x0407,
            @"es":@0x040a,@"it":@0x0410,@"pt":@0x0416,@"ja":@0x0411,
            @"ko":@0x0412,@"zh":@0x0804,@"ru":@0x0419};
        NSNumber *identifier=identifiers[language];cpu->_eax=identifier?identifier.unsignedIntValue:0x0409;
        if([language isEqualToString:@"en"]&&[[locale objectForKey:NSLocaleCountryCode]isEqualToString:@"GB"])
            cpu->_eax=0x0809;
    }
}
