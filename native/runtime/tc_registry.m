#import <Foundation/Foundation.h>
#include "tc_process.h"
#include <pthread.h>
#include <string.h>

/* The game's private registry namespace lives in macOS preferences. No host
 * system settings are exposed. One mutex serializes handles and saved updates. */
static pthread_mutex_t registry_lock=PTHREAD_MUTEX_INITIALIZER;
static NSUserDefaults *preferences;
static NSDictionary *keys;
static NSMutableDictionary<NSNumber *,NSArray *> *handles;
static uint32_t next_handle=1;
static BOOL invalid_store;

static void *memory(_cpu *cpu,uint64_t address,size_t size) {
    tc_cpu *c=(tc_cpu *)cpu;
    if(!address||address>UINT32_MAX||size>c->memory_size||address>c->memory_size-size||
       cpu->_pointer_offset>UINTPTR_MAX-address-size)abort();
    return (void *)(uintptr_t)(cpu->_pointer_offset+address);
}
static uint32_t argument(_cpu *cpu,unsigned n) {
    uint32_t value;memcpy(&value,memory(cpu,(uint64_t)cpu->_esp+4+n*4,4),4);return value;
}
static void put(_cpu *cpu,uint32_t address,uint32_t value) {memcpy(memory(cpu,address,4),&value,4);}
static NSString *name(_cpu *cpu,uint32_t address) {
    if(!address)return @"";
    for(unsigned n=0;n<32768;n++)if(!*(const char *)memory(cpu,(uint64_t)address+n,1))
        return [[[NSString alloc]initWithBytes:memory(cpu,address,n) length:n
                    encoding:NSWindowsCP1252StringEncoding]lowercaseString];
    return nil;
}
static void enter(void) {
    pthread_mutex_lock(&registry_lock);
    if(handles)return;
    handles=[NSMutableDictionary new];
    preferences=[[NSUserDefaults alloc]initWithSuiteName:@"local.truecrime.native.registry"];
    id saved=[preferences objectForKey:@"keys"];
    invalid_store=saved&&![saved isKindOfClass:NSDictionary.class];
    keys=invalid_store?@{}:(saved?:@{});
}
static NSArray *key_handle(uint32_t handle) {
    if(handle>=0x80000000u&&handle<=0x80000003u)
        return @[@[@"hkcr",@"hkcu",@"hklm",@"hku"][handle-0x80000000u],@0xf003f];
    if(handle==0x80000005u)return @[@"hkcc",@0xf003f];
    return handles[@(handle)];
}
static NSString *key_path(NSString *parent,NSString *child) {
    if(!child)return nil;
    NSMutableArray *parts=[NSMutableArray arrayWithObject:parent];
    for(NSString *part in [child componentsSeparatedByString:@"\\"])
        if(part.length)[parts addObject:part];
    NSString *path=[parts componentsJoinedByString:@"\\"];
    return path.length<=32767?path:nil;
}
static BOOL exists(NSString *path) {return [path rangeOfString:@"\\"].location==NSNotFound||keys[path]!=nil;}
static uint32_t save(NSDictionary *updated) {
    [preferences setObject:updated forKey:@"keys"];
    if(![preferences synchronize]){[preferences setObject:keys forKey:@"keys"];return 29;}
    keys=updated;return 0;
}
static uint32_t open_key(_cpu *cpu,BOOL create,BOOL legacy) {
    uint32_t out=argument(cpu,create?7:legacy?2:4);
    if(!out)return 87;put(cpu,out,0);
    if(!legacy&&argument(cpu,2))return 87;
    uint32_t access=legacy?0xf003fu:argument(cpu,create?5:3);
    if((access&~0xf033fu)||(access&0x300u)==0x300u)return 87;
    if(create) {
        if(argument(cpu,4))return 50; /* Volatile/link/backup keys are unsupported. */
        if(argument(cpu,3)) {
            NSString *class_name=name(cpu,argument(cpu,3));if(!class_name)return 87;
            if(class_name.length)return 50;
        }
        uint32_t security=argument(cpu,6);
        if(security) {
            uint32_t info[3];memcpy(info,memory(cpu,security,12),12);
            if(info[0]!=12)return 87;if(info[1]||info[2])return 50;
        }
    }
    NSArray *parent=key_handle(argument(cpu,0));if(!parent)return 6;
    NSString *child=name(cpu,argument(cpu,1));
    NSString *path=key_path(parent[0],child);if(!path)return 87;
    if(!child.length&&!handles[@(argument(cpu,0))]) {
        put(cpu,out,argument(cpu,0));
        if(create&&argument(cpu,8))put(cpu,argument(cpu,8),2);
        return 0;
    }
    BOOL present=exists(path);if(!present&&!create)return 2;
    if(next_handle>0xffffffu)return 8;
    if(!present) {
        NSMutableDictionary *updated=[keys mutableCopy];NSString *prefix=@"";
        for(NSString *part in [path componentsSeparatedByString:@"\\"]) {
            prefix=prefix.length?[prefix stringByAppendingFormat:@"\\%@",part]:part;
            if(!updated[prefix])updated[prefix]=@{};
        }
        uint32_t error=save(updated);if(error)return error;
    }
    uint32_t handle=0xe9000000u|next_handle++;
    handles[@(handle)]=@[path,@(access&~0x300u)];put(cpu,out,handle);
    if(create&&argument(cpu,8))put(cpu,argument(cpu,8),present?2:1);
    return 0;
}
static void open_call(_cpu *cpu,BOOL create,BOOL legacy) {
    @autoreleasepool {enter();cpu->_eax=invalid_store?13:open_key(cpu,create,legacy);pthread_mutex_unlock(&registry_lock);}
}
void tc_registry_open(_cpu *cpu) {open_call(cpu,NO,NO);}
void tc_registry_open_legacy(_cpu *cpu) {open_call(cpu,NO,YES);}
void tc_registry_create(_cpu *cpu) {open_call(cpu,YES,NO);}
void tc_registry_close(_cpu *cpu) {
    @autoreleasepool {
        enter();uint32_t handle=argument(cpu,0);cpu->_eax=key_handle(handle)?0:6;
        [handles removeObjectForKey:@(handle)];pthread_mutex_unlock(&registry_lock);
    }
}
static uint32_t query(_cpu *cpu) {
    if(argument(cpu,2)||(argument(cpu,4)&&!argument(cpu,5)))return 87;
    NSArray *key=key_handle(argument(cpu,0));if(!key)return 6;
    if(!([key[1]unsignedIntValue]&1))return 5;
    NSString *value_name=name(cpu,argument(cpu,1));if(!value_name)return 87;
    id values=keys[key[0]];if(values&&![values isKindOfClass:NSDictionary.class])return 13;
    id value=values[value_name];if(!value)return 2;
    if(![value isKindOfClass:NSDictionary.class]||![value[@"type"]isKindOfClass:NSNumber.class]||
       ![value[@"data"]isKindOfClass:NSData.class])return 13;
    NSData *data=value[@"data"];if(data.length>UINT32_MAX)return 13;
    uint32_t size_address=argument(cpu,5),capacity=0;
    if(size_address){memcpy(&capacity,memory(cpu,size_address,4),4);put(cpu,size_address,(uint32_t)data.length);}
    if(argument(cpu,3))put(cpu,argument(cpu,3),[value[@"type"]unsignedIntValue]);
    if(argument(cpu,4)) {
        if(capacity<data.length)return 234;
        if(data.length)memcpy(memory(cpu,argument(cpu,4),data.length),data.bytes,data.length);
    }
    return 0;
}
void tc_registry_query(_cpu *cpu) {
    @autoreleasepool {enter();cpu->_eax=invalid_store?13:query(cpu);pthread_mutex_unlock(&registry_lock);}
}
static uint32_t set_value(_cpu *cpu) {
    if(argument(cpu,2))return 87;
    NSArray *key=key_handle(argument(cpu,0));if(!key)return 6;
    if(!([key[1]unsignedIntValue]&2))return 5;
    NSString *value_name=name(cpu,argument(cpu,1));if(!value_name)return 87;
    uint32_t type=argument(cpu,3),address=argument(cpu,4),size=argument(cpu,5);
    if(size>16*1024*1024)return 8;
    if((size&&!address)||type>11||((type==4||type==5)&&size!=4)||(type==11&&size!=8))return 87;
    id existing=keys[key[0]];if(existing&&![existing isKindOfClass:NSDictionary.class])return 13;
    NSMutableDictionary *values=existing?[existing mutableCopy]:[NSMutableDictionary new];
    NSData *data=size?[NSData dataWithBytes:memory(cpu,address,size) length:size]:[NSData data];
    values[value_name]=@{@"type":@(type),@"data":data};
    NSMutableDictionary *updated=[keys mutableCopy];updated[key[0]]=values;return save(updated);
}
void tc_registry_set(_cpu *cpu) {
    @autoreleasepool {enter();cpu->_eax=invalid_store?13:set_value(cpu);pthread_mutex_unlock(&registry_lock);}
}

#ifdef TC_REGISTRY_SELF_CHECK
#include <assert.h>
int main(void) {
    @autoreleasepool {
        unsigned char bytes[256]={0};tc_cpu c={0};c.scalar._pointer_offset=(uintptr_t)bytes;
        c.memory_size=sizeof(bytes);c.scalar._esp=32;
        handles=[NSMutableDictionary new];
        uint32_t number=123;keys=@{@"hklm\\software\\game":@{@"width":@{@"type":@4,@"data":[NSData dataWithBytes:&number length:4]}}};
        handles[@0xe9000001]=@[@"hklm\\software\\game",@1];
        memcpy(bytes+96,"WIDTH",6);uint32_t args[]={0xe9000001,96,0,112,128,116};memcpy(bytes+36,args,sizeof(args));
        put(&c.scalar,116,3);assert(query(&c.scalar)==234&&bytes[128]==0);
        uint32_t required;memcpy(&required,bytes+116,4);assert(required==4);
        put(&c.scalar,116,4);assert(!query(&c.scalar));memcpy(&required,bytes+128,4);assert(required==123);
        assert(set_value(&c.scalar)==5);
        assert([key_path(@"hklm",@"software\\\\game")isEqualToString:@"hklm\\software\\game"]);
    }return 0;
}
#endif
