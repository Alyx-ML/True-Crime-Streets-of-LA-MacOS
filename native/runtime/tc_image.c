#include "tc_image.h"
#include "tc_tls.h"
#include "tc_heap.h"
#include "tc_d3d8.h"
#include "tc_dinput.h"
#include "tc_dsound.h"
#include "tc_bink.h"
#include "tc_vm.h"
#include "tc_sync.h"
#include "tc_files.h"
#include "tc_process.h"
#include "tc_threads.h"
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define TC_FILE_SIZE 2932736u
#define TC_IMAGE_BASE 0x00400000u
#define TC_IMAGE_SIZE 0x00364000u
#define TC_STACK_TOP 0x04000000u
#define TC_STACK_SIZE 0x00100000u
#define TC_RUNTIME_BASE 0x03e00000u
#define TC_RUNTIME_SIZE 0x00004000u
#define TC_HEAP_BASE 0x10000000u
#define TC_HEAP_SIZE 0x60000000u
#define TC_VM_BASE 0x70000000u
#define TC_VM_SIZE 0x10000000u
#define TC_STATIC_TLS_ARRAY (TC_RUNTIME_BASE + 0x2000u)
#define TC_STATIC_TLS_DATA (TC_RUNTIME_BASE + 0x2010u)

static uint16_t read16(const unsigned char *p)
{
    return (uint16_t)p[0] | (uint16_t)p[1] << 8;
}

static uint32_t read32(const unsigned char *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static int fail(char *error, size_t size, const char *message)
{
    if (error && size) snprintf(error, size, "%s", message);
    return -1;
}

static int modern_display_modes(unsigned char *memory)
{
    static const uint32_t old_modes[][2]={{640,480},{800,600},{1024,768},{1152,864},{1280,960}};
    static const uint32_t modes[][2]={{640,480},{1280,720},{1920,1080},{2560,1440},{3840,2160}};
    /* The original Display screen and renderer use separate fixed-size tables.
     * Updating adapter enumeration alone is filtered out by these tables. */
    for(unsigned i=0;i<5;i++) {
        if(memcmp(memory+0x6b16c8+i*8,old_modes[i],8))return -1;
        for(unsigned format=0;format<3;format++)
            if(memcmp(memory+0x68d5a8+(i*3+format)*12,old_modes[i],8))return -1;
    }
    for(unsigned i=0;i<5;i++) {
        memcpy(memory+0x6b16c8+i*8,modes[i],8);
        for(unsigned format=0;format<3;format++)
            memcpy(memory+0x68d5a8+(i*3+format)*12,modes[i],8);
    }
    return 0;
}

int tc_image_open(tc_image *image, const char *executable, char *error, size_t error_size)
{
    static const unsigned char supported_sha256[32] = {
        0x2b,0x96,0x54,0x35,0x03,0x9c,0x42,0x5b,0x4b,0xb0,0xf4,0xab,0x90,0x79,0xd8,0xce,
        0x8a,0x87,0xc8,0x02,0x2e,0x40,0xa5,0x03,0x83,0x01,0xcf,0xac,0x2d,0xb5,0x9e,0xfc
    };
    if (!image || !executable || image->cpu.memory_size)
        return fail(error, error_size, "Expected an unused image and executable path");
    if (sizeof(size_t) < 8) return fail(error, error_size, "A 64-bit host is required");
    FILE *file = fopen(executable, "rb");
    if (!file) {
        int open_error=errno;
        if(error&&error_size)snprintf(error,error_size,"Cannot open TrueCrime.exe: %s (errno %d)",strerror(open_error),open_error);
        return -1;
    }
    unsigned char *data = malloc(TC_FILE_SIZE);
    if (!data) {
        fclose(file);
        return fail(error, error_size, "Cannot allocate executable input buffer");
    }
    size_t count = fread(data, 1, TC_FILE_SIZE, file);
    int extra = fgetc(file);
    int read_error = ferror(file);
    int close_error = fclose(file);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (count != TC_FILE_SIZE || extra != EOF || read_error || close_error ||
        !CC_SHA256(data, TC_FILE_SIZE, digest) || memcmp(digest, supported_sha256, 32)) {
        free(data);
        return fail(error, error_size, "Unsupported executable size or SHA-256");
    }

    /* Fixed layout is authorized only by the exact executable hash above. */
    uint32_t pe = read32(data + 0x3c);
    if (pe > TC_FILE_SIZE - 248 || memcmp(data + pe, "PE\0\0", 4)) goto bad_layout;
    const unsigned char *optional = data + pe + 24;
    uint32_t headers = read32(optional + 60);
    uint16_t sections = read16(data + pe + 6);
    uint32_t table = pe + 24 + read16(data + pe + 20);
    if (read16(data + pe + 4) != 0x14c || read16(optional) != 0x10b ||
        read32(optional + 28) != TC_IMAGE_BASE || read32(optional + 56) != TC_IMAGE_SIZE ||
        read32(optional + 72) != TC_STACK_SIZE || headers > TC_IMAGE_SIZE ||
        headers > TC_FILE_SIZE || table > TC_FILE_SIZE ||
        sections > (TC_FILE_SIZE - table) / 40) goto bad_layout;
    for (unsigned i = 0; i < sections; ++i) {
        const unsigned char *section = data + table + i * 40;
        uint32_t virtual_size = read32(section + 8), rva = read32(section + 12);
        uint32_t raw_size = read32(section + 16), raw_offset = read32(section + 20);
        if (rva > TC_IMAGE_SIZE || virtual_size > TC_IMAGE_SIZE - rva ||
            raw_size > TC_IMAGE_SIZE - rva || raw_offset > TC_FILE_SIZE ||
            raw_size > TC_FILE_SIZE - raw_offset) goto bad_layout;
    }

    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0 || TC_IMAGE_BASE % page || TC_IMAGE_SIZE % page ||
        TC_STACK_TOP % page || TC_STACK_SIZE % page ||
        TC_RUNTIME_BASE % page || TC_RUNTIME_SIZE % page ||
        TC_HEAP_BASE % page || TC_HEAP_SIZE % page) {
        free(data);
        return fail(error, error_size, "Unsupported host page alignment");
    }
    size_t capacity = (size_t)(UINT64_C(1) << 32);
    unsigned char *mapping = mmap(NULL, capacity, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mapping == MAP_FAILED) {
        free(data);
        return fail(error, error_size, "Cannot reserve the 32-bit guest address space");
    }
    if (mprotect(mapping + TC_IMAGE_BASE, TC_IMAGE_SIZE, PROT_READ | PROT_WRITE) ||
        mprotect(mapping + TC_STACK_TOP - TC_STACK_SIZE, TC_STACK_SIZE, PROT_READ | PROT_WRITE) ||
        mprotect(mapping + TC_RUNTIME_BASE, TC_RUNTIME_SIZE, PROT_READ | PROT_WRITE) ||
        mprotect(mapping + TC_HEAP_BASE, TC_HEAP_SIZE, PROT_READ | PROT_WRITE)) {
        munmap(mapping, capacity);
        free(data);
        return fail(error, error_size, "Cannot commit guest image, stack, runtime and heap memory");
    }
    memcpy(mapping + TC_IMAGE_BASE, data, headers);
    for (unsigned i = 0; i < sections; ++i) {
        const unsigned char *section = data + table + i * 40;
        memcpy(mapping + TC_IMAGE_BASE + read32(section + 12),
               data + read32(section + 20), read32(section + 16));
    }
    if(modern_display_modes(mapping)) {
        munmap(mapping,capacity);free(data);
        return fail(error,error_size,"Original Display tables do not match the supported executable");
    }
    tc_image loaded = {0};
    loaded.cpu.scalar._pointer_offset = (uintptr_t)mapping;
    loaded.cpu.memory_size = capacity;
    loaded.cpu.mxcsr = TC_MXCSR_DEFAULT;
    loaded.cpu.x87_result_address = TC_RUNTIME_BASE;
    loaded.cpu.fs_base = TC_RUNTIME_BASE + 0x1000;
    loaded.cpu.fs_size = 0x1000;
    loaded.cpu.command_line_address = TC_RUNTIME_BASE + 0x3000;
    /* The native launcher currently supports a game directory, not guest
       command-line switches. Preserve Windows quoting for argv[0]. */
    static const char command_line[] = "\"TrueCrime.exe\"";
    memcpy(mapping + loaded.cpu.command_line_address, command_line, sizeof(command_line));
    loaded.cpu.scalar._st_cw = 0x037f;
    loaded.cpu.scalar._eflags = 0x0202;
    loaded.cpu.scalar._esp = TC_STACK_TOP;
    loaded.entry = TC_IMAGE_BASE + read32(optional + 16);
    loaded.stack_limit = TC_STACK_TOP - TC_STACK_SIZE;
    loaded.stack_top = TC_STACK_TOP;
    /* The 32-bit NT_TIB prefix. PEB and exception delivery are separate work. */
    tc_write_fs(&loaded.cpu.scalar, 0x00, UINT32_MAX);
    tc_write_fs(&loaded.cpu.scalar, 0x04, loaded.stack_top);
    tc_write_fs(&loaded.cpu.scalar, 0x08, loaded.stack_limit);
    tc_write_fs(&loaded.cpu.scalar, 0x18, loaded.cpu.fs_base);
    tc_write_fs(&loaded.cpu.scalar, 0x20, (uint32_t)getpid());
    /* Guest thread 1 is the initial CPU. Future thread creation must allocate
       distinct guest IDs; these are not macOS pthread identifiers. */
    tc_write_fs(&loaded.cpu.scalar, 0x24, 1);
    /* Exact-image PE TLS directory: [0x75a000,0x75a040), index at
       0x757910, zero-fill 0, null callback list at 0x69b450. Module index 0
       belongs to this executable. Each future CPU needs its own array/block. */
    uint32_t static_tls_data = TC_STATIC_TLS_DATA, static_tls_index = 0;
    memcpy(mapping + TC_STATIC_TLS_ARRAY, &static_tls_data, 4);
    memcpy(mapping + TC_STATIC_TLS_DATA, mapping + 0x75a000, 0x40);
    memcpy(mapping + 0x757910, &static_tls_index, 4);
    tc_write_fs(&loaded.cpu.scalar, 0x2c, TC_STATIC_TLS_ARRAY);
    loaded.cpu.tls_process = tc_tls_create();
    if (!loaded.cpu.tls_process) {
        munmap(mapping, capacity);
        free(data);
        return fail(error, error_size, "Cannot allocate process TLS state");
    }
    loaded.cpu.heap_process = tc_heap_process_create((uintptr_t)mapping, TC_HEAP_BASE, TC_HEAP_SIZE);
    if (!loaded.cpu.heap_process) {
        tc_tls_destroy(loaded.cpu.tls_process);
        munmap(mapping, capacity);
        free(data);
        return fail(error, error_size, "Cannot allocate process heap state");
    }
    loaded.cpu.vm_process = tc_vm_create((uintptr_t)mapping, TC_VM_BASE, TC_VM_SIZE);
    if (!loaded.cpu.vm_process) {
        tc_heap_process_destroy(loaded.cpu.heap_process);
        tc_tls_destroy(loaded.cpu.tls_process);
        munmap(mapping, capacity);
        free(data);
        return fail(error, error_size, "Cannot allocate virtual-memory state");
    }
    loaded.cpu.sync_process=tc_sync_create();
    if (!loaded.cpu.sync_process) {
        tc_vm_destroy(loaded.cpu.vm_process);
        tc_heap_process_destroy(loaded.cpu.heap_process);
        tc_tls_destroy(loaded.cpu.tls_process);
        munmap(mapping,capacity);
        free(data);
        return fail(error,error_size,"Cannot allocate synchronization state");
    }
    loaded.cpu.files=tc_files_create(executable);
    if (!loaded.cpu.files) {
        tc_sync_destroy(loaded.cpu.sync_process);
        tc_vm_destroy(loaded.cpu.vm_process);
        tc_heap_process_destroy(loaded.cpu.heap_process);
        tc_tls_destroy(loaded.cpu.tls_process);
        munmap(mapping,capacity);
        free(data);
        return fail(error,error_size,"Cannot allocate file handle state");
    }
    loaded.cpu.process=tc_process_create(loaded.cpu.heap_process);
    if(!loaded.cpu.process) {
        tc_image_close(&loaded);
        free(data);
        return fail(error,error_size,"Cannot allocate process environment state");
    }
    loaded.cpu.threads=tc_threads_create(loaded.cpu.heap_process);
    if(!loaded.cpu.threads) {
        tc_image_close(&loaded);free(data);
        return fail(error,error_size,"Cannot allocate native thread state");
    }
    if(!tc_ds_open(&loaded.cpu)) {
        tc_image_close(&loaded);free(data);
        return fail(error,error_size,"Cannot allocate native audio state");
    }
    if(!tc_bink_init(&loaded.cpu)){tc_image_close(&loaded);free(data);return fail(error,error_size,"Cannot allocate native movie state");}
    tc_imports_install(&loaded.cpu.scalar);
    free(data);
    *image = loaded;
    if (error && error_size) error[0] = 0;
    return 0;

bad_layout:
    free(data);
    return fail(error, error_size, "Unsupported PE section layout");
}

void tc_image_close(tc_image *image)
{
    if (!image) return;
    tc_threads_destroy(image->cpu.threads);
    tc_d3d_close(&image->cpu);
    tc_di_close(&image->cpu);
    tc_bink_destroy(&image->cpu);
    tc_ds_close(&image->cpu);
    tc_files_destroy(image->cpu.files);
    tc_sync_destroy(image->cpu.sync_process);
    tc_process_destroy(image->cpu.process);
    tc_heap_process_destroy(image->cpu.heap_process);
    tc_vm_destroy(image->cpu.vm_process);
    tc_tls_destroy(image->cpu.tls_process);
    if (image->cpu.memory_size)
        munmap((void *)(uintptr_t)image->cpu.scalar._pointer_offset, image->cpu.memory_size);
    memset(image, 0, sizeof(*image));
}

#ifdef TC_IMAGE_SELF_CHECK
#include <assert.h>
int main(int argc, char **argv)
{
    assert(argc == 2);
    tc_image image = {0};
    char error[128];
    assert(tc_image_open(&image, argv[1], error, sizeof(error)) == 0);
    const unsigned char *memory = (void *)(uintptr_t)image.cpu.scalar._pointer_offset;
    assert(read16(memory + TC_IMAGE_BASE) == 0x5a4d);
    assert(read16(memory + 0x4010a0) == 0xc18b);
    assert(image.entry == 0x75d005 && image.cpu.mxcsr == TC_MXCSR_DEFAULT);
    assert(read32(memory + image.stack_limit) == 0);
    assert(read32(memory+0x6b16e8)==3840&&read32(memory+0x6b16ec)==2160);
    assert(read32(memory+0x68d638)==3840&&read32(memory+0x68d63c)==2160);
    assert(read32(memory+0x68d658)==32);
    assert(image.cpu.x87_result_address == TC_RUNTIME_BASE);
    assert(read32(memory + TC_RUNTIME_BASE) == 0);
    assert(tc_read_fs(&image.cpu.scalar, 0x2c) == TC_STATIC_TLS_ARRAY);
    assert(read32(memory + TC_STATIC_TLS_ARRAY) == TC_STATIC_TLS_DATA);
    assert(read32(memory + 0x757910) == 0);
    assert(memcmp(memory + TC_STATIC_TLS_DATA, memory + 0x75a000, 0x40) == 0);
    assert(tc_read_fs(&image.cpu.scalar, 0) == UINT32_MAX);
    assert(tc_read_fs(&image.cpu.scalar, 4) == image.stack_top);
    assert(tc_read_fs(&image.cpu.scalar, 8) == image.stack_limit);
    assert(tc_read_fs(&image.cpu.scalar, 0x18) == image.cpu.fs_base);
    assert(tc_read_fs(&image.cpu.scalar, 0x20) == (uint32_t)getpid());
    assert(tc_read_fs(&image.cpu.scalar, 0x24) == 1);
    assert(tc_image_open(&image, argv[1], error, sizeof(error)) == -1);
    tc_image_close(&image);
    assert(image.cpu.memory_size == 0);
    tc_image_close(&image);
    return 0;
}
#endif
