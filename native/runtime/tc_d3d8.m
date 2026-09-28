#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <AppKit/AppKit.h>
#include <stdatomic.h>
#include "tc_modern.h"
#include <time.h>
#include <errno.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#import <ImageIO/ImageIO.h>
#include "tc_d3d8.h"
#include "tc_heap.h"
#include <math.h>
#include <float.h>
#include <string.h>

#define INVALID 0x8876086cu
#define UNAVAILABLE 0x8876086au
#define LOST 0x88760868u
#define OOM 0x8007000eu
#define TC_DEVICE_CAPABILITIES 0x00098440u /* Rasterization, hardware T&L, DrawPrimitives2Ex, TL vertices. */
#define TC_TEXTURE_OPERATIONS 0x039effffu /* Operations 1..26 except PREMODULATE and bump mapping. */

typedef struct {float diffuse[4],ambient[4],specular[4],emissive[4],power;} Material;
typedef struct {
    uint32_t type;float diffuse[4],specular[4],ambient[4],position[3],direction[3];
    float range,falloff,attenuation0,attenuation1,attenuation2,theta,phi;
} Light;
typedef struct {vector_float4 diffuse,ambient,specular,position,direction,attenuation,spot;} MetalLight;
typedef struct {
    vector_float4 diffuse,ambient,specular,emissive,globalAmbient;
    vector_uint4 flags,sources;vector_float4 parameters;MetalLight lights[8];
} Lighting;
typedef struct {vector_float4 color,parameters;vector_uint4 modes;} Fog;
typedef struct {vector_uint4 color,alpha;vector_float4 factor;vector_uint4 extra;} Combiner;
_Static_assert(sizeof(Combiner)==64,"Metal combiner layout");
_Static_assert(sizeof(Fog)==48,"Metal fog layout");
_Static_assert(sizeof(Material)==68&&sizeof(Light)==104,"D3D8 material/light layout");
_Static_assert(sizeof(MetalLight)==112&&sizeof(Lighting)==1024,"Metal lighting layout");

@interface TCGraphicsObject : NSObject {
@public uint32_t mipOffset[15], mipPitch[15], mipSize[15], lockedLevels;
}
@property uint32_t address, kind, references, data, length, format, width, height, fvf;
@property uint32_t levels, pool, usage, lod, parent, internalReferences, surfaceLevel;
@property BOOL locked;
@property(strong) id<MTLTexture> texture;
@end
@implementation TCGraphicsObject
@end

@interface TCMetal : NSObject {
@public
    uint32_t heap, tables[6], render[256], stages[8][32], vertexFormat, vertexHandle, nextVertexHandle;
    uint32_t streams[16], strides[16], indices, baseVertex, boundTexture[8];
    uint32_t viewport[6], deviceAddress, backSurface, depthSurface, backFormat, targetSurface, targetDepth, targetFormat;
    BOOL autoDepth, capturedFrame, scaledDirty, scaledFresh, msaaFresh, archiveDirty, nativePhase;
    unsigned upscaleMode, hdrMode, msaaSamples, passSamples;
    double archiveSaved;
    _Atomic float edrHeadroom;
    double lastPresent;
    matrix_float4x4 world, view, projection, textureMatrices[8];
    Material material;
    BOOL scene;
    BOOL reportedFailure[6][97];
    uint64_t headlessDraws,headlessPresents;
}
@property(strong) CAMetalLayer *layer;
@property(strong) id<MTLDevice> device;
@property(strong) id<MTLCommandQueue> queue;
@property(strong) id<MTLLibrary> library;
@property(strong) id<MTLTexture> color, depth, backBuffer, defaultDepth;
@property(strong) id<MTLCommandBuffer> command;
@property(strong) id<MTLFXSpatialScaler> scaler;
@property(strong) id<MTLRenderPipelineState> hdrPipeline;
/* scaledColor/Depth: 3D scene target (output size x MetalFX percentage).
 * outputColor/Depth: final image at the output resolution; the same textures as
 * scaledColor/Depth without MetalFX. 2D drawn after the MetalFX upscale lands here. */
@property(strong) id<MTLTexture> scaledColor, scaledDepth, msaaColor, msaaDepth, outputColor, outputDepth;
/* The render pass stays open across draws until its attachments change or
 * another encoder, commit, or present needs the command buffer. */
@property(strong) id<MTLRenderCommandEncoder> pass;
@property(strong) id<MTLTexture> passColor, passDepth;
@property(strong) id<MTLFunction> vertexFunction, fragmentFunction;
@property(strong) id<MTLBinaryArchive> archive;
@property(strong) NSURL *archiveURL, *keysURL;
@property(strong) NSMutableDictionary<NSNumber *, TCGraphicsObject *> *objects;
@property(strong) NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *pipelines;
@property(strong) NSMutableDictionary<NSNumber *, id<MTLSamplerState>> *samplers;
@property(strong) NSMutableDictionary<NSNumber *, id<MTLDepthStencilState>> *depthStates;
@property(strong) NSMutableDictionary<NSNumber *,NSData *> *lights, *vertexDeclarations;
@property(strong) NSMutableSet<NSNumber *> *enabledLights;
@end
@implementation TCMetal
@end

/* The 32-bit address-space mapping owns accessible pages. As elsewhere in the
 * runtime, access to an uncommitted page remains a host fault until guest SEH exists. */
static void *mem(tc_cpu *c, uint64_t address, uint64_t length) {
    if (!address || address > UINT32_MAX || length > c->memory_size ||
        address > c->memory_size - length ||
        c->scalar._pointer_offset > UINTPTR_MAX - address - length) abort();
    return (void *)(uintptr_t)(c->scalar._pointer_offset + address);
}
static uint32_t arg(tc_cpu *c, unsigned n) {
    uint32_t v; memcpy(&v, mem(c, (uint64_t)c->scalar._esp + 4 + n*4, 4), 4); return v;
}
static void put(tc_cpu *c, uint32_t address, uint32_t v) { memcpy(mem(c,address,4),&v,4); }
static float real(uint32_t v) { float f; memcpy(&f,&v,4); return f; }
static vector_float4 rgba(uint32_t c) {
    return (vector_float4){((c>>16)&255)/255.f,((c>>8)&255)/255.f,(c&255)/255.f,(c>>24)/255.f};
}
static TCMetal *context(tc_cpu *c) { return (__bridge TCMetal *)c->graphics; }
uint32_t tc_d3d_surface_format(tc_cpu *c,uint32_t address) {
    TCGraphicsObject *surface=context(c).objects[@(address)];
    return surface.kind==5?surface.format:0;
}
static uint32_t alloc(tc_cpu *c, TCMetal *g, uint32_t size) {
    return tc_heap_alloc(c->heap_process,g->heap,8,size);
}
static TCGraphicsObject *object(tc_cpu *c, TCMetal *g, unsigned kind) {
    uint32_t address=alloc(c,g,4); if (!address) return nil;
    TCGraphicsObject *o=[TCGraphicsObject new]; o.address=address; o.kind=kind; o.references=1;
    put(c,address,g->tables[kind]); g.objects[@(address)]=o; return o;
}
static void release_internal(tc_cpu *c,TCMetal *g,TCGraphicsObject *o);
static void discard_object(tc_cpu *c,TCMetal *g,TCGraphicsObject *o) {
    if(o.data)tc_heap_free(c->heap_process,g->heap,o.data);
    tc_heap_free(c->heap_process,g->heap,o.address);
    [g.objects removeObjectForKey:@(o.address)];
    if(o.address==g->backSurface)g->backSurface=0;
    if(o.address==g->depthSurface)g->depthSurface=0;
    TCGraphicsObject *parent=g.objects[@(o.parent)];
    if(o.kind==5&&parent.kind==4)release_internal(c,g,parent);
}
/* Internal bindings retain resources without keeping the device alive. External
 * references retain the parent chain. Texture surfaces also retain their container
 * internally so GetContainer remains valid after the texture is released. */
static uint32_t retain_object(TCMetal *g,TCGraphicsObject *o) {
    if(o.parent&&o.references==o.internalReferences)retain_object(g,g.objects[@(o.parent)]);
    return ++o.references;
}
static void retain_internal(TCGraphicsObject *o) {o.references++;o.internalReferences++;}
static void release_internal(tc_cpu *c,TCMetal *g,TCGraphicsObject *o) {
    if(!o||!o.internalReferences)return;
    o.internalReferences--;if(!--o.references)discard_object(c,g,o);
}
static void bind_surface(tc_cpu *c,TCMetal *g,uint32_t *slot,TCGraphicsObject *next) {
    TCGraphicsObject *old=g.objects[@(*slot)];
    if(next)retain_internal(next);
    *slot=next.address;
    release_internal(c,g,old);
}
static void release_object(tc_cpu *c, TCMetal *g, TCGraphicsObject *o) {
    if(!o||o.references<=o.internalReferences)return;
    --o.references;
    uint32_t parent=o.parent&&o.references==o.internalReferences?o.parent:0;
    if(!o.references) {
        if(o.kind==1) {
            bind_surface(c,g,&g->targetSurface,nil);bind_surface(c,g,&g->targetDepth,nil);
            for(unsigned stage=0;stage<8;stage++)bind_surface(c,g,&g->boundTexture[stage],nil);for(unsigned stream=0;stream<16;stream++)bind_surface(c,g,&g->streams[stream],nil);bind_surface(c,g,&g->indices,nil);
            [g.vertexDeclarations removeAllObjects];g->vertexHandle=g->vertexFormat=0;
            g->deviceAddress=0;g.color=nil;g.depth=nil;g.backBuffer=nil;g.defaultDepth=nil;
        }
        discard_object(c,g,o);
    }
    if(parent)release_object(c,g,g.objects[@(parent)]);
}
static BOOL surfaces_released(TCMetal *g) {
    for(TCGraphicsObject *o in g.objects.allValues)
        if(o.kind>=2&&o.pool==0&&o.references>o.internalReferences)return NO;
    return YES;
}
static void end_pass(TCMetal *g) {
    if(!g.pass)return;
    [g.pass endEncoding];g.pass=nil;g.passColor=g.passDepth=nil;
}
static id<MTLTexture> render_texture(TCMetal *g,unsigned width,unsigned height,BOOL depth) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        depth?MTLPixelFormatDepth32Float_Stencil8:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget;
    if(!depth)d.usage|=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
    return [g.device newTextureWithDescriptor:d];
}
static TCGraphicsObject *surface_object(tc_cpu *c,TCMetal *g,TCGraphicsObject *device,
    id<MTLTexture> texture,uint32_t format,BOOL depth) {
    TCGraphicsObject *surface=object(c,g,5);if(!surface)return nil;
    surface.texture=texture;surface.width=(uint32_t)texture.width;surface.height=(uint32_t)texture.height;
    surface.format=format;surface.usage=depth?2:1;surface.length=surface.width*surface.height*4;
    surface.parent=device.address;retain_object(g,device);
    if(device.kind==4)retain_internal(device);
    return surface;
}
static TCGraphicsObject *owning_device(TCMetal *g,TCGraphicsObject *o) {
    TCGraphicsObject *parent=g.objects[@(o.parent)];
    return parent.kind==4?g.objects[@(parent.parent)]:parent;
}
static MTLPixelFormat texture_format(uint32_t format) {
    switch(format) {
    case 21:case 22:case 23:case 24:case 25:case 26:return MTLPixelFormatBGRA8Unorm;
    case 0x31545844:return MTLPixelFormatBC1_RGBA;
    // DXT2/4 share the DXT3/5 block layouts. Preserve their premultiplied RGB;
    // the game's blend state determines how the sampled values are combined.
    case 0x32545844:case 0x33545844:return MTLPixelFormatBC2_RGBA;
    case 0x34545844:case 0x35545844:return MTLPixelFormatBC3_RGBA;
    default:return MTLPixelFormatInvalid;
    }
}
static unsigned block_size(uint32_t format) { return format==0x31545844?8:16; }
static BOOL compressed(uint32_t format) { return format>255; }
static unsigned mip_dimension(unsigned value,unsigned level) { value>>=level;return value?value:1; }
static BOOL texture_layout(TCGraphicsObject *o) {
    unsigned maximum=1;
    for(unsigned n=MAX(o.width,o.height);n>1;n>>=1)maximum++;
    unsigned levels=o.levels?o.levels:maximum;
    if(!o.width||!o.height||maximum>15||levels>maximum||!texture_format(o.format))return NO;
    uint64_t total=0;
    for(unsigned i=0;i<levels;i++) {
        unsigned w=mip_dimension(o.width,i),h=mip_dimension(o.height,i);
        unsigned pitch=compressed(o.format)?((w+3)/4)*block_size(o.format):w*(o.format<=22?4:2);
        unsigned size=pitch*(compressed(o.format)?(h+3)/4:h);
        o->mipOffset[i]=(uint32_t)total;o->mipPitch[i]=pitch;o->mipSize[i]=size;total+=size;
        if(total>UINT32_MAX)return NO;
    }
    o.levels=levels;o.length=(uint32_t)total;return YES;
}
static id<MTLTexture> upload_texture_bytes(TCMetal *g,TCGraphicsObject *o,const unsigned char *bytes) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:texture_format(o.format)
        width:o.width height:o.height mipmapped:o.levels>1];
    d.mipmapLevelCount=o.levels;d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> texture=[g.device newTextureWithDescriptor:d];if(!texture)return nil;
    for(unsigned i=0;i<o.levels;i++) {
        unsigned w=mip_dimension(o.width,i),h=mip_dimension(o.height,i),pitch=o->mipPitch[i];
        const unsigned char *src=bytes+o->mipOffset[i];unsigned char *converted=NULL;
        if(o.format>=22&&o.format<=26) {
            converted=malloc((size_t)w*h*4);if(!converted)return nil;
            for(uint64_t pixel=0;pixel<(uint64_t)w*h;pixel++) {
                unsigned r,g,b,a=255;
                if(o.format==22){b=src[pixel*4];g=src[pixel*4+1];r=src[pixel*4+2];}
                else {
                    uint16_t v;memcpy(&v,src+pixel*2,2);
                    if(o.format==23){r=(v>>11)*255/31;g=((v>>5)&63)*255/63;b=(v&31)*255/31;}
                    else if(o.format==26){r=((v>>8)&15)*17;g=((v>>4)&15)*17;b=(v&15)*17;a=(v>>12)*17;}
                    else {r=((v>>10)&31)*255/31;g=((v>>5)&31)*255/31;b=(v&31)*255/31;if(o.format==25)a=(v>>15)*255;}
                }
                converted[pixel*4]=b;converted[pixel*4+1]=g;converted[pixel*4+2]=r;converted[pixel*4+3]=a;
            }
            src=converted;pitch=w*4;
        }
        [texture replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:i withBytes:src bytesPerRow:pitch];free(converted);
    }
    return texture;
}
static id<MTLTexture> upload_texture(tc_cpu *c,TCMetal *g,TCGraphicsObject *o) {
    return upload_texture_bytes(g,o,mem(c,o.data,o.length));
}
static unsigned method_count(unsigned kind) {
    static const unsigned count[]={16,97,14,14,19,11}; return count[kind];
}
#include "tc_fixed_metallib.h"

static BOOL blend(unsigned v, MTLBlendFactor *out);
/* Pipeline key: blend enable, source/destination factors, operation, write
 * mask, depth attachment, raster sample count, alpha-to-coverage. */
static uint32_t pipeline_key(const uint32_t *render,BOOL depth,unsigned samples,BOOL coverage) {
    return (render[27]!=0)|render[19]<<1|render[20]<<5|render[171]<<9|render[168]<<12|
        (uint32_t)depth<<16|samples<<17|(uint32_t)coverage<<20;
}
static MTLRenderPipelineDescriptor *pipeline_descriptor(TCMetal *g,uint32_t key) {
    MTLBlendFactor source,destination;unsigned operation=(key>>9)&7,samples=(key>>17)&7;
    if(!blend((key>>1)&15,&source)||!blend((key>>5)&15,&destination)||operation<1||operation>5||
       (samples!=1&&samples!=2&&samples!=4)||key>>21)return nil;
    MTLRenderPipelineDescriptor *p=[MTLRenderPipelineDescriptor new];
    p.vertexFunction=g.vertexFunction;p.fragmentFunction=g.fragmentFunction;
    p.rasterSampleCount=samples;p.alphaToCoverageEnabled=(key>>20)&1;
    p.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    p.depthAttachmentPixelFormat=p.stencilAttachmentPixelFormat=(key>>16)&1?MTLPixelFormatDepth32Float_Stencil8:MTLPixelFormatInvalid;
    p.colorAttachments[0].blendingEnabled=key&1;
    p.colorAttachments[0].rgbBlendOperation=p.colorAttachments[0].alphaBlendOperation=(MTLBlendOperation)(operation-1);
    uint32_t mask=(key>>12)&15;
    p.colorAttachments[0].writeMask=((mask&1)?MTLColorWriteMaskRed:0)|((mask&2)?MTLColorWriteMaskGreen:0)|
        ((mask&4)?MTLColorWriteMaskBlue:0)|((mask&8)?MTLColorWriteMaskAlpha:0);
    p.colorAttachments[0].sourceRGBBlendFactor=p.colorAttachments[0].sourceAlphaBlendFactor=source;
    p.colorAttachments[0].destinationRGBBlendFactor=p.colorAttachments[0].destinationAlphaBlendFactor=destination;
    if(g.archive)p.binaryArchives=@[g.archive];
    return p;
}
/* Pipelines are looked up in the saved binary archive; their keys are
 * rebuilt at startup so first use of a blend combination does not stall. */
static id<MTLRenderPipelineState> pipeline_state(TCMetal *g,uint32_t key,BOOL record) {
    id<MTLRenderPipelineState> pipeline=g.pipelines[@(key)];if(pipeline)return pipeline;
    MTLRenderPipelineDescriptor *p=pipeline_descriptor(g,key);if(!p)return nil;
    pipeline=[g.device newRenderPipelineStateWithDescriptor:p error:nil];if(!pipeline)return nil;
    g.pipelines[@(key)]=pipeline;
    if(record)g->archiveDirty=YES;
    return pipeline;
}
/* ponytail: prewarm is synchronous at device creation; move it to a background
 * queue if the archive grows large enough to delay startup noticeably. */
static void load_pipeline_cache(TCMetal *g) {
    NSFileManager *files=NSFileManager.defaultManager;
    NSURL *directory=[[files URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
        URLByAppendingPathComponent:@"TrueCrimeMetal" isDirectory:YES];
    if(!directory||![files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil])return;
    /* Name the cache after the shader library so rebuilt shaders start fresh. */
    uint32_t hash=2166136261u;for(size_t i=0;i<sizeof(tc_fixed_metallib);i++)hash=(hash^tc_fixed_metallib[i])*16777619u;
    g.archiveURL=[directory URLByAppendingPathComponent:[NSString stringWithFormat:@"pipelines-%08x.bin",hash]];
    g.keysURL=[directory URLByAppendingPathComponent:[NSString stringWithFormat:@"pipelines-%08x.plist",hash]];
    MTLBinaryArchiveDescriptor *d=[MTLBinaryArchiveDescriptor new];
    NSArray *keys=nil;
    if([files fileExistsAtPath:g.archiveURL.path]){d.url=g.archiveURL;keys=[NSArray arrayWithContentsOfURL:g.keysURL error:nil];}
    g.archive=[g.device newBinaryArchiveWithDescriptor:d error:nil];
    if(!g.archive&&d.url){d.url=nil;keys=nil;g.archive=[g.device newBinaryArchiveWithDescriptor:d error:nil];}
    if(!g.archive){g.archiveURL=nil;return;}
    for(id key in keys)if([key isKindOfClass:NSNumber.class])pipeline_state(g,[key unsignedIntValue],NO);
}
static void save_pipeline_cache(TCMetal *g) {
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);double now=t.tv_sec+t.tv_nsec/1e9;
    if(!g->archiveDirty||!g.archiveURL||(g->archiveSaved&&now-g->archiveSaved<10))return;
    g->archiveDirty=NO;g->archiveSaved=now;
    /* Re-serializing one archive object fails on every other call (macOS 27),
     * so each save packs a fresh archive once. Write beside the loaded archive
     * and rename over it, since the loaded one may map the old file. */
    NSError *error=nil;
    id<MTLBinaryArchive> archive=[g.device newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:&error];
    for(NSNumber *key in g.pipelines) {
        MTLRenderPipelineDescriptor *p=pipeline_descriptor(g,key.unsignedIntValue);
        if(p&&![archive addRenderPipelineFunctionsWithDescriptor:p error:&error])archive=nil;
        if(!archive)break;
    }
    NSURL *temporary=[g.archiveURL URLByAppendingPathExtension:@"tmp"];
    if(!archive||![archive serializeToURL:temporary error:&error]||rename(temporary.fileSystemRepresentation,g.archiveURL.fileSystemRepresentation)) {
        fprintf(stderr,"Pipeline cache could not be saved: %s\n",error?error.localizedDescription.UTF8String:strerror(errno));
        g.archiveURL=nil;return;
    }
    [g.pipelines.allKeys writeToURL:g.keysURL error:nil];
}

int tc_d3d_attach(tc_cpu *c, CAMetalLayer *layer) {
    if (!c || !c->heap_process || (!layer&&!c->headless) || c->graphics) return -1;
    TCMetal *g=[TCMetal new]; g.device=layer.device ?: MTLCreateSystemDefaultDevice();
    if (!g.device) return -1;
    g.queue=[g.device newCommandQueue];
    dispatch_data_t libraryData=dispatch_data_create(tc_fixed_metallib,sizeof(tc_fixed_metallib),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    g.library=[g.device newLibraryWithData:libraryData error:nil];
    if (!g.queue || !g.library) return -1;
    g->heap=tc_heap_create(c->heap_process,0,0,0); if (!g->heap) return -1;
    g.objects=[NSMutableDictionary new]; g.pipelines=[NSMutableDictionary new];
    g.samplers=[NSMutableDictionary new]; g.depthStates=[NSMutableDictionary new];
    g.vertexFunction=[g.library newFunctionWithName:@"vs"];g.fragmentFunction=[g.library newFunctionWithName:@"fs"];
    if(!g.vertexFunction||!g.fragmentFunction) return -1;
    g.vertexDeclarations=[NSMutableDictionary new];g->nextVertexHandle=1;
    for(unsigned k=0;k<6;k++) {
        g->tables[k]=alloc(c,g,method_count(k)*4);
        if(!g->tables[k]) { tc_heap_destroy(c->heap_process,g->heap); return -1; }
        for(unsigned m=0;m<method_count(k);m++) put(c,g->tables[k]+m*4,0xf0010000u+k*0x1000u+m*16u);
    }
    g.layer=layer; layer.device=g.device; layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
    /* Presentation copies the persistent D3D back buffer into the drawable. */
    layer.framebufferOnly=NO; layer.opaque=YES; layer.maximumDrawableCount=3;
    g->world=g->view=g->projection=matrix_identity_float4x4;
    g.lights=[NSMutableDictionary new];g.enabledLights=[NSMutableSet new];
    for(unsigned i=0;i<4;i++)g->material.diffuse[i]=g->material.ambient[i]=1;
    g->render[7]=1; g->render[14]=1; g->render[19]=2; g->render[20]=1;
    g->render[22]=3; g->render[23]=4; g->render[137]=1;
    g->render[8]=3;g->render[9]=2;g->render[25]=8;g->render[168]=15;g->render[171]=1;
    g->render[53]=g->render[54]=g->render[55]=1;g->render[56]=8;
    g->render[58]=g->render[59]=g->render[60]=UINT32_MAX;
    g->render[141]=g->render[142]=1;g->render[145]=1;g->render[146]=2;
    g->render[37]=g->render[38]=0x3f800000u;
    for(unsigned i=0;i<8;i++) {
        g->textureMatrices[i]=matrix_identity_float4x4;
        g->stages[i][1]=i?1:4;g->stages[i][2]=2;g->stages[i][3]=1;
        g->stages[i][4]=i?1:2;g->stages[i][5]=2;g->stages[i][6]=1;
        g->stages[i][11]=i;g->stages[i][28]=1;
        g->stages[i][26]=g->stages[i][27]=1;
        g->stages[i][13]=g->stages[i][14]=1;
        g->stages[i][16]=g->stages[i][17]=1;
    }
    tc_modern_init(c);load_pipeline_cache(g);c->graphics=(__bridge_retained void *)g; return 0;
}
void tc_d3d_close(tc_cpu *c) {
    if(!c || !c->graphics) return;
    TCMetal *g=(__bridge_transfer TCMetal *)c->graphics; c->graphics=NULL;
    end_pass(g);
    if(g.command) { [g.command commit]; [g.command waitUntilCompleted]; }
    g->archiveSaved=0;save_pipeline_cache(g);
    tc_heap_destroy(c->heap_process,g->heap);tc_modern_close(c);
}
void tc_direct_create(_cpu *cpu) {
    @autoreleasepool {
        tc_cpu *c=(tc_cpu *)cpu; TCMetal *g=context(c); cpu->_eax=0;
        if(g && arg(c,0)==220) cpu->_eax=object(c,g,0).address;
    }
}
static BOOL reset(TCMetal *g, const uint32_t *p) {
    unsigned w=p[0],h=p[1];
    if(!w || !h || w>16384 || h>16384 || (p[2]!=21 && p[2]!=22) || p[3]>1 || p[4] ||
       (p[8] && p[9]!=75) || (p[12]!=0 && p[12]!=1 && p[12]!=0x80000000u)) return NO;
    end_pass(g);
    if(g.command) { [g.command commit]; [g.command waitUntilCompleted]; g.command=nil; }
    id<MTLTexture> color=render_texture(g,w,h,NO);
    id<MTLTexture> depth=p[8]?render_texture(g,w,h,YES):nil;
    if(!color||(p[8]&&!depth))return NO;
    g.scaler=nil;g.scaledColor=g.scaledDepth=g.outputColor=g.outputDepth=nil;g->upscaleMode=0;g->scaledDirty=NO;g->nativePhase=NO;
    g.msaaColor=g.msaaDepth=nil;g->msaaSamples=1;
    g.color=g.backBuffer=color;g.depth=g.defaultDepth=depth;
    g->backFormat=g->targetFormat=p[2];g->autoDepth=p[8]!=0;g.layer.drawableSize=CGSizeMake(w,h);
    g.layer.displaySyncEnabled=p[12]!=0x80000000u;
    g->viewport[0]=g->viewport[1]=0; g->viewport[2]=w;g->viewport[3]=h;
    g->viewport[4]=0; g->viewport[5]=0x3f800000; return YES;
}
static BOOL reset_guest_device(tc_cpu *c,TCMetal *g,uint32_t address) {
    if(!surfaces_released(g))return NO;
    uint32_t parameters[13];memcpy(parameters,mem(c,address,sizeof(parameters)),sizeof(parameters));
    if(c->prepare_graphics&&c->prepare_graphics(&c->scalar,parameters))return NO;
    if(!reset(g,parameters))return NO;
    bind_surface(c,g,&g->targetSurface,nil);bind_surface(c,g,&g->targetDepth,nil);
    for(unsigned stage=0;stage<8;stage++)bind_surface(c,g,&g->boundTexture[stage],nil);for(unsigned stream=0;stream<16;stream++)bind_surface(c,g,&g->streams[stream],nil);bind_surface(c,g,&g->indices,nil);
    memcpy(mem(c,address,sizeof(parameters)),parameters,sizeof(parameters));return YES;
}
static BOOL scaled_target(TCMetal *g) {
    return g.scaledColor&&g.color==g.backBuffer&&(!g.depth||g.depth==g.defaultDepth);
}
static void resolve_scaled(TCMetal *g) {
    end_pass(g);
    if(!g->scaledDirty||!g.scaler||g->nativePhase)return;
    if(!g.command)g.command=[g.queue commandBuffer];
    g.scaler.colorTexture=g.scaledColor;g.scaler.outputTexture=g.outputColor;
    [g.scaler encodeToCommandBuffer:g.command];g->scaledDirty=NO;
}
/* Output resolution: the UI-scale output size (tc_modern_output) when the game
 * runs at a virtual resolution, otherwise the game's back buffer size. The 3D
 * scene renders at output x MetalFX percentage; viewports scale to match. */
static void configure_scaler(tc_cpu *c,TCMetal *g) {
    if(!g.backBuffer)return;
    unsigned mode=tc_modern_get(c,TC_METALFX);
    uint32_t outW=(uint32_t)g.backBuffer.width,outH=(uint32_t)g.backBuffer.height;
    tc_modern_output(c,outW,outH,&outW,&outH);
    const unsigned percentages[]={100,67,59,50};
    NSUInteger w=MAX(1,outW*percentages[mode]/100),h=MAX(1,outH*percentages[mode]/100);
    BOOL native=w==g.backBuffer.width&&h==g.backBuffer.height&&!mode;
    if(native?!g.scaledColor:(mode==g->upscaleMode&&g.scaledColor.width==w&&g.scaledColor.height==h&&g.outputColor.width==outW))return;
    resolve_scaled(g);end_pass(g);
    g.scaler=nil;g.scaledColor=g.scaledDepth=g.outputColor=g.outputDepth=nil;g->upscaleMode=0;g->nativePhase=NO;
    if(g.layer)g.layer.drawableSize=CGSizeMake(outW,outH);
    if(native)return;
    id<MTLTexture> color=render_texture(g,(unsigned)w,(unsigned)h,NO);
    id<MTLTexture> depth=g.defaultDepth?render_texture(g,(unsigned)w,(unsigned)h,YES):nil;
    if(!color||(g.defaultDepth&&!depth)){fprintf(stderr,"Scaled render targets could not be created; using the game resolution.\n");
        tc_modern_set(c,TC_METALFX,0);if(g.layer)g.layer.drawableSize=CGSizeMake(g.backBuffer.width,g.backBuffer.height);return;}
    if(!mode) {
        g.scaledColor=g.outputColor=color;g.scaledDepth=g.outputDepth=depth;g->scaledFresh=YES;return;
    }
    if(![MTLFXSpatialScalerDescriptor supportsDevice:g.device]) {
        tc_modern_set(c,TC_METALFX,0);fprintf(stderr,"MetalFX spatial scaling is unavailable on this GPU.\n");return;
    }
    MTLFXSpatialScalerDescriptor *d=[MTLFXSpatialScalerDescriptor new];
    d.inputWidth=w;d.inputHeight=h;d.outputWidth=outW;d.outputHeight=outH;
    d.colorTextureFormat=d.outputTextureFormat=MTLPixelFormatBGRA8Unorm;
    d.colorProcessingMode=MTLFXSpatialScalerColorProcessingModePerceptual;
    id<MTLFXSpatialScaler> scaler=[d newSpatialScalerWithDevice:g.device];
    id<MTLTexture> output=render_texture(g,outW,outH,NO);
    id<MTLTexture> outputDepth=g.defaultDepth?render_texture(g,outW,outH,YES):nil;
    if(!scaler||!output||(g.defaultDepth&&!outputDepth)||
       (color.usage&scaler.colorTextureUsage)!=scaler.colorTextureUsage||
       (output.usage&scaler.outputTextureUsage)!=scaler.outputTextureUsage) {
        tc_modern_set(c,TC_METALFX,0);fprintf(stderr,"MetalFX resources could not be created; using native resolution.\n");return;
    }
    scaler.inputContentWidth=w;scaler.inputContentHeight=h;
    g.scaler=scaler;g.scaledColor=color;g.scaledDepth=depth;g.outputColor=output;g.outputDepth=outputDepth;
    g->upscaleMode=mode;g->scaledFresh=YES;
}
/* MSAA covers the scene target only: the back buffer (or MetalFX input) with
 * the automatic depth buffer. Each pass resolves into that texture, so
 * presentation, capture and MetalFX read resolved pixels.
 * ponytail: single-sample draws into the back buffer between MSAA passes are
 * overwritten by the next resolve, as with the MetalFX scaled target. */
static BOOL msaa_target(TCMetal *g) {
    return g->msaaSamples>1&&g.msaaColor&&!g->nativePhase&&g.color==g.backBuffer&&(!g.depth||g.depth==g.defaultDepth);
}
static id<MTLTexture> msaa_texture(TCMetal *g,NSUInteger width,NSUInteger height,BOOL depth,unsigned samples) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        depth?MTLPixelFormatDepth32Float_Stencil8:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    d.textureType=MTLTextureType2DMultisample;d.sampleCount=samples;
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget;
    return [g.device newTextureWithDescriptor:d];
}
static void configure_msaa(tc_cpu *c,TCMetal *g) {
    unsigned samples=(unsigned[]){1,2,4}[tc_modern_get(c,TC_MSAA)];
    id<MTLTexture> resolve=g.scaledColor?g.scaledColor:g.backBuffer;
    if(samples==g->msaaSamples&&(samples==1||(g.msaaColor.width==resolve.width&&g.msaaColor.height==resolve.height)))return;
    end_pass(g);g.msaaColor=g.msaaDepth=nil;g->msaaSamples=1;
    if(samples==1||!resolve)return;
    id<MTLTexture> color=[g.device supportsTextureSampleCount:samples]?msaa_texture(g,resolve.width,resolve.height,NO,samples):nil;
    id<MTLTexture> depth=color&&g.defaultDepth?msaa_texture(g,resolve.width,resolve.height,YES,samples):nil;
    if(!color||(g.defaultDepth&&!depth)) {
        tc_modern_set(c,TC_MSAA,0);fprintf(stderr,"MSAA resources could not be created; anti-aliasing disabled.\n");return;
    }
    g.msaaColor=color;g.msaaDepth=depth;g->msaaSamples=samples;g->msaaFresh=YES;
}
static double monotonic_seconds(void) {
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;
}
static void pace_frame(tc_cpu *c,TCMetal *g) {
    unsigned fps=tc_modern_get(c,TC_FRAME_LIMIT);double now=monotonic_seconds();
    if(fps&&g->lastPresent) {
        double remaining=g->lastPresent+1.0/fps-now;
        if(remaining>0&&remaining<1) {
            struct timespec delay={(time_t)remaining,(long)((remaining-floor(remaining))*1e9)};
            while(nanosleep(&delay,&delay)&&errno==EINTR){}
        }
    }
    g->lastPresent=monotonic_seconds();
}
static id<MTLRenderCommandEncoder> encoder(TCMetal *g, unsigned flags, uint32_t color, float z, unsigned stencil) {
    if(!g.color) return nil;
    BOOL scaled=scaled_target(g),msaa=msaa_target(g);
    id<MTLTexture> resolve=scaled?(g->nativePhase?g.outputColor:g.scaledColor):g.color;
    id<MTLTexture> depth=scaled&&g.depth?(g->nativePhase?g.outputDepth:g.scaledDepth):g.depth;
    id<MTLTexture> target=msaa?g.msaaColor:resolve;if(msaa&&depth)depth=g.msaaDepth;
    if(scaled) {if(g->scaledFresh){flags|=7;g->scaledFresh=NO;}g->scaledDirty=YES;}
    if(msaa&&g->msaaFresh){flags|=7;g->msaaFresh=NO;}
    if(g.pass&&!flags&&g.passColor==target&&g.passDepth==depth)return g.pass;
    end_pass(g);
    if(!g.command) g.command=[g.queue commandBuffer];
    MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor renderPassDescriptor];
    vector_float4 v=rgba(color);
    p.colorAttachments[0].texture=target;
    p.colorAttachments[0].loadAction=flags&1 ? MTLLoadActionClear : MTLLoadActionLoad;
    p.colorAttachments[0].storeAction=msaa?MTLStoreActionStoreAndMultisampleResolve:MTLStoreActionStore;
    if(msaa)p.colorAttachments[0].resolveTexture=resolve;
    p.colorAttachments[0].clearColor=MTLClearColorMake(v.x,v.y,v.z,v.w);
    p.depthAttachment.texture=depth; p.depthAttachment.clearDepth=z;
    p.depthAttachment.loadAction=flags&2 ? MTLLoadActionClear : MTLLoadActionLoad;
    p.depthAttachment.storeAction=MTLStoreActionStore;
    p.stencilAttachment.texture=depth; p.stencilAttachment.clearStencil=stencil;
    p.stencilAttachment.loadAction=flags&4 ? MTLLoadActionClear : MTLLoadActionLoad;
    p.stencilAttachment.storeAction=MTLStoreActionStore;
    g.pass=[g.command renderCommandEncoderWithDescriptor:p];
    if(g.pass){g.passColor=target;g.passDepth=depth;g->passSamples=msaa?g->msaaSamples:1;}
    return g.pass;
}
int tc_d3d_resize(tc_cpu *c, uint32_t width, uint32_t height) {
    TCMetal *g=context(c);
    if(!g || g->scene||!surfaces_released(g))return -1;
    if(!g.color) { g.layer.drawableSize=CGSizeMake(width,height);return 0; }
    uint32_t p[13]={width,height,g->backFormat,1,0,1,0,1,g->autoDepth,75,0,0,g.layer.displaySyncEnabled?1:0x80000000u};
    if(!reset(g,p))return -1;
    bind_surface(c,g,&g->targetSurface,nil);bind_surface(c,g,&g->targetDepth,nil);
    for(unsigned stage=0;stage<8;stage++)bind_surface(c,g,&g->boundTexture[stage],nil);for(unsigned stream=0;stream<16;stream++)bind_surface(c,g,&g->streams[stream],nil);bind_surface(c,g,&g->indices,nil);return 0;
}
/* Explicit, one-shot offscreen capture. The request file is created only when
 * the headless driver has finished sending the desired menu input. */
static uint32_t capture_frame(TCMetal *g,NSString *path) {
    id<MTLTexture> source=g.outputColor?g.outputColor:g.backBuffer;
    NSUInteger width=source.width,height=source.height,pitch=(width*4+255)&~255u;
    id<MTLBuffer> pixels=[g.device newBufferWithLength:pitch*height options:MTLResourceStorageModeShared];
    if(!pixels)return OOM;
    if(!g.command)g.command=[g.queue commandBuffer];
    id<MTLBlitCommandEncoder> encoder=[g.command blitCommandEncoder];
    if(!encoder)return LOST;
    [encoder copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(width,height,1) toBuffer:pixels destinationOffset:0
        destinationBytesPerRow:pitch destinationBytesPerImage:pitch*height];
    [encoder endEncoding];[g.command commit];[g.command waitUntilCompleted];
    BOOL failed=g.command.status==MTLCommandBufferStatusError;g.command=nil;
    if(failed)return LOST;
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(pixels.contents,width,height,8,pitch,space,
        kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst);
    CGColorSpaceRelease(space);if(!context)return OOM;
    CGImageRef image=CGBitmapContextCreateImage(context);CGContextRelease(context);
    if(!image)return OOM;
    CGImageDestinationRef destination=CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path],CFSTR("public.png"),1,NULL);
    if(!destination){CGImageRelease(image);return INVALID;}
    CGImageDestinationAddImage(destination,image,NULL);
    BOOL written=CGImageDestinationFinalize(destination);
    CFRelease(destination);CGImageRelease(image);
    fprintf(stderr,"Headless frame %s: %s\n",written?"saved":"failed",path.fileSystemRepresentation);
    return written?0:INVALID;
}
/* Switch the layer between SDR BGRA8 and EDR RGBA16F when the menu setting changes. */
static void configure_hdr(tc_cpu *c,TCMetal *g) {
    static unsigned frames;
    if(frames++%60==0) {
        __weak TCMetal *weak=g;
        dispatch_async(dispatch_get_main_queue(),^{
            TCMetal *strong=weak;NSScreen *screen=NSScreen.mainScreen;
            if(strong&&screen)atomic_store(&strong->edrHeadroom,(float)screen.maximumExtendedDynamicRangeColorComponentValue);
        });
    }
    unsigned mode=tc_modern_get(c,TC_HDR);
    if(mode&&!g.hdrPipeline) {
        MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
        d.vertexFunction=[g.library newFunctionWithName:@"present_vs"];
        d.fragmentFunction=[g.library newFunctionWithName:@"present_hdr_fs"];
        d.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;
        g.hdrPipeline=[g.device newRenderPipelineStateWithDescriptor:d error:nil];
        if(!g.hdrPipeline){fprintf(stderr,"HDR output pipeline could not be created; using SDR.\n");tc_modern_set(c,TC_HDR,0);mode=0;}
    }
    if(mode==g->hdrMode)return;
    g->hdrMode=mode;
    g.layer.wantsExtendedDynamicRangeContent=mode!=0;
    g.layer.pixelFormat=mode?MTLPixelFormatRGBA16Float:MTLPixelFormatBGRA8Unorm;
    CGColorSpaceRef space=mode?CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB):NULL;
    g.layer.colorspace=space;if(space)CGColorSpaceRelease(space);
}
static uint32_t present(tc_cpu *c,TCMetal *g) {
    resolve_scaled(g);save_pipeline_cache(g);g->nativePhase=NO;
    if(!g.backBuffer) return INVALID;
    id<MTLTexture> image=g.outputColor?g.outputColor:g.backBuffer;
    if(!g.layer) {
        const char *requested=getenv("TC_HEADLESS_FRAME");
        NSString *path=requested?[NSString stringWithUTF8String:requested]:nil;
        /* Each <path>.request file captures one frame; remove it so later requests capture again. */
        NSString *request=[path stringByAppendingString:@".request"];
        if(path.length&&[[NSFileManager defaultManager]fileExistsAtPath:request]) {
            [[NSFileManager defaultManager]removeItemAtPath:request error:nil];return capture_frame(g,path);
        }
        if(g.command){[g.command commit];[g.command waitUntilCompleted];
            BOOL failed=g.command.status==MTLCommandBufferStatusError;g.command=nil;return failed?LOST:0;}
        return 0;
    }
    g.layer.displaySyncEnabled=tc_modern_get(c,TC_VSYNC)!=0;
    configure_hdr(c,g);
    pace_frame(c,g);
    id<CAMetalDrawable> drawable=[g.layer nextDrawable]; if(!drawable) return LOST;
    if(!g.command) g.command=[g.queue commandBuffer];
    if(g->hdrMode) {
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=drawable.texture;
        pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e=[g.command renderCommandEncoderWithDescriptor:pass];
        if(!e)return LOST;
        /* Paper white 1.0/1.5/2.0 x SDR white, never above the display's current headroom. */
        float headroom=fmaxf(1,atomic_load(&g->edrHeadroom));
        vector_float2 levels={fminf((float[]){1,1,1.5f,2}[g->hdrMode],headroom),headroom};
        [e setRenderPipelineState:g.hdrPipeline];[e setFragmentTexture:image atIndex:0];
        [e setFragmentBytes:&levels length:sizeof(levels) atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];
    } else {
        id<MTLBlitCommandEncoder> b=[g.command blitCommandEncoder];
        [b copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(image.width,image.height,1) toTexture:drawable.texture
            destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [b endEncoding];
    }
    [g.command presentDrawable:drawable]; [g.command commit]; g.command=nil; return 0;
}
static BOOL blend(unsigned v, MTLBlendFactor *out) {
    static const MTLBlendFactor factors[]={MTLBlendFactorZero,MTLBlendFactorZero,MTLBlendFactorOne,
        MTLBlendFactorSourceColor,MTLBlendFactorOneMinusSourceColor,MTLBlendFactorSourceAlpha,
        MTLBlendFactorOneMinusSourceAlpha,MTLBlendFactorDestinationAlpha,MTLBlendFactorOneMinusDestinationAlpha,
        MTLBlendFactorDestinationColor,MTLBlendFactorOneMinusDestinationColor,MTLBlendFactorSourceAlphaSaturated};
    if(v<1 || v>11) return NO; *out=factors[v]; return YES;
}
static BOOL render_state_valid(unsigned state,uint32_t value) {
    switch(state) {
    case 7:case 14:case 15:case 27:case 28:case 29:case 48:case 52:case 137:case 141:case 142:case 143:return value<=1;
    case 8:return value==2||value==3;
    case 9:return value==2;
    case 19:case 20:return value>=1&&value<=11;
    case 22:return value>=1&&value<=3;
    case 23:case 25:case 53:case 54:case 55:case 56:return value>=1&&value<=8;
    case 24:case 34:case 57:case 58:case 59:case 60:case 139:return YES;
    case 35:case 140:return value<=3;
    case 36:case 37:return isfinite(real(value));
    case 38:return isfinite(real(value))&&real(value)>=0&&real(value)<=1;
    case 145:case 146:case 147:case 148:return value<=2;
    case 168:return value<=15;
    case 171:return value>=1&&value<=5;
    default:return NO;
    }
}
static BOOL combiner_channel(uint32_t op,uint32_t first,uint32_t second,uint32_t third,BOOL alpha,BOOL *sample) {
    if(op<2||op>26||!(TC_TEXTURE_OPERATIONS&(1u<<(op-1)))||(alpha&&op>=18&&op<=21))return NO;
    uint32_t arguments[]={first,second,third};
    for(unsigned i=0;i<3;i++) {
        if((i==0&&op==3)||(i==1&&op==2)||(i==2&&op<25))continue;
        unsigned argument=arguments[i];if((argument&~0x3fu)||(argument&15)>5)return NO;
        *sample|=(argument&15)==2;
    }
    *sample|=op==13||op==15;return YES;
}
static BOOL texture_flags_valid(uint32_t flags) {
    unsigned count=flags&255;
    return !flags||(!(flags&~0x107u)&&count>=2&&count<=4);
}
static BOOL combiner_settings(TCMetal *g,unsigned index,BOOL bound,Combiner *result) {
    uint32_t *stage=g->stages[index];
    *result=(Combiner){{1,0,0,0},{2,0,0,0},rgba(g->render[60]),{stage[26],stage[27],stage[28],0}};
    if(stage[1]==1)return YES;
    BOOL sample=NO;
    if(!combiner_channel(stage[1],stage[2],stage[3],stage[26],NO,&sample)||
       !combiner_channel(stage[4],stage[5],stage[6],stage[27],YES,&sample)||(stage[28]!=1&&stage[28]!=5))return NO;
    /* A missing texture terminates the texture cascade. */
    if(sample&&!bound)return YES;
    if(sample&&((stage[11]&~0x30007u)||!texture_flags_valid(stage[24])))return NO;
    result->color=(vector_uint4){stage[1],stage[2],stage[3],0};
    result->alpha=(vector_uint4){stage[4],stage[5],stage[6],sample};return YES;
}
static BOOL light_valid(const Light *light) {
    const unsigned char *bytes=(const unsigned char *)light;
    for(unsigned i=4;i<sizeof(*light);i+=4){float value;memcpy(&value,bytes+i,4);if(!isfinite(value))return NO;}
    if(light->type<1||light->type>3)return NO;
    if(light->type!=1&&!light->direction[0]&&!light->direction[1]&&!light->direction[2])return NO;
    if(light->type!=3&&(light->range<0||light->range>sqrtf(FLT_MAX)||light->attenuation0<0||light->attenuation1<0||light->attenuation2<0||
       !(light->attenuation0||light->attenuation1||light->attenuation2)))return NO;
    return light->type!=2||(light->falloff>=0&&light->theta>=0&&light->theta<=light->phi&&light->phi<=M_PI);
}
static vector_float4 color_value(const float value[4]) {vector_float4 result;memcpy(&result,value,16);return result;}
static unsigned material_source(TCMetal *g,unsigned state,uint32_t fvf) {
    unsigned source=g->render[141]?g->render[state]:0;
    return (source==1&&!(fvf&64))||(source==2&&!(fvf&128))?0:source;
}
static Lighting lighting(TCMetal *g,uint32_t fvf,BOOL lit) {
    Lighting result={0};
    result.diffuse=color_value(g->material.diffuse);result.ambient=color_value(g->material.ambient);
    result.specular=color_value(g->material.specular);result.emissive=color_value(g->material.emissive);
    result.globalAmbient=rgba(g->render[139]);
    result.flags=(vector_uint4){lit,(unsigned)g.enabledLights.count,g->render[29],g->render[142]};
    result.sources=(vector_uint4){material_source(g,145,fvf),material_source(g,147,fvf),material_source(g,146,fvf),material_source(g,148,fvf)};
    result.parameters=(vector_float4){g->material.power,g->render[143],0,0};
    unsigned i=0;
    for(NSNumber *index in [[g.enabledLights allObjects]sortedArrayUsingSelector:@selector(compare:)]) {
        Light light;memcpy(&light,g.lights[index].bytes,sizeof(light));MetalLight *out=&result.lights[i++];
        out->diffuse=color_value(light.diffuse);out->ambient=color_value(light.ambient);out->specular=color_value(light.specular);
        out->position=simd_mul(g->view,(vector_float4){light.position[0],light.position[1],light.position[2],1});
        out->position.w=light.type;
        out->direction=simd_mul(g->view,(vector_float4){light.direction[0],light.direction[1],light.direction[2],0});
        out->direction.w=light.range;
        out->attenuation=(vector_float4){light.attenuation0,light.attenuation1,light.attenuation2,light.falloff};
        out->spot=(vector_float4){cosf(light.theta/2),cosf(light.phi/2),0,0};
    }
    return result;
}
typedef struct { vector_float4 position,color,specular,normal,viewPosition,uv[8]; } Vertex;
_Static_assert(sizeof(Vertex)==208,"Metal vertex layout");
typedef struct {matrix_float4x4 matrices[8];vector_uint4 settings[8];} TextureTransforms;
_Static_assert(sizeof(TextureTransforms)==640,"Metal texture transform layout");
static unsigned coordinate_size(uint32_t format,unsigned index) {
    static const unsigned sizes[]={2,3,4,1};return sizes[(format>>(16+index*2))&3];
}
static BOOL coordinate_source_valid(uint32_t source,uint32_t format) {
    unsigned generated=source>>16,index=source&0xffff;
    if(generated>3||index>=8)return NO;
    if(!generated)return index<((format>>8)&15);
    return (format&14)==2&&(generated==2||(format&16));
}
static unsigned vertex_size(uint32_t format) {
    unsigned pos=format&14,count=(format>>8)&15;
    if((pos!=2&&pos!=4)||count>8||((format&0xffff)&~(0xfd0u|pos))||
        (pos==4&&(format&16))||(count<8&&(format>>(16+count*2))))return 0;
    unsigned size=(pos==4?16:12)+(format&16?12:0)+(format&64?4:0)+(format&128?4:0);
    for(unsigned i=0;i<count;i++)size+=coordinate_size(format,i)*4;
    return size;
}
/* ponytail: fixed-function declarations are capped at 64 tokens; programmable
 * declarations and blend weights require additional renderer support. */
typedef struct {
    uint32_t tokens[64], tokenCount, format, required[16], offsets[15], sources[15];
} VertexDeclaration;
static BOOL declaration_layout(VertexDeclaration *d) {
    uint32_t seen=0,streamMask=0;unsigned stream=16;BOOL ended=NO;
    d->format=0;memset(d->required,0,sizeof(d->required));
    for(unsigned i=0;i<d->tokenCount;i++) {
        uint32_t token=d->tokens[i];
        if(token==UINT32_MAX){ended=i+1==d->tokenCount;break;}
        if(!token)continue;
        if((token&0xfffffff0u)==0x20000000u) {
            stream=token&15;if(streamMask&(1u<<stream))return NO;
            streamMask|=1u<<stream;continue;
        }
        if(stream==16)return NO;
        if((token&0xfff0ffffu)==0x50000000u) {
            if(token&~0x500f0000u)return NO;
            d->required[stream]+=((token>>16)&15)*4;continue;
        }
        if((token&0xfff0fff0u)!=0x40000000u)return NO;
        unsigned reg=token&15,type=(token>>16)&15,size=0;
        if(reg>=15||(seen&(1u<<reg)))return NO;
        if(reg==0&&type==2){d->format|=2;size=12;}
        else if(reg==3&&type==2){d->format|=16;size=12;}
        else if((reg==5||reg==6)&&type==4){d->format|=reg==5?64:128;size=4;}
        else if(reg>=7&&type<=3) {
            static const unsigned dimensions[]={3,0,1,2};
            d->format|=dimensions[type]<<(16+(reg-7)*2);size=(type+1)*4;
        } else return NO;
        seen|=1u<<reg;d->sources[reg]=stream;d->offsets[reg]=d->required[stream];d->required[stream]+=size;
    }
    if(!ended||!(seen&1))return NO;
    unsigned coordinates=0;
    while(coordinates<8&&(seen&(1u<<(7+coordinates))))coordinates++;
    if((seen>>7)!=((1u<<coordinates)-1))return NO;
    d->format|=coordinates<<8;
    return vertex_size(d->format)!=0;
}
typedef struct {
    matrix_float4x4 worldView, clip;
    matrix_float3x3 normal;
    vector_uint4 flags;
} Transforms;
_Static_assert(sizeof(Transforms)==192,"Metal transform uniform layout");
static Fog fog_settings(TCMetal *g,uint32_t format) {
    BOOL affine=g->projection.columns[0].w==0&&g->projection.columns[1].w==0&&
        g->projection.columns[2].w==0&&g->projection.columns[3].w==1;
    Fog result={rgba(g->render[34]),{real(g->render[36]),real(g->render[37]),real(g->render[38]),0},
        {g->render[28],g->render[35],(format&14)==4?0:g->render[140],(!affine?1u:0u)|(g->render[48]?2u:0u)}};
    return result;
}
static BOOL vertex_range(uint64_t length,unsigned required,unsigned stride,uint64_t index) {
    return stride>=required&&required&&index<=UINT32_MAX&&
        index*stride<=length&&required<=length-index*stride;
}
static uint32_t draw(tc_cpu *c, TCMetal *g, unsigned type, unsigned count, uint32_t address, unsigned stride,
    const unsigned char *indexData,unsigned indexSize,unsigned firstVertex,BOOL userMemory) {
    if(!g->scene || !count || !g.color || type<1 || type>6) return INVALID;
    uint64_t n=type==1 ? count : type==2 ? (uint64_t)count*2 : type==3 ? (uint64_t)count+1 : type==4 ? (uint64_t)count*3 : (uint64_t)count+2;
    uint64_t output=type==6 ? (uint64_t)count*3 : n;
    if(n>UINT32_MAX || output>UINT32_MAX || output>SIZE_MAX/sizeof(Vertex)) return INVALID;
    uint32_t f=g->vertexFormat, pos=f&14,coordinates=(f>>8)&15;
    BOOL lit=pos==2&&g->render[137];
    const VertexDeclaration *declaration=(const VertexDeclaration *)g.vertexDeclarations[@(g->vertexHandle)].bytes;
    if(!vertex_size(f)||(lit&&!(f&16)))return UNAVAILABLE;
    uint32_t addresses[16]={0},strides[16]={0},required[16]={0};uint64_t lengths[16]={0};
    if(declaration)memcpy(required,declaration->required,sizeof(required));else required[0]=vertex_size(f);
    for(unsigned stream=0;stream<16;stream++)if(required[stream]) {
        if(userMemory) {
            if(stream||!address||!stride||address>=c->memory_size)return INVALID;
            addresses[0]=address;strides[0]=stride;lengths[0]=c->memory_size-address;
        } else {
            TCGraphicsObject *buffer=g.objects[@(g->streams[stream])];
            if(!buffer||buffer.kind!=2||buffer.locked)return INVALID;
            addresses[stream]=buffer.data;strides[stream]=g->strides[stream];lengths[stream]=buffer.length;
        }
    }
    id<MTLBuffer> vb=[g.device newBufferWithLength:output*sizeof(Vertex) options:MTLResourceStorageModeShared];
    if(!vb) return OOM;
    Vertex *dst=vb.contents;
    matrix_float4x4 worldView=simd_mul(g->view,g->world),transform=simd_mul(g->projection,worldView);
    matrix_float3x3 normalTransform={.columns={worldView.columns[0].xyz,worldView.columns[1].xyz,worldView.columns[2].xyz}};
    BOOL normalNeeded=lit;
    for(uint64_t j=0;j<output;j++) {
        uint64_t i=type==6 ? (j%3==0 ? 0 : j/3+1+(j%3==2)) : j;
        uint32_t index=0;if(indexData)memcpy(&index,indexData+i*indexSize,indexSize);
        uint64_t sourceIndex=(indexData?index:i)+(uint64_t)firstVertex;
        const unsigned char *sources[16]={0};
        for(unsigned stream=0;stream<16;stream++)if(required[stream]) {
            if(!vertex_range(lengths[stream],required[stream],strides[stream],sourceIndex))return INVALID;
            sources[stream]=mem(c,(uint64_t)addresses[stream]+sourceIndex*strides[stream],required[stream]);
        }
        const unsigned char *v=sources[0];float xyz[4]={0,0,0,1};
        if(declaration)v=sources[declaration->sources[0]]+declaration->offsets[0];
        memcpy(xyz,v,pos==4?16:12); v+=pos==4?16:12;
        vector_float4 p={xyz[0],xyz[1],xyz[2],1};
        dst[j].viewPosition=0;dst[j].normal=0;dst[j].specular=0;
        if(pos==4) {
            if(!isfinite(xyz[3]) || xyz[3]==0) return INVALID;
            float w=1/xyz[3];
            p=(vector_float4){(2*(xyz[0]-g->viewport[0]+0.5f)/g->viewport[2]-1)*w,
                (1-2*(xyz[1]-g->viewport[1]+0.5f)/g->viewport[3])*w,xyz[2]*w,w};
        }
        dst[j].position=p; dst[j].color=(vector_float4){1,1,1,1}; memset(dst[j].uv,0,sizeof(dst[j].uv));
        if(f&16) {
            if(declaration)v=sources[declaration->sources[3]]+declaration->offsets[3];
            float values[3];memcpy(values,v,12);v+=12;
            dst[j].normal=(vector_float4){values[0],values[1],values[2],0};
        }
        if(f&64) { if(declaration)v=sources[declaration->sources[5]]+declaration->offsets[5];uint32_t color; memcpy(&color,v,4); v+=4;dst[j].color=rgba(color); }
        if(f&128) {if(declaration)v=sources[declaration->sources[6]]+declaration->offsets[6];uint32_t color;memcpy(&color,v,4);v+=4;dst[j].specular=rgba(color);}
        for(unsigned coordinate=0;coordinate<coordinates;coordinate++) {
            if(declaration)v=sources[declaration->sources[7+coordinate]]+declaration->offsets[7+coordinate];
            unsigned size=coordinate_size(f,coordinate)*4;
            memcpy(&dst[j].uv[coordinate],v,size);v+=size;
        }
    }
    MTLBlendFactor source,destination;
    if(!blend(g->render[19],&source) || !blend(g->render[20],&destination) ||
       g->render[22]<1 || g->render[22]>3 || g->render[23]<1 || g->render[23]>8) return UNAVAILABLE;
    Combiner combiners[8]={0};float lodBias[8]={0};TextureTransforms textureTransforms={0};
    memcpy(textureTransforms.matrices,g->textureMatrices,sizeof(g->textureMatrices));
    id<MTLTexture> textures[8]={nil};id<MTLSamplerState> samplers[8]={nil};
    for(unsigned i=0;i<8;i++) {
        TCGraphicsObject *texture=g.objects[@(g->boundTexture[i])];
        Combiner *combiner=&combiners[i];uint32_t *stage=g->stages[i];
        if(!combiner_settings(g,i,texture!=nil,combiner))return UNAVAILABLE;
        if(combiner->color.x==1)break;
        if(!combiner->alpha.w)continue;
        if(!texture.texture||texture.locked||!coordinate_source_valid(stage[11],f))return UNAVAILABLE;
        unsigned generated=stage[11]>>16;
        normalNeeded|=generated==1||generated==3;
        textureTransforms.settings[i]=(vector_uint4){stage[11],generated?3:coordinate_size(f,stage[11]),stage[24],1};
        if(texture.texture==g.color||texture.texture==g.color.parentTexture)return INVALID;
        combiner->color.w|=texture.format==22;
        if(stage[13]<1||stage[13]>3||stage[14]<1||stage[14]>3||
            stage[16]<1||stage[16]>2||stage[17]<1||stage[17]>2||stage[18]>2||!isfinite(real(stage[19])))return UNAVAILABLE;
        /* Forced 16x anisotropic filtering on linear, mipmapped minification. */
        uint32_t lodMin=MIN(MAX(texture.lod,stage[20]),texture.levels-1),lodMax=texture.levels-1;
        BOOL anisotropic=stage[17]==2&&stage[18]&&texture.levels>1;
        NSNumber *samplerKey=@(stage[13]|stage[14]<<2|stage[16]<<4|stage[17]<<6|stage[18]<<8|lodMin<<10|lodMax<<14|(uint32_t)anisotropic<<18);
        samplers[i]=g.samplers[samplerKey];
        if(!samplers[i]) {
            MTLSamplerDescriptor *s=[MTLSamplerDescriptor new];
            MTLSamplerAddressMode modes[]={0,MTLSamplerAddressModeRepeat,MTLSamplerAddressModeMirrorRepeat,MTLSamplerAddressModeClampToEdge};
            s.sAddressMode=modes[stage[13]];s.tAddressMode=modes[stage[14]];
            s.magFilter=stage[16]==2?MTLSamplerMinMagFilterLinear:MTLSamplerMinMagFilterNearest;
            s.minFilter=stage[17]==2?MTLSamplerMinMagFilterLinear:MTLSamplerMinMagFilterNearest;
            s.mipFilter=stage[18]==2?MTLSamplerMipFilterLinear:stage[18]==1?MTLSamplerMipFilterNearest:MTLSamplerMipFilterNotMipmapped;
            s.lodMinClamp=lodMin;s.lodMaxClamp=lodMax;s.maxAnisotropy=anisotropic?16:1;
            samplers[i]=[g.device newSamplerStateWithDescriptor:s];if(!samplers[i])return OOM;
            g.samplers[samplerKey]=samplers[i];
        }
        textures[i]=texture.texture;lodBias[i]=real(stage[19]);
    }
    if(normalNeeded) {
        float determinant=simd_determinant(normalTransform);if(!isfinite(determinant)||determinant==0)return INVALID;
        normalTransform=simd_transpose(simd_inverse(normalTransform));
    }
    /* 2D after 3D: upscale the scene now and draw HUD/menus at output resolution. */
    if(pos==4&&g.scaler&&!g->nativePhase&&scaled_target(g)){resolve_scaled(g);g->nativePhase=YES;}
    id<MTLRenderCommandEncoder> e=encoder(g,0,0,1,0); if(!e) return LOST;
    /* Alpha-tested, unblended cutouts (fences, foliage) antialias through coverage. */
    BOOL coverage=g->passSamples>1&&g->render[15]&&!g->render[27]&&(g->render[25]==5||g->render[25]==7);
    id<MTLRenderPipelineState> pipeline=pipeline_state(g,pipeline_key(g->render,g.depth!=nil,g->passSamples,coverage),YES);
    if(!pipeline) return UNAVAILABLE;
    BOOL depthTest=g.depth&&g->render[7],stencilTest=g.depth&&g->render[52];
    uint64_t depthKey=(depthTest?g->render[23]-1:MTLCompareFunctionAlways)|(uint64_t)(depthTest&&g->render[14])<<3;
    if(stencilTest)depthKey|=1ull<<4|(uint64_t)(g->render[56]-1)<<5|(uint64_t)(g->render[53]-1)<<8|(uint64_t)(g->render[54]-1)<<11|
        (uint64_t)(g->render[55]-1)<<14|(uint64_t)(g->render[58]&255)<<17|(uint64_t)(g->render[59]&255)<<25;
    id<MTLDepthStencilState> depth=g.depthStates[@(depthKey)];
    if(!depth) {
        MTLDepthStencilDescriptor *d=[MTLDepthStencilDescriptor new];
        d.depthCompareFunction=(MTLCompareFunction)(depthKey&7);d.depthWriteEnabled=(depthKey>>3)&1;
        if(stencilTest) {
            MTLStencilDescriptor *stencil=[MTLStencilDescriptor new];
            stencil.stencilCompareFunction=(MTLCompareFunction)(g->render[56]-1);
            stencil.stencilFailureOperation=(MTLStencilOperation)(g->render[53]-1);
            stencil.depthFailureOperation=(MTLStencilOperation)(g->render[54]-1);
            stencil.depthStencilPassOperation=(MTLStencilOperation)(g->render[55]-1);
            stencil.readMask=g->render[58]&255;stencil.writeMask=g->render[59]&255;
            d.frontFaceStencil=d.backFaceStencil=stencil;
        }
        depth=[g.device newDepthStencilStateWithDescriptor:d];
        if(!depth) return OOM;
        g.depthStates[@(depthKey)]=depth;
    }
    [e setRenderPipelineState:pipeline]; [e setDepthStencilState:depth];
    [e setStencilReferenceValue:g->render[57]&255];
    [e setTriangleFillMode:g->render[8]==2?MTLTriangleFillModeLines:MTLTriangleFillModeFill];
    id<MTLTexture> drawn=g->nativePhase?g.outputColor:g.scaledColor;
    double sx=scaled_target(g)?(double)drawn.width/g.backBuffer.width:1;
    double sy=scaled_target(g)?(double)drawn.height/g.backBuffer.height:1;
    [e setViewport:(MTLViewport){g->viewport[0]*sx,g->viewport[1]*sy,g->viewport[2]*sx,g->viewport[3]*sy,real(g->viewport[4]),real(g->viewport[5])}];
    [e setFrontFacingWinding:MTLWindingClockwise];
    [e setCullMode:g->render[22]==1?MTLCullModeNone:g->render[22]==2?MTLCullModeFront:MTLCullModeBack];
    [e setVertexBuffer:vb offset:0 atIndex:0];
    Transforms transforms={worldView,transform,normalTransform,{pos==4,(f&128)!=0,0,0}};
    [e setVertexBytes:&transforms length:sizeof(transforms) atIndex:3];
    [e setVertexBytes:&textureTransforms length:sizeof(textureTransforms) atIndex:4];
    Lighting illumination=lighting(g,f,lit);[e setVertexBytes:&illumination length:sizeof(illumination) atIndex:1];
    Fog fog=fog_settings(g,f);[e setVertexBytes:&fog length:sizeof(fog) atIndex:2];
    [e setFragmentBytes:&fog length:sizeof(fog) atIndex:3];
    [e setFragmentBytes:combiners length:sizeof(combiners) atIndex:0];
    uint32_t alphaTest[4]={g->render[15],g->render[25],g->render[24]&255,coverage};
    [e setFragmentBytes:alphaTest length:sizeof(alphaTest) atIndex:2];
    [e setFragmentBytes:lodBias length:sizeof(lodBias) atIndex:1];
    [e setFragmentTextures:textures withRange:NSMakeRange(0,8)];
    /* Unused stages still need a bound sampler for Metal validation. */
    for(unsigned i=0;i<8;i++)if(!samplers[i]) {
        samplers[i]=g.samplers[@UINT32_MAX];
        if(!samplers[i]){samplers[i]=[g.device newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];if(!samplers[i])return OOM;g.samplers[@UINT32_MAX]=samplers[i];}
    }
    [e setFragmentSamplerStates:samplers withRange:NSMakeRange(0,8)];
    MTLPrimitiveType types[]={0,MTLPrimitiveTypePoint,MTLPrimitiveTypeLine,MTLPrimitiveTypeLineStrip,MTLPrimitiveTypeTriangle,MTLPrimitiveTypeTriangleStrip,MTLPrimitiveTypeTriangle};
    [e drawPrimitives:types[type] vertexStart:0 vertexCount:output];return 0;
}
static uint32_t indexed(tc_cpu *c, TCMetal *g, unsigned type, unsigned primitives,
    unsigned minimum, unsigned vertices, uint32_t indexAddress, unsigned format,
    uint32_t vertexAddress, unsigned stride, unsigned base, BOOL userMemory) {
    if(type<1 || type>6 || !primitives || !vertices || (format!=101 && format!=102)) return INVALID;
    uint64_t count=type==1?primitives:type==2?(uint64_t)primitives*2:
        type==3?(uint64_t)primitives+1:type==4?(uint64_t)primitives*3:(uint64_t)primitives+2;
    if(count>UINT32_MAX)return INVALID;
    unsigned size=format==101?2:4;
    const unsigned char *input=mem(c,indexAddress,count*size);
    for(uint64_t i=0;i<count;i++) {
        uint32_t index=0;memcpy(&index,input+i*size,size);
        if(index<minimum || (uint64_t)index>=((uint64_t)minimum+vertices))return INVALID;
    }
    /* Each source uses the same original index, including triangle-fan expansion. */
    return draw(c,g,type,primitives,vertexAddress,stride,input,size,base,userMemory);
}
static void bind_object(tc_cpu *c, TCMetal *g, uint32_t *slot, uint32_t value) {
    bind_surface(c,g,slot,g.objects[@(value)]);
}
static BOOL buffer_options(uint32_t usage,uint32_t pool) {
    return !(usage&~0x208u)&&pool<=2&&(!(usage&0x200)||pool!=1);
}
static BOOL buffer_lock_valid(TCGraphicsObject *buffer,uint32_t offset,uint32_t length,uint32_t flags) {
    if(buffer.locked||offset>buffer.length||length>buffer.length-offset||(flags&~0x3810u))return NO;
    if((flags&0x3000)&&(!(buffer.usage&0x200)||(flags&0x10)))return NO;
    if((flags&0x3000)==0x3000)return NO;
    return !(flags&0x10)||!(buffer.usage&8);
}
/* Expose modern modes to the original Display menu without changing the
 * physical macOS display mode. */
static const uint32_t adapter_modes[][4]={
    {640,480,60,22},{800,600,60,22},{1024,768,60,22},
    {1152,864,60,22},{1280,960,60,22},{1280,720,60,22},
    {1920,1080,60,22},{2560,1440,60,22},{3840,2160,60,22}
};
#define TC_ADAPTER_MODE_COUNT (sizeof(adapter_modes)/sizeof(adapter_modes[0]))
static uint32_t lock_pixels(tc_cpu *c,TCGraphicsObject *o,unsigned level,uint32_t out,uint32_t rectangle,unsigned flags) {
    if(!out||!o.data)return INVALID;
    if((o.usage&1)||level>=o.levels||(o->lockedLevels&(1u<<level))||(flags&~0x2810u))return INVALID;
    if((flags&0x2000)&&(!(o.usage&0x200)||rectangle))return INVALID;
    unsigned w=mip_dimension(o.width,level),h=mip_dimension(o.height,level),x=0,y=0;
    if(rectangle) {
        int32_t r[4];memcpy(r,mem(c,rectangle,16),16);
        if(r[0]<0||r[1]<0||r[2]<=r[0]||r[3]<=r[1]||(uint32_t)r[2]>w||(uint32_t)r[3]>h)return INVALID;
        if(compressed(o.format)&&(r[0]%4||r[1]%4||(r[2]%4&&(unsigned)r[2]!=w)||(r[3]%4&&(unsigned)r[3]!=h)))return INVALID;
        x=(unsigned)r[0];y=(unsigned)r[1];
    }
    uint32_t offset=compressed(o.format)?y/4*o->mipPitch[level]+x/4*block_size(o.format):y*o->mipPitch[level]+x*(o.format<=22?4:2);
    uint32_t lock[]={o->mipPitch[level],o.data+o->mipOffset[level]+offset};
    memcpy(mem(c,out,8),lock,8);o->lockedLevels|=1u<<level;o.locked=YES;return 0;

}
static uint32_t unlock_pixels(tc_cpu *c,TCMetal *g,TCGraphicsObject *o,unsigned level) {
    if(level>=o.levels||!(o->lockedLevels&(1u<<level)))return INVALID;
    if(o.kind==4&&o.pool!=2) {
        /* Keep submitted draws on their previous texture snapshot. */
        id<MTLTexture> texture=upload_texture(c,g,o);if(!texture)return OOM;
        o.texture=texture;
    }
    o->lockedLevels&=~(1u<<level);o.locked=o->lockedLevels!=0;return 0;
}
typedef struct {uint32_t x,y,width,height,dx,dy;} CopyRegion;
static BOOL copy_region(TCGraphicsObject *source,TCGraphicsObject *destination,
    const int32_t *rectangle,const int32_t *point,CopyRegion *out) {
    int32_t full[]={0,0,(int32_t)source.width,(int32_t)source.height};
    const int32_t *r=rectangle?:full;
    int64_t dx=point?point[0]:r[0],dy=point?point[1]:r[1];
    int64_t w=(int64_t)r[2]-r[0],h=(int64_t)r[3]-r[1];
    if(r[0]<0||r[1]<0||w<=0||h<=0||r[2]>source.width||r[3]>source.height||
        dx<0||dy<0||dx+w>destination.width||dy+h>destination.height)return NO;
    if(compressed(source.format)&&(r[0]%4||r[1]%4||dx%4||dy%4||
        (w%4&&(r[2]!=source.width||dx+w!=destination.width))||
        (h%4&&(r[3]!=source.height||dy+h!=destination.height))))return NO;
    *out=(CopyRegion){r[0],r[1],(uint32_t)w,(uint32_t)h,(uint32_t)dx,(uint32_t)dy};return YES;
}
static uint32_t copy_rects(tc_cpu *c,TCMetal *g,TCGraphicsObject *device,
    TCGraphicsObject *source,uint32_t rectangles,uint32_t count,TCGraphicsObject *destination,uint32_t points) {
    if(!source||!destination||source==destination||source.kind!=5||destination.kind!=5||
        owning_device(g,source)!=device||owning_device(g,destination)!=device||
        source.format!=destination.format||!texture_format(source.format))return INVALID;
    end_pass(g);
    TCGraphicsObject *sp=g.objects[@(source.parent)],*dp=g.objects[@(destination.parent)];
    TCGraphicsObject *ss=sp.kind==4?sp:source,*ds=dp.kind==4?dp:destination;
    unsigned sl=sp.kind==4?source.surfaceLevel:0,dl=dp.kind==4?destination.surfaceLevel:0;
    if((ss->lockedLevels&(1u<<sl))||(ds->lockedLevels&(1u<<dl)))return INVALID;
    if(!rectangles)count=1;
    if(!count)return 0;
    if(count>c->memory_size/sizeof(CopyRegion))return INVALID;
    const int32_t *rs=rectangles?mem(c,rectangles,(uint64_t)count*16):NULL;
    const int32_t *ps=points?mem(c,points,(uint64_t)count*8):NULL;
    NSMutableData *regions=[NSMutableData dataWithLength:(NSUInteger)count*sizeof(CopyRegion)];
    if(!regions)return OOM;CopyRegion *copies=regions.mutableBytes;
    for(uint32_t i=0;i<count;i++)if(!copy_region(source,destination,rs?rs+i*4:NULL,ps?ps+i*2:NULL,copies+i))return INVALID;
    if(!ds.data) {
        id<MTLTexture> from=source.texture;unsigned level=0;
        if(ss.data){from=upload_texture(c,g,ss);level=sl;}
        id<MTLTexture> to=destination.texture;
        if(!from||!to)return ss.data?OOM:INVALID;
        if(from==to||from.pixelFormat!=to.pixelFormat)return INVALID;
        if(!g.command)g.command=[g.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit=[g.command blitCommandEncoder];if(!blit)return LOST;
        for(uint32_t i=0;i<count;i++) {
            CopyRegion r=copies[i];
            [blit copyFromTexture:from sourceSlice:0 sourceLevel:level sourceOrigin:MTLOriginMake(r.x,r.y,0)
                sourceSize:MTLSizeMake(r.width,r.height,1) toTexture:to destinationSlice:0 destinationLevel:0
                destinationOrigin:MTLOriginMake(r.dx,r.dy,0)];
        }
        [blit endEncoding];return 0;
    }
    const unsigned char *input;unsigned pitch;
    id<MTLBuffer> readback=nil;
    if(ss.data){input=mem(c,ss.data+ss->mipOffset[sl],ss->mipSize[sl]);pitch=ss->mipPitch[sl];}
    else {
        if(!source.texture||(source.format!=21&&source.format!=22))return INVALID;
        pitch=(source.width*4+255)&~255u;
        readback=[g.device newBufferWithLength:(NSUInteger)pitch*source.height options:MTLResourceStorageModeShared];
        if(!readback)return OOM;
        if(!g.command)g.command=[g.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit=[g.command blitCommandEncoder];if(!blit)return LOST;
        [blit copyFromTexture:source.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(source.width,source.height,1) toBuffer:readback destinationOffset:0
            destinationBytesPerRow:pitch destinationBytesPerImage:(NSUInteger)pitch*source.height];
        [blit endEncoding];[g.command commit];[g.command waitUntilCompleted];
        BOOL failed=g.command.status==MTLCommandBufferStatusError;g.command=nil;if(failed)return LOST;
        input=readback.contents;
    }
    /* Stage the entire CPU allocation so failed uploads leave destination data
     * unchanged, and earlier submitted draws retain their texture snapshots. */
    NSMutableData *staged=[NSMutableData dataWithBytes:mem(c,ds.data,ds.length) length:ds.length];
    if(!staged)return OOM;
    unsigned char *output=(unsigned char *)staged.mutableBytes+ds->mipOffset[dl];
    unsigned unit=compressed(source.format)?4:1;
    unsigned bytes=compressed(source.format)?block_size(source.format):source.format<=22?4:2;
    for(uint32_t i=0;i<count;i++) {
        CopyRegion r=copies[i];unsigned rows=(r.height+unit-1)/unit,rowBytes=(r.width+unit-1)/unit*bytes;
        for(unsigned y=0;y<rows;y++)memcpy(output+(r.dy/unit+y)*ds->mipPitch[dl]+r.dx/unit*bytes,
            input+(r.y/unit+y)*pitch+r.x/unit*bytes,rowBytes);
    }
    id<MTLTexture> replacement=nil;
    if(ds.kind==4&&ds.pool!=2){replacement=upload_texture_bytes(g,ds,staged.bytes);if(!replacement)return OOM;}
    memcpy(mem(c,ds.data,ds.length),staged.bytes,ds.length);
    if(replacement)ds.texture=replacement;
    return 0;
}
static uint32_t dispatch(tc_cpu *c, TCMetal *g, unsigned kind, unsigned m) {
    TCGraphicsObject *o=g.objects[@(arg(c,0))];
    if(!o || o.kind!=kind) return INVALID;
#define A(n) arg(c,n)
    static const unsigned char ids[6][16]={
            {0xda,0xe8,0xd9,0x1d,0x77,0x1c,0x40,0x4d,0xb0,0xcf,0x98,0xfe,0xfd,0xff,0x95,0x12},
            {0xdf,0xe5,0x85,0x73,0xe8,0x8f,0xd5,0x41,0x86,0xb6,0xd7,0xb4,0x85,0x47,0xb6,0xcf},
            {0xc7,0xea,0xee,0x8a,0xf9,0x05,0xd4,0x44,0xb5,0x91,0,0x0b,0xd,0xf1,0xcb,0x95},
            {0x9a,0x9c,0x68,0x0e,0x3d,0x05,0xa0,0x44,0x9d,0x92,0xdb,0x0e,0x3d,0x75,0x0f,0x86},
            {0x75,0xd5,0xcd,0xe4,0x66,0x28,0x01,0x4f,0xb1,0x2e,0x7e,0xec,0xe1,0xec,0x93,0x58},
            {0xca,0xeb,0x6e,0xb9,0x26,0xb3,0xa5,0x4e,0x88,0x2f,0x2f,0xf5,0xba,0xe0,0x21,0xdd}};
        static const unsigned char unknown[16]={0,0,0,0,0,0,0,0,0xc0,0,0,0,0,0,0,0x46};
    if(m==0) {
        if(!A(1)||!A(2))return INVALID;
        const void *id=mem(c,A(1),16);put(c,A(2),0);
        if(memcmp(id,unknown,16)&&memcmp(id,ids[kind],16))return 0x80004002u;
        retain_object(g,o);put(c,A(2),o.address);return 0;
    }
    if((kind==0&&m==13)||(kind==1&&m==7)) {
        if(kind==0&&(A(1)||A(2)!=1))return INVALID;
        /* XYZ transforms and fixed-function lighting execute in the Metal
         * vertex shader. D3DCAPS8, 53 DWORD-sized fields;
         * shader version zero means programmable shaders are unavailable. */
        uint32_t caps[53]={
            [0]=1,[5]=0x80000001u,[7]=TC_DEVICE_CAPABILITIES,[8]=0xcf0,[9]=0x310190,
            [10]=0xff,[11]=0x7ff,[12]=0x7ff,[13]=0xff,[34]=0xff,[15]=0x4005,[16]=0x03030300,[19]=0x17,
            [22]=16384,[23]=16384,[25]=8192,[26]=16384,[27]=1,[28]=0x7f7fffff,
            [14]=0x80208,[35]=8,[36]=TC_TEXTURE_OPERATIONS,[37]=8,[38]=8,[39]=0x3b,[40]=8,[44]=0x3f800000,[45]=1048575,
            [46]=0xffffff,[47]=16,[48]=2048};
        memcpy(mem(c,A(kind==0?3:1),sizeof(caps)),caps,sizeof(caps));return 0;
    }
    if(m==1) return retain_object(g,o);
    if(m==2) { uint32_t remaining=o.references-1; release_object(c,g,o); return remaining; }
    if(kind==0) {
        switch(m) {
        case 4: return 1;
        case 5: {
            if(A(1))return INVALID;
            unsigned char identifier[1068]={0};
            const char *driver="Native Metal",*description="True Crime Metal renderer";
            memcpy(identifier,driver,strlen(driver));memcpy(identifier+512,description,strlen(description));
            memcpy(mem(c,A(3),sizeof(identifier)),identifier,sizeof(identifier));return 0;
        }
        case 6: return A(1)==0 ? TC_ADAPTER_MODE_COUNT:0;
        case 7:
            if(A(1)||A(2)>=TC_ADAPTER_MODE_COUNT)return INVALID;
            {uint32_t mode[4];memcpy(mode,adapter_modes[A(2)],16);tc_modern_virtual_mode(c,&mode[0],&mode[1]);
            memcpy(mem(c,A(3),16),mode,16);}return 0;
        case 8: {
            if(A(1))return INVALID;
            uint32_t mode[]={1280,720,60,22};memcpy(mem(c,A(2),16),mode,16);return 0;
        }
        case 9: return !A(1) && A(2)==1 && (A(3)==21 || A(3)==22) && (A(4)==21 || A(4)==22) ? 0:UNAVAILABLE;
        case 10: return !A(1)&&A(2)==1&&((A(5)==3&&!(A(4)&~0x201u)&&(!(A(4)&1)||(!(A(4)&0x200)&&(A(6)==21||A(6)==22)))&&texture_format(A(6))&&
            (!compressed(A(6))||g.device.supportsBCTextureCompression))||
            ((A(5)==6||A(5)==7)&&buffer_options(A(4),0)&&
             (A(5)==6?A(6)==100:(A(6)==101||A(6)==102)))||
            (A(5)==1&&((A(4)==2&&A(6)==75)||(A(4)==1&&(A(6)==21||A(6)==22)))))?0:UNAVAILABLE;
        case 11: return !A(1) && A(2)==1 && !A(5) ? 0:UNAVAILABLE;
        case 12: return !A(1) && A(2)==1 && A(5)==75 ? 0:UNAVAILABLE;
        case 14: return 0;
        case 15: {
            put(c,A(6),0);
            if(g->deviceAddress || A(1) || A(2)!=1 || !reset_guest_device(c,g,A(5))) return UNAVAILABLE;
            TCGraphicsObject *d=object(c,g,1); if(!d) return OOM;
            g->deviceAddress=d.address;put(c,A(6),d.address); return 0;
        }
        default:return UNAVAILABLE;
        }
    }
    if(kind>=2&&m==3) {
        if(!A(1))return INVALID;put(c,A(1),0);
        TCGraphicsObject *device=owning_device(g,o);if(!device||device.kind!=1)return INVALID;
        retain_object(g,device);put(c,A(1),device.address);return 0;
    }
    if(kind==5) {
        if(m==7) {
            if(!A(1)||!A(2))return INVALID;put(c,A(2),0);
            TCGraphicsObject *parent=g.objects[@(o.parent)];if(!parent)return INVALID;
            const void *id=mem(c,A(1),16);
            if(memcmp(id,unknown,16)&&memcmp(id,ids[parent.kind],16))return 0x80004002u;
            retain_object(g,parent);put(c,A(2),parent.address);return 0;
        }
        if(m==8) {
            if(!A(1))return INVALID;
            uint32_t desc[]={o.format,1,o.usage,o.pool,o.length,0,o.width,o.height};
            memcpy(mem(c,A(1),sizeof(desc)),desc,sizeof(desc));return 0;
        }
        if(m==9||m==10) {
            TCGraphicsObject *parent=g.objects[@(o.parent)];
            TCGraphicsObject *storage=parent.kind==4?parent:o;
            unsigned level=parent.kind==4?o.surfaceLevel:0;
            return m==9?lock_pixels(c,storage,level,A(1),A(2),A(3)):unlock_pixels(c,g,storage,level);
        }
        return UNAVAILABLE;
    }
    if(kind==2 || kind==3) {
        switch(m) {
        case 10:return kind==2?6:7;
        case 11: {
            uint32_t offset=A(1),length=A(2),flags=A(4);
            if(!A(3))return INVALID;put(c,A(3),0);
            if(!buffer_lock_valid(o,offset,length,flags))return INVALID;
            /* Draws copy vertices/indices into independent Metal buffers before
               submission. DISCARD can reuse this CPU allocation safely, while
               NOOVERWRITE preserves it; neither touches an in-flight draw. */
            if(flags&0x2000)memset(mem(c,o.data,o.length),0,o.length);
            o.locked=YES; put(c,A(3),o.data+offset); return 0;
        }
        case 12:if(!o.locked)return INVALID;o.locked=NO;return 0;
        case 13: {
            uint32_t desc[]={o.format,kind==2?6:7,o.usage,o.pool,o.length,o.fvf};
            memcpy(mem(c,A(1),kind==2?24:20),desc,kind==2?24:20);return 0;
        }
        default:return UNAVAILABLE;
        }
    }
    if(kind==4) {
        switch(m) {
        case 10:return 3;
        case 11:{uint32_t old=o.lod;if(o.pool==1)o.lod=MIN(A(1),o.levels-1);return old;}
        case 12:return o.lod;
        case 13:return o.levels;
        case 14: {
            unsigned level=A(1);if(level>=o.levels)return INVALID;
            uint32_t desc[]={o.format,1,o.usage,o.pool,o->mipSize[level],0,mip_dimension(o.width,level),mip_dimension(o.height,level)};
            memcpy(mem(c,A(2),32),desc,32);return 0;
        }
        case 15: {
            if(!A(2))return INVALID;put(c,A(2),0);unsigned level=A(1);
            if(level>=o.levels)return INVALID;

            for(TCGraphicsObject *surface in g.objects.allValues)
                if(surface.kind==5&&surface.parent==o.address&&surface.surfaceLevel==level) {
                    retain_object(g,surface);put(c,A(2),surface.address);return 0;
                }
            if(!(o.usage&1)) {
                TCGraphicsObject *surface=object(c,g,5);if(!surface)return OOM;
                surface.parent=o.address;retain_object(g,o);retain_internal(o);
                surface.width=mip_dimension(o.width,level);surface.height=mip_dimension(o.height,level);
                surface.format=o.format;surface.pool=o.pool;surface.usage=o.usage;
                surface.length=o->mipSize[level];surface.surfaceLevel=level;
                put(c,A(2),surface.address);return 0;
            }
            id<MTLTexture> view=[o.texture newTextureViewWithPixelFormat:o.texture.pixelFormat
                textureType:MTLTextureType2D levels:NSMakeRange(level,1) slices:NSMakeRange(0,1)];
            if(!view)return OOM;
            TCGraphicsObject *surface=surface_object(c,g,o,view,o.format,NO);if(!surface)return OOM;
            surface.surfaceLevel=level;put(c,A(2),surface.address);return 0;
        }
        case 16:return lock_pixels(c,o,A(1),A(2),A(3),A(4));
        case 17:return unlock_pixels(c,g,o,A(1));
        default:return UNAVAILABLE;
        }
    }
    switch(m) {
    case 3:return 0;
    case 4: {
        uint64_t budget=g.device.recommendedMaxWorkingSetSize,used=g.device.currentAllocatedSize;
        return (uint32_t)(MIN(budget>used?budget-used:0,UINT32_MAX)&~((UINT64_C(1)<<20)-1));
    }
    case 14:if(g->scene)return INVALID;return reset_guest_device(c,g,A(1))?0:UNAVAILABLE;
    case 15:if(A(1)||A(2)||A(3)||A(4)||g->scene)return INVALID;return present(c,g);
    case 16:case 32:case 33: {
        uint32_t out=A(m==16?3:1);if(!out)return INVALID;put(c,out,0);
        if(m==16&&(A(1)||A(2)))return INVALID;
        BOOL depth=m==33;
        id<MTLTexture> texture=m==16?g.backBuffer:depth?g.depth:g.color;
        if(!texture)return depth?0x88760866u:INVALID;
        uint32_t *slot=m==16?&g->backSurface:depth?&g->targetDepth:&g->targetSurface;
        TCGraphicsObject *surface=g.objects[@(*slot)];
        if(!surface)for(TCGraphicsObject *candidate in g.objects.allValues)
            if(candidate.kind==5&&candidate.texture==texture){surface=candidate;break;}
        if(surface)retain_object(g,surface);
        else {
            surface=surface_object(c,g,o,texture,depth?75:m==16?g->backFormat:g->targetFormat,depth);
            if(!surface)return OOM;
        }
        if(m==16)g->backSurface=surface.address;
        if(texture==g.defaultDepth)g->depthSurface=surface.address;
        if(texture==g.color&&!g->targetSurface)bind_surface(c,g,&g->targetSurface,surface);
        if(texture==g.depth&&!g->targetDepth)bind_surface(c,g,&g->targetDepth,surface);
        put(c,out,surface.address);return 0;
    }
    case 20: {
        put(c,A(7),0);uint32_t w=A(1),h=A(2);
        if(!w||!h||w>16384||h>16384||(A(4)&~0x201u)||A(6)>2||
           ((A(4)&0x201)&&A(6)!=0)||((A(4)&1)&&((A(4)&0x200)||(A(5)!=21&&A(5)!=22)))||!texture_format(A(5))||
           (compressed(A(5))&&!g.device.supportsBCTextureCompression))return UNAVAILABLE;
        TCGraphicsObject *t=object(c,g,4);if(!t)return OOM;
        t.parent=o.address;retain_object(g,o);
        t.width=w;t.height=h;t.format=A(5);t.levels=A(3);t.pool=A(6);t.usage=A(4);
        if(!texture_layout(t)){release_object(c,g,t);return INVALID;}
        if(t.usage&1) {
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:w height:h mipmapped:t.levels>1];
            d.mipmapLevelCount=t.levels;d.storageMode=MTLStorageModePrivate;
            d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
            t.texture=[g.device newTextureWithDescriptor:d];
            if(!t.texture){release_object(c,g,t);return OOM;}
        } else {
            t.data=alloc(c,g,t.length);if(!t.data){release_object(c,g,t);return OOM;}
        }
        put(c,A(7),t.address);return 0;
    }
    case 23:case 24: {
        put(c,A(5),0);
        if(!A(1)||!buffer_options(A(2),A(4))||(m==24&&A(3)!=101&&A(3)!=102))return UNAVAILABLE;
        TCGraphicsObject *b=object(c,g,m==23?2:3);if(!b)return OOM;
        b.parent=o.address;retain_object(g,o);
        b.length=A(1);b.format=m==23?100:A(3);b.fvf=m==23?A(3):0;b.usage=A(2);b.pool=A(4);b.data=alloc(c,g,b.length);
        if(!b.data){release_object(c,g,b);return OOM;}put(c,A(5),b.address);return 0;
    }
    case 25:case 26: {
        BOOL depth=m==26;uint32_t out=A(depth?5:6);if(!out)return INVALID;put(c,out,0);
        unsigned w=A(1),h=A(2),format=A(3);
        if(!w||!h||w>16384||h>16384)return INVALID;
        if(A(4)||(!depth&&A(5))||(depth?format!=75:(format!=21&&format!=22)))return UNAVAILABLE;
        id<MTLTexture> texture=render_texture(g,w,h,depth);if(!texture)return OOM;
        TCGraphicsObject *surface=surface_object(c,g,o,texture,format,depth);if(!surface)return OOM;
        put(c,out,surface.address);return 0;
    }
    case 27: {
        if(!A(4))return INVALID;put(c,A(4),0);
        if(!A(1)||!A(2)||A(1)>16384||A(2)>16384||!texture_format(A(3)))return INVALID;
        TCGraphicsObject *surface=object(c,g,5);if(!surface)return OOM;
        surface.parent=o.address;retain_object(g,o);
        surface.width=A(1);surface.height=A(2);surface.format=A(3);surface.pool=2;surface.levels=1;
        if(!texture_layout(surface)){release_object(c,g,surface);return INVALID;}
        surface.data=alloc(c,g,surface.length);
        if(!surface.data){release_object(c,g,surface);return OOM;}
        put(c,A(4),surface.address);return 0;
    }
    case 28:return copy_rects(c,g,o,g.objects[@(A(1))],A(2),A(3),g.objects[@(A(4))],A(5));
    case 31: {
        TCGraphicsObject *color=A(1)?g.objects[@(A(1))]:g.objects[@(g->targetSurface)];
        TCGraphicsObject *depth=g.objects[@(A(2))];
        if((A(1)&&(!color||color.kind!=5||color.usage!=1||owning_device(g,color)!=o))||
           (A(2)&&(!depth||depth.kind!=5||depth.usage!=2||owning_device(g,depth)!=o)))return INVALID;
        id<MTLTexture> target=A(1)?color.texture:g.color;
        if(!target||(depth&&(depth.width<target.width||depth.height<target.height)))return INVALID;
        if(A(1)){g.color=target;g->targetFormat=color.format;bind_surface(c,g,&g->targetSurface,color);}
        g.depth=depth.texture;bind_surface(c,g,&g->targetDepth,depth);
        g->viewport[0]=g->viewport[1]=0;g->viewport[2]=(uint32_t)target.width;g->viewport[3]=(uint32_t)target.height;
        g->viewport[4]=0;g->viewport[5]=0x3f800000;return 0;
    }
    case 29: {
        TCGraphicsObject *source=g.objects[@(A(1))],*destination=g.objects[@(A(2))];
        if(!source||!destination||source.kind!=4||destination.kind!=4||source.pool!=2||destination.pool!=0||
            (destination.usage&1)||source.locked||destination.locked||source.format!=destination.format)return INVALID;
        unsigned first=0;
        while(first<source.levels&&(mip_dimension(source.width,first)!=destination.width||
              mip_dimension(source.height,first)!=destination.height))first++;
        if(first==source.levels||source.levels-first<destination.levels)return INVALID;
        TCGraphicsObject *candidate=[TCGraphicsObject new];
        candidate.width=destination.width;candidate.height=destination.height;
        candidate.levels=destination.levels;candidate.format=destination.format;
        candidate.data=source.data+source->mipOffset[first];
        if(!texture_layout(candidate))return INVALID;
        id<MTLTexture> texture=upload_texture(c,g,candidate);if(!texture)return OOM;
        memcpy(mem(c,destination.data,destination.length),mem(c,candidate.data,candidate.length),destination.length);
        destination.texture=texture;return 0;
    }
    case 34:if(g->scene)return INVALID;if(c->frame_input)c->frame_input(&c->scalar);configure_scaler(c,g);configure_msaa(c,g);g->nativePhase=NO;g->scene=YES;return 0;
    case 35:if(!g->scene)return INVALID;resolve_scaled(g);g->scene=NO;return 0;
    case 36: {
        if(A(1)||A(2)||(A(3)&~7u)||((A(3)&6)&&!g.depth)||!isfinite(real(A(5)))||real(A(5))<0||real(A(5))>1)return INVALID;
        return encoder(g,A(3),A(4),real(A(5)),A(6))?0:LOST;
    }
    case 37:case 38:case 39: {
        matrix_float4x4 *target=A(1)==256?&g->world:A(1)==2?&g->view:A(1)==3?&g->projection:
            A(1)>=16&&A(1)<24?&g->textureMatrices[A(1)-16]:NULL;
        if(!target)return UNAVAILABLE;
        if(m==38)memcpy(mem(c,A(2),64),target,64);
        else { matrix_float4x4 value;memcpy(&value,mem(c,A(2),64),64);
            /* D3D row-vector matrices become column-vector matrices through layout. */
            *target=m==39?simd_mul(value,*target):value; }return 0;
    }
    case 40: {
        uint32_t v[6];memcpy(v,mem(c,A(1),24),24);
        if(!v[2]||!v[3]||(uint64_t)v[0]+v[2]>g.color.width||(uint64_t)v[1]+v[3]>g.color.height||
            !isfinite(real(v[4]))||!isfinite(real(v[5]))||real(v[4])<0||real(v[5])>1||real(v[4])>real(v[5]))return INVALID;
        memcpy(g->viewport,v,24);return 0;
    }
    case 41:memcpy(mem(c,A(1),24),g->viewport,24);return 0;
    case 42: {
        Material material;memcpy(&material,mem(c,A(1),sizeof(material)),sizeof(material));
        for(unsigned i=0;i<sizeof(material);i+=4) {
            float value;memcpy(&value,(const unsigned char *)&material+i,4);if(!isfinite(value))return INVALID;
        }
        if(material.power<0)return INVALID;g->material=material;return 0;
    }
    case 43:memcpy(mem(c,A(1),sizeof(Material)),&g->material,sizeof(Material));return 0;
    case 44: {
        Light light;memcpy(&light,mem(c,A(2),sizeof(light)),sizeof(light));if(!light_valid(&light))return INVALID;
        g.lights[@(A(1))]=[NSData dataWithBytes:&light length:sizeof(light)];return 0;
    }
    case 45: {
        NSData *light=g.lights[@(A(1))];if(!light)return INVALID;
        memcpy(mem(c,A(2),sizeof(Light)),light.bytes,sizeof(Light));return 0;
    }
    case 46: {
        NSNumber *index=@(A(1));BOOL enabled=A(2)!=0;
        if(enabled&&![g.enabledLights containsObject:index]&&g.enabledLights.count>=8)return INVALID;
        if(!g.lights[index]) {
            Light light={.type=3,.diffuse={1,1,1,0},.direction={0,0,1}};
            g.lights[index]=[NSData dataWithBytes:&light length:sizeof(light)];
        }
        if(enabled)[g.enabledLights addObject:index];else [g.enabledLights removeObject:index];return 0;
    }
    case 47:if(!g.lights[@(A(1))])return INVALID;put(c,A(2),[g.enabledLights containsObject:@(A(1))]);return 0;
    case 50:case 51: {
        unsigned state=A(1);if(state>=256)return UNAVAILABLE;
        uint32_t value=m==50?A(2):g->render[state];
        if(!render_state_valid(state,value))return UNAVAILABLE;
        if(m==50)g->render[state]=value;else put(c,A(2),value);return 0;
    }
    case 60: {
        if(A(1)>=8)return UNAVAILABLE;uint32_t texture=g->boundTexture[A(1)];
        put(c,A(2),texture);if(texture)retain_object(g,g.objects[@(texture)]);return 0;
    }
    case 61: {
        if(A(1)>=8)return UNAVAILABLE;TCGraphicsObject *t=g.objects[@(A(2))];
        if(A(2)&&(!t||t.kind!=4||t.pool==2))return INVALID;
        bind_object(c,g,&g->boundTexture[A(1)],A(2));return 0;
    }
    case 62:case 63:
        if(A(1)>=8||A(2)>=32)return UNAVAILABLE;
        if(m==62)put(c,A(3),g->stages[A(1)][A(2)]);else g->stages[A(1)][A(2)]=A(3);return 0;
    case 70:return draw(c,g,A(1),A(3),0,0,NULL,0,A(2),NO);
    case 72: {
        uint32_t result=draw(c,g,A(1),A(2),A(3),A(4),NULL,0,0,YES);
        bind_object(c,g,&g->streams[0],0);return result;
    }
    case 71: {
        TCGraphicsObject *i=g.objects[@(g->indices)];
        if(!i||i.locked)return INVALID;
        uint64_t count=A(1)==1?A(5):A(1)==2?(uint64_t)A(5)*2:A(1)==3?(uint64_t)A(5)+1:A(1)==4?(uint64_t)A(5)*3:(uint64_t)A(5)+2;
        unsigned size=i.format==101?2:4;uint64_t start=(uint64_t)A(4)*size;
        if(start>i.length||count*size>i.length-start)return INVALID;
        return indexed(c,g,A(1),A(5),A(2),A(3),i.data+(uint32_t)start,i.format,0,0,g->baseVertex,NO);
    }
    case 73: {
        uint32_t result=indexed(c,g,A(1),A(4),A(2),A(3),A(5),A(6),A(7),A(8),0,YES);
        bind_object(c,g,&g->streams[0],0);bind_object(c,g,&g->indices,0);return result;
    }
    case 75: {
        if(!A(1)||!A(3))return INVALID;
        if(A(2)||A(4))return UNAVAILABLE;
        VertexDeclaration declaration={0};
        for(unsigned i=0;i<64;i++) {
            memcpy(&declaration.tokens[i],mem(c,(uint64_t)A(1)+i*4,4),4);
            declaration.tokenCount=i+1;if(declaration.tokens[i]==UINT32_MAX)break;
        }
        if(!declaration_layout(&declaration))return UNAVAILABLE;
        if(g->nextVertexHandle>UINT32_MAX-16)return OOM;
        uint32_t handle=g->nextVertexHandle;g->nextVertexHandle+=16;
        g.vertexDeclarations[@(handle)]=[NSData dataWithBytes:&declaration length:sizeof(declaration)];
        put(c,A(3),handle);return 0;
    }
    case 76: {
        const VertexDeclaration *declaration=(const VertexDeclaration *)g.vertexDeclarations[@(A(1))].bytes;
        if(!declaration&&A(1)&&!vertex_size(A(1)))return UNAVAILABLE;
        g->vertexHandle=declaration?A(1):0;g->vertexFormat=declaration?declaration->format:A(1);return 0;
    }
    case 77:if(!A(1))return INVALID;put(c,A(1),g->vertexHandle?:g->vertexFormat);return 0;
    case 78:
        if(!g.vertexDeclarations[@(A(1))])return INVALID;
        [g.vertexDeclarations removeObjectForKey:@(A(1))];
        if(g->vertexHandle==A(1))g->vertexHandle=g->vertexFormat=0;return 0;
    case 81:case 82: {
        const VertexDeclaration *declaration=(const VertexDeclaration *)g.vertexDeclarations[@(A(1))].bytes;
        if(!declaration||!A(3))return INVALID;
        uint32_t size=m==81?declaration->tokenCount*4:0,capacity=0;
        if(A(2))memcpy(&capacity,mem(c,A(3),4),4);
        put(c,A(3),size);
        if(A(2)&&capacity<size)return 0x88760867u; /* D3DERR_MOREDATA */
        if(A(2)&&size)memcpy(mem(c,A(2),size),declaration->tokens,size);return 0;
    }
    case 83: {
        unsigned stream=A(1);if(stream>=16)return INVALID;TCGraphicsObject *b=g.objects[@(A(2))];
        if(A(2)&&(!b||b.kind!=2||!A(3)||A(3)>2048))return INVALID;
        bind_object(c,g,&g->streams[stream],A(2));g->strides[stream]=A(3);return 0;
    }
    case 84: {
        unsigned stream=A(1);if(stream>=16||!A(2)||!A(3))return INVALID;
        put(c,A(2),g->streams[stream]);put(c,A(3),g->strides[stream]);
        if(g->streams[stream])retain_object(g,g.objects[@(g->streams[stream])]);return 0;
    }
    case 85: {
        TCGraphicsObject *b=g.objects[@(A(1))];if(A(1)&&(!b||b.kind!=3))return INVALID;
        bind_object(c,g,&g->indices,A(1));g->baseVertex=A(2);return 0;
    }
    case 86:put(c,A(1),g->indices);put(c,A(2),g->baseVertex);if(g->indices)retain_object(g,g.objects[@(g->indices)]);return 0;
    case 88:return A(1)?UNAVAILABLE:0;
    case 89:put(c,A(1),0);return 0;
    default:return UNAVAILABLE;
    }
#undef A
}
void tc_d3d_dispatch(_cpu *cpu, uint32_t method) {
    @autoreleasepool {
        tc_cpu *c=(tc_cpu *)cpu;TCMetal *g=context(c);
        cpu->_eax=g ? dispatch(c,g,method>>8,method&255) : INVALID;
        unsigned kind=method>>8,slot=method&255;
        if(c->headless&&g) {
            BOOL hresult=slot!=1&&slot!=2&&!(kind==0&&(slot==4||slot==6||slot==14))&&
                !(kind==1&&slot==4)&&!(kind>=2&&kind<=4&&slot==10)&&!(kind==4&&slot>=11&&slot<=13);
            if(hresult&&(cpu->_eax&0x80000000u)&&kind<6&&slot<97&&!g->reportedFailure[kind][slot]) {
                g->reportedFailure[kind][slot]=YES;
                fprintf(stderr,"Headless Metal: method=%#x rejected, HRESULT=%#x, FVF=%#x\n",method,cpu->_eax,g->vertexFormat);
                if(method==0x14b)fprintf(stderr,"Headless Metal: CreateVertexShader function=%#x usage=%#x\n",arg(c,2),arg(c,4));
            }
            if(kind==1&&!cpu->_eax) {
                if(slot>=70&&slot<=73)g->headlessDraws++;
                if(slot==15) {
                    g->headlessPresents++;
                    if(g->headlessPresents==1||g->headlessPresents==120)
                        fprintf(stderr,"Headless Metal: %llu presents completed, %llu draws encoded\n",
                            (unsigned long long)g->headlessPresents,(unsigned long long)g->headlessDraws);
                }
            }
        }
        if(method==0x114 && (cpu->_eax&0x80000000u))
            fprintf(stderr,"CreateTexture failed: %ux%u levels=%u usage=%#x format=%#x pool=%u HRESULT=%#x\n",
                arg(c,1),arg(c,2),arg(c,3),arg(c,4),arg(c,5),arg(c,6),cpu->_eax);
    }
}

#ifdef TC_TEXTURE_SELF_CHECK
#include <assert.h>
int main(void) {
    @autoreleasepool {
        TCGraphicsObject *t=[TCGraphicsObject new];t.width=7;t.height=5;t.format=0x31545844;
        assert(texture_layout(t)&&t.levels==3&&t->mipPitch[0]==16);
        assert(t->mipSize[0]==32&&t->mipSize[1]==8&&t->mipSize[2]==8&&t.length==48);
        t.levels=4;assert(!texture_layout(t));
        t.levels=0;t.format=21;assert(texture_layout(t)&&t.length==168);
        t.width=256;t.height=64;t.levels=4;t.format=0x34545844;
        assert(texture_format(t.format)==MTLPixelFormatBC3_RGBA&&texture_layout(t)&&t.length==21760);
        t.format=0x32545844;
        assert(texture_format(t.format)==MTLPixelFormatBC2_RGBA&&texture_layout(t)&&t.length==21760);
    }return 0;
}
#endif

#ifdef TC_BUFFER_SELF_CHECK
#include <assert.h>
int main(void) {
    @autoreleasepool {
        assert(buffer_options(8,1)&&buffer_options(0x208,0)&&buffer_options(0x208,2));
        assert(!buffer_options(0x208,1)&&!buffer_options(0,3));
        unsigned char bytes[1024]={0};tc_cpu cpu={0};cpu.memory_size=sizeof(bytes);
        cpu.scalar._pointer_offset=(uintptr_t)bytes;cpu.scalar._esp=128;
        TCMetal *g=[TCMetal new];g.objects=[NSMutableDictionary new];
        TCGraphicsObject *buffer=[TCGraphicsObject new];buffer.address=32;buffer.kind=2;
        buffer.data=256;buffer.length=64;buffer.usage=0x208;buffer.pool=0;buffer.format=100;
        g.objects[@32]=buffer;
        uint32_t args[]={32,8,16,64,0x1000};memcpy(bytes+132,args,sizeof(args));
        memset(bytes+256,0x5a,65);assert(dispatch(&cpu,g,2,11)==0&&buffer.locked);
        assert(bytes[256]==0x5a&&bytes[319]==0x5a);assert(dispatch(&cpu,g,2,12)==0);
        args[4]=0x2000;memcpy(bytes+132,args,sizeof(args));assert(dispatch(&cpu,g,2,11)==0);
        for(unsigned i=256;i<320;i++)assert(!bytes[i]);assert(bytes[320]==0x5a);
        uint32_t address;memcpy(&address,bytes+64,4);assert(address==264);
        assert(dispatch(&cpu,g,2,12)==0);args[4]=0x10;memcpy(bytes+132,args,sizeof(args));
        assert(dispatch(&cpu,g,2,11)==INVALID&&!buffer.locked);
        args[1]=64;memcpy(bytes+132,args,sizeof(args));assert(dispatch(&cpu,g,2,13)==0);
        uint32_t description[6];memcpy(description,bytes+64,sizeof(description));
        assert(description[2]==0x208&&description[3]==0&&description[4]==64);
    }return 0;
}
#endif

#ifdef TC_RENDER_STATE_SELF_CHECK
#include <assert.h>
static int reject_graphics_preferences(_cpu *cpu,uint32_t parameters[13]) {
    parameters[0]=1920;cpu->_eax=99;return -1;
}
int main(void) {
    assert(render_state_valid(25,8)&&!render_state_valid(25,9));
    VertexDeclaration declaration={.tokens={0x20000000,0x40040005,0x40020000,0x40010007,UINT32_MAX},.tokenCount=5};
    assert(declaration_layout(&declaration)&&declaration.format==0x142&&declaration.required[0]==24);
    assert(declaration.offsets[5]==0&&declaration.offsets[0]==4&&declaration.offsets[7]==16);
    VertexDeclaration skipped={.tokens={0x20000000,0x50020000,0x40020000,UINT32_MAX},.tokenCount=4};
    assert(declaration_layout(&skipped)&&skipped.offsets[0]==8&&skipped.required[0]==20);
    declaration.tokens[3]=0x40010008;assert(!declaration_layout(&declaration));
    declaration.tokens[3]=0x40020000;assert(!declaration_layout(&declaration));
    declaration.tokens[0]=0x20000010;assert(!declaration_layout(&declaration));
    VertexDeclaration multiple={.tokens={0x20000000,0x40020000,0x40010007,0x20000001,0x40040005,UINT32_MAX},.tokenCount=6};
    assert(declaration_layout(&multiple)&&multiple.format==0x142);
    assert(multiple.required[0]==20&&multiple.required[1]==4&&multiple.sources[5]==1);
    assert(vertex_range(80,20,20,3)&&!vertex_range(79,20,20,3));
    assert(!vertex_range(80,20,16,0)&&!vertex_range(UINT64_MAX,4,4,UINT64_MAX));
    assert(vertex_size(0x202)==28&&vertex_size(0x30102)==16&&vertex_size(0x10102)==24);
    assert(vertex_size(0x80000802)==84&&!vertex_size(0x902)&&!vertex_size(0x30002));
    assert(texture_flags_valid(0)&&texture_flags_valid(2)&&texture_flags_valid(0x103)&&texture_flags_valid(0x104));
    assert(!texture_flags_valid(1)&&!texture_flags_valid(0x100)&&!texture_flags_valid(0x105));
    assert(coordinate_source_valid(0x20000,2)&&coordinate_source_valid(0x10000,0x12)&&coordinate_source_valid(0x30007,0x12));
    assert(!coordinate_source_valid(0x30000,2)&&!coordinate_source_valid(0x20000,4));
    assert(!coordinate_source_valid(0x40000,0x12)&&!coordinate_source_valid(0x20008,2));
    assert(coordinate_source_valid(1,0x202)&&!coordinate_source_valid(1,0x102));
    assert(render_state_valid(168,0)&&render_state_valid(168,15)&&!render_state_valid(168,16));
    assert(TC_ADAPTER_MODE_COUNT==9&&adapter_modes[0][0]==640&&adapter_modes[0][1]==480&&adapter_modes[0][3]==22);
    assert(adapter_modes[8][0]==3840&&adapter_modes[8][1]==2160);
    assert((TC_DEVICE_CAPABILITIES&0x18000)==0x18000);
    assert(render_state_valid(171,5)&&!render_state_valid(171,0));
    assert(render_state_valid(58,UINT32_MAX)&&!render_state_valid(256,0));
    assert(render_state_valid(145,2)&&!render_state_valid(145,3)&&render_state_valid(143,1));
    assert(render_state_valid(35,3)&&!render_state_valid(140,4));
    assert(render_state_valid(38,0x3f800000)&&!render_state_valid(38,0x40000000));
    assert(!render_state_valid(36,0x7fc00000));
    Light light={.type=3,.direction={0,0,1}};assert(light_valid(&light));
    light.direction[2]=0;assert(!light_valid(&light));
    light.type=1;light.range=100;light.attenuation0=1;assert(light_valid(&light));
    light.attenuation0=0;assert(!light_valid(&light));
    light.type=2;light.attenuation0=1;light.direction[2]=1;light.theta=.5f;light.phi=1;assert(light_valid(&light));
    light.theta=2;assert(!light_valid(&light));
    @autoreleasepool {
        TCMetal *g=[TCMetal new];
        uint32_t states[256]={0};states[27]=1;states[19]=5;states[20]=6;states[171]=1;states[168]=15;
        MTLRenderPipelineDescriptor *p=pipeline_descriptor(g,pipeline_key(states,YES,2,NO));
        assert(p&&p.rasterSampleCount==2&&!p.alphaToCoverageEnabled&&p.colorAttachments[0].blendingEnabled);
        assert(p.colorAttachments[0].sourceRGBBlendFactor==MTLBlendFactorSourceAlpha&&
            p.colorAttachments[0].destinationRGBBlendFactor==MTLBlendFactorOneMinusSourceAlpha);
        assert(p.colorAttachments[0].writeMask==MTLColorWriteMaskAll&&p.depthAttachmentPixelFormat==MTLPixelFormatDepth32Float_Stencil8);
        states[27]=0;p=pipeline_descriptor(g,pipeline_key(states,NO,1,YES));
        assert(p&&p.rasterSampleCount==1&&p.alphaToCoverageEnabled&&!p.colorAttachments[0].blendingEnabled);
        assert(p.depthAttachmentPixelFormat==MTLPixelFormatInvalid);
        assert(!pipeline_descriptor(g,pipeline_key(states,NO,3,NO))&&!pipeline_descriptor(g,1u<<21));
        unsigned char parameterMemory[128]={0};tc_cpu parameterCPU={0};
        parameterCPU.scalar._pointer_offset=(uintptr_t)parameterMemory;parameterCPU.memory_size=sizeof(parameterMemory);
        parameterCPU.prepare_graphics=reject_graphics_preferences;
        const uint32_t oldParameters[13]={640,480,22};memcpy(parameterMemory+16,oldParameters,sizeof(oldParameters));
        assert(!reset_guest_device(&parameterCPU,g,16)&&parameterCPU.scalar._eax==99);
        assert(!memcmp(parameterMemory+16,oldParameters,sizeof(oldParameters)));
        g->stages[0][1]=4;g->stages[0][2]=2;g->stages[0][3]=1;
        g->stages[0][4]=2;g->stages[0][5]=2;g->stages[0][28]=1;
        Combiner combination;
        assert(combiner_settings(g,0,YES,&combination)&&combination.alpha.w);
        assert(combiner_settings(g,0,NO,&combination)&&combination.color.x==1);
        g->stages[0][1]=2;g->stages[0][2]=0x33;g->stages[0][5]=0;
        assert(combiner_settings(g,0,NO,&combination)&&combination.color.x==2&&!combination.alpha.w);
        g->stages[0][2]=5;assert(combiner_settings(g,0,YES,&combination));
        g->stages[0][2]=6;assert(!combiner_settings(g,0,YES,&combination));
        g->stages[0][1]=17;assert(!combiner_settings(g,0,YES,&combination));
        g->stages[0][1]=1;assert(combiner_settings(g,0,YES,&combination)&&combination.color.x==1);
        uint32_t *second=g->stages[1];second[1]=16;second[2]=2;second[3]=1;
        second[4]=2;second[5]=1;second[28]=1;second[11]=7;
        assert(combiner_settings(g,1,YES,&combination)&&combination.color.x==16&&
            combination.color.w==0&&combination.alpha.w);
        assert(combiner_settings(g,1,NO,&combination)&&combination.color.x==1);
        second[11]=8;assert(!combiner_settings(g,1,YES,&combination));
        second[11]=0;second[24]=0x103;assert(combiner_settings(g,1,YES,&combination));
        second[24]=0x105;assert(!combiner_settings(g,1,YES,&combination));
        second[24]=0;second[1]=25;second[2]=5;second[3]=4;second[26]=2;second[28]=5;
        assert(combiner_settings(g,1,YES,&combination)&&combination.alpha.w&&combination.extra.x==2&&combination.extra.z==5);
        second[26]=6;assert(!combiner_settings(g,1,YES,&combination));
        second[26]=1;second[1]=21;second[4]=18;assert(!combiner_settings(g,1,YES,&combination));
        second[4]=24;assert(combiner_settings(g,1,YES,&combination));
        g->view=matrix_identity_float4x4;g.lights=[NSMutableDictionary new];
        g.enabledLights=[NSMutableSet setWithObject:@100];light.type=3;light.theta=0;
        g.lights[@100]=[NSData dataWithBytes:&light length:sizeof(light)];
        g->render[141]=1;g->render[145]=1;
        assert(material_source(g,145,0)==0&&material_source(g,145,64)==1);
        Lighting packed=lighting(g,64,YES);
        assert(packed.flags.x==1&&packed.flags.y==1&&packed.lights[0].position.w==3&&packed.lights[0].direction.z==1);
        g->projection=matrix_identity_float4x4;g->render[28]=1;g->render[140]=3;g->render[48]=1;
        Fog fog=fog_settings(g,2);assert(fog.modes.x==1&&fog.modes.z==3&&fog.modes.w==2);
        assert(fog_settings(g,4).modes.z==0);
        g->projection.columns[2].w=1;g->projection.columns[3].w=0;
        assert(fog_settings(g,2).modes.w==3);
    }return 0;
}
#endif

#ifdef TC_SURFACE_SELF_CHECK
#include <assert.h>
@interface TCSurfaceDimensions : NSObject
@property NSUInteger width,height;
@end
@implementation TCSurfaceDimensions
@end
int main(void) {
    @autoreleasepool {
        unsigned char bytes[256]={0};tc_cpu cpu={0};
        cpu.scalar._pointer_offset=(uintptr_t)bytes;cpu.memory_size=sizeof(bytes);cpu.scalar._esp=128;
        TCMetal *g=[TCMetal new];g.objects=[NSMutableDictionary new];
        TCGraphicsObject *device=[TCGraphicsObject new];device.address=16;device.kind=1;device.references=1;
        TCGraphicsObject *surface=[TCGraphicsObject new];surface.address=32;surface.kind=5;surface.references=1;
        surface.parent=16;surface.format=22;surface.usage=1;surface.width=640;surface.height=480;surface.length=640*480*4;
        g.objects[@16]=device;g.objects[@32]=surface;g->backSurface=32;
        TCSurfaceDimensions *texture=[TCSurfaceDimensions new];texture.width=640;texture.height=480;
        surface.texture=(id<MTLTexture>)texture;g.color=g.backBuffer=surface.texture;
        uint32_t args[]={32,64};memcpy(bytes+132,args,sizeof(args));
        assert(dispatch(&cpu,g,5,8)==0);
        uint32_t desc[8];memcpy(desc,bytes+64,sizeof(desc));
        assert(desc[0]==22&&desc[1]==1&&desc[2]==1&&desc[4]==640*480*4&&desc[6]==640&&desc[7]==480);
        assert(dispatch(&cpu,g,5,3)==0&&device.references==2);
        uint32_t address;memcpy(&address,bytes+64,4);assert(address==16);
        assert(!reset_guest_device(&cpu,g,64));
        args[0]=16;memcpy(bytes+132,args,sizeof(args));
        assert(dispatch(&cpu,g,1,32)==0&&surface.references==3&&surface.internalReferences==1);
        assert(dispatch(&cpu,g,1,33)==0x88760866u);
        uint32_t targetArgs[]={16,32,0};memcpy(bytes+132,targetArgs,sizeof(targetArgs));
        assert(dispatch(&cpu,g,1,31)==0&&g.color==surface.texture&&!g.depth);
        assert(g->viewport[2]==640&&g->viewport[3]==480&&surface.internalReferences==1);
        release_object(&cpu,g,surface);release_object(&cpu,g,surface);
        assert(surface.references==1&&surface.internalReferences==1&&device.references==1);
        assert(surfaces_released(g));
        assert(retain_object(g,surface)==2&&device.references==2&&!surfaces_released(g));
        bind_surface(&cpu,g,&g->targetSurface,surface);
        assert(surface.references==2&&surface.internalReferences==1);
        bind_surface(&cpu,g,&g->targetSurface,nil);
        assert(surface.references==1&&!surface.internalReferences);
        TCGraphicsObject *container=[TCGraphicsObject new];container.kind=4;container.address=40;
        container.parent=device.address;container.references=1;g.objects[@40]=container;retain_object(g,device);
        TCGraphicsObject *mip=[TCGraphicsObject new];mip.kind=5;mip.address=48;mip.references=1;
        mip.parent=40;g.objects[@48]=mip;retain_object(g,container);retain_internal(container);
        assert(owning_device(g,mip)==device);
        bind_surface(&cpu,g,&g->targetSurface,mip);
        release_object(&cpu,g,mip);release_object(&cpu,g,container);
        assert(mip.references==1&&container.references==1&&container.internalReferences==1&&device.references==2);
        assert(retain_object(g,mip)==2&&container.references==2&&device.references==3);
        assert(owning_device(g,container)==device);
        TCGraphicsObject *pixels=[TCGraphicsObject new];pixels.kind=5;pixels.pool=2;
        pixels.width=4;pixels.height=2;pixels.format=21;pixels.levels=1;pixels.data=192;
        assert(texture_layout(pixels));
        int32_t rectangle[]={1,1,3,2};memcpy(bytes+96,rectangle,16);
        assert(lock_pixels(&cpu,pixels,0,64,96,0)==0);
        uint32_t locked[2];memcpy(locked,bytes+64,8);assert(locked[0]==16&&locked[1]==212);
        assert(lock_pixels(&cpu,pixels,0,64,0,0)==INVALID);
        assert(unlock_pixels(&cpu,g,pixels,0)==0&&!pixels.locked);
        assert(unlock_pixels(&cpu,g,pixels,0)==INVALID);
        pixels.parent=device.address;pixels.address=80;
        TCGraphicsObject *copied=[TCGraphicsObject new];copied.kind=5;copied.pool=2;
        copied.parent=device.address;copied.address=88;copied.width=4;copied.height=2;
        copied.format=21;copied.levels=1;copied.data=224;assert(texture_layout(copied));
        for(unsigned i=0;i<32;i++)bytes[192+i]=(unsigned char)i;
        memset(bytes+224,0xcc,32);
        int32_t sourceRect[]={1,0,3,2},destinationPoint[]={0,0};
        memcpy(bytes+96,sourceRect,16);memcpy(bytes+112,destinationPoint,8);
        assert(copy_rects(&cpu,g,device,pixels,96,1,copied,112)==0);
        assert(!memcmp(bytes+224,bytes+196,8)&&!memcmp(bytes+240,bytes+212,8)&&bytes[232]==0xcc);
        unsigned char before[32];memcpy(before,bytes+224,32);
        destinationPoint[0]=3;memcpy(bytes+112,destinationPoint,8);
        assert(copy_rects(&cpu,g,device,pixels,96,1,copied,112)==INVALID&&!memcmp(before,bytes+224,32));
        assert(copy_rects(&cpu,g,device,pixels,0,0,pixels,0)==INVALID);
        CopyRegion region;pixels.format=copied.format=0x31545844;
        int32_t blockRect[]={0,0,3,2};
        assert(!copy_region(pixels,copied,blockRect,NULL,&region));
        pixels.width=copied.width=3;assert(copy_region(pixels,copied,blockRect,NULL,&region));
    }
    return 0;
}
#endif
