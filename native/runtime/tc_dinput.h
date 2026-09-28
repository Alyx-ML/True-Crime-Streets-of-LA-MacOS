#ifndef TC_DINPUT_H
#define TC_DINPUT_H
#include "tc_sse.h"
void tc_direct_input_create(_cpu *cpu);
void tc_di_dispatch(_cpu *cpu, uint32_t method);
void tc_di_close(tc_cpu *cpu);
#endif
