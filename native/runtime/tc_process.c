#include "tc_process.h"
#include "tc_heap.h"
#include <CoreFoundation/CoreFoundation.h>
#include <crt_externs.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <sys/resource.h>
#include <errno.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>

struct tc_process {
    struct tc_heap_process *heaps;
    uint32_t environment_heap[2];
    CFDataRef environment[2];
    _Atomic uint32_t unhandled_filter;
    int priority_base;
};

static CFDataRef environment_block(char *const *entries,int wide) {
    CFMutableStringRef text=CFStringCreateMutable(NULL,0);
    if(!text)return NULL;
    const UniChar zero=0;
    for(size_t i=0;entries[i];i++) {
        CFStringRef entry=CFStringCreateWithCString(NULL,entries[i],kCFStringEncodingUTF8);
        if(!entry) {CFRelease(text);return NULL;}
        CFStringAppend(text,entry);CFStringAppendCharacters(text,&zero,1);
        CFRelease(entry);
    }
    if(!CFStringGetLength(text))CFStringAppendCharacters(text,&zero,1);
    CFStringAppendCharacters(text,&zero,1);
    /* GetEnvironmentStrings returns OEM bytes, even though most ANSI APIs use
       Windows-1252. Explicit UTF-16LE conversion avoids an external BOM.
       https://learn.microsoft.com/en-us/windows/win32/api/processenv/nf-processenv-getenvironmentstringsw */
    CFStringEncoding encoding=wide?kCFStringEncodingUTF16LE:kCFStringEncodingDOSLatinUS;
    CFRange range=CFRangeMake(0,CFStringGetLength(text));
    CFIndex length=0;
    if(CFStringGetBytes(text,range,encoding,'?',false,NULL,0,&length)!=range.length ||
       length<=0 || (uint64_t)length>UINT32_MAX) {CFRelease(text);return NULL;}
    CFMutableDataRef result=CFDataCreateMutable(NULL,length);
    if(result) {
        CFDataSetLength(result,length);
        if(CFStringGetBytes(text,range,encoding,'?',false,CFDataGetMutableBytePtr(result),length,NULL)!=range.length) {
            CFRelease(result);result=NULL;
        }
    }
    CFRelease(text);return result;
}
struct tc_process *tc_process_create(struct tc_heap_process *heaps) {
    struct tc_process *p=calloc(1,sizeof(*p));
    if(!p)return NULL;
    errno=0;p->priority_base=getpriority(PRIO_PROCESS,0);
    if(errno){free(p);return NULL;}
    p->heaps=heaps;
    atomic_init(&p->unhandled_filter,0);
    /* Snapshot before the game worker starts. Guest environment changes are
       not yet implemented; host environment changes do not alter this copy. */
    for(unsigned i=0;i<2;i++) {
        p->environment[i]=environment_block(*_NSGetEnviron(),i);
        p->environment_heap[i]=tc_heap_create(heaps,0,0,0);
        if(!p->environment[i] || !p->environment_heap[i]) {
            tc_process_destroy(p);return NULL;
        }
    }
    return p;
}
void tc_process_destroy(struct tc_process *p) {
    if(!p)return;
    for(unsigned i=0;i<2;i++) {
        if(p->environment[i])CFRelease(p->environment[i]);
        if(p->environment_heap[i])tc_heap_destroy(p->heaps,p->environment_heap[i]);
    }
    free(p);
}

static void *memory(tc_cpu *c, uint64_t address, size_t size) {
    if (!address || address > UINT32_MAX || size > c->memory_size ||
        address > c->memory_size-size || c->scalar._pointer_offset > UINTPTR_MAX-address-size) abort();
    return (void *)(uintptr_t)(c->scalar._pointer_offset+address);
}
static uint32_t argument_at(_cpu *cpu,unsigned index) {
    uint32_t value;
    memcpy(&value,memory((tc_cpu *)cpu,(uint64_t)cpu->_esp+4+(uint64_t)index*4,4),4);
    return value;
}
static uint32_t argument(_cpu *cpu) {return argument_at(cpu,0);}
static CFStringEncoding codepage(uint32_t page) {
    switch(page) {
        case 0:case 3:case 1252:return kCFStringEncodingWindowsLatin1;
        case 1:case 437:return kCFStringEncodingDOSLatinUS;
        default:return kCFStringEncodingInvalidId;
    }
}
static void process_error(_cpu *cpu,uint32_t error) {
    cpu->_eax=0;tc_write_fs(cpu,0x34,error);
}
void tc_version_info(_cpu *cpu) {
    uint32_t address=argument(cpu),size;
    if(!address){process_error(cpu,87);return;}
    memcpy(&size,memory((tc_cpu *)cpu,address,4),4);
    if(size!=148&&size!=156){process_error(cpu,87);return;}
    /* This is the guest ABI compatibility level, not the host OS version.
       The recovered CRT branches on NT versus DOS and major/minor version.
       Keep it on the game's Windows XP NT path while native APIs replace Win32. */
    unsigned char output[156]={0};
    const uint32_t fields[]={size,5,1,2600,2};
    memcpy(output,fields,sizeof(fields));
    if(size==156)output[154]=1; /* VER_NT_WORKSTATION, no service pack. */
    memcpy(memory((tc_cpu *)cpu,address,size),output,size);cpu->_eax=1;
}
void tc_ansi_codepage(_cpu *cpu) {cpu->_eax=1252;}
void tc_oem_codepage(_cpu *cpu) {cpu->_eax=437;}
void tc_codepage_info(_cpu *cpu) {
    uint32_t address=argument_at(cpu,1);
    if(codepage(argument(cpu))==kCFStringEncodingInvalidId || !address) {
        process_error(cpu,87);return;
    }
    /* CPINFO: DWORD MaxCharSize, two default bytes, twelve lead-byte bytes,
       and two bytes of trailing structure alignment. Both pages are SBCS. */
    unsigned char info[20]={1,0,0,0,'?'};
    memcpy(memory((tc_cpu *)cpu,address,sizeof(info)),info,sizeof(info));cpu->_eax=1;
}
static size_t text_length(tc_cpu *c,uint32_t address,int32_t count,unsigned width) {
    if(count!=-1)return (size_t)count;
    for(size_t length=0;length<INT32_MAX;length++) {
        uint16_t value=0;
        memcpy(&value,memory(c,(uint64_t)address+length*width,width),width);
        if(!value)return length+1;
    }
    return 0;
}
void tc_multibyte_to_wide(_cpu *cpu) {
    tc_cpu *c=(tc_cpu *)cpu;
    CFStringEncoding encoding=codepage(argument(cpu));
    uint32_t flags=argument_at(cpu,1),source=argument_at(cpu,2),destination=argument_at(cpu,4);
    int32_t count=(int32_t)argument_at(cpu,3),capacity=(int32_t)argument_at(cpu,5);
    if(encoding==kCFStringEncodingInvalidId || !source || !count || count < -1 ||
       capacity<0 || (capacity&&(!destination||source==destination))) {process_error(cpu,87);return;}
    if((flags&~11u) || (flags&3)==3) {process_error(cpu,1004);return;}
    size_t length=text_length(c,source,count,1);
    CFStringRef text=CFStringCreateWithBytes(NULL,memory(c,source,length),length,encoding,false);
    if(!text) {process_error(cpu,1113);return;}
    if(flags&2) {
        CFMutableStringRef decomposed=CFStringCreateMutableCopy(NULL,0,text);CFRelease(text);
        if(!decomposed) {process_error(cpu,8);return;}
        CFStringNormalize(decomposed,kCFStringNormalizationFormD);text=decomposed;
    }
    CFIndex needed=CFStringGetLength(text);
    if(needed>INT32_MAX)process_error(cpu,87);
    else if(capacity&&capacity<needed)process_error(cpu,122);
    else {
        if(capacity) {
            CFIndex bytes=0;
            CFStringGetBytes(text,CFRangeMake(0,needed),kCFStringEncodingUTF16LE,0,false,
                            memory(c,destination,(size_t)needed*2),needed*2,&bytes);
            if(bytes!=needed*2)abort();
        }
        cpu->_eax=(uint32_t)needed;
    }
    CFRelease(text);
}
static CFDataRef encode_single_byte(CFStringRef text,CFStringEncoding encoding,
                                   unsigned char replacement,uint32_t *used) {
    CFMutableDataRef result=CFDataCreateMutable(NULL,0);
    if(!result)return NULL;
    *used=0;
    /* ponytail: per-code-point conversion favors explicit replacement semantics;
       batch conversion if startup text volume becomes material. Windows best-fit
       transliteration is not implemented; unmappable code points use replacement. */
    for(CFIndex i=0,length=CFStringGetLength(text);i<length;) {
        UniChar first=CFStringGetCharacterAtIndex(text,i);
        CFIndex units=1;
        if(first>=0xd800&&first<=0xdbff&&i+1<length) {
            UniChar next=CFStringGetCharacterAtIndex(text,i+1);
            if(next>=0xdc00&&next<=0xdfff)units=2;
        }
        unsigned char byte=replacement;CFIndex written=0;
        if(CFStringGetBytes(text,CFRangeMake(i,units),encoding,0,false,&byte,1,&written)!=units || written!=1) {
            byte=replacement;*used=1;
        }
        CFDataAppendBytes(result,&byte,1);i+=units;
    }
    return result;
}
static int english_locale(uint32_t locale) {
    return locale==0||locale==0x7f||locale==0x400||locale==0x800||locale==0x409||locale==0x809;
}
static int character_member(UniChar ch,CFCharacterSetPredefinedSet set) {
    return CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(set),ch);
}
static uint16_t character_type(UniChar ch) {
    if((ch>=0xd800&&ch<=0xdfff)||character_member(ch,kCFCharacterSetIllegal))return 0;
    uint16_t type=0x200;
    if(character_member(ch,kCFCharacterSetUppercaseLetter))type|=1;
    if(character_member(ch,kCFCharacterSetLowercaseLetter))type|=2;
    if(character_member(ch,kCFCharacterSetDecimalDigit))type|=4;
    if(character_member(ch,kCFCharacterSetWhitespaceAndNewline)||ch==9)type|=8;
    /* C/POSIX punctuation includes printable symbols such as + and $. */
    if(character_member(ch,kCFCharacterSetPunctuation)||character_member(ch,kCFCharacterSetSymbol))type|=16;
    if(character_member(ch,kCFCharacterSetControl))type|=32;
    if(character_member(ch,kCFCharacterSetWhitespace))type|=64;
    if((ch>='0'&&ch<='9')||(ch>='A'&&ch<='F')||(ch>='a'&&ch<='f')||
       (ch>=0xff10&&ch<=0xff19)||(ch>=0xff21&&ch<=0xff26)||(ch>=0xff41&&ch<=0xff46))type|=128;
    if(character_member(ch,kCFCharacterSetLetter)&&!character_member(ch,kCFCharacterSetNonBase))type|=256;
    return type;
}
static void string_type(_cpu *cpu,int wide) {
    tc_cpu *c=(tc_cpu *)cpu;unsigned offset=wide?0:1;
    uint32_t kind=argument_at(cpu,offset),source=argument_at(cpu,offset+1);
    int32_t count=(int32_t)argument_at(cpu,offset+2);
    uint32_t destination=argument_at(cpu,offset+3);
    if((!wide&&!english_locale(argument(cpu)))||!source||!destination||source==destination||!count) {
        process_error(cpu,87);return;
    }
    if(kind!=1) {process_error(cpu,kind==2||kind==4?50:1004);return;}
    size_t length=text_length(c,source,count<0?-1:count,wide?2:1);
    const unsigned char *input=memory(c,source,length*(wide?2:1));
    CFStringRef text=wide?NULL:CFStringCreateWithBytes(NULL,input,length,kCFStringEncodingWindowsLatin1,false);
    if(!wide&&!text) {process_error(cpu,1113);return;}
    if(text&&CFStringGetLength(text)!=(CFIndex)length) {CFRelease(text);process_error(cpu,1113);return;}
    uint16_t *types=malloc(length*sizeof(*types));
    if(!types) {if(text)CFRelease(text);process_error(cpu,8);return;}
    for(size_t i=0;i<length;i++) {
        UniChar ch;
        if(wide)memcpy(&ch,input+i*2,2);else ch=CFStringGetCharacterAtIndex(text,i);
        types[i]=character_type(ch);
    }
    memcpy(memory(c,destination,length*2),types,length*2);
    free(types);if(text)CFRelease(text);cpu->_eax=1;
}
void tc_string_type_a(_cpu *cpu) {string_type(cpu,0);}
void tc_string_type_w(_cpu *cpu) {string_type(cpu,1);}
static void map_case(_cpu *cpu,int wide) {
    tc_cpu *c=(tc_cpu *)cpu;
    uint32_t locale=argument(cpu),flags=argument_at(cpu,1);
    uint32_t source=argument_at(cpu,2),destination=argument_at(cpu,4);
    int32_t count=(int32_t)argument_at(cpu,3),capacity=(int32_t)argument_at(cpu,5);
    /* The native guest currently exposes an English Windows-1252 environment.
       Reject other LCIDs rather than silently applying the wrong case rules. */
    if(!english_locale(locale)||
       !source||!count||capacity<0||(capacity&&!destination)) {process_error(cpu,87);return;}
    uint32_t operation=flags&~0x40000000u; /* LOCALE_USE_CP_ACP */
    if(operation!=0x100&&operation!=0x200) {process_error(cpu,1004);return;}
    size_t length=text_length(c,source,count<0?-1:count,wide?2:1);
    CFStringRef input=CFStringCreateWithBytes(NULL,memory(c,source,length*(wide?2:1)),
        length*(wide?2:1),wide?kCFStringEncodingUTF16LE:kCFStringEncodingWindowsLatin1,false);
    if(!input) {process_error(cpu,1113);return;}
    CFMutableStringRef text=CFStringCreateMutableCopy(NULL,0,input);CFRelease(input);
    CFLocaleRef rules=CFLocaleCreate(NULL,locale==0x7f?CFSTR("en_US_POSIX"):
        locale==0x809?CFSTR("en_GB"):CFSTR("en_US"));
    if(!text||!rules) {
        if(text)CFRelease(text);if(rules)CFRelease(rules);process_error(cpu,8);return;
    }
    if(operation==0x100)CFStringLowercase(text,rules);else CFStringUppercase(text,rules);
    CFRelease(rules);
    uint32_t replaced=0;
    CFDataRef bytes=wide?NULL:encode_single_byte(text,kCFStringEncodingWindowsLatin1,'?',&replaced);
    if(!wide&&!bytes) {CFRelease(text);process_error(cpu,8);return;}
    CFIndex needed=wide?CFStringGetLength(text):CFDataGetLength(bytes);
    if(needed>INT32_MAX)process_error(cpu,87);
    else if(capacity&&capacity<needed)process_error(cpu,122);
    else {
        if(capacity) {
            if(wide) {
                CFIndex written=0;
                CFStringGetBytes(text,CFRangeMake(0,needed),kCFStringEncodingUTF16LE,0,false,
                    memory(c,destination,(size_t)needed*2),needed*2,&written);
                if(written!=needed*2)abort();
            } else memcpy(memory(c,destination,(size_t)needed),CFDataGetBytePtr(bytes),(size_t)needed);
        }
        cpu->_eax=(uint32_t)needed;
    }
    if(bytes)CFRelease(bytes);CFRelease(text);
}
void tc_map_string_a(_cpu *cpu) {map_case(cpu,0);}
void tc_map_string_w(_cpu *cpu) {map_case(cpu,1);}
void tc_wide_to_multibyte(_cpu *cpu) {
    tc_cpu *c=(tc_cpu *)cpu;
    CFStringEncoding encoding=codepage(argument(cpu));
    uint32_t flags=argument_at(cpu,1),source=argument_at(cpu,2),destination=argument_at(cpu,4);
    int32_t count=(int32_t)argument_at(cpu,3),capacity=(int32_t)argument_at(cpu,5);
    uint32_t default_address=argument_at(cpu,6),used_address=argument_at(cpu,7);
    if(encoding==kCFStringEncodingInvalidId || !source || !count || count < -1 ||
       capacity<0 || (capacity&&(!destination||source==destination))) {process_error(cpu,87);return;}
    if(flags&~0x400u) {process_error(cpu,1004);return;}
    size_t length=text_length(c,source,count,2);
    /* Copy handles potentially unaligned guest UTF-16 input. CFString accepts
       unpaired surrogates, which the output converter replaces explicitly. */
    UniChar *characters=malloc(length*2);
    if(!characters) {process_error(cpu,8);return;}
    memcpy(characters,memory(c,source,length*2),length*2);
    CFStringRef text=CFStringCreateWithCharacters(NULL,characters,length);free(characters);
    if(!text) {process_error(cpu,8);return;}
    unsigned char replacement='?';
    if(default_address)memcpy(&replacement,memory(c,default_address,1),1);
    uint32_t used=0;
    CFDataRef data=encode_single_byte(text,encoding,replacement,&used);CFRelease(text);
    if(!data) {process_error(cpu,8);return;}
    CFIndex needed=CFDataGetLength(data);
    if(needed>INT32_MAX)process_error(cpu,87);
    else if(capacity&&capacity<needed)process_error(cpu,122);
    else {
        if(capacity)memcpy(memory(c,destination,needed),CFDataGetBytePtr(data),needed);
        if(used_address)memcpy(memory(c,used_address,4),&used,4);
        cpu->_eax=(uint32_t)needed;
    }
    CFRelease(data);
}
static void get_environment(_cpu *cpu,unsigned wide) {
    tc_cpu *c=(tc_cpu *)cpu;struct tc_process *p=c->process;
    if(!p)abort();
    uint32_t length=(uint32_t)CFDataGetLength(p->environment[wide]);
    cpu->_eax=tc_heap_alloc(p->heaps,p->environment_heap[wide],0,length);
    if(cpu->_eax)memcpy(memory(c,cpu->_eax,length),CFDataGetBytePtr(p->environment[wide]),length);
    else tc_write_fs(cpu,0x34,8);
}
static void free_environment(_cpu *cpu,unsigned wide) {
    struct tc_process *p=((tc_cpu *)cpu)->process;
    if(!p)abort();
    cpu->_eax=tc_heap_free(p->heaps,p->environment_heap[wide],argument(cpu));
    if(!cpu->_eax)tc_write_fs(cpu,0x34,87);
}
void tc_environment_a(_cpu *cpu) {get_environment(cpu,0);}
void tc_environment_w(_cpu *cpu) {get_environment(cpu,1);}
void tc_free_environment_a(_cpu *cpu) {free_environment(cpu,0);}
void tc_free_environment_w(_cpu *cpu) {free_environment(cpu,1);}
void tc_command_line(_cpu *cpu) {
    tc_cpu *c=(tc_cpu *)cpu;
    if (!c->command_line_address) abort();
    cpu->_eax=c->command_line_address;
}
static void startup_info(unsigned char output[68]) {
    memset(output,0,68);
    /* 32-bit STARTUPINFOA: ordinary GUI launch, no inherited console handles. */
    const uint32_t size=68,flags=1;
    const uint16_t show=1;
    memcpy(output,&size,4);memcpy(output+44,&flags,4);memcpy(output+48,&show,2);
}
void tc_startup_info(_cpu *cpu) {
    unsigned char output[68];startup_info(output);
    memcpy(memory((tc_cpu *)cpu,argument(cpu),sizeof(output)),output,sizeof(output));
}
static const char *const modules[]={"kernel32.dll","d3d8.dll","dinput8.dll","user32.dll","winmm.dll","advapi32.dll","gdi32.dll"};
static const struct { uint32_t address; const char *name; } exports[]={
#define TC_IMPORT(slot,target,bytes,handler,name) {target,name},
#include "tc_imports.def"
#undef TC_IMPORT
};
static int guest_string(tc_cpu *c,uint32_t address,char *name,size_t capacity) {
    if(!address)return 0;
    for(size_t i=0;i<capacity;i++) {
        memcpy(name+i,memory(c,(uint64_t)address+i,1),1);
        if(!name[i])return 1;
    }
    return 0;
}
static uint32_t module_named(const char *name) {
    if(!strcasecmp(name,"TrueCrime.exe"))return 0x400000;
    size_t length=strlen(name);
    for(unsigned i=0;i<sizeof(modules)/sizeof(*modules);i++)
        if(!strcasecmp(name,modules[i]) ||
           (length==strlen(modules[i])-4&&!strncasecmp(name,modules[i],length)))
            return 0xe3000000+i;
    return 0;
}
static uint32_t export_named(uint32_t module,const char *name) {
    unsigned index=module-0xe3000000;
    if(index>=sizeof(modules)/sizeof(*modules))return 0;
    size_t length=strlen(modules[index]);
    for(size_t i=0;i<sizeof(exports)/sizeof(*exports);i++) {
        const char *separator=strchr(exports[i].name,'!');
        if(separator && (size_t)(separator-exports[i].name)==length &&
           !strncasecmp(exports[i].name,modules[index],length) &&
           !strcmp(separator+1,name))return exports[i].address;
    }
    return 0;
}
void tc_debug_output(_cpu *cpu) {
    char text[32768];
    if(!argument(cpu)){cpu->_eax=0;return;}
    if(!guest_string((tc_cpu *)cpu,argument(cpu),text,sizeof(text))){tc_write_fs(cpu,0x34,87);cpu->_eax=0;return;}
    fputs(text,stderr);cpu->_eax=0;
}
void tc_module_handle(_cpu *cpu) {
    uint32_t address=argument(cpu);
    if(!address) {cpu->_eax=0x400000;return;}
    char name[261];
    cpu->_eax=guest_string((tc_cpu *)cpu,address,name,sizeof(name))?module_named(name):0;
    if(!cpu->_eax)tc_write_fs(cpu,0x34,126);
}
void tc_load_library(_cpu *cpu) {
    /* Native modules are statically linked. Arbitrary guest DLL loading is unsupported. */
    if(!argument(cpu)) {cpu->_eax=0;tc_write_fs(cpu,0x34,87);return;}
    tc_module_handle(cpu);
}
void tc_get_proc_address(_cpu *cpu) {
    uint32_t module=argument(cpu),address;
    memcpy(&address,memory((tc_cpu *)cpu,(uint64_t)cpu->_esp+8,4),4);
    cpu->_eax=0;
    if(module!=0x400000 && module-0xe3000000>=sizeof(modules)/sizeof(*modules)) {
        tc_write_fs(cpu,0x34,6);return;
    }
    /* The registered native exports have names only, no ordinal exports. */
    char name[261];
    if(address>UINT16_MAX && guest_string((tc_cpu *)cpu,address,name,sizeof(name)))
        cpu->_eax=export_named(module,name);
    if(!cpu->_eax)tc_write_fs(cpu,0x34,127);
}
static uint64_t filetime(const struct timespec *time) {
    const int64_t epoch=INT64_C(11644473600);
    if(time->tv_sec < -epoch || time->tv_nsec<0 || time->tv_nsec>=1000000000)abort();
    __uint128_t ticks=((__int128)time->tv_sec+epoch)*10000000+time->tv_nsec/100;
    if(ticks>UINT64_MAX)abort();return (uint64_t)ticks;
}
void tc_system_filetime(_cpu *cpu) {
    struct timespec time;if(clock_gettime(CLOCK_REALTIME,&time))abort();
    uint64_t value=filetime(&time);
    memcpy(memory((tc_cpu *)cpu,argument(cpu),8),&value,8);
}
static void system_information(uint32_t output[9]) {
    long page=sysconf(_SC_PAGESIZE);
    if(page<4096||page>65536||(page&(page-1)))abort();
    /* This describes a single-processor translated 32-bit ABI configuration, not
       the ARM64 host instruction set. Commitment uses host-page granularity. */
    const uint32_t values[]={0,(uint32_t)page,0x10000,0x7fffffff,1,1,586,65536,6};
    memcpy(output,values,sizeof(values));
}
void tc_system_info(_cpu *cpu) {
    uint32_t output[9];system_information(output);
    memcpy(memory((tc_cpu *)cpu,argument(cpu),sizeof(output)),output,sizeof(output));
}
static void system_time_fields(const struct tm *date,long nanoseconds,uint16_t output[8]) {
    if(date->tm_year < -299 || date->tm_year > 28927 || nanoseconds<0 || nanoseconds>=1000000000)abort();
    const uint16_t fields[]={(uint16_t)(date->tm_year+1900),(uint16_t)(date->tm_mon+1),
        (uint16_t)date->tm_wday,(uint16_t)date->tm_mday,(uint16_t)date->tm_hour,
        (uint16_t)date->tm_min,(uint16_t)date->tm_sec,(uint16_t)(nanoseconds/1000000)};
    memcpy(output,fields,sizeof(fields));
}
void tc_local_time(_cpu *cpu) {
    struct timespec now;struct tm local;
    if(clock_gettime(CLOCK_REALTIME,&now)||!localtime_r(&now.tv_sec,&local))abort();
    uint16_t output[8];system_time_fields(&local,now.tv_nsec,output);
    memcpy(memory((tc_cpu *)cpu,argument(cpu),sizeof(output)),output,sizeof(output));
}
void tc_priority_class(_cpu *cpu) {
    if(argument_at(cpu,0)!=UINT32_MAX){process_error(cpu,6);return;}
    uint32_t priority=argument_at(cpu,1);int adjustment;
    switch(priority) {
        case 0x20:adjustment=0;break;
        case 0x40:adjustment=19;break;
        case 0x4000:adjustment=5;break;
        case 0x8000:adjustment=-5;break;
        case 0x80:adjustment=-10;break;
        case 0x100:process_error(cpu,50);return; /* No native real-time scheduling. */
        default:process_error(cpu,87);return;
    }
    struct tc_process *p=((tc_cpu *)cpu)->process;if(!p)abort();
    int value=p->priority_base+adjustment;if(value>19)value=19;if(value< -20)value=-20;
    if(setpriority(PRIO_PROCESS,0,value)){process_error(cpu,errno==EPERM||errno==EACCES?5:50);return;}
    cpu->_eax=1;
}
void tc_set_exception_filter(_cpu *cpu) {
    struct tc_process *p=((tc_cpu *)cpu)->process;if(!p)abort();
    /* Registration is process-wide. Host fault conversion and SEH unwinding
       remain unsupported; do not claim that installing a filter implements them. */
    cpu->_eax=atomic_exchange(&p->unhandled_filter,argument(cpu));
}
void tc_exit_process(_cpu *cpu) {
    /* Guest CRT cleanup runs before this API. The process owns all game threads. */
    _Exit((int)(argument(cpu)&255));
}
#ifdef TC_PROCESS_SELF_CHECK
#include <assert.h>
int main(void) {
    const UniChar sample[]={0x20ac,0x2603,0};uint32_t used=0;
    CFStringRef sample_text=CFStringCreateWithCharacters(NULL,sample,3);
    CFDataRef encoded=encode_single_byte(sample_text,codepage(0),'!',&used);
    assert(encoded&&used==1&&CFDataGetLength(encoded)==3);
    assert(!memcmp(CFDataGetBytePtr(encoded),"\x80!\0",3));CFRelease(encoded);
    encoded=encode_single_byte(sample_text,codepage(1252),0,&used);
    assert(encoded&&used==1&&!memcmp(CFDataGetBytePtr(encoded),"\x80\0\0",3));
    CFRelease(encoded);CFRelease(sample_text);
    assert(codepage(1)==codepage(437)&&codepage(932)==kCFStringEncodingInvalidId);
    unsigned char guest[2048]={0};tc_cpu cpu={0};
    cpu.scalar._pointer_offset=(uintptr_t)guest;cpu.memory_size=sizeof(guest);
    cpu.scalar._esp=32;cpu.fs_base=256;cpu.fs_size=128;
    struct tc_process filters={0};atomic_init(&filters.unhandled_filter,0);cpu.process=&filters;
    uint32_t priority_args[]={0xe7000001,0x20};memcpy(guest+36,priority_args,sizeof(priority_args));
    tc_priority_class(&cpu.scalar);assert(!cpu.scalar._eax&&tc_read_fs(&cpu.scalar,0x34)==6);
    uint32_t filter=0x6712ba;memcpy(guest+36,&filter,4);tc_set_exception_filter(&cpu.scalar);
    assert(cpu.scalar._eax==0&&atomic_load(&filters.unhandled_filter)==filter);
    filter=0;memcpy(guest+36,&filter,4);tc_set_exception_filter(&cpu.scalar);
    assert(cpu.scalar._eax==0x6712ba&&!atomic_load(&filters.unhandled_filter));cpu.process=NULL;
    tc_debug_output(&cpu.scalar);assert(cpu.scalar._eax==0);
    uint32_t args[]={1252,0,512,UINT32_MAX,1024,0};
    memcpy(guest+36,args,sizeof(args));memcpy(guest+512,"A\x80",3);
    tc_multibyte_to_wide(&cpu.scalar);assert(cpu.scalar._eax==3);
    args[5]=2;memcpy(guest+36,args,sizeof(args));
    tc_multibyte_to_wide(&cpu.scalar);
    assert(!cpu.scalar._eax&&tc_read_fs(&cpu.scalar,0x34)==122&&!guest[1024]);
    args[5]=3;memcpy(guest+36,args,sizeof(args));tc_multibyte_to_wide(&cpu.scalar);
    const uint16_t converted[]={'A',0x20ac,0};
    assert(cpu.scalar._eax==3&&!memcmp(guest+1024,converted,sizeof(converted)));
    args[0]=512;memcpy(guest+36,args,4);
    uint32_t version_size=156;memcpy(guest+512,&version_size,4);guest[668]=0x5a;
    tc_version_info(&cpu.scalar);
    assert(cpu.scalar._eax==1&&guest[516]==5&&guest[520]==1&&guest[528]==2);
    assert(guest[666]==1&&guest[668]==0x5a);
    version_size=147;memcpy(guest+512,&version_size,4);tc_version_info(&cpu.scalar);
    assert(!cpu.scalar._eax&&tc_read_fs(&cpu.scalar,0x34)==87&&guest[512]==147);
    const uint16_t uppercase[]={'A',0xc9,0};
    const uint16_t lowercase[]={'a',0xe9,0};
    memcpy(guest+512,uppercase,sizeof(uppercase));
    uint32_t mapping[]={0x409,0x100,512,UINT32_MAX,1024,0};
    memcpy(guest+36,mapping,sizeof(mapping));tc_map_string_w(&cpu.scalar);
    assert(cpu.scalar._eax==3);
    mapping[5]=2;memcpy(guest+36,mapping,sizeof(mapping));guest[1024]=0x5a;
    tc_map_string_w(&cpu.scalar);assert(!cpu.scalar._eax&&guest[1024]==0x5a&&tc_read_fs(&cpu.scalar,0x34)==122);
    mapping[4]=512;mapping[5]=3;memcpy(guest+36,mapping,sizeof(mapping));
    tc_map_string_w(&cpu.scalar);assert(cpu.scalar._eax==3&&!memcmp(guest+512,lowercase,sizeof(lowercase)));
    memcpy(guest+512,"a\xe9",3);mapping[1]=0x200;mapping[3]=UINT32_MAX-1;
    memcpy(guest+36,mapping,sizeof(mapping));tc_map_string_a(&cpu.scalar);
    assert(cpu.scalar._eax==3&&!memcmp(guest+512,"A\xc9",3));
    mapping[1]=0x400;memcpy(guest+36,mapping,sizeof(mapping));tc_map_string_a(&cpu.scalar);
    assert(!cpu.scalar._eax&&tc_read_fs(&cpu.scalar,0x34)==1004);
    const uint16_t classification[]={'A','g','7',' ',9,10,'+','$',0xe9,0};
    memcpy(guest+512,classification,sizeof(classification));
    uint32_t typing[]={1,512,UINT32_MAX-1,1025};memcpy(guest+36,typing,sizeof(typing));
    tc_string_type_w(&cpu.scalar);assert(cpu.scalar._eax==1);
    uint16_t types[10];memcpy(types,guest+1025,sizeof(types));
    assert((types[0]&0x181)==0x181&&(types[1]&0x182)==0x102);
    assert((types[2]&0x84)==0x84&&(types[3]&0x48)==0x48);
    assert((types[4]&0x68)==0x68&&(types[5]&0x68)==0x28);
    assert((types[6]&16)&&(types[7]&16)&&(types[8]&0x102)==0x102&&(types[9]&32));
    memcpy(guest+512,"A\xe9",3);
    uint32_t typing_a[]={0x409,1,512,UINT32_MAX,1025};memcpy(guest+36,typing_a,sizeof(typing_a));
    tc_string_type_a(&cpu.scalar);assert(cpu.scalar._eax==1);
    memcpy(types,guest+1025,6);assert((types[0]&1)&&(types[1]&2)&&(types[2]&32));
    typing_a[1]=2;memcpy(guest+36,typing_a,sizeof(typing_a));guest[1025]=0x5a;
    tc_string_type_a(&cpu.scalar);assert(!cpu.scalar._eax&&guest[1025]==0x5a&&tc_read_fs(&cpu.scalar,0x34)==50);
    typing_a[1]=1;typing_a[4]=512;memcpy(guest+36,typing_a,sizeof(typing_a));
    tc_string_type_a(&cpu.scalar);assert(!cpu.scalar._eax&&tc_read_fs(&cpu.scalar,0x34)==87);
    char *environment[]={"A=one","B=caf\xc3\xa9",NULL};
    CFDataRef block=environment_block(environment,0);
    static const unsigned char expected[]="A=one\0B=caf\x82\0";
    assert(block&&CFDataGetLength(block)==sizeof(expected));
    assert(!memcmp(CFDataGetBytePtr(block),expected,sizeof(expected)));CFRelease(block);
    block=environment_block(environment,1);
    static const uint16_t expected_w[]={'A','=','o','n','e',0,'B','=','c','a','f',0xe9,0,0};
    assert(block&&CFDataGetLength(block)==sizeof(expected_w));
    assert(!memcmp(CFDataGetBytePtr(block),expected_w,sizeof(expected_w)));CFRelease(block);
    char *empty[]={NULL};block=environment_block(empty,1);
    assert(block&&CFDataGetLength(block)==4&&!memcmp(CFDataGetBytePtr(block),"\0\0\0\0",4));
    CFRelease(block);
    uint32_t kernel=module_named("KERNEL32");
    assert(kernel==module_named("kernel32.dll"));
    assert(export_named(kernel,"GetTickCount")==0xf0000000);
    assert(!export_named(kernel,"gettickcount"));
    assert(!export_named(module_named("d3d8.dll"),"GetTickCount"));
    assert(!module_named("missing.dll"));
    struct timespec time={0,123456789};
    assert(filetime(&time)==UINT64_C(116444736001234567));
    const struct tm leap_day={.tm_year=124,.tm_mon=1,.tm_mday=29,.tm_wday=4,.tm_hour=23,.tm_min=59,.tm_sec=58};
    uint16_t date[8];system_time_fields(&leap_day,999999999,date);
    const uint16_t expected_date[]={2024,2,4,29,23,59,58,999};assert(!memcmp(date,expected_date,sizeof(date)));
    uint32_t information[9];system_information(information);
    assert(information[0]==0&&information[1]==(uint32_t)sysconf(_SC_PAGESIZE));
    assert(information[2]==0x10000&&information[3]==0x7fffffff&&information[4]==1&&information[5]==1);
    assert(information[6]==586&&information[7]==65536&&information[8]==6);
    uint32_t system_output=513;memcpy(guest+36,&system_output,4);guest[512]=guest[549]=0x5a;
    tc_system_info(&cpu.scalar);assert(!memcmp(guest+513,information,sizeof(information))&&guest[512]==0x5a&&guest[549]==0x5a);
    assert(export_named(module_named("winmm"),"timeGetTime")==0xf0000590);
    unsigned char output[68];startup_info(output);
    assert(output[0]==68&&output[44]==1&&output[48]==1);
    for(unsigned i=52;i<68;i++)assert(!output[i]);
    return 0;
}
#endif
