#ifndef TC_PREFERENCES_H
#define TC_PREFERENCES_H
#include "tc_input.h"

typedef struct {
    tc_graphics_settings graphics;
    tc_keyboard_settings keyboard;
    uint32_t stick_deadzone_percent, camera_speed, camera_invert_y;
    uint64_t controller_actions[TC_PAD_BUTTON_COUNT];
    uint32_t controller_keys[TC_PAD_BUTTON_COUNT];
} tc_preferences;

tc_preferences tc_preferences_defaults(void);
/* Apply on the game thread before input publication; invalid values leave state unchanged. */
int tc_preferences_apply(tc_image *image, tc_input *input, const tc_preferences *value);
/* Versioned property-list file. Parent directory must exist. Return 0 or -1.
 * Load failures preserve output; save replaces the file atomically. */
int tc_preferences_load(const char *path, tc_preferences *output);
int tc_preferences_save(const char *path, const tc_preferences *value);
#endif
