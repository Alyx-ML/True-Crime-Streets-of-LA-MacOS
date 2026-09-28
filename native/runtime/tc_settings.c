#include "tc_settings.h"
#include <string.h>

static unsigned char *image_memory(const tc_image *image)
{
    if (!image || image->cpu.memory_size != (UINT64_C(1) << 32) || image->entry != 0x75d005)
        return NULL;
    return (unsigned char *)(uintptr_t)image->cpu.scalar._pointer_offset;
}

static uint32_t read_word(const unsigned char *memory, uint32_t address)
{
    uint32_t value;
    memcpy(&value, memory + address, sizeof(value));
    return value;
}

static void write_word(unsigned char *memory, uint32_t address, uint32_t value)
{
    memcpy(memory + address, &value, sizeof(value));
}

tc_graphics_settings tc_graphics_defaults(void)
{
    return (tc_graphics_settings){.adapter = 0, .width = 640, .height = 480,
        .bits_per_pixel = 32, .windowed = 0, .no_shaders = 0, .detail = 2};
}

int tc_graphics_read(const tc_image *image, tc_graphics_settings *settings)
{
    unsigned char *memory = image_memory(image);
    if (!memory || !settings) return -1;
    *settings = (tc_graphics_settings){
        .adapter = read_word(memory, 0x753074),
        .width = read_word(memory, 0x6b9b98),
        .height = read_word(memory, 0x6b9b9c),
        .bits_per_pixel = read_word(memory, 0x6b9ba0),
        .windowed = memory[0x753078] == 1,
        .no_shaders = memory[0x75158a] != 0,
        .detail = read_word(memory, 0x6b9ba4)
    };
    return 0;
}

int tc_graphics_validate(const tc_graphics_settings *settings)
{
    if (!settings) return -1;
    tc_graphics_settings value = *settings;
    return (!value.width || !value.height || value.width > 16384 || value.height > 16384 ||
        (value.bits_per_pixel != 16 && value.bits_per_pixel != 32) ||
        value.adapter > INT32_MAX || value.windowed > 1 || value.no_shaders > 1 || value.detail > 2) ? -1 : 0;
}

int tc_graphics_apply(tc_image *image, const tc_graphics_settings *settings)
{
    unsigned char *memory = image_memory(image);
    if (!memory || tc_graphics_validate(settings)) return -1;
    tc_graphics_settings value = *settings;

    /* Recovered from 0x61f960..0x61fa80. These globals' subsystem names remain
       unknown; retain their addresses rather than inventing graphics labels. */
    static const uint32_t detail_values[3][5] = {
        {0x3f800000, 0x42fa0000, 0x42c80000, 125, 10},
        {0x3fc00000, 0x43160000, 0x42fa0000, 150, 16},
        {0x40000000, 0x43480000, 0x43480000, 200, 24}
    };
    static const uint32_t detail_addresses[5] = {
        0x6b95a4, 0x6a8304, 0x6a8308, 0x6a830c, 0x6ae954
    };
    write_word(memory, 0x753074, value.adapter);
    write_word(memory, 0x6b9b98, value.width);
    write_word(memory, 0x6b9b9c, value.height);
    write_word(memory, 0x6b9ba0, value.bits_per_pixel);
    memory[0x753078] = (unsigned char)value.windowed;
    memory[0x75158a] = (unsigned char)value.no_shaders;
    write_word(memory, 0x6b9ba4, value.detail);
    for (unsigned i = 0; i < 5; ++i)
        write_word(memory, detail_addresses[i], detail_values[value.detail][i]);
    return 0;
}

static const tc_keyboard_action keyboard_actions[] = {
#include "tc_keyboard_bindings.inc"
};
_Static_assert(sizeof(keyboard_actions) / sizeof(keyboard_actions[0]) == TC_KEYBOARD_ACTION_COUNT,
               "Keyboard action count must match recovered metadata");

const tc_keyboard_action *tc_keyboard_action_at(unsigned index)
{
    return index < TC_KEYBOARD_ACTION_COUNT ? &keyboard_actions[index] : NULL;
}

tc_keyboard_settings tc_keyboard_defaults(void)
{
    tc_keyboard_settings settings;
    for (unsigned i = 0; i < TC_KEYBOARD_ACTION_COUNT; ++i)
        settings.scan_code[i] = keyboard_actions[i].default_scan_code;
    return settings;
}

int tc_keyboard_read(const tc_image *image, tc_keyboard_settings *settings)
{
    unsigned char *memory = image_memory(image);
    if (!memory || !settings) return -1;
    tc_keyboard_settings result;
    for (unsigned i = 0; i < TC_KEYBOARD_ACTION_COUNT; ++i)
        result.scan_code[i] = read_word(memory, keyboard_actions[i].guest_address);
    *settings = result;
    return 0;
}

int tc_keyboard_apply(tc_image *image, const tc_keyboard_settings *settings)
{
    unsigned char *memory = image_memory(image);
    if (!memory || !settings) return -1;
    tc_keyboard_settings value = *settings;
    for (unsigned i = 0; i < TC_KEYBOARD_ACTION_COUNT; ++i)
        if (value.scan_code[i] > 255) return -1;
    for (unsigned i = 0; i < TC_KEYBOARD_ACTION_COUNT; ++i)
        write_word(memory, keyboard_actions[i].guest_address, value.scan_code[i]);
    return 0;
}

#ifdef TC_SETTINGS_SELF_CHECK
#include <assert.h>
int main(int argc, char **argv)
{
    assert(argc == 2);
    tc_graphics_settings limits=tc_graphics_defaults();limits.width=limits.height=16384;
    assert(tc_graphics_validate(&limits)==0);limits.width=16385;
    assert(tc_graphics_validate(&limits)==-1);
    tc_image image = {0};
    char error[128];
    assert(tc_image_open(&image, argv[1], error, sizeof(error)) == 0);
    tc_graphics_settings value = tc_graphics_defaults(), readback;
    value.width = 1920;
    value.height = 1080;
    value.windowed = 1;
    assert(tc_graphics_apply(&image, &value) == 0);
    assert(tc_graphics_read(&image, &readback) == 0);
    assert(readback.width == 1920 && readback.height == 1080 && readback.windowed == 1);
    assert(read_word(image_memory(&image), 0x6a830c) == 200);
    value.detail = 0;
    assert(tc_graphics_apply(&image, &value) == 0);
    assert(read_word(image_memory(&image), 0x6ae954) == 10);
    value.detail = 3;
    value.width = 1280;
    assert(tc_graphics_apply(&image, &value) == -1);
    assert(tc_graphics_read(&image, &readback) == 0);
    assert(readback.width == 1920 && readback.detail == 0);
    tc_keyboard_settings keys = tc_keyboard_defaults(), key_readback;
    assert(keys.scan_code[0] == 17 && keys.scan_code[33] == 47);
    keys.scan_code[0] = 200;
    keys.scan_code[1] = 200; /* Context-dependent duplicate bindings are intentional. */
    assert(tc_keyboard_apply(&image, &keys) == 0);
    assert(tc_keyboard_read(&image, &key_readback) == 0);
    assert(key_readback.scan_code[0] == 200 && key_readback.scan_code[1] == 200);
    keys.scan_code[0] = 17;
    keys.scan_code[33] = 256;
    assert(tc_keyboard_apply(&image, &keys) == -1);
    assert(tc_keyboard_read(&image, &key_readback) == 0 && key_readback.scan_code[0] == 200);
    assert(tc_keyboard_action_at(TC_KEYBOARD_ACTION_COUNT) == NULL);
    tc_image_close(&image);
    assert(tc_graphics_apply(&image, &value) == -1);
    return 0;
}
#endif
