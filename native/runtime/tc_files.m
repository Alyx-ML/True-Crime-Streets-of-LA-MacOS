#include "tc_modern.h"
#import <Foundation/Foundation.h>
#include "tc_files.h"
#include "tc_threads.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

struct file { uint32_t handle,share,inherit,access;int fd;dev_t device;ino_t inode;struct file *next; };
struct mmio { uint32_t handle,address,length,position;struct mmio *next; };
/* The original save wrappers reject handles <= -1 using signed comparisons.
 * Keep opaque file handles positive and separate from other native handles. */
enum { FILE_HANDLE_FIRST=0x22000000u, FILE_HANDLE_LIMIT=0x2fffffffu };
_Static_assert(FILE_HANDLE_FIRST>0 && FILE_HANDLE_LIMIT<INT32_MAX,"Save handles must remain positive");
struct files {
    /* ponytail: serialized file operations; per-handle locks if parallel asset
     * reads become a bottleneck. This also prevents close/read descriptor reuse. */
    pthread_mutex_t mutex;uint32_t next;struct file *list;char *executable;
    uint32_t standard[3]; /* GUI launch has no inherited console handles. */
    struct mmio *media;
};
static void *mem(tc_cpu *c,uint64_t address,size_t size) {
    if(!address||address>UINT32_MAX||size>c->memory_size||address>c->memory_size-size||
        c->scalar._pointer_offset>UINTPTR_MAX-address-size)abort();
    return (void *)(uintptr_t)(c->scalar._pointer_offset+address);
}
static uint32_t arg(_cpu *cpu,unsigned n) {
    uint32_t v;memcpy(&v,mem((tc_cpu *)cpu,(uint64_t)cpu->_esp+4+n*4,4),4);return v;
}
static void put(_cpu *cpu,uint32_t address,uint32_t value){memcpy(mem((tc_cpu *)cpu,address,4),&value,4);}
static uint32_t error_code(int code) {
    switch(code) {
    case ENOENT:return 2;case ENOTDIR:return 3;case EACCES:case EPERM:case EISDIR:return 5;
    case EBADF:return 6;case ENOMEM:return 8;case EMFILE:case ENFILE:return 4;
    case EINVAL:return 87;case EFAULT:return 998;case ENAMETOOLONG:return 206;
    case ESPIPE:return 25;case EOVERFLOW:return 534;case EEXIST:return 80;
    case ENOSPC:case EDQUOT:return 112;case EROFS:return 19;case EFBIG:return 223;default:return 31;
    }
}
static void fail(_cpu *cpu,uint32_t result,uint32_t error){cpu->_eax=result;tc_write_fs(cpu,0x34,error);}
static NSString *guest_text(_cpu *cpu,uint32_t address,BOOL wide) {
    if(!address)return nil;
    unsigned char bytes[65536];size_t n,width=wide?2:1;
    for(n=0;n<32768;n++) {
        uint16_t unit=0;
        memcpy(&unit,mem((tc_cpu *)cpu,(uint64_t)address+n*width,width),width);
        if(!unit)break;
        memcpy(bytes+n*width,&unit,width);
    }
    if(n==32768)return nil;
    NSString *name=[[NSString alloc]initWithBytes:bytes length:n*width
        encoding:wide?NSUTF16LittleEndianStringEncoding:NSWindowsCP1252StringEncoding];
    return name;
}
static NSString *encoded_path(_cpu *cpu,uint32_t address,BOOL wide) {
    NSString *name=guest_text(cpu,address,wide);
    if(!name.length)return nil;
    name=[name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    /* Z: is the native filesystem root. Z:relative follows the process current
       directory; other drives and UNC/device paths are not mounted. */
    if(name.length>=2&&[[name substringToIndex:2]caseInsensitiveCompare:@"Z:"]==NSOrderedSame) {
        name=[name substringFromIndex:2];if(!name.length)name=@".";
    }
    if([name containsString:@":"]||[name hasPrefix:@"//"])return nil;
    return name;
}
static NSString *path(_cpu *cpu,uint32_t address) {return encoded_path(cpu,address,NO);}
char *tc_file_native_path(_cpu *cpu,uint32_t address) {
    @autoreleasepool {NSString *name=path(cpu,address);return name?strdup(name.fileSystemRepresentation):NULL;}
}
static NSData *guest_path(const char *native) {
    NSString *name=[[NSFileManager defaultManager]stringWithFileSystemRepresentation:native length:strlen(native)];
    if(!name||![name hasPrefix:@"/"])return nil;
    name=[@"Z:" stringByAppendingString:[name stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
    return [name dataUsingEncoding:NSWindowsCP1252StringEncoding allowLossyConversion:NO];
}
void *tc_files_create(const char *executable) {
    struct files *p=calloc(1,sizeof(*p));if(!p)return NULL;
    p->executable=realpath(executable,NULL);if(!p->executable){free(p);return NULL;}
    if(pthread_mutex_init(&p->mutex,NULL)){free(p->executable);free(p);return NULL;}
    p->next=FILE_HANDLE_FIRST;return p;
}
void tc_files_destroy(void *state) {
    struct files *p=state;if(!p)return;
    while(p->list){struct file *next=p->list->next;close(p->list->fd);free(p->list);p->list=next;}
    while(p->media){struct mmio *next=p->media->next;free(p->media);p->media=next;}
    pthread_mutex_destroy(&p->mutex);free(p->executable);free(p);
}
static struct files *lock(_cpu *cpu) {
    struct files *p=((tc_cpu *)cpu)->files;
    if(!p||pthread_mutex_lock(&p->mutex))abort();return p;
}
static void unlock(struct files *p){if(pthread_mutex_unlock(&p->mutex))abort();}
static struct mmio *media_find(struct files *p,uint32_t handle) {
    struct mmio *m=p->media;while(m&&m->handle!=handle)m=m->next;return m;
}
void tc_mmio_open(_cpu *cpu) {
    uint32_t info=arg(cpu,1),v[18];cpu->_eax=0;
    if(!info)return;
    memcpy(v,mem((tc_cpu *)cpu,info,sizeof(v)),sizeof(v));
    put(cpu,info+12,272); /* MMIOERR_INVALIDFILE */
    /* The game's WAV loader supplies a read-only FOURCC_MEM buffer. Filename,
       custom I/O callbacks, allocation and write modes require separate support. */
    if(arg(cpu,2)||v[1]!=0x204d454d||v[2]||(int32_t)v[5]<=0||!v[6]||
       (uint64_t)v[6]+v[5]>((tc_cpu *)cpu)->memory_size)return;
    struct mmio *m=calloc(1,sizeof(*m));if(!m){put(cpu,info+12,263);return;}
    m->address=v[6];m->length=v[5];
    struct files *p=lock(cpu);
    if(p->next==FILE_HANDLE_LIMIT){unlock(p);free(m);put(cpu,info+12,260);return;}
    m->handle=p->next++;m->next=p->media;p->media=m;unlock(p);
    put(cpu,info+12,0);cpu->_eax=m->handle;
}
void tc_mmio_close(_cpu *cpu) {
    struct files *p=lock(cpu);struct mmio **link=&p->media;
    while(*link&&(*link)->handle!=arg(cpu,0))link=&(*link)->next;
    cpu->_eax=arg(cpu,1)?11:!*link?5:0;
    if(!cpu->_eax){struct mmio *m=*link;*link=m->next;free(m);}unlock(p);
}
void tc_mmio_fourcc(_cpu *cpu) {
    uint32_t address=arg(cpu,0),flags=arg(cpu,1),value=0;BOOL ended=NO;
    if(!address||(flags&~0x10u)){cpu->_eax=0;return;}
    for(unsigned i=0;i<4;i++) {
        unsigned char ch=' ';
        if(!ended){ch=*(unsigned char *)mem((tc_cpu *)cpu,(uint64_t)address+i,1);if(!ch){ended=YES;ch=' ';}}
        if((flags&0x10)&&ch>='a'&&ch<='z')ch-=32;
        value|=(uint32_t)ch<<(8*i);
    }cpu->_eax=value;
}
static uint32_t riff_word(const unsigned char *data) {uint32_t n;memcpy(&n,data,4);return n;}
static uint32_t riff_descend(const unsigned char *data,uint32_t length,uint32_t *position,
                             uint32_t chunk[5],const uint32_t *parent,uint32_t flags) {
    if(flags&&flags!=0x10&&flags!=0x20&&flags!=0x40)return 11;
    uint64_t limit=length,pos=*position;
    if(parent) {
        uint64_t end=(uint64_t)parent[3]+parent[1];
        if((parent[0]!=0x46464952&&parent[0]!=0x5453494c)||parent[1]<4||end>length)return 272;
        limit=end;if(pos<(uint64_t)parent[3]+4)pos=(uint64_t)parent[3]+4;
    }
    while(pos+8<=limit) {
        uint32_t id=riff_word(data+pos),size=riff_word(data+pos+4),type=0;
        uint64_t start=pos+8,end=start+size,next=end+(size&1);
        BOOL container=id==0x46464952||id==0x5453494c;
        if(end>limit||next>limit||(container&&size<4))return 272;
        if(container)type=riff_word(data+start);
        BOOL match=!flags||(flags==0x10&&id==chunk[0])||
            (flags==0x20&&id==0x46464952&&type==chunk[2])||
            (flags==0x40&&id==0x5453494c&&type==chunk[2]);
        if(match){chunk[0]=id;chunk[1]=size;chunk[2]=type;chunk[3]=(uint32_t)start;chunk[4]=0;
            *position=(uint32_t)start+(container?4:0);return 0;}
        pos=next;
    }return 265; /* MMIOERR_CHUNKNOTFOUND */
}
void tc_mmio_descend(_cpu *cpu) {
    uint32_t out=arg(cpu,1),parentAddress=arg(cpu,2),chunk[5],parent[5];
    if(!out){cpu->_eax=11;return;}
    memcpy(chunk,mem((tc_cpu *)cpu,out,20),20);
    if(parentAddress)memcpy(parent,mem((tc_cpu *)cpu,parentAddress,20),20);
    struct files *p=lock(cpu);struct mmio *m=media_find(p,arg(cpu,0));cpu->_eax=5;
    if(m){cpu->_eax=riff_descend(mem((tc_cpu *)cpu,m->address,m->length),m->length,&m->position,
        chunk,parentAddress?parent:NULL,arg(cpu,3));if(!cpu->_eax)memcpy(mem((tc_cpu *)cpu,out,20),chunk,20);}
    unlock(p);
}
void tc_mmio_read(_cpu *cpu) {
    int32_t requested=(int32_t)arg(cpu,2);uint32_t out=arg(cpu,1);cpu->_eax=UINT32_MAX;
    if(requested<0||(!out&&requested))return;
    struct files *p=lock(cpu);struct mmio *m=media_find(p,arg(cpu,0));
    if(m){uint32_t count=MIN((uint32_t)requested,m->length-m->position);
        if(count)memmove(mem((tc_cpu *)cpu,out,count),mem((tc_cpu *)cpu,(uint64_t)m->address+m->position,count),count);
        m->position+=count;cpu->_eax=count;}unlock(p);
}
void tc_mmio_ascend(_cpu *cpu) {
    uint32_t address=arg(cpu,1),chunk[5];if(!address||arg(cpu,2)){cpu->_eax=11;return;}
    memcpy(chunk,mem((tc_cpu *)cpu,address,20),20);
    struct files *p=lock(cpu);struct mmio *m=media_find(p,arg(cpu,0));cpu->_eax=5;
    if(m){uint64_t end=(uint64_t)chunk[3]+chunk[1]+(chunk[1]&1);
        cpu->_eax=chunk[4]||end>m->length?272:0;if(!cpu->_eax)m->position=(uint32_t)end;}unlock(p);
}
static struct file *find(struct files *p,uint32_t handle){struct file *f=p->list;while(f&&f->handle!=handle)f=f->next;return f;}
static unsigned standard_index(uint32_t selector) {return (uint32_t)-10-selector;}
void tc_standard_get(_cpu *cpu) {
    unsigned index=standard_index(arg(cpu,0));
    if(index>=3){fail(cpu,UINT32_MAX,87);return;}
    struct files *p=lock(cpu);cpu->_eax=p->standard[index];unlock(p);
}
void tc_standard_set(_cpu *cpu) {
    unsigned index=standard_index(arg(cpu,0));
    if(index>=3){fail(cpu,0,87);return;}
    /* Win32 stores the supplied value without opening, validating or closing
       it. ReadFile/WriteFile perform handle validation when it is used. */
    struct files *p=lock(cpu);p->standard[index]=arg(cpu,1);unlock(p);cpu->_eax=1;
}
void tc_handle_count(_cpu *cpu) {
    /* Obsolete DOS handle-table sizing has no effect for the NT guest ABI. */
    cpu->_eax=arg(cpu,0);
}
void tc_module_filename(_cpu *cpu) {
    @autoreleasepool {
        uint32_t module=arg(cpu,0),destination=arg(cpu,1),capacity=arg(cpu,2);
        if(module&&module!=0x400000){fail(cpu,0,126);return;}
        if(!capacity){fail(cpu,0,122);return;}
        if(!destination){fail(cpu,0,87);return;}
        struct files *p=((tc_cpu *)cpu)->files;if(!p)abort();
        NSData *name=guest_path(p->executable);if(!name){fail(cpu,0,1113);return;}
        size_t length=MIN(name.length,(size_t)capacity-1);
        unsigned char *output=mem((tc_cpu *)cpu,destination,length+1);
        memcpy(output,name.bytes,length);output[length]=0;
        if(name.length>=capacity)fail(cpu,capacity,122);else cpu->_eax=(uint32_t)length;
    }
}
void tc_directory_get(_cpu *cpu) {
    @autoreleasepool {
        uint32_t capacity=arg(cpu,0),destination=arg(cpu,1);
        struct files *p=lock(cpu);char *current=getcwd(NULL,0);
        uint32_t error=current?0:error_code(errno);unlock(p);
        if(!current){fail(cpu,0,error);return;}
        NSData *name=guest_path(current);free(current);
        if(!name){fail(cpu,0,1113);return;}
        if(name.length>=capacity){cpu->_eax=(uint32_t)name.length+1;return;}
        if(!destination){fail(cpu,0,87);return;}
        unsigned char *output=mem((tc_cpu *)cpu,destination,name.length+1);
        memcpy(output,name.bytes,name.length);output[name.length]=0;cpu->_eax=(uint32_t)name.length;
    }
}
void tc_directory_set(_cpu *cpu) {
    @autoreleasepool {
        NSString *name=path(cpu,arg(cpu,0));if(!name){fail(cpu,0,123);return;}
        struct files *p=lock(cpu);int result=chdir(name.fileSystemRepresentation);
        uint32_t error=result?error_code(errno):0;unlock(p);
        if(result)fail(cpu,0,error);else cpu->_eax=1;
    }
}
static BOOL disk_space_bytes(const struct statvfs *info,uint64_t values[3]) {
    uint64_t unit=info->f_frsize?info->f_frsize:info->f_bsize;
    uint64_t blocks[]={info->f_bavail,info->f_blocks,info->f_bfree};
    if(!unit)return NO;
    for(unsigned i=0;i<3;i++) {
        if(blocks[i]>UINT64_MAX/unit)return NO;
        values[i]=blocks[i]*unit;
    }
    return YES;
}
void tc_disk_space(_cpu *cpu) {
    @autoreleasepool {
        NSString *name=arg(cpu,0)?path(cpu,arg(cpu,0)):@".";
        if(!name){fail(cpu,0,123);return;}
        int fd=open(name.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
        if(fd<0){fail(cpu,0,error_code(errno));return;}
        struct statvfs info;int result=fstatvfs(fd,&info),error=errno;close(fd);
        if(result){fail(cpu,0,error_code(error));return;}
        uint64_t values[3];
        if(!disk_space_bytes(&info,values)){fail(cpu,0,534);return;}
        /* POSIX exposes caller-available free blocks; per-user total quotas are
         * not exposed here, so total capacity is the mounted volume capacity. */
        for(unsigned i=0;i<3;i++)if(arg(cpu,i+1))memcpy(mem((tc_cpu *)cpu,arg(cpu,i+1),8),&values[i],8);
        cpu->_eax=1;
    }
}
void tc_directory_create(_cpu *cpu) {
    @autoreleasepool {
        if(arg(cpu,1)) {
            uint32_t security[3];memcpy(security,mem((tc_cpu *)cpu,arg(cpu,1),12),12);
            if(security[0]!=12||security[1]||security[2]>1){fail(cpu,0,50);return;}
        }
        NSString *name=path(cpu,arg(cpu,0));if(!name){fail(cpu,0,123);return;}
        struct files *p=lock(cpu);int result=mkdir(name.fileSystemRepresentation,0777);
        uint32_t error=result?(errno==EEXIST?183:errno==ENOENT?3:error_code(errno)):0;unlock(p);
        if(result)fail(cpu,0,error);else cpu->_eax=1;
    }
}
static int open_file(const char *name,int flags) {
    int fd;do{fd=open(name,flags,0666);}while(fd<0&&errno==EINTR);return fd;
}
static void file_open(_cpu *cpu,BOOL wide) {
    @autoreleasepool {
        uint32_t desired=arg(cpu,1),share=arg(cpu,2),flags=arg(cpu,5),disposition=arg(cpu,4),inherit=0;
        uint32_t access=((desired&0x80000000u)?1:0)|((desired&0x40000000u)?2:0);
        if(arg(cpu,3)) {
            uint32_t security[3];memcpy(security,mem((tc_cpu *)cpu,arg(cpu,3),12),12);
            if(security[0]!=12||security[1]||security[2]>1){fail(cpu,UINT32_MAX,50);return;}
            inherit=security[2];
        }
        if((desired&~0xc0000000u)||disposition<1||disposition>5||arg(cpu,6)||(share&~7u)||
           (flags&~0x98000080u)){fail(cpu,UINT32_MAX,50);return;}
        if((disposition==2||disposition==5)&&!(access&2)){fail(cpu,UINT32_MAX,5);return;}
        NSString *name=encoded_path(cpu,arg(cpu,0),wide);if(!name){fail(cpu,UINT32_MAX,123);return;}
        struct file *f=calloc(1,sizeof(*f));if(!f){fail(cpu,UINT32_MAX,8);return;}
        struct files *p=lock(cpu);
        if(p->next==FILE_HANDLE_LIMIT){unlock(p);free(f);fail(cpu,UINT32_MAX,4);return;}
        int mode=access==3?O_RDWR:access==2?O_WRONLY:O_RDONLY;
        mode|=O_CLOEXEC|O_NONBLOCK;if(flags&0x80000000u)mode|=O_SYNC;
        BOOL created=NO;int fd;
        if(disposition==1||disposition==2||disposition==4) {
            fd=open_file(name.fileSystemRepresentation,mode|O_CREAT|O_EXCL);
            if(fd>=0)created=YES;
            else if(errno==EEXIST&&disposition!=1)fd=open_file(name.fileSystemRepresentation,mode);
        } else fd=open_file(name.fileSystemRepresentation,mode);
        if(fd<0){uint32_t error=error_code(errno);unlock(p);free(f);fail(cpu,UINT32_MAX,error);return;}
        struct stat info;
        if(fstat(fd,&info)){uint32_t error=error_code(errno);close(fd);unlock(p);free(f);fail(cpu,UINT32_MAX,error);return;}
        if(!S_ISREG(info.st_mode)){close(fd);unlock(p);free(f);fail(cpu,UINT32_MAX,5);return;}
        for(struct file *other=p->list;other;other=other->next) {
            if(other->device==info.st_dev&&other->inode==info.st_ino&&
               ((other->access&~share)||(access&~other->share))) {
                close(fd);unlock(p);free(f);fail(cpu,UINT32_MAX,32);return;
            }
        }
        /* Do not pass O_TRUNC to open: sharing and allocation must succeed
         * before existing save data can be modified. */
        if((disposition==2||disposition==5)&&!created&&ftruncate(fd,0)) {
            uint32_t error=error_code(errno);close(fd);unlock(p);free(f);fail(cpu,UINT32_MAX,error);return;
        }
        f->handle=p->next++;f->fd=fd;f->share=share;f->access=access;f->inherit=inherit;
        f->device=info.st_dev;f->inode=info.st_ino;f->next=p->list;p->list=f;
        cpu->_eax=f->handle;unlock(p);
        if(disposition==2||disposition==4)tc_write_fs(cpu,0x34,created?0:183);
    }
}
void tc_file_open(_cpu *cpu) {file_open(cpu,NO);}
void tc_file_open_w(_cpu *cpu) {file_open(cpu,YES);}
static NSArray<NSString *> *profile_values(NSString *text,NSString *section,NSString *key) {
    NSMutableArray<NSString *> *values=[NSMutableArray new];NSString *current=nil;
    NSCharacterSet *spaces=NSCharacterSet.whitespaceCharacterSet;
    for(NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *item=[line stringByTrimmingCharactersInSet:spaces];
        if(!item.length||[item hasPrefix:@";"])continue;
        if([item hasPrefix:@"["]) {
            NSRange end=[item rangeOfString:@"]"];
            current=end.location!=NSNotFound?[[item substringWithRange:NSMakeRange(1,end.location-1)]stringByTrimmingCharactersInSet:spaces]:nil;
            if(!section&&current.length)[values addObject:current];continue;
        }
        if(!section||!current||[current caseInsensitiveCompare:section]!=NSOrderedSame)continue;
        NSRange equal=[item rangeOfString:@"="];if(equal.location==NSNotFound)continue;
        NSString *name=[[item substringToIndex:equal.location]stringByTrimmingCharactersInSet:spaces];
        if(!name.length)continue;
        if(!key){[values addObject:name];continue;}
        if([name caseInsensitiveCompare:key]!=NSOrderedSame)continue;
        NSString *value=[[item substringFromIndex:equal.location+1]stringByTrimmingCharactersInSet:spaces];
        if(value.length>=2&&(([value hasPrefix:@"\""]&&[value hasSuffix:@"\""])||
                            ([value hasPrefix:@"'"]&&[value hasSuffix:@"'"])))value=[value substringWithRange:NSMakeRange(1,value.length-2)];
        [values addObject:value];break;
    }
    return values;
}
static NSString *load_profile(NSString *name,NSStringEncoding *encoding,uint32_t *failure) {
    NSError *error=nil;
    NSData *data=[NSData dataWithContentsOfFile:name options:NSDataReadingMappedIfSafe error:&error];
    *encoding=NSWindowsCP1252StringEncoding;*failure=0;
    if(!data) {
        *failure=[error.domain isEqualToString:NSCocoaErrorDomain]&&error.code==NSFileReadNoSuchFileError?2:5;
        return nil;
    }
    if(data.length>16*1024*1024){*failure=8;return nil;}
    const unsigned char *bytes=data.bytes;NSUInteger offset=0;
    if(data.length>=2&&bytes[0]==0xff&&bytes[1]==0xfe){*encoding=NSUTF16LittleEndianStringEncoding;offset=2;}
    else if(data.length>=2&&bytes[0]==0xfe&&bytes[1]==0xff){*encoding=NSUTF16BigEndianStringEncoding;offset=2;}
    NSString *text=[[NSString alloc]initWithBytes:data.length?bytes+offset:(const unsigned char *)"" length:data.length-offset encoding:*encoding];
    if(!text)*failure=1113;return text;
}
static NSString *read_profile(_cpu *cpu,NSString *name) {
    /* Relative profiles use the game directory, without Windows INI redirection. */
    struct files *p=lock(cpu);NSStringEncoding encoding;uint32_t error;
    NSString *text=load_profile(name,&encoding,&error);unlock(p);
    if(error)tc_write_fs(cpu,0x34,error);return text ?: @"";
}
static NSString *edit_profile(NSString *text,NSString *section,NSString *key,NSString *value) {
    NSString *newline=[text containsString:@"\r\n"]?@"\r\n":@"\n";
    NSString *normalized=[[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray<NSString *> *lines=[[normalized componentsSeparatedByString:@"\n"]mutableCopy];
    NSCharacterSet *spaces=NSCharacterSet.whitespaceCharacterSet;
    NSUInteger start=NSNotFound,end=lines.count,entry=NSNotFound;
    for(NSUInteger i=0;i<lines.count;i++) {
        NSString *item=[lines[i]stringByTrimmingCharactersInSet:spaces];
        if([item hasPrefix:@"["]) {
            if(start!=NSNotFound){end=i;break;}
            NSRange close=[item rangeOfString:@"]"];
            if(close.location!=NSNotFound) {
                NSString *name=[[item substringWithRange:NSMakeRange(1,close.location-1)]stringByTrimmingCharactersInSet:spaces];
                if([name caseInsensitiveCompare:section]==NSOrderedSame)start=i;
            }
        } else if(start!=NSNotFound&&key&&![item hasPrefix:@";"]) {
            NSRange equal=[item rangeOfString:@"="];
            if(equal.location!=NSNotFound&&entry==NSNotFound&&
               [[[item substringToIndex:equal.location]stringByTrimmingCharactersInSet:spaces]caseInsensitiveCompare:key]==NSOrderedSame)entry=i;
        }
    }
    if(!key) {
        if(start!=NSNotFound)[lines removeObjectsInRange:NSMakeRange(start,end-start)];
    } else if(!value) {
        if(entry!=NSNotFound)[lines removeObjectAtIndex:entry];
    } else {
        NSString *replacement=[NSString stringWithFormat:@"%@=%@",key,value];
        if(entry!=NSNotFound)lines[entry]=replacement;
        else if(start!=NSNotFound)[lines insertObject:replacement atIndex:end];
        else {
            if(lines.count&&![lines.lastObject length])[lines removeLastObject];
            [lines addObject:[NSString stringWithFormat:@"[%@]",section]];[lines addObject:replacement];[lines addObject:@""];
        }
    }
    return [lines componentsJoinedByString:newline];
}
void tc_profile_write(_cpu *cpu) {
    @autoreleasepool {
        /* There is no profile cache to flush. */
        if(!arg(cpu,0)&&!arg(cpu,1)&&!arg(cpu,2)){cpu->_eax=1;return;}
        NSString *section=guest_text(cpu,arg(cpu,0),NO),*key=guest_text(cpu,arg(cpu,1),NO);
        NSString *value=guest_text(cpu,arg(cpu,2),NO),*name=path(cpu,arg(cpu,3));
        /* Persist the output resolution, never the virtual UI-scale one. */
        BOOL width=[key caseInsensitiveCompare:@"ScreenWidth"]==NSOrderedSame;
        if(value&&(width||[key caseInsensitiveCompare:@"ScreenHeight"]==NSOrderedSame))
            value=[NSString stringWithFormat:@"%u",tc_modern_real_screen((tc_cpu *)cpu,!width,(uint32_t)value.longLongValue)];
        NSCharacterSet *newlines=NSCharacterSet.newlineCharacterSet;
        if(!section.length||!name||(arg(cpu,1)&&!key.length)||(arg(cpu,2)&&!value)||
           [section containsString:@"]"]||[section rangeOfCharacterFromSet:newlines].location!=NSNotFound||
           (key&&([key containsString:@"="]||[key rangeOfCharacterFromSet:newlines].location!=NSNotFound))||
           (value&&[value rangeOfCharacterFromSet:newlines].location!=NSNotFound)){fail(cpu,0,87);return;}
        struct files *p=lock(cpu);struct stat info;
        int status=lstat(name.fileSystemRepresentation,&info);uint32_t failure=0;
        if(status&&errno!=ENOENT)failure=error_code(errno);
        else if(!status) {
            /* Atomic replacement requires a closed regular profile. Do not break
               symbolic/hard links or leave open guest handles on stale contents. */
            if(!S_ISREG(info.st_mode)||info.st_nlink>1)failure=50;
            else if(!(info.st_mode&0222))failure=5;
            else for(struct file *f=p->list;f;f=f->next)
                if(f->device==info.st_dev&&f->inode==info.st_ino){failure=32;break;}
        }
        if(failure){unlock(p);fail(cpu,0,failure);return;}
        NSStringEncoding encoding;NSString *text=load_profile(name,&encoding,&failure);
        if(!text&&failure!=2){unlock(p);fail(cpu,0,failure);return;}
        if(!text&&(!key||!value)){unlock(p);cpu->_eax=1;return;}
        NSString *updated=edit_profile(text ?: @"",section,key,value);
        NSData *body=[updated dataUsingEncoding:encoding allowLossyConversion:NO];
        if(!body){unlock(p);fail(cpu,0,1113);return;}
        NSMutableData *data=[NSMutableData new];
        if(encoding==NSUTF16LittleEndianStringEncoding){const unsigned char bom[]={0xff,0xfe};[data appendBytes:bom length:2];}
        else if(encoding==NSUTF16BigEndianStringEncoding){const unsigned char bom[]={0xfe,0xff};[data appendBytes:bom length:2];}
        [data appendData:body];NSError *error=nil;
        BOOL saved=[data writeToFile:name options:NSDataWritingAtomic error:&error];unlock(p);
        if(!saved) {
            NSError *underlying=error.userInfo[NSUnderlyingErrorKey];
            fail(cpu,0,[underlying.domain isEqualToString:NSPOSIXErrorDomain]?error_code((int)underlying.code):5);
        } else cpu->_eax=1;
    }
}
void tc_profile_string(_cpu *cpu) {
    @autoreleasepool {
        uint32_t output=arg(cpu,3),capacity=arg(cpu,4);cpu->_eax=0;
        if(!capacity)return;
        if(!output){fail(cpu,0,87);return;}
        NSString *section=guest_text(cpu,arg(cpu,0),NO),*key=guest_text(cpu,arg(cpu,1),NO);
        NSString *fallback=arg(cpu,2)?guest_text(cpu,arg(cpu,2),NO):@"",*name=path(cpu,arg(cpu,5));
        if(!name||!fallback||(arg(cpu,0)&&!section)||(arg(cpu,1)&&!key)){fail(cpu,0,87);return;}
        NSArray<NSString *> *values=profile_values(read_profile(cpu,name),section,key);
        BOOL enumeration=!section||!key;
        NSMutableData *result=[NSMutableData new];const unsigned char zero=0;
        if(!enumeration) {
            NSString *value=values.firstObject;
            if(!value) {
                value=fallback;
                while(value.length&&([value characterAtIndex:value.length-1]==' '||[value characterAtIndex:value.length-1]=='\t'))
                    value=[value substringToIndex:value.length-1];
            }
            [result appendData:[value dataUsingEncoding:NSWindowsCP1252StringEncoding allowLossyConversion:YES]];
        } else for(NSString *value in values) {
            [result appendData:[value dataUsingEncoding:NSWindowsCP1252StringEncoding allowLossyConversion:YES]];
            [result appendBytes:&zero length:1];
        }
        unsigned terminators=enumeration?2:1;
        unsigned char *destination=mem((tc_cpu *)cpu,output,capacity);
        if(capacity<terminators){memset(destination,0,capacity);return;}
        /* Enumeration data already contains each item's terminator. */
        size_t length=MIN(result.length,(size_t)capacity-terminators);
        BOOL truncated=enumeration&&result.length+1>capacity;
        if(enumeration&&!truncated)length=result.length;
        memcpy(destination,result.bytes,length);destination[length]=0;
        if(enumeration&&(truncated||!length))destination[length+1]=0;
        cpu->_eax=(uint32_t)length;
    }
}
void tc_profile_integer(_cpu *cpu) {
    @autoreleasepool {
        uint32_t fallback=arg(cpu,2);cpu->_eax=fallback;
        NSString *section=guest_text(cpu,arg(cpu,0),NO),*key=guest_text(cpu,arg(cpu,1),NO),*name=path(cpu,arg(cpu,3));
        if(!section||!key||!name){fail(cpu,fallback,87);return;}
        NSString *value=profile_values(read_profile(cpu,name),section,key).firstObject;
        if(!value.length)return;
        const char *number=value.UTF8String;while(*number==' '||*number=='\t')number++;
        const char *digits=(*number=='-'||*number=='+')?number+1:number;
        int base=digits[0]=='0'&&(digits[1]=='x'||digits[1]=='X')?16:10;
        cpu->_eax=(uint32_t)strtoll(number,NULL,base);
        /* UI scale: report a virtual 480-line resolution; the renderer outputs at the ini size. */
        BOOL width=[key caseInsensitiveCompare:@"ScreenWidth"]==NSOrderedSame;
        if(width||[key caseInsensitiveCompare:@"ScreenHeight"]==NSOrderedSame) {
            NSString *other=profile_values(read_profile(cpu,name),section,width?@"ScreenHeight":@"ScreenWidth").firstObject;
            uint32_t otherValue=(uint32_t)other.longLongValue;
            cpu->_eax=tc_modern_virtual_screen((tc_cpu *)cpu,!width,width?cpu->_eax:otherValue,width?otherValue:cpu->_eax);
        }
    }
}
static void file_io(_cpu *cpu,BOOL writing) {
    uint32_t count=arg(cpu,2),output=arg(cpu,3);
    if(!output||arg(cpu,4)){fail(cpu,0,87);return;}put(cpu,output,0);
    void *buffer=count?mem((tc_cpu *)cpu,arg(cpu,1),count):NULL;
    struct files *p=lock(cpu);struct file *f=find(p,arg(cpu,0));
    if(!f){unlock(p);fail(cpu,0,6);return;}
    if(!(f->access&(writing?2:1))){unlock(p);fail(cpu,0,5);return;}
    ssize_t n;do{n=writing?write(f->fd,buffer,count):read(f->fd,buffer,count);}while(n<0&&errno==EINTR);
    uint32_t error=n<0?error_code(errno):0;unlock(p);
    if(n<0){fail(cpu,0,error);return;}put(cpu,output,(uint32_t)n);cpu->_eax=1;
}
void tc_file_read(_cpu *cpu) { file_io(cpu,NO); }
void tc_file_write(_cpu *cpu) { file_io(cpu,YES); }
void tc_file_flush(_cpu *cpu) {
    struct files *p=lock(cpu);struct file *f=find(p,arg(cpu,0));
    if(!f){unlock(p);fail(cpu,0,6);return;}
    if(!(f->access&2)){unlock(p);fail(cpu,0,5);return;}
    int result;do{result=fsync(f->fd);}while(result&&errno==EINTR);
    uint32_t error=result?error_code(errno):0;unlock(p);
    if(result)fail(cpu,0,error);else cpu->_eax=1;
}
void tc_file_end(_cpu *cpu) {
    struct files *p=lock(cpu);struct file *f=find(p,arg(cpu,0));
    if(!f){unlock(p);fail(cpu,0,6);return;}
    if(!(f->access&2)){unlock(p);fail(cpu,0,5);return;}
    off_t offset=lseek(f->fd,0,SEEK_CUR);int result=offset<0?-1:ftruncate(f->fd,offset);
    uint32_t error=result?error_code(errno):0;unlock(p);
    if(result)fail(cpu,0,error);else cpu->_eax=1;
}
void tc_file_size(_cpu *cpu) {
    uint32_t high=arg(cpu,1);struct stat info;
    struct files *p=lock(cpu);struct file *f=find(p,arg(cpu,0));
    if(!f){unlock(p);fail(cpu,UINT32_MAX,6);return;}
    int status=fstat(f->fd,&info);uint32_t error=status?error_code(errno):0;unlock(p);
    if(status){fail(cpu,UINT32_MAX,error);return;}
    uint64_t size=(uint64_t)info.st_size;if(high)put(cpu,high,(uint32_t)(size>>32));
    cpu->_eax=(uint32_t)size;tc_write_fs(cpu,0x34,0);
}
void tc_file_seek(_cpu *cpu) {
    uint32_t highAddress=arg(cpu,2),method=arg(cpu,3);int64_t offset;
    if(method>2){fail(cpu,UINT32_MAX,87);return;}
    if(highAddress){uint32_t high;memcpy(&high,mem((tc_cpu *)cpu,highAddress,4),4);
        uint64_t bits=(uint64_t)high<<32|arg(cpu,1);memcpy(&offset,&bits,8);}
    else offset=(int32_t)arg(cpu,1);
    if(method==0&&offset<0){fail(cpu,UINT32_MAX,131);return;}
    struct files *p=lock(cpu);struct file *f=find(p,arg(cpu,0));
    if(!f){unlock(p);fail(cpu,UINT32_MAX,6);return;}
    const int origins[]={SEEK_SET,SEEK_CUR,SEEK_END};off_t result=lseek(f->fd,offset,origins[method]);
    uint32_t error=result<0?error_code(errno):0;unlock(p);
    if(result<0){fail(cpu,UINT32_MAX,error);return;}
    if(highAddress)put(cpu,highAddress,(uint32_t)((uint64_t)result>>32));
    cpu->_eax=(uint32_t)result;tc_write_fs(cpu,0x34,0);
}
void tc_file_close(_cpu *cpu) {
    if(tc_thread_close((tc_cpu *)cpu,arg(cpu,0))){cpu->_eax=1;return;}
    struct files *p=lock(cpu);uint32_t handle=arg(cpu,0);struct file **link=&p->list;
    while(*link&&(*link)->handle!=handle)link=&(*link)->next;
    if(!*link){unlock(p);fail(cpu,0,6);return;}
    struct file *f=*link;*link=f->next;int result=close(f->fd);uint32_t error=result?error_code(errno):0;
    free(f);unlock(p);if(result)fail(cpu,0,error);else cpu->_eax=1;
}
void tc_file_attributes(_cpu *cpu) {
    @autoreleasepool {
        NSString *name=path(cpu,arg(cpu,0));if(!name){fail(cpu,UINT32_MAX,123);return;}
        struct files *p=lock(cpu);struct stat info;int result=stat(name.fileSystemRepresentation,&info);
        uint32_t error=result?error_code(errno):0;unlock(p);
        if(result){fail(cpu,UINT32_MAX,error);return;}
        uint32_t attributes=S_ISDIR(info.st_mode)?16:0;if(!(info.st_mode&0222))attributes|=1;
        if([name.lastPathComponent hasPrefix:@"."])attributes|=2;cpu->_eax=attributes?attributes:128;
    }
}
void tc_file_type(_cpu *cpu) {
    struct files *p=lock(cpu);int found=find(p,arg(cpu,0))!=NULL;unlock(p);
    if(found)cpu->_eax=1;else fail(cpu,0,6);
}
#ifdef TC_FILES_SELF_CHECK
#include <assert.h>
int main(void) {
    /* RIFF with an odd-sized unknown chunk before data: verifies searching,
       padding, parent bounds, container position and malformed-size rejection. */
    unsigned char riff[]={ 'R','I','F','F',26,0,0,0,'W','A','V','E',
        'J','U','N','K',1,0,0,0,99,0,'d','a','t','a',4,0,0,0,1,2,3,4 };
    uint32_t pos=0,parent[5]={0,0,0x45564157,0,0},chunk[5]={0x61746164,0,0,0,0};
    assert(!riff_descend(riff,sizeof(riff),&pos,parent,NULL,0x20)&&pos==12&&parent[3]==8);
    assert(!riff_descend(riff,sizeof(riff),&pos,chunk,parent,0x10)&&pos==30&&chunk[1]==4);
    pos=12;riff[16]=255;assert(riff_descend(riff,sizeof(riff),&pos,chunk,parent,0x10)==272);
    @autoreleasepool {
        unsigned char bytes[512]={0};tc_cpu c={0};c.memory_size=sizeof(bytes);c.scalar._pointer_offset=(uintptr_t)bytes;
        memcpy(bytes+32,"Data\\World.bin",15);assert([path(&c.scalar,32)isEqualToString:@"Data/World.bin"]);
        memcpy(bytes+32,"C:\\x",5);assert(path(&c.scalar,32)==nil);
        memcpy(bytes+32,"Z:\\tmp\\file",12);assert([path(&c.scalar,32)isEqualToString:@"/tmp/file"]);
        const uint16_t unicode_path[]={'Z',':','\\','t','m','p','\\',0x4e16,0x754c,0xd83c,0xdfae,0};
        memcpy(bytes+33,unicode_path,sizeof(unicode_path));
        assert([encoded_path(&c.scalar,33,YES)isEqualToString:@"/tmp/世界🎮"]);
        uint16_t empty=0;memcpy(bytes+33,&empty,2);assert(!encoded_path(&c.scalar,33,YES));
        NSData *mapped=guest_path("/tmp/caf\xc3\xa9");
        assert(mapped.length==11&&!memcmp(mapped.bytes,"Z:\\tmp\\caf\xe9",11));
        NSString *profile=@"; comment\r\n[Graphics]\r\nWidth=1920\r\nName='Wide screen'\r\n[Game]\r\nVolume=700\r\n";
        assert([profile_values(profile,@"graphics",@"WIDTH").firstObject isEqualToString:@"1920"]);
        assert([profile_values(profile,@"Graphics",@"Name").firstObject isEqualToString:@"Wide screen"]);
        assert([profile_values(profile,nil,nil)isEqualToArray:@[@"Graphics",@"Game"]]);
        assert([profile_values(profile,@"Graphics",nil)isEqualToArray:@[@"Width",@"Name"]]);
        assert(!profile_values(profile,@"Missing",@"Width").count);
        NSString *edited=edit_profile(profile,@"graphics",@"Width",@"2560");
        assert([profile_values(edited,@"Graphics",@"Width").firstObject isEqualToString:@"2560"]);
        assert([edited containsString:@"; comment\r\n"]&&[edited containsString:@"Name='Wide screen'"]);
        edited=edit_profile(edited,@"Game",@"Radar",@"1");
        assert([profile_values(edited,@"Game",@"Radar").firstObject isEqualToString:@"1"]);
        edited=edit_profile(edited,@"Graphics",@"Name",nil);assert(!profile_values(edited,@"Graphics",@"Name").count);
        edited=edit_profile(edited,@"Graphics",nil,nil);assert(![profile_values(edited,nil,nil)containsObject:@"Graphics"]);
        edited=edit_profile(edited,@"Controls",@"Jump",@"57");
        assert([profile_values(edited,@"Controls",@"Jump").firstObject isEqualToString:@"57"]);
        struct statvfs disk={0};uint64_t capacity[3];disk.f_frsize=4096;
        disk.f_bavail=3;disk.f_blocks=UINT64_C(1)<<21;disk.f_bfree=7;
        assert(disk_space_bytes(&disk,capacity)&&capacity[0]==12288&&capacity[1]==UINT64_C(8589934592)&&capacity[2]==28672);
        disk.f_blocks=UINT64_MAX;assert(!disk_space_bytes(&disk,capacity));
        assert(error_code(ENOENT)==2&&error_code(EACCES)==5&&error_code(EBADF)==6);
        char temporary[]="/tmp/tc-files-XXXXXX";int fd=mkstemp(temporary);assert(fd>=0);
        assert(write(fd,"keep",4)==4);assert(!close(fd));
        strcpy((char *)bytes+32,temporary);c.scalar._esp=128;c.fs_base=256;c.fs_size=64;
        c.files=tc_files_create(temporary);assert(c.files);
        uint32_t standard_args[]={(uint32_t)-11,123};
        memcpy(bytes+132,standard_args,sizeof(standard_args));tc_standard_get(&c.scalar);assert(!c.scalar._eax);
        tc_standard_set(&c.scalar);assert(c.scalar._eax==1);
        tc_standard_get(&c.scalar);assert(c.scalar._eax==123);
        standard_args[0]=0;memcpy(bytes+132,standard_args,sizeof(standard_args));tc_standard_get(&c.scalar);
        assert(c.scalar._eax==UINT32_MAX&&tc_read_fs(&c.scalar,0x34)==87);
        uint32_t module_args[]={0,320,2};memcpy(bytes+132,module_args,sizeof(module_args));
        tc_module_filename(&c.scalar);
        assert(c.scalar._eax==2&&bytes[320]=='Z'&&!bytes[321]&&tc_read_fs(&c.scalar,0x34)==122);
        module_args[2]=128;memcpy(bytes+132,module_args,sizeof(module_args));tc_module_filename(&c.scalar);
        assert(c.scalar._eax>2&&c.scalar._eax<128&&!bytes[320+c.scalar._eax]);
        uint32_t args[7]={32,0x80000000u,1,0,3,128,0};memcpy(bytes+132,args,sizeof(args));
        uint16_t wide_temporary[64]={0};assert(strlen(temporary)<64);
        for(size_t i=0;i<strlen(temporary);i++)wide_temporary[i]=(unsigned char)temporary[i];
        memcpy(bytes+320,wide_temporary,(strlen(temporary)+1)*2);args[0]=320;memcpy(bytes+132,args,sizeof(args));
        tc_file_open_w(&c.scalar);uint32_t reader=c.scalar._eax;assert(reader!=UINT32_MAX);args[0]=32;
        args[1]=0x40000000u;args[2]=3;args[4]=2;memcpy(bytes+132,args,sizeof(args));
        tc_file_open(&c.scalar);assert(c.scalar._eax==UINT32_MAX&&tc_read_fs(&c.scalar,0x34)==32);
        args[0]=reader;args[1]=0;memcpy(bytes+132,args,sizeof(args));tc_file_size(&c.scalar);
        assert(c.scalar._eax==4);tc_file_close(&c.scalar);assert(c.scalar._eax==1);
        args[0]=32;args[1]=0x40000000u;memcpy(bytes+132,args,sizeof(args));tc_file_open(&c.scalar);
        uint32_t writer=c.scalar._eax;assert((int32_t)writer>0);
        memcpy(bytes+192,"save",4);args[0]=writer;args[1]=192;args[2]=4;args[3]=220;args[4]=0;
        memcpy(bytes+132,args,sizeof(args));tc_file_write(&c.scalar);assert(c.scalar._eax==1&&bytes[220]==4);
        tc_file_flush(&c.scalar);assert(c.scalar._eax==1);tc_file_close(&c.scalar);assert(c.scalar._eax==1);
        fd=open(temporary,O_RDONLY);assert(fd>=0);char saved[4];assert(read(fd,saved,4)==4&&!memcmp(saved,"save",4));
        assert(!close(fd));
        memcpy(bytes+192,"Game",5);memcpy(bytes+208,"Radar",6);memcpy(bytes+224,"1",2);
        uint32_t profile_args[]={192,208,224,32};memcpy(bytes+132,profile_args,sizeof(profile_args));
        tc_profile_write(&c.scalar);assert(c.scalar._eax==1);
        profile_args[2]=7;memcpy(bytes+132,profile_args,sizeof(profile_args));
        tc_profile_integer(&c.scalar);assert(c.scalar._eax==1);
        profile_args[2]=0;memcpy(bytes+132,profile_args,sizeof(profile_args));tc_profile_write(&c.scalar);assert(c.scalar._eax==1);
        profile_args[2]=7;memcpy(bytes+132,profile_args,sizeof(profile_args));tc_profile_integer(&c.scalar);assert(c.scalar._eax==7);
        assert(!unlink(temporary));tc_files_destroy(c.files);
    }return 0;
}
#endif
