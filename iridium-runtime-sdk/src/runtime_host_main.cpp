#include "iridium_runtime_host_api.hpp"

#include <iostream>
#include <map>
#include <stdexcept>
#include <string>

namespace {

IridiumRuntimeHostInvocationPaths parse_arguments(int argc, char** argv) {
    std::map<std::string, const char*> values;
    for (int index = 1; index < argc; index += 2) {
        if (index + 1 >= argc) {
            throw std::runtime_error("missing value for " + std::string(argv[index]));
        }
        values[argv[index]] = argv[index + 1];
    }

    const auto require = [&](const std::string& key) -> const char* {
        const auto iterator = values.find(key);
        if (iterator == values.end() || iterator->second == nullptr || iterator->second[0] == '\0') {
            throw std::runtime_error("missing required argument: " + key);
        }
        return iterator->second;
    };

    return IridiumRuntimeHostInvocationPaths{
        require("--launch-package"),
        require("--session-update"),
        require("--terminal-result"),
        require("--telemetry"),
        require("--host-log"),
    };
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const auto invocation = parse_arguments(argc, argv);
        return iridium_runtime_host_run(&invocation);
    } catch (const std::exception& error) {
        std::cerr << "runtime-host.bin: " << error.what() << '\n';
        return 64;
    }
}
