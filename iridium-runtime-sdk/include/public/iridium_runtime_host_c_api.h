#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IridiumRuntimeHostInvocationPaths {
  const char* launch_package_path;
  const char* session_update_path;
  const char* terminal_result_path;
  const char* telemetry_path;
  const char* host_log_path;
} IridiumRuntimeHostInvocationPaths;

typedef struct IridiumRuntimeHostCapabilityRefreshPaths {
  const char* runtime_bundle_root_path;
} IridiumRuntimeHostCapabilityRefreshPaths;

typedef enum IridiumRuntimeHostPlayableServiceKind {
  IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_RENDER = 0,
  IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_INPUT = 1,
  IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_AUDIO = 2,
} IridiumRuntimeHostPlayableServiceKind;

typedef enum IridiumRuntimeHostRegistrationStatus {
  IRIDIUM_RUNTIME_HOST_REGISTRATION_OK = 0,
  IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT = 64,
  IRIDIUM_RUNTIME_HOST_REGISTRATION_SESSION_CONFLICT = 65,
  IRIDIUM_RUNTIME_HOST_REGISTRATION_SESSION_MISMATCH = 66,
  IRIDIUM_RUNTIME_HOST_REGISTRATION_SERVICE_CONFLICT = 67,
} IridiumRuntimeHostRegistrationStatus;

typedef enum IridiumRuntimeHostLaunchMilestone {
  IRIDIUM_RUNTIME_HOST_MILESTONE_WINE_SERVER_READY = 0,
  IRIDIUM_RUNTIME_HOST_MILESTONE_WINDOWS_PROCESS_STARTED = 1,
  IRIDIUM_RUNTIME_HOST_MILESTONE_FIRST_FRAME_PRESENTED = 2,
} IridiumRuntimeHostLaunchMilestone;

typedef struct IridiumRuntimeHostPlayableSessionReservation {
  const char* session_identifier;
  const char* runtime_bundle_root_path;
  const char* host_log_path;
} IridiumRuntimeHostPlayableSessionReservation;

typedef struct IridiumRuntimeHostPlayableServiceRegistration {
  const char* session_identifier;
  IridiumRuntimeHostPlayableServiceKind service_kind;
  const char* service_handle;
  const char* service_metadata;
} IridiumRuntimeHostPlayableServiceRegistration;

typedef struct IridiumRuntimeHostPlayableServiceLiveness {
  const char* session_identifier;
  IridiumRuntimeHostPlayableServiceKind service_kind;
  int service_live;
} IridiumRuntimeHostPlayableServiceLiveness;

int iridium_runtime_host_run(const IridiumRuntimeHostInvocationPaths* invocation);
int iridium_runtime_host_refresh_capabilities(const IridiumRuntimeHostCapabilityRefreshPaths* invocation);
int iridium_runtime_host_acquire_playable_session(
  const IridiumRuntimeHostPlayableSessionReservation* reservation
);
int iridium_runtime_host_register_playable_service(
  const IridiumRuntimeHostPlayableServiceRegistration* registration
);
int iridium_runtime_host_set_playable_service_liveness(
  const IridiumRuntimeHostPlayableServiceLiveness* liveness
);
int iridium_runtime_host_unregister_playable_service(
  const IridiumRuntimeHostPlayableServiceRegistration* registration
);
int iridium_runtime_host_release_playable_session(const char* session_identifier);
int iridium_runtime_host_record_launch_milestone(
  const char* session_identifier,
  IridiumRuntimeHostLaunchMilestone milestone
);

#ifdef __cplusplus
}
#endif
