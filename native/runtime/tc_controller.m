#include <SDL3/SDL.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include "tc_controller.h"

/* Every connected device stays open; input comes from the one used last,
 * so switching controllers (or pads) needs no menu action. */
typedef struct { SDL_JoystickID id; SDL_Gamepad *gamepad; SDL_Joystick *joystick; } Device;
static Device devices[8];
static int device_count, initialized;
static SDL_JoystickID active_id;

static float axis_value(Sint16 value)
{
    return value < 0 ? value / 32768.0f : value / 32767.0f;
}

static Device *find_device(SDL_JoystickID id)
{
    for (int i = 0; i < device_count; ++i) if (devices[i].id == id) return &devices[i];
    return NULL;
}

static void choose_active(void)
{
    active_id = 0;
    for (int i = 0; i < device_count && !active_id; ++i) if (devices[i].gamepad) active_id = devices[i].id;
    if (!active_id && device_count) active_id = devices[0].id;
}

static void close_device(SDL_JoystickID id)
{
    Device *d = find_device(id);
    if (!d) return;
    fprintf(stderr, "SDL3 controller disconnected: %s\n", SDL_GetJoystickName(d->joystick));
    if (d->gamepad) SDL_CloseGamepad(d->gamepad); else SDL_CloseJoystick(d->joystick);
    *d = devices[--device_count];
    if (active_id == id) choose_active();
}

static void open_device(SDL_JoystickID id)
{
    Device *existing = find_device(id);
    /* A mapping can arrive after the joystick: reopen it as a gamepad. */
    if (existing && (existing->gamepad || !SDL_IsGamepad(id))) return;
    if (existing) close_device(id);
    if (device_count == (int)(sizeof(devices) / sizeof(*devices))) return;
    Device d = {id, NULL, NULL};
    if (SDL_IsGamepad(id)) {
        d.gamepad = SDL_OpenGamepad(id);
        if (d.gamepad) d.joystick = SDL_GetGamepadJoystick(d.gamepad);
    } else {
        d.joystick = SDL_OpenJoystick(id);
        /* Skip HID devices that are not controllers (too few buttons to play). */
        if (d.joystick && SDL_GetNumJoystickButtons(d.joystick) < 4) {
            SDL_CloseJoystick(d.joystick); return;
        }
    }
    if (!d.joystick) {
        fprintf(stderr, "SDL3 controller open failed: %s\n", SDL_GetError());
        return;
    }
    devices[device_count++] = d;
    fprintf(stderr, "SDL3 controller connected: %s (%s)\n", SDL_GetJoystickName(d.joystick),
        d.gamepad ? "gamepad mapping" : "generic joystick");
    Device *active = find_device(active_id);
    if (!active || (d.gamepad && !active->gamepad)) active_id = id;
}

static void activity(tc_input *input, SDL_JoystickID id)
{
    if (!find_device(id)) return;
    active_id = id;
    input->controller_active = 1;
}

void tc_controller_close(void)
{
    while (device_count) close_device(devices[0].id);
    if (initialized) SDL_QuitSubSystem(SDL_INIT_GAMEPAD);
    initialized = 0;
}

int tc_controller_poll(tc_input *input)
{
    if (!input) return -1;
    tc_input_release_controller(input);
    if (!initialized) {
        /* AppKit owns the window and gates input; SDL has no focused window. */
        SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
        /* HIDAPI drivers give full PlayStation/Xbox/Switch support over USB and Bluetooth. */
        SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "1");
        SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_PS4, "1");
        SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_PS5, "1");
        SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_XBOX, "1");
        /* Gamepad initialization includes joysticks and events, never audio/video. */
        if (!SDL_InitSubSystem(SDL_INIT_GAMEPAD)) {
            fprintf(stderr, "SDL3 controller initialization failed: %s\n", SDL_GetError());
            return -1;
        }
        initialized = 1;
        SDL_SetGamepadEventsEnabled(true);
        SDL_SetJoystickEventsEnabled(true);
        int count = 0;
        SDL_JoystickID *ids = SDL_GetJoysticks(&count);
        for (int i = 0; ids && i < count; ++i) open_device(ids[i]);
        SDL_free(ids);
    }
    SDL_PumpEvents();
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        switch (event.type) {
        case SDL_EVENT_JOYSTICK_ADDED: open_device(event.jdevice.which); break;
        case SDL_EVENT_GAMEPAD_ADDED: open_device(event.gdevice.which); break;
        case SDL_EVENT_JOYSTICK_REMOVED: close_device(event.jdevice.which); break;
        case SDL_EVENT_GAMEPAD_BUTTON_DOWN: activity(input, event.gbutton.which); break;
        case SDL_EVENT_GAMEPAD_AXIS_MOTION:
            if (abs(event.gaxis.value) > 16000) activity(input, event.gaxis.which);
            break;
        case SDL_EVENT_JOYSTICK_BUTTON_DOWN: {
            Device *d = find_device(event.jbutton.which);
            if (d && !d->gamepad) activity(input, d->id);
            break;
        }
        case SDL_EVENT_JOYSTICK_HAT_MOTION: {
            Device *d = find_device(event.jhat.which);
            if (d && !d->gamepad && event.jhat.value) activity(input, d->id);
            break;
        }
        case SDL_EVENT_JOYSTICK_AXIS_MOTION: {
            /* Generic triggers rest at -32768: count movement from the initial state. */
            Device *d = find_device(event.jaxis.which);
            Sint16 rest = 0;
            if (d && !d->gamepad) SDL_GetJoystickAxisInitialState(d->joystick, event.jaxis.axis, &rest);
            if (d && !d->gamepad && abs(event.jaxis.value - rest) > 16000) activity(input, d->id);
            break;
        }
        default: break;
        }
    }
    SDL_UpdateGamepads();
    input->controller_connected = 0; input->controller_name[0] = 0;
    Device *d = find_device(active_id);
    if (!d) { input->controller_active = 0; return 0; }
    input->controller_connected = 1;
    const char *name = d->gamepad ? SDL_GetGamepadName(d->gamepad) : SDL_GetJoystickName(d->joystick);
    if (device_count > 1)
        snprintf(input->controller_name, sizeof(input->controller_name), "%s (+%d)", name ? name : "Generic Controller", device_count - 1);
    else
        snprintf(input->controller_name, sizeof(input->controller_name), "%s", name ? name : "Generic Controller");
    if (d->gamepad) {
        SDL_Gamepad *gamepad = d->gamepad;
        static const SDL_GamepadButton buttons[TC_PAD_BUTTON_COUNT] = {
            [TC_PAD_A] = SDL_GAMEPAD_BUTTON_SOUTH,
            [TC_PAD_B] = SDL_GAMEPAD_BUTTON_EAST,
            [TC_PAD_X] = SDL_GAMEPAD_BUTTON_WEST,
            [TC_PAD_Y] = SDL_GAMEPAD_BUTTON_NORTH,
            [TC_PAD_LEFT_SHOULDER] = SDL_GAMEPAD_BUTTON_LEFT_SHOULDER,
            [TC_PAD_RIGHT_SHOULDER] = SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER,
            [TC_PAD_LEFT_TRIGGER] = SDL_GAMEPAD_BUTTON_INVALID,
            [TC_PAD_RIGHT_TRIGGER] = SDL_GAMEPAD_BUTTON_INVALID,
            [TC_PAD_LEFT_STICK] = SDL_GAMEPAD_BUTTON_LEFT_STICK,
            [TC_PAD_RIGHT_STICK] = SDL_GAMEPAD_BUTTON_RIGHT_STICK,
            [TC_PAD_UP] = SDL_GAMEPAD_BUTTON_DPAD_UP,
            [TC_PAD_DOWN] = SDL_GAMEPAD_BUTTON_DPAD_DOWN,
            [TC_PAD_LEFT] = SDL_GAMEPAD_BUTTON_DPAD_LEFT,
            [TC_PAD_RIGHT] = SDL_GAMEPAD_BUTTON_DPAD_RIGHT,
            [TC_PAD_MENU] = SDL_GAMEPAD_BUTTON_START,
            [TC_PAD_OPTIONS] = SDL_GAMEPAD_BUTTON_BACK
        };
        for (unsigned i = 0; i < TC_PAD_BUTTON_COUNT; ++i)
            if (buttons[i] != SDL_GAMEPAD_BUTTON_INVALID)
                tc_input_button(input, i, SDL_GetGamepadButton(gamepad, buttons[i]));
        tc_input_button(input, TC_PAD_LEFT_TRIGGER,
            SDL_GetGamepadAxis(gamepad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) > 16383);
        tc_input_button(input, TC_PAD_RIGHT_TRIGGER,
            SDL_GetGamepadAxis(gamepad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) > 16383);
        return tc_input_sticks(input,
            axis_value(SDL_GetGamepadAxis(gamepad, SDL_GAMEPAD_AXIS_LEFTX)),
            -axis_value(SDL_GetGamepadAxis(gamepad, SDL_GAMEPAD_AXIS_LEFTY)),
            axis_value(SDL_GetGamepadAxis(gamepad, SDL_GAMEPAD_AXIS_RIGHTX)),
            -axis_value(SDL_GetGamepadAxis(gamepad, SDL_GAMEPAD_AXIS_RIGHTY))) ? -1 : 1;
    }
    /* ponytail: unmapped devices expose the first 16 buttons and four axes;
     * use an SDL gamepad mapping for device-specific axis layouts. */
    int count = SDL_GetNumJoystickButtons(d->joystick);
    for (unsigned i = 0; i < TC_PAD_BUTTON_COUNT && (int)i < count; ++i)
        tc_input_button(input, i, SDL_GetJoystickButton(d->joystick, i));
    if (SDL_GetNumJoystickHats(d->joystick) > 0) {
        Uint8 hat = SDL_GetJoystickHat(d->joystick, 0);
        const Uint8 directions[] = {SDL_HAT_UP, SDL_HAT_DOWN, SDL_HAT_LEFT, SDL_HAT_RIGHT};
        for (unsigned i = 0; i < 4; ++i)
            tc_input_button(input, TC_PAD_UP + i,
                input->controller[TC_PAD_UP + i] || (hat & directions[i]));
    }
    float axes[4] = {0};
    count = SDL_GetNumJoystickAxes(d->joystick);
    for (int i = 0; i < 4 && i < count; ++i)
        axes[i] = axis_value(SDL_GetJoystickAxis(d->joystick, i));
    return tc_input_sticks(input, axes[0], -axes[1], axes[2], -axes[3]) ? -1 : 1;
}

#ifdef TC_CONTROLLER_SELF_CHECK
#include <assert.h>
/* Build with -DTC_CONTROLLER_SELF_CHECK and link tc_input plus SDL3. */
int main(void)
{
    assert(axis_value(-32768) == -1.0f);
    assert(axis_value(32767) == 1.0f);
    assert(axis_value(0) == 0.0f);
    tc_input input = {0};
    tc_input_key(&input, 17, 1);
    tc_input_bind_button(&input, TC_PAD_A, 1);
    tc_input_button(&input, TC_PAD_A, 1);
    tc_input_release_controller(&input);
    assert(input.controller[TC_PAD_A] == 0);
    assert(input.keyboard[17] == 0x80);
    assert(input.controller_actions[TC_PAD_A] == 1);
    assert(tc_controller_poll(NULL) == -1);
    SDL_VirtualJoystickDesc desc={0};SDL_INIT_INTERFACE(&desc);
    desc.type=SDL_JOYSTICK_TYPE_GAMEPAD;desc.naxes=6;desc.nbuttons=SDL_GAMEPAD_BUTTON_COUNT;
    desc.button_mask=(1u<<SDL_GAMEPAD_BUTTON_COUNT)-1;desc.axis_mask=63;
    desc.name="Name entry virtual controller";
    assert(SDL_InitSubSystem(SDL_INIT_GAMEPAD));
    SDL_JoystickID id=SDL_AttachVirtualJoystick(&desc);assert(id);
    SDL_Joystick *virtualPad=SDL_OpenJoystick(id);assert(virtualPad);
    assert(tc_controller_poll(&input)==1);
    assert(SDL_SetJoystickVirtualButton(virtualPad,SDL_GAMEPAD_BUTTON_SOUTH,true));
    assert(SDL_SetJoystickVirtualAxis(virtualPad,SDL_GAMEPAD_AXIS_LEFTX,20000));
    assert(tc_controller_poll(&input)==1);
    assert(input.controller[TC_PAD_A]&&input.sticks[0]>0.5f&&input.controller_active);
    assert(SDL_SetJoystickVirtualButton(virtualPad,SDL_GAMEPAD_BUTTON_SOUTH,false));
    assert(SDL_SetJoystickVirtualAxis(virtualPad,SDL_GAMEPAD_AXIS_LEFTX,0));
    tc_controller_poll(&input);assert(!input.controller[TC_PAD_A]);
    /* A second pad takes over as soon as it is used, and hands back on disconnect. */
    desc.name="Second virtual controller";
    SDL_JoystickID second=SDL_AttachVirtualJoystick(&desc);assert(second);
    SDL_Joystick *secondPad=SDL_OpenJoystick(second);assert(secondPad);
    assert(tc_controller_poll(&input)==1&&strstr(input.controller_name,"(+1)"));
    assert(SDL_SetJoystickVirtualButton(secondPad,SDL_GAMEPAD_BUTTON_EAST,true));
    tc_controller_poll(&input);
    assert(input.controller[TC_PAD_B]&&!strncmp(input.controller_name,"Second",6));
    SDL_CloseJoystick(secondPad);assert(SDL_DetachVirtualJoystick(second));
    tc_controller_poll(&input);assert(!strncmp(input.controller_name,"Name entry",10));
    SDL_CloseJoystick(virtualPad);assert(SDL_DetachVirtualJoystick(id));
    assert(tc_controller_poll(&input)==0&&!input.controller_connected);
    fprintf(stderr,"SDL3 virtual controller check passed: discovery, button, stick, activity, release, disconnect.\n");
    tc_controller_close();
    return 0;
}
#endif
