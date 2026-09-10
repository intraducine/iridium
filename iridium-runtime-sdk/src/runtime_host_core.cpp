#include "iridium_runtime_host_api.hpp"
#include "iridium_runtime_host_contract.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <mutex>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <crt_externs.h>
#endif

#include "../../iridium-fex-ios/iridium/ios/include/iridium_fex_ios_elf_compat.h"
#include "../../iridium-fex-ios/iridium/ios/include/iridium_fex_ios_bridge.h"
#include "../../iridium-wine-ios/iridium/ios/include/iridium_wine_ios_bridge.h"

namespace
{
    extern "C" void iridium_runtime_host_register_embedded_wine_server_bridge(void);

    bool looks_like_test_harness_name(std::string program_name)
    {
        for (char &character : program_name)
        {
            character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
        }

        return program_name == "xctest"
               || program_name.find("test") != std::string::npos;
    }

    bool allow_test_readiness_overrides()
    {
        const char *explicit_test_harness = std::getenv("IRIDIUM_TEST_HARNESS");
        if (explicit_test_harness != nullptr && explicit_test_harness[0] == '1'
            && explicit_test_harness[1] == '\0')
        {
            return true;
        }

        const char *xctest_config = std::getenv("XCTestConfigurationFilePath");
        if (xctest_config != nullptr && xctest_config[0] != '\0')
        {
            return true;
        }

        const char *xctest_bundle = std::getenv("XCTestBundlePath");
        if (xctest_bundle != nullptr && xctest_bundle[0] != '\0')
        {
            return true;
        }

#if defined(__APPLE__)
        const char *program_name = getprogname();
        if (program_name != nullptr && program_name[0] != '\0')
        {
            return looks_like_test_harness_name(program_name);
        }
#endif

        return false;
    }

    struct HostArguments
    {
        std::string launch_package_path;
        std::string session_update_path;
        std::string terminal_result_path;
        std::string telemetry_path;
        std::string host_log_path;
    };

    struct HostCapabilityRefreshArguments
    {
        std::string runtime_bundle_root_path;
    };

    struct LaunchPackageSummary
    {
        std::string id;
        std::string game_title;
        std::string executable_path;
        std::string working_directory;
        std::string runtime_bundle_root_path;
        std::string environment_file_path;
        bool direct_launch_only = false;
        std::vector<std::string> launch_arguments;
        std::map<std::string, std::string> environment;
    };

    struct DirectLaunchProfile
    {
        bool direct_launch_only = true;
        std::vector<std::string> blocked_entrypoints = {
            "explorer.exe",
            "cmd.exe",
            "powershell.exe",
            "steam.exe",
            "steamservice.exe",
            "epicgameslauncher.exe",
            "origin.exe",
            "uplay.exe",
            "battle.net.exe",
        };
        std::vector<std::string> supported_architectures = {"x64"};
    };

    struct EmbeddedTranslatorReadiness
    {
        bool translator_present = false;
        bool jit_ready = false;
        bool launch_ready = false;
        std::string jit_status;
        std::string launch_status;
        std::string status_summary;
        std::string allocator_backend;
        std::string session_kind;
        std::string failure_stage;
        std::string tool_recommendation;
        bool tool_bootstrap_required = false;
        std::string tool_bootstrap_kind;
        std::string tool_bootstrap_summary;
        bool exception_ports_active = false;
    };

    struct RuntimeSubsystemReadiness
    {
        bool ready = false;
        std::string status;
        std::string status_summary;
    };

    struct EmbeddedExecutionBootstrap
    {
        bool success = false;
        std::string failure_code;
        std::string failure_reason;
        std::string translator_binary;
        std::string userland_root;
        std::string prefix_root;
        std::string resolved_wine_binary;
        std::string jit_status;
        std::string allocator_backend;
        std::string session_kind;
        std::string failure_stage;
        std::string tool_recommendation;
        bool tool_bootstrap_required = false;
        std::string tool_bootstrap_kind;
        std::string tool_bootstrap_summary;
        bool exception_ports_active = false;
        std::string session_identifier;
        std::string running_state;
        std::string running_summary;
        std::string terminal_status;
        std::string terminal_failure_code;
        std::string terminal_failure_reason;
    };

    struct EmbeddedExecutionTerminalResult
    {
        std::string terminal_status;
        std::string terminal_failure_code;
        std::string terminal_failure_reason;
    };

    struct EmbeddedExecutionPollResult
    {
        bool available = false;
        std::string state;
        std::string status_summary;
        bool wine_server_ready = false;
        bool windows_process_started = false;
        bool first_frame_presented = false;
    };

    void write_session_update(
        const HostArguments &arguments,
        const LaunchPackageSummary &package,
        const std::string &state,
        const std::vector<std::string> &state_history,
        const std::string &status_summary,
        const std::string &failure_code,
        const std::string &failure_reason);

    enum class PlayableServiceKind
    {
        render,
        input,
        audio,
    };

    struct PlayableServiceState
    {
        bool live = false;
        std::string handle;
        std::string metadata;
    };

    struct PlayableSessionRegistryState
    {
        bool active = false;
        std::string session_identifier;
        std::string runtime_bundle_root_path;
        std::string host_log_path;
        PlayableServiceState render;
        PlayableServiceState input;
        PlayableServiceState audio;
        bool wine_server_ready = false;
        bool windows_process_started = false;
        bool first_frame_presented = false;
    };

    struct HostTelemetrySnapshot
    {
        bool available = false;
        double average_fps = 0;
        double frame_time_p95_ms = 0;
        double memory_pressure_ratio = 0;
        std::string thermal_state;
    };

    std::mutex playable_session_registry_mutex;
    PlayableSessionRegistryState playable_session_registry;

    struct EnvironmentSnapshotEntry
    {
        std::string key;
        bool had_value = false;
        std::string value;
    };

    class ScopedProcessEnvironmentOverrides
    {
      public:
        explicit ScopedProcessEnvironmentOverrides(
            const std::map<std::string, std::string> &environment)
        {
            snapshots_.reserve(environment.size());

            for (const auto &pair : environment)
            {
                if (!should_override_environment_key(pair.first))
                {
                    continue;
                }

                const char *current_value = std::getenv(pair.first.c_str());
                EnvironmentSnapshotEntry snapshot;
                snapshot.key = pair.first;
                snapshot.had_value = current_value != nullptr;
                snapshot.value = current_value == nullptr ? std::string() : std::string(current_value);
                snapshots_.push_back(snapshot);

                setenv(pair.first.c_str(), pair.second.c_str(), 1);
            }
        }

        ScopedProcessEnvironmentOverrides(const ScopedProcessEnvironmentOverrides &) = delete;
        ScopedProcessEnvironmentOverrides &operator=(const ScopedProcessEnvironmentOverrides &) = delete;

        ~ScopedProcessEnvironmentOverrides()
        {
            for (auto iterator = snapshots_.rbegin(); iterator != snapshots_.rend(); ++iterator)
            {
                if (iterator->had_value)
                {
                    setenv(iterator->key.c_str(), iterator->value.c_str(), 1);
                }
                else
                {
                    unsetenv(iterator->key.c_str());
                }
            }
        }

      private:
        static bool should_override_environment_key(const std::string &key)
        {
            return key == "IRIDIUM_RUNTIME_SESSION_ID"
                   || key == iridium::runtime::kNoDesktopEnvironmentKey
                   || key == "IRIDIUM_SKIP_WINEBOOT_IF_SEEDED"
                   || key == "WINEARCH"
                   || key == "WINEDEBUG"
                   || key == "WINEDEBUGLOG"
                   || key == iridium::runtime::kWineDataDirectoryEnvironmentKey
                   || key == iridium::runtime::kWineHostServerEnvironmentKey
                   || key == "WINEPREFIX"
                   || key == "WINESERVER"
                   || key == iridium::runtime::kWineServerRootEnvironmentKey
                   || key.rfind("IRIDIUM_WINE_IOS_", 0) == 0;
        }

        std::vector<EnvironmentSnapshotEntry> snapshots_;
    };

    std::string lowercase(std::string value);
    bool file_exists(const std::string &path);
    bool directory_exists(const std::string &path);
    std::string detect_embedded_guest_wine_binary(
        const std::string &userland_root,
        std::string *error_message);
    std::string env_lookup(const std::map<std::string, std::string> &environment, const std::string &key);
    bool looks_like_wine_userland_root(const std::string &root_path);
    std::string detect_translator_binary(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment);
    std::string resolve_userland_root(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment,
        const std::string &host_log_path);
    std::string first_existing_path(const std::vector<std::string> &candidates);
    bool parse_double(const std::string &value, double *output);
    bool remove_file_if_exists(const std::string &path);
    std::map<std::string, std::string> current_process_environment();

    struct IOSOpenGLBackendReadiness
    {
        bool ready = false;
        std::string status_summary;
    };

    const char *playable_service_name(PlayableServiceKind kind)
    {
        switch (kind)
        {
        case PlayableServiceKind::render:
            return "render";
        case PlayableServiceKind::input:
            return "input";
        case PlayableServiceKind::audio:
            return "audio";
        }

        return "unknown";
    }

    PlayableServiceState &playable_service_slot(
        PlayableSessionRegistryState &registry,
        PlayableServiceKind kind)
    {
        switch (kind)
        {
        case PlayableServiceKind::render:
            return registry.render;
        case PlayableServiceKind::input:
            return registry.input;
        case PlayableServiceKind::audio:
            return registry.audio;
        }

        return registry.render;
    }

    const PlayableServiceState &playable_service_slot(
        const PlayableSessionRegistryState &registry,
        PlayableServiceKind kind)
    {
        switch (kind)
        {
        case PlayableServiceKind::render:
            return registry.render;
        case PlayableServiceKind::input:
            return registry.input;
        case PlayableServiceKind::audio:
            return registry.audio;
        }

        return registry.render;
    }

    PlayableSessionRegistryState snapshot_playable_session_registry()
    {
        const std::lock_guard<std::mutex> lock(playable_session_registry_mutex);
        return playable_session_registry;
    }

    bool try_record_launch_milestone_locked(
        PlayableSessionRegistryState &registry,
        IridiumRuntimeHostLaunchMilestone milestone)
    {
        bool *slot = nullptr;
        switch (milestone)
        {
        case IRIDIUM_RUNTIME_HOST_MILESTONE_WINE_SERVER_READY:
            slot = &registry.wine_server_ready;
            break;
        case IRIDIUM_RUNTIME_HOST_MILESTONE_WINDOWS_PROCESS_STARTED:
            slot = &registry.windows_process_started;
            break;
        case IRIDIUM_RUNTIME_HOST_MILESTONE_FIRST_FRAME_PRESENTED:
            slot = &registry.first_frame_presented;
            break;
        default:
            return false;
        }

        const bool changed = !*slot;
        *slot = true;
        return changed;
    }

    const char *launch_milestone_name(IridiumRuntimeHostLaunchMilestone milestone)
    {
        switch (milestone)
        {
        case IRIDIUM_RUNTIME_HOST_MILESTONE_WINE_SERVER_READY:
            return "wineServerReady";
        case IRIDIUM_RUNTIME_HOST_MILESTONE_WINDOWS_PROCESS_STARTED:
            return "windowsProcessStarted";
        case IRIDIUM_RUNTIME_HOST_MILESTONE_FIRST_FRAME_PRESENTED:
            return "firstFramePresented";
        }
        return "unknown";
    }

    bool try_parse_playable_service_kind(
        IridiumRuntimeHostPlayableServiceKind raw_kind,
        PlayableServiceKind *parsed_kind)
    {
        if (parsed_kind == nullptr)
        {
            return false;
        }

        switch (raw_kind)
        {
        case IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_RENDER:
            *parsed_kind = PlayableServiceKind::render;
            return true;
        case IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_INPUT:
            *parsed_kind = PlayableServiceKind::input;
            return true;
        case IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_AUDIO:
            *parsed_kind = PlayableServiceKind::audio;
            return true;
        }

        return false;
    }

    std::string json_escape(const std::string &value)
    {
        std::ostringstream stream;
        for (const char ch : value)
        {
            switch (ch)
            {
            case '\\':
                stream << "\\\\";
                break;
            case '"':
                stream << "\\\"";
                break;
            case '\n':
                stream << "\\n";
                break;
            case '\r':
                stream << "\\r";
                break;
            case '\t':
                stream << "\\t";
                break;
            default:
                stream << ch;
                break;
            }
        }
        return stream.str();
    }

    std::string trim_trailing_slashes(std::string path)
    {
        while (path.size() > 1 && path.back() == '/')
        {
            path.pop_back();
        }
        return path;
    }

    std::string parent_path(const std::string &path)
    {
        const std::string normalized = trim_trailing_slashes(path);
        const auto separator = normalized.find_last_of('/');
        if (separator == std::string::npos)
        {
            return "";
        }
        if (separator == 0)
        {
            return "/";
        }
        return normalized.substr(0, separator);
    }

    std::string filename_from_path(const std::string &path)
    {
        const std::string normalized = trim_trailing_slashes(path);
        const auto separator = normalized.find_last_of('/');
        if (separator == std::string::npos)
        {
            return normalized;
        }
        return normalized.substr(separator + 1);
    }

    std::string join_path(const std::string &lhs, const std::string &rhs)
    {
        if (lhs.empty())
        {
            return rhs;
        }
        if (lhs == "/")
        {
            return "/" + rhs;
        }
        if (lhs.back() == '/')
        {
            return lhs + rhs;
        }
        return lhs + "/" + rhs;
    }

    void create_directories(const std::string &path)
    {
        const std::string normalized = trim_trailing_slashes(path);
        if (normalized.empty())
        {
            return;
        }

        std::string current;
        if (normalized.front() == '/')
        {
            current = "/";
        }

        std::stringstream stream(normalized);
        std::string segment;
        while (std::getline(stream, segment, '/'))
        {
            if (segment.empty())
            {
                continue;
            }
            current = join_path(current, segment);
            if (::mkdir(current.c_str(), 0755) != 0 && errno != EEXIST)
            {
                throw std::runtime_error("failed to create directory: " + current);
            }
        }
    }

    std::string read_text(const std::string &path)
    {
        std::ifstream input(path);
        if (!input)
        {
            throw std::runtime_error("failed to open file: " + path);
        }
        std::ostringstream buffer;
        buffer << input.rdbuf();
        return buffer.str();
    }

    void ensure_parent_directory(const std::string &path)
    {
        const auto parent = parent_path(path);
        if (!parent.empty())
        {
            create_directories(parent);
        }
    }

    void write_text(const std::string &path, const std::string &text)
    {
        ensure_parent_directory(path);
        std::ofstream output(path, std::ios::binary | std::ios::trunc);
        if (!output)
        {
            throw std::runtime_error("failed to write file: " + path);
        }
        output << text;
    }

    void append_log(const std::string &path, const std::string &line)
    {
        ensure_parent_directory(path);
        std::ofstream output(path, std::ios::app);
        if (!output)
        {
            throw std::runtime_error("failed to append log: " + path);
        }
        output << line << '\n';
    }

    void append_environment_probe(
        const std::string &host_log_path,
        const std::map<std::string, std::string> &environment,
        const std::string &key)
    {
        const std::string value = env_lookup(environment, key);
        append_log(
            host_log_path,
            "launch-env " + key + "=" + (value.empty() ? std::string("missing") : value));
    }

    std::string json_unescape(const std::string &value)
    {
        std::string unescaped;
        unescaped.reserve(value.size());

        for (std::size_t index = 0; index < value.size(); ++index)
        {
            const char character = value[index];
            if (character != '\\' || index + 1 >= value.size())
            {
                unescaped.push_back(character);
                continue;
            }

            const char escaped = value[++index];
            switch (escaped)
            {
            case '\\':
            case '"':
            case '/':
                unescaped.push_back(escaped);
                break;
            case 'b':
                unescaped.push_back('\b');
                break;
            case 'f':
                unescaped.push_back('\f');
                break;
            case 'n':
                unescaped.push_back('\n');
                break;
            case 'r':
                unescaped.push_back('\r');
                break;
            case 't':
                unescaped.push_back('\t');
                break;
            default:
                unescaped.push_back(escaped);
                break;
            }
        }

        return unescaped;
    }

    std::string extract_json_string(const std::string &json, const std::string &key)
    {
        const std::regex pattern("\"" + key + "\"\\s*:\\s*\"((?:\\\\.|[^\"])*)\"");
        std::smatch match;
        if (!std::regex_search(json, match, pattern) || match.size() < 2)
        {
            throw std::runtime_error("missing JSON string key: " + key);
        }
        return json_unescape(match[1].str());
    }

    bool extract_json_bool(const std::string &json, const std::string &key)
    {
        const std::regex pattern("\"" + key + "\"\\s*:\\s*(true|false)");
        std::smatch match;
        if (!std::regex_search(json, match, pattern) || match.size() < 2)
        {
            throw std::runtime_error("missing JSON bool key: " + key);
        }
        return match[1].str() == "true";
    }

    std::string extract_json_object_body(const std::string &json, const std::string &key)
    {
        const std::regex pattern("\"" + key + "\"\\s*:\\s*\\{((?:[^{}\"]|\"(?:\\\\.|[^\"])*\")*)\\}");
        std::smatch match;
        if (!std::regex_search(json, match, pattern) || match.size() < 2)
        {
            return "";
        }
        return match[1].str();
    }

    std::string extract_json_array_body(const std::string &json, const std::string &key)
    {
        const std::regex pattern("\"" + key + "\"\\s*:\\s*\\[((?:[^\\[\\]\"]|\"(?:\\\\.|[^\"])*\")*)\\]");
        std::smatch match;
        if (!std::regex_search(json, match, pattern) || match.size() < 2)
        {
            return "";
        }
        return match[1].str();
    }

    std::map<std::string, std::string> extract_json_string_map(const std::string &json_object_body)
    {
        std::map<std::string, std::string> values;
        const std::regex pair_pattern("\"((?:\\\\.|[^\"])*)\"\\s*:\\s*\"((?:\\\\.|[^\"])*)\"");
        auto begin = std::sregex_iterator(json_object_body.begin(), json_object_body.end(), pair_pattern);
        const auto end = std::sregex_iterator();

        for (auto iterator = begin; iterator != end; ++iterator)
        {
            values.emplace(
                json_unescape((*iterator)[1].str()),
                json_unescape((*iterator)[2].str()));
        }

        return values;
    }

    std::vector<std::string> extract_json_string_array(const std::string &json_array_body)
    {
        std::vector<std::string> values;
        const std::regex value_pattern("\"((?:\\\\.|[^\"])*)\"");
        auto begin = std::sregex_iterator(json_array_body.begin(), json_array_body.end(), value_pattern);
        const auto end = std::sregex_iterator();

        for (auto iterator = begin; iterator != end; ++iterator)
        {
            values.push_back(json_unescape((*iterator)[1].str()));
        }

        return values;
    }

    bool json_contains_string_key(const std::string &json, const std::string &key)
    {
        const std::regex pattern("\"" + key + "\"\\s*:");
        return std::regex_search(json, pattern);
    }

    HostArguments make_arguments(const iridium::runtime::HostInvocationPaths &invocation)
    {
        auto require = [](const char *path, const char *label) -> std::string
        {
            if (path == nullptr || path[0] == '\0')
            {
                throw std::runtime_error(std::string("missing required invocation path: ") + label);
            }
            return std::string(path);
        };

        HostArguments arguments;
        arguments.launch_package_path = require(invocation.launch_package_path, "launch_package_path");
        arguments.session_update_path = require(invocation.session_update_path, "session_update_path");
        arguments.terminal_result_path = require(invocation.terminal_result_path, "terminal_result_path");
        arguments.telemetry_path = require(invocation.telemetry_path, "telemetry_path");
        arguments.host_log_path = require(invocation.host_log_path, "host_log_path");
        return arguments;
    }

    LaunchPackageSummary parse_launch_package(const std::string &launch_package_path)
    {
        const std::string json = read_text(launch_package_path);
        LaunchPackageSummary summary;
        summary.id = extract_json_string(json, "id");
        summary.game_title = extract_json_string(json, "gameTitle");
        summary.executable_path = extract_json_string(json, "executablePath");
        summary.working_directory = extract_json_string(json, "workingDirectory");
        summary.runtime_bundle_root_path = extract_json_string(json, "runtimeBundleRootPath");
        summary.environment_file_path = extract_json_string(json, "environmentFilePath");
        summary.direct_launch_only = extract_json_bool(json, "directLaunchOnly");
        summary.launch_arguments = extract_json_string_array(extract_json_array_body(json, "launchArguments"));
        summary.environment = extract_json_string_map(extract_json_object_body(json, "environment"));
        return summary;
    }

    std::string lowercase(std::string value)
    {
        for (char &character : value)
        {
            character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
        }
        return value;
    }

    std::string runtime_artifact_path(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment,
        const std::string &environment_key,
        const std::string &relative_path)
    {
        const std::string explicit_path = env_lookup(environment, environment_key);
        if (!explicit_path.empty())
        {
            return explicit_path;
        }

        if (package.runtime_bundle_root_path.empty())
        {
            return "";
        }

        return join_path(package.runtime_bundle_root_path, relative_path);
    }

    DirectLaunchProfile load_direct_launch_profile(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment)
    {
        DirectLaunchProfile profile;
        const std::string profile_path = runtime_artifact_path(
            package,
            environment,
            "IRIDIUM_DIRECT_LAUNCH_PROFILE",
            "Metadata/direct-launch.json");
        if (profile_path.empty() || !file_exists(profile_path))
        {
            return profile;
        }

        try
        {
            const std::string json = read_text(profile_path);
            if (json_contains_string_key(json, "directLaunchOnly"))
            {
                profile.direct_launch_only = extract_json_bool(json, "directLaunchOnly");
            }
            else if (json_contains_string_key(json, "directLaunch"))
            {
                profile.direct_launch_only = extract_json_bool(json, "directLaunch");
            }

            const std::string blocked_body = json_contains_string_key(json, "blockedEntryPoints")
                                                 ? extract_json_array_body(json, "blockedEntryPoints")
                                                 : extract_json_array_body(json, "blockedEntrypoints");
            const auto blocked = extract_json_string_array(blocked_body);
            if (!blocked.empty())
            {
                profile.blocked_entrypoints.clear();
                for (const auto &entry : blocked)
                {
                    profile.blocked_entrypoints.push_back(lowercase(entry));
                }
            }

            const std::string architectures_body = json_contains_string_key(json, "supportsArchitectures")
                                                       ? extract_json_array_body(json, "supportsArchitectures")
                                                       : extract_json_array_body(json, "supportedArchitectures");
            const auto architectures = extract_json_string_array(architectures_body);
            if (!architectures.empty())
            {
                profile.supported_architectures.clear();
                for (const auto &architecture : architectures)
                {
                    profile.supported_architectures.push_back(lowercase(architecture));
                }
            }
        }
        catch (...)
        {
            return profile;
        }

        return profile;
    }

    bool supports_architecture(const DirectLaunchProfile &profile, const std::string &architecture)
    {
        const std::string normalized = lowercase(architecture);
        for (const auto &candidate : profile.supported_architectures)
        {
            if (lowercase(candidate) == normalized)
            {
                return true;
            }
        }
        return false;
    }

    bool is_blocked_entrypoint(const std::string &executable_path, const DirectLaunchProfile &profile)
    {
        const std::string filename = lowercase(filename_from_path(executable_path));
        for (const auto &candidate : profile.blocked_entrypoints)
        {
            if (filename == candidate)
            {
                return true;
            }
        }
        return false;
    }

    double now_reference_seconds()
    {
        using clock = std::chrono::system_clock;
        static constexpr std::int64_t kAppleReferenceOffset = 978307200;
        const auto now = clock::now();
        const auto unix_seconds = std::chrono::duration_cast<std::chrono::duration<double>>(now.time_since_epoch()).count();
        return unix_seconds - static_cast<double>(kAppleReferenceOffset);
    }

    std::string json_number(double value)
    {
        std::ostringstream stream;
        stream << std::fixed << std::setprecision(6) << value;
        return stream.str();
    }

    std::string env_or_default(const char *key, const char *fallback)
    {
        const char *value = std::getenv(key);
        return value == nullptr ? std::string(fallback) : std::string(value);
    }

    bool file_exists(const std::string &path)
    {
        return !path.empty() && access(path.c_str(), F_OK) == 0;
    }

    bool directory_exists(const std::string &path)
    {
        struct stat metadata{};
        return !path.empty() && stat(path.c_str(), &metadata) == 0 && S_ISDIR(metadata.st_mode);
    }

    struct EmbeddedGuestWineLoaderInspection
    {
        bool is_x86_64_elf = false;
        bool has_program_interpreter = false;
        std::string program_interpreter_path;
    };

    bool read_file_bytes_at(const std::string &path, std::uint64_t offset, void *buffer, std::size_t size)
    {
        if (size == 0)
        {
            return true;
        }

        std::ifstream input(path, std::ios::binary);
        if (!input)
        {
            return false;
        }

        input.seekg(static_cast<std::streamoff>(offset));
        if (!input)
        {
            return false;
        }

        input.read(reinterpret_cast<char *>(buffer), static_cast<std::streamsize>(size));
        return static_cast<std::size_t>(input.gcount()) == size;
    }

    bool read_file_prefix(const std::string &path, unsigned char *buffer, std::size_t buffer_size, std::size_t *bytes_read = nullptr)
    {
        std::ifstream input(path, std::ios::binary);
        if (!input)
        {
            if (bytes_read != nullptr)
            {
                *bytes_read = 0;
            }
            return false;
        }

        input.read(reinterpret_cast<char *>(buffer), static_cast<std::streamsize>(buffer_size));
        if (bytes_read != nullptr)
        {
            *bytes_read = static_cast<std::size_t>(input.gcount());
        }
        return input.good() || input.eof();
    }

    bool prefix_matches(const unsigned char *buffer, std::size_t available, const unsigned char *expected, std::size_t expected_size)
    {
        if (available < expected_size)
        {
            return false;
        }
        return std::memcmp(buffer, expected, expected_size) == 0;
    }

    EmbeddedGuestWineLoaderInspection inspect_embedded_guest_wine_loader(const std::string &path)
    {
        EmbeddedGuestWineLoaderInspection inspection;
        Elf64_Ehdr header{};
        if (!read_file_bytes_at(path, 0, &header, sizeof(header)))
        {
            return inspection;
        }

        if (header.e_ident[EI_MAG0] != ELFMAG0 || header.e_ident[EI_MAG1] != ELFMAG1 || header.e_ident[EI_MAG2] != ELFMAG2 || header.e_ident[EI_MAG3] != ELFMAG3 || header.e_ident[EI_CLASS] != ELFCLASS64 || header.e_ident[EI_DATA] != ELFDATA2LSB || header.e_machine != EM_X86_64)
        {
            return inspection;
        }

        inspection.is_x86_64_elf = true;

        if (header.e_phoff == 0 || header.e_phentsize < sizeof(Elf64_Phdr) || header.e_phnum == 0)
        {
            return inspection;
        }

        const std::size_t phdr_entry_size = static_cast<std::size_t>(header.e_phentsize);
        const std::size_t phdr_count = static_cast<std::size_t>(header.e_phnum);
        if (phdr_entry_size > static_cast<std::size_t>(-1) / phdr_count)
        {
            return inspection;
        }

        const std::size_t phdr_table_size = phdr_entry_size * phdr_count;
        std::vector<unsigned char> program_headers(phdr_table_size);
        if (!read_file_bytes_at(path, header.e_phoff, program_headers.data(), phdr_table_size))
        {
            return inspection;
        }

        for (std::size_t index = 0; index < phdr_count; ++index)
        {
            const std::size_t offset = index * phdr_entry_size;
            if (offset + sizeof(Elf64_Phdr) > program_headers.size())
            {
                return inspection;
            }

            Elf64_Phdr program_header{};
            std::memcpy(&program_header, program_headers.data() + offset, sizeof(program_header));
            if (program_header.p_type == PT_INTERP && program_header.p_filesz > 0)
            {
                inspection.has_program_interpreter = true;
                std::vector<char> interpreter(static_cast<std::size_t>(program_header.p_filesz));
                if (read_file_bytes_at(path, program_header.p_offset, interpreter.data(), interpreter.size()))
                {
                    const auto terminator = std::find(interpreter.begin(), interpreter.end(), '\0');
                    inspection.program_interpreter_path.assign(interpreter.begin(), terminator);
                }
                break;
            }
        }

        return inspection;
    }

    std::string absolute_guest_path(const std::string &userland_root, const std::string &guest_path)
    {
        if (!guest_path.empty() && guest_path.front() == '/')
        {
            return join_path(userland_root, guest_path.substr(1));
        }
        return join_path(userland_root, guest_path);
    }

    bool preloader_has_required_companion(
        const std::string &userland_root,
        const std::string &preloader_relative_path)
    {
        const std::string parent = parent_path(preloader_relative_path);
        const std::vector<std::string> companion_names = {"wine", "wine64"};
        for (const auto &companion_name : companion_names)
        {
            const std::string companion_relative_path = parent.empty() ? companion_name : join_path(parent, companion_name);
            const std::string companion_path = join_path(userland_root, companion_relative_path);
            if (!file_exists(companion_path))
            {
                continue;
            }

            const EmbeddedGuestWineLoaderInspection inspection = inspect_embedded_guest_wine_loader(companion_path);
            if (!inspection.is_x86_64_elf)
            {
                continue;
            }

            if (inspection.has_program_interpreter && (inspection.program_interpreter_path.empty() || !file_exists(absolute_guest_path(userland_root, inspection.program_interpreter_path))))
            {
                continue;
            }

            return true;
        }

        return false;
    }

    std::vector<const char *> make_launch_argument_pointers(const LaunchPackageSummary &package)
    {
        std::vector<const char *> pointers;
        pointers.reserve(package.launch_arguments.size());
        for (const auto &argument : package.launch_arguments)
        {
            pointers.push_back(argument.c_str());
        }
        return pointers;
    }

    bool file_is_x86_64_elf(const std::string &path)
    {
        return inspect_embedded_guest_wine_loader(path).is_x86_64_elf;
    }

    bool file_is_embedded_guest_wine_loader(const std::string &path)
    {
        const EmbeddedGuestWineLoaderInspection inspection = inspect_embedded_guest_wine_loader(path);
        return inspection.is_x86_64_elf && !inspection.has_program_interpreter;
    }

    std::string describe_binary_format(const std::string &path)
    {
        unsigned char header[20] = {};
        std::size_t bytes_read = 0;
        if (!read_file_prefix(path, header, sizeof(header), &bytes_read) || bytes_read == 0)
        {
            return "unreadable";
        }

        const EmbeddedGuestWineLoaderInspection inspection = inspect_embedded_guest_wine_loader(path);
        if (inspection.is_x86_64_elf)
        {
            return inspection.has_program_interpreter ? "x86_64 ELF (PT_INTERP)" : "x86_64 ELF";
        }

        static constexpr unsigned char ELF_MAGIC[] = {0x7f, 'E', 'L', 'F'};
        if (prefix_matches(header, bytes_read, ELF_MAGIC, sizeof(ELF_MAGIC)))
        {
            return "non-x86_64 ELF";
        }

        static constexpr unsigned char MACHO_64_LE[] = {0xcf, 0xfa, 0xed, 0xfe};
        static constexpr unsigned char MACHO_64_BE[] = {0xfe, 0xed, 0xfa, 0xcf};
        static constexpr unsigned char MACHO_32_LE[] = {0xce, 0xfa, 0xed, 0xfe};
        static constexpr unsigned char MACHO_32_BE[] = {0xfe, 0xed, 0xfa, 0xce};
        if (prefix_matches(header, bytes_read, MACHO_64_LE, sizeof(MACHO_64_LE)) || prefix_matches(header, bytes_read, MACHO_64_BE, sizeof(MACHO_64_BE)) || prefix_matches(header, bytes_read, MACHO_32_LE, sizeof(MACHO_32_LE)) || prefix_matches(header, bytes_read, MACHO_32_BE, sizeof(MACHO_32_BE)))
        {
            return "Mach-O";
        }

        if (bytes_read >= 2 && header[0] == '#' && header[1] == '!')
        {
            return "script";
        }

        return "unknown format";
    }

    std::string detect_embedded_guest_wine_binary(
        const std::string &userland_root,
        std::string *error_message)
    {
        const std::vector<std::string> candidate_paths = {
            "lib/wine/x86_64-unix/wine-preloader",
            "lib64/wine/x86_64-unix/wine-preloader",
            "lib/wine/x86_64-unix/wine",
            "lib64/wine/x86_64-unix/wine",
            "bin/wine64",
            "bin/wine",
            "wine64",
            "wine",
        };

        std::vector<std::string> incompatible_candidates;
        for (const auto &candidate_relative_path : candidate_paths)
        {
            const std::string candidate = join_path(userland_root, candidate_relative_path);
            if (!file_exists(candidate))
            {
                continue;
            }
            if (file_is_embedded_guest_wine_loader(candidate))
            {
                const std::string candidate_name = filename_from_path(candidate_relative_path);
                if ((candidate_name == "wine-preloader" || candidate_name == "wine64-preloader")
                    && !preloader_has_required_companion(userland_root, candidate_relative_path))
                {
                    if (error_message != nullptr)
                    {
                        *error_message = "Bundled Wine userland wine-preloader requires a sibling Unix Wine loader and its PT_INTERP ELF interpreter.";
                    }
                    return "";
                }
                return candidate;
            }
            incompatible_candidates.push_back(candidate + " (" + describe_binary_format(candidate) + ")");
        }

        if (error_message != nullptr)
        {
            if (!incompatible_candidates.empty())
            {
                std::ostringstream stream;
                stream << "Bundled Wine userland does not expose an embedded-FEX-compatible x86_64 ELF Wine loader without PT_INTERP. Found only ";
                for (std::size_t index = 0; index < incompatible_candidates.size(); ++index)
                {
                    if (index > 0)
                    {
                        stream << ", ";
                    }
                    stream << incompatible_candidates[index];
                }
                stream << ".";
                *error_message = stream.str();
            }
            else
            {
                *error_message = "Bundled Wine userland is missing an embedded-FEX-compatible x86_64 ELF Wine loader without PT_INTERP (expected lib/wine/x86_64-unix/wine-preloader, lib64/wine/x86_64-unix/wine-preloader, lib/wine/x86_64-unix/wine, lib64/wine/x86_64-unix/wine, bin/wine64, bin/wine, wine64, or wine).";
            }
        }

        return "";
    }

    bool env_flag_enabled(const std::map<std::string, std::string> &environment, const std::string &key)
    {
        auto iterator = environment.find(key);
        if (iterator == environment.end())
        {
            return false;
        }

        const std::string value = lowercase(iterator->second);
        return value == "1" || value == "true" || value == "yes";
    }

    bool parse_double(const std::string &value, double *output)
    {
        if (value.empty() || output == nullptr)
        {
            return false;
        }

        char *end = nullptr;
        errno = 0;
        const double parsed = std::strtod(value.c_str(), &end);
        if (errno != 0 || end == value.c_str() || (end != nullptr && *end != '\0'))
        {
            return false;
        }

        *output = parsed;
        return true;
    }

    bool remove_file_if_exists(const std::string &path)
    {
        if (path.empty() || !file_exists(path))
        {
            return true;
        }
        return ::unlink(path.c_str()) == 0 || errno == ENOENT;
    }

    std::string env_lookup(const std::map<std::string, std::string> &environment, const std::string &key)
    {
        auto iterator = environment.find(key);
        if (iterator == environment.end())
        {
            return "";
        }
        return iterator->second;
    }

    std::map<std::string, std::string> current_process_environment()
    {
        std::map<std::string, std::string> values;
#if defined(__APPLE__)
        char **process_environment = *_NSGetEnviron();
#else
        extern char **environ;
        char **process_environment = environ;
#endif

        if (process_environment == nullptr)
        {
            return values;
        }

        for (char **entry = process_environment; *entry != nullptr; ++entry)
        {
            const std::string raw(*entry);
            const auto separator = raw.find('=');
            if (separator == std::string::npos)
            {
                continue;
            }
            values.emplace(raw.substr(0, separator), raw.substr(separator + 1));
        }

        return values;
    }

    std::map<std::string, std::string> load_environment_file(const std::string &path)
    {
        std::map<std::string, std::string> values;
        if (!file_exists(path))
        {
            return values;
        }

        std::stringstream stream(read_text(path));
        std::string line;
        while (std::getline(stream, line))
        {
            const auto separator = line.find('=');
            if (separator == std::string::npos)
            {
                continue;
            }
            values.emplace(line.substr(0, separator), line.substr(separator + 1));
        }

        return values;
    }

    std::map<std::string, std::string> merged_launch_environment(const LaunchPackageSummary &package)
    {
        std::map<std::string, std::string> environment = current_process_environment();

        for (const auto &pair : load_environment_file(package.environment_file_path))
        {
            environment[pair.first] = pair.second;
        }

        for (const auto &pair : package.environment)
        {
            environment[pair.first] = pair.second;
        }

        return environment;
    }

    std::string detect_prefix_root(const std::map<std::string, std::string> &environment)
    {
        return env_lookup(environment, "WINEPREFIX");
    }

    bool ensure_prefix_layout(const std::string &prefix_root, std::string *error_message)
    {
        if (prefix_root.empty())
        {
            if (error_message != nullptr)
            {
                *error_message = "Wine prefix root is missing from the launch environment.";
            }
            return false;
        }

        char error_buffer[512] = {};
        const IridiumWineIOSPrefixLayout layout{
            prefix_root.c_str()};
        const int result = iridium_wine_ios_prepare_prefix_layout(
            &layout,
            error_buffer,
            sizeof(error_buffer));
        if (result == 0)
        {
            return true;
        }

        if (error_message != nullptr)
        {
            *error_message = error_buffer[0] == '\0'
                                 ? "Failed to prepare Wine prefix layout."
                                 : std::string(error_buffer);
        }
        return false;
    }

    bool validate_userland_root(
        const std::string &userland_root,
        std::string *resolved_wine_binary,
        std::string *error_message)
    {
        char error_buffer[512] = {};
        const int result = iridium_wine_ios_validate_userland_root(
            userland_root.c_str(),
            error_buffer,
            sizeof(error_buffer));
        if (result != 0)
        {
            if (error_message != nullptr)
            {
                *error_message = error_buffer[0] == '\0'
                                     ? "Bundled Wine userland is missing or does not expose a direct-launch-compatible Wine binary."
                                     : std::string(error_buffer);
            }
            return false;
        }

        const std::string wine_binary = detect_embedded_guest_wine_binary(userland_root, error_message);
        if (wine_binary.empty())
        {
            return false;
        }

        if (resolved_wine_binary != nullptr)
        {
            *resolved_wine_binary = wine_binary;
        }
        return true;
    }

    std::string resolve_jit_status(const std::map<std::string, std::string> &environment)
    {
        const std::string explicit_status = env_lookup(environment, "IRIDIUM_HOST_JIT_STATUS");
        if (!explicit_status.empty())
        {
            return explicit_status;
        }

        if (!allow_test_readiness_overrides())
        {
            return "required";
        }

        return env_or_default("IRIDIUM_HOST_JIT_STATUS", "required");
    }

    EmbeddedTranslatorReadiness probe_embedded_translator(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment)
    {
        EmbeddedTranslatorReadiness readiness;
        const std::string translator_binary = detect_translator_binary(package, environment);
        IridiumFEXIOSReadiness bridge_readiness{};
        if (iridium_fex_ios_probe_readiness(
                translator_binary.c_str(),
                resolve_jit_status(environment).c_str(),
                &bridge_readiness) == 0)
        {
            readiness.translator_present = bridge_readiness.translator_present != 0;
            readiness.jit_ready = bridge_readiness.jit_ready != 0;
            readiness.launch_ready = bridge_readiness.launch_ready != 0;
            readiness.jit_status = bridge_readiness.jit_status == nullptr
                                       ? std::string()
                                       : std::string(bridge_readiness.jit_status);
            readiness.launch_status = bridge_readiness.launch_status == nullptr
                                          ? std::string()
                                          : std::string(bridge_readiness.launch_status);
            readiness.status_summary = bridge_readiness.status_summary == nullptr
                                           ? std::string()
                                           : std::string(bridge_readiness.status_summary);
            readiness.allocator_backend = bridge_readiness.allocator_backend == nullptr
                                              ? std::string()
                                              : std::string(bridge_readiness.allocator_backend);
            readiness.session_kind = bridge_readiness.jit_session_kind == nullptr
                                         ? std::string()
                                         : std::string(bridge_readiness.jit_session_kind);
            readiness.failure_stage = bridge_readiness.jit_failure_stage == nullptr
                                          ? std::string()
                                          : std::string(bridge_readiness.jit_failure_stage);
            readiness.tool_recommendation = bridge_readiness.jit_tool_recommendation == nullptr
                                                ? std::string()
                                                : std::string(bridge_readiness.jit_tool_recommendation);
            readiness.tool_bootstrap_required = bridge_readiness.tool_bootstrap_required != 0;
            readiness.tool_bootstrap_kind = bridge_readiness.tool_bootstrap_kind == nullptr
                                                ? std::string()
                                                : std::string(bridge_readiness.tool_bootstrap_kind);
            readiness.tool_bootstrap_summary = bridge_readiness.tool_bootstrap_summary == nullptr
                                                   ? std::string()
                                                   : std::string(bridge_readiness.tool_bootstrap_summary);
            readiness.exception_ports_active = bridge_readiness.exception_ports_active != 0;
        }
        return readiness;
    }

    bool validate_embedded_launch_paths(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment,
        std::string *error_message)
    {
        const std::string translator_binary = detect_translator_binary(package, environment);
        if (!file_exists(translator_binary))
        {
            if (error_message != nullptr)
            {
                *error_message = "Bundled x64 translator artifact is missing.";
            }
            return false;
        }

        if (!file_exists(package.executable_path))
        {
            if (error_message != nullptr)
            {
                *error_message = "Selected executable is missing from managed storage.";
            }
            return false;
        }

        if (!file_exists(package.environment_file_path))
        {
            if (error_message != nullptr)
            {
                *error_message = "Runtime environment file is missing for the prepared prefix.";
            }
            return false;
        }

        if (package.runtime_bundle_root_path.empty() || !directory_exists(package.runtime_bundle_root_path))
        {
            if (error_message != nullptr)
            {
                *error_message = "Runtime bundle root is missing for embedded execution.";
            }
            return false;
        }

        const std::string prefix_root = detect_prefix_root(environment);
        if (!ensure_prefix_layout(prefix_root, error_message))
        {
            return false;
        }

        char error_buffer[512] = {};
        const std::vector<const char *> launch_argument_pointers = make_launch_argument_pointers(package);
        const IridiumFEXIOSLaunchPaths launch_paths{
            translator_binary.c_str(),
            package.executable_path.c_str(),
            package.runtime_bundle_root_path.c_str(),
            prefix_root.c_str(),
            package.environment_file_path.c_str(),
            "direct",
            "win64",
            launch_argument_pointers.empty() ? nullptr : launch_argument_pointers.data(),
            launch_argument_pointers.size()};
        const int validation_result = iridium_fex_ios_validate_launch(
            &launch_paths,
            error_buffer,
            sizeof(error_buffer));
        if (validation_result != 0)
        {
            if (error_message != nullptr)
            {
                *error_message = error_buffer[0] == '\0'
                                     ? "Embedded translator rejected the launch package."
                                     : std::string(error_buffer);
            }
            return false;
        }

        return true;
    }

    EmbeddedExecutionBootstrap bootstrap_embedded_execution(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment,
        const std::string &host_log_path)
    {
        EmbeddedExecutionBootstrap bootstrap;
        bootstrap.translator_binary = detect_translator_binary(package, environment);
        bootstrap.userland_root = resolve_userland_root(package, environment, host_log_path);
        bootstrap.prefix_root = detect_prefix_root(environment);

        const EmbeddedTranslatorReadiness readiness = probe_embedded_translator(package, environment);
        bootstrap.jit_status = readiness.jit_status.empty()
                                   ? resolve_jit_status(environment)
                                   : readiness.jit_status;
        bootstrap.allocator_backend = readiness.allocator_backend.empty()
                                          ? std::string("none")
                                          : readiness.allocator_backend;
        bootstrap.session_kind = readiness.session_kind.empty()
                                     ? std::string("none")
                                     : readiness.session_kind;
        bootstrap.failure_stage = readiness.failure_stage;
        bootstrap.tool_recommendation = readiness.tool_recommendation.empty()
                                            ? std::string("none")
                                            : readiness.tool_recommendation;
        bootstrap.tool_bootstrap_required = readiness.tool_bootstrap_required;
        bootstrap.tool_bootstrap_kind = readiness.tool_bootstrap_kind;
        bootstrap.tool_bootstrap_summary = readiness.tool_bootstrap_summary;
        bootstrap.exception_ports_active = readiness.exception_ports_active;
        if (!validate_embedded_launch_paths(package, environment, &bootstrap.failure_reason))
        {
            bootstrap.failure_code = "runtimeBootFailed";
            return bootstrap;
        }

        if (!validate_userland_root(bootstrap.userland_root, &bootstrap.resolved_wine_binary, &bootstrap.failure_reason))
        {
            bootstrap.failure_code = "runtimeBootFailed";
            return bootstrap;
        }

        if (!readiness.translator_present)
        {
            bootstrap.failure_code = "runtimeBootFailed";
            bootstrap.failure_reason = "Bundled x64 translator artifact is missing.";
            return bootstrap;
        }

        if (!readiness.jit_ready)
        {
            bootstrap.failure_code = "jitNotReady";
            bootstrap.failure_reason = readiness.status_summary.empty()
                                           ? "JIT must be enabled externally before the embedded translator can execute."
                                           : readiness.status_summary;
            return bootstrap;
        }

        std::map<std::string, std::string> process_environment_values = environment;
        if (process_environment_values.find(iridium::runtime::kWineDataDirectoryEnvironmentKey)
                == process_environment_values.end())
        {
            process_environment_values[iridium::runtime::kWineDataDirectoryEnvironmentKey] =
                join_path(bootstrap.userland_root, "share/wine");
        }
        process_environment_values[iridium::runtime::kWineHostServerEnvironmentKey] = "embedded";

        char wine_binary_buffer[1024] = {};
        char wine_error_buffer[512] = {};
        const ScopedProcessEnvironmentOverrides process_environment(process_environment_values);
        const int wine_bootstrap_result = iridium_wine_ios_bootstrap_direct_launch(
            package.executable_path.c_str(),
            bootstrap.prefix_root.c_str(),
            bootstrap.userland_root.c_str(),
            wine_binary_buffer,
            sizeof(wine_binary_buffer),
            wine_error_buffer,
            sizeof(wine_error_buffer));
        if (wine_bootstrap_result != 0)
        {
            bootstrap.failure_code = "runtimeBootFailed";
            bootstrap.failure_reason = wine_error_buffer[0] == '\0'
                                           ? "Bundled Wine runtime rejected the direct-launch bootstrap."
                                           : std::string(wine_error_buffer);
            return bootstrap;
        }
        bootstrap.resolved_wine_binary = wine_binary_buffer;

        char session_identifier_buffer[256] = {};
        char translator_error_buffer[512] = {};
        const std::vector<const char *> launch_argument_pointers = make_launch_argument_pointers(package);
        const IridiumFEXIOSLaunchPaths launch_paths{
            bootstrap.translator_binary.c_str(),
            package.executable_path.c_str(),
            package.runtime_bundle_root_path.c_str(),
            bootstrap.prefix_root.c_str(),
            package.environment_file_path.c_str(),
            "direct",
            "win64",
            launch_argument_pointers.empty() ? nullptr : launch_argument_pointers.data(),
            launch_argument_pointers.size()};
        iridium_runtime_host_register_embedded_wine_server_bridge();
        const int translator_start_result = iridium_fex_ios_start_guest_execution(
            &launch_paths,
            bootstrap.jit_status.c_str(),
            session_identifier_buffer,
            sizeof(session_identifier_buffer),
            translator_error_buffer,
            sizeof(translator_error_buffer));
        if (translator_start_result != 0)
        {
            bootstrap.failure_code = translator_start_result == IRIDIUM_FEX_IOS_STATUS_JIT_NOT_READY ? "jitNotReady" : "runtimeBootFailed";
            bootstrap.failure_reason = translator_error_buffer[0] == '\0'
                                           ? "Embedded translator rejected the launch package."
                                           : std::string(translator_error_buffer);
            return bootstrap;
        }
        bootstrap.session_identifier = session_identifier_buffer;

        IridiumFEXIOSExecutionPoll execution_poll{};
        if (iridium_fex_ios_poll_guest_state(
                bootstrap.session_identifier.c_str(),
                &execution_poll) == 0)
        {
            if (execution_poll.state != nullptr)
            {
                bootstrap.running_state = execution_poll.state;
            }
            if (execution_poll.status_summary != nullptr)
            {
                bootstrap.running_summary = execution_poll.status_summary;
            }
        }

        if (bootstrap.session_identifier.empty() || bootstrap.session_identifier == "embedded-fex-session")
        {
            bootstrap.failure_code = "runtimeBootFailed";
            bootstrap.failure_reason = "Embedded translator returned a placeholder session identifier.";
            return bootstrap;
        }

        bootstrap.success = true;
        return bootstrap;
    }

    EmbeddedExecutionTerminalResult collect_embedded_execution_terminal_result(
        const std::string &session_identifier,
        const std::map<std::string, std::string> &environment)
    {
        EmbeddedExecutionTerminalResult terminal_result;
        IridiumFEXIOSExecutionResult execution_result{};
        const bool allow_synthetic_terminal = env_flag_enabled(
            environment,
            "IRIDIUM_HOST_ALLOW_SYNTHETIC_TERMINAL_STATUS");
        const std::string terminal_override = allow_synthetic_terminal
                                                  ? env_lookup(environment, "IRIDIUM_HOST_TERMINAL_STATUS")
                                                  : "";
        if (iridium_fex_ios_collect_guest_exit(
                session_identifier.c_str(),
                terminal_override.empty() ? nullptr : terminal_override.c_str(),
                &execution_result) == 0)
        {
            if (execution_result.terminal_state != nullptr)
            {
                terminal_result.terminal_status = execution_result.terminal_state;
            }
            if (execution_result.failure_code != nullptr)
            {
                terminal_result.terminal_failure_code = execution_result.failure_code;
            }
            if (execution_result.failure_reason != nullptr)
            {
                terminal_result.terminal_failure_reason = execution_result.failure_reason;
            }
        }
        else
        {
            terminal_result.terminal_status = "failed";
            terminal_result.terminal_failure_code = "runtimeBootFailed";
            terminal_result.terminal_failure_reason = "Embedded translator did not emit a terminal result.";
        }

        if (terminal_result.terminal_status.empty())
        {
            terminal_result.terminal_status = "failed";
            terminal_result.terminal_failure_code = "runtimeBootFailed";
            terminal_result.terminal_failure_reason = "Embedded translator did not emit a terminal state.";
        }

        return terminal_result;
    }

    EmbeddedExecutionPollResult poll_embedded_execution_state(const std::string &session_identifier)
    {
        EmbeddedExecutionPollResult result;
        IridiumFEXIOSExecutionPoll execution_poll{};
        if (iridium_fex_ios_poll_guest_state(session_identifier.c_str(), &execution_poll) != 0)
        {
            return result;
        }

        result.available = true;
        if (execution_poll.state != nullptr)
        {
            result.state = execution_poll.state;
        }
        if (execution_poll.status_summary != nullptr)
        {
            result.status_summary = execution_poll.status_summary;
        }
        result.wine_server_ready = execution_poll.wine_server_ready != 0;
        result.windows_process_started = execution_poll.windows_process_started != 0;
        result.first_frame_presented = execution_poll.first_frame_presented != 0;
        return result;
    }

    bool embedded_poll_state_is_terminal(const std::string &state)
    {
        return state == "completed" || state == "failed";
    }

    std::string host_session_state_for_embedded_poll(const std::string &state)
    {
        if (state == "completed" || state == "failed")
        {
            return state;
        }
        if (state == "executing" || state == "running" || state == "stopping")
        {
            return "running";
        }
        return "bootingRuntime";
    }

    std::vector<std::string> host_session_history_for_embedded_poll(const std::string &state)
    {
        if (state == "completed")
        {
            return {"queued", "bootstrappingPrefix", "bootingRuntime", "running", "completed"};
        }
        if (state == "failed")
        {
            return {"queued", "bootstrappingPrefix", "bootingRuntime", "running", "failed"};
        }
        if (state == "executing" || state == "running" || state == "stopping")
        {
            return {"queued", "bootstrappingPrefix", "bootingRuntime", "running"};
        }
        return {"queued", "bootstrappingPrefix", "bootingRuntime"};
    }

    EmbeddedExecutionTerminalResult monitor_embedded_execution_until_terminal(
        const HostArguments &arguments,
        const LaunchPackageSummary &package,
        const std::string &session_identifier,
        const std::map<std::string, std::string> &environment)
    {
        EmbeddedExecutionPollResult last_reported_poll;
        while (true)
        {
            const EmbeddedExecutionPollResult poll = poll_embedded_execution_state(session_identifier);
            if (poll.available)
            {
                const bool changed = !last_reported_poll.available
                                     || poll.state != last_reported_poll.state
                                     || poll.status_summary != last_reported_poll.status_summary
                                     || poll.wine_server_ready != last_reported_poll.wine_server_ready
                                     || poll.windows_process_started != last_reported_poll.windows_process_started
                                     || poll.first_frame_presented != last_reported_poll.first_frame_presented;
                if (changed)
                {
                    append_log(
                        arguments.host_log_path,
                        "embedded-state=" + (poll.state.empty() ? std::string("unknown") : poll.state)
                            + " summary=" + (poll.status_summary.empty() ? std::string("none") : poll.status_summary));
                    if (poll.wine_server_ready && !last_reported_poll.wine_server_ready)
                    {
                        iridium::runtime::RecordLaunchMilestone(
                            session_identifier.c_str(),
                            IRIDIUM_RUNTIME_HOST_MILESTONE_WINE_SERVER_READY);
                    }
                    if (poll.windows_process_started && !last_reported_poll.windows_process_started)
                    {
                        iridium::runtime::RecordLaunchMilestone(
                            session_identifier.c_str(),
                            IRIDIUM_RUNTIME_HOST_MILESTONE_WINDOWS_PROCESS_STARTED);
                    }
                    if (embedded_poll_state_is_terminal(poll.state))
                    {
                        return collect_embedded_execution_terminal_result(session_identifier, environment);
                    }
                    write_session_update(
                        arguments,
                        package,
                        host_session_state_for_embedded_poll(poll.state),
                        host_session_history_for_embedded_poll(poll.state),
                        poll.status_summary.empty()
                            ? "Embedded FEX guest execution is active."
                            : poll.status_summary,
                        "",
                        "");
                    last_reported_poll = poll;
                }
            }
            else if (!last_reported_poll.available)
            {
                append_log(arguments.host_log_path, "embedded-state=unavailable");
                last_reported_poll.available = true;
            }

            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    }

    std::string first_existing_path(const std::vector<std::string> &candidates)
    {
        for (const auto &candidate : candidates)
        {
            if (file_exists(candidate))
            {
                return candidate;
            }
        }
        return "";
    }

    std::string detect_wine_binary(const std::map<std::string, std::string> &environment)
    {
        const std::string explicit_binary = env_lookup(environment, "IRIDIUM_EXTERNAL_WINE_BINARY");
        if (!explicit_binary.empty())
        {
            return explicit_binary;
        }

        const std::string explicit_runtime_binary = env_lookup(environment, "IRIDIUM_WINE_BINARY");
        if (!explicit_runtime_binary.empty())
        {
            return explicit_runtime_binary;
        }

        const std::string userland_root =
            env_lookup(environment, iridium::runtime::kUserlandRootEnvironmentKey);
        if (!userland_root.empty())
        {
            const auto bundled_binary = first_existing_path({
                join_path(userland_root, "bin/wine64"),
                join_path(userland_root, "bin/wine"),
                join_path(userland_root, "wine64"),
                join_path(userland_root, "wine"),
                join_path(userland_root, "Contents/MacOS/wine"),
                join_path(userland_root, "Contents/Resources/wine/bin/wine64"),
                join_path(userland_root, "Contents/Resources/wine/bin/wine"),
            });
            if (!bundled_binary.empty())
            {
                return bundled_binary;
            }
        }

        return "";
    }

    std::string detect_translator_binary(const std::map<std::string, std::string> &environment)
    {
        const auto external = env_lookup(environment, "IRIDIUM_EXTERNAL_TRANSLATOR_BINARY");
        if (!external.empty())
        {
            return external;
        }
        return env_lookup(environment, "IRIDIUM_TRANSLATOR_BINARY");
    }

    std::string detect_translator_binary(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment)
    {
        const std::string detected = detect_translator_binary(environment);
        if (!detected.empty())
        {
            return detected;
        }
        return runtime_artifact_path(
            package,
            environment,
            "IRIDIUM_TRANSLATOR_BINARY",
            "Translator/x64-jit.bin");
    }

    std::string detect_userland_archive(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment)
    {
        return runtime_artifact_path(
            package,
            environment,
            "IRIDIUM_USERLAND_ARCHIVE",
            "Userland/wine-userland.tar.zst");
    }

    std::string detect_bundle_manifest_path(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment)
    {
        return runtime_artifact_path(
            package,
            environment,
            "IRIDIUM_RUNTIME_BUNDLE_MANIFEST",
            "manifest.json");
    }

    std::string detect_bundle_version(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment)
    {
        const std::string manifest_path = detect_bundle_manifest_path(package, environment);
        if (manifest_path.empty() || !file_exists(manifest_path))
        {
            return "";
        }

        try
        {
            return extract_json_string(read_text(manifest_path), "version");
        }
        catch (...)
        {
            return "";
        }
    }

    bool looks_like_wine_userland_root(const std::string &root_path)
    {
        if (!directory_exists(root_path))
        {
            return false;
        }

        return !first_existing_path({
                                        join_path(root_path, "bin/wine64"),
                                        join_path(root_path, "bin/wine"),
                                        join_path(root_path, "wine64"),
                                        join_path(root_path, "wine"),
                                        join_path(root_path, "Contents/MacOS/wine"),
                                        join_path(root_path, "Contents/Resources/wine/bin/wine64"),
                                        join_path(root_path, "Contents/Resources/wine/bin/wine"),
                                    })
                    .empty();
    }

    bool clear_directory_tree(const std::string &path, const std::string &host_log_path)
    {
        if (path.empty() || !file_exists(path))
        {
            return true;
        }

        const std::string rm_binary = first_existing_path({"/bin/rm",
                                                           "/usr/bin/rm"});
        if (rm_binary.empty())
        {
            append_log(host_log_path, "userland-unpack=cleanup-missing-rm");
            return false;
        }

        std::vector<std::string> argv_storage = {
            rm_binary,
            "-rf",
            path};
        std::vector<char *> argv;
        for (auto &argument : argv_storage)
        {
            argv.push_back(const_cast<char *>(argument.c_str()));
        }
        argv.push_back(nullptr);

        std::vector<std::string> env_storage;
#if defined(__APPLE__)
        char **process_environment = *_NSGetEnviron();
#else
        extern char **environ;
        char **process_environment = environ;
#endif
        if (process_environment != nullptr)
        {
            for (char **entry = process_environment; *entry != nullptr; ++entry)
            {
                env_storage.emplace_back(*entry);
            }
        }

        std::vector<char *> envp;
        for (auto &entry : env_storage)
        {
            envp.push_back(const_cast<char *>(entry.c_str()));
        }
        envp.push_back(nullptr);

        pid_t child_pid = 0;
        const int spawn_result = posix_spawn(
            &child_pid,
            rm_binary.c_str(),
            nullptr,
            nullptr,
            argv.data(),
            envp.data());
        if (spawn_result != 0)
        {
            append_log(host_log_path, "userland-unpack=cleanup-spawn-failed");
            return false;
        }

        int status = 0;
        if (waitpid(child_pid, &status, 0) < 0)
        {
            append_log(host_log_path, "userland-unpack=cleanup-waitpid-failed");
            return false;
        }

        if (!(WIFEXITED(status) && WEXITSTATUS(status) == 0))
        {
            append_log(host_log_path, "userland-unpack=cleanup-failed");
            return false;
        }

        append_log(host_log_path, "userland-unpack=cleanup-ok");
        return true;
    }

    bool unpack_userland_archive(
        const std::string &archive_path,
        const std::string &destination_root,
        const std::string &host_log_path)
    {
        if (archive_path.empty() || !file_exists(archive_path) || destination_root.empty())
        {
            return false;
        }

        create_directories(destination_root);

        const std::string tar_binary = first_existing_path({"/usr/bin/tar",
                                                            "/bin/tar"});
        if (tar_binary.empty())
        {
            append_log(host_log_path, "userland-unpack=missing-tar");
            return false;
        }

        std::vector<std::string> env_storage;
#if defined(__APPLE__)
        char **process_environment = *_NSGetEnviron();
#else
        extern char **environ;
        char **process_environment = environ;
#endif
        if (process_environment != nullptr)
        {
            for (char **entry = process_environment; *entry != nullptr; ++entry)
            {
                env_storage.emplace_back(*entry);
            }
        }

        std::vector<char *> envp;
        for (auto &entry : env_storage)
        {
            envp.push_back(const_cast<char *>(entry.c_str()));
        }
        envp.push_back(nullptr);

        const bool prefers_zstd_tar = archive_path.size() >= 8 &&
                                      archive_path.compare(archive_path.size() - 8, 8, ".tar.zst") == 0;
        const std::vector<std::vector<std::string>> argv_attempts = prefers_zstd_tar
                                                                        ? std::vector<std::vector<std::string>>{
                                                                              {tar_binary, "--zstd", "-xf", archive_path, "-C", destination_root},
                                                                              {tar_binary, "-xf", archive_path, "-C", destination_root},
                                                                          }
                                                                        : std::vector<std::vector<std::string>>{
                                                                              {tar_binary, "-xf", archive_path, "-C", destination_root},
                                                                          };

        for (size_t index = 0; index < argv_attempts.size(); ++index)
        {
            auto argv_storage = argv_attempts[index];
            std::vector<char *> argv;
            for (auto &argument : argv_storage)
            {
                argv.push_back(const_cast<char *>(argument.c_str()));
            }
            argv.push_back(nullptr);

            if (prefers_zstd_tar)
            {
                append_log(host_log_path, index == 0 ? "userland-unpack=try-zstd" : "userland-unpack=retry-plain");
            }

            posix_spawn_file_actions_t file_actions;
            posix_spawn_file_actions_init(&file_actions);
            posix_spawn_file_actions_addopen(
                &file_actions,
                STDOUT_FILENO,
                "/dev/null",
                O_WRONLY,
                0);
            posix_spawn_file_actions_addopen(
                &file_actions,
                STDERR_FILENO,
                "/dev/null",
                O_WRONLY,
                0);

            pid_t child_pid = 0;
            const int spawn_result = posix_spawn(
                &child_pid,
                tar_binary.c_str(),
                &file_actions,
                nullptr,
                argv.data(),
                envp.data());
            posix_spawn_file_actions_destroy(&file_actions);
            if (spawn_result != 0)
            {
                append_log(host_log_path, "userland-unpack=spawn-failed");
                continue;
            }

            int status = 0;
            if (waitpid(child_pid, &status, 0) < 0)
            {
                append_log(host_log_path, "userland-unpack=waitpid-failed");
                continue;
            }

            const bool succeeded = WIFEXITED(status) && WEXITSTATUS(status) == 0;
            if (succeeded)
            {
                append_log(host_log_path, "userland-unpack=ok");
                return true;
            }
        }

        append_log(host_log_path, "userland-unpack=failed");
        return false;
    }

    std::string userland_version_stamp_path(const std::string &extracted_root)
    {
        return join_path(extracted_root, ".iridium-userland-version");
    }

    std::string resolve_userland_root(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment,
        const std::string &host_log_path)
    {
        const std::string explicit_root =
            env_lookup(environment, iridium::runtime::kUserlandRootEnvironmentKey);
        if (!explicit_root.empty())
        {
            return explicit_root;
        }

        if (package.runtime_bundle_root_path.empty())
        {
            return "";
        }

        const std::string support_root = join_path(package.runtime_bundle_root_path, "Support/wine-userland");
        if (looks_like_wine_userland_root(support_root))
        {
            return support_root;
        }

        const std::string bundled_root = join_path(package.runtime_bundle_root_path, "Userland/root");

        const std::string archive_path = detect_userland_archive(package, environment);
        const std::string extracted_root = join_path(package.runtime_bundle_root_path, "Userland/extracted");
        const std::string bundle_version = detect_bundle_version(package, environment);
        const std::string version_stamp_path = userland_version_stamp_path(extracted_root);

        if (directory_exists(extracted_root) && looks_like_wine_userland_root(extracted_root))
        {
            if (bundle_version.empty() || !file_exists(version_stamp_path))
            {
                return extracted_root;
            }

            try
            {
                if (read_text(version_stamp_path) == bundle_version)
                {
                    append_log(host_log_path, "userland-unpack=reused");
                    return extracted_root;
                }
            }
            catch (...)
            {
            }
        }

        if (!clear_directory_tree(extracted_root, host_log_path))
        {
            return "";
        }

        if (unpack_userland_archive(archive_path, extracted_root, host_log_path))
        {
            if (!bundle_version.empty())
            {
                try
                {
                    write_text(version_stamp_path, bundle_version);
                }
                catch (...)
                {
                }
            }
            return extracted_root;
        }

        if (looks_like_wine_userland_root(bundled_root))
        {
            append_log(host_log_path, "userland-unpack=fallback-bundled-root");
            return bundled_root;
        }

        return "";
    }

    std::string managed_root_from_bundle_root(const std::string &runtime_bundle_root_path)
    {
        return parent_path(parent_path(runtime_bundle_root_path));
    }

    std::string resolve_optional_capability(
        const std::map<std::string, std::string> &environment,
        const std::string &key,
        const char *fallback_key)
    {
        const std::string explicit_value = env_lookup(environment, key);
        if (!explicit_value.empty())
        {
            return explicit_value;
        }

        const char *process_value = std::getenv(fallback_key);
        return process_value == nullptr ? std::string() : std::string(process_value);
    }

    RuntimeSubsystemReadiness make_subsystem_readiness(
        bool ready,
        std::string status,
        std::string status_summary)
    {
        RuntimeSubsystemReadiness readiness;
        readiness.ready = ready;
        readiness.status = std::move(status);
        readiness.status_summary = std::move(status_summary);
        return readiness;
    }

    RuntimeSubsystemReadiness resolve_subsystem_override(
        const std::map<std::string, std::string> &environment,
        const std::string &key_prefix,
        const RuntimeSubsystemReadiness &fallback,
        const char *ready_summary)
    {
        if (!allow_test_readiness_overrides())
        {
            return fallback;
        }

        const std::string status_key = key_prefix + "_STATUS";
        const std::string summary_key = key_prefix + "_SUMMARY";
        const std::string ready_key = key_prefix + "_READY";
        const std::string status_override = resolve_optional_capability(
            environment,
            status_key,
            status_key.c_str());
        const std::string summary_override = resolve_optional_capability(
            environment,
            summary_key,
            summary_key.c_str());
        const bool ready_override = env_flag_enabled(environment, ready_key);

        if (!status_override.empty() || !summary_override.empty() || ready_override)
        {
            RuntimeSubsystemReadiness readiness;
            readiness.ready = ready_override;
            readiness.status = status_override.empty()
                                   ? (ready_override ? "ready" : fallback.status)
                                   : status_override;
            readiness.status_summary = summary_override.empty()
                                           ? (ready_override ? std::string(ready_summary) : fallback.status_summary)
                                           : summary_override;
            return readiness;
        }

        return fallback;
    }

    std::string missing_service_status(PlayableServiceKind kind)
    {
        switch (kind)
        {
        case PlayableServiceKind::render:
            return "presentationServiceMissing";
        case PlayableServiceKind::input:
            return "inputBridgeMissing";
        case PlayableServiceKind::audio:
            return "audioBridgeMissing";
        }

        return "serviceMissing";
    }

    std::string ready_service_summary(PlayableServiceKind kind, const std::string &session_identifier)
    {
        switch (kind)
        {
        case PlayableServiceKind::render:
            return "Runtime host presentation service is live for session " + session_identifier + ".";
        case PlayableServiceKind::input:
            return "Runtime host input service is live for session " + session_identifier + ".";
        case PlayableServiceKind::audio:
            return "Runtime host audio service is live for session " + session_identifier + ".";
        }

        return "Runtime host playable service is live.";
    }

    std::string missing_service_summary(
        PlayableServiceKind kind,
        const PlayableSessionRegistryState &registry,
        const std::string &requested_session_identifier)
    {
        const char *service_name = playable_service_name(kind);
        if (!registry.active)
        {
            return "Runtime host has no active playable session bound to a live "
                   + std::string(service_name) + " service.";
        }

        if (registry.session_identifier != requested_session_identifier)
        {
            return "Runtime host " + std::string(service_name) + " service is reserved for session "
                   + registry.session_identifier + ", not " + requested_session_identifier + ".";
        }

        switch (kind)
        {
        case PlayableServiceKind::render:
            return "Runtime host has not registered a live iOS presentation service for session "
                   + requested_session_identifier + ".";
        case PlayableServiceKind::input:
            return "Runtime host has not registered a live iOS input bridge for session "
                   + requested_session_identifier + ".";
        case PlayableServiceKind::audio:
            return "Runtime host has not registered a live iOS audio bridge for session "
                   + requested_session_identifier + ".";
        }

        return "Runtime host playable service is not ready.";
    }

    RuntimeSubsystemReadiness detect_registered_service_readiness(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment,
        const EmbeddedTranslatorReadiness &launch_readiness,
        PlayableServiceKind kind,
        const std::string &override_prefix,
        const char *blocked_summary,
        const char *override_ready_summary)
    {
        RuntimeSubsystemReadiness fallback;
        if (!launch_readiness.launch_ready)
        {
            fallback = make_subsystem_readiness(false, "launchBlocked", blocked_summary);
        }
        else
        {
            const auto registry = snapshot_playable_session_registry();
            if (!registry.active)
            {
                fallback = make_subsystem_readiness(
                    false,
                    missing_service_status(kind),
                    missing_service_summary(kind, registry, package.id));
            }
            else if (registry.session_identifier != package.id)
            {
                fallback = make_subsystem_readiness(
                    false,
                    missing_service_status(kind),
                    missing_service_summary(kind, registry, package.id));
            }
            else
            {
                const PlayableServiceState &service = playable_service_slot(registry, kind);
                if (service.live)
                {
                    std::string summary = ready_service_summary(kind, package.id);
                    if (!service.metadata.empty())
                    {
                        summary += " " + service.metadata;
                    }
                    fallback = make_subsystem_readiness(true, "ready", summary);
                }
                else
                {
                    fallback = make_subsystem_readiness(
                        false,
                        missing_service_status(kind),
                        missing_service_summary(kind, registry, package.id));
                }
            }
        }

        return resolve_subsystem_override(
            environment,
            override_prefix,
            fallback,
            override_ready_summary);
    }

    std::string resolve_staged_userland_root_without_unpacking(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment)
    {
        const std::string explicit_root =
            env_lookup(environment, iridium::runtime::kUserlandRootEnvironmentKey);
        if (!explicit_root.empty())
        {
            return explicit_root;
        }

        if (package.runtime_bundle_root_path.empty())
        {
            return "";
        }

        const std::string support_root = join_path(package.runtime_bundle_root_path, "Support/wine-userland");
        if (directory_exists(support_root))
        {
            return support_root;
        }

        const std::string extracted_root = join_path(package.runtime_bundle_root_path, "Userland/extracted");
        if (directory_exists(extracted_root))
        {
            return extracted_root;
        }

        return "";
    }

    bool binary_contains_any_marker(const std::string &path, const std::vector<std::string> &markers)
    {
        try
        {
            const std::string data = read_text(path);
            for (const auto &marker : markers)
            {
                if (data.find(marker) != std::string::npos)
                {
                    return true;
                }
            }
        }
        catch (...)
        {
            return false;
        }
        return false;
    }

    IOSOpenGLBackendReadiness inspect_ios_opengl_backend_payload(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment)
    {
        const std::string userland_root = resolve_staged_userland_root_without_unpacking(package, environment);
        if (userland_root.empty())
        {
            return {
                false,
                "Runtime host presentation service is live, but this bundle does not include a staged Wine userland OpenGL backend."
            };
        }

        const std::string wineios_driver = first_existing_path({
            join_path(userland_root, "lib/wine/x86_64-unix/wineios.so"),
            join_path(userland_root, "lib64/wine/x86_64-unix/wineios.so"),
            join_path(userland_root, "lib/wine/aarch64-unix/wineios.so"),
            join_path(userland_root, "lib64/wine/aarch64-unix/wineios.so"),
        });
        if (wineios_driver.empty())
        {
            return {
                false,
                "Runtime host presentation service is live, but this bundle does not include the wineios.drv Unix driver needed to present guest frames."
            };
        }

        const std::string opengl_backend = first_existing_path({
            join_path(userland_root, "lib/wine/x86_64-unix/opengl32.so"),
            join_path(userland_root, "lib64/wine/x86_64-unix/opengl32.so"),
            join_path(userland_root, "lib/wine/aarch64-unix/opengl32.so"),
            join_path(userland_root, "lib64/wine/aarch64-unix/opengl32.so"),
        });
        if (opengl_backend.empty())
        {
            return {
                false,
                "Runtime host presentation service is live, but this bundle does not include Wine's Unix OpenGL backend."
            };
        }

        const std::string egl_loader = join_path(parent_path(opengl_backend), "win32u.so");
        if (!file_exists(egl_loader) || !binary_contains_any_marker(egl_loader, {"libEGL"}))
        {
            return {
                false,
                "Runtime host presentation service is live, but this bundle does not include an EGL-capable Wine OpenGL backend loader."
            };
        }

        return {true, ""};
    }

    RuntimeSubsystemReadiness detect_presentation_readiness(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment,
        const EmbeddedTranslatorReadiness &launch_readiness)
    {
        RuntimeSubsystemReadiness readiness = detect_registered_service_readiness(
            package,
            environment,
            launch_readiness,
            PlayableServiceKind::render,
            "IRIDIUM_HOST_PRESENTATION",
            "Guest presentation is blocked until embedded launch bootstrap is ready.",
            "Guest presentation path is ready.");

        if (!readiness.ready)
        {
            return readiness;
        }

        const std::string backend_contract_path = runtime_artifact_path(
            package,
            environment,
            "IRIDIUM_IOS_PRESENTATION_BACKEND_CONTRACT",
            "Graphics/ios-presentation-backend.json");
        if (backend_contract_path.empty() || !file_exists(backend_contract_path))
        {
            return make_subsystem_readiness(
                false,
                "graphicsBackendMissing",
                "Runtime host presentation service is live, but this bundle does not include an iOS Wine graphics backend contract. OpenGL/Vulkan/D3D titles can run without presenting guest frames.");
        }

        try
        {
            const std::string contract = read_text(backend_contract_path);
            if (!extract_json_bool(contract, "presentable"))
            {
                return make_subsystem_readiness(
                    false,
                    "graphicsBackendDisabled",
                    "Runtime host presentation service is live, but the packaged iOS Wine graphics backend is not marked presentable.");
            }
        }
        catch (...)
        {
            return make_subsystem_readiness(
                false,
                "graphicsBackendInvalid",
                "Runtime host presentation service is live, but the packaged iOS Wine graphics backend contract could not be read.");
        }

        const IOSOpenGLBackendReadiness opengl_backend =
            inspect_ios_opengl_backend_payload(package, environment);
        if (!opengl_backend.ready)
        {
            return make_subsystem_readiness(
                false,
                "graphicsBackendMissing",
                opengl_backend.status_summary);
        }

        return readiness;
    }

    RuntimeSubsystemReadiness detect_input_readiness(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment,
        const EmbeddedTranslatorReadiness &launch_readiness)
    {
        return detect_registered_service_readiness(
            package,
            environment,
            launch_readiness,
            PlayableServiceKind::input,
            "IRIDIUM_HOST_INPUT",
            "Guest input is blocked until embedded launch bootstrap is ready.",
            "Guest input path is ready.");
    }

    RuntimeSubsystemReadiness detect_audio_readiness(
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment,
        const EmbeddedTranslatorReadiness &launch_readiness)
    {
        return detect_registered_service_readiness(
            package,
            environment,
            launch_readiness,
            PlayableServiceKind::audio,
            "IRIDIUM_HOST_AUDIO",
            "Guest audio is blocked until embedded launch bootstrap is ready.",
            "Guest audio path is ready.");
    }

    void append_readiness_json(
        std::ostringstream &payload,
        const char *key,
        const RuntimeSubsystemReadiness &readiness)
    {
        payload
            << "  \"" << key << "\": {\n"
            << "    \"ready\": " << (readiness.ready ? "true" : "false") << ",\n"
            << "    \"status\": \"" << json_escape(readiness.status) << "\",\n"
            << "    \"statusSummary\": \"" << json_escape(readiness.status_summary) << "\"\n"
            << "  }";
    }

    void write_host_capabilities(const LaunchPackageSummary &package, const std::map<std::string, std::string> &environment)
    {
        const std::string device_class = resolve_optional_capability(
            environment,
            "IRIDIUM_HOST_DEVICE_CLASS",
            "IRIDIUM_HOST_DEVICE_CLASS");
        const std::string device_tier = resolve_optional_capability(
            environment,
            "IRIDIUM_HOST_DEVICE_TIER",
            "IRIDIUM_HOST_DEVICE_TIER");
        const EmbeddedTranslatorReadiness readiness = probe_embedded_translator(package, environment);
        const std::string jit_status = readiness.jit_status.empty()
                                           ? resolve_jit_status(environment)
                                           : readiness.jit_status;
        const RuntimeSubsystemReadiness presentation_readiness = detect_presentation_readiness(package, environment, readiness);
        const RuntimeSubsystemReadiness input_readiness = detect_input_readiness(package, environment, readiness);
        const RuntimeSubsystemReadiness audio_readiness = detect_audio_readiness(package, environment, readiness);
        const PlayableSessionRegistryState registry = snapshot_playable_session_registry();
        const bool milestones_match_session = registry.active && registry.session_identifier == package.id;
        const bool wine_server_ready = milestones_match_session && registry.wine_server_ready;
        const bool windows_process_started = milestones_match_session && registry.windows_process_started;
        const bool first_frame_presented = milestones_match_session && registry.first_frame_presented;
        const bool runtime_verified = wine_server_ready && windows_process_started && first_frame_presented;
        const std::string launch_status = runtime_verified ? "runtimeVerified" : readiness.launch_status;
        const std::string launch_status_summary = runtime_verified
                                                      ? "Wine server, Windows process, and first guest frame were verified for the active session."
                                                      : readiness.status_summary;
        const std::string capabilities_path = join_path(
            managed_root_from_bundle_root(package.runtime_bundle_root_path),
            iridium::runtime::kCapabilityRecordFileName);

        std::ostringstream payload;
        payload
            << "{\n";

        if (device_class.empty())
        {
            payload << "  \"deviceCapabilityClass\": null,\n";
        }
        else
        {
            payload << "  \"deviceCapabilityClass\": \"" << json_escape(device_class) << "\",\n";
        }

        if (device_tier.empty())
        {
            payload << "  \"deviceTier\": null,\n";
        }
        else
        {
            payload << "  \"deviceTier\": \"" << json_escape(device_tier) << "\",\n";
        }

        payload
            << "  \"jitStatus\": \"" << json_escape(jit_status) << "\",\n"
            << "  \"launchReady\": " << (readiness.launch_ready ? "true" : "false") << ",\n"
            << "  \"launchStatus\": " << (launch_status.empty() ? "null" : "\"" + json_escape(launch_status) + "\"") << ",\n"
            << "  \"launchStatusSummary\": " << (launch_status_summary.empty() ? "null" : "\"" + json_escape(launch_status_summary) + "\"") << ",\n"
            << "  \"runtimeMilestones\": {\n"
            << "    \"sessionIdentifier\": " << (milestones_match_session ? "\"" + json_escape(registry.session_identifier) + "\"" : "null") << ",\n"
            << "    \"wineServerReady\": " << (wine_server_ready ? "true" : "false") << ",\n"
            << "    \"windowsProcessStarted\": " << (windows_process_started ? "true" : "false") << ",\n"
            << "    \"firstFramePresented\": " << (first_frame_presented ? "true" : "false") << "\n"
            << "  },\n"
            << "  \"jitSessionKind\": " << (readiness.session_kind.empty() ? "null" : "\"" + json_escape(readiness.session_kind) + "\"") << ",\n"
            << "  \"jitFailureStage\": " << (readiness.failure_stage.empty() ? "null" : "\"" + json_escape(readiness.failure_stage) + "\"") << ",\n"
            << "  \"allocatorBackend\": " << (readiness.allocator_backend.empty() ? "null" : "\"" + json_escape(readiness.allocator_backend) + "\"") << ",\n"
            << "  \"jitToolRecommendation\": " << (readiness.tool_recommendation.empty() ? "null" : "\"" + json_escape(readiness.tool_recommendation) + "\"") << ",\n"
            << "  \"jitToolBootstrapRequired\": " << (readiness.tool_bootstrap_required ? "true" : "false") << ",\n"
            << "  \"jitToolBootstrapKind\": "
            << (readiness.tool_bootstrap_kind.empty() ? "null" : "\"" + json_escape(readiness.tool_bootstrap_kind) + "\"") << ",\n"
            << "  \"jitToolBootstrapSummary\": "
            << (readiness.tool_bootstrap_summary.empty() ? "null" : "\"" + json_escape(readiness.tool_bootstrap_summary) + "\"") << ",\n"
            << "  \"jitSummary\": " << (readiness.status_summary.empty() ? "null" : "\"" + json_escape(readiness.status_summary) + "\"") << ",\n"
            << "  \"exceptionPortsActive\": " << (readiness.exception_ports_active ? "true" : "false") << ",\n";
        append_readiness_json(payload, "presentationReadiness", presentation_readiness);
        payload << ",\n";
        append_readiness_json(payload, "inputReadiness", input_readiness);
        payload << ",\n";
        append_readiness_json(payload, "audioReadiness", audio_readiness);
        payload
            << ",\n"
            << "  \"measuredAt\": " << json_number(now_reference_seconds()) << ",\n"
            << "  \"runtimeHostVersion\": \"" << json_escape(iridium::runtime::kDefaultHostVersion) << "\",\n"
            << "  \"supportedArchitectures\": [\"x64\"],\n"
            << "  \"supportedGraphicsAPIs\": [\"opengl\"],\n"
            << "  \"translatorPresent\": " << (readiness.translator_present ? "true" : "false") << ",\n"
            << "  \"translatorReady\": " << (readiness.launch_ready ? "true" : "false");
        payload << "\n";
        payload << "}\n";
        write_text(capabilities_path, payload.str());
    }

    void write_session_update(
        const HostArguments &arguments,
        const LaunchPackageSummary &package,
        const std::string &state,
        const std::vector<std::string> &state_history,
        const std::string &status_summary,
        const std::string &failure_code = "",
        const std::string &failure_reason = "")
    {
        std::ostringstream payload;
        payload
            << "{\n"
            << "  \"failureCode\": " << (failure_code.empty() ? "null" : "\"" + json_escape(failure_code) + "\"") << ",\n"
            << "  \"failureReason\": " << (failure_reason.empty() ? "null" : "\"" + json_escape(failure_reason) + "\"") << ",\n"
            << "  \"id\": \"" << json_escape(package.id) << "\",\n"
            << "  \"state\": \"" << json_escape(state) << "\",\n"
            << "  \"stateHistory\": [";

        for (std::size_t index = 0; index < state_history.size(); ++index)
        {
            if (index > 0)
            {
                payload << ", ";
            }
            payload << "\"" << json_escape(state_history[index]) << "\"";
        }

        payload
            << "],\n"
            << "  \"statusSummary\": \"" << json_escape(status_summary) << "\",\n"
            << "  \"updatedAt\": " << json_number(now_reference_seconds()) << "\n"
            << "}\n";
        write_text(arguments.session_update_path, payload.str());
    }

    void write_terminal_result(
        const HostArguments &arguments,
        const LaunchPackageSummary &package,
        const std::string &terminal_status,
        const std::vector<std::string> &state_history,
        const std::string &failure_code = "",
        const std::string &failure_reason = "")
    {
        std::ostringstream payload;
        payload
            << "{\n"
            << "  \"failureCode\": " << (failure_code.empty() ? "null" : "\"" + json_escape(failure_code) + "\"") << ",\n"
            << "  \"failureReason\": " << (failure_reason.empty() ? "null" : "\"" + json_escape(failure_reason) + "\"") << ",\n"
            << "  \"id\": \"" << json_escape(package.id) << "\",\n"
            << "  \"reportedAt\": " << json_number(now_reference_seconds()) << ",\n"
            << "  \"stateHistory\": [";

        for (std::size_t index = 0; index < state_history.size(); ++index)
        {
            if (index > 0)
            {
                payload << ", ";
            }
            payload << "\"" << json_escape(state_history[index]) << "\"";
        }

        payload
            << "],\n"
            << "  \"terminalStatus\": \"" << json_escape(terminal_status) << "\"\n"
            << "}\n";
        write_text(arguments.terminal_result_path, payload.str());
    }

    HostTelemetrySnapshot detect_host_telemetry(const std::map<std::string, std::string> &environment)
    {
        HostTelemetrySnapshot telemetry;
        if (env_flag_enabled(environment, "IRIDIUM_HOST_NO_TELEMETRY"))
        {
            return telemetry;
        }

        const std::string fps =
            env_lookup(environment, iridium::runtime::kHostTelemetryAverageFPSEnvironmentKey);
        const std::string p95 =
            env_lookup(environment, iridium::runtime::kHostTelemetryFrameTimeP95MSEnvironmentKey);
        const std::string pressure =
            env_lookup(environment, iridium::runtime::kHostTelemetryMemoryPressureRatioEnvironmentKey);
        const std::string thermal = env_lookup(environment, iridium::runtime::kHostTelemetryThermalStateEnvironmentKey);

        if (fps.empty() || p95.empty() || pressure.empty() || thermal.empty())
        {
            return telemetry;
        }

        if (!parse_double(fps, &telemetry.average_fps) || !parse_double(p95, &telemetry.frame_time_p95_ms) || !parse_double(pressure, &telemetry.memory_pressure_ratio))
        {
            return telemetry;
        }

        telemetry.available = true;
        telemetry.thermal_state = thermal;
        return telemetry;
    }

    bool write_telemetry(
        const HostArguments &arguments,
        const std::map<std::string, std::string> &environment)
    {
        const HostTelemetrySnapshot telemetry = detect_host_telemetry(environment);
        if (!telemetry.available)
        {
            remove_file_if_exists(arguments.telemetry_path);
            return false;
        }

        std::ostringstream payload;
        payload
            << "{\n"
            << "  \"averageFPS\": " << json_number(telemetry.average_fps) << ",\n"
            << "  \"frameTimeP95MS\": " << json_number(telemetry.frame_time_p95_ms) << ",\n"
            << "  \"memoryPressureRatio\": " << json_number(telemetry.memory_pressure_ratio) << ",\n"
            << "  \"thermalState\": \"" << json_escape(telemetry.thermal_state) << "\"\n"
            << "}\n";
        write_text(arguments.telemetry_path, payload.str());
        return true;
    }

    int spawn_external_wine(
        const HostArguments &arguments,
        const LaunchPackageSummary &package,
        const std::map<std::string, std::string> &environment)
    {
        std::map<std::string, std::string> launch_environment = environment;
        const std::string translator_binary = detect_translator_binary(package, launch_environment);
        const std::string userland_archive = detect_userland_archive(package, launch_environment);
        const std::string userland_root = resolve_userland_root(package, launch_environment, arguments.host_log_path);

        if (!translator_binary.empty() && launch_environment.find("IRIDIUM_TRANSLATOR_BINARY") == launch_environment.end())
        {
            launch_environment["IRIDIUM_TRANSLATOR_BINARY"] = translator_binary;
        }
        if (!userland_archive.empty() && launch_environment.find("IRIDIUM_USERLAND_ARCHIVE") == launch_environment.end())
        {
            launch_environment["IRIDIUM_USERLAND_ARCHIVE"] = userland_archive;
        }
        if (!userland_root.empty()
            && launch_environment.find(iridium::runtime::kUserlandRootEnvironmentKey) == launch_environment.end())
        {
            launch_environment[iridium::runtime::kUserlandRootEnvironmentKey] = userland_root;
        }

        const std::string wine_binary = detect_wine_binary(launch_environment);
        if (wine_binary.empty())
        {
            const std::vector<std::string> history = {"queued", "bootingRuntime", "failed"};
            write_session_update(
                arguments,
                package,
                "failed",
                history,
                "Runtime host could not locate a configured Wine binary.",
                "runtimeBootFailed",
                "No Wine binary was available for external execution.");
            write_terminal_result(
                arguments,
                package,
                "failed",
                history,
                "runtimeBootFailed",
                "No Wine binary was available for external execution.");
            append_log(arguments.host_log_path, "engine=external-wine");
            append_log(arguments.host_log_path, "wine-binary=missing");
            append_log(arguments.host_log_path, "translator-binary=" + (translator_binary.empty() ? std::string("missing") : translator_binary));
            append_log(arguments.host_log_path, "userland-archive=" + (userland_archive.empty() ? std::string("missing") : userland_archive));
            append_log(arguments.host_log_path, "userland-root=" + (userland_root.empty() ? std::string("missing") : userland_root));
            return 1;
        }

        write_session_update(
            arguments,
            package,
            "queued",
            {"queued"},
            "Native runtime host accepted the external Wine launch package.");

        write_session_update(
            arguments,
            package,
            "running",
            {"queued", "bootingRuntime", "running"},
            "Native runtime host launched the external Wine engine.");

        append_log(arguments.host_log_path, "engine=external-wine");
        append_log(arguments.host_log_path, "wine-binary=" + wine_binary);
        append_log(arguments.host_log_path, "translator-binary=" + (translator_binary.empty() ? std::string("missing") : translator_binary));
        append_log(arguments.host_log_path, "userland-archive=" + (userland_archive.empty() ? std::string("missing") : userland_archive));
        append_log(arguments.host_log_path, "userland-root=" + (userland_root.empty() ? std::string("missing") : userland_root));
        append_log(arguments.host_log_path, "working-directory=" + package.working_directory);

        std::vector<std::string> argv_storage;
        argv_storage.push_back(wine_binary);
        argv_storage.push_back(package.executable_path);
        for (const auto &argument : package.launch_arguments)
        {
            argv_storage.push_back(argument);
        }

        std::vector<char *> argv;
        for (auto &argument : argv_storage)
        {
            argv.push_back(const_cast<char *>(argument.c_str()));
        }
        argv.push_back(nullptr);

        std::vector<std::string> env_storage;
        env_storage.reserve(launch_environment.size());
        for (const auto &pair : launch_environment)
        {
            env_storage.push_back(pair.first + "=" + pair.second);
        }

        std::vector<char *> envp;
        for (auto &entry : env_storage)
        {
            envp.push_back(const_cast<char *>(entry.c_str()));
        }
        envp.push_back(nullptr);

        posix_spawn_file_actions_t file_actions;
        posix_spawn_file_actions_init(&file_actions);
        posix_spawn_file_actions_addopen(&file_actions, STDOUT_FILENO, arguments.host_log_path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
        posix_spawn_file_actions_addopen(&file_actions, STDERR_FILENO, arguments.host_log_path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
#if defined(__APPLE__) && TARGET_OS_OSX
        if (!package.working_directory.empty())
        {
            posix_spawn_file_actions_addchdir_np(&file_actions, package.working_directory.c_str());
        }
#endif

        pid_t child_pid = 0;
        const int spawn_result = posix_spawn(
            &child_pid,
            wine_binary.c_str(),
            &file_actions,
            nullptr,
            argv.data(),
            envp.data());
        posix_spawn_file_actions_destroy(&file_actions);

        if (spawn_result != 0)
        {
            const std::vector<std::string> history = {"queued", "bootingRuntime", "failed"};
            write_session_update(
                arguments,
                package,
                "failed",
                history,
                "Runtime host failed to spawn the external Wine engine.",
                "runtimeBootFailed",
                "posix_spawn failed with errno " + std::to_string(spawn_result));
            write_terminal_result(
                arguments,
                package,
                "failed",
                history,
                "runtimeBootFailed",
                "posix_spawn failed with errno " + std::to_string(spawn_result));
            return 1;
        }

        int status = 0;
        if (waitpid(child_pid, &status, 0) < 0)
        {
            const std::vector<std::string> history = {"queued", "bootingRuntime", "running", "failed"};
            write_terminal_result(
                arguments,
                package,
                "failed",
                history,
                "runtimeBootFailed",
                "waitpid failed while monitoring the external Wine engine.");
            return 1;
        }

        const bool succeeded = WIFEXITED(status) && WEXITSTATUS(status) == 0;
        const std::vector<std::string> history = succeeded
                                                     ? std::vector<std::string>{"queued", "bootingRuntime", "running", "completed"}
                                                     : std::vector<std::string>{"queued", "bootingRuntime", "running", "failed"};

        const bool telemetry_written = write_telemetry(arguments, launch_environment);
        write_terminal_result(
            arguments,
            package,
            succeeded ? "completed" : "failed",
            history,
            succeeded ? "" : "gameProcessExited",
            succeeded ? "" : "External Wine engine exited with status " + std::to_string(status) + ".");
        append_log(arguments.host_log_path, succeeded ? "terminal=completed" : "terminal=failed");
        append_log(arguments.host_log_path, telemetry_written ? "telemetry=written" : "telemetry=absent");
        return succeeded ? 0 : 1;
    }

    int run(const HostArguments &arguments)
    {
        const LaunchPackageSummary package = parse_launch_package(arguments.launch_package_path);
        const auto environment = merged_launch_environment(package);
        const DirectLaunchProfile profile = load_direct_launch_profile(package, environment);

        append_log(arguments.host_log_path, "launch-package=" + arguments.launch_package_path);
        append_log(arguments.host_log_path, "game=" + package.game_title);
        append_log(arguments.host_log_path, "executable=" + package.executable_path);
        for (std::size_t index = 0; index < package.launch_arguments.size(); ++index)
        {
            append_log(arguments.host_log_path, "launch-arg[" + std::to_string(index) + "]=" + package.launch_arguments[index]);
        }
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_WINE_IOS_GRAPHICS_DRIVER");
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_WINE_IOS_BRIDGE_CONFIG");
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_WINE_IOS_BRIDGE_ROOT");
        append_environment_probe(arguments.host_log_path, environment, iridium::runtime::kWineServerRootEnvironmentKey);
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_WINE_IOS_SURFACE_ID");
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_WINE_IOS_SURFACE_WIDTH");
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_WINE_IOS_SURFACE_HEIGHT");
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_WINE_IOS_TRACE_PATH");
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH");
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH");
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_WINE_IOS_AUDIO_STATE_PATH");
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_RENDERER_PRESET");
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_RUNTIME_GRAPHICS_STACK");
        append_environment_probe(arguments.host_log_path, environment, "WINEDEBUG");
        append_environment_probe(arguments.host_log_path, environment, "WINEDEBUGLOG");
        append_environment_probe(arguments.host_log_path, environment, "WINESERVER");
        append_environment_probe(arguments.host_log_path, environment, "IRIDIUM_WINE_HOST_WINESERVER");
        append_log(
            arguments.host_log_path,
            "translator-binary=" + (detect_translator_binary(package, environment).empty()
                                        ? std::string("missing")
                                        : detect_translator_binary(package, environment)));
        append_log(
            arguments.host_log_path,
            "userland-archive=" + (detect_userland_archive(package, environment).empty()
                                       ? std::string("missing")
                                       : detect_userland_archive(package, environment)));

        write_host_capabilities(package, environment);
        remove_file_if_exists(arguments.telemetry_path);

        if (!package.direct_launch_only || !profile.direct_launch_only || !supports_architecture(profile, "x64") || is_blocked_entrypoint(package.executable_path, profile))
        {
            const std::vector<std::string> history = {"queued", "failed"};
            write_session_update(
                arguments,
                package,
                "failed",
                history,
                "Runtime host rejected a blocked entrypoint or unsupported direct-launch policy.",
                "desktopShellEntrypointBlocked",
                "Desktop shells, launcher shells, and non-x64 launch targets are blocked.");
            write_terminal_result(
                arguments,
                package,
                "failed",
                history,
                "desktopShellEntrypointBlocked",
                "Desktop shells, launcher shells, and non-x64 launch targets are blocked.");
            append_log(arguments.host_log_path, "terminal=failed");
            return 1;
        }

        if (env_flag_enabled(environment, "IRIDIUM_HOST_ENABLE_EXTERNAL_ENGINE"))
        {
            append_log(arguments.host_log_path, "engine-mode=development-external");
            return spawn_external_wine(arguments, package, environment);
        }

        const EmbeddedExecutionBootstrap embedded_bootstrap = bootstrap_embedded_execution(
            package,
            environment,
            arguments.host_log_path);
        append_log(arguments.host_log_path, "engine=embedded-opengl");
        append_log(arguments.host_log_path, "jit-status=" + embedded_bootstrap.jit_status);
        append_log(arguments.host_log_path, "jit-backend=" + (embedded_bootstrap.allocator_backend.empty() ? std::string("none") : embedded_bootstrap.allocator_backend));
        append_log(arguments.host_log_path, "jit-session-kind=" + (embedded_bootstrap.session_kind.empty() ? std::string("none") : embedded_bootstrap.session_kind));
        append_log(arguments.host_log_path, "jit-failure-stage=" + (embedded_bootstrap.failure_stage.empty() ? std::string("none") : embedded_bootstrap.failure_stage));
        append_log(arguments.host_log_path, "jit-tool-recommendation=" + (embedded_bootstrap.tool_recommendation.empty() ? std::string("none") : embedded_bootstrap.tool_recommendation));
        append_log(arguments.host_log_path, "jit-tool-bootstrap-required=" + std::string(embedded_bootstrap.tool_bootstrap_required ? "true" : "false"));
        append_log(arguments.host_log_path, "exception-ports-active=" + std::string(embedded_bootstrap.exception_ports_active ? "true" : "false"));
        append_log(
            arguments.host_log_path,
            "jit-summary=" + (embedded_bootstrap.failure_reason.empty()
                                  ? (embedded_bootstrap.jit_status == "ready"
                                         ? std::string("JIT is attached and the embedded bootstrap is ready; runtime milestones are pending.")
                                         : std::string(""))
                                  : embedded_bootstrap.failure_reason));
        append_log(
            arguments.host_log_path,
            "translator-binary=" + (embedded_bootstrap.translator_binary.empty()
                                        ? std::string("missing")
                                        : embedded_bootstrap.translator_binary));
        append_log(
            arguments.host_log_path,
            "userland-root=" + (embedded_bootstrap.userland_root.empty()
                                    ? std::string("missing")
                                    : embedded_bootstrap.userland_root));
        append_log(
            arguments.host_log_path,
            "prefix-root=" + (embedded_bootstrap.prefix_root.empty()
                                  ? std::string("missing")
                                  : embedded_bootstrap.prefix_root));
        append_log(
            arguments.host_log_path,
            "wine-binary=" + (embedded_bootstrap.resolved_wine_binary.empty()
                                  ? std::string("missing")
                                  : embedded_bootstrap.resolved_wine_binary));
        append_log(
            arguments.host_log_path,
            "session-id=" + (embedded_bootstrap.session_identifier.empty()
                                 ? std::string("missing")
                                 : embedded_bootstrap.session_identifier));

        if (!embedded_bootstrap.success)
        {
            const std::vector<std::string> history = {"queued", "failed"};
            write_session_update(
                arguments,
                package,
                "failed",
                history,
                embedded_bootstrap.failure_reason,
                embedded_bootstrap.failure_code,
                embedded_bootstrap.failure_reason);
            write_terminal_result(
                arguments,
                package,
                "failed",
                history,
                embedded_bootstrap.failure_code,
                embedded_bootstrap.failure_reason);
            append_log(arguments.host_log_path, "terminal=failed");
            return 1;
        }

        write_session_update(
            arguments,
            package,
            "queued",
            {"queued"},
            "Embedded runtime host accepted the direct-launch package.");

        const EmbeddedExecutionTerminalResult embedded_terminal = monitor_embedded_execution_until_terminal(
            arguments,
            package,
            embedded_bootstrap.session_identifier,
            environment);
        const bool should_fail = embedded_terminal.terminal_status == "failed";
        if (!should_fail)
        {
            const bool telemetry_written = write_telemetry(arguments, environment);
            append_log(arguments.host_log_path, telemetry_written ? "telemetry=written" : "telemetry=absent");
        }
        else
        {
            remove_file_if_exists(arguments.telemetry_path);
            append_log(arguments.host_log_path, "telemetry=absent");
        }

        const std::vector<std::string> terminal_history = should_fail
                                                              ? std::vector<std::string>{"queued", "bootstrappingPrefix", "bootingRuntime", "running", "failed"}
                                                              : std::vector<std::string>{"queued", "bootstrappingPrefix", "bootingRuntime", "running", "completed"};

        write_terminal_result(
            arguments,
            package,
            should_fail ? "failed" : (embedded_terminal.terminal_status.empty() ? "completed" : embedded_terminal.terminal_status),
            terminal_history,
            should_fail ? (
                              embedded_terminal.terminal_failure_code.empty()
                                  ? "gameProcessExited"
                                  : embedded_terminal.terminal_failure_code)
                        : "",
            should_fail ? (
                              embedded_terminal.terminal_failure_reason.empty()
                                  ? "Embedded Wine/FEX runtime observed the game process exit after startup."
                                  : embedded_terminal.terminal_failure_reason)
                        : "");
        append_log(arguments.host_log_path, std::string("terminal=") + (should_fail ? "failed" : "completed"));
        return should_fail ? 1 : 0;
    }

} // namespace

namespace
{

    HostCapabilityRefreshArguments make_refresh_arguments(const iridium::runtime::HostCapabilityRefreshPaths &invocation)
    {
        return HostCapabilityRefreshArguments{
            invocation.runtime_bundle_root_path == nullptr ? "" : std::string(invocation.runtime_bundle_root_path),
        };
    }

    void write_playable_session_log(const std::string &host_log_path, const std::string &line)
    {
        if (host_log_path.empty())
        {
            return;
        }

        append_log(host_log_path, line);
    }

    LaunchPackageSummary make_capability_probe_package(
        const std::string &session_identifier,
        const std::string &runtime_bundle_root_path)
    {
        LaunchPackageSummary package;
        package.id = session_identifier.empty() ? "host-capability-refresh" : session_identifier;
        package.game_title = "Host Capability Refresh";
        package.runtime_bundle_root_path = runtime_bundle_root_path;
        package.direct_launch_only = true;
        return package;
    }

    LaunchPackageSummary make_capability_probe_package(const HostCapabilityRefreshArguments &arguments)
    {
        const auto registry = snapshot_playable_session_registry();
        return make_capability_probe_package(
            registry.active ? registry.session_identifier : std::string("host-capability-refresh"),
            arguments.runtime_bundle_root_path);
    }

    void refresh_playable_session_capabilities(
        const std::string &runtime_bundle_root_path,
        const std::string &session_identifier)
    {
        if (runtime_bundle_root_path.empty() || !directory_exists(runtime_bundle_root_path))
        {
            return;
        }

        const LaunchPackageSummary package = make_capability_probe_package(
            session_identifier,
            runtime_bundle_root_path);
        const auto environment = current_process_environment();
        write_host_capabilities(package, environment);
    }

    int refresh_capabilities(const HostCapabilityRefreshArguments &arguments)
    {
        if (arguments.runtime_bundle_root_path.empty() || !directory_exists(arguments.runtime_bundle_root_path))
        {
            return 64;
        }

        const LaunchPackageSummary package = make_capability_probe_package(arguments);
        const auto environment = current_process_environment();
        write_host_capabilities(package, environment);
        return 0;
    }

    int acquire_playable_session(const iridium::runtime::HostPlayableSessionReservation &reservation)
    {
        if (reservation.session_identifier == nullptr || reservation.session_identifier[0] == '\0'
            || reservation.runtime_bundle_root_path == nullptr || reservation.runtime_bundle_root_path[0] == '\0')
        {
            return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
        }

        const std::string session_identifier(reservation.session_identifier);
        const std::string runtime_bundle_root_path(reservation.runtime_bundle_root_path);
        const std::string host_log_path = reservation.host_log_path == nullptr
                                              ? std::string()
                                              : std::string(reservation.host_log_path);

        if (!directory_exists(runtime_bundle_root_path))
        {
            return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
        }

        {
            const std::lock_guard<std::mutex> lock(playable_session_registry_mutex);
            if (playable_session_registry.active
                && playable_session_registry.session_identifier != session_identifier)
            {
                return IRIDIUM_RUNTIME_HOST_REGISTRATION_SESSION_CONFLICT;
            }

            playable_session_registry.active = true;
            playable_session_registry.session_identifier = session_identifier;
            playable_session_registry.runtime_bundle_root_path = runtime_bundle_root_path;
            if (!host_log_path.empty())
            {
                playable_session_registry.host_log_path = host_log_path;
            }
            write_playable_session_log(
                playable_session_registry.host_log_path,
                "session-acquired id=" + playable_session_registry.session_identifier);
        }

        refresh_playable_session_capabilities(runtime_bundle_root_path, session_identifier);
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_OK;
    }

    int register_playable_service(const iridium::runtime::HostPlayableServiceRegistration &registration)
    {
        if (registration.session_identifier == nullptr || registration.session_identifier[0] == '\0')
        {
            return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
        }

        PlayableServiceKind service_kind{};
        if (!try_parse_playable_service_kind(registration.service_kind, &service_kind))
        {
            return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
        }

        const std::string session_identifier(registration.session_identifier);
        const std::string service_handle = registration.service_handle == nullptr
                                               ? std::string()
                                               : std::string(registration.service_handle);
        const std::string service_metadata = registration.service_metadata == nullptr
                                                 ? std::string()
                                                 : std::string(registration.service_metadata);

        std::string runtime_bundle_root_path;
        std::string host_log_path;
        {
            const std::lock_guard<std::mutex> lock(playable_session_registry_mutex);
            if (!playable_session_registry.active)
            {
                return IRIDIUM_RUNTIME_HOST_REGISTRATION_SESSION_MISMATCH;
            }
            if (playable_session_registry.session_identifier != session_identifier)
            {
                return IRIDIUM_RUNTIME_HOST_REGISTRATION_SESSION_MISMATCH;
            }

            PlayableServiceState &service = playable_service_slot(playable_session_registry, service_kind);
            if (!service.handle.empty() && !service_handle.empty()
                && service.handle != service_handle)
            {
                return IRIDIUM_RUNTIME_HOST_REGISTRATION_SERVICE_CONFLICT;
            }

            service.handle = service_handle;
            service.metadata = service_metadata;
            runtime_bundle_root_path = playable_session_registry.runtime_bundle_root_path;
            host_log_path = playable_session_registry.host_log_path;
        }

        std::string log_line = std::string(playable_service_name(service_kind))
                               + "-service-registered session=" + session_identifier;
        if (!service_handle.empty())
        {
            log_line += " handle=" + service_handle;
        }
        if (!service_metadata.empty())
        {
            log_line += " metadata=" + service_metadata;
        }
        write_playable_session_log(host_log_path, log_line);
        refresh_playable_session_capabilities(runtime_bundle_root_path, session_identifier);
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_OK;
    }

    int set_playable_service_liveness(const iridium::runtime::HostPlayableServiceLiveness &liveness)
    {
        if (liveness.session_identifier == nullptr || liveness.session_identifier[0] == '\0')
        {
            return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
        }

        PlayableServiceKind service_kind{};
        if (!try_parse_playable_service_kind(liveness.service_kind, &service_kind))
        {
            return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
        }

        const std::string session_identifier(liveness.session_identifier);
        const bool service_live = liveness.service_live != 0;

        std::string runtime_bundle_root_path;
        std::string host_log_path;
        std::string service_handle;
        std::string service_metadata;
        {
            const std::lock_guard<std::mutex> lock(playable_session_registry_mutex);
            if (!playable_session_registry.active
                || playable_session_registry.session_identifier != session_identifier)
            {
                return IRIDIUM_RUNTIME_HOST_REGISTRATION_SESSION_MISMATCH;
            }

            PlayableServiceState &service = playable_service_slot(playable_session_registry, service_kind);
            if (service_live && service.handle.empty())
            {
                return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
            }

            service.live = service_live;
            runtime_bundle_root_path = playable_session_registry.runtime_bundle_root_path;
            host_log_path = playable_session_registry.host_log_path;
            service_handle = service.handle;
            service_metadata = service.metadata;
        }

        std::string log_line;
        if (service_live)
        {
            log_line = std::string("service-live session=") + session_identifier + " kind="
                       + playable_service_name(service_kind);
            if (!service_handle.empty())
            {
                log_line += " handle=" + service_handle;
            }
            if (!service_metadata.empty())
            {
                log_line += " metadata=" + service_metadata;
            }
        }
        else
        {
            log_line = std::string("service-liveness-failure session=") + session_identifier + " kind="
                       + playable_service_name(service_kind);
        }

        write_playable_session_log(host_log_path, log_line);
        refresh_playable_session_capabilities(runtime_bundle_root_path, session_identifier);
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_OK;
    }

    int unregister_playable_service(const iridium::runtime::HostPlayableServiceRegistration &registration)
    {
        if (registration.session_identifier == nullptr || registration.session_identifier[0] == '\0')
        {
            return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
        }

        PlayableServiceKind service_kind{};
        if (!try_parse_playable_service_kind(registration.service_kind, &service_kind))
        {
            return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
        }

        const std::string session_identifier(registration.session_identifier);
        std::string runtime_bundle_root_path;
        std::string host_log_path;
        {
            const std::lock_guard<std::mutex> lock(playable_session_registry_mutex);
            if (!playable_session_registry.active
                || playable_session_registry.session_identifier != session_identifier)
            {
                return IRIDIUM_RUNTIME_HOST_REGISTRATION_SESSION_MISMATCH;
            }

            PlayableServiceState &service = playable_service_slot(playable_session_registry, service_kind);
            service.live = false;
            service.handle.clear();
            service.metadata.clear();
            runtime_bundle_root_path = playable_session_registry.runtime_bundle_root_path;
            host_log_path = playable_session_registry.host_log_path;
        }

        write_playable_session_log(
            host_log_path,
            std::string("service-liveness-failure session=") + session_identifier + " kind="
                + playable_service_name(service_kind));
        refresh_playable_session_capabilities(runtime_bundle_root_path, session_identifier);
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_OK;
    }

    int release_playable_session(const char *session_identifier)
    {
        if (session_identifier == nullptr || session_identifier[0] == '\0')
        {
            return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
        }

        const std::string requested_identifier(session_identifier);
        std::string runtime_bundle_root_path;
        std::string host_log_path;
        {
            const std::lock_guard<std::mutex> lock(playable_session_registry_mutex);
            if (!playable_session_registry.active)
            {
                return IRIDIUM_RUNTIME_HOST_REGISTRATION_OK;
            }
            if (playable_session_registry.session_identifier != requested_identifier)
            {
                return IRIDIUM_RUNTIME_HOST_REGISTRATION_SESSION_MISMATCH;
            }

            runtime_bundle_root_path = playable_session_registry.runtime_bundle_root_path;
            host_log_path = playable_session_registry.host_log_path;
            playable_session_registry = PlayableSessionRegistryState{};
        }

        char stop_error[512] = {};
        const int stop_status = iridium_fex_ios_request_guest_stop(
            requested_identifier.c_str(),
            stop_error,
            sizeof(stop_error));
        if (stop_status != 0)
        {
            write_playable_session_log(
                host_log_path,
                "guest-stop-request-failed id=" + requested_identifier
                    + " status=" + std::to_string(stop_status)
                    + " error=" + (stop_error[0] == '\0' ? std::string("none") : std::string(stop_error)));
        }
        else
        {
            write_playable_session_log(host_log_path, "guest-stop-requested id=" + requested_identifier);
        }

        write_playable_session_log(host_log_path, "session-released id=" + requested_identifier);
        refresh_playable_session_capabilities(runtime_bundle_root_path, "");
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_OK;
    }

    int record_launch_milestone(
        const char *session_identifier,
        IridiumRuntimeHostLaunchMilestone milestone)
    {
        if (session_identifier == nullptr || session_identifier[0] == '\0')
        {
            return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
        }

        const std::string requested_identifier(session_identifier);
        std::string runtime_bundle_root_path;
        std::string host_log_path;
        bool changed = false;
        {
            const std::lock_guard<std::mutex> lock(playable_session_registry_mutex);
            if (!playable_session_registry.active
                || playable_session_registry.session_identifier != requested_identifier)
            {
                return IRIDIUM_RUNTIME_HOST_REGISTRATION_SESSION_MISMATCH;
            }
            changed = try_record_launch_milestone_locked(playable_session_registry, milestone);
            if (!changed && std::string(launch_milestone_name(milestone)) == "unknown")
            {
                return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
            }
            runtime_bundle_root_path = playable_session_registry.runtime_bundle_root_path;
            host_log_path = playable_session_registry.host_log_path;
        }

        if (changed)
        {
            write_playable_session_log(
                host_log_path,
                "runtime-milestone session=" + requested_identifier
                    + " milestone=" + launch_milestone_name(milestone));
            refresh_playable_session_capabilities(runtime_bundle_root_path, requested_identifier);
        }
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_OK;
    }

} // namespace

int iridium::runtime::RunHostInvocation(const HostInvocationPaths &invocation)
{
    return run(make_arguments(invocation));
}

int iridium::runtime::RefreshHostCapabilities(const HostCapabilityRefreshPaths &invocation)
{
    return refresh_capabilities(make_refresh_arguments(invocation));
}

int iridium::runtime::AcquirePlayableSession(const HostPlayableSessionReservation &reservation)
{
    return acquire_playable_session(reservation);
}

int iridium::runtime::RegisterPlayableService(const HostPlayableServiceRegistration &registration)
{
    return register_playable_service(registration);
}

int iridium::runtime::SetPlayableServiceLiveness(const HostPlayableServiceLiveness &liveness)
{
    return set_playable_service_liveness(liveness);
}

int iridium::runtime::UnregisterPlayableService(const HostPlayableServiceRegistration &registration)
{
    return unregister_playable_service(registration);
}

int iridium::runtime::ReleasePlayableSession(const char *session_identifier)
{
    return release_playable_session(session_identifier);
}

int iridium::runtime::RecordLaunchMilestone(
    const char *session_identifier,
    IridiumRuntimeHostLaunchMilestone milestone)
{
    return record_launch_milestone(session_identifier, milestone);
}

extern "C" int iridium_runtime_host_run(const iridium::runtime::HostInvocationPaths *invocation)
{
    if (invocation == nullptr)
    {
        return 64;
    }

    try
    {
        return iridium::runtime::RunHostInvocation(*invocation);
    }
    catch (const std::exception &error)
    {
        std::cerr << "runtime-host.bin: " << error.what() << '\n';
        return 64;
    }
}

extern "C" int iridium_runtime_host_refresh_capabilities(const iridium::runtime::HostCapabilityRefreshPaths *invocation)
{
    if (invocation == nullptr)
    {
        return 64;
    }

    try
    {
        return iridium::runtime::RefreshHostCapabilities(*invocation);
    }
    catch (const std::exception &error)
    {
        std::cerr << "runtime-host.bin: " << error.what() << '\n';
        return 64;
    }
}

extern "C" int iridium_runtime_host_acquire_playable_session(
    const iridium::runtime::HostPlayableSessionReservation *reservation)
{
    if (reservation == nullptr)
    {
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
    }

    try
    {
        return iridium::runtime::AcquirePlayableSession(*reservation);
    }
    catch (const std::exception &error)
    {
        std::cerr << "runtime-host.bin: " << error.what() << '\n';
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
    }
}

extern "C" int iridium_runtime_host_register_playable_service(
    const iridium::runtime::HostPlayableServiceRegistration *registration)
{
    if (registration == nullptr)
    {
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
    }

    try
    {
        return iridium::runtime::RegisterPlayableService(*registration);
    }
    catch (const std::exception &error)
    {
        std::cerr << "runtime-host.bin: " << error.what() << '\n';
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
    }
}

extern "C" int iridium_runtime_host_set_playable_service_liveness(
    const iridium::runtime::HostPlayableServiceLiveness *liveness)
{
    if (liveness == nullptr)
    {
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
    }

    try
    {
        return iridium::runtime::SetPlayableServiceLiveness(*liveness);
    }
    catch (const std::exception &error)
    {
        std::cerr << "runtime-host.bin: " << error.what() << '\n';
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
    }
}

extern "C" int iridium_runtime_host_unregister_playable_service(
    const iridium::runtime::HostPlayableServiceRegistration *registration)
{
    if (registration == nullptr)
    {
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
    }

    try
    {
        return iridium::runtime::UnregisterPlayableService(*registration);
    }
    catch (const std::exception &error)
    {
        std::cerr << "runtime-host.bin: " << error.what() << '\n';
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
    }
}

extern "C" int iridium_runtime_host_release_playable_session(const char *session_identifier)
{
    try
    {
        return iridium::runtime::ReleasePlayableSession(session_identifier);
    }
    catch (const std::exception &error)
    {
        std::cerr << "runtime-host.bin: " << error.what() << '\n';
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
    }
}

extern "C" int iridium_runtime_host_record_launch_milestone(
    const char *session_identifier,
    IridiumRuntimeHostLaunchMilestone milestone)
{
    try
    {
        return iridium::runtime::RecordLaunchMilestone(session_identifier, milestone);
    }
    catch (const std::exception &error)
    {
        std::cerr << "runtime-host.bin: " << error.what() << '\n';
        return IRIDIUM_RUNTIME_HOST_REGISTRATION_INVALID_ARGUMENT;
    }
}
