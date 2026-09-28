#ifndef TC_BINK_H
#define TC_BINK_H
#include "tc_sse.h"
int tc_bink_init(tc_cpu *cpu);
void tc_bink_destroy(tc_cpu *cpu);
void tc_bink_sound(_cpu *cpu);
void tc_bink_open(_cpu *cpu);
void tc_bink_close(_cpu *cpu);
void tc_bink_frame(_cpu *cpu);
void tc_bink_next(_cpu *cpu);
void tc_bink_wait(_cpu *cpu);
void tc_bink_pause(_cpu *cpu);
void tc_bink_copy(_cpu *cpu);
void tc_bink_error(_cpu *cpu);
void tc_bink_surface(_cpu *cpu);
void tc_bink_video(_cpu *cpu);
void tc_bink_volume(_cpu *cpu);
void tc_bink_logo(_cpu *cpu);
void tc_bink_directsound(_cpu *cpu);
#endif
