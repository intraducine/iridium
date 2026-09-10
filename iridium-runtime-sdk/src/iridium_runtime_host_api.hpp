#pragma once

#include "../include/public/iridium_runtime_host_c_api.h"

namespace iridium {
namespace runtime {

using HostInvocationPaths = IridiumRuntimeHostInvocationPaths;
using HostCapabilityRefreshPaths = IridiumRuntimeHostCapabilityRefreshPaths;
using HostPlayableSessionReservation = IridiumRuntimeHostPlayableSessionReservation;
using HostPlayableServiceRegistration = IridiumRuntimeHostPlayableServiceRegistration;
using HostPlayableServiceLiveness = IridiumRuntimeHostPlayableServiceLiveness;

int RunHostInvocation(const HostInvocationPaths& invocation);
int RefreshHostCapabilities(const HostCapabilityRefreshPaths& invocation);
int AcquirePlayableSession(const HostPlayableSessionReservation& reservation);
int RegisterPlayableService(const HostPlayableServiceRegistration& registration);
int SetPlayableServiceLiveness(const HostPlayableServiceLiveness& liveness);
int UnregisterPlayableService(const HostPlayableServiceRegistration& registration);
int ReleasePlayableSession(const char* session_identifier);
int RecordLaunchMilestone(const char* session_identifier, IridiumRuntimeHostLaunchMilestone milestone);

}  // namespace runtime
}  // namespace iridium
