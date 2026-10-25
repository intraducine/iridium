"""Exercise the host's actual core-option registration with the upstream ABI."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INCLUDE = ROOT / 'vendor/Flycast/core/deps/libretro-common/include'


@unittest.skipUnless(shutil.which('clang++') and (INCLUDE / 'libretro.h').is_file(),
                     'C++ compiler and pinned libretro header required')
class RetroOptionsTests(unittest.TestCase):
    def test_flycast_controller_startup_reaches_upstream_expansion_refresh(self):
        host = (ROOT / 'iridium/apps/ios/RuntimeBridge/IRRetroPlayer.mm').read_text()
        setup = host[host.index('    api.controller(0,'):host.index('    double rate = info.timing.')]
        core = (ROOT / 'vendor/Flycast/shell/libretro/libretro.cpp').read_text()
        start = core.index('void retro_set_controller_port_device(')
        controller = core[start:core.index('\nstatic void refresh_devices(', start)]
        devices = '\n'.join(line for line in core.splitlines() if line.startswith('#define RETRO_DEVICE_'))
        kinds = ','.join(sorted(set(re.findall(r'MDT_\w+', controller))))
        fixture = r'''#include "libretro.h"
#include <cassert>
#include <string>
DEVICES
enum { KINDS };
namespace config { int MapleMainDevices[4]; }
static int device_type[4] = {-1,-1,-1,-1};
static bool first_run = true, devices_need_refresh;
static constexpr int MAPLE_PORTS = 4;
static int refreshes;
struct Platform { bool isConsole() { return true; } };
static struct { Platform platform; } settings;
static void set_input_descriptors() {}
static void update_variables(bool) { ++refreshes; }
CONTROLLER
static void start(const std::string &engine) {
    struct { void (*controller)(unsigned, unsigned); } api{retro_set_controller_port_device};
SETUP
}
int main() {
    start("flycast");
    assert(refreshes == 1 && devices_need_refresh);
    assert(device_type[0] == RETRO_DEVICE_JOYPAD && config::MapleMainDevices[0] == MDT_SegaController);
    for (unsigned port = 1; port < 4; ++port)
        assert(device_type[port] == RETRO_DEVICE_NONE && config::MapleMainDevices[port] == MDT_None);
    for (int &type : device_type) type = -1;
    refreshes = 0;
    start("azahar");
    assert(device_type[0] == RETRO_DEVICE_JOYPAD && refreshes == 0);
    for (unsigned port = 1; port < 4; ++port) assert(device_type[port] == -1);
}
'''.replace('\nDEVICES\n', '\n' + devices + '\n').replace('KINDS', kinds).replace('\nCONTROLLER\n', '\n' + controller + '\n').replace('SETUP', setup)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); unit = folder / 'check.cpp'; unit.write_text(fixture)
            binary = folder / 'check'
            subprocess.run(['clang++', '-std=c++17', '-I', str(INCLUDE), str(unit), '-o', str(binary)],
                           check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=10)

    def test_international_options_use_english_defaults_and_keep_overrides(self):
        source = (ROOT / 'iridium/apps/ios/RuntimeBridge/IRRetroPlayer.mm').read_text()
        cases = source[source.index('    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:'):
                       source.index('    case RETRO_ENVIRONMENT_SET_VARIABLES:')]
        fixture = r'''#include "libretro.h"
#include <cassert>
#include <map>
#include <string>
struct Player { std::map<std::string, std::string> options; } player;
static bool environment(unsigned command, void *data) {
    auto p = &player;
    switch (command) {
CASES
    default: return false;
    }
}
int main() {
    unsigned version = 0;
    assert(environment(RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION, &version) && version == 2);
    retro_core_option_v2_definition definitions[3]{};
    definitions[0].key = "vmu"; definitions[0].default_value = "enabled";
    definitions[0].values[0].value = "disabled";
    definitions[1].key = "fallback"; definitions[1].values[0].value = "first";
    retro_core_option_v2_definition localized[2]{};
    localized[0].key = "vmu"; localized[0].default_value = "localized";
    retro_core_options_v2 english{nullptr, definitions}, local{nullptr, localized};
    retro_core_options_v2_intl v2{&english, &local};
    assert(environment(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL, &v2));
    assert(player.options.at("vmu") == "enabled" && player.options.at("fallback") == "first");
    player.options["vmu"] = "user";
    assert(environment(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL, &v2));
    assert(player.options.at("vmu") == "user");
    v2.us = nullptr;
    assert(!environment(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL, &v2));
    assert(!environment(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL, nullptr));
    player.options.clear();
    retro_core_option_definition legacy[3]{};
    legacy[0].key = "vmu"; legacy[0].default_value = "enabled";
    legacy[0].values[0].value = "disabled";
    legacy[1].key = "fallback"; legacy[1].values[0].value = "first";
    retro_core_options_intl v1{legacy, nullptr};
    assert(environment(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL, &v1));
    assert(player.options.at("vmu") == "enabled" && player.options.at("fallback") == "first");
    player.options["vmu"] = "user";
    assert(environment(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL, &v1));
    assert(player.options.at("vmu") == "user");
    v1.us = nullptr;
    assert(!environment(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL, &v1));
    assert(!environment(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL, nullptr));
}
'''.replace('CASES', cases)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); unit = folder / 'check.cpp'; unit.write_text(fixture)
            binary = folder / 'check'
            subprocess.run(['clang++', '-std=c++17', '-I', str(INCLUDE), str(unit), '-o', str(binary)],
                           check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=10)
