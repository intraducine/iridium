#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IridiumFEXIOSReadiness {
  int translator_present;
  int jit_required;
  int jit_ready;
  int launch_ready;
  int tool_bootstrap_required;
  int exception_ports_active;
  const char* translator_status;
  const char* jit_status;
  const char* launch_status;
  const char* status_summary;
  const char* allocator_backend;
  const char* jit_session_kind;
  const char* jit_failure_stage;
  const char* jit_tool_recommendation;
  const char* tool_bootstrap_kind;
  const char* tool_bootstrap_summary;
} IridiumFEXIOSReadiness;

typedef struct IridiumFEXIOSAllocatorProbe {
  int allocation_succeeded;
  int write_succeeded;
  int execution_succeeded;
  const char* status;
  const char* backend;
  const char* failure_stage;
  const char* error_domain;
  int error_code;
  const char* status_summary;
} IridiumFEXIOSAllocatorProbe;

typedef struct IridiumFEXIOSExecutionHandle {
  const char* session_identifier;
} IridiumFEXIOSExecutionHandle;

typedef struct IridiumFEXIOSExecutionPoll {
  const char* state;
  const char* status_summary;
  int wine_server_ready;
  int windows_process_started;
  int first_frame_presented;
} IridiumFEXIOSExecutionPoll;

typedef struct IridiumFEXIOSExecutionResult {
  int succeeded;
  const char* terminal_state;
  const char* failure_code;
  const char* failure_reason;
} IridiumFEXIOSExecutionResult;

typedef struct IridiumFEXIOSLaunchPaths {
  const char* translator_binary_path;
  const char* executable_path;
  const char* runtime_bundle_root_path;
  const char* prefix_root_path;
  const char* environment_file_path;
  const char* launch_mode;
  const char* windows_guest_architecture;
  const char* const* launch_arguments;
  size_t launch_argument_count;
} IridiumFEXIOSLaunchPaths;

/**
 * Starts the native Wine server inside the containing app process. Returning
 * zero means the server socket is ready for guest clients. A positive errno
 * value reports a startup failure.
 */
typedef int (*IridiumFEXIOSEmbeddedWineServerStart)(
  int debug_enabled,
  char* error_buffer,
  size_t error_buffer_size
);

typedef enum IridiumFEXIOSStatusCode {
  IRIDIUM_FEX_IOS_STATUS_OK = 0,
  IRIDIUM_FEX_IOS_STATUS_INVALID_ARGUMENT = 1,
  IRIDIUM_FEX_IOS_STATUS_TRANSLATOR_MISSING = 2,
  IRIDIUM_FEX_IOS_STATUS_EXECUTABLE_MISSING = 3,
  IRIDIUM_FEX_IOS_STATUS_ENVIRONMENT_FILE_MISSING = 4,
  IRIDIUM_FEX_IOS_STATUS_PREFIX_ROOT_MISSING = 5,
  IRIDIUM_FEX_IOS_STATUS_RUNTIME_BUNDLE_ROOT_MISSING = 6,
  IRIDIUM_FEX_IOS_STATUS_PREFIX_ROOT_NOT_WRITABLE = 7,
  IRIDIUM_FEX_IOS_STATUS_WINEPREFIX_MISMATCH = 8,
  IRIDIUM_FEX_IOS_STATUS_NO_DESKTOP_MISSING = 9,
  IRIDIUM_FEX_IOS_STATUS_WINEARCH_INVALID = 10,
  IRIDIUM_FEX_IOS_STATUS_JIT_NOT_READY = 11,
  IRIDIUM_FEX_IOS_STATUS_RUNTIME_CONTRACT_INVALID = 12,
  IRIDIUM_FEX_IOS_STATUS_DIRECT_LAUNCH_REQUIRED = 13,
  IRIDIUM_FEX_IOS_STATUS_GUEST_ARCHITECTURE_UNSUPPORTED = 14,
  IRIDIUM_FEX_IOS_STATUS_SYSCALL_BRIDGE_UNAVAILABLE = 15,
} IridiumFEXIOSStatusCode;

int iridium_fex_ios_probe_readiness(
  const char* translator_binary_path,
  const char* jit_status,
  IridiumFEXIOSReadiness* out_readiness
);

int iridium_fex_ios_probe_allocator(
  const char* jit_status,
  IridiumFEXIOSAllocatorProbe* out_probe
);

int iridium_fex_ios_validate_launch(
  const IridiumFEXIOSLaunchPaths* launch_paths,
  char* error_buffer,
  size_t error_buffer_size
);

int iridium_fex_ios_start_guest_execution(
  const IridiumFEXIOSLaunchPaths* launch_paths,
  const char* jit_status,
  char* session_identifier_buffer,
  size_t session_identifier_buffer_size,
  char* error_buffer,
  size_t error_buffer_size
);

int iridium_fex_ios_poll_guest_state(
  const char* session_identifier,
  IridiumFEXIOSExecutionPoll* out_poll
);

int iridium_fex_ios_collect_guest_exit(
  const char* session_identifier,
  const char* terminal_status_override,
  IridiumFEXIOSExecutionResult* out_result
);

int iridium_fex_ios_request_guest_stop(
  const char* session_identifier,
  char* error_buffer,
  size_t error_buffer_size
);

void iridium_fex_ios_register_embedded_wine_server_start(
  IridiumFEXIOSEmbeddedWineServerStart callback
);

/**
 * Records a native Wine-server interrupt for a translated guest thread.
 * Returns zero when the guest thread is registered, or a positive errno.
 */
int iridium_fex_ios_signal_guest_thread(uint64_t guest_thread_identifier, int signal_number);

#ifdef __cplusplus
}
#endif
