#ifndef TC_INPUT_H
#define TC_INPUT_H

#include "tc_settings.h"

typedef enum {
    TC_PAD_A, TC_PAD_B, TC_PAD_X, TC_PAD_Y,
    TC_PAD_LEFT_SHOULDER, TC_PAD_RIGHT_SHOULDER,
    TC_PAD_LEFT_TRIGGER, TC_PAD_RIGHT_TRIGGER,
    TC_PAD_LEFT_STICK, TC_PAD_RIGHT_STICK,
    TC_PAD_UP, TC_PAD_DOWN, TC_PAD_LEFT, TC_PAD_RIGHT,
    TC_PAD_MENU, TC_PAD_OPTIONS, TC_PAD_BUTTON_COUNT
} tc_pad_button;

typedef struct {
    unsigned char keyboard[256], controller[TC_PAD_BUTTON_COUNT];
    uint64_t controller_actions[TC_PAD_BUTTON_COUNT];
    uint32_t controller_keys[TC_PAD_BUTTON_COUNT]; /* DirectInput scan code; zero unbinds. */
    int controller_connected;
    int controller_active; /* Last deliberate input source; zero is keyboard/mouse. */
    char controller_name[96];
    float sticks[4]; /* Left x/y, right x/y; positive y points upward. */
    uint32_t stick_deadzone_percent;
} tc_input;

/* Zero initialization leaves controller buttons unbound. Calls must be serialized. */
int tc_input_key(tc_input *input, unsigned scan_code, int pressed);
int tc_input_button(tc_input *input, unsigned button, int pressed);
/* Bit i names keyboard action i from tc_keyboard_action_at. Zero unbinds. */
int tc_input_bind_button(tc_input *input, unsigned button, uint64_t action_bits);
int tc_input_sticks(tc_input *input, float lx, float ly, float rx, float ry);
int tc_input_camera_delta(const tc_input *input, uint32_t speed, int invert_y, double elapsed, double delta[2]);
void tc_input_release_controller(tc_input *input);
void tc_input_release_all(tc_input *input);
/* Publish immediately before game input consumption, replacing GetDeviceState output. */
int tc_input_publish(const tc_input *input, tc_image *image);

#endif
