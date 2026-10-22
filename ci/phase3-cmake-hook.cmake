# SPDX-License-Identifier: AGPL-3.0-only
# Defer until the upstream root has declared all targets. Nested dependency
# projects must not install a second hook.
if(CMAKE_CURRENT_SOURCE_DIR STREQUAL CMAKE_SOURCE_DIR)
  if(EXISTS "${IRIDIUM_PHASE3_GENERATED}/include/Common/CodeBlock.h")
    include_directories(BEFORE "${IRIDIUM_PHASE3_GENERATED}/include")
  endif()
  cmake_language(EVAL CODE "cmake_language(DEFER CALL include \"${IRIDIUM_PHASE3_TARGET_HOOK}\")")
endif()
