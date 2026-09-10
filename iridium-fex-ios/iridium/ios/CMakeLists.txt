cmake_minimum_required(VERSION 3.14)

add_library(iridium-fex-ios-embedded STATIC
  src/iridium_fex_ios_allocator_probe.cpp
  src/iridium_fex_ios_bridge.cpp
  src/iridium_fex_ios_guest_loader.cpp
  src/iridium_fex_ios_jit_runtime_internal.cpp
  src/iridium_fex_ios_syscall_bridge.cpp
)

target_include_directories(iridium-fex-ios-embedded
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
  PRIVATE
    ${PROJECT_SOURCE_DIR}/Source
    ${PROJECT_SOURCE_DIR}/Source/Tools
    ${PROJECT_SOURCE_DIR}/Source/Tools/FEXInterpreter
    ${PROJECT_SOURCE_DIR}/Source/Tools/CommonTools
    ${PROJECT_SOURCE_DIR}/Source/Tools/LinuxEmulation
    ${PROJECT_SOURCE_DIR}/FEXCore/include
    ${CMAKE_BINARY_DIR}/include
    ${CMAKE_BINARY_DIR}/generated
)

target_compile_definitions(iridium-fex-ios-embedded
  PUBLIC
    IRIDIUM_FEX_IOS_EMBEDDED=1
    IRIDIUM_FEX_IOS_ENABLE_FEXCORE=1
)

target_link_libraries(iridium-fex-ios-embedded
  PRIVATE
    FEXCore
    Common
    CommonTools
    JemallocLibs
    fmt::fmt
)

if (TARGET LinuxEmulation)
  target_compile_definitions(iridium-fex-ios-embedded
    PUBLIC
      IRIDIUM_FEX_IOS_ENABLE_LINUX_EMULATION=1
  )
  target_link_libraries(iridium-fex-ios-embedded
    PRIVATE
      LinuxEmulation
  )
endif()

set_target_properties(iridium-fex-ios-embedded PROPERTIES
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/artifacts"
  OUTPUT_NAME "iridium-fex-ios-embedded"
)

file(GENERATE
  OUTPUT "${CMAKE_BINARY_DIR}/iridium-ios-embedded-artifact.txt"
  CONTENT "MODE=embedded\nPLATFORM=${IRIDIUM_IOS_EMBEDDED_PLATFORM}\nTARGET=iridium-fex-ios-embedded\nARTIFACT=$<TARGET_LINKER_FILE:iridium-fex-ios-embedded>\n"
)

if (IRIDIUM_IOS_EMBEDDED_TESTING)
  enable_testing()

  if (IRIDIUM_IOS_EMBEDDED_PLATFORM STREQUAL "host")
    add_executable(iridium-fex-ios-embedded-tests
      tests/iridium_fex_ios_bridge_tests.cpp
    )

    add_executable(iridium-fex-ios-allocator-probe
      tests/iridium_fex_ios_allocator_probe_main.cpp
    )

    set_target_properties(
      iridium-fex-ios-embedded-tests
      iridium-fex-ios-allocator-probe
      PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/Bin"
    )

    target_include_directories(iridium-fex-ios-embedded-tests
      PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${PROJECT_SOURCE_DIR}/FEXCore/include
    )

    target_include_directories(iridium-fex-ios-allocator-probe
      PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
    )

    target_link_libraries(iridium-fex-ios-embedded-tests
      PRIVATE
        iridium-fex-ios-embedded
        FEXCore
        fmt::fmt
    )

    target_link_libraries(iridium-fex-ios-allocator-probe
      PRIVATE
        iridium-fex-ios-embedded
    )

    add_test(
      NAME iridium-fex-ios-host-test-build
      COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target iridium-fex-ios-embedded-tests iridium-fex-ios-allocator-probe
    )
    set_tests_properties(iridium-fex-ios-host-test-build PROPERTIES
      FIXTURES_SETUP iridium-fex-ios-host-built-tests
    )

    add_test(
      NAME iridium-fex-ios-embedded-tests
      COMMAND $<TARGET_FILE:iridium-fex-ios-embedded-tests>
    )
    set_tests_properties(iridium-fex-ios-embedded-tests PROPERTIES
      FIXTURES_REQUIRED iridium-fex-ios-host-built-tests
    )

    add_test(
      NAME iridium-fex-ios-allocator-probe
      COMMAND $<TARGET_FILE:iridium-fex-ios-allocator-probe> ready
    )
    set_tests_properties(iridium-fex-ios-allocator-probe PROPERTIES
      FIXTURES_REQUIRED iridium-fex-ios-host-built-tests
    )
  endif()

  add_test(
    NAME iridium-fex-ios-build-script-smoke
    COMMAND /bin/sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/build_embedded_translator_smoke.sh" "${CMAKE_BINARY_DIR}" "${IRIDIUM_IOS_EMBEDDED_PLATFORM}"
  )
endif()
