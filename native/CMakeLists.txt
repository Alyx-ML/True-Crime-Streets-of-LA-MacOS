cmake_minimum_required(VERSION 3.20)
project(TrueCrimeRecompTools LANGUAGES C CXX OBJC)

# Tools, native runtime and an explicitly requested development app target.
set(SRW "${CMAKE_CURRENT_SOURCE_DIR}/vendor/SR/SRW")
file(GLOB SRW_SOURCES CONFIGURE_DEPENDS
    "${SRW}/*.c" "${SRW}/*.cpp" "${SRW}/udis86-1.7.2/libudis86/*.c")
add_executable(srw ${SRW_SOURCES})
target_include_directories(srw PRIVATE "${SRW}/udis86-1.7.2")
target_compile_definitions(srw PRIVATE HAVE_STRING_H=1 OUTPUT_TYPE=7)
target_compile_features(srw PRIVATE cxx_std_20)

file(GLOB UDIS_SOURCES CONFIGURE_DEPENDS "${SRW}/udis86-1.7.2/libudis86/*.c")
add_library(tc_decode SHARED decode.c ${UDIS_SOURCES})
target_include_directories(tc_decode PRIVATE "${SRW}/udis86-1.7.2")
target_compile_definitions(tc_decode PRIVATE HAVE_STRING_H=1)

add_library(tc_sse STATIC runtime/tc_sse.c runtime/tc_tls.c runtime/tc_heap.c runtime/tc_vm.c runtime/tc_sync.c runtime/tc_threads.m runtime/tc_d3d8.m runtime/tc_modern.m runtime/tc_dinput.c runtime/tc_process.c runtime/tc_files.m runtime/tc_registry.m runtime/tc_dsound.m runtime/tc_video.c runtime/tc_bink.c)
find_package(PkgConfig REQUIRED)
# Prefer the minimal LGPL FFmpeg (Bink demuxer/decoders only) in vendor/ffmpeg-lgpl.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/vendor/ffmpeg-lgpl/lib/pkgconfig")
    set(ENV{PKG_CONFIG_PATH} "${CMAKE_CURRENT_SOURCE_DIR}/vendor/ffmpeg-lgpl/lib/pkgconfig")
endif()
pkg_check_modules(TC_FFMPEG REQUIRED IMPORTED_TARGET libavformat libavcodec libavutil libswscale)
target_link_libraries(tc_sse PUBLIC PkgConfig::TC_FFMPEG)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(TC_METAL_HEADER "${CMAKE_CURRENT_BINARY_DIR}/tc_fixed_metallib.h")
add_custom_command(OUTPUT "${TC_METAL_HEADER}"
    COMMAND xcrun -sdk macosx metal -std=macos-metal2.4
        "-fmodules-cache-path=${CMAKE_CURRENT_BINARY_DIR}/metal-module-cache"
        "${CMAKE_CURRENT_SOURCE_DIR}/runtime/tc_fixed.metal"
        -o "${CMAKE_CURRENT_BINARY_DIR}/tc_fixed.metallib"
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/embed_metal.py"
        "${CMAKE_CURRENT_BINARY_DIR}/tc_fixed.metallib" "${TC_METAL_HEADER}"
    DEPENDS runtime/tc_fixed.metal embed_metal.py
    BYPRODUCTS "${CMAKE_CURRENT_BINARY_DIR}/tc_fixed.metallib"
    VERBATIM)
target_sources(tc_sse PRIVATE "${TC_METAL_HEADER}")
target_include_directories(tc_sse PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
set_source_files_properties(runtime/tc_d3d8.m runtime/tc_modern.m runtime/tc_files.m runtime/tc_registry.m runtime/tc_dsound.m PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(tc_sse PUBLIC "-framework ImageIO" "-framework CoreGraphics" "-framework Metal" "-framework MetalFX" "-framework QuartzCore" "-framework AppKit" "-framework Foundation" "-framework CoreFoundation" "-framework AVFoundation")
target_include_directories(tc_sse PUBLIC runtime "${CMAKE_CURRENT_SOURCE_DIR}/vendor/SR/SR/llasm-support")
target_compile_definitions(tc_sse PUBLIC PTROFS_64BIT)

# Compile only the SoftFloat operations used by translated helpers.
set(SOFTFLOAT "${CMAKE_CURRENT_SOURCE_DIR}/vendor/berkeley-softfloat-3/source")
set(SOFTFLOAT_NAMES f32_add f32_sub f32_mul f32_div f32_sqrt i32_to_f32 f32_to_i32
    s_roundToI32 s_shiftRightJam64
    s_addMagsF32 s_subMagsF32 s_normSubnormalF32Sig s_normRoundPackToF32
    s_roundPackToF32 s_shiftRightJam32 s_shortShiftRightJam64
    s_approxRecipSqrt32_1 s_approxRecipSqrt_1Ks softfloat_state)
list(APPEND SOFTFLOAT_NAMES f64_add f64_sub s_addMagsF64 s_subMagsF64
    s_normRoundPackToF64 s_roundPackToF64 extF80_to_f64 f64_roundToInt)
foreach(name IN LISTS SOFTFLOAT_NAMES)
    target_sources(tc_sse PRIVATE "${SOFTFLOAT}/${name}.c")
endforeach()
target_sources(tc_sse PRIVATE
    "${SOFTFLOAT}/8086-SSE/s_propagateNaNF32UI.c"
    "${SOFTFLOAT}/8086-SSE/s_propagateNaNF64UI.c"
    "${SOFTFLOAT}/8086-SSE/s_extF80UIToCommonNaN.c"
    "${SOFTFLOAT}/8086-SSE/s_commonNaNToF64UI.c"
    "${SOFTFLOAT}/8086-SSE/softfloat_raiseFlags.c")
target_include_directories(tc_sse PRIVATE "${SOFTFLOAT}/include" "${SOFTFLOAT}/8086-SSE")
target_compile_features(tc_sse PRIVATE c_std_11)
target_compile_definitions(tc_sse PRIVATE THREAD_LOCAL=_Thread_local
    SOFTFLOAT_FAST_INT64 SOFTFLOAT_FAST_DIV64TO32)

# Reuse upstream implementations required by the expanded translation.
# Windows FS/interrupt callbacks remain unresolved until platform integration.
set(LLASM_SUPPORT "${CMAKE_CURRENT_SOURCE_DIR}/vendor/SR/SR/llasm-support")
add_library(tc_legacy STATIC
    "${LLASM_SUPPORT}/llasm_float.c"
    "${LLASM_SUPPORT}/llasm_divide.c"
    "${LLASM_SUPPORT}/llasm_movs.c"
    "${LLASM_SUPPORT}/llasm_stos.c"
    "${LLASM_SUPPORT}/llasm_cmps.c"
    "${LLASM_SUPPORT}/llasm_scas.c"
    "${LLASM_SUPPORT}/llasm_fs_mem.c"
    "${LLASM_SUPPORT}/llasm_int.c"
    "${LLASM_SUPPORT}/llasm_pushx.c")
target_compile_definitions(tc_legacy PUBLIC PTROFS_64BIT PRIVATE TC_GUEST_X87_RESULTS)
target_compile_features(tc_legacy PRIVATE c_std_11)

option(TC_BUILD_SELF_CHECK "Build the optional SSE helper check without running it" OFF)
add_library(tc_image STATIC runtime/tc_image.c)
target_link_libraries(tc_image PUBLIC tc_sse)
add_library(tc_settings STATIC runtime/tc_settings.c)
target_link_libraries(tc_settings PUBLIC tc_image)
add_library(tc_input STATIC runtime/tc_input.c)
target_link_libraries(tc_input PUBLIC tc_settings)
find_package(SDL3 CONFIG REQUIRED)
add_library(tc_controller STATIC runtime/tc_controller.m)
target_link_libraries(tc_controller PUBLIC tc_input SDL3::SDL3)
add_library(tc_preferences STATIC runtime/tc_preferences.m)
target_compile_options(tc_preferences PRIVATE -fobjc-arc)
target_link_libraries(tc_preferences PUBLIC tc_input "-framework Foundation")
add_library(tc_host STATIC runtime/tc_host.m)
target_compile_options(tc_host PRIVATE -fobjc-arc)
target_link_libraries(tc_host PUBLIC tc_preferences tc_controller "-framework AppKit")
set(TC_TRANSLATED_OBJECT "${CMAKE_CURRENT_SOURCE_DIR}/generated/image-recovered/truecrime.o")
if(EXISTS "${TC_TRANSLATED_OBJECT}")
    add_executable(tc_game MACOSX_BUNDLE EXCLUDE_FROM_ALL runtime/tc_app.m "${TC_TRANSLATED_OBJECT}")
    set_source_files_properties("${TC_TRANSLATED_OBJECT}" PROPERTIES EXTERNAL_OBJECT TRUE)
    target_compile_options(tc_game PRIVATE -fobjc-arc)
    target_compile_definitions(tc_game PRIVATE "TC_GAME_DIRECTORY=\"${CMAKE_CURRENT_SOURCE_DIR}/..\"")
    target_link_libraries(tc_game PRIVATE tc_host tc_legacy)
    set_target_properties(tc_game PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/runtime/Info.plist.in")
    add_custom_command(TARGET tc_game POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_BUNDLE_DIR:tc_game>/Contents/Resources"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${CMAKE_CURRENT_SOURCE_DIR}/generated/image-recovered/provenance.json"
            "$<TARGET_BUNDLE_DIR:tc_game>/Contents/Resources/static-recompilation.json"
        VERBATIM)
endif()
# Release app: runtime only, no game code. On first launch its bundled converter
# translates the player's own TrueCrime.exe into a bundle loaded at run time,
# so every runtime symbol stays linked and exported for that bundle.
add_executable(tc_player MACOSX_BUNDLE EXCLUDE_FROM_ALL runtime/tc_app.m)
target_compile_options(tc_player PRIVATE -fobjc-arc)
target_compile_definitions(tc_player PRIVATE TC_DYNAMIC_GAME_CODE "TC_GAME_DIRECTORY=\"\"")
target_link_libraries(tc_player PRIVATE tc_host tc_legacy)
target_link_options(tc_player PRIVATE -Wl,-all_load)
set_target_properties(tc_player PROPERTIES OUTPUT_NAME tc_game
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/player"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/runtime/Info.plist.in")
if(TC_BUILD_SELF_CHECK)
    add_executable(bink-self-check EXCLUDE_FROM_ALL runtime/tc_bink.c)
    target_link_libraries(bink-self-check PRIVATE tc_host tc_legacy)
    target_compile_definitions(bink-self-check PRIVATE TC_BINK_SELF_CHECK)
    target_compile_options(bink-self-check PRIVATE -UNDEBUG)
    add_executable(video-self-check EXCLUDE_FROM_ALL runtime/tc_video.c)
    target_link_libraries(video-self-check PRIVATE PkgConfig::TC_FFMPEG)
    target_compile_definitions(video-self-check PRIVATE TC_VIDEO_SELF_CHECK)
    target_compile_options(video-self-check PRIVATE -UNDEBUG)
    add_executable(audio-self-check EXCLUDE_FROM_ALL runtime/tc_dsound.m)
    target_link_libraries(audio-self-check PRIVATE tc_sse)
    target_compile_definitions(audio-self-check PRIVATE TC_DS_SELF_CHECK)
    target_compile_options(audio-self-check PRIVATE -UNDEBUG)
    add_executable(sse-self-check runtime/tc_sse.c)
    target_link_libraries(sse-self-check PRIVATE tc_sse)
    target_include_directories(sse-self-check PRIVATE "${SOFTFLOAT}/include")
    target_compile_definitions(sse-self-check PRIVATE TC_SSE_SELF_CHECK THREAD_LOCAL=_Thread_local)
    target_compile_features(sse-self-check PRIVATE c_std_11)
    target_compile_options(sse-self-check PRIVATE -UNDEBUG)
endif()
