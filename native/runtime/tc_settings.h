#ifndef TC_SETTINGS_H
#define TC_SETTINGS_H

#include "tc_image.h"

typedef struct {
    uint32_t adapter, width, height, bits_per_pixel;
    uint32_t windowed, no_shaders, detail;
} tc_graphics_settings;

tc_graphics_settings tc_graphics_defaults(void);
int tc_graphics_validate(const tc_graphics_settings *settings);
/* Return -1 without modifying output/state for invalid settings or unloaded images. */
int tc_graphics_read(const tc_image *image, tc_graphics_settings *settings);
int tc_graphics_apply(tc_image *image, const tc_graphics_settings *settings);

#define TC_KEYBOARD_ACTION_COUNT 34
typedef struct {
    const char *name;
    uint32_t default_scan_code, guest_address;
} tc_keyboard_action;

/* Values are DirectInput scan codes, not macOS key codes. Shared bindings are valid. */
typedef struct {
    uint32_t scan_code[TC_KEYBOARD_ACTION_COUNT];
} tc_keyboard_settings;

const tc_keyboard_action *tc_keyboard_action_at(unsigned index);
tc_keyboard_settings tc_keyboard_defaults(void);
int tc_keyboard_read(const tc_image *image, tc_keyboard_settings *settings);
int tc_keyboard_apply(tc_image *image, const tc_keyboard_settings *settings);

#endif
