#ifndef TC_DSOUND_H
#define TC_DSOUND_H
#include "tc_sse.h"
int tc_ds_open(tc_cpu *cpu);
void tc_ds_close(tc_cpu *cpu);
void tc_direct_sound_create(_cpu *cpu);
void tc_ds_dispatch(_cpu *cpu, uint32_t method);
/* Native movie PCM shares the DirectSound mixer. Headless calls never start
 * the engine or allocate PCM queues. The key identifies one movie's lifetime. */
int tc_ds_movie_write(tc_cpu *cpu,void *key,uint32_t track,uint32_t rate,
    uint32_t channels,int planar,const float *const *samples,uint32_t count,int paused);
int tc_ds_movie_volume(tc_cpu *cpu,void *key,uint32_t track,uint32_t volume);
int tc_ds_movie_pause(tc_cpu *cpu,void *key,int paused);
void tc_ds_movie_clear(tc_cpu *cpu,void *key,int remove);
#endif
