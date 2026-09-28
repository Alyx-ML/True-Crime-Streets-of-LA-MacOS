#ifndef TC_VIDEO_H
#define TC_VIDEO_H
#include <stddef.h>
#include <stdint.h>
struct tc_video;
typedef struct {
    uint32_t width,height,frames,rate,rate_divisor;
} tc_video_info;
/* Decoding creates no output device, window or audio engine. A single caller
 * owns each decoder and its current BGRA frame. Audio is skipped by default. */
struct tc_video *tc_video_open(const char *path,tc_video_info *info,char *error,size_t error_size);
/* Optional synchronous float PCM sink. Return zero to stop on sink failure.
 * Pointers are borrowed only for the call; track is the file's track ID. */
typedef int (*tc_video_audio_sink)(void *opaque,uint32_t track,uint32_t rate,
    uint32_t channels,int planar,const float *const *samples,uint32_t count);
void tc_video_set_audio(struct tc_video *video,tc_video_audio_sink sink,void *opaque);
/* Returns 1 for a decoded frame, 0 at EOF, or -1 on error. The pixels remain
 * valid until the next decode or close. stride is positive, bytes per row. */
int tc_video_next(struct tc_video *video,const uint8_t **pixels,uint32_t *stride,char *error,size_t error_size);
void tc_video_close(struct tc_video *video);
#endif
