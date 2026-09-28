#include "tc_video.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct tc_video {
    FILE *file;
    AVIOContext *io;
    AVFormatContext *container;
    AVCodecContext *decoder;
    AVCodecContext **audio;
    unsigned audio_count;
    AVFrame *audio_frame;
    tc_video_audio_sink sink;
    void *sink_opaque;
    AVPacket *packet;
    AVFrame *frame;
    struct SwsContext *conversion;
    unsigned char *pixels;
    uint32_t width,height,stride;
    int stream,draining;
};
static void describe(char *out,size_t size,const char *operation,int code) {
    if(!out||!size)return;
    char detail[AV_ERROR_MAX_STRING_SIZE];av_strerror(code,detail,sizeof(detail));
    snprintf(out,size,"%s: %s",operation,detail);
}
static int read_file(void *opaque,uint8_t *buffer,int size) {
    FILE *file=opaque;size_t count=fread(buffer,1,(size_t)size,file);
    if(count)return (int)count;
    return ferror(file)?AVERROR(EIO):AVERROR_EOF;
}
static int64_t seek_file(void *opaque,int64_t offset,int whence) {
    FILE *file=opaque;
    if(whence&AVSEEK_SIZE) {
        off_t position=ftello(file);if(position<0)return AVERROR(errno);
        if(fseeko(file,0,SEEK_END))return AVERROR(errno);
        off_t size=ftello(file);int code=errno;
        if(fseeko(file,position,SEEK_SET))return AVERROR(errno);
        return size<0?AVERROR(code):size;
    }
    whence&=~AVSEEK_FORCE;
    if(whence!=SEEK_SET&&whence!=SEEK_CUR&&whence!=SEEK_END)return AVERROR(EINVAL);
    if(fseeko(file,offset,whence))return AVERROR(errno);
    off_t position=ftello(file);return position<0?AVERROR(errno):position;
}
void tc_video_close(struct tc_video *v) {
    if(!v)return;
    sws_freeContext(v->conversion);av_free(v->pixels);
    av_frame_free(&v->frame);av_packet_free(&v->packet);avcodec_free_context(&v->decoder);
    for(unsigned i=0;i<v->audio_count;i++)avcodec_free_context(&v->audio[i]);
    free(v->audio);av_frame_free(&v->audio_frame);
    avformat_close_input(&v->container);
    if(v->io){av_freep(&v->io->buffer);avio_context_free(&v->io);}
    if(v->file)fclose(v->file);free(v);
}
struct tc_video *tc_video_open(const char *path,tc_video_info *info,char *error,size_t error_size) {
    int result=AVERROR(EINVAL);const char *operation="Open Bink video";
    if(!path||!info){describe(error,error_size,operation,result);return NULL;}
    memset(info,0,sizeof(*info));
    struct tc_video *v=calloc(1,sizeof(*v));
    if(!v){describe(error,error_size,operation,AVERROR(ENOMEM));return NULL;}
    /* Custom local-file IO prevents FFmpeg from interpreting guest paths as
     * network URLs or starting protocol subprocesses. */
    v->file=fopen(path,"rb");if(!v->file){result=AVERROR(errno);goto failed;}
    unsigned char *buffer=av_malloc(32768);
    if(!buffer){result=AVERROR(ENOMEM);goto failed;}
    v->io=avio_alloc_context(buffer,32768,0,v->file,read_file,NULL,seek_file);
    if(!v->io){av_free(buffer);result=AVERROR(ENOMEM);goto failed;}
    v->container=avformat_alloc_context();if(!v->container){result=AVERROR(ENOMEM);goto failed;}
    v->container->pb=v->io;v->container->flags|=AVFMT_FLAG_CUSTOM_IO;
    const AVInputFormat *bink=av_find_input_format("bink");
    if(!bink){result=AVERROR_DEMUXER_NOT_FOUND;goto failed;}
    result=avformat_open_input(&v->container,NULL,bink,NULL);if(result<0)goto failed;
    result=avformat_find_stream_info(v->container,NULL);if(result<0)goto failed;
    v->stream=av_find_best_stream(v->container,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0);
    if(v->stream<0){result=v->stream;goto failed;}
    AVStream *stream=v->container->streams[v->stream];
    if(stream->codecpar->codec_id!=AV_CODEC_ID_BINKVIDEO){result=AVERROR_DECODER_NOT_FOUND;goto failed;}
    const AVCodec *codec=avcodec_find_decoder(stream->codecpar->codec_id);
    if(!codec){result=AVERROR_DECODER_NOT_FOUND;goto failed;}
    v->decoder=avcodec_alloc_context3(codec);if(!v->decoder){result=AVERROR(ENOMEM);goto failed;}
    result=avcodec_parameters_to_context(v->decoder,stream->codecpar);if(result<0)goto failed;
    /* One decoder thread per movie keeps frame ordering and ownership simple. */
    v->decoder->thread_count=1;
    result=avcodec_open2(v->decoder,codec,NULL);if(result<0)goto failed;
    AVRational rate=av_guess_frame_rate(v->container,stream,NULL);
    if(v->decoder->width<=0||v->decoder->height<=0||v->decoder->width>16384||v->decoder->height>16384||rate.num<=0||rate.den<=0){result=AVERROR_INVALIDDATA;goto failed;}
    int64_t frames=stream->nb_frames;
    if(frames<=0&&stream->duration!=AV_NOPTS_VALUE&&stream->duration>0)
        frames=av_rescale_q(stream->duration,stream->time_base,av_inv_q(rate));
    if(frames<=0||frames>UINT32_MAX){result=AVERROR_INVALIDDATA;goto failed;}
    v->width=v->decoder->width;v->height=v->decoder->height;v->stride=v->width*4;
    v->packet=av_packet_alloc();v->frame=av_frame_alloc();
    v->pixels=av_malloc((size_t)v->stride*v->height);
    if(!v->packet||!v->frame||!v->pixels){result=AVERROR(ENOMEM);goto failed;}
    *info=(tc_video_info){v->width,v->height,(uint32_t)frames,(uint32_t)rate.num,(uint32_t)rate.den};
    if(error&&error_size)error[0]=0;return v;
failed:describe(error,error_size,operation,result);tc_video_close(v);return NULL;
}
void tc_video_set_audio(struct tc_video *v,tc_video_audio_sink sink,void *opaque) {
    if(v){v->sink=sink;v->sink_opaque=opaque;}
}
static int audio_packet(struct tc_video *v) {
    if(!v->sink)return 0;
    unsigned index=v->packet->stream_index;
    if(index>=v->container->nb_streams)return AVERROR_INVALIDDATA;
    AVStream *stream=v->container->streams[index];
    if(stream->codecpar->codec_type!=AVMEDIA_TYPE_AUDIO)return 0;
    if(!v->audio) {
        v->audio=calloc(v->container->nb_streams,sizeof(*v->audio));
        if(!v->audio)return AVERROR(ENOMEM);
        v->audio_count=v->container->nb_streams;
    }
    if(!v->audio_frame){v->audio_frame=av_frame_alloc();if(!v->audio_frame)return AVERROR(ENOMEM);}
    AVCodecContext *decoder=v->audio[index];int result;
    if(!decoder) {
        enum AVCodecID id=stream->codecpar->codec_id;
        if(id!=AV_CODEC_ID_BINKAUDIO_DCT&&id!=AV_CODEC_ID_BINKAUDIO_RDFT)return AVERROR_DECODER_NOT_FOUND;
        const AVCodec *codec=avcodec_find_decoder(id);if(!codec)return AVERROR_DECODER_NOT_FOUND;
        decoder=avcodec_alloc_context3(codec);if(!decoder)return AVERROR(ENOMEM);
        v->audio[index]=decoder;
        result=avcodec_parameters_to_context(decoder,stream->codecpar);
        if(result>=0){decoder->thread_count=1;result=avcodec_open2(decoder,codec,NULL);}
        if(result<0){avcodec_free_context(&v->audio[index]);return result;}
    }
    result=avcodec_send_packet(decoder,v->packet);if(result<0)return result;
    while((result=avcodec_receive_frame(decoder,v->audio_frame))>=0) {
        AVFrame *frame=v->audio_frame;int channels=frame->ch_layout.nb_channels;
        if((frame->format!=AV_SAMPLE_FMT_FLT&&frame->format!=AV_SAMPLE_FMT_FLTP)||
            channels<1||channels>2||frame->sample_rate<=0||frame->sample_rate>192000||frame->nb_samples<0) {
            av_frame_unref(frame);return AVERROR_INVALIDDATA;
        }
        int accepted=v->sink(v->sink_opaque,(uint32_t)stream->id,frame->sample_rate,channels,
            frame->format==AV_SAMPLE_FMT_FLTP,(const float *const *)frame->extended_data,frame->nb_samples);
        av_frame_unref(frame);if(!accepted)return AVERROR_EXTERNAL;
    }
    return result==AVERROR(EAGAIN)||result==AVERROR_EOF?0:result;
}
int tc_video_next(struct tc_video *v,const uint8_t **pixels,uint32_t *stride,char *error,size_t error_size) {
    int result=AVERROR(EINVAL);
    if(!v||!pixels||!stride)goto failed;
    *pixels=NULL;*stride=0;
    for(;;) {
        result=avcodec_receive_frame(v->decoder,v->frame);
        if(result==0)break;
        if(result==AVERROR_EOF)return 0;
        if(result!=AVERROR(EAGAIN))goto failed;
        if(v->draining){result=AVERROR_INVALIDDATA;goto failed;}
        do {
            av_packet_unref(v->packet);result=av_read_frame(v->container,v->packet);
            if(result>=0&&v->packet->stream_index!=v->stream){result=audio_packet(v);if(result<0)goto failed;}
        }while(result>=0&&v->packet->stream_index!=v->stream);
        if(result==AVERROR_EOF){v->draining=1;result=avcodec_send_packet(v->decoder,NULL);}
        else if(result>=0)result=avcodec_send_packet(v->decoder,v->packet);
        av_packet_unref(v->packet);
        if(result<0)goto failed;
    }
    if(v->frame->width!=(int)v->width||v->frame->height!=(int)v->height){result=AVERROR_INVALIDDATA;goto failed;}
    v->conversion=sws_getCachedContext(v->conversion,v->width,v->height,v->frame->format,
        v->width,v->height,AV_PIX_FMT_BGRA,SWS_BILINEAR,NULL,NULL,NULL);
    if(!v->conversion){result=AVERROR(ENOMEM);goto failed;}
    uint8_t *destination[]={v->pixels,NULL,NULL,NULL};int pitches[]={(int)v->stride,0,0,0};
    result=sws_scale(v->conversion,(const uint8_t *const *)v->frame->data,v->frame->linesize,0,v->height,destination,pitches);
    av_frame_unref(v->frame);
    if(result!=(int)v->height){result=AVERROR_INVALIDDATA;goto failed;}
    *pixels=v->pixels;*stride=v->stride;if(error&&error_size)error[0]=0;return 1;
failed:describe(error,error_size,"Decode Bink frame",result);return -1;
}
#ifdef TC_VIDEO_SELF_CHECK
/* Optional check: audio is never opened and decoded pixels are not displayed. */
#include <assert.h>
#include <math.h>
static int check_audio(void *opaque,uint32_t track,uint32_t rate,uint32_t channels,
    int planar,const float *const *samples,uint32_t count) {
    (void)track;assert(rate&&channels>=1&&channels<=2&&samples&&samples[0]);
    for(uint32_t i=0;i<count;i++)for(uint32_t ch=0;ch<channels;ch++)
        assert(isfinite(planar?samples[ch][i]:samples[0][(size_t)i*channels+ch]));
    *(uint64_t *)opaque+=count;return 1;
}
int main(int argc,char **argv) {
    assert(argc==2||argc==3);char error[256];tc_video_info info;uint64_t samples=0;
    struct tc_video *v=tc_video_open(argv[1],&info,error,sizeof(error));
    if(!v){fprintf(stderr,"%s\n",error);return 1;}
    if(argc==3){assert(!strcmp(argv[2],"--audio"));tc_video_set_audio(v,check_audio,&samples);}
    const uint8_t *pixels;uint32_t stride;uint64_t frames=0;int result;
    while((result=tc_video_next(v,&pixels,&stride,error,sizeof(error)))>0){assert(pixels&&stride==info.width*4);frames++;}
    assert(result==0&&frames==info.frames);if(argc==3)assert(samples>0);
    tc_video_close(v);return 0;
}
#endif
