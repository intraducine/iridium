cmake_minimum_required(VERSION 3.22)

set(IRIDIUM_FEX_FORK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../iridium-fex-ios" CACHE PATH "Sibling iridium-fex-ios workspace")
set(IRIDIUM_FEX_EMBEDDED_PLATFORM "host" CACHE STRING "Apple platform for the embedded FEX bridge artifact")
set_property(CACHE IRIDIUM_FEX_EMBEDDED_PLATFORM PROPERTY STRINGS host device simulator)

if(IRIDIUM_FEX_EMBEDDED_PLATFORM STREQUAL "device")
  set(CMAKE_OSX_SYSROOT "iphoneos")
  set(CMAKE_OSX_ARCHITECTURES "arm64")
  set(CMAKE_OSX_DEPLOYMENT_TARGET "18.0")
elseif(IRIDIUM_FEX_EMBEDDED_PLATFORM STREQUAL "simulator")
  set(CMAKE_OSX_SYSROOT "iphonesimulator")
  set(CMAKE_OSX_ARCHITECTURES "arm64")
  set(CMAKE_OSX_DEPLOYMENT_TARGET "18.0")
else()
  set(CMAKE_OSX_SYSROOT "macosx")
  set(CMAKE_OSX_ARCHITECTURES "arm64")
  set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0")
endif()

project(iridium_runtime_sdk LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(IRIDIUM_FEX_EMBEDDED_BUILD_ROOT "${CMAKE_BINARY_DIR}/fex-ios-embedded-host" CACHE PATH "Build root for the embedded FEX bridge artifact")
set(IRIDIUM_FEX_EMBEDDED_LIBRARY "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/artifacts/libiridium-fex-ios-embedded.a")
set(IRIDIUM_FEX_EMBEDDED_SUPPORT_LIBRARIES
  "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/Source/Tools/CommonTools/libCommonTools.a"
  "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/Source/Common/libCommon.a"
  "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/Source/Common/cpp-optparse/libcpp-optparse.a"
  "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/FEXCore/Source/libFEXCore.a"
  "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/FEXCore/Source/libFEXCore_Base.a"
  "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/FEXCore/Source/libJemallocLibs.a"
  "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/External/fmt/libfmt.a"
  "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/External/xxhash/cmake_unofficial/libxxhash.a"
  "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/External/rpmalloc/librpmalloc.a"
  "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/External/tiny-json/libtiny-json.a"
  "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/External/cephes/libcephes_128bit.a"
  "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}/External/SoftFloat-3e/libsoftfloat_3e.a"
)

add_custom_target(iridium-fex-ios-embedded-artifact
  COMMAND /bin/bash "${IRIDIUM_FEX_FORK_ROOT}/iridium/ios/build_embedded_translator.sh"
          --platform "${IRIDIUM_FEX_EMBEDDED_PLATFORM}"
          --build-root "${IRIDIUM_FEX_EMBEDDED_BUILD_ROOT}"
          --output "${IRIDIUM_FEX_EMBEDDED_LIBRARY}"
  BYPRODUCTS "${IRIDIUM_FEX_EMBEDDED_LIBRARY}"
  WORKING_DIRECTORY "${IRIDIUM_FEX_FORK_ROOT}"
  COMMENT "Refreshing canonical Iridium embedded FEX bridge"
  VERBATIM
)

add_library(iridium-fex-ios-embedded STATIC IMPORTED GLOBAL)
set_target_properties(iridium-fex-ios-embedded PROPERTIES
  IMPORTED_LOCATION "${IRIDIUM_FEX_EMBEDDED_LIBRARY}"
)
add_dependencies(iridium-fex-ios-embedded iridium-fex-ios-embedded-artifact)

add_library(iridium-runtime-host-core STATIC
  src/embedded_wine_bridge.cpp
  src/runtime_host_core.cpp
)

target_include_directories(iridium-runtime-host-core
  PRIVATE
    ${PROJECT_SOURCE_DIR}/include
)

target_compile_definitions(iridium-runtime-host-core
  PRIVATE
    IRIDIUM_RUNTIME_HOST_VERSION=\"0.1.0-dev\"
)

add_executable(runtime-host.bin
  src/runtime_host_main.cpp
)

target_include_directories(runtime-host.bin
  PRIVATE
    ${PROJECT_SOURCE_DIR}/include
)

target_link_libraries(runtime-host.bin
  PRIVATE
    iridium-runtime-host-core
)

target_link_libraries(iridium-runtime-host-core
  PRIVATE
    iridium-fex-ios-embedded
    ${IRIDIUM_FEX_EMBEDDED_SUPPORT_LIBRARIES}
)
