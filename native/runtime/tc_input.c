#include "tc_input.h"
#include <string.h>
#include <math.h>

int tc_input_key(tc_input *input, unsigned scan_code, int pressed)
{
    if (!input || scan_code > 255 || (pressed != 0 && pressed != 1)) return -1;
    input->keyboard[scan_code] = pressed ? 0x80 : 0;
    return 0;
}

int tc_input_button(tc_input *input, unsigned button, int pressed)
{
    if (!input || button >= TC_PAD_BUTTON_COUNT || (pressed != 0 && pressed != 1)) return -1;
    input->controller[button] = (unsigned char)pressed;
    return 0;
}

int tc_input_bind_button(tc_input *input, unsigned button, uint64_t action_bits)
{
    if (!input || button >= TC_PAD_BUTTON_COUNT || (action_bits >> TC_KEYBOARD_ACTION_COUNT)) return -1;
    input->controller_actions[button] = action_bits;
    return 0;
}

int tc_input_sticks(tc_input *input,float lx,float ly,float rx,float ry)
{
    float values[]={lx,ly,rx,ry};
    if(!input)return -1;
    for(unsigned i=0;i<4;i++)if(!isfinite(values[i])||values[i]<-1||values[i]>1)return -1;
    memcpy(input->sticks,values,sizeof(values));return 0;
}
int tc_input_camera_delta(const tc_input *input,uint32_t speed,int invert_y,double elapsed,double delta[2])
{
    if(!input||!delta||input->stick_deadzone_percent>95||speed>5000||
       (invert_y!=0&&invert_y!=1)||!isfinite(elapsed)||elapsed<0)return -1;
    delta[0]=delta[1]=0;
    double x=input->sticks[2],y=input->sticks[3],length=hypot(x,y);
    double deadzone=input->stick_deadzone_percent/100.0;
    if(!isfinite(length)||length<=deadzone)return 0;
    /* Limit accumulated motion after a stall, rather than jumping the camera. */
    double scale=(fmin(length,1)-deadzone)/(1-deadzone)/length*speed*fmin(elapsed,0.1);
    delta[0]=x*scale;delta[1]=y*scale*(invert_y?1:-1);return 0;
}
void tc_input_release_controller(tc_input *input)
{
    if (input) {
        memset(input->controller, 0, sizeof(input->controller));
        memset(input->sticks, 0, sizeof(input->sticks));
    }
}

void tc_input_release_all(tc_input *input)
{
    if (!input) return;
    memset(input->keyboard, 0, sizeof(input->keyboard));
    tc_input_release_controller(input);
}

int tc_input_publish(const tc_input *input, tc_image *image)
{
    tc_keyboard_settings bindings;
    if (!input || tc_keyboard_read(image, &bindings)) return -1;
    unsigned char combined[256];
    for (unsigned key = 0; key < 256; ++key) combined[key] = input->keyboard[key] & 0x80;
    for (unsigned action = 0; action < TC_KEYBOARD_ACTION_COUNT; ++action)
        if (bindings.scan_code[action] > 255) return -1;
    for (unsigned button = 0; button < TC_PAD_BUTTON_COUNT; ++button) {
        if ((input->controller_actions[button] >> TC_KEYBOARD_ACTION_COUNT)||input->controller_keys[button]>255) return -1;
        if (!input->controller[button]) continue;
        if(input->controller_keys[button])combined[input->controller_keys[button]]=0x80;
        for (unsigned action = 0; action < TC_KEYBOARD_ACTION_COUNT; ++action)
            if (bindings.scan_code[action] && (input->controller_actions[button] & (UINT64_C(1) << action)))
                combined[bindings.scan_code[action]] = 0x80;
    }
    if(input->stick_deadzone_percent>95)return -1;
    float threshold=input->stick_deadzone_percent/100.0f;
    const unsigned actions[]={2,3,1,0};
    const float movement[]={-input->sticks[0],input->sticks[0],-input->sticks[1],input->sticks[1]};
    for(unsigned i=0;i<4;i++) {
        if(!isfinite(movement[i]))return -1;
        unsigned code=bindings.scan_code[actions[i]];
        if(code&&movement[i]>threshold)combined[code]=0x80;
    }
    /* 0x5e93f2 supplies this buffer to GetDeviceState; consumers test bit 7.
       Rebuild it each frame so a held button follows rebinding without stuck keys. */
    unsigned char *memory = (void *)(uintptr_t)image->cpu.scalar._pointer_offset;
    memcpy(memory + 0x72b8d8, combined, sizeof(combined));
    memcpy(image->cpu.input_keyboard, combined, sizeof(combined));
    return 0;
}

#ifdef TC_INPUT_SELF_CHECK
#include <assert.h>
int main(int argc, char **argv)
{
    assert(argc == 2);
    tc_image image = {0};
    tc_input input = {0};
    char error[128];
    assert(tc_image_open(&image, argv[1], error, sizeof(error)) == 0);
    tc_keyboard_settings keys = tc_keyboard_defaults();
    assert(tc_keyboard_apply(&image, &keys) == 0);
    unsigned char *state_bytes = (void *)(uintptr_t)(image.cpu.scalar._pointer_offset + 0x72b8d8);
    assert(tc_input_bind_button(&input, TC_PAD_A, 1) == 0);
    assert(tc_input_button(&input, TC_PAD_A, 1) == 0);
    assert(tc_input_key(&input, 17, 1) == 0);
    tc_input_release_controller(&input);
    assert(tc_input_publish(&input, &image) == 0 && state_bytes[17] == 0x80);
    assert(tc_input_key(&input, 17, 0) == 0);
    assert(tc_input_publish(&input, &image) == 0 && state_bytes[17] == 0);
    assert(tc_input_button(&input, TC_PAD_A, 1) == 0);
    assert(tc_input_publish(&input, &image) == 0 && state_bytes[17] == 0x80);
    assert(tc_input_bind_button(&input, TC_PAD_A, 2) == 0);
    assert(tc_input_publish(&input, &image) == 0 && state_bytes[17] == 0 && state_bytes[31] == 0x80);
    assert(tc_input_bind_button(&input, TC_PAD_A, UINT64_C(1) << 34) == -1);
    tc_input_release_all(&input);
    assert(tc_input_publish(&input, &image) == 0 && state_bytes[31] == 0);
    input.stick_deadzone_percent=20;
    assert(tc_input_sticks(&input,0,1,1,0)==0);
    assert(tc_input_publish(&input,&image)==0&&state_bytes[17]==0x80);
    double delta[2];assert(tc_input_camera_delta(&input,1000,0,.01,delta)==0&&fabs(delta[0]-10)<1e-6&&delta[1]==0);
    assert(tc_input_sticks(&input,0,0,0,.1f)==0);
    assert(tc_input_camera_delta(&input,1000,0,.01,delta)==0&&delta[0]==0&&delta[1]==0);
    assert(tc_input_sticks(&input,0,0,0,1)==0);
    assert(tc_input_camera_delta(&input,1000,1,.01,delta)==0&&fabs(delta[1]-10)<1e-6);
    assert(tc_input_sticks(&input,NAN,0,0,0)==-1);
    tc_input_release_controller(&input);assert(input.sticks[3]==0);
    input.controller_keys[TC_PAD_MENU]=1;tc_input_button(&input,TC_PAD_MENU,1);
    assert(tc_input_publish(&input,&image)==0&&state_bytes[1]==0x80);
    input.controller_keys[TC_PAD_MENU]=28;
    assert(tc_input_publish(&input,&image)==0&&!state_bytes[1]&&state_bytes[28]==0x80);
    tc_input_release_controller(&input);
    assert(tc_input_publish(&input,&image)==0&&!state_bytes[28]&&input.controller_keys[TC_PAD_MENU]==28);
    input.controller_keys[TC_PAD_MENU]=256;assert(tc_input_publish(&input,&image)==-1);
    tc_image_close(&image);
    return 0;
}
#endif
