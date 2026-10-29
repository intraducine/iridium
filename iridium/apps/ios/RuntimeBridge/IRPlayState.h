// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <future>
#include <stdexcept>
#include <unistd.h>
#include <vector>

static constexpr size_t irPlayStateSize = 40 * 1024 * 1024 + 8;
static constexpr uint32_t irPlayStateMagic = 0x49525032;

struct IRPlayStateFile {
    std::vector<char> path;
    FILE* file = nullptr;
    IRPlayStateFile() {
        auto name = (fs::temp_directory_path() / "iridium-play-state-XXXXXX").string();
        path.assign(name.begin(), name.end()); path.push_back(0);
        int fd = mkstemp(path.data());
        if (fd < 0) throw std::runtime_error("state temporary file");
        file = fdopen(fd, "w+b");
        if (!file) { close(fd); unlink(path.data()); throw std::runtime_error("state stream"); }
    }
    ~IRPlayStateFile() { fclose(file); unlink(path.data()); }
    IRPlayStateFile(const IRPlayStateFile&) = delete;
    IRPlayStateFile& operator=(const IRPlayStateFile&) = delete;
};

static bool irPlayWaitState(CPS2VM* vm, std::future<bool> result) {
    auto gs = static_cast<CGSH_OpenGL_Libretro*>(vm->GetGSHandler());
    // Full VM snapshots can wait for GS work on this owner thread.
    while (result.wait_for(std::chrono::milliseconds(1)) != std::future_status::ready)
        if (gs) gs->FlushMailBox();
    bool success = result.get();
    if (gs) gs->FlushMailBox();
    return success;
}

static bool irPlaySaveState(CPS2VM* vm, void* data, size_t size) {
    if (!vm || vm->GetStatus() != CVirtualMachine::PAUSED || !data || size != irPlayStateSize) return false;
    try {
        IRPlayStateFile temporary;
        if (!irPlayWaitState(vm, vm->SaveState(fs::path(temporary.path.data()))) ||
            fseek(temporary.file, 0, SEEK_END)) return false;
        long length = ftell(temporary.file);
        if (length <= 0 || static_cast<size_t>(length) > size - 8 || fseek(temporary.file, 0, SEEK_SET)) return false;
        uint32_t header[] = {irPlayStateMagic, static_cast<uint32_t>(length)};
        memset(data, 0, size); memcpy(data, header, sizeof header);
        return fread(static_cast<char*>(data) + 8, 1, length, temporary.file) == static_cast<size_t>(length);
    } catch (...) { return false; }
}

static bool irPlayLoadState(CPS2VM* vm, const void* data, size_t size) {
    if (!vm || vm->GetStatus() != CVirtualMachine::PAUSED || !data || size != irPlayStateSize) return false;
    uint32_t header[2]; memcpy(header, data, sizeof header);
    if (header[0] != irPlayStateMagic || !header[1] || header[1] > size - 8) return false;
    try {
        IRPlayStateFile temporary;
        if (fwrite(static_cast<const char*>(data) + 8, 1, header[1], temporary.file) != header[1] || fflush(temporary.file)) return false;
        return irPlayWaitState(vm, vm->LoadState(fs::path(temporary.path.data())));
    } catch (...) { return false; }
}
