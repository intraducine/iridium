# Iridium integration only; no upstream source files are modified.
function(iridium_add_frontend_adapter)
  target_sources(ppsspp_libretro PRIVATE "${IRIDIUM_PSP_ADAPTER}")
  target_link_options(ppsspp_libretro PRIVATE
    "-Wl,-exported_symbols_list,${IRIDIUM_PSP_EXPORTS}")
endfunction()
cmake_language(DEFER CALL iridium_add_frontend_adapter)
