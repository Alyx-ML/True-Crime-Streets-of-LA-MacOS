#ifndef TC_D3D8_H
#define TC_D3D8_H
#include "tc_sse.h"
/* Called by statically emitted guest procedures, never by executing x86 code. */
void tc_direct_create(_cpu *cpu);
void tc_d3d_dispatch(_cpu *cpu, uint32_t method);
uint32_t tc_d3d_surface_format(tc_cpu *cpu,uint32_t address);
void tc_d3d_close(tc_cpu *cpu);
int tc_d3d_resize(tc_cpu *cpu, uint32_t width, uint32_t height);
#ifdef __OBJC__
@class CAMetalLayer;
/* Host attaches its view's layer before guest device creation. Serialized with rendering. */
int tc_d3d_attach(tc_cpu *cpu, CAMetalLayer *layer);
#endif
#endif
