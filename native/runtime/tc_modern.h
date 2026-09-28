#ifndef TC_MODERN_H
#define TC_MODERN_H
#include "tc_sse.h"
#include "tc_input.h"
enum { TC_FRAME_LIMIT, TC_VSYNC, TC_METALFX, TC_DEADZONE, TC_LOOK_SPEED, TC_INVERT_LOOK, TC_INVERT_LOOK_X, TC_INVERT_MOVE_X, TC_INVERT_MOVE_Y, TC_SWAP_STICKS, TC_CONFIRM_B, TC_HDR, TC_MSAA, TC_UI_SCALE, TC_MODERN_COUNT };
void tc_modern_init(tc_cpu *cpu);
void tc_modern_close(tc_cpu *cpu);
unsigned tc_modern_get(tc_cpu *cpu, unsigned setting);
void tc_modern_set(tc_cpu *cpu, unsigned setting, unsigned value);
void tc_modern_input(tc_cpu *cpu, tc_input *input);
/* UI scale: the game lays out at a virtual 480-line resolution (its design size)
 * while the renderer outputs at the real ini resolution. */
/* Replace the output-size display mode with the virtual one (EnumAdapterModes). */
void tc_modern_virtual_mode(tc_cpu *cpu, uint32_t *width, uint32_t *height);
uint32_t tc_modern_real_screen(tc_cpu *cpu, int height, uint32_t value);
uint32_t tc_modern_virtual_screen(tc_cpu *cpu, int height, uint32_t width_value, uint32_t height_value);
void tc_modern_output(tc_cpu *cpu, uint32_t width, uint32_t height, uint32_t *out_width, uint32_t *out_height);
int tc_modern_button_bound(tc_cpu *cpu, unsigned button);
void tc_menu_refresh(_cpu *cpu, uint32_t screen, uint32_t controls);
void tc_menu_event(_cpu *cpu, uint32_t screen);
#endif
