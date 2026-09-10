add_library(arm64ecfex SHARED
  Module.cpp
  Module.S
  IosJitAlias.cpp
  libarm64ecfex.def
  $<TARGET_OBJECTS:FEXCore_object>)

patch_library_wine(arm64ecfex)

target_include_directories(arm64ecfex PRIVATE
  "${CMAKE_SOURCE_DIR}/Source/Windows/include/"
  "${CMAKE_SOURCE_DIR}/Source/"
  "${CMAKE_SOURCE_DIR}/Source/Windows/")

target_link_libraries(arm64ecfex PRIVATE
  FEXCore_Base
  Common
  CommonTools
  CommonWindows
  CommonWindowsRuntime
  ntdll_ex)

# Upstream FEX uses `-static -nostdlib -nostartfiles -nodefaultlibs` to avoid
# pulling in mingw's CRT, then re-adds libc++/libc++abi/libunwind manually.
# This works on Linux-host arm64ec builds but FAILS on macOS-host llvm-mingw
# 22.1.4: ld.lld can't reconcile EC-mangled defs in libc++abi.a against
# non-EC-mangled refs from C++ frontend code, and segfaults on the link.
#
# For our iOS-host build, fall through to the default mingw link rules —
# they include the right startup files, CRT, and produce a clean arm64ec PE.
# The resulting DLL is slightly larger but links cleanly.
if (FEX_IOS_HOST_BUILD)
  target_link_options(arm64ecfex PRIVATE -static)
else()
  target_link_options(arm64ecfex PRIVATE -static -nostdlib -nostartfiles -nodefaultlibs -lc++ -lc++abi -lunwind)
  target_link_libraries(arm64ecfex PRIVATE ${LIBGCC_PATH})
endif()
install(TARGETS arm64ecfex RUNTIME
  DESTINATION ${CMAKE_INSTALL_LIBDIR}
  COMPONENT Runtime)
