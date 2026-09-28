#ifndef TC_PROCESS_H
#define TC_PROCESS_H
#include "tc_sse.h"
struct tc_process *tc_process_create(struct tc_heap_process *heaps);
void tc_process_destroy(struct tc_process *process);
void tc_environment_a(_cpu *cpu);
void tc_environment_w(_cpu *cpu);
void tc_free_environment_a(_cpu *cpu);
void tc_free_environment_w(_cpu *cpu);
void tc_ansi_codepage(_cpu *cpu);
void tc_oem_codepage(_cpu *cpu);
void tc_codepage_info(_cpu *cpu);
void tc_version_info(_cpu *cpu);
void tc_string_type_a(_cpu *cpu);
void tc_string_type_w(_cpu *cpu);
void tc_map_string_a(_cpu *cpu);
void tc_map_string_w(_cpu *cpu);
void tc_multibyte_to_wide(_cpu *cpu);
void tc_wide_to_multibyte(_cpu *cpu);
void tc_command_line(_cpu *cpu);
void tc_startup_info(_cpu *cpu);
void tc_debug_output(_cpu *cpu);
void tc_module_handle(_cpu *cpu);
void tc_load_library(_cpu *cpu);
void tc_get_proc_address(_cpu *cpu);
void tc_system_info(_cpu *cpu);
void tc_local_time(_cpu *cpu);
void tc_system_filetime(_cpu *cpu);
void tc_priority_class(_cpu *cpu);
void tc_set_exception_filter(_cpu *cpu);
void tc_exit_process(_cpu *cpu);
void tc_registry_create(_cpu *cpu);
void tc_registry_open(_cpu *cpu);
void tc_registry_open_legacy(_cpu *cpu);
void tc_registry_close(_cpu *cpu);
void tc_registry_query(_cpu *cpu);
void tc_registry_set(_cpu *cpu);
#endif
