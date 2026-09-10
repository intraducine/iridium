#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IridiumWineIOSPrefixLayout {
  const char* prefix_root_path;
} IridiumWineIOSPrefixLayout;

typedef struct IridiumWineIOSPlayableSessionConfiguration {
  const char* prefix_root_path;
  const char* session_identifier;
  const char* surface_identifier;
  const char* framebuffer_path;
  const char* input_events_path;
  const char* audio_state_path;
  unsigned int surface_width;
  unsigned int surface_height;
} IridiumWineIOSPlayableSessionConfiguration;

int iridium_wine_ios_prepare_prefix_layout(
  const IridiumWineIOSPrefixLayout* layout,
  char* error_buffer,
  size_t error_buffer_size
);

int iridium_wine_ios_validate_userland_root(
  const char* userland_root_path,
  char* error_buffer,
  size_t error_buffer_size
);

int iridium_wine_ios_is_blocked_entrypoint(const char* executable_path);

int iridium_wine_ios_bootstrap_direct_launch(
  const char* executable_path,
  const char* prefix_root_path,
  const char* userland_root_path,
  char* resolved_wine_binary_buffer,
  size_t resolved_wine_binary_buffer_size,
  char* error_buffer,
  size_t error_buffer_size
);

int iridium_wine_ios_configure_playable_session(
  const IridiumWineIOSPlayableSessionConfiguration* configuration,
  char* bridge_config_path_buffer,
  size_t bridge_config_path_buffer_size,
  char* error_buffer,
  size_t error_buffer_size
);

#ifdef __cplusplus
}
#endif
