# SPDX-License-Identifier: MIT

# This applies some common linker options that reduce code size and linking time in Release mode. Namely:
# --gc-sections: Linktime garbage collection, discards unused sections from the final output
# --strip-all  : Similar to running `strip`, discards the symbol table from the final output
# --as-needed  : Only includes libraries that are actually needed in the final output.

macro(LinkerGC target)
  # These are GNU/ELF linker flags. Apple's ld rejects them; Xcode already
  # dead-strips the final application when the embedding project requests it.
  if (CMAKE_BUILD_TYPE MATCHES "RELEASE" AND NOT APPLE)
    target_link_options(${target} PRIVATE
      "LINKER:--gc-sections"
      "LINKER:--strip-all"
      "LINKER:--as-needed")
  endif()
endmacro()
