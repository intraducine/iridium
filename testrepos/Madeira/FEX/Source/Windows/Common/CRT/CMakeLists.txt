if (FEX_IOS_HOST_BUILD)
  # Minimal stub for iOS-host build — only the FEX::Windows::* lifecycle
  # hooks that Module.cpp calls; skips _tls_index, DllMainCRTStartup,
  # CRT$XIA/XCA/etc. section markers, and rpmalloc init that conflict with
  # mingw's default startup.
  target_sources(CommonWindowsRuntime PRIVATE CRT_iOS.cpp)
else()
  target_sources(CommonWindowsRuntime PRIVATE Alloc.cpp IO.cpp Math.cpp String.cpp Misc.cpp CRT.cpp)
  add_subdirectory(Musl)
endif()
