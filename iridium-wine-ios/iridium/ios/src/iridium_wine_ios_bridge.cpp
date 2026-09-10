#include "../include/iridium_wine_ios_bridge.h"

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <vector>

#if __has_include(<filesystem>)
#include <filesystem>
namespace fs = std::filesystem;
#elif __has_include(<experimental/filesystem>)
#include <experimental/filesystem>
namespace fs = std::experimental::filesystem;
#endif

namespace {
constexpr const char* kWineIOSGraphicsDriver = "wineios.drv";
constexpr const char* kWineIOSAudioDriver = "winecoreaudio.drv";
constexpr const char* kWineDriverRegistrySection = "Software\\Wine\\Drivers";
constexpr const char* kWineVideoRegistrySection =
  "System\\CurrentControlSet\\Control\\Video\\{00000000-0000-0000-0000-000000000000}\\0000";

struct PlayableBridgeArtifacts {
  std::string session_identifier;
  std::string surface_identifier;
  std::string framebuffer_path;
  std::string input_events_path;
  std::string audio_state_path;
  unsigned int surface_width = 0;
  unsigned int surface_height = 0;
};

bool file_exists(const char* path) {
  return path != nullptr && path[0] != '\0' && access(path, F_OK) == 0;
}

bool file_exists(const std::string& path) {
  return file_exists(path.c_str());
}

std::string string_or_empty(const char* value) {
  return value == nullptr ? std::string() : std::string(value);
}

std::string launch_winedebug_value() {
  const char* value = std::getenv("WINEDEBUG");
  if (value == nullptr || value[0] == '\0') {
    return "-all";
  }
  return value;
}

std::string launch_winedebuglog_path() {
  const char* value = std::getenv("WINEDEBUGLOG");
  if (value == nullptr || value[0] == '\0') {
    return "";
  }
  return value;
}

void append_bootstrap_trace(
  const std::string& wine_debug,
  const std::string& wine_debug_log_path,
  const std::string& bridge_config_path,
  const std::string& framebuffer_path
) {
  const char* trace_path = std::getenv("IRIDIUM_WINE_IOS_TRACE_PATH");
  if (trace_path == nullptr || trace_path[0] == '\0') {
    return;
  }

  std::ofstream stream(trace_path, std::ios::app);
  if (!stream.is_open()) {
    return;
  }

  stream << "bridge-bootstrap WINEDEBUG=" << wine_debug << "\n";
  stream << "bridge-bootstrap WINEDEBUGLOG="
         << (wine_debug_log_path.empty() ? std::string("missing") : wine_debug_log_path)
         << "\n";
  if (!bridge_config_path.empty()) {
    stream << "bridge-bootstrap config=" << bridge_config_path << "\n";
  }
  if (!framebuffer_path.empty()) {
    stream << "bridge-bootstrap framebuffer=" << framebuffer_path << "\n";
  }
}

unsigned int parse_unsigned_env(const char* key) {
  const char* value = std::getenv(key);
  if (value == nullptr || value[0] == '\0') {
    return 0;
  }

  char* end = nullptr;
  const unsigned long parsed = std::strtoul(value, &end, 10);
  if (end == nullptr || *end != '\0') {
    return 0;
  }

  return static_cast<unsigned int>(parsed);
}

bool has_required_bridge_artifacts(const PlayableBridgeArtifacts& artifacts) {
  return !artifacts.session_identifier.empty()
    && !artifacts.surface_identifier.empty()
    && !artifacts.framebuffer_path.empty()
    && !artifacts.input_events_path.empty()
    && !artifacts.audio_state_path.empty()
    && artifacts.surface_width > 0
    && artifacts.surface_height > 0;
}

void write_error(char* buffer, size_t buffer_size, const std::string& message) {
  if (buffer == nullptr || buffer_size == 0) {
    return;
  }
  std::strncpy(buffer, message.c_str(), buffer_size - 1);
  buffer[buffer_size - 1] = '\0';
}

std::string read_text_file(const std::string& path) {
  std::ifstream stream(path);
  if (!stream.is_open()) {
    return "";
  }
  return std::string((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
}

int write_text_file(const std::string& path, const std::string& contents) {
  std::ofstream stream(path, std::ios::trunc);
  if (!stream.is_open()) {
    return errno == 0 ? EIO : errno;
  }
  stream << contents;
  stream.close();
  if (!stream) {
    return EIO;
  }
  return 0;
}

std::vector<std::string> split_registry_lines(const std::string& contents) {
  std::vector<std::string> lines;
  std::string current;

  for (const char character : contents) {
    if (character == '\n') {
      if (!current.empty() && current.back() == '\r') {
        current.pop_back();
      }
      lines.push_back(current);
      current.clear();
    } else {
      current.push_back(character);
    }
  }

  if (!current.empty() || (!contents.empty() && contents.back() != '\n')) {
    if (!current.empty() && current.back() == '\r') {
      current.pop_back();
    }
    lines.push_back(current);
  }

  return lines;
}

std::string join_registry_lines(const std::vector<std::string>& lines) {
  std::ostringstream output;
  for (const auto& line : lines) {
    output << line << "\n";
  }
  return output.str();
}

bool is_registry_section_line(const std::string& line) {
  return line.size() >= 2 && line.front() == '[' && line.back() == ']';
}

bool is_registry_section(const std::string& line, const std::string& section) {
  return line == "[" + section + "]";
}

bool is_registry_value_assignment(const std::string& line, const std::string& key) {
  const std::string prefix = "\"" + key + "\"=";
  return line.rfind(prefix, 0) == 0;
}

std::string registry_value_line(const std::string& key, const std::string& value) {
  return "\"" + key + "\"=\"" + value + "\"";
}

int ensure_registry_value(
  const std::string& registry_path,
  const std::string& section,
  const std::string& key,
  const std::string& value,
  char* error_buffer,
  size_t error_buffer_size
) {
  std::string contents = read_text_file(registry_path);
  if (contents.empty()) {
    write_error(error_buffer, error_buffer_size, "prefix registry payload is missing");
    return 1;
  }

  std::vector<std::string> lines = split_registry_lines(contents);
  std::vector<std::string> updated;
  bool found_section = false;
  bool in_section = false;
  bool wrote_value = false;
  const std::string value_line = registry_value_line(key, value);

  updated.reserve(lines.size() + 4);
  for (const auto& line : lines) {
    if (is_registry_section_line(line)) {
      if (in_section && !wrote_value) {
        updated.push_back(value_line);
        wrote_value = true;
      }
      in_section = is_registry_section(line, section);
      if (in_section) {
        found_section = true;
        wrote_value = false;
      }
      updated.push_back(line);
      continue;
    }

    if (in_section && is_registry_value_assignment(line, key)) {
      if (!wrote_value) {
        updated.push_back(value_line);
        wrote_value = true;
      }
      continue;
    }

    updated.push_back(line);
  }

  if (in_section && !wrote_value) {
    updated.push_back(value_line);
  }

  if (!found_section) {
    if (!updated.empty() && !updated.back().empty()) {
      updated.push_back("");
    }
    updated.push_back("[" + section + "]");
    updated.push_back(value_line);
  }

  const int result = write_text_file(registry_path, join_registry_lines(updated));
  if (result != 0) {
    write_error(error_buffer, error_buffer_size, "failed to update prefix registry payload");
    return result;
  }

  return 0;
}

std::string join_path(const std::string& lhs, const std::string& rhs) {
  if (lhs.empty()) {
    return rhs;
  }
  if (lhs.back() == '/') {
    return lhs + rhs;
  }
  return lhs + "/" + rhs;
}

int ensure_directory(const std::string& path) {
  if (path.empty()) {
    return EINVAL;
  }
  std::error_code error;
  fs::create_directories(path, error);
  return error ? error.value() : 0;
}

std::string lowercase(std::string value) {
  for (char& character : value) {
    if (character >= 'A' && character <= 'Z') {
      character = static_cast<char>(character - 'A' + 'a');
    }
  }
  return value;
}

std::string filename(const std::string& path) {
  const auto separator = path.find_last_of('/');
  if (separator == std::string::npos) {
    return path;
  }
  return path.substr(separator + 1);
}

bool directory_exists(const std::string& path) {
  std::error_code error;
  return fs::is_directory(fs::path(path), error);
}

bool symlink_points_to(const std::string& path, const std::string& target) {
  std::error_code error;
  if (!fs::is_symlink(fs::path(path), error)) {
    return false;
  }
  return fs::read_symlink(fs::path(path), error) == fs::path(target);
}

int ensure_symlink(const std::string& path, const std::string& target) {
  std::error_code error;
  if (symlink_points_to(path, target)) {
    return 0;
  }

  fs::remove(fs::path(path), error);
  error.clear();
  fs::create_symlink(fs::path(target), fs::path(path), error);
  return error ? error.value() : 0;
}

std::string find_windows_dll_directory(const std::string& root) {
  const std::vector<std::string> candidates = {
    join_path(root, "lib/wine/x86_64-windows"),
    join_path(root, "lib64/wine/x86_64-windows"),
  };
  for (const auto& candidate : candidates) {
    if (directory_exists(candidate)) {
      return candidate;
    }
  }
  return "";
}

int expose_builtin_system32_dlls(
  const std::string& prefix_root,
  const std::string& userland_root,
  char* error_buffer,
  size_t error_buffer_size
) {
  const std::string system32_directory = join_path(prefix_root, "drive_c/windows/system32");
  const int directory_result = ensure_directory(system32_directory);
  if (directory_result != 0) {
    write_error(error_buffer, error_buffer_size, "failed to create prefix system32 directory");
    return directory_result;
  }

  const std::string dll_directory = find_windows_dll_directory(userland_root);
  if (dll_directory.empty()) {
    write_error(error_buffer, error_buffer_size, "userland root is missing x86_64 Windows DLL directory");
    return ENOENT;
  }

  std::error_code error;
  for (const auto& entry : fs::directory_iterator(fs::path(dll_directory), error)) {
    if (error) {
      write_error(error_buffer, error_buffer_size, "failed to enumerate bundled Windows DLL directory");
      return error.value();
    }

    std::error_code status_error;
    const auto status = entry.symlink_status(status_error);
    if (status_error || (!fs::is_regular_file(status) && !fs::is_symlink(status))) {
      continue;
    }

    const int result = ensure_symlink(
      join_path(system32_directory, entry.path().filename().string()),
      entry.path().string()
    );
    if (result != 0) {
      write_error(error_buffer, error_buffer_size, "failed to expose bundled Windows DLL in prefix system32");
      return result;
    }
  }
  if (error) {
    write_error(error_buffer, error_buffer_size, "failed to enumerate bundled Windows DLL directory");
    return error.value();
  }

  return 0;
}

std::string find_wine_binary(const std::string& root) {
  const std::vector<std::string> candidates = {
    join_path(root, "lib/wine/x86_64-unix/wine-preloader"),
    join_path(root, "lib64/wine/x86_64-unix/wine-preloader"),
    join_path(root, "lib/wine/x86_64-unix/wine"),
    join_path(root, "lib64/wine/x86_64-unix/wine"),
    join_path(root, "bin/wine64"),
    join_path(root, "bin/wine"),
    join_path(root, "wine64"),
    join_path(root, "wine"),
    join_path(root, "Contents/MacOS/wine"),
    join_path(root, "Contents/Resources/wine/bin/wine64"),
    join_path(root, "Contents/Resources/wine/bin/wine"),
  };
  for (const auto& candidate : candidates) {
    if (file_exists(candidate)) {
      return candidate;
    }
  }
  return "";
}

std::string find_wineserver_binary(const std::string& root) {
  const std::vector<std::string> candidates = {
    join_path(root, "bin/wineserver"),
    join_path(root, "Contents/Resources/wine/bin/wineserver"),
  };
  for (const auto& candidate : candidates) {
    if (file_exists(candidate)) {
      return candidate;
    }
  }
  return "";
}

bool is_direct_launch_binary_path(const std::string& path) {
  const std::string binary_name = lowercase(filename(path));
  return binary_name == "wine64" || binary_name == "wine" || binary_name == "wine-preloader"
    || binary_name == "wine64-preloader";
}

int require_seed_file(
  const std::string& userland_root,
  const std::string& relative_path,
  char* error_buffer,
  size_t error_buffer_size
) {
  const std::string full_path = join_path(userland_root, relative_path);
  if (file_exists(full_path)) {
    return 0;
  }

  write_error(
    error_buffer,
    error_buffer_size,
    "userland root is missing required seed file: " + relative_path
  );
  return 1;
}

int validate_seed_file_contents(
  const std::string& userland_root,
  const std::string& relative_path,
  char* error_buffer,
  size_t error_buffer_size
) {
  const std::string full_path = join_path(userland_root, relative_path);
  std::ifstream stream(full_path);
  if (!stream.is_open()) {
    write_error(
      error_buffer,
      error_buffer_size,
      "userland root is missing required seed file: " + relative_path
    );
    return 1;
  }

  std::string contents((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
  if (contents.find("WINE REGISTRY Version 2") != 0) {
    write_error(
      error_buffer,
      error_buffer_size,
      "seed file is not a Wine registry payload: " + relative_path
    );
    return 1;
  }

  if (contents.find("#arch=win64") == std::string::npos) {
    write_error(
      error_buffer,
      error_buffer_size,
      "seed file is not tagged for win64: " + relative_path
    );
    return 1;
  }

  return 0;
}

int hydrate_prefix_seed(
  const std::string& prefix_root,
  const std::string& userland_root,
  char* error_buffer,
  size_t error_buffer_size
) {
  const std::vector<std::string> required_seed_files = {
    "prefix-seed/system.reg",
    "prefix-seed/user.reg",
    "prefix-seed/userdef.reg",
  };

  for (const auto& relative_path : required_seed_files) {
    if (require_seed_file(userland_root, relative_path, error_buffer, error_buffer_size) != 0) {
      return 1;
    }

    const std::string source = join_path(userland_root, relative_path);
    const std::string destination = join_path(prefix_root, filename(relative_path));
    if (file_exists(destination)) {
      continue;
    }

    std::error_code error;
    fs::copy_file(
      fs::path(source),
      fs::path(destination),
      fs::copy_options::overwrite_existing,
      error
    );
    if (error) {
      write_error(error_buffer, error_buffer_size, "failed to hydrate seeded prefix registry");
      return error.value();
    }
  }

  return 0;
}

int configure_prefix_driver_selection(
  const std::string& prefix_root,
  char* error_buffer,
  size_t error_buffer_size
) {
  const std::string userRegistryPath = join_path(prefix_root, "user.reg");
  const std::string systemRegistryPath = join_path(prefix_root, "system.reg");

  if (ensure_registry_value(
        userRegistryPath,
        kWineDriverRegistrySection,
        "Graphics",
        "ios",
        error_buffer,
        error_buffer_size) != 0) {
    return 1;
  }
  if (ensure_registry_value(
        userRegistryPath,
        kWineDriverRegistrySection,
        "Audio",
        "coreaudio",
        error_buffer,
        error_buffer_size) != 0) {
    return 1;
  }
  if (ensure_registry_value(
        systemRegistryPath,
        kWineVideoRegistrySection,
        "GraphicsDriver",
        kWineIOSGraphicsDriver,
        error_buffer,
        error_buffer_size) != 0) {
    return 1;
  }

  return 0;
}

std::string playable_session_config_path(const std::string& prefix_root) {
  return join_path(prefix_root, "config/iridium-playable-session.json");
}

int write_playable_session_bridge_config(
  const std::string& prefix_root,
  const PlayableBridgeArtifacts& artifacts,
  char* bridge_config_path_buffer,
  size_t bridge_config_path_buffer_size,
  char* error_buffer,
  size_t error_buffer_size
) {
  if (!has_required_bridge_artifacts(artifacts)) {
    write_error(error_buffer, error_buffer_size, "missing playable-session bridge artifacts");
    return 1;
  }

  if (ensure_directory(join_path(prefix_root, "config")) != 0) {
    write_error(error_buffer, error_buffer_size, "failed to create playable-session config directory");
    return 1;
  }

  const std::string configPath = playable_session_config_path(prefix_root);
  std::ostringstream payload;
  payload
    << "{\n"
    << "  \"sessionIdentifier\": \"" << artifacts.session_identifier << "\",\n"
    << "  \"surfaceIdentifier\": \"" << artifacts.surface_identifier << "\",\n"
    << "  \"framebufferPath\": \"" << artifacts.framebuffer_path << "\",\n"
    << "  \"inputEventsPath\": \"" << artifacts.input_events_path << "\",\n"
    << "  \"audioStatePath\": \"" << artifacts.audio_state_path << "\",\n"
    << "  \"surfaceWidth\": " << artifacts.surface_width << ",\n"
    << "  \"surfaceHeight\": " << artifacts.surface_height << ",\n"
    << "  \"graphicsDriver\": \"" << kWineIOSGraphicsDriver << "\",\n"
    << "  \"audioDriver\": \"" << kWineIOSAudioDriver << "\",\n"
    << "  \"graphicsStack\": \"metalOpenGLFallback\",\n"
    << "  \"fullscreenOnly\": true\n"
    << "}\n";

  const int writeResult = write_text_file(configPath, payload.str());
  if (writeResult != 0) {
    write_error(error_buffer, error_buffer_size, "failed to write playable-session bridge config");
    return writeResult;
  }

  write_error(bridge_config_path_buffer, bridge_config_path_buffer_size, configPath);
  return 0;
}

int validate_launch_ready_prefix(
  const std::string& prefix_root,
  char* error_buffer,
  size_t error_buffer_size
) {
  const std::vector<std::string> required_paths = {
    join_path(prefix_root, "system.reg"),
    join_path(prefix_root, "user.reg"),
    join_path(prefix_root, "userdef.reg"),
    join_path(prefix_root, "dosdevices/c:"),
    join_path(prefix_root, "dosdevices/z:"),
  };

  for (const auto& path : required_paths) {
    if (!file_exists(path)) {
      write_error(error_buffer, error_buffer_size, "prefix is missing required direct-launch state");
      return 1;
    }
  }

  return 0;
}

int validate_direct_launch_env_file(
  const std::string& env_path,
  const std::string& prefix_root,
  const std::string& wineserver_binary,
  const std::string& wine_data_directory,
  const std::string& bridge_config_path,
  const PlayableBridgeArtifacts& artifacts,
  char* error_buffer,
  size_t error_buffer_size
) {
  std::ifstream stream(env_path);
  if (!stream.is_open()) {
    write_error(error_buffer, error_buffer_size, "failed to write direct-launch environment");
    return 1;
  }

  std::string contents((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
  const std::string wine_debug_log_path = launch_winedebuglog_path();
  const std::vector<std::string> required_lines = {
    "IRIDIUM_NO_DESKTOP=1\n",
    "IRIDIUM_SKIP_WINEBOOT_IF_SEEDED=1\n",
    std::string("IRIDIUM_WINE_IOS_GRAPHICS_DRIVER=") + kWineIOSGraphicsDriver + "\n",
    std::string("IRIDIUM_WINE_IOS_AUDIO_DRIVER=") + kWineIOSAudioDriver + "\n",
    "WINEARCH=win64\n",
    "WINEDEBUG=" + launch_winedebug_value() + "\n",
    "WINEPREFIX=" + prefix_root + "\n",
    "WINESERVER=" + wineserver_binary + "\n",
    "WINEDATADIR=" + wine_data_directory + "\n",
    "IRIDIUM_WINE_HOST_WINESERVER=embedded\n",
  };

  for (const auto& line : required_lines) {
    if (contents.find(line) == std::string::npos) {
      write_error(error_buffer, error_buffer_size, "direct-launch environment is incomplete");
      return 1;
    }
  }

  if (!wine_debug_log_path.empty()
      && contents.find("WINEDEBUGLOG=" + wine_debug_log_path + "\n") == std::string::npos) {
    write_error(error_buffer, error_buffer_size, "direct-launch environment is incomplete");
    return 1;
  }

  if (!bridge_config_path.empty()
      && contents.find("IRIDIUM_WINE_IOS_BRIDGE_CONFIG=" + bridge_config_path + "\n")
        == std::string::npos) {
    write_error(error_buffer, error_buffer_size, "direct-launch environment is incomplete");
    return 1;
  }

  const std::vector<std::string> optional_bridge_lines = {
    artifacts.framebuffer_path.empty() ? std::string() : "IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH=" + artifacts.framebuffer_path + "\n",
    artifacts.input_events_path.empty() ? std::string() : "IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH=" + artifacts.input_events_path + "\n",
    artifacts.audio_state_path.empty() ? std::string() : "IRIDIUM_WINE_IOS_AUDIO_STATE_PATH=" + artifacts.audio_state_path + "\n",
    artifacts.surface_identifier.empty() ? std::string() : "IRIDIUM_WINE_IOS_SURFACE_ID=" + artifacts.surface_identifier + "\n",
    artifacts.surface_width == 0 ? std::string() : "IRIDIUM_WINE_IOS_SURFACE_WIDTH=" + std::to_string(artifacts.surface_width) + "\n",
    artifacts.surface_height == 0 ? std::string() : "IRIDIUM_WINE_IOS_SURFACE_HEIGHT=" + std::to_string(artifacts.surface_height) + "\n",
  };
  for (const auto& line : optional_bridge_lines) {
    if (!line.empty() && contents.find(line) == std::string::npos) {
      write_error(error_buffer, error_buffer_size, "direct-launch environment is incomplete");
      return 1;
    }
  }

  return 0;
}

int write_direct_launch_env(
  const std::string& prefix_root,
  const std::string& wineserver_binary,
  const std::string& wine_data_directory,
  const std::string& bridge_config_path,
  const PlayableBridgeArtifacts& artifacts,
  char* error_buffer,
  size_t error_buffer_size
) {
  const std::string env_path = join_path(prefix_root, "config/iridium-direct-launch.env");
  std::ofstream stream(env_path, std::ios::trunc);
  if (!stream.is_open()) {
    write_error(error_buffer, error_buffer_size, "failed to write direct-launch environment");
    return 1;
  }

  stream << "IRIDIUM_NO_DESKTOP=1\n";
  stream << "IRIDIUM_SKIP_WINEBOOT_IF_SEEDED=1\n";
  stream << "IRIDIUM_WINE_IOS_GRAPHICS_DRIVER=" << kWineIOSGraphicsDriver << "\n";
  stream << "IRIDIUM_WINE_IOS_AUDIO_DRIVER=" << kWineIOSAudioDriver << "\n";
  stream << "WINEARCH=win64\n";
  stream << "WINEDEBUG=" << launch_winedebug_value() << "\n";
  const std::string wine_debug_log_path = launch_winedebuglog_path();
  if (!wine_debug_log_path.empty()) {
    stream << "WINEDEBUGLOG=" << wine_debug_log_path << "\n";
  }
  stream << "WINEPREFIX=" << prefix_root << "\n";
  stream << "WINEDATADIR=" << wine_data_directory << "\n";
  stream << "IRIDIUM_WINE_HOST_WINESERVER=embedded\n";
  if (!bridge_config_path.empty()) {
    stream << "IRIDIUM_WINE_IOS_BRIDGE_CONFIG=" << bridge_config_path << "\n";
  }
  if (!artifacts.surface_identifier.empty()) {
    stream << "IRIDIUM_WINE_IOS_SURFACE_ID=" << artifacts.surface_identifier << "\n";
  }
  if (!artifacts.framebuffer_path.empty()) {
    stream << "IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH=" << artifacts.framebuffer_path << "\n";
  }
  if (!artifacts.input_events_path.empty()) {
    stream << "IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH=" << artifacts.input_events_path << "\n";
  }
  if (!artifacts.audio_state_path.empty()) {
    stream << "IRIDIUM_WINE_IOS_AUDIO_STATE_PATH=" << artifacts.audio_state_path << "\n";
  }
  if (artifacts.surface_width > 0) {
    stream << "IRIDIUM_WINE_IOS_SURFACE_WIDTH=" << artifacts.surface_width << "\n";
  }
  if (artifacts.surface_height > 0) {
    stream << "IRIDIUM_WINE_IOS_SURFACE_HEIGHT=" << artifacts.surface_height << "\n";
  }
  if (!wineserver_binary.empty()) {
    stream << "WINESERVER=" << wineserver_binary << "\n";
  }

  stream.close();
  if (!stream) {
    write_error(error_buffer, error_buffer_size, "failed to finalize direct-launch environment");
    return 1;
  }

  return validate_direct_launch_env_file(
    env_path,
    prefix_root,
    wineserver_binary,
    wine_data_directory,
    bridge_config_path,
    artifacts,
    error_buffer,
    error_buffer_size
  );
}

void set_launch_environment(
  const std::string& prefix_root,
  const std::string& wineserver_binary,
  const std::string& wine_data_directory,
  const std::string& bridge_config_path,
  const PlayableBridgeArtifacts& artifacts
) {
  setenv("IRIDIUM_NO_DESKTOP", "1", 1);
  setenv("IRIDIUM_SKIP_WINEBOOT_IF_SEEDED", "1", 1);
  setenv("IRIDIUM_WINE_IOS_GRAPHICS_DRIVER", kWineIOSGraphicsDriver, 1);
  setenv("IRIDIUM_WINE_IOS_AUDIO_DRIVER", kWineIOSAudioDriver, 1);
  setenv("WINEARCH", "win64", 1);
  const std::string wine_debug = launch_winedebug_value();
  setenv("WINEDEBUG", wine_debug.c_str(), 1);
  const std::string wine_debug_log_path = launch_winedebuglog_path();
  if (!wine_debug_log_path.empty()) {
    setenv("WINEDEBUGLOG", wine_debug_log_path.c_str(), 1);
  }
  setenv("WINEPREFIX", prefix_root.c_str(), 1);
  setenv("WINEDATADIR", wine_data_directory.c_str(), 1);
  setenv("IRIDIUM_WINE_HOST_WINESERVER", "embedded", 1);
  if (!bridge_config_path.empty()) {
    setenv("IRIDIUM_WINE_IOS_BRIDGE_CONFIG", bridge_config_path.c_str(), 1);
  }
  if (!artifacts.surface_identifier.empty()) {
    setenv("IRIDIUM_WINE_IOS_SURFACE_ID", artifacts.surface_identifier.c_str(), 1);
  }
  if (!artifacts.framebuffer_path.empty()) {
    setenv("IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH", artifacts.framebuffer_path.c_str(), 1);
  }
  if (!artifacts.input_events_path.empty()) {
    setenv("IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH", artifacts.input_events_path.c_str(), 1);
  }
  if (!artifacts.audio_state_path.empty()) {
    setenv("IRIDIUM_WINE_IOS_AUDIO_STATE_PATH", artifacts.audio_state_path.c_str(), 1);
  }
  if (artifacts.surface_width > 0) {
    const std::string width = std::to_string(artifacts.surface_width);
    setenv("IRIDIUM_WINE_IOS_SURFACE_WIDTH", width.c_str(), 1);
  }
  if (artifacts.surface_height > 0) {
    const std::string height = std::to_string(artifacts.surface_height);
    setenv("IRIDIUM_WINE_IOS_SURFACE_HEIGHT", height.c_str(), 1);
  }
  if (!wineserver_binary.empty()) {
    setenv("WINESERVER", wineserver_binary.c_str(), 1);
  }
}

}  // namespace

extern "C" int iridium_wine_ios_prepare_prefix_layout(
  const IridiumWineIOSPrefixLayout* layout,
  char* error_buffer,
  size_t error_buffer_size
) {
  if (layout == nullptr || layout->prefix_root_path == nullptr || layout->prefix_root_path[0] == '\0') {
    write_error(error_buffer, error_buffer_size, "missing prefix root path");
    return 1;
  }

  const std::string prefix_root(layout->prefix_root_path);
  const std::vector<std::string> required_paths = {
    prefix_root,
    join_path(prefix_root, "drive_c"),
    join_path(prefix_root, "drive_c/users"),
    join_path(prefix_root, "drive_c/users/steamuser"),
    join_path(prefix_root, "dosdevices"),
    join_path(prefix_root, "config"),
  };

  for (const auto& path : required_paths) {
    const int result = ensure_directory(path);
    if (result != 0) {
      write_error(error_buffer, error_buffer_size, "failed to create Wine prefix layout");
      return result;
    }
  }

  {
    const int result = ensure_symlink(join_path(prefix_root, "dosdevices/c:"), "../drive_c");
    if (result != 0) {
      write_error(error_buffer, error_buffer_size, "failed to create c: dosdevice link");
      return result;
    }
  }
  {
    const int result = ensure_symlink(join_path(prefix_root, "dosdevices/z:"), "/");
    if (result != 0) {
      write_error(error_buffer, error_buffer_size, "failed to create z: dosdevice link");
      return result;
    }
  }

  write_error(error_buffer, error_buffer_size, "");
  return 0;
}

extern "C" int iridium_wine_ios_validate_userland_root(
  const char* userland_root_path,
  char* error_buffer,
  size_t error_buffer_size
) {
  if (!file_exists(userland_root_path)) {
    write_error(error_buffer, error_buffer_size, "userland root is missing");
    return 1;
  }

  const std::string root(userland_root_path);
  if (!directory_exists(root)) {
    write_error(error_buffer, error_buffer_size, "userland root is not a directory");
    return 2;
  }

  const std::string resolved_wine_binary = find_wine_binary(root);
  if (resolved_wine_binary.empty()) {
    write_error(error_buffer, error_buffer_size, "userland root does not contain a Wine launcher");
    return 3;
  }
  if (find_wineserver_binary(root).empty()) {
    write_error(error_buffer, error_buffer_size, "userland root does not contain wineserver");
    return 4;
  }
  if (!directory_exists(join_path(root, "share/wine"))) {
    write_error(error_buffer, error_buffer_size, "userland root does not contain share/wine");
    return 5;
  }
  if (!file_exists(join_path(root, "share/wine/nls/l_intl.nls"))) {
    write_error(error_buffer, error_buffer_size, "userland root is missing share/wine/nls/l_intl.nls");
    return 10;
  }
  if (!directory_exists(join_path(root, "lib/wine")) && !directory_exists(join_path(root, "lib64/wine"))) {
    write_error(error_buffer, error_buffer_size, "userland root does not contain Wine libraries");
    return 6;
  }

  if (!is_direct_launch_binary_path(resolved_wine_binary)) {
    write_error(error_buffer, error_buffer_size, "userland root does not expose a direct-launch-compatible Wine binary");
    return 7;
  }

  if (require_seed_file(root, "prefix-seed/system.reg", error_buffer, error_buffer_size) != 0 ||
      require_seed_file(root, "prefix-seed/user.reg", error_buffer, error_buffer_size) != 0 ||
      require_seed_file(root, "prefix-seed/userdef.reg", error_buffer, error_buffer_size) != 0) {
    return 8;
  }

  if (validate_seed_file_contents(root, "prefix-seed/system.reg", error_buffer, error_buffer_size) != 0 ||
      validate_seed_file_contents(root, "prefix-seed/user.reg", error_buffer, error_buffer_size) != 0 ||
      validate_seed_file_contents(root, "prefix-seed/userdef.reg", error_buffer, error_buffer_size) != 0) {
    return 9;
  }

  write_error(error_buffer, error_buffer_size, "");
  return 0;
}

extern "C" int iridium_wine_ios_is_blocked_entrypoint(const char* executable_path) {
  if (executable_path == nullptr) {
    return 1;
  }

  const std::string entrypoint = lowercase(filename(executable_path));
  static const std::vector<std::string> blocked = {
    "explorer.exe",
    "cmd.exe",
    "powershell.exe",
    "pwsh.exe",
    "control.exe",
    "start.exe",
    "winebrowser.exe",
    "winemenubuilder.exe",
    "regedit.exe",
    "wordpad.exe",
    "taskmgr.exe",
    "wineboot.exe",
    "msiexec.exe",
    "rundll32.exe",
    "steam.exe",
    "steamservice.exe",
    "epicgameslauncher.exe",
    "origin.exe",
    "uplay.exe",
    "battle.net.exe",
  };

  for (const auto& candidate : blocked) {
    if (entrypoint == candidate) {
      return 1;
    }
  }

  return 0;
}

extern "C" int iridium_wine_ios_bootstrap_direct_launch(
  const char* executable_path,
  const char* prefix_root_path,
  const char* userland_root_path,
  char* resolved_wine_binary_buffer,
  size_t resolved_wine_binary_buffer_size,
  char* error_buffer,
  size_t error_buffer_size
) {
  if (iridium_wine_ios_is_blocked_entrypoint(executable_path) != 0) {
    write_error(error_buffer, error_buffer_size, "blocked entrypoint");
    return 1;
  }

  if (!file_exists(executable_path)) {
    write_error(error_buffer, error_buffer_size, "selected executable is missing");
    return 2;
  }

  const IridiumWineIOSPrefixLayout layout{prefix_root_path};
  const int prefix_result = iridium_wine_ios_prepare_prefix_layout(
    &layout,
    error_buffer,
    error_buffer_size
  );
  if (prefix_result != 0) {
    return prefix_result;
  }

  const int userland_result = iridium_wine_ios_validate_userland_root(
    userland_root_path,
    error_buffer,
    error_buffer_size
  );
  if (userland_result != 0) {
    return userland_result;
  }

  const std::string root(userland_root_path);
  const std::string resolved_wine_binary = find_wine_binary(root);
  const std::string resolved_wineserver_binary = find_wineserver_binary(root);
  const std::string wine_data_directory = join_path(root, "share/wine");
  if (resolved_wine_binary.empty()) {
    write_error(error_buffer, error_buffer_size, "userland root does not expose a launchable Wine binary");
    return 4;
  }
  if (resolved_wineserver_binary.empty()) {
    write_error(error_buffer, error_buffer_size, "userland root does not expose wineserver");
    return 5;
  }

  const int seed_result = hydrate_prefix_seed(prefix_root_path, root, error_buffer, error_buffer_size);
  if (seed_result != 0) {
    return seed_result;
  }
  if (expose_builtin_system32_dlls(prefix_root_path, root, error_buffer, error_buffer_size) != 0) {
    return 6;
  }
  if (configure_prefix_driver_selection(prefix_root_path, error_buffer, error_buffer_size) != 0) {
    return 7;
  }
  const int prefix_validation_result = validate_launch_ready_prefix(prefix_root_path, error_buffer, error_buffer_size);
  if (prefix_validation_result != 0) {
    return prefix_validation_result;
  }

  std::string bridge_config_path;
  PlayableBridgeArtifacts bridge_artifacts;
  const char* runtime_session_identifier = std::getenv("IRIDIUM_RUNTIME_SESSION_ID");
  if (runtime_session_identifier != nullptr && runtime_session_identifier[0] != '\0') {
    const char* surface_identifier = std::getenv("IRIDIUM_WINE_IOS_SURFACE_ID");
    bridge_artifacts.session_identifier = runtime_session_identifier;
    bridge_artifacts.surface_identifier =
      (surface_identifier != nullptr && surface_identifier[0] != '\0')
      ? std::string(surface_identifier)
      : std::string("surface.") + runtime_session_identifier;
    bridge_artifacts.framebuffer_path = string_or_empty(std::getenv("IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH"));
    bridge_artifacts.input_events_path = string_or_empty(std::getenv("IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH"));
    bridge_artifacts.audio_state_path = string_or_empty(std::getenv("IRIDIUM_WINE_IOS_AUDIO_STATE_PATH"));
    bridge_artifacts.surface_width = parse_unsigned_env("IRIDIUM_WINE_IOS_SURFACE_WIDTH");
    bridge_artifacts.surface_height = parse_unsigned_env("IRIDIUM_WINE_IOS_SURFACE_HEIGHT");
    char bridge_config_path_buffer[1024] = {};
    IridiumWineIOSPlayableSessionConfiguration configuration{
      prefix_root_path,
      runtime_session_identifier,
      bridge_artifacts.surface_identifier.c_str(),
      bridge_artifacts.framebuffer_path.c_str(),
      bridge_artifacts.input_events_path.c_str(),
      bridge_artifacts.audio_state_path.c_str(),
      bridge_artifacts.surface_width,
      bridge_artifacts.surface_height,
    };
    if (iridium_wine_ios_configure_playable_session(
          &configuration,
          bridge_config_path_buffer,
          sizeof(bridge_config_path_buffer),
          error_buffer,
          error_buffer_size
        ) != 0) {
      return 8;
    }
    bridge_config_path = bridge_config_path_buffer;
  }

  if (write_direct_launch_env(
        prefix_root_path,
        resolved_wineserver_binary,
        wine_data_directory,
        bridge_config_path,
        bridge_artifacts,
        error_buffer,
        error_buffer_size
      ) != 0) {
    return 9;
  }
  set_launch_environment(
    prefix_root_path,
    resolved_wineserver_binary,
    wine_data_directory,
    bridge_config_path,
    bridge_artifacts
  );
  append_bootstrap_trace(
    launch_winedebug_value(),
    launch_winedebuglog_path(),
    bridge_config_path,
    bridge_artifacts.framebuffer_path
  );

  write_error(resolved_wine_binary_buffer, resolved_wine_binary_buffer_size, resolved_wine_binary);
  write_error(error_buffer, error_buffer_size, "");
  return 0;
}

extern "C" int iridium_wine_ios_configure_playable_session(
  const IridiumWineIOSPlayableSessionConfiguration* configuration,
  char* bridge_config_path_buffer,
  size_t bridge_config_path_buffer_size,
  char* error_buffer,
  size_t error_buffer_size
) {
  if (configuration == nullptr || configuration->prefix_root_path == nullptr
      || configuration->prefix_root_path[0] == '\0'
      || configuration->session_identifier == nullptr
      || configuration->session_identifier[0] == '\0') {
    write_error(error_buffer, error_buffer_size, "missing playable-session configuration");
    return 1;
  }

  const std::string prefixRoot(configuration->prefix_root_path);
  PlayableBridgeArtifacts artifacts;
  artifacts.session_identifier = configuration->session_identifier;
  artifacts.surface_identifier =
    (configuration->surface_identifier != nullptr && configuration->surface_identifier[0] != '\0')
    ? std::string(configuration->surface_identifier)
    : std::string("surface.") + artifacts.session_identifier;
  artifacts.framebuffer_path = string_or_empty(configuration->framebuffer_path);
  artifacts.input_events_path = string_or_empty(configuration->input_events_path);
  artifacts.audio_state_path = string_or_empty(configuration->audio_state_path);
  artifacts.surface_width = configuration->surface_width;
  artifacts.surface_height = configuration->surface_height;

  if (!has_required_bridge_artifacts(artifacts)) {
    write_error(error_buffer, error_buffer_size, "missing playable-session bridge artifacts");
    return 3;
  }

  if (configure_prefix_driver_selection(prefixRoot, error_buffer, error_buffer_size) != 0) {
    return 2;
  }

  return write_playable_session_bridge_config(
    prefixRoot,
    artifacts,
    bridge_config_path_buffer,
    bridge_config_path_buffer_size,
    error_buffer,
    error_buffer_size
  );
}
