#pragma once

namespace iridium {
namespace runtime {

constexpr const char* kDefaultHostVersion = IRIDIUM_RUNTIME_HOST_VERSION;
constexpr const char* kCapabilityRecordFileName = "host-capabilities.json";
constexpr const char* kRuntimeHostContractVersion = "1";
constexpr const char* kNoDesktopEnvironmentKey = "IRIDIUM_NO_DESKTOP";
constexpr const char* kUserlandRootEnvironmentKey = "IRIDIUM_USERLAND_ROOT";
constexpr const char* kWineServerRootEnvironmentKey = "IRIDIUM_WINE_SERVER_ROOT";
constexpr const char* kWineDataDirectoryEnvironmentKey = "WINEDATADIR";
constexpr const char* kWineHostServerEnvironmentKey = "IRIDIUM_WINE_HOST_WINESERVER";
constexpr const char* kHostTelemetryAverageFPSEnvironmentKey = "IRIDIUM_HOST_TELEMETRY_AVERAGE_FPS";
constexpr const char* kHostTelemetryFrameTimeP95MSEnvironmentKey = "IRIDIUM_HOST_TELEMETRY_FRAME_TIME_P95_MS";
constexpr const char* kHostTelemetryMemoryPressureRatioEnvironmentKey = "IRIDIUM_HOST_TELEMETRY_MEMORY_PRESSURE_RATIO";
constexpr const char* kHostTelemetryThermalStateEnvironmentKey = "IRIDIUM_HOST_TELEMETRY_THERMAL_STATE";

}  // namespace runtime
}  // namespace iridium
