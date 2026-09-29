# MADEIRA: IosMonoBridge.cpp is guarded entirely by #ifdef FEX_IOS_HOST, so it compiles to an empty
# object for every non-iOS build. Same integration pattern as ARM64EC/IosJitAlias.cpp.
add_library(wow64fex SHARED
  Module.cpp
  IosMonoBridge.cpp
  libwow64fex.def
  $<TARGET_OBJECTS:FEXCore_object>)

patch_library_wine(wow64fex)

target_include_directories(wow64fex PRIVATE
  "${CMAKE_SOURCE_DIR}/Source/Windows/include/"
  "${CMAKE_SOURCE_DIR}/Source/Windows/"
  "${CMAKE_SOURCE_DIR}/Source/")

target_link_libraries(wow64fex PRIVATE
  FEXCore_Base
  Common
  CommonTools
  CommonWindows
  CommonWindowsRuntime
  wow64_ex
  ntdll_ex)

# MADEIRA: mirrors the ARM64EC branch. Upstream's `-nostdlib -nostartfiles -nodefaultlibs` plus a
# manual libc++/libc++abi/libunwind is what keeps the PE free of a MinGW runtime dependency, but the
# iOS-host build needs mingw's default link rules instead:
#  - CRT_iOS.cpp (selected by the same flag in Common/CRT/CMakeLists.txt) drops _tls_index and
#    DllMainCRTStartup and relies on mingw's startup files to run global constructors and TLS setup;
#  - the iOS-host diagnostics in FEXCore reference a handful of CRT entry points (time(), snprintf)
#    that -nodefaultlibs does not provide.
# The result is a slightly larger PE with the correct startup, which is the trade the ARM64EC module
# already makes. Unlike ARM64EC, this is NOT working around an EC-mangling linker crash, so the
# upstream link line is kept verbatim for every non-iOS build.
if (FEX_IOS_HOST_BUILD)
  target_link_options(wow64fex PRIVATE -static)
else()
  target_link_options(wow64fex PRIVATE -static -nostdlib -nostartfiles -nodefaultlibs -lc++ -lc++abi -lunwind)
  target_link_libraries(wow64fex PRIVATE ${LIBGCC_PATH})
endif()
install(TARGETS wow64fex RUNTIME
  DESTINATION ${CMAKE_INSTALL_LIBDIR}
  COMPONENT Runtime)
