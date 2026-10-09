// SPDX-License-Identifier: AGPL-3.0-only
// Compiled into the isolated upstream component, never the app executable.
// The frontend serial owner polls this flag before permitting native unload.
namespace Libretro { extern bool g_pendingBoot; }
extern "C" __attribute__((visibility("default"))) bool ir_ppsspp_boot_pending(void) {
    return Libretro::g_pendingBoot;
}
