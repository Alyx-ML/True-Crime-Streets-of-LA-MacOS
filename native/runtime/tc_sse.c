#include "tc_tls.h"
#include "tc_heap.h"
#include "tc_d3d8.h"
#include "tc_dinput.h"
#include "tc_dsound.h"
#include "tc_bink.h"
#include "tc_process.h"
#include "tc_vm.h"
#include "tc_sync.h"
#include "tc_files.h"
#include "tc_host.h"
#include "tc_threads.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <fenv.h>
#include <stdatomic.h>
#include <mach/mach_time.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <sched.h>
#include "softfloat.h"
#pragma STDC FENV_ACCESS ON

_Noreturn void tc_unmapped_guest(_cpu *cpu,uint32_t address)
{
    fprintf(stderr,"Static translation has no entry for guest address 0x%08x; ESP=0x%08x EBP=0x%08x\n",address,cpu->_esp,cpu->_ebp);
    if(cpu->_esp>=0x03f00000u&&cpu->_esp<=0x04000000u-32) {
        uint32_t stack[8];memcpy(stack,(void *)(uintptr_t)(cpu->_pointer_offset+cpu->_esp),sizeof(stack));
        fprintf(stderr,"Startup stack:");
        for(unsigned i=0;i<8;i++)fprintf(stderr," %08x",stack[i]);
        fputc('\n',stderr);
    }
    abort();
}

static tc_cpu *state(_cpu *cpu, uint32_t index)
{
    if (cpu == NULL || index >= 8) abort();
    return (tc_cpu *)cpu;
}

/* Match the guest CPUID profile: no optional SIMD/TSC/CMPXCHG8B features,
 * no advertised floating-point emulation or processor errata. Unknown IDs are false. */
static void tc_processor_feature(_cpu *cpu){cpu->_eax=0;}

/* SRW emits this for SSE instructions it cannot translate; reaching one is a translation gap. */
void tc_unsupported_instruction(_cpu *cpu, uint32_t address)
{
    (void)cpu;
    fprintf(stderr, "Static translation has no implementation for guest instruction at 0x%08x\n", address);
    abort();
}

void tc_cpuid(_cpu *cpu)
{
    uint32_t leaf=cpu->_eax;
    cpu->_eax=cpu->_ebx=cpu->_ecx=cpu->_edx=0;
    if(leaf==0) {
        cpu->_eax=1;cpu->_ebx=0x756e6547;cpu->_edx=0x49656e69;cpu->_ecx=0x6c65746e;
    } else if(leaf==1) {
        /* Guest compatibility profile, not the ARM host's identity. Advertise
           x87 only; incomplete SIMD instruction families are not selectable. */
        cpu->_eax=0x500;cpu->_edx=1;
    }
    atomic_thread_fence(memory_order_seq_cst);
}

void tc_store_fence(void)
{
    atomic_thread_fence(memory_order_seq_cst);
}

static void *memory(tc_cpu *context, uint32_t address, uint32_t alignment, uint32_t size)
{
    if ((alignment != 1 && alignment != 16) || address % alignment != 0 ||
        (size != 4 && size != 8 && size != 10 && size != 16) || (uint64_t)address + size > context->memory_size ||
        context->scalar._pointer_offset > UINTPTR_MAX - address - (size - 1)) abort();
    /* Fail closed until a guest exception dispatcher exists; faults are not ignored. */
    return (void *)(uintptr_t)(context->scalar._pointer_offset + address);
}

static void *fs_memory(_cpu *cpu, uint32_t offset)
{
    tc_cpu *context = state(cpu, 0);
    if (!context->fs_base || context->fs_size < 4 || offset > context->fs_size - 4 ||
        offset > UINT32_MAX - context->fs_base) abort();
    return memory(context, context->fs_base + offset, 1, 4);
}

uint32_t tc_read_fs(_cpu *cpu, uint32_t offset)
{
    uint32_t value;
    memcpy(&value, fs_memory(cpu, offset), 4);
    return value;
}

void tc_write_fs(_cpu *cpu, uint32_t offset, uint32_t value)
{
    memcpy(fs_memory(cpu, offset), &value, 4);
}

static uint64_t continuous_nanoseconds(void)
{
    mach_timebase_info_data_t scale;
    if (mach_timebase_info(&scale) || !scale.denom) abort();
    __uint128_t value = (__uint128_t)mach_continuous_time() * scale.numer / scale.denom;
    if (value > INT64_MAX) abort();
    return (uint64_t)value;
}

static void tc_get_tick_count(_cpu *cpu)
{
    cpu->_eax = (uint32_t)(continuous_nanoseconds() / 1000000);
}

static uint32_t guest_argument(_cpu *cpu, uint32_t index)
{
    tc_cpu *context = state(cpu, 0);
    uint64_t address = (uint64_t)cpu->_esp + 4 + (uint64_t)index * 4;
    if (address > UINT32_MAX) abort();
    uint32_t value;
    memcpy(&value, memory(context, (uint32_t)address, 1, 4), 4);
    return value;
}

static void performance_result(_cpu *cpu, uint64_t value)
{
    tc_cpu *context = state(cpu, 0);
    uint32_t address = guest_argument(cpu, 0);
    if (!address) abort();
    memcpy(memory(context, address, 1, 8), &value, 8);
    cpu->_eax = 1;
}

static void tc_performance_counter(_cpu *cpu)
{
    performance_result(cpu, continuous_nanoseconds());
}

static void tc_performance_frequency(_cpu *cpu)
{
    performance_result(cpu, UINT64_C(1000000000));
}

static void tc_get_last_error(_cpu *cpu)
{
    cpu->_eax = tc_read_fs(cpu, 0x34);
}

static void tc_set_last_error(_cpu *cpu)
{
    tc_write_fs(cpu, 0x34, guest_argument(cpu, 0));
}

static void tc_sleep(_cpu *cpu)
{
    uint32_t milliseconds = guest_argument(cpu, 0);
    if (!milliseconds) {
        if (sched_yield()) abort();
        return;
    }
    if (milliseconds == UINT32_MAX) {
        /* Windows INFINITE does not complete merely because a signal arrives. */
        for (;;) pause();
    }
    struct timespec remaining = {milliseconds / 1000, (milliseconds % 1000) * 1000000L};
    while (nanosleep(&remaining, &remaining)) {
        if (errno != EINTR) abort();
    }
}

static void tc_current_process_id(_cpu *cpu) { cpu->_eax = tc_read_fs(cpu, 0x20); }
static void tc_current_thread_id(_cpu *cpu) { cpu->_eax = tc_read_fs(cpu, 0x24); }

static void tc_tls_alloc_import(_cpu *cpu) { cpu->_eax = tc_tls_alloc(state(cpu, 0)); }
static void tc_tls_free_import(_cpu *cpu) { cpu->_eax = tc_tls_free(state(cpu, 0), guest_argument(cpu, 0)); }
static void tc_tls_get_import(_cpu *cpu) { cpu->_eax = tc_tls_get(state(cpu, 0), guest_argument(cpu, 0)); }
static void tc_tls_set_import(_cpu *cpu)
{
    cpu->_eax = tc_tls_set(state(cpu, 0), guest_argument(cpu, 0), guest_argument(cpu, 1));
}

static void tc_heap_create_import(_cpu *cpu)
{
    cpu->_eax = tc_heap_create(state(cpu, 0)->heap_process, guest_argument(cpu, 0), guest_argument(cpu, 1), guest_argument(cpu, 2));
    if (!cpu->_eax) tc_write_fs(cpu, 0x34, 8);
}
static void tc_heap_destroy_import(_cpu *cpu)
{
    cpu->_eax = tc_heap_destroy(state(cpu, 0)->heap_process, guest_argument(cpu, 0));
    if (!cpu->_eax) tc_write_fs(cpu, 0x34, 87);
}
static void tc_heap_alloc_import(_cpu *cpu)
{
    cpu->_eax = tc_heap_alloc(state(cpu, 0)->heap_process, guest_argument(cpu, 0), guest_argument(cpu, 1), guest_argument(cpu, 2));
}
static void tc_heap_realloc_import(_cpu *cpu)
{
    cpu->_eax = tc_heap_realloc(state(cpu, 0)->heap_process, guest_argument(cpu, 0), guest_argument(cpu, 1), guest_argument(cpu, 2), guest_argument(cpu, 3));
}
static void tc_heap_free_import(_cpu *cpu)
{
    if (guest_argument(cpu, 1) & ~1u) abort();
    cpu->_eax = tc_heap_free(state(cpu, 0)->heap_process, guest_argument(cpu, 0), guest_argument(cpu, 2));
    if (!cpu->_eax) tc_write_fs(cpu, 0x34, 87);
}
static void tc_heap_size_import(_cpu *cpu)
{
    if (guest_argument(cpu, 1) & ~1u) abort();
    cpu->_eax = tc_heap_size(state(cpu, 0)->heap_process, guest_argument(cpu, 0), guest_argument(cpu, 2));
    if (cpu->_eax == UINT32_MAX) tc_write_fs(cpu, 0x34, 87);
}

static void tc_bad_read_pointer(_cpu *cpu) {
    tc_cpu *c=state(cpu,0);uint32_t address=guest_argument(cpu,0),size=guest_argument(cpu,1);
    if(!size){cpu->_eax=0;return;}
    if(!address||(uint64_t)address+size>c->memory_size||
        cpu->_pointer_offset>UINTPTR_MAX-(uint64_t)address-size){cpu->_eax=1;return;}
    cpu->_eax=!tc_memory_readable(cpu->_pointer_offset+address,size);
}
static void tc_virtual_alloc(_cpu *cpu)
{
    uint32_t error;
    cpu->_eax = tc_vm_alloc(state(cpu,0)->vm_process,guest_argument(cpu,0),
        guest_argument(cpu,1),guest_argument(cpu,2),guest_argument(cpu,3),&error);
    if (!cpu->_eax) tc_write_fs(cpu,0x34,error);
}
static void tc_virtual_free(_cpu *cpu)
{
    uint32_t error;
    cpu->_eax = tc_vm_free(state(cpu,0)->vm_process,guest_argument(cpu,0),
        guest_argument(cpu,1),guest_argument(cpu,2),&error);
    if (!cpu->_eax) tc_write_fs(cpu,0x34,error);
}
static void tc_virtual_protect(_cpu *cpu)
{
    uint32_t output=guest_argument(cpu,3),old,error;
    if (!output) { cpu->_eax=0;tc_write_fs(cpu,0x34,87);return; }
    void *destination=memory(state(cpu,0),output,1,4);
    cpu->_eax=tc_vm_protect(state(cpu,0)->vm_process,guest_argument(cpu,0),
        guest_argument(cpu,1),guest_argument(cpu,2),&old,&error);
    if (cpu->_eax) memcpy(destination,&old,4);
    else tc_write_fs(cpu,0x34,error);
}

void tc_import_dispatch(_cpu *cpu, uint32_t slot)
{
    if (!cpu) abort();
    switch (slot) {
#define TC_IMPORT(slot, target, bytes, handler, symbol) case slot: handler(cpu); return;
#include "tc_imports.def"
#undef TC_IMPORT
    default: abort();
    }
}

void tc_imports_install(_cpu *cpu)
{
    tc_cpu *context = state(cpu, 0);
#define TC_IMPORT(slot, target, bytes, handler, symbol) \
    { uint32_t address = target; memcpy(memory(context, slot, 1, 4), &address, 4); }
#include "tc_imports.def"
#undef TC_IMPORT
}

uint32_t tc_x87_result(_cpu *cpu, const void *value)
{
    tc_cpu *context = state(cpu, 0);
    if (!value || !context->x87_result_address) abort();
    memmove(memory(context, context->x87_result_address, 1, 8), value, 8);
    return context->x87_result_address;
}

void tc_xmm_copy(_cpu *cpu, uint32_t destination, uint32_t source)
{
    tc_cpu *context = state(cpu, destination);
    if (source >= 8) abort();
    memmove(context->xmm[destination], context->xmm[source], 16);
}

void tc_xmm_load(_cpu *cpu, uint32_t destination, uint32_t address, uint32_t alignment)
{
    tc_cpu *context = state(cpu, destination);
    memcpy(context->xmm[destination], memory(context, address, alignment, 16), 16);
}

void tc_xmm_store(_cpu *cpu, uint32_t source, uint32_t address, uint32_t alignment)
{
    tc_cpu *context = state(cpu, source);
    memcpy(memory(context, address, alignment, 16), context->xmm[source], 16);
}

void tc_xmm_copy32(_cpu *cpu, uint32_t destination, uint32_t source)
{
    tc_cpu *context = state(cpu, destination);
    if (source >= 8) abort();
    /* Register MOVSS preserves the destination's upper 96 bits. */
    context->xmm[destination][0] = context->xmm[source][0];
}

void tc_xmm_load32(_cpu *cpu, uint32_t destination, uint32_t address)
{
    tc_cpu *context = state(cpu, destination);
    uint32_t value;
    memcpy(&value, memory(context, address, 1, 4), 4);
    /* Legacy memory MOVSS clears the destination's upper 96 bits. */
    context->xmm[destination][0] = value;
    memset(context->xmm[destination] + 1, 0, 12);
}

void tc_xmm_store32(_cpu *cpu, uint32_t source, uint32_t address)
{
    tc_cpu *context = state(cpu, source);
    memcpy(memory(context, address, 1, 4), context->xmm[source], 4);
}

static void source128(tc_cpu *context, uint32_t source, uint32_t from_memory,
                      uint32_t result[4])
{
    if (from_memory > 1) abort();
    if (from_memory) {
        memcpy(result, memory(context, source, 16, 16), 16);
    } else {
        if (source >= 8) abort();
        memcpy(result, context->xmm[source], 16);
    }
}

void tc_xmm_shuffle(_cpu *cpu, uint32_t destination, uint32_t source,
                    uint32_t from_memory, uint32_t control)
{
    tc_cpu *context = state(cpu, destination);
    uint32_t left[4], right[4];
    if (control > 255) abort();
    memcpy(left, context->xmm[destination], 16);
    source128(context, source, from_memory, right);
    /* Snapshot both operands before writing: source may equal destination. */
    context->xmm[destination][0] = left[control & 3];
    context->xmm[destination][1] = left[(control >> 2) & 3];
    context->xmm[destination][2] = right[(control >> 4) & 3];
    context->xmm[destination][3] = right[(control >> 6) & 3];
}

void tc_xmm_logic(_cpu *cpu, uint32_t destination, uint32_t source,
                  uint32_t from_memory, uint32_t operation)
{
    tc_cpu *context = state(cpu, destination);
    uint32_t right[4];
    if (operation > 3) abort();
    source128(context, source, from_memory, right);
    for (unsigned i = 0; i < 4; ++i) {
        uint32_t left = context->xmm[destination][i];
        switch (operation) {
        case 0: context->xmm[destination][i] = left ^ right[i]; break;
        case 1: context->xmm[destination][i] = left & right[i]; break;
        /* ANDNPS complements the old destination, not the source. */
        case 2: context->xmm[destination][i] = ~left & right[i]; break;
        case 3: context->xmm[destination][i] = left | right[i]; break;
        }
    }
}

void tc_xmm_unpack(_cpu *cpu, uint32_t destination, uint32_t source,
                   uint32_t from_memory, uint32_t high)
{
    tc_cpu *context = state(cpu, destination);
    uint32_t left[4], right[4];
    if (high > 1) abort();
    memcpy(left, context->xmm[destination], 16);
    source128(context, source, from_memory, right);
    unsigned first = high * 2;
    context->xmm[destination][0] = left[first];
    context->xmm[destination][1] = right[first];
    context->xmm[destination][2] = left[first + 1];
    context->xmm[destination][3] = right[first + 1];
}

void tc_xmm_movlh(_cpu *cpu, uint32_t destination, uint32_t source)
{
    tc_cpu *context = state(cpu, destination);
    if (source >= 8) abort();
    /* MOVLHPS preserves the low half and copies source bits 63:0 to 127:64. */
    memmove(context->xmm[destination] + 2, context->xmm[source], 8);
}

void tc_mxcsr_load(_cpu *cpu, uint32_t address)
{
    tc_cpu *context = state(cpu, 0);
    uint32_t value;
    memcpy(&value, memory(context, address, 1, 4), 4);
    if (value & 0xffff0000u) abort();
    context->mxcsr = value;
}

void tc_mxcsr_store(_cpu *cpu, uint32_t address)
{
    tc_cpu *context = state(cpu, 0);
    memcpy(memory(context, address, 1, 4), &context->mxcsr, 4);
}

static int subnormal32(uint32_t bits)
{
    return (bits & 0x7f800000u) == 0 && (bits & 0x007fffffu) != 0;
}

static void raise_flags(tc_cpu *context, uint32_t flags)
{
    context->mxcsr |= flags;
    /* Guest exception dispatch remains unavailable; do not commit a faulting result. */
    if (flags & ~(context->mxcsr >> 7) & 0x3f) abort();
}

typedef struct {
    uint_fast8_t rounding, tininess, flags;
} float_environment;

static float_environment begin_float(tc_cpu *context)
{
    if (context->mxcsr & 0xffff0000u) abort();
    float_environment saved = {
        softfloat_roundingMode, softfloat_detectTininess, softfloat_exceptionFlags
    };
    static const uint_fast8_t rounding[] = {
        softfloat_round_near_even, softfloat_round_min,
        softfloat_round_max, softfloat_round_minMag
    };
    softfloat_roundingMode = rounding[(context->mxcsr >> 13) & 3];
    softfloat_detectTininess = softfloat_tininess_afterRounding;
    softfloat_exceptionFlags = 0;
    return saved;
}

static void end_float(tc_cpu *context, float_environment saved, uint32_t flags)
{
    uint_fast8_t raised = softfloat_exceptionFlags;
    if (raised & softfloat_flag_invalid) flags |= 1;
    if (raised & softfloat_flag_infinite) flags |= 4;
    if (raised & softfloat_flag_overflow) flags |= 8;
    if (raised & softfloat_flag_underflow) flags |= 16;
    if (raised & softfloat_flag_inexact) flags |= 32;
    softfloat_roundingMode = saved.rounding;
    softfloat_detectTininess = saved.tininess;
    softfloat_exceptionFlags = saved.flags;
    raise_flags(context, flags);
}

static uint32_t source32(tc_cpu *context, uint32_t source, uint32_t from_memory)
{
    if (from_memory > 1) abort();
    if (!from_memory) {
        if (source >= 8) abort();
        return context->xmm[source][0];
    }
    uint32_t value;
    memcpy(&value, memory(context, source, 1, 4), 4);
    return value;
}

void tc_xmm_arithmetic(_cpu *cpu, uint32_t destination, uint32_t source,
                       uint32_t from_memory, uint32_t scalar, uint32_t operation)
{
    tc_cpu *context = state(cpu, destination);
    uint32_t right[4] = {0}, result[4], flags = 0;
    if (scalar > 1 || from_memory > 1 || operation > 4) abort();
    /* ponytail: FTZ needs x86-specific underflow handling; reject it until added. */
    if (context->mxcsr & 0xffff8000u) abort();
    if (scalar && from_memory) {
        memcpy(right, memory(context, source, 1, 4), 4);
    } else {
        source128(context, source, from_memory, right);
    }
    memcpy(result, context->xmm[destination], 16);
    float_environment saved = begin_float(context);
    for (unsigned i = 0; i < (scalar ? 1u : 4u); ++i) {
        /* SQRT consumes only the source; the old destination is not an input. */
        uint32_t a = operation == 4 ? 0 : result[i];
        uint32_t b = right[i];
        if (context->mxcsr & 0x40) {
            if (subnormal32(a)) a &= 0x80000000u;
            if (subnormal32(b)) b &= 0x80000000u;
        } else if ((a & 0x7fffffffu) <= 0x7f800000u &&
                   (b & 0x7fffffffu) <= 0x7f800000u &&
                   (subnormal32(a) || subnormal32(b))) {
            flags |= 2; /* SoftFloat does not supply x86's denormal-input flag. */
        }
        float32_t left_value = {a}, right_value = {b}, value;
        switch (operation) {
        case 0: value = f32_add(left_value, right_value); break;
        case 1: value = f32_sub(left_value, right_value); break;
        case 2: value = f32_mul(left_value, right_value); break;
        case 3: value = f32_div(left_value, right_value); break;
        default: value = f32_sqrt(right_value); break;
        }
        result[i] = value.v;
    }
    end_float(context, saved, flags);
    memcpy(context->xmm[destination], result, 16);
}

static uint32_t compare_bits(tc_cpu *context, uint32_t *left, uint32_t *right,
                             uint32_t quiet, uint32_t *flags)
{
    if (quiet > 1 || (context->mxcsr & 0xffff0000u)) abort();
    uint32_t a = *left, b = *right, condition;
    if (context->mxcsr & 0x40) {
        if (subnormal32(a)) a &= 0x80000000u;
        if (subnormal32(b)) b &= 0x80000000u;
    }
    int nan_a = (a & 0x7fffffffu) > 0x7f800000u;
    int nan_b = (b & 0x7fffffffu) > 0x7f800000u;
    if (nan_a || nan_b) {
        condition = CF | PF | ZF;
        if (!quiet || (nan_a && !(a & 0x00400000u)) ||
                      (nan_b && !(b & 0x00400000u))) *flags |= 1;
    } else {
        if (subnormal32(a) || subnormal32(b)) *flags |= 2;
        if (a == b || ((a | b) & 0x7fffffffu) == 0) {
            condition = ZF;
        } else {
            int less = (a ^ b) & 0x80000000u ? (a >> 31) :
                (a & 0x80000000u ? a > b : a < b);
            condition = less ? CF : 0;
        }
    }
    *left = a;
    *right = b;
    return condition;
}

void tc_xmm_compare(_cpu *cpu, uint32_t destination, uint32_t source,
                    uint32_t from_memory, uint32_t quiet)
{
    tc_cpu *context = state(cpu, destination);
    uint32_t a = context->xmm[destination][0];
    uint32_t b = source32(context, source, from_memory), flags = 0;
    uint32_t condition = compare_bits(context, &a, &b, quiet, &flags);
    raise_flags(context, flags);
    cpu->_eflags = (cpu->_eflags & ~(CF | PF | AF | ZF | SF | OF)) | condition;
}

void tc_xmm_minmax(_cpu *cpu, uint32_t destination, uint32_t source,
                   uint32_t from_memory, uint32_t scalar, uint32_t maximum)
{
    tc_cpu *context = state(cpu, destination);
    uint32_t result[4], right[4] = {0}, flags = 0;
    if (scalar > 1 || maximum > 1) abort();
    if (scalar) right[0] = source32(context, source, from_memory);
    else source128(context, source, from_memory, right);
    memcpy(result, context->xmm[destination], 16);
    for (unsigned i = 0; i < (scalar ? 1u : 4u); ++i) {
        uint32_t a = result[i], b = right[i];
        uint32_t relation = compare_bits(context, &a, &b, 0, &flags);
        /* Legacy SSE selects the second operand on equality or unordered input,
           preserving its signed zero and NaN payload, including signaling NaNs. */
        result[i] = relation == (maximum ? 0u : CF) ? a : b;
    }
    raise_flags(context, flags);
    memcpy(context->xmm[destination], result, 16);
}

static int predicate_matches(uint32_t relation, uint32_t predicate)
{
    int matches = 0;
    switch (predicate) {
    case 0: matches = relation == ZF; break;
    case 1: matches = relation == CF; break;
    case 2: matches = relation == CF || relation == ZF; break;
    case 3: matches = (relation & PF) != 0; break;
    case 4: matches = relation != ZF; break;
    case 5: matches = relation != CF; break;
    case 6: matches = relation != CF && relation != ZF; break;
    case 7: matches = (relation & PF) == 0; break;
    }
    return matches;
}

void tc_xmm_compare_mask(_cpu *cpu, uint32_t destination, uint32_t source,
                         uint32_t from_memory, uint32_t scalar, uint32_t predicate)
{
    tc_cpu *context = state(cpu, destination);
    uint32_t result[4], right[4] = {0}, flags = 0;
    if (scalar > 1 || predicate > 7) abort();
    if (scalar) right[0] = source32(context, source, from_memory);
    else source128(context, source, from_memory, right);
    memcpy(result, context->xmm[destination], 16);
    uint32_t quiet = predicate == 0 || predicate == 3 || predicate == 4 || predicate == 7;
    for (unsigned i = 0; i < (scalar ? 1u : 4u); ++i) {
        uint32_t a = result[i], b = right[i];
        uint32_t relation = compare_bits(context, &a, &b, quiet, &flags);
        result[i] = predicate_matches(relation, predicate) ? UINT32_MAX : 0;
    }
    raise_flags(context, flags);
    memcpy(context->xmm[destination], result, 16);
}

void tc_xmm_from_i32(_cpu *cpu, uint32_t destination, uint32_t source,
                     uint32_t from_memory)
{
    tc_cpu *context = state(cpu, destination);
    if (from_memory > 1) abort();
    /* Register inputs are passed by value, memory inputs as guest addresses. */
    uint32_t bits = from_memory ? source32(context, source, 1) : source;
    int32_t signed_value;
    memcpy(&signed_value, &bits, 4);
    float_environment saved = begin_float(context);
    float32_t value = i32_to_f32(signed_value);
    end_float(context, saved, 0);
    context->xmm[destination][0] = value.v;
}

static void write_gpr(_cpu *cpu, uint32_t destination, uint32_t result)
{
    /* Indices follow x86 encoding order, without pointer arithmetic across members. */
    switch (destination) {
    case 0: cpu->_eax = result; break;
    case 1: cpu->_ecx = result; break;
    case 2: cpu->_edx = result; break;
    case 3: cpu->_ebx = result; break;
    case 4: cpu->_esp = result; break;
    case 5: cpu->_ebp = result; break;
    case 6: cpu->_esi = result; break;
    case 7: cpu->_edi = result; break;
    default: abort();
    }
}

void tc_xmm_bits32(_cpu *cpu, uint32_t destination, uint32_t source)
{
    tc_cpu *context = state(cpu, source);
    write_gpr(cpu, destination, context->xmm[source][0]);
}

void tc_xmm_move64(_cpu *cpu, uint32_t xmm, uint32_t source, uint32_t mode)
{
    tc_cpu *context = state(cpu, xmm);
    uint64_t value;
    if (mode == 2) {
        memcpy(memory(context, source, 1, 8), context->xmm[xmm], 8);
        return;
    }
    if (mode == 0) {
        if (source >= 8) abort();
        memcpy(&value, context->xmm[source], 8);
    } else if (mode == 1) memcpy(&value, memory(context, source, 1, 8), 8);
    else abort();
    memcpy(context->xmm[xmm], &value, 8);
    memset(context->xmm[xmm] + 2, 0, 8);
}

void tc_xmm_add64(_cpu *cpu, uint32_t destination, uint32_t source,
                  uint32_t from_memory, uint32_t subtract)
{
    tc_cpu *context = state(cpu, destination);
    if (from_memory > 1 || subtract > 1 || (context->mxcsr & 0xffff8000u)) abort();
    uint64_t values[2];
    memcpy(&values[0], context->xmm[destination], 8);
    if (from_memory) memcpy(&values[1], memory(context, source, 1, 8), 8);
    else {
        if (source >= 8) abort();
        memcpy(&values[1], context->xmm[source], 8);
    }
    uint32_t flags = 0;
    int any_nan = (values[0] & UINT64_C(0x7fffffffffffffff)) > UINT64_C(0x7ff0000000000000) ||
                  (values[1] & UINT64_C(0x7fffffffffffffff)) > UINT64_C(0x7ff0000000000000);
    for (unsigned i = 0; i < 2; ++i) {
        uint64_t magnitude = values[i] & UINT64_C(0x7fffffffffffffff);
        if (magnitude && magnitude < UINT64_C(0x0010000000000000)) {
            if (context->mxcsr & 64) values[i] &= UINT64_C(0x8000000000000000);
            else if (!any_nan) flags |= 2;
        }
    }
    float_environment saved = begin_float(context);
    float64_t a = {values[0]}, b = {values[1]};
    float64_t result = subtract ? f64_sub(a, b) : f64_add(a, b);
    end_float(context, saved, flags);
    memcpy(context->xmm[destination], &result.v, 8);
}

static uint32_t compare64(tc_cpu *context, uint64_t a, uint64_t b,
                          uint32_t quiet, uint32_t *exceptions)
{
    uint64_t values[2] = {a, b};
    int unordered = 0;
    for (unsigned i = 0; i < 2; ++i) {
        uint64_t magnitude = values[i] & UINT64_C(0x7fffffffffffffff);
        if (magnitude > UINT64_C(0x7ff0000000000000)) {
            unordered = 1;
            if (!quiet || !(values[i] & UINT64_C(0x0008000000000000))) *exceptions |= 1;
        } else if (magnitude && magnitude < UINT64_C(0x0010000000000000)) {
            if (context->mxcsr & 64) values[i] &= UINT64_C(0x8000000000000000);
            else *exceptions |= 2;
        }
    }
    a = values[0]; b = values[1];
    if (unordered) return CF | PF | ZF;
    if (a == b || ((a | b) & UINT64_C(0x7fffffffffffffff)) == 0) return ZF;
    return ((a >> 63) != (b >> 63) ? a >> 63 : (a >> 63) ? a > b : a < b) ? CF : 0;
}

void tc_xmm_compare_pd(_cpu *cpu, uint32_t destination, uint32_t source,
                       uint32_t from_memory, uint32_t predicate)
{
    tc_cpu *context = state(cpu, destination);
    if (predicate > 7) abort();
    uint32_t source_words[4], exceptions = 0;
    uint64_t left[2], right[2], result[2];
    source128(context, source, from_memory, source_words);
    memcpy(left, context->xmm[destination], 16);
    memcpy(right, source_words, 16);
    uint32_t quiet = predicate == 0 || predicate == 3 || predicate == 4 || predicate == 7;
    for (unsigned i = 0; i < 2; ++i) {
        uint32_t relation = compare64(context, left[i], right[i], quiet, &exceptions);
        result[i] = predicate_matches(relation, predicate) ? UINT64_MAX : 0;
    }
    raise_flags(context, exceptions);
    memcpy(context->xmm[destination], result, 16);
}

void tc_xmm_sse2(_cpu *cpu, uint32_t destination, uint32_t source,
                  uint32_t mode, uint32_t operation)
{
    tc_cpu *context = state(cpu, destination);
    if (mode > 2 || operation > 3 || (mode == 2 && (operation > 1 || source > 255))) abort();
    uint32_t right[4] = {source, 0, 0, 0};
    if (mode == 1 && operation == 3) memcpy(right, memory(context, source, 1, 8), 8);
    else if (mode != 2) source128(context, source, mode, right);
    if (operation < 2) {
        uint64_t lanes[2], count = (uint64_t)right[0] | ((uint64_t)right[1] << 32);
        memcpy(lanes, context->xmm[destination], 16);
        for (unsigned i = 0; i < 2; ++i)
            lanes[i] = count > 63 ? 0 : operation == 0 ? lanes[i] >> count : lanes[i] << count;
        memcpy(context->xmm[destination], lanes, 16);
    } else if (operation == 2) {
        for (unsigned i = 0; i < 4; ++i) context->xmm[destination][i] -= right[i];
    } else {
        uint64_t values[2];
        memcpy(&values[0], context->xmm[destination], 8);
        memcpy(&values[1], right, 8);
        uint32_t exceptions = 0;
        uint32_t flags = compare64(context, values[0], values[1], 1, &exceptions);
        raise_flags(context, exceptions);
        cpu->_eflags = (cpu->_eflags & ~(CF | PF | AF | ZF | SF | OF)) | flags;
    }
}

void tc_xmm_to_i32(_cpu *cpu, uint32_t destination, uint32_t source,
                   uint32_t from_memory, uint32_t truncate)
{
    tc_cpu *context = state(cpu, destination);
    if (truncate > 1) abort();
    float32_t value = {source32(context, source, from_memory)};
    if ((context->mxcsr & 0x40) && subnormal32(value.v)) value.v &= 0x80000000u;
    float_environment saved = begin_float(context);
    uint32_t result = (uint32_t)f32_to_i32(value,
        truncate ? softfloat_round_minMag : softfloat_roundingMode, true);
    end_float(context, saved, 0);
    write_gpr(cpu, destination, result);
}

void tc_xmm_movemask(_cpu *cpu, uint32_t destination, uint32_t source)
{
    tc_cpu *context = state(cpu, source);
    uint32_t result = 0;
    for (unsigned i = 0; i < 4; ++i) result |= (context->xmm[source][i] >> 31) << i;
    write_gpr(cpu, destination, result);
}

void tc_cmps32(_cpu *cpu, uint32_t repeat)
{
    tc_cpu *context = state(cpu, 0);
    if (repeat > 2) abort();
    if (repeat && cpu->_ecx == 0) return;
    do {
        uint32_t a, b;
        memcpy(&a, memory(context, cpu->_esi, 1, 4), 4);
        memcpy(&b, memory(context, cpu->_edi, 1, 4), 4);
        uint32_t result = a - b;
        uint32_t flags = (a < b ? CF : 0) | (!result ? ZF : 0) |
            ((result >> 24) & SF) | ((a ^ b ^ result) & AF);
        if ((a ^ b) & (a ^ result) & 0x80000000u) flags |= OF;
        if (!__builtin_parity(result & 255)) flags |= PF;
        cpu->_eflags = (cpu->_eflags & ~(CF | PF | AF | ZF | SF | OF)) | flags;
        uint32_t step = (cpu->_eflags & DF) ? UINT32_MAX - 3 : 4;
        cpu->_esi += step;
        cpu->_edi += step;
        if (!repeat) break;
        --cpu->_ecx;
        if ((repeat == 1 && result != 0) || (repeat == 2 && result == 0)) break;
    } while (cpu->_ecx);
}

static void reciprocal(_cpu *cpu, uint32_t destination, uint32_t source,
                       uint32_t from_memory, uint32_t scalar, int square_root)
{
    tc_cpu *context = state(cpu, destination);
    if (scalar > 1) abort();
    uint32_t values[4];
    if (scalar) values[0] = source32(context, source, from_memory);
    else source128(context, source, from_memory, values);
    uint_fast8_t rounding = softfloat_roundingMode, flags = softfloat_exceptionFlags;
    softfloat_roundingMode = softfloat_round_near_even;
    for (unsigned i = 0; i < (scalar ? 1u : 4u); ++i) {
        uint32_t bits = values[i], magnitude = bits & 0x7fffffffu;
        if (magnitude > 0x7f800000u) values[i] = bits | 0x00400000u;
        else if (magnitude < 0x00800000u) values[i] = (bits & 0x80000000u) | 0x7f800000u;
        else if (square_root && (bits & 0x80000000u)) values[i] = 0xffc00000u;
        else if (magnitude == 0x7f800000u) values[i] = bits & 0x80000000u;
        else {
            /* Meets the ISA approximation bound; not bit-identical to a
               particular historical CPU's reciprocal-square-root estimate. */
            float32_t value = {bits}, one = {0x3f800000u};
            values[i] = f32_div(one, square_root ? f32_sqrt(value) : value).v;
            if ((values[i] & 0x7f800000u) == 0) values[i] &= 0x80000000u;
        }
    }
    softfloat_roundingMode = rounding;
    softfloat_exceptionFlags = flags; /* RCP/RSQRT do not raise SIMD exceptions. */
    memcpy(context->xmm[destination], values, scalar ? 4 : 16);
}

void tc_xmm_rsqrt(_cpu *cpu, uint32_t destination, uint32_t source,
                   uint32_t from_memory, uint32_t scalar)
{
    reciprocal(cpu, destination, source, from_memory, scalar, 1);
}

void tc_xmm_rcp(_cpu *cpu, uint32_t destination, uint32_t source,
                 uint32_t from_memory, uint32_t scalar)
{
    reciprocal(cpu, destination, source, from_memory, scalar, 0);
}

static void commit_shift32(_cpu *cpu, uint32_t destination, uint32_t value,
                           uint32_t result, uint32_t carry, uint32_t count)
{
    uint32_t flags = cpu->_eflags & ~(CF | PF | ZF | SF);
    flags |= carry | (!result ? ZF : 0) | ((result >> 24) & SF);
    if (!__builtin_parity(result & 255)) flags |= PF;
    /* Preserve architecturally undefined AF and, for counts > 1, OF. */
    if (count == 1) {
        flags &= ~OF;
        if ((value ^ result) & 0x80000000u) flags |= OF;
    }
    write_gpr(cpu, destination, result);
    cpu->_eflags = flags;
}

void tc_shift32(_cpu *cpu, uint32_t destination, uint32_t value,
                uint32_t count, uint32_t operation)
{
    if (!cpu || destination >= 8 || operation > 2) abort();
    count &= 31;
    if (!count) return;
    uint32_t result = operation == 0 ? value << count : value >> count;
    if (operation == 2 && (value & 0x80000000u)) result |= UINT32_MAX << (32 - count);
    uint32_t carry = operation == 0 ? (value >> (32 - count)) & 1 : (value >> (count - 1)) & 1;
    commit_shift32(cpu, destination, value, result, carry, count);
}

void tc_shift_part(_cpu *cpu, uint32_t destination, uint32_t whole,
                   uint32_t count, uint32_t operation, uint32_t width, uint32_t offset)
{
    if (!cpu || destination >= 8 || operation > 2 ||
        (width != 8 && width != 16) || (offset != 0 && !(width == 8 && offset == 8))) abort();
    count &= 31;
    if (!count) return;
    uint32_t mask = (1u << width) - 1, sign = 1u << (width - 1);
    uint32_t value = (whole >> offset) & mask;
    uint32_t extended = value;
    if (operation == 2 && (value & sign)) extended |= ~mask;
    uint32_t result = operation == 0 ? value << count : extended >> count;
    if (operation == 2 && (value & sign)) result |= UINT32_MAX << (32 - count);
    result &= mask;
    uint32_t flags = cpu->_eflags & ~(PF | ZF | SF);
    if (!result) flags |= ZF;
    if (result & sign) flags |= SF;
    if (!__builtin_parity(result & 255)) flags |= PF;
    /* SHL/SHR carry is undefined for counts >= operand width; retain it. */
    if (count < width || operation == 2) {
        uint32_t carry = operation == 0 ? (value >> (width - count)) & 1
            : count >= width ? !!(value & sign) : (value >> (count - 1)) & 1;
        flags = (flags & ~CF) | carry;
    }
    if (count == 1) {
        flags &= ~OF;
        if ((value ^ result) & sign) flags |= OF;
    }
    write_gpr(cpu, destination, (whole & ~(mask << offset)) | (result << offset));
    cpu->_eflags = flags;
}

void tc_double_shift32(_cpu *cpu, uint32_t destination, uint32_t value,
                      uint32_t source, uint32_t count, uint32_t right)
{
    if (!cpu || destination >= 8 || right > 1) abort();
    count &= 31;
    if (!count) return;
    uint32_t result = right ? (value >> count) | (source << (32 - count))
                            : (value << count) | (source >> (32 - count));
    uint32_t carry = right ? (value >> (count - 1)) & 1 : (value >> (32 - count)) & 1;
    commit_shift32(cpu, destination, value, result, carry, count);
}

void tc_x87_round(_cpu *cpu)
{
    if (!cpu || cpu->_st_top >= 8 || (cpu->_st_cw & 0x3fu) != 0x3fu) abort();
    float64_t value;
    memcpy(&value.v, &cpu->_st[cpu->_st_top], 8);
    const uint64_t magnitude = UINT64_C(0x7fffffffffffffff);
    uint64_t absolute = value.v & magnitude;
    if (absolute > UINT64_C(0x7ff0000000000000) ||
        (absolute && absolute < UINT64_C(0x0010000000000000))) abort();
    static const uint_fast8_t rounding[] = {
        softfloat_round_near_even, softfloat_round_min,
        softfloat_round_max, softfloat_round_minMag
    };
    uint_fast8_t saved_flags = softfloat_exceptionFlags;
    softfloat_exceptionFlags = 0;
    /* ponytail: operates on the existing binary64 stack; full 80-bit operands
       and pending unmasked exceptions require replacement of the x87 core. */
    float64_t result = f64_roundToInt(value, rounding[(cpu->_st_cw >> 10) & 3], true);
    uint_fast8_t raised = softfloat_exceptionFlags;
    softfloat_exceptionFlags = saved_flags;
    cpu->_st_sw_cond &= ~0x200u;
    if (raised & softfloat_flag_inexact) {
        cpu->_st_sw_cond |= 0x20u;
        if ((result.v & magnitude) > absolute) cpu->_st_sw_cond |= 0x200u;
    }
    memcpy(&cpu->_st[cpu->_st_top], &result.v, 8);
}

void tc_x87_clear(_cpu *cpu)
{
    /* Pending unmasked x87 exceptions are not represented by this core. */
    if (!cpu || (cpu->_st_cw & 0x3fu) != 0x3fu) abort();
    cpu->_st_sw_cond &= ~0x80ffu;
}

void tc_x87_load80(_cpu *cpu, uint32_t address)
{
    tc_cpu *context = state(cpu, 0);
    if (cpu->_st_top >= 8 || (cpu->_st_cw & 0xc3fu) != 0x3fu) abort();
    const unsigned char *bytes = memory(context, address, 1, 10);
    extFloat80_t value;
    memcpy(&value.signif, bytes, 8);
    memcpy(&value.signExp, bytes + 8, 2);
    uint32_t exponent = value.signExp & 0x7fffu;
    /* Unsupported encodings and x87 NaN/denormal exceptions need the full core. */
    if ((exponent && !(value.signif >> 63)) || exponent == 0x7fffu ||
        (!exponent && value.signif)) abort();
    uint_fast8_t rounding = softfloat_roundingMode, flags = softfloat_exceptionFlags;
    softfloat_roundingMode = softfloat_round_near_even;
    softfloat_exceptionFlags = 0;
    /* ponytail: narrow to the upstream binary64 stack. Replace that stack to
       retain the full x87 significand; narrowing must not change guest status. */
    float64_t result = extF80_to_f64(value);
    uint_fast8_t raised = softfloat_exceptionFlags;
    softfloat_roundingMode = rounding;
    softfloat_exceptionFlags = flags;
    if (raised & (softfloat_flag_invalid | softfloat_flag_overflow | softfloat_flag_underflow)) abort();
    cpu->_st_top = (cpu->_st_top + 7) & 7;
    memcpy(&cpu->_st[cpu->_st_top], &result.v, 8);
    cpu->_st_sw_cond &= ~0x200u;
}

void tc_x87_pi(_cpu *cpu)
{
    if (!cpu || cpu->_st_top >= 8 || (cpu->_st_cw & 0xc3fu) != 0x3fu) abort();
    /* ponytail: constant rounded to the existing binary64 stack; replace
       the stack representation for the x87 80-bit constant. */
    cpu->_st_top = (cpu->_st_top + 7) & 7;
    cpu->_st[cpu->_st_top] = 0x1.921fb54442d18p1;
    cpu->_st_sw_cond &= ~0x200u;
}

void tc_x87_atan(_cpu *cpu)
{
    if (!cpu || cpu->_st_top >= 8 || (cpu->_st_cw & 0xc3fu) != 0x3fu) abort();
    uint32_t next = (cpu->_st_top + 1) & 7;
    double x = cpu->_st[cpu->_st_top], y = cpu->_st[next];
    if (!isfinite(x) || !isfinite(y) || fpclassify(x) == FP_SUBNORMAL ||
        fpclassify(y) == FP_SUBNORMAL) abort();
    fenv_t environment;
    if (feholdexcept(&environment) || fesetround(FE_TONEAREST)) abort();
    /* ponytail: binary64/libm, like the upstream transcendental core. Extended
       precision, stack tags and x87 rounding/exception status need a new core. */
    double result = atan2(y, x);
    if (fesetenv(&environment)) abort();
    cpu->_st[next] = result;
    cpu->_st_top = next;
    if (y == 0 && x > 0) cpu->_st_sw_cond &= ~0x200u;
}

/* F2XM1: ST0 = 2^ST0 - 1, defined for -1 <= ST0 <= 1 (CRT pow/exp 0x6693d0). */
void tc_x87_exp2m1(_cpu *cpu)
{
    if (!cpu || cpu->_st_top >= 8 || (cpu->_st_cw & 0xc3fu) != 0x3fu) abort();
    double x = cpu->_st[cpu->_st_top];
    if (!(fabs(x) <= 1)) abort();
    cpu->_st[cpu->_st_top] = expm1(x * M_LN2);
    cpu->_st_sw_cond &= ~0x200u;
}

/* FSCALE: ST0 = ST0 * 2^trunc(ST1). */
void tc_x87_scale(_cpu *cpu)
{
    if (!cpu || cpu->_st_top >= 8 || (cpu->_st_cw & 0xc3fu) != 0x3fu) abort();
    double x = cpu->_st[cpu->_st_top], s = trunc(cpu->_st[(cpu->_st_top + 1) & 7]);
    if (!isfinite(x) || !isfinite(s)) abort();
    cpu->_st[cpu->_st_top] = ldexp(x, s > 1e5 ? 100000 : s < -1e5 ? -100000 : (int)s);
    cpu->_st_sw_cond &= ~0x200u;
}

/* FFREE, FINCSTP, FDECSTP, FLDL2E, FLDL2T, FXAM, FTST, FPREM, FPREM1, FYL2XP1, FNCLEX.
   ponytail: binary64 stack without tags, like the other helpers here; FFREE is a no-op
   and FXAM never reports an empty register. */
void tc_x87_misc(_cpu *cpu, uint32_t op, uint32_t index)
{
    (void)index;
    if (!cpu || cpu->_st_top >= 8 || op > 10) abort();
    double *st = cpu->_st;uint32_t top = cpu->_st_top, next = (top + 1) & 7;
    switch (op) {
    case 0: break;
    case 1: cpu->_st_top = next; break;
    case 2: cpu->_st_top = (top + 7) & 7; break;
    case 3: case 4:
        cpu->_st_top = (top + 7) & 7;
        st[cpu->_st_top] = op == 3 ? M_LOG2E : 3.321928094887362347870319429489390175864831393;
        break;
    case 5: {
        double x = st[top];uint32_t c = signbit(x) ? 0x200u : 0;
        switch (fpclassify(x)) {
        case FP_NAN: c |= 0x100; break;
        case FP_INFINITE: c |= 0x500; break;
        case FP_ZERO: c |= 0x4000; break;
        case FP_SUBNORMAL: c |= 0x4400; break;
        default: c |= 0x400; break;
        }
        cpu->_st_sw_cond = (cpu->_st_sw_cond & ~0x4700u) | c;
        break;
    }
    case 6: {
        double x = st[top];
        uint32_t c = isnan(x) ? 0x4500u : x < 0 ? 0x100u : x == 0 ? 0x4000u : 0;
        cpu->_st_sw_cond = (cpu->_st_sw_cond & ~0x4700u) | c;
        break;
    }
    case 7: case 8: {
        double x = st[top], y = st[next];
        double q = op == 7 ? trunc(x / y) : nearbyint(x / y);
        st[top] = op == 7 ? fmod(x, y) : remainder(x, y);
        uint64_t n = isfinite(q) ? (uint64_t)fabs(fmod(q, 8)) : 0;
        cpu->_st_sw_cond = (cpu->_st_sw_cond & ~0x4700u) | ((n & 1) ? 0x200u : 0) |
            ((n & 2) ? 0x4000u : 0) | ((n & 4) ? 0x100u : 0);
        break;
    }
    case 9:
        st[next] = st[next] * log1p(st[top]) / M_LN2;
        cpu->_st_top = next;
        break;
    case 10: cpu->_st_sw_cond &= ~0x80ffu; break;
    }
}

void tc_x87_sincos(_cpu *cpu)
{
    if (!cpu || cpu->_st_top >= 8) abort();
    double angle = cpu->_st[cpu->_st_top];
    if (!isfinite(angle) || fpclassify(angle) == FP_SUBNORMAL) abort();
    if (fabs(angle) >= 0x1p63) {
        cpu->_st_sw_cond |= 0x400u;
        return;
    }
    if ((cpu->_st_cw & 0xc3fu) != 0x3fu) abort();
    fenv_t environment;
    if (feholdexcept(&environment) || fesetround(FE_TONEAREST)) abort();
    /* ponytail: same binary64/libm ceiling as upstream FSIN/FCOS. Replace
       the x87 representation and transcendental core for hardware fidelity. */
    double sine = sin(angle), cosine = cos(angle);
    if (fesetenv(&environment)) abort();
    cpu->_st[cpu->_st_top] = sine;
    cpu->_st_top = (cpu->_st_top + 7) & 7;
    cpu->_st[cpu->_st_top] = cosine;
    cpu->_st_sw_cond &= ~0x400u;
    /* C1 rounding direction and x87 precision status are not represented by
       this core. The exact zero case requires no rounding. */
    if (angle == 0) cpu->_st_sw_cond &= ~0x200u;
}

void tc_x87_compare(_cpu *cpu, uint32_t source, uint32_t quiet, uint32_t pop)
{
    if (!cpu || source >= 8 || cpu->_st_top >= 8 || quiet > 1 || pop > 1) abort();
    uint64_t a, b;
    memcpy(&a, &cpu->_st[cpu->_st_top], sizeof(a));
    memcpy(&b, &cpu->_st[(cpu->_st_top + source) & 7], sizeof(b));
    const uint64_t magnitude = UINT64_C(0x7fffffffffffffff);
    const uint64_t infinity = UINT64_C(0x7ff0000000000000);
    const uint64_t quiet_bit = UINT64_C(0x0008000000000000);
    int nan_a = (a & magnitude) > infinity, nan_b = (b & magnitude) > infinity;
    /* ponytail: upstream stores binary64 without tags. Replace the complete
       x87 state before claiming 80-bit fidelity or handling empty stack slots. */
    if ((nan_a || nan_b) && (!quiet || (nan_a && !(a & quiet_bit)) ||
                            (nan_b && !(b & quiet_bit)))) abort();
    uint32_t flags;
    if (nan_a || nan_b) flags = CF | PF | ZF;
    else if (a == b || ((a | b) & magnitude) == 0) flags = ZF;
    else {
        int less = (a >> 63) != (b >> 63) ? (int)(a >> 63) :
                   (a >> 63) ? a > b : a < b;
        flags = less ? CF : 0;
    }
    cpu->_eflags = (cpu->_eflags & ~(CF | PF | AF | ZF | SF | OF)) | flags;
    cpu->_st_sw_cond &= ~0x200u; /* C1 cleared; C0, C2 and C3 unchanged. */
    if (pop) cpu->_st_top = (cpu->_st_top + 1) & 7;
}

#ifdef TC_SSE_SELF_CHECK
#include <assert.h>
int main(void)
{
    _cpu profile={0};profile._eflags=0x202;tc_cpuid(&profile);
    assert(profile._eax==1&&profile._ebx==0x756e6547&&profile._eflags==0x202);
    profile._eax=1;tc_cpuid(&profile);assert(profile._edx==1&&!profile._ecx);
    profile._eax=7;tc_cpuid(&profile);assert(!(profile._eax|profile._ebx|profile._ecx|profile._edx));
    tc_cpu double_math = {0};
    double_math.mxcsr = TC_MXCSR_DEFAULT;
    uint64_t one64 = UINT64_C(0x3ff0000000000000), result64;
    memcpy(double_math.xmm[0], &one64, 8);
    memcpy(double_math.xmm[1], &one64, 8);
    double_math.xmm[0][2] = 123;
    tc_xmm_add64(&double_math.scalar, 0, 1, 0, 0);
    memcpy(&result64, double_math.xmm[0], 8);
    assert(result64 == UINT64_C(0x4000000000000000) && double_math.xmm[0][2] == 123);
    tc_xmm_add64(&double_math.scalar, 0, 1, 0, 1);
    double_math.mxcsr |= 1u << 13;
    tc_xmm_add64(&double_math.scalar, 0, 1, 0, 1);
    memcpy(&result64, double_math.xmm[0], 8);
    assert(result64 == UINT64_C(0x8000000000000000));
    tc_cpu packed_compare = {0};
    const uint64_t left64[4] = {0x3ff0000000000000, 0x3ff0000000000000, 0x4000000000000000, 0x7ff8000000000001};
    const uint64_t right64[4] = {0x3ff0000000000000, 0x4000000000000000, 0x3ff0000000000000, 0};
    const unsigned masks64[8] = {1, 2, 3, 8, 14, 13, 12, 7};
    for (unsigned predicate = 0; predicate < 8; ++predicate) {
        for (unsigned pair = 0; pair < 4; pair += 2) {
            memcpy(packed_compare.xmm[0], left64 + pair, 16);
            memcpy(packed_compare.xmm[1], right64 + pair, 16);
            packed_compare.mxcsr = TC_MXCSR_DEFAULT;
            packed_compare.scalar._eflags = 0x202;
            tc_xmm_compare_pd(&packed_compare.scalar, 0, 1, 0, predicate);
            uint64_t actual[2];
            memcpy(actual, packed_compare.xmm[0], 16);
            for (unsigned lane = 0; lane < 2; ++lane)
                assert(actual[lane] == ((masks64[predicate] & (1u << (pair + lane))) ? UINT64_MAX : 0));
            assert(packed_compare.scalar._eflags == 0x202);
            int signaling = predicate == 1 || predicate == 2 || predicate == 5 || predicate == 6;
            assert(packed_compare.mxcsr == (TC_MXCSR_DEFAULT | ((pair == 2 && signaling) ? 1 : 0)));
        }
    }
    tc_cpu integer = {0};
    integer.mxcsr = TC_MXCSR_DEFAULT;
    integer.xmm[0][0] = 0xffffffffu;
    integer.xmm[0][1] = 1;
    tc_xmm_sse2(&integer.scalar, 0, 32, 2, 0);
    assert(integer.xmm[0][0] == 1 && integer.xmm[0][1] == 0);
    integer.xmm[1][1] = 1; /* Count is 2^32, not a masked five-bit value. */
    tc_xmm_sse2(&integer.scalar, 0, 1, 0, 1);
    assert(integer.xmm[0][0] == 0 && integer.xmm[0][1] == 0);
    integer.xmm[1][0] = 1;
    tc_xmm_sse2(&integer.scalar, 0, 1, 0, 2);
    assert(integer.xmm[0][0] == UINT32_MAX && integer.xmm[0][1] == UINT32_MAX);
    tc_xmm_bits32(&integer.scalar, 3, 0);
    assert(integer.scalar._ebx == UINT32_MAX);
    integer.xmm[0][2] = 123;
    tc_xmm_move64(&integer.scalar, 0, 0, 0);
    assert(integer.xmm[0][0] == UINT32_MAX && integer.xmm[0][2] == 0);
    memset(integer.xmm[0], 0, 16);
    memset(integer.xmm[1], 0, 16);
    integer.xmm[1][1] = 0x80000000u;
    tc_xmm_sse2(&integer.scalar, 0, 1, 0, 3);
    assert(integer.scalar._eflags == ZF);
    integer.xmm[1][1] = 0x7ff80000u;
    tc_xmm_sse2(&integer.scalar, 0, 1, 0, 3);
    assert(integer.scalar._eflags == (CF | PF | ZF) && integer.mxcsr == TC_MXCSR_DEFAULT);
    _cpu trigonometry = {0};
    trigonometry._st_cw = 0x37f;
    trigonometry._st[0] = -0.0;
    trigonometry._st_sw_cond = 0x600;
    tc_x87_sincos(&trigonometry);
    assert(trigonometry._st_top == 7 && trigonometry._st[7] == 1.0);
    assert(trigonometry._st[0] == 0.0 && signbit(trigonometry._st[0]));
    assert(trigonometry._st_sw_cond == 0);
    trigonometry._st[7] = -0x1p63;
    tc_x87_sincos(&trigonometry);
    assert(trigonometry._st_top == 7 && trigonometry._st[7] == -0x1p63);
    assert(trigonometry._st_sw_cond & 0x400);
    uint32_t strings[] = {5, 7, 9, 5, 8, 9};
    tc_cpu compare_strings = {0};
    compare_strings.memory_size = sizeof(strings);
    compare_strings.scalar._pointer_offset = (uintptr_t)strings;
    compare_strings.scalar._edi = 12;
    compare_strings.scalar._ecx = 3;
    tc_cmps32(&compare_strings.scalar, 1);
    assert(compare_strings.scalar._esi == 8 && compare_strings.scalar._edi == 20);
    assert(compare_strings.scalar._ecx == 1 && (compare_strings.scalar._eflags & CF));
    compare_strings.scalar._eflags = DF;
    tc_cmps32(&compare_strings.scalar, 2);
    assert(compare_strings.scalar._esi == 4 && compare_strings.scalar._edi == 16);
    assert(compare_strings.scalar._ecx == 0 && (compare_strings.scalar._eflags & ZF));
    uint32_t before_flags = compare_strings.scalar._eflags;
    tc_cmps32(&compare_strings.scalar, 1);
    assert(compare_strings.scalar._esi == 4 && compare_strings.scalar._eflags == before_flags);
    tc_cpu reciprocal = {0};
    reciprocal.mxcsr = 0;
    reciprocal.xmm[0][1] = 123;
    reciprocal.xmm[1][0] = 0x40800000;
    tc_xmm_rsqrt(&reciprocal.scalar, 0, 1, 0, 1);
    assert(reciprocal.xmm[0][0] == 0x3f000000 && reciprocal.xmm[0][1] == 123);
    const uint32_t special[4] = {1, 0x80000001, 0xbf800000, 0x7f800001};
    memcpy(reciprocal.xmm[1], special, 16);
    tc_xmm_rsqrt(&reciprocal.scalar, 1, 1, 0, 0);
    assert(reciprocal.xmm[1][0] == 0x7f800000 && reciprocal.xmm[1][1] == 0xff800000);
    assert(reciprocal.xmm[1][2] == 0xffc00000 && reciprocal.xmm[1][3] == 0x7fc00001);
    assert(reciprocal.mxcsr == 0);
    const uint32_t reciprocals[4] = {0xc0000000u, 0xff800000u, 0x7f7fffffu, 0x80000000u};
    memcpy(reciprocal.xmm[2], reciprocals, 16);
    tc_xmm_rcp(&reciprocal.scalar, 2, 2, 0, 0);
    assert(reciprocal.xmm[2][0] == 0xbf000000u && reciprocal.xmm[2][1] == 0x80000000u);
    assert(reciprocal.xmm[2][2] == 0 && reciprocal.xmm[2][3] == 0xff800000u);
    assert(reciprocal.mxcsr == 0);
    _cpu shift = {0};
    shift._eax = 0x80000000u;
    shift._eflags = 0x202;
    tc_shift32(&shift, 0, shift._eax, 1, 0);
    assert(shift._eax == 0 && shift._eflags == (0x202 | CF | PF | ZF | OF));
    uint32_t saved_flags = shift._eflags;
    tc_shift32(&shift, 0, shift._eax, 32, 1);
    assert(shift._eax == 0 && shift._eflags == saved_flags);
    tc_shift32(&shift, 1, 0x80000001u, 1, 2);
    assert(shift._ecx == 0xc0000000u && shift._eflags == (0x202 | CF | PF | SF));
    tc_shift32(&shift, 2, 0x80000000u, 31, 1);
    assert(shift._edx == 1 && shift._eflags == 0x202);
    tc_double_shift32(&shift, 0, 0x80000000u, 0x80000000u, 1, 0);
    assert(shift._eax == 1 && shift._eflags == (0x202 | CF | OF));
    tc_double_shift32(&shift, 1, 1, 1, 1, 1);
    assert(shift._ecx == 0x80000000u && shift._eflags == (0x202 | CF | PF | SF | OF));
    saved_flags = shift._eflags;
    tc_double_shift32(&shift, 1, 0, 0, 32, 0);
    assert(shift._ecx == 0x80000000u && shift._eflags == saved_flags);
    tc_shift_part(&shift, 3, 0x12345680u, 1, 0, 8, 0);
    assert(shift._ebx == 0x12345600u && (shift._eflags & (CF | PF | ZF | SF | OF)) == (CF | PF | ZF | OF));
    tc_shift_part(&shift, 0, 0x12348056u, 31, 2, 8, 8);
    assert(shift._eax == 0x1234ff56u && (shift._eflags & (CF | SF | PF)) == (CF | SF | PF));
    tc_shift_part(&shift, 1, 0x12348001u, 1, 1, 16, 0);
    assert(shift._ecx == 0x12344000u && (shift._eflags & (CF | OF | SF)) == (CF | OF));
    unsigned char extended_bytes[11] = {0};
    uint64_t significand = UINT64_C(0xc000000000000000);
    uint16_t exponent = 0x3fff;
    memcpy(extended_bytes + 1, &significand, 8);
    memcpy(extended_bytes + 9, &exponent, 2);
    tc_cpu extended = {0};
    extended.scalar._st_cw = 0x37f;
    extended.scalar._pointer_offset = (uintptr_t)extended_bytes;
    extended.memory_size = sizeof(extended_bytes);
    extended.mxcsr = TC_MXCSR_DEFAULT;
    tc_x87_load80(&extended.scalar, 1);
    assert(extended.scalar._st_top == 7 && extended.scalar._st[7] == 1.5);
    assert(extended.mxcsr == TC_MXCSR_DEFAULT);
    memset(extended_bytes + 1, 0, 10);
    extended_bytes[10] = 0x80;
    tc_x87_load80(&extended.scalar, 1);
    assert(extended.scalar._st_top == 6 && signbit(extended.scalar._st[6]));
    unsigned char result_memory[16] = {0};
    tc_cpu result_cpu = {0};
    result_cpu.scalar._pointer_offset = (uintptr_t)result_memory;
    result_cpu.memory_size = sizeof(result_memory);
    result_cpu.x87_result_address = 4;
    uint64_t result_value = UINT64_C(0x0123456789abcdef), copied_value;
    assert(tc_x87_result(&result_cpu.scalar, &result_value) == 4);
    memcpy(&copied_value, result_memory + 4, 8);
    assert(copied_value == result_value && result_memory[3] == 0 && result_memory[12] == 0);
    result_cpu.fs_base = 4;
    result_cpu.fs_size = 12;
    tc_write_fs(&result_cpu.scalar, 1, 0x12345678u);
    assert(tc_read_fs(&result_cpu.scalar, 1) == 0x12345678u);
    tc_write_fs(&result_cpu.scalar, 8, 0xabcdef01u);
    assert(tc_read_fs(&result_cpu.scalar, 8) == 0xabcdef01u);
    result_cpu.scalar._esp = 0;
    uint32_t performance_address = 8;
    memcpy(result_memory + 4, &performance_address, 4);
    tc_import_dispatch(&result_cpu.scalar, 0x00676084);
    memcpy(&copied_value, result_memory + 8, 8);
    assert(copied_value == UINT64_C(1000000000) && result_cpu.scalar._eax == 1);
    assert(result_cpu.scalar._esp == 0);
    unsigned char thread_bytes[64] = {0};
    tc_cpu thread_cpu = {0};
    thread_cpu.scalar._pointer_offset = (uintptr_t)thread_bytes;
    thread_cpu.memory_size = sizeof(thread_bytes);
    thread_cpu.fs_base = 8;
    thread_cpu.fs_size = 56;
    uint32_t last_error = 0x80000001u;
    memcpy(thread_bytes + 4, &last_error, 4);
    tc_import_dispatch(&thread_cpu.scalar, 0x00676144);
    tc_import_dispatch(&thread_cpu.scalar, 0x00676080);
    assert(thread_cpu.scalar._eax == last_error && thread_cpu.scalar._esp == 0);
    tc_write_fs(&thread_cpu.scalar, 0x20, 99);
    tc_write_fs(&thread_cpu.scalar, 0x24, 7);
    tc_import_dispatch(&thread_cpu.scalar, 0x0067618c);
    assert(thread_cpu.scalar._eax == 99);
    tc_import_dispatch(&thread_cpu.scalar, 0x006760b0);
    assert(thread_cpu.scalar._eax == 7 && tc_read_fs(&thread_cpu.scalar, 0x34) == last_error);
    _cpu rounded = {0};
    const double rounded_expected[4][2] = {{2, -2}, {1, -2}, {2, -1}, {1, -1}};
    for (unsigned mode = 0; mode < 4; ++mode) {
        for (unsigned negative = 0; negative < 2; ++negative) {
            rounded._st_cw = 0x37f | (mode << 10);
            rounded._st[0] = negative ? -1.5 : 1.5;
            rounded._st_sw_cond = 0x4500;
            tc_x87_round(&rounded);
            assert(rounded._st[0] == rounded_expected[mode][negative]);
            assert(rounded._st_sw_cond == (0x4520u |
                (fabs(rounded_expected[mode][negative]) == 2 ? 0x200u : 0)));
        }
    }
    rounded._st[0] = -0.0;
    tc_x87_round(&rounded);
    assert(signbit(rounded._st[0]) && (rounded._st_sw_cond & 0x20));
    _cpu arc = {0};
    arc._st_cw = 0x37f;
    arc._st_top = 7;
    arc._st[7] = 1;
    arc._st[0] = -0.0;
    tc_x87_atan(&arc);
    assert(arc._st_top == 0 && arc._st[0] == 0 && signbit(arc._st[0]));
    arc._st[0] = 1;
    arc._st[1] = 1;
    tc_x87_atan(&arc);
    assert(arc._st_top == 1 && fabs(arc._st[1] - 0.7853981633974483) < 1e-15);
    arc._st[1] = 0.5;
    tc_x87_exp2m1(&arc);
    assert(fabs(arc._st[1] - (M_SQRT2 - 1)) < 1e-15);
    arc._st[1] = 1.5;
    arc._st[2] = 3.9;
    tc_x87_scale(&arc);
    assert(arc._st[1] == 12 && arc._st_top == 1);
    arc._st_sw_cond = 0xc7ffu;
    tc_x87_clear(&arc);
    assert(arc._st_sw_cond == 0x4700u);
    tc_x87_pi(&arc);
    assert(arc._st_top == 0 && arc._st[0] == 0x1.921fb54442d18p1);
    _cpu fp = {0};
    fp._st_top = 7;
    fp._st[7] = -2.0;
    fp._st[0] = -1.0;
    fp._eflags = 0x202 | CF | PF | AF | ZF | SF | OF;
    fp._st_sw_cond = 0x4700;
    tc_x87_compare(&fp, 1, 0, 1);
    assert(fp._eflags == (0x202 | CF) && fp._st_top == 0 && fp._st_sw_cond == 0x4500);
    fp._st[0] = -0.0;
    fp._st[1] = 0.0;
    tc_x87_compare(&fp, 1, 0, 0);
    assert(fp._eflags == (0x202 | ZF) && fp._st_top == 0);
    uint64_t qnan = UINT64_C(0x7ff8000000000001);
    memcpy(&fp._st[1], &qnan, sizeof(qnan));
    tc_x87_compare(&fp, 1, 1, 0);
    assert(fp._eflags == (0x202 | CF | PF | ZF));
    unsigned char bytes[64] = {0};
    tc_cpu context = {.mxcsr = TC_MXCSR_DEFAULT};
    context.scalar._pointer_offset = (uintptr_t)bytes;
    context.memory_size = sizeof(bytes);
    context.scalar._eax = 0x12345678;
    for (unsigned i = 0; i < 16; ++i) bytes[i] = (unsigned char)(i * 13);
    tc_xmm_load(&context.scalar, 0, 0, 16);
    tc_xmm_copy(&context.scalar, 7, 0);
    tc_xmm_copy(&context.scalar, 7, 7);
    tc_xmm_store(&context.scalar, 7, 32, 16);
    assert(memcmp(bytes, bytes + 32, 16) == 0);
    tc_xmm_store(&context.scalar, 7, 17, 1);
    assert(memcmp(bytes, bytes + 17, 16) == 0);
    assert(context.scalar._eax == 0x12345678);
    for (unsigned i = 0; i < 4; ++i) context.xmm[1][i] = i + 1;
    tc_xmm_shuffle(&context.scalar, 1, 1, 0, 0x1b);
    for (unsigned i = 0; i < 4; ++i) assert(context.xmm[1][i] == 4 - i);
    context.xmm[2][0] = 0x80000000;
    tc_xmm_copy32(&context.scalar, 1, 2);
    assert(context.xmm[1][0] == 0x80000000 && context.xmm[1][1] == 3);
    tc_xmm_store32(&context.scalar, 1, 60);
    tc_xmm_load32(&context.scalar, 1, 60);
    assert(context.xmm[1][0] == 0x80000000);
    for (unsigned i = 1; i < 4; ++i) assert(context.xmm[1][i] == 0);
    const uint32_t expected[] = {0x66666666, 0x88888888, 0x22222222, 0xeeeeeeee};
    for (unsigned op = 0; op < 4; ++op) {
        for (unsigned i = 0; i < 4; ++i) {
            context.xmm[0][i] = 0xcccccccc;
            context.xmm[1][i] = 0xaaaaaaaa;
        }
        tc_xmm_store(&context.scalar, 1, 48, 16);
        tc_xmm_logic(&context.scalar, 0, op & 1 ? 48 : 1, op & 1, op);
        for (unsigned i = 0; i < 4; ++i) assert(context.xmm[0][i] == expected[op]);
    }
    tc_xmm_logic(&context.scalar, 0, 0, 0, 0);
    for (unsigned i = 0; i < 4; ++i) assert(context.xmm[0][i] == 0);
    for (unsigned high = 0; high < 2; ++high) {
        for (unsigned i = 0; i < 4; ++i) {
            context.xmm[0][i] = i + 1;
            context.xmm[1][i] = i + 5;
        }
        tc_xmm_store(&context.scalar, 1, 48, 16);
        tc_xmm_unpack(&context.scalar, 0, high ? 48 : 1, high, high);
        assert(context.xmm[0][0] == 1 + high * 2);
        assert(context.xmm[0][1] == 5 + high * 2);
        assert(context.xmm[0][2] == 2 + high * 2);
        assert(context.xmm[0][3] == 6 + high * 2);
    }
    tc_xmm_unpack(&context.scalar, 1, 1, 0, 0);
    assert(context.xmm[1][0] == 5 && context.xmm[1][1] == 5);
    assert(context.xmm[1][2] == 6 && context.xmm[1][3] == 6);
    tc_xmm_movlh(&context.scalar, 0, 1);
    assert(context.xmm[0][0] == 3 && context.xmm[0][1] == 7);
    assert(context.xmm[0][2] == 5 && context.xmm[0][3] == 5);
    tc_xmm_movlh(&context.scalar, 0, 0);
    assert(context.xmm[0][2] == 3 && context.xmm[0][3] == 7);
    context.xmm[0][0] = 0x3fc00000; /* 1.5 */
    context.xmm[1][0] = 0x40000000; /* 2 */
    tc_xmm_arithmetic(&context.scalar, 0, 1, 0, 1, 0);
    assert(context.xmm[0][0] == 0x40600000 && context.xmm[0][1] == 7);
    tc_xmm_arithmetic(&context.scalar, 0, 1, 0, 1, 1);
    assert(context.xmm[0][0] == 0x3fc00000);
    tc_xmm_arithmetic(&context.scalar, 0, 1, 0, 1, 2);
    assert(context.xmm[0][0] == 0x40400000);
    tc_xmm_arithmetic(&context.scalar, 0, 1, 0, 1, 3);
    assert(context.xmm[0][0] == 0x3fc00000);
    context.xmm[1][0] = 0x40800000; /* 4 */
    tc_xmm_arithmetic(&context.scalar, 0, 1, 0, 1, 4);
    assert(context.xmm[0][0] == 0x40000000);
    context.xmm[1][0] = 0;
    tc_xmm_arithmetic(&context.scalar, 0, 1, 0, 1, 3);
    assert(context.xmm[0][0] == 0x7f800000 && (context.mxcsr & 4));
    context.mxcsr = TC_MXCSR_DEFAULT | (2u << 13); /* Round toward +infinity. */
    context.xmm[0][0] = 0x3f800000;
    context.xmm[1][0] = 0x33000000; /* 2^-25 */
    tc_xmm_arithmetic(&context.scalar, 0, 1, 0, 1, 0);
    assert(context.xmm[0][0] == 0x3f800001 && (context.mxcsr & 32));
    tc_mxcsr_store(&context.scalar, 60);
    context.mxcsr = 0;
    tc_mxcsr_load(&context.scalar, 60);
    assert(context.mxcsr == (TC_MXCSR_DEFAULT | (2u << 13) | 32));
    context.mxcsr = TC_MXCSR_DEFAULT;
    context.scalar._eflags = IF | DF | CF | PF | AF | ZF | SF | OF;
    context.xmm[0][0] = 0x80000000;
    context.xmm[1][0] = 0;
    tc_xmm_compare(&context.scalar, 0, 1, 0, 0);
    assert(context.scalar._eflags == (IF | DF | ZF));
    context.xmm[0][0] = 0xc0000000; /* -2 < -1 */
    context.xmm[1][0] = 0xbf800000;
    tc_xmm_compare(&context.scalar, 0, 1, 0, 0);
    assert(context.scalar._eflags == (IF | DF | CF));
    context.xmm[1][0] = 0x7fc00001;
    tc_xmm_store32(&context.scalar, 1, 60);
    tc_xmm_compare(&context.scalar, 0, 60, 1, 1);
    assert(context.scalar._eflags == (IF | DF | ZF | PF | CF));
    assert(context.mxcsr == TC_MXCSR_DEFAULT);
    tc_xmm_compare(&context.scalar, 0, 1, 0, 0);
    assert(context.mxcsr == (TC_MXCSR_DEFAULT | 1));
    context.mxcsr = TC_MXCSR_DEFAULT;
    context.xmm[1][0] = 0x7f800001;
    tc_xmm_compare(&context.scalar, 0, 1, 0, 1);
    assert(context.mxcsr == (TC_MXCSR_DEFAULT | 1));
    context.mxcsr = TC_MXCSR_DEFAULT;
    context.xmm[1][0] = 0x3fc00000;
    tc_xmm_to_i32(&context.scalar, 1, 1, 0, 0);
    assert(context.scalar._ecx == 2 && (context.mxcsr & 32));
    tc_xmm_to_i32(&context.scalar, 1, 1, 0, 1);
    assert(context.scalar._ecx == 1);
    tc_xmm_from_i32(&context.scalar, 0, 0x80000000u, 0);
    assert(context.xmm[0][0] == 0xcf000000 && context.xmm[0][1] == 7);
    context.xmm[1][0] = 0x7f800000;
    tc_xmm_store32(&context.scalar, 1, 60);
    tc_xmm_to_i32(&context.scalar, 1, 60, 1, 1);
    assert(context.scalar._ecx == 0x80000000u && (context.mxcsr & 1));
    const uint32_t predicate_masks[8] = {1, 2, 3, 8, 14, 13, 12, 7};
    for (unsigned predicate = 0; predicate < 8; ++predicate) {
        const uint32_t left[4] = {0x3f800000, 0x3f800000, 0x40000000, 0x7fc00001};
        const uint32_t right[4] = {0x3f800000, 0x40000000, 0x3f800000, 0};
        context.mxcsr = TC_MXCSR_DEFAULT;
        memcpy(context.xmm[0], left, 16);
        memcpy(context.xmm[1], right, 16);
        tc_xmm_compare_mask(&context.scalar, 0, 1, 0, 0, predicate);
        tc_xmm_movemask(&context.scalar, 1, 0);
        assert(context.scalar._ecx == predicate_masks[predicate]);
        assert((context.mxcsr & 1) == (predicate == 1 || predicate == 2 || predicate == 5 || predicate == 6));
    }
    context.mxcsr = TC_MXCSR_DEFAULT;
    context.xmm[0][0] = 0;
    context.xmm[1][0] = 0x80000000;
    tc_xmm_minmax(&context.scalar, 0, 1, 0, 1, 0);
    assert(context.xmm[0][0] == 0x80000000);
    context.xmm[1][0] = 0x7f800001;
    tc_xmm_minmax(&context.scalar, 0, 1, 0, 1, 1);
    assert(context.xmm[0][0] == 0x7f800001 && (context.mxcsr & 1));
    context.mxcsr = TC_MXCSR_DEFAULT;
    context.xmm[0][0] = 0xc0000000;
    context.xmm[1][0] = 0xbf800000;
    tc_xmm_store(&context.scalar, 1, 48, 16);
    tc_xmm_minmax(&context.scalar, 0, 48, 1, 1, 1);
    assert(context.xmm[0][0] == 0xbf800000);
    assert(context.scalar._eax == 0x12345678);
    return 0;
}
#endif
