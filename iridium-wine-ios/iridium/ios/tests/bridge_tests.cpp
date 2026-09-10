#include "../include/iridium_wine_ios_bridge.h"

#include "iosdrv.h"
#include "iridium_ios_audio.h"

#include <array>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#if __has_include(<filesystem>)
#include <filesystem>
namespace fs = std::filesystem;
#elif __has_include(<experimental/filesystem>)
#include <experimental/filesystem>
namespace fs = std::experimental::filesystem;
#endif

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
  }
}

fs::path make_temp_root() {
  const fs::path root = fs::temp_directory_path() / fs::path("iridium-wine-ios-tests");
  fs::remove_all(root);
  fs::create_directories(root);
  return root;
}

void write_file(const fs::path& path, const std::string& contents = "fixture") {
  fs::create_directories(path.parent_path());
  std::ofstream stream(path);
  stream << contents;
}

fs::path make_userland_fixture(const fs::path& root) {
  write_file(root / "bin/wine64");
  write_file(root / "bin/wineserver");
  write_file(root / "lib/wine/builtin.dll");
  write_file(root / "lib/wine/x86_64-windows/kernel32.dll");
  write_file(root / "lib/wine/x86_64-windows/kernelbase.dll");
  write_file(root / "share/wine/system.reg");
  write_file(root / "share/wine/nls/l_intl.nls");
  write_file(root / "prefix-seed/system.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(root / "prefix-seed/user.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(root / "prefix-seed/userdef.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  return root;
}

void test_prepare_prefix_layout() {
  const fs::path root = make_temp_root();
  const fs::path prefix = root / "prefix";
  char error[512] = {};

  const IridiumWineIOSPrefixLayout layout{prefix.c_str()};
  require(iridium_wine_ios_prepare_prefix_layout(&layout, error, sizeof(error)) == 0, error);
  require(fs::is_directory(prefix / "drive_c"), "drive_c directory missing");
  require(fs::is_directory(prefix / "drive_c/users/steamuser"), "steamuser directory missing");
  require(fs::is_symlink(prefix / "dosdevices/c:"), "c: symlink missing");
  require(fs::is_symlink(prefix / "dosdevices/z:"), "z: symlink missing");
}

void test_validate_userland_root_requires_prefix_seed() {
  const fs::path root = make_temp_root() / "userland";
  write_file(root / "bin/wine64");
  write_file(root / "bin/wineserver");
  write_file(root / "lib/wine/builtin.dll");
  write_file(root / "share/wine/system.reg");
  write_file(root / "share/wine/nls/l_intl.nls");

  char error[512] = {};
  require(
    iridium_wine_ios_validate_userland_root(root.c_str(), error, sizeof(error)) != 0,
    "userland without prefix seed should fail"
  );
}

void test_validate_userland_root_rejects_missing_wineserver() {
  const fs::path root = make_temp_root() / "userland";
  write_file(root / "bin/wine64");
  write_file(root / "lib/wine/builtin.dll");
  write_file(root / "share/wine/system.reg");
  write_file(root / "share/wine/nls/l_intl.nls");
  write_file(root / "prefix-seed/system.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(root / "prefix-seed/user.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(root / "prefix-seed/userdef.reg", "WINE REGISTRY Version 2\n#arch=win64\n");

  char error[512] = {};
  require(
    iridium_wine_ios_validate_userland_root(root.c_str(), error, sizeof(error)) != 0,
    "userland without wineserver should fail"
  );
}

void test_validate_userland_root_rejects_missing_wine_launcher() {
  const fs::path root = make_temp_root() / "userland";
  write_file(root / "bin/wineserver");
  write_file(root / "lib/wine/builtin.dll");
  write_file(root / "share/wine/system.reg");
  write_file(root / "share/wine/nls/l_intl.nls");
  write_file(root / "prefix-seed/system.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(root / "prefix-seed/user.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(root / "prefix-seed/userdef.reg", "WINE REGISTRY Version 2\n#arch=win64\n");

  char error[512] = {};
  require(
    iridium_wine_ios_validate_userland_root(root.c_str(), error, sizeof(error)) != 0,
    "userland without launcher should fail"
  );
}

void test_validate_userland_root_rejects_missing_libraries() {
  const fs::path root = make_temp_root() / "userland";
  write_file(root / "bin/wine64");
  write_file(root / "bin/wineserver");
  write_file(root / "share/wine/system.reg");
  write_file(root / "share/wine/nls/l_intl.nls");
  write_file(root / "prefix-seed/system.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(root / "prefix-seed/user.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(root / "prefix-seed/userdef.reg", "WINE REGISTRY Version 2\n#arch=win64\n");

  char error[512] = {};
  require(
    iridium_wine_ios_validate_userland_root(root.c_str(), error, sizeof(error)) != 0,
    "userland without libraries should fail"
  );
}

void test_validate_userland_root_rejects_invalid_seed_payload() {
  const fs::path root = make_temp_root() / "userland";
  write_file(root / "bin/wine64");
  write_file(root / "bin/wineserver");
  write_file(root / "lib/wine/builtin.dll");
  write_file(root / "share/wine/system.reg");
  write_file(root / "share/wine/nls/l_intl.nls");
  write_file(root / "prefix-seed/system.reg", "invalid");
  write_file(root / "prefix-seed/user.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(root / "prefix-seed/userdef.reg", "WINE REGISTRY Version 2\n#arch=win64\n");

  char error[512] = {};
  require(
    iridium_wine_ios_validate_userland_root(root.c_str(), error, sizeof(error)) != 0,
    "userland with invalid seed payload should fail"
  );
}

void test_validate_userland_root_rejects_missing_server_nls() {
  const fs::path root = make_userland_fixture(make_temp_root() / "userland");
  fs::remove(root / "share/wine/nls/l_intl.nls");

  char error[512] = {};
  require(
    iridium_wine_ios_validate_userland_root(root.c_str(), error, sizeof(error)) != 0,
    "userland without l_intl.nls should fail"
  );
  require(
    std::string(error).find("l_intl.nls") != std::string::npos,
    "missing NLS failure should identify l_intl.nls"
  );
}

void test_bootstrap_direct_launch_hydrates_prefix_and_sets_env() {
  const fs::path root = make_temp_root();
  const fs::path userland = make_userland_fixture(root / "userland");
  const fs::path prefix = root / "prefix";
  const fs::path executable = root / "game" / "SampleGame.exe";
  const fs::path bridge_root = root / "bridge";
  const fs::path framebuffer = bridge_root / "framebuffer.bgra";
  const fs::path input_events = bridge_root / "input-events.csv";
  const fs::path audio_state = bridge_root / "audio-state.txt";
  const fs::path trace = bridge_root / "wineios-trace.log";
  const fs::path wine_debug_log = bridge_root / "wine-debug.log";
  write_file(executable, "game");
  write_file(framebuffer, std::string(4 * 2 * 4, '\0'));
  write_file(input_events, "");
  write_file(audio_state, "sessionIdentifier=player-session\nsessionActive=1\ninterrupted=0\ncategory=playback\n");

  setenv("IRIDIUM_RUNTIME_SESSION_ID", "player-session", 1);
  setenv("IRIDIUM_WINE_IOS_SURFACE_ID", "surface.player-session", 1);
  setenv("IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH", framebuffer.c_str(), 1);
  setenv("IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH", input_events.c_str(), 1);
  setenv("IRIDIUM_WINE_IOS_AUDIO_STATE_PATH", audio_state.c_str(), 1);
  setenv("IRIDIUM_WINE_IOS_SURFACE_WIDTH", "4", 1);
  setenv("IRIDIUM_WINE_IOS_SURFACE_HEIGHT", "2", 1);
  setenv("IRIDIUM_WINE_IOS_TRACE_PATH", trace.c_str(), 1);
  setenv("WINEDEBUG", "warn+all,+loaddll,+seh,+driver,+winediag", 1);
  setenv("WINEDEBUGLOG", wine_debug_log.c_str(), 1);

  char wine_binary[1024] = {};
  char error[512] = {};
  require(
    iridium_wine_ios_bootstrap_direct_launch(
      executable.c_str(),
      prefix.c_str(),
      userland.c_str(),
      wine_binary,
      sizeof(wine_binary),
      error,
      sizeof(error)
    ) == 0,
    error
  );
  unsetenv("IRIDIUM_RUNTIME_SESSION_ID");
  unsetenv("IRIDIUM_WINE_IOS_SURFACE_ID");
  unsetenv("IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH");
  unsetenv("IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH");
  unsetenv("IRIDIUM_WINE_IOS_AUDIO_STATE_PATH");
  unsetenv("IRIDIUM_WINE_IOS_SURFACE_WIDTH");
  unsetenv("IRIDIUM_WINE_IOS_SURFACE_HEIGHT");
  unsetenv("IRIDIUM_WINE_IOS_TRACE_PATH");
  unsetenv("WINEDEBUGLOG");

  require(fs::exists(prefix / "system.reg"), "system.reg not hydrated");
  require(fs::exists(prefix / "user.reg"), "user.reg not hydrated");
  require(fs::exists(prefix / "userdef.reg"), "userdef.reg not hydrated");
  require(fs::exists(prefix / "config/iridium-direct-launch.env"), "launch env file missing");
  require(fs::exists(prefix / "config/iridium-playable-session.json"), "playable-session config missing");
  require(fs::is_symlink(prefix / "drive_c/windows/system32/kernel32.dll"), "system32 kernel32 link missing");
  require(fs::is_symlink(prefix / "drive_c/windows/system32/kernelbase.dll"), "system32 kernelbase link missing");
  require(std::string(wine_binary).find("wine64") != std::string::npos, "wine64 path not returned");
  require(std::getenv("IRIDIUM_SKIP_WINEBOOT_IF_SEEDED") != nullptr, "skip gate env missing");
  require(std::getenv("WINEPREFIX") != nullptr, "WINEPREFIX not exported");
  require(std::getenv("WINEDATADIR") != nullptr, "WINEDATADIR not exported");
  require(
    std::getenv("IRIDIUM_WINE_HOST_WINESERVER") != nullptr &&
      std::string(std::getenv("IRIDIUM_WINE_HOST_WINESERVER")) == "embedded",
    "embedded wineserver architecture marker not exported"
  );
  require(
    std::string(std::getenv("WINEDATADIR")) == (userland / "share/wine").string(),
    "WINEDATADIR does not target the staged Wine data directory"
  );
  require(fs::exists(trace), "bootstrap trace missing");

  std::ifstream env_stream(prefix / "config/iridium-direct-launch.env");
  const std::string env_contents(
    (std::istreambuf_iterator<char>(env_stream)),
    std::istreambuf_iterator<char>()
  );
  const std::vector<std::string> required_lines = {
    "IRIDIUM_NO_DESKTOP=1",
    "IRIDIUM_SKIP_WINEBOOT_IF_SEEDED=1",
    "IRIDIUM_WINE_IOS_GRAPHICS_DRIVER=wineios.drv",
    "IRIDIUM_WINE_IOS_AUDIO_DRIVER=winecoreaudio.drv",
    std::string("IRIDIUM_WINE_IOS_BRIDGE_CONFIG=") + (prefix / "config/iridium-playable-session.json").string(),
    std::string("IRIDIUM_WINE_IOS_SURFACE_ID=surface.player-session"),
    std::string("IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH=") + framebuffer.string(),
    std::string("IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH=") + input_events.string(),
    std::string("IRIDIUM_WINE_IOS_AUDIO_STATE_PATH=") + audio_state.string(),
    "IRIDIUM_WINE_IOS_SURFACE_WIDTH=4",
    "IRIDIUM_WINE_IOS_SURFACE_HEIGHT=2",
    "WINEARCH=win64",
    "WINEDEBUG=warn+all,+loaddll,+seh,+driver,+winediag",
    std::string("WINEDEBUGLOG=") + wine_debug_log.string(),
    std::string("WINEPREFIX=") + prefix.string(),
    std::string("WINESERVER=") + (userland / "bin/wineserver").string(),
    std::string("WINEDATADIR=") + (userland / "share/wine").string(),
    "IRIDIUM_WINE_HOST_WINESERVER=embedded",
  };
  for (const auto& line : required_lines) {
    require(env_contents.find(line) != std::string::npos, "direct-launch env file is incomplete");
  }

  std::ifstream trace_stream(trace);
  const std::string trace_contents(
    (std::istreambuf_iterator<char>(trace_stream)),
    std::istreambuf_iterator<char>()
  );
  require(
    trace_contents.find("bridge-bootstrap WINEDEBUG=warn+all,+loaddll,+seh,+driver,+winediag") != std::string::npos,
    "bootstrap trace missing WINEDEBUG"
  );
  require(
    trace_contents.find("bridge-bootstrap WINEDEBUGLOG=" + wine_debug_log.string()) != std::string::npos,
    "bootstrap trace missing WINEDEBUGLOG"
  );

  std::ifstream user_reg_stream(prefix / "user.reg");
  const std::string user_reg_contents(
    (std::istreambuf_iterator<char>(user_reg_stream)),
    std::istreambuf_iterator<char>()
  );
  require(user_reg_contents.find("\"Graphics\"=\"ios\"") != std::string::npos, "user.reg missing graphics driver selection");
  require(user_reg_contents.find("\"Audio\"=\"coreaudio\"") != std::string::npos, "user.reg missing audio driver selection");

  std::ifstream system_reg_stream(prefix / "system.reg");
  const std::string system_reg_contents(
    (std::istreambuf_iterator<char>(system_reg_stream)),
    std::istreambuf_iterator<char>()
  );
  require(system_reg_contents.find("\"GraphicsDriver\"=\"wineios.drv\"") != std::string::npos, "system.reg missing GraphicsDriver selection");

  std::ifstream config_stream(prefix / "config/iridium-playable-session.json");
  const std::string config_contents(
    (std::istreambuf_iterator<char>(config_stream)),
    std::istreambuf_iterator<char>()
  );
  require(config_contents.find("\"sessionIdentifier\": \"player-session\"") != std::string::npos, "playable-session config missing session id");
  require(config_contents.find("\"surfaceIdentifier\": \"surface.player-session\"") != std::string::npos, "playable-session config missing surface id");
  require(config_contents.find(std::string("\"framebufferPath\": \"") + framebuffer.string() + "\"") != std::string::npos, "playable-session config missing framebuffer path");
  require(config_contents.find(std::string("\"inputEventsPath\": \"") + input_events.string() + "\"") != std::string::npos, "playable-session config missing input path");
  require(config_contents.find(std::string("\"audioStatePath\": \"") + audio_state.string() + "\"") != std::string::npos, "playable-session config missing audio state path");
  require(config_contents.find("\"surfaceWidth\": 4") != std::string::npos, "playable-session config missing surface width");
  require(config_contents.find("\"surfaceHeight\": 2") != std::string::npos, "playable-session config missing surface height");
  require(config_contents.find("\"graphicsDriver\": \"wineios.drv\"") != std::string::npos, "playable-session config missing graphics driver");
  require(config_contents.find("\"audioDriver\": \"winecoreaudio.drv\"") != std::string::npos, "playable-session config missing audio driver");
  unsetenv("WINEDEBUG");
}

void test_bootstrap_direct_launch_repairs_stale_prefix_driver_registry() {
  const fs::path root = make_temp_root();
  const fs::path userland = make_userland_fixture(root / "userland");
  const fs::path prefix = root / "prefix";
  const fs::path executable = root / "game" / "SampleGame.exe";
  write_file(executable, "game");
  write_file(
    prefix / "user.reg",
    "WINE REGISTRY Version 2\n"
    "#arch=win64\n"
    "\n"
    "[Software\\Wine\\Drivers]\n"
    "\"Graphics\"=\"x11\"\n"
    "\"Audio\"=\"alsa\"\n"
    "\"Graphics\"=\"wayland\"\n");
  write_file(
    prefix / "system.reg",
    "WINE REGISTRY Version 2\n"
    "#arch=win64\n"
    "\n"
    "[System\\CurrentControlSet\\Control\\Video\\{00000000-0000-0000-0000-000000000000}\\0000]\n"
    "\"GraphicsDriver\"=\"winex11.drv\"\n"
    "\"GraphicsDriver\"=\"winewayland.drv\"\n");
  write_file(prefix / "userdef.reg", "WINE REGISTRY Version 2\n#arch=win64\n");

  char wine_binary[1024] = {};
  char error[512] = {};
  require(
    iridium_wine_ios_bootstrap_direct_launch(
      executable.c_str(),
      prefix.c_str(),
      userland.c_str(),
      wine_binary,
      sizeof(wine_binary),
      error,
      sizeof(error)
    ) == 0,
    error
  );

  std::ifstream user_reg_stream(prefix / "user.reg");
  const std::string user_reg_contents(
    (std::istreambuf_iterator<char>(user_reg_stream)),
    std::istreambuf_iterator<char>()
  );
  require(user_reg_contents.find("\"Graphics\"=\"ios\"") != std::string::npos, "user.reg did not repair graphics driver");
  require(user_reg_contents.find("\"Audio\"=\"coreaudio\"") != std::string::npos, "user.reg did not repair audio driver");
  require(user_reg_contents.find("\"Graphics\"=\"x11\"") == std::string::npos, "user.reg retained stale x11 graphics driver");
  require(user_reg_contents.find("\"Graphics\"=\"wayland\"") == std::string::npos, "user.reg retained stale wayland graphics driver");
  require(user_reg_contents.find("\"Audio\"=\"alsa\"") == std::string::npos, "user.reg retained stale audio driver");

  std::ifstream system_reg_stream(prefix / "system.reg");
  const std::string system_reg_contents(
    (std::istreambuf_iterator<char>(system_reg_stream)),
    std::istreambuf_iterator<char>()
  );
  require(
    system_reg_contents.find("\"GraphicsDriver\"=\"wineios.drv\"") != std::string::npos,
    "system.reg did not repair GraphicsDriver"
  );
  require(
    system_reg_contents.find("\"GraphicsDriver\"=\"winex11.drv\"") == std::string::npos,
    "system.reg retained stale winex11 driver"
  );
  require(
    system_reg_contents.find("\"GraphicsDriver\"=\"winewayland.drv\"") == std::string::npos,
    "system.reg retained stale wayland driver"
  );
}

void test_configure_playable_session_writes_bridge_contract() {
  const fs::path root = make_temp_root();
  const fs::path prefix = root / "prefix";
  const fs::path bridge_root = root / "bridge";
  const fs::path framebuffer = bridge_root / "framebuffer.bgra";
  const fs::path input_events = bridge_root / "input-events.csv";
  const fs::path audio_state = bridge_root / "audio-state.txt";
  const IridiumWineIOSPrefixLayout layout{prefix.c_str()};
  char error[512] = {};
  require(iridium_wine_ios_prepare_prefix_layout(&layout, error, sizeof(error)) == 0, error);
  write_file(prefix / "system.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(prefix / "user.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(prefix / "userdef.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(framebuffer, std::string(8 * 4, '\0'));
  write_file(input_events, "");
  write_file(audio_state, "sessionIdentifier=explicit-session\nsessionActive=1\ninterrupted=0\ncategory=playback\n");

  char config_path[1024] = {};
  IridiumWineIOSPlayableSessionConfiguration configuration{
    prefix.c_str(),
    "explicit-session",
    "surface.explicit",
    framebuffer.c_str(),
    input_events.c_str(),
    audio_state.c_str(),
    2,
    1,
  };

  require(
    iridium_wine_ios_configure_playable_session(
      &configuration,
      config_path,
      sizeof(config_path),
      error,
      sizeof(error)
    ) == 0,
    error
  );
  require(std::string(config_path).find("iridium-playable-session.json") != std::string::npos, "config path not returned");
  require(fs::exists(config_path), "playable-session config file missing");
}

void test_wineios_bridge_helpers_roundtrip_framebuffer_and_input() {
  const fs::path root = make_temp_root();
  const fs::path prefix = root / "prefix";
  const fs::path bridge_root = root / "bridge";
  const fs::path framebuffer = bridge_root / "framebuffer.bgra";
  const fs::path input_events = bridge_root / "input-events.csv";
  const fs::path audio_state = bridge_root / "audio-state.txt";
  const IridiumWineIOSPrefixLayout layout{prefix.c_str()};
  char error[512] = {};
  char config_path[1024] = {};

  require(iridium_wine_ios_prepare_prefix_layout(&layout, error, sizeof(error)) == 0, error);
  write_file(prefix / "system.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(prefix / "user.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(prefix / "userdef.reg", "WINE REGISTRY Version 2\n#arch=win64\n");
  write_file(framebuffer, std::string(4 * 2 * 4, '\0'));
  write_file(input_events,
    "0,controllerButton,down,0,,,1.000000,buttonA\n"
    "1,keyboard,down,0,,,1.000000,ArrowLeft\n");
  write_file(audio_state, "sessionIdentifier=explicit-session\nsessionActive=1\ninterrupted=0\ncategory=playback\n");

  IridiumWineIOSPlayableSessionConfiguration configuration{
    prefix.c_str(),
    "explicit-session",
    "surface.explicit",
    framebuffer.c_str(),
    input_events.c_str(),
    audio_state.c_str(),
    4,
    2,
  };
  require(
    iridium_wine_ios_configure_playable_session(
      &configuration,
      config_path,
      sizeof(config_path),
      error,
      sizeof(error)
    ) == 0,
    error
  );

  setenv(IRIDIUM_WINE_IOS_BRIDGE_CONFIG_ENV, config_path, 1);
  setenv(IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH_ENV, framebuffer.c_str(), 1);
  setenv(IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH_ENV, input_events.c_str(), 1);
  setenv(IRIDIUM_WINE_IOS_AUDIO_STATE_PATH_ENV, audio_state.c_str(), 1);
  setenv(IRIDIUM_WINE_IOS_SURFACE_WIDTH_ENV, "4", 1);
  setenv(IRIDIUM_WINE_IOS_SURFACE_HEIGHT_ENV, "2", 1);

  struct wineios_bridge_configuration loaded = {};
  require(wineiosdrv_load_bridge_configuration(&loaded, error, sizeof(error)) == 0, error);
  require(std::string(loaded.surface_identifier) == "surface.explicit", "loaded bridge surface id mismatch");
  require(std::string(loaded.framebuffer_path) == framebuffer.string(), "loaded framebuffer path mismatch");

  struct wineios_framebuffer_surface surface = {};
  require(wineiosdrv_open_framebuffer_surface(&loaded, &surface, error, sizeof(error)) == 0, error);
  require(!fs::exists(framebuffer.string() + ".ready"), "opening a surface must not publish readiness before a frame exists");
  const std::array<uint32_t, 8> pixels = {
    0xff0000ffu, 0xff00ff00u, 0xffff0000u, 0xffffffffu,
    0xff123456u, 0xffabcdefu, 0xff00ffffu, 0xff654321u,
  };
  require(
    wineiosdrv_present_frame(&surface, pixels.data(), pixels.size() * sizeof(uint32_t), 4, 2, error, sizeof(error)) == 0,
    error
  );
  require(fs::exists(framebuffer.string() + ".ready"), "first successful presentation should publish a frame-ready marker");

  uint32_t pixel = 0;
  require(wineiosdrv_read_framebuffer_pixel(&surface, 1, 1, &pixel, error, sizeof(error)) == 0, error);
  require(pixel == 0xffabcdefu, "framebuffer readback mismatch");

  size_t cursor = 0;
  struct wineios_input_event event = {};
  unsigned int virtual_key = 0;
  require(wineiosdrv_poll_input_event(&loaded, &cursor, &event, error, sizeof(error)) == 0, error);
  require(std::string(event.type) == "controllerButton", "first input event type mismatch");
  require(wineiosdrv_translate_virtual_key(&event, &virtual_key) == 0, "first virtual-key translation failed");
  require(virtual_key == 0x0D, "controller button A should translate to VK_RETURN");

  require(wineiosdrv_poll_input_event(&loaded, &cursor, &event, error, sizeof(error)) == 0, error);
  require(std::string(event.type) == "keyboard", "second input event type mismatch");
  require(wineiosdrv_translate_virtual_key(&event, &virtual_key) == 0, "second virtual-key translation failed");
  require(virtual_key == 0x25, "ArrowLeft should translate to VK_LEFT");

  unsetenv(IRIDIUM_WINE_IOS_BRIDGE_CONFIG_ENV);
  unsetenv(IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH_ENV);
  unsetenv(IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH_ENV);
  unsetenv(IRIDIUM_WINE_IOS_AUDIO_STATE_PATH_ENV);
  unsetenv(IRIDIUM_WINE_IOS_SURFACE_WIDTH_ENV);
  unsetenv(IRIDIUM_WINE_IOS_SURFACE_HEIGHT_ENV);
}

void test_iPhone_audio_state_gates_render_ready() {
  const fs::path root = make_temp_root();
  const fs::path audio_state = root / "audio-state.txt";
  char error[512] = {};

  setenv("IRIDIUM_WINE_IOS_AUDIO_STATE_PATH", audio_state.c_str(), 1);
  write_file(audio_state, "sessionIdentifier=player-session\nsessionActive=0\ninterrupted=0\ncategory=playback\n");
  require(iridium_ios_audio_render_ready(error, sizeof(error)) != 0, "inactive playback session should block render audio");

  write_file(audio_state, "sessionIdentifier=player-session\nsessionActive=1\ninterrupted=0\ncategory=playback\n");
  require(iridium_ios_audio_render_ready(error, sizeof(error)) == 0, error);
  unsetenv("IRIDIUM_WINE_IOS_AUDIO_STATE_PATH");
}

void test_bootstrap_direct_launch_rejects_blocked_entrypoint() {
  const fs::path root = make_temp_root();
  const fs::path userland = make_userland_fixture(root / "userland");
  const fs::path prefix = root / "prefix";
  const fs::path executable = root / "game" / "msiexec.exe";
  write_file(executable, "installer");

  char wine_binary[1024] = {};
  char error[512] = {};
  require(
    iridium_wine_ios_bootstrap_direct_launch(
      executable.c_str(),
      prefix.c_str(),
      userland.c_str(),
      wine_binary,
      sizeof(wine_binary),
      error,
      sizeof(error)
    ) != 0,
    "blocked entrypoint should fail"
  );
}

void test_blocked_entrypoints() {
  require(iridium_wine_ios_is_blocked_entrypoint("/tmp/explorer.exe") != 0, "explorer.exe should be blocked");
  require(iridium_wine_ios_is_blocked_entrypoint("/tmp/winebrowser.exe") != 0, "winebrowser.exe should be blocked");
  require(iridium_wine_ios_is_blocked_entrypoint("/tmp/msiexec.exe") != 0, "msiexec.exe should be blocked");
  require(iridium_wine_ios_is_blocked_entrypoint("/tmp/wineboot.exe") != 0, "wineboot.exe should be blocked");
  require(iridium_wine_ios_is_blocked_entrypoint("/tmp/Game.exe") == 0, "Game.exe should be allowed");
}

}  // namespace

int main() {
  test_prepare_prefix_layout();
  test_validate_userland_root_requires_prefix_seed();
  test_validate_userland_root_rejects_missing_wineserver();
  test_validate_userland_root_rejects_missing_wine_launcher();
  test_validate_userland_root_rejects_missing_libraries();
  test_validate_userland_root_rejects_invalid_seed_payload();
  test_validate_userland_root_rejects_missing_server_nls();
  test_bootstrap_direct_launch_hydrates_prefix_and_sets_env();
  test_bootstrap_direct_launch_repairs_stale_prefix_driver_registry();
  test_configure_playable_session_writes_bridge_contract();
  test_wineios_bridge_helpers_roundtrip_framebuffer_and_input();
  test_iPhone_audio_state_gates_render_ready();
  test_bootstrap_direct_launch_rejects_blocked_entrypoint();
  test_blocked_entrypoints();
  std::cout << "bridge_tests passed\n";
  return 0;
}
