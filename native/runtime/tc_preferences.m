#import <Foundation/Foundation.h>
#include "tc_preferences.h"
#include <math.h>
#include <string.h>

#define GRAPHICS_FIELDS(X) X(adapter) X(width) X(height) X(bits_per_pixel) X(windowed) X(no_shaders) X(detail)

static int valid(const tc_preferences *value)
{
    if (!value || tc_graphics_validate(&value->graphics) || value->stick_deadzone_percent>95 ||
        value->camera_speed>5000 || value->camera_invert_y>1) return 0;
    for (unsigned i = 0; i < TC_KEYBOARD_ACTION_COUNT; ++i)
        if (value->keyboard.scan_code[i] > 255) return 0;
    for (unsigned i = 0; i < TC_PAD_BUTTON_COUNT; ++i)
        if ((value->controller_actions[i] >> TC_KEYBOARD_ACTION_COUNT)||value->controller_keys[i]>255) return 0;
    return 1;
}

int tc_preferences_apply(tc_image *image, tc_input *input, const tc_preferences *value)
{
    if (!input || !valid(value)) return -1;
    if (tc_graphics_apply(image, &value->graphics)) return -1;
    /* Both settings APIs use the same loaded-image guard. Values were validated
       before any writes; the keyboard apply cannot fail after graphics apply. */
    if (tc_keyboard_apply(image, &value->keyboard)) abort();
    input->stick_deadzone_percent=value->stick_deadzone_percent;
    memcpy(input->controller_actions, value->controller_actions, sizeof(value->controller_actions));
    memcpy(input->controller_keys,value->controller_keys,sizeof(value->controller_keys));
    return 0;
}

tc_preferences tc_preferences_defaults(void)
{
    tc_preferences value = {0};
    value.graphics = tc_graphics_defaults();
    value.keyboard = tc_keyboard_defaults();
    value.stick_deadzone_percent=20;value.camera_speed=900;
    value.controller_keys[TC_PAD_A]=28;value.controller_keys[TC_PAD_B]=1;value.controller_keys[TC_PAD_MENU]=1;
    value.controller_keys[TC_PAD_UP]=200;value.controller_keys[TC_PAD_DOWN]=208;
    value.controller_keys[TC_PAD_LEFT]=203;value.controller_keys[TC_PAD_RIGHT]=205;
    return value;
}

static int number(id object, uint64_t maximum, uint64_t *output)
{
    if (![object isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)object) == CFBooleanGetTypeID()) return 0;
    double value = [object doubleValue];
    if (!isfinite(value) || value < 0 || value > maximum || floor(value) != value) return 0;
    *output = (uint64_t)value;
    return 1;
}

static int decode(id object, tc_preferences *output)
{
    if (![object isKindOfClass:NSDictionary.class]) return -1;
    NSDictionary *document = object;
    uint64_t value;
    if (!number(document[@"version"], 3, &value) || value < 1) return -1;
    uint64_t version=value;
    id graphics = document[@"graphics"], keys = document[@"keyboard"], pad = document[@"controller"];
    if (![graphics isKindOfClass:NSDictionary.class] || ![keys isKindOfClass:NSArray.class] ||
        ![pad isKindOfClass:NSArray.class] || [keys count] != TC_KEYBOARD_ACTION_COUNT ||
        [pad count] != TC_PAD_BUTTON_COUNT) return -1;
    tc_preferences result = tc_preferences_defaults();
    /* Older documents had no direct controller keys. Keep their bindings exact. */
    memset(result.controller_keys,0,sizeof(result.controller_keys));
    if(version>=2) {
        if(!number(document[@"stickDeadzonePercent"],95,&value))return -1;result.stick_deadzone_percent=(uint32_t)value;
        if(!number(document[@"cameraSpeed"],5000,&value))return -1;result.camera_speed=(uint32_t)value;
        if(!number(document[@"cameraInvertY"],1,&value))return -1;result.camera_invert_y=(uint32_t)value;
    }
#define READ(name) if (!number(graphics[@#name], UINT32_MAX, &value)) return -1; result.graphics.name = (uint32_t)value;
    GRAPHICS_FIELDS(READ)
#undef READ
    for (unsigned i = 0; i < TC_KEYBOARD_ACTION_COUNT; ++i) {
        if (!number(keys[i], 255, &value)) return -1;
        result.keyboard.scan_code[i] = (uint32_t)value;
    }
    for (unsigned i = 0; i < TC_PAD_BUTTON_COUNT; ++i) {
        if (!number(pad[i], (UINT64_C(1) << TC_KEYBOARD_ACTION_COUNT) - 1, &value)) return -1;
        result.controller_actions[i] = value;
    }
    if(version>=3) {
        id direct=document[@"controllerKeys"];
        if(![direct isKindOfClass:NSArray.class]||[direct count]!=TC_PAD_BUTTON_COUNT)return -1;
        for(unsigned i=0;i<TC_PAD_BUTTON_COUNT;i++) {
            if(!number(direct[i],255,&value))return -1;result.controller_keys[i]=(uint32_t)value;
        }
    }
    if (!valid(&result)) return -1;
    *output = result;
    return 0;
}

int tc_preferences_load(const char *path, tc_preferences *output)
{
    if (!path || !output) return -1;
    @autoreleasepool {
        NSString *name = [NSString stringWithUTF8String:path];
        if (!name) return -1;
        NSData *data = [NSData dataWithContentsOfFile:name];
        if (!data || data.length > 65536) return -1;
        id document = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                               format:NULL error:NULL];
        return decode(document, output);
    }
}

int tc_preferences_save(const char *path, const tc_preferences *value)
{
    if (!path || !valid(value)) return -1;
    @autoreleasepool {
        NSString *name = [NSString stringWithUTF8String:path];
        if (!name) return -1;
        NSMutableDictionary *graphics = [NSMutableDictionary dictionary];
#define WRITE(field) graphics[@#field] = @(value->graphics.field);
        GRAPHICS_FIELDS(WRITE)
#undef WRITE
        NSMutableArray *keys = [NSMutableArray array], *pad = [NSMutableArray array],*direct=[NSMutableArray array];
        for (unsigned i = 0; i < TC_KEYBOARD_ACTION_COUNT; ++i) [keys addObject:@(value->keyboard.scan_code[i])];
        for (unsigned i = 0; i < TC_PAD_BUTTON_COUNT; ++i) [pad addObject:@(value->controller_actions[i])];
        for(unsigned i=0;i<TC_PAD_BUTTON_COUNT;i++)[direct addObject:@(value->controller_keys[i])];
        NSDictionary *document = @{@"version": @3, @"controllerKeys":direct,@"stickDeadzonePercent": @(value->stick_deadzone_percent),
            @"cameraSpeed": @(value->camera_speed), @"cameraInvertY": @(value->camera_invert_y), @"graphics": graphics, @"keyboard": keys, @"controller": pad};
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:document format:NSPropertyListXMLFormat_v1_0
                                                               options:0 error:NULL];
        return data && [data writeToFile:name options:NSDataWritingAtomic error:NULL] ? 0 : -1;
    }
}

#ifdef TC_PREFERENCES_SELF_CHECK
#include <assert.h>
int main(void)
{
    @autoreleasepool {
        tc_preferences value = tc_preferences_defaults(), loaded = {0};
        value.graphics.width = 1920;value.stick_deadzone_percent=30;value.camera_speed=1200;value.camera_invert_y=1;
        value.controller_actions[TC_PAD_A] = (UINT64_C(1) << 33) | 1;
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert(tc_preferences_save(path.fileSystemRepresentation, &value) == 0);
        assert(tc_preferences_load(path.fileSystemRepresentation, &loaded) == 0);
        assert(loaded.graphics.width == 1920 && loaded.controller_actions[TC_PAD_A] == value.controller_actions[TC_PAD_A]);
        assert(loaded.controller_keys[TC_PAD_A]==28&&loaded.controller_keys[TC_PAD_MENU]==1);
        assert(decode(@{@"version": @2}, &loaded) == -1 && loaded.graphics.width == 1920);
        assert(loaded.stick_deadzone_percent==30&&loaded.camera_speed==1200&&loaded.camera_invert_y==1);
        NSMutableDictionary *legacy=[[NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:path]
            options:NSPropertyListMutableContainers format:NULL error:NULL]mutableCopy];
        legacy[@"version"]=@1;[legacy removeObjectsForKeys:@[@"stickDeadzonePercent",@"cameraSpeed",@"cameraInvertY"]];
        assert(decode(legacy,&loaded)==0&&loaded.graphics.width==1920&&loaded.controller_actions[TC_PAD_A]==value.controller_actions[TC_PAD_A]);
        assert(loaded.stick_deadzone_percent==20&&loaded.camera_speed==900&&!loaded.camera_invert_y);
        for(unsigned i=0;i<TC_PAD_BUTTON_COUNT;i++)assert(!loaded.controller_keys[i]);
        legacy[@"version"]=@2;legacy[@"stickDeadzonePercent"]=@30;legacy[@"cameraSpeed"]=@1200;legacy[@"cameraInvertY"]=@1;
        assert(decode(legacy,&loaded)==0&&!loaded.controller_keys[TC_PAD_A]&&loaded.camera_speed==1200);
        uint64_t result;
        assert(!number(@YES, 255, &result) && !number(@1.5, 255, &result));
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
    return 0;
}
#endif
