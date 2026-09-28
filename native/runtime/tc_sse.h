#ifndef TC_SSE_H
#define TC_SSE_H

#include <stddef.h>
#include "llasm_cpu.h"

#define TC_TLS_SLOTS 1088
struct tc_tls_process;
struct tc_heap_process;
struct tc_vm_process;
struct tc_sync_process;
struct tc_process;
struct tc_threads;

/* All SSE-enabled translated entry points require this complete allocation.
 * The upstream scalar CPU remains the prefix consumed by generated LLVM code.
 * memory_size bounds the contiguous guest memory based at _pointer_offset.
 */
typedef struct {
    _cpu scalar;
    uint32_t xmm[8][4];
    size_t memory_size;
    uint32_t mxcsr;
    struct tc_tls_process *tls_process;
    struct tc_heap_process *heap_process;
    uint32_t tls_value[TC_TLS_SLOTS];
    uint64_t tls_generation[TC_TLS_SLOTS];
    uint32_t fs_base, fs_size;
    uint32_t x87_result_address; /* Eight guest bytes reserved per CPU. */
    void *graphics; /* Retained native D3D8-to-Metal context; owned by image. */
    void *platform;
    void (*frame_input)(_cpu *cpu); /* Host snapshots input at BeginScene. */
    void *directinput;
    unsigned char input_keyboard[256];
    void (*read_mouse)(_cpu *cpu, int32_t axes[3], unsigned char buttons[8]);
    uint32_t command_line_address;
    struct tc_vm_process *vm_process;
    struct tc_sync_process *sync_process;
    void *files;
    struct tc_process *process;
    void (*guest_invoke)(_cpu *cpu,uint32_t address);
    int (*prepare_graphics)(_cpu *cpu,uint32_t parameters[13]);
    struct tc_threads *threads;
    void *audio; /* Process audio context shared by guest threads. */
    void *bink; /* Shared native movie decoder state. */
    int headless; /* No host windows, input capture or audio device access. */
    int audio_disabled; /* Keep the visible game independent of audio devices. */
    int (*read_controller)(_cpu *cpu,int32_t axes[8],uint32_t pov[4],unsigned char buttons[128]);
    void *modern; /* Native options shared by the original menus and Metal/SDL3. */
} tc_cpu;

/* Set this explicitly when creating a guest CPU; a zero MXCSR unmasks faults. */
#define TC_MXCSR_DEFAULT 0x1f80u
void tc_store_fence(void);
void tc_import_dispatch(_cpu *cpu, uint32_t slot);
/* Only call for the hash-validated image and matching generated import thunks. */
void tc_imports_install(_cpu *cpu);
uint32_t tc_read_fs(_cpu *cpu, uint32_t offset);
void tc_write_fs(_cpu *cpu, uint32_t offset, uint32_t value);
uint32_t tc_x87_result(_cpu *cpu, const void *value);

void tc_xmm_copy(_cpu *cpu, uint32_t destination, uint32_t source);
void tc_xmm_load(_cpu *cpu, uint32_t destination, uint32_t address, uint32_t alignment);
void tc_xmm_store(_cpu *cpu, uint32_t source, uint32_t address, uint32_t alignment);
void tc_xmm_copy32(_cpu *cpu, uint32_t destination, uint32_t source);
void tc_xmm_load32(_cpu *cpu, uint32_t destination, uint32_t address);
void tc_xmm_store32(_cpu *cpu, uint32_t source, uint32_t address);
void tc_xmm_shuffle(_cpu *cpu, uint32_t destination, uint32_t source,
                    uint32_t from_memory, uint32_t control);
/* Operation values are also emitted by SRW: 0=XOR, 1=AND, 2=AND-NOT, 3=OR. */
void tc_xmm_logic(_cpu *cpu, uint32_t destination, uint32_t source,
                  uint32_t from_memory, uint32_t operation);
void tc_xmm_unpack(_cpu *cpu, uint32_t destination, uint32_t source,
                   uint32_t from_memory, uint32_t high);
void tc_xmm_movlh(_cpu *cpu, uint32_t destination, uint32_t source);
/* Operation values match SRW: add, subtract, multiply, divide, square root. */
void tc_xmm_arithmetic(_cpu *cpu, uint32_t destination, uint32_t source,
                       uint32_t from_memory, uint32_t scalar, uint32_t operation);
void tc_mxcsr_load(_cpu *cpu, uint32_t address);
void tc_mxcsr_store(_cpu *cpu, uint32_t address);
void tc_xmm_compare(_cpu *cpu, uint32_t destination, uint32_t source,
                    uint32_t from_memory, uint32_t quiet);
void tc_xmm_from_i32(_cpu *cpu, uint32_t destination, uint32_t source,
                     uint32_t from_memory);
void tc_xmm_to_i32(_cpu *cpu, uint32_t destination, uint32_t source,
                   uint32_t from_memory, uint32_t truncate);
void tc_xmm_minmax(_cpu *cpu, uint32_t destination, uint32_t source,
                   uint32_t from_memory, uint32_t scalar, uint32_t maximum);
void tc_xmm_compare_mask(_cpu *cpu, uint32_t destination, uint32_t source,
                         uint32_t from_memory, uint32_t scalar, uint32_t predicate);
void tc_xmm_movemask(_cpu *cpu, uint32_t destination, uint32_t source);
void tc_xmm_rsqrt(_cpu *cpu, uint32_t destination, uint32_t source,
                   uint32_t from_memory, uint32_t scalar);
void tc_xmm_rcp(_cpu *cpu, uint32_t destination, uint32_t source,
                 uint32_t from_memory, uint32_t scalar);
/* Uses the upstream binary64 x87 stack. Invalid-operation cases abort until
 * extended-precision state, tags and guest x87 exceptions are implemented. */
void tc_x87_compare(_cpu *cpu, uint32_t source, uint32_t quiet, uint32_t pop);
/* Limited to the upstream binary64 stack and masked nearest-rounding mode. */
void tc_x87_sincos(_cpu *cpu);
void tc_x87_atan(_cpu *cpu);
void tc_x87_exp2m1(_cpu *cpu);
void tc_x87_scale(_cpu *cpu);
void tc_x87_misc(_cpu *cpu, uint32_t op, uint32_t index);
void tc_x87_pi(_cpu *cpu);
/* Ten-byte memory operand, narrowed to the existing binary64 x87 stack. */
void tc_x87_load80(_cpu *cpu, uint32_t address);
void tc_x87_clear(_cpu *cpu);
void tc_x87_round(_cpu *cpu);
/* Byte/word shifts preserve the rest of the destination register. */
void tc_shift_part(_cpu *cpu, uint32_t destination, uint32_t whole,
                   uint32_t count, uint32_t operation, uint32_t width, uint32_t offset);
/* 32-bit SHLD/SHRD; right selects SHRD. */
void tc_double_shift32(_cpu *cpu, uint32_t destination, uint32_t value,
                      uint32_t source, uint32_t count, uint32_t right);
/* 32-bit variable shifts: operation 0=SHL, 1=SHR, 2=SAR. */
void tc_shift32(_cpu *cpu, uint32_t destination, uint32_t value,
                uint32_t count, uint32_t operation);
/* CMPSD: repeat 0=single, 1=REPE, 2=REPNE. */
void tc_cmps32(_cpu *cpu, uint32_t repeat);
void tc_xmm_bits32(_cpu *cpu, uint32_t destination, uint32_t source);
/* mode: 0=register copy, 1=load, 2=store. MOVQ loads clear the upper half. */
void tc_xmm_move64(_cpu *cpu, uint32_t xmm, uint32_t source, uint32_t mode);
/* operation: 0=PSRLQ, 1=PSLLQ, 2=PSUBD, 3=UCOMISD.
 * mode: 0=register, 1=memory, 2=immediate shift count. */
void tc_xmm_sse2(_cpu *cpu, uint32_t destination, uint32_t source,
                  uint32_t mode, uint32_t operation);
void tc_xmm_compare_pd(_cpu *cpu, uint32_t destination, uint32_t source,
                       uint32_t from_memory, uint32_t predicate);
void tc_xmm_add64(_cpu *cpu, uint32_t destination, uint32_t source,
                  uint32_t from_memory, uint32_t subtract);

#endif
