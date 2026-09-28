#ifndef TC_HOST_H
#define TC_HOST_H
#include "tc_image.h"
/* Main thread: initialize after image_open, before starting translated game code
 * on a worker thread. The application must keep its AppKit event loop running.
 * Close only after the game worker stops, before image_close. Returns 0 or -1. */
int tc_host_open(tc_image *image, const char *preferences_path);
void tc_host_close(tc_image *image);
void tc_window_register(_cpu *cpu);
void tc_window_create(_cpu *cpu);
void tc_window_default(_cpu *cpu);
void tc_window_class_name(_cpu *cpu);
void tc_window_text(_cpu *cpu);
void tc_windows_enum(_cpu *cpu);
void tc_window_long(_cpu *cpu);
void tc_window_destroy(_cpu *cpu);
void tc_window_unregister(_cpu *cpu);
void tc_window_show(_cpu *cpu);
void tc_message_peek(_cpu *cpu);
void tc_message_dispatch(_cpu *cpu);
void tc_message_translate(_cpu *cpu);
void tc_window_adjust(_cpu *cpu);
void tc_desktop_window(_cpu *cpu);
void tc_system_metrics(_cpu *cpu);
void tc_window_move(_cpu *cpu);
void tc_window_foreground(_cpu *cpu);
void tc_window_activate(_cpu *cpu);
void tc_window_focus(_cpu *cpu);
void tc_window_update(_cpu *cpu);
void tc_async_key(_cpu *cpu);
void tc_stock_object(_cpu *cpu);
void tc_window_hook_install(_cpu *cpu);
void tc_icon_load(_cpu *cpu);
void tc_cursor_load(_cpu *cpu);
void tc_cursor_show(_cpu *cpu);
void tc_system_language(_cpu *cpu);
#endif
