#ifndef TC_FILES_H
#define TC_FILES_H
#include "tc_sse.h"
/* Caller frees the returned filesystem path. */
char *tc_file_native_path(_cpu *cpu,uint32_t address);
void *tc_files_create(const char *executable);
void tc_files_destroy(void *state);
void tc_standard_get(_cpu *cpu);
void tc_standard_set(_cpu *cpu);
void tc_handle_count(_cpu *cpu);
void tc_module_filename(_cpu *cpu);
void tc_directory_get(_cpu *cpu);
void tc_directory_set(_cpu *cpu);
void tc_directory_create(_cpu *cpu);
void tc_disk_space(_cpu *cpu);
void tc_file_open(_cpu *cpu);
void tc_file_open_w(_cpu *cpu);
void tc_profile_write(_cpu *cpu);
void tc_profile_string(_cpu *cpu);
void tc_profile_integer(_cpu *cpu);
void tc_file_read(_cpu *cpu);
void tc_file_write(_cpu *cpu);
void tc_file_flush(_cpu *cpu);
void tc_file_end(_cpu *cpu);
void tc_file_size(_cpu *cpu);
void tc_file_seek(_cpu *cpu);
void tc_file_close(_cpu *cpu);
void tc_file_attributes(_cpu *cpu);
void tc_file_type(_cpu *cpu);
void tc_mmio_open(_cpu *cpu);
void tc_mmio_close(_cpu *cpu);
void tc_mmio_fourcc(_cpu *cpu);
void tc_mmio_descend(_cpu *cpu);
void tc_mmio_read(_cpu *cpu);
void tc_mmio_ascend(_cpu *cpu);
#endif
