# SPDX-License-Identifier: AGPL-3.0-only
foreach(target dynarmic citra_core video_core citra_libretro)
  target_include_directories(${target} BEFORE PRIVATE "${IRIDIUM_PHASE3_GENERATED}/include" "${bridge}")
endforeach()
get_target_property(sources dynarmic SOURCES)
list(FILTER sources EXCLUDE REGEX "(^|/)(address_space[.]cpp|spin_lock_arm64[.]cpp|exception_handler_macos[.]cpp|exception_handler_macos_mig[.]c|exception_handler_generic[.]cpp)$")
set_property(TARGET dynarmic PROPERTY SOURCES "${sources}")
# The shared debugger owns exception handling. Dynarmic uses its checked-memory path.
target_sources(dynarmic PRIVATE "${IRIDIUM_PHASE3_GENERATED}/spin_lock_arm64.cpp" "${IRIDIUM_PHASE3_GENERATED}/address_space.cpp" "${CMAKE_SOURCE_DIR}/externals/dynarmic/src/dynarmic/backend/exception_handler_generic.cpp")
get_target_property(sources citra_core SOURCES)
list(REMOVE_ITEM sources arm/dynarmic/arm_dynarmic.cpp)
set_property(TARGET citra_core PROPERTY SOURCES "${sources}")
target_sources(citra_core PRIVATE "${IRIDIUM_PHASE3_GENERATED}/arm_dynarmic.cpp")
get_target_property(sources video_core SOURCES)
list(REMOVE_ITEM sources shader/shader_jit.cpp shader/shader_jit_a64_compiler.cpp)
list(FILTER sources EXCLUDE REGEX "renderer_vulkan/vk_(platform|present_window|swapchain)[.]cpp")
set_property(TARGET video_core PROPERTY SOURCES "${sources}")
get_target_property(definitions video_core COMPILE_DEFINITIONS)
list(REMOVE_ITEM definitions HAVE_LIBRETRO)
set_property(TARGET video_core PROPERTY COMPILE_DEFINITIONS "${definitions}")
# Use Azahar's main renderer and presentation queue with an iOS Metal surface.
target_sources(video_core PRIVATE "${IRIDIUM_PHASE3_GENERATED}/shader_jit.cpp" "${IRIDIUM_PHASE3_GENERATED}/shader_jit_a64_compiler.cpp"
  "${IRIDIUM_PHASE3_GENERATED}/vk_platform.cpp"
  "${CMAKE_SOURCE_DIR}/src/video_core/renderer_vulkan/vk_present_window.cpp"
  "${CMAKE_SOURCE_DIR}/src/video_core/renderer_vulkan/vk_swapchain.cpp")
get_target_property(sources citra_libretro_common SOURCES)
list(FILTER sources EXCLUDE REGEX "libretro_vk[.]cpp|libretro_window[.]cpp|mouse_tracker[.]cpp")
set_property(TARGET citra_libretro_common PROPERTY SOURCES "${sources}")
target_sources(citra_libretro_common PRIVATE "${IRIDIUM_PHASE3_GENERATED}/libretro_window.cpp" "${IRIDIUM_PHASE3_GENERATED}/mouse_tracker.cpp")
get_target_property(sources citra_libretro SOURCES)
list(REMOVE_ITEM sources citra_libretro.cpp)
set_property(TARGET citra_libretro PROPERTY SOURCES "${sources}")
target_sources(citra_libretro PRIVATE "${IRIDIUM_PHASE3_GENERATED}/citra_libretro.cpp"
  "${bridge}/IRAzaharCamera.cpp"
  "${bridge}/IRAzaharJIT.cpp" "${bridge}/IRAzaharGraphics.mm" "${bridge}/IRJITExecutionProbe.c")
target_include_directories(citra_libretro PRIVATE "${CMAKE_SOURCE_DIR}/externals/json")
set_source_files_properties("${bridge}/IRAzaharGraphics.mm" TARGET_DIRECTORY citra_libretro PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(citra_libretro PRIVATE "${IRIDIUM_AZAHAR_MOLTENVK}" "-framework Metal" "-framework QuartzCore" "-framework CoreGraphics" "-framework UIKit")
