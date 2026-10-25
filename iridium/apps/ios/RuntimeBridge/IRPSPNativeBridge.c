// SPDX-License-Identifier: AGPL-3.0-only
#include "IRPSPNativeBridge.h"
#include "IRAudioVolume.h"
#include <dlfcn.h>
#include <stddef.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/loader.h>
#endif

struct IRPSPJITDiagnostic {
    int descriptor;
    pthread_mutex_t lock;
    unsigned sequence;
    size_t bytes;
    bool failed;
};
static pthread_mutex_t journal_creation_lock = PTHREAD_MUTEX_INITIALIZER;
static bool journal_active;

static void journal_dispose(IRPSPJITDiagnostic *journal) {
    close(journal->descriptor); pthread_mutex_destroy(&journal->lock); free(journal);
}

static const char *stage_name(IRJITDiagnosticStage stage) {
    static const char *names[] = { "invalid", "activation.enter", "activation.return",
        "worker.enter", "load.enter", "load.return", "symbol", "abi", "image.uuid.high", "image.uuid.low",
        "native.enter", "csops", "alloc.enter", "alloc.return", "rw.enter", "rw.return",
        "emit.enter", "emit.return", "cache.enter", "cache.return", "rx.enter", "rx.return",
        "guard.enter", "guard.declined", "guard.ready", "exec.enter", "exec.return", "recovered.signal",
        "signal.offset", "handlers.restored", "free.enter", "free.return", "native.return", "worker.return",
        "main.result", "restore.enter", "restore.return", "completion", "player.enter", "player.return",
        "cancel", "timeout", "owner.release", "alloc.error", "protect.error", "native.error",
        "symbol.enter", "abi.enter", "handlers.restore.enter", "code.length",
        "code.word.0", "code.word.1", "code.word.2", "code.word.3", "call.enter",
        "probe.base", "image.base", "app.image.base", "app.image.uuid.high", "app.image.uuid.low",
        "observation.failed", "fallback", "prepare.enter", "prepare.reject", "arena.enter",
        "arena.error", "arena.return", "prepare.return", "arena.view" };
    return stage > 0 && (size_t)stage < sizeof names / sizeof *names ? names[stage] : NULL;
}

static bool journal_write(IRPSPJITDiagnostic *journal, const char *bytes, size_t count) {
    if (journal->failed || count > 32768 - journal->bytes) return journal->failed = true, false;
    size_t offset = 0;
    while (offset < count) {
        ssize_t wrote = write(journal->descriptor, bytes + offset, count - offset);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) return journal->failed = true, false;
        offset += (size_t)wrote;
    }
    journal->bytes += count;
    int result;
    do { result = fsync(journal->descriptor); } while (result < 0 && errno == EINTR);
    if (result) journal->failed = true;
    return !journal->failed;
}

static IRPSPJITDiagnostic *journal_open(const char *directory, const char *identity) {
    if (!directory || !identity || strlen(identity) > 160) return NULL;
    for (const unsigned char *p = (const unsigned char *)identity; *p; ++p)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9') ||
              *p == '.' || *p == '-' || *p == '_' || *p == '=' || *p == ' ')) return NULL;
    int folder = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (folder < 0) return NULL;
    // The creation lock also excludes a cancelled attempt's retained writer.
    struct stat status;
    if (fstatat(folder, "iridium-psp-jit-stages.log", &status, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISREG(status.st_mode) || status.st_nlink != 1 ||
            renameat(folder, "iridium-psp-jit-stages.log", folder, "iridium-psp-jit-stages.previous.log")) {
            close(folder); return NULL;
        }
    } else if (errno != ENOENT) { close(folder); return NULL; }
    int descriptor = openat(folder, "iridium-psp-jit-stages.log", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    close(folder);
    if (descriptor < 0) return NULL;
    IRPSPJITDiagnostic *journal = calloc(1, sizeof *journal);
    if (!journal) { close(descriptor); return NULL; }
    journal->descriptor = descriptor;
    if (pthread_mutex_init(&journal->lock, NULL)) { close(descriptor); free(journal); return NULL; }
    struct timespec now, monotonic; clock_gettime(CLOCK_REALTIME, &now); clock_gettime(CLOCK_MONOTONIC, &monotonic);
    char header[384];
    int length = snprintf(header, sizeof header, "IRJIT1 attempt=%lld-%09ld utc=%lld.%09ld mono=%lld.%09ld %s\n",
        (long long)now.tv_sec, now.tv_nsec, (long long)now.tv_sec, now.tv_nsec,
        (long long)monotonic.tv_sec, monotonic.tv_nsec, identity);
    if (length < 0 || (size_t)length >= sizeof header || !journal_write(journal, header, (size_t)length)) {
        journal_dispose(journal); return NULL;
    }
    return journal;
}
IRPSPJITDiagnostic *ir_psp_jit_diagnostic_open(const char *directory, const char *identity) {
    pthread_mutex_lock(&journal_creation_lock);
    IRPSPJITDiagnostic *journal = journal_active ? NULL : journal_open(directory, identity);
    if (journal) journal_active = true;
    pthread_mutex_unlock(&journal_creation_lock);
    return journal;
}

bool ir_psp_jit_diagnostic_mark(IRPSPJITDiagnostic *journal, IRJITDiagnosticStage stage,
    uint32_t pass, int64_t value, int error) {
    if (!journal) return false;
    int saved = errno;
    pthread_mutex_lock(&journal->lock);
    const char *name = stage_name(stage);
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    char line[192];
    int count = name ? snprintf(line, sizeof line,
        "seq=%u mono=%lld.%09ld stage=%s pass=%u value=%lld error=%d\n",
        ++journal->sequence, (long long)now.tv_sec, now.tv_nsec, name, pass, (long long)value, error) : -1;
    bool result = count > 0 && (size_t)count < sizeof line && journal_write(journal, line, (size_t)count);
    if (!result) journal->failed = true;
    pthread_mutex_unlock(&journal->lock);
    errno = saved;
    return result;
}
bool ir_psp_jit_diagnostic_healthy(IRPSPJITDiagnostic *journal) {
    if (!journal) return false;
    pthread_mutex_lock(&journal->lock); bool result = !journal->failed; pthread_mutex_unlock(&journal->lock);
    return result;
}
void ir_psp_jit_diagnostic_close(IRPSPJITDiagnostic *journal) {
    if (!journal) return;
    journal_dispose(journal);
    pthread_mutex_lock(&journal_creation_lock); journal_active = false; pthread_mutex_unlock(&journal_creation_lock);
}
static bool diagnostic_callback(void *context, IRJITDiagnosticStage stage, uint32_t pass, int64_t value, int error) {
    return ir_psp_jit_diagnostic_mark(context, stage, pass, value, error);
}

#ifdef __APPLE__
static bool record_image(IRPSPJITDiagnostic *journal, const void *symbol, bool app) {
    Dl_info info;
    if (!dladdr(symbol, &info) || !info.dli_fbase) return false;
    const struct mach_header_64 *header = info.dli_fbase;
    if (header->magic != MH_MAGIC_64) return false;
    const struct load_command *command = (const void *)(header + 1);
    size_t remaining = header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds && remaining >= sizeof *command; ++i) {
        if (command->cmdsize < sizeof *command || command->cmdsize > remaining) return false;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
            uint64_t halves[2]; memcpy(halves, ((const struct uuid_command *)command)->uuid, sizeof halves);
            // Private anchors are mandatory before execution; ordinary export redacts bases.
            return ir_psp_jit_diagnostic_mark(journal, app ? IR_JIT_APP_IMAGE_BASE : IR_JIT_IMAGE_BASE,
                       0, (int64_t)(uintptr_t)header, 0) &&
                   ir_psp_jit_diagnostic_mark(journal, app ? IR_JIT_APP_IMAGE_UUID_HIGH : IR_JIT_IMAGE_UUID_HIGH,
                       0, (int64_t)halves[0], 0) &&
                   ir_psp_jit_diagnostic_mark(journal, app ? IR_JIT_APP_IMAGE_UUID_LOW : IR_JIT_IMAGE_UUID_LOW,
                       0, (int64_t)halves[1], 0);
        }
        remaining -= command->cmdsize;
        command = (const void *)((const char *)command + command->cmdsize);
    }
    return false;
}
#endif

static void *handle;
static bool loaded;
static struct {
    uint32_t (*abi)(void);
    int (*check_jit)(void);
    int (*check_jit_diagnostic)(const IRJITDiagnosticSink *);
    void *(*create)(const char *, const char *, const char *, bool, IRPSPNativeEvent, IRPSPNativeInput);
    void (*pause)(void), (*resume)(void), (*stop)(void);
    uint64_t (*frames)(void);
    bool (*request)(unsigned, int);
    int (*resolution)(void);
} api;

static bool load(const char *component, const IRJITDiagnosticSink *sink) {
    if (!component) return false;
    if (!loaded) {
        if (!handle) {
            if (!ir_jit_diagnostic_mark(sink, IR_JIT_LOAD_ENTER, 0, 0, 0)) return false;
            handle = dlopen(component, RTLD_NOW | RTLD_LOCAL);
            if (!ir_jit_diagnostic_mark(sink, IR_JIT_LOAD_RETURN, 0, handle != NULL, 0)) return false;
        }
        if (!handle) return false;
        unsigned symbol = 0;
#define LOAD(name) if (!ir_jit_diagnostic_mark(sink, IR_JIT_SYMBOL_ENTER, ++symbol, 0, 0)) return false; api.name = (__typeof__(api.name))dlsym(handle, "ir_native_psp_" #name); if (!ir_jit_diagnostic_mark(sink, IR_JIT_SYMBOL, symbol, api.name != NULL, 0) || !api.name) return false;
        LOAD(abi) LOAD(check_jit) LOAD(create) LOAD(pause) LOAD(resume) LOAD(request) LOAD(resolution) LOAD(stop) LOAD(frames)
#undef LOAD
        loaded = true;
    }
    if (!ir_jit_diagnostic_mark(sink, IR_JIT_ABI_ENTER, 0, 0, 0)) return false;
    uint32_t version = api.abi ? api.abi() : 0;
    return ir_jit_diagnostic_mark(sink, IR_JIT_ABI, 0, version, 0) && version == 3 && api.create && api.stop && api.frames;
}
int ir_psp_native_check_jit(const char *component) { return load(component, NULL) ? api.check_jit() : -1; }
int ir_psp_native_check_jit_diagnostic(const char *component, IRPSPJITDiagnostic *journal) {
    if (!ir_psp_jit_diagnostic_healthy(journal)) return -6;
    IRJITDiagnosticSink sink = {journal, diagnostic_callback};
    if (!load(component, &sink)) return ir_psp_jit_diagnostic_healthy(journal) ? -1 : -6;
    // Additive ABI-3 entry point: never silently run an old untraced component.
    if (!ir_psp_jit_diagnostic_mark(journal, IR_JIT_SYMBOL_ENTER, 0, 0, 0)) return -6;
    api.check_jit_diagnostic = (__typeof__(api.check_jit_diagnostic))dlsym(handle, "ir_native_psp_check_jit_diagnostic");
    if (!ir_psp_jit_diagnostic_mark(journal, IR_JIT_SYMBOL, 0, api.check_jit_diagnostic != NULL, 0)) return -6;
    if (!api.check_jit_diagnostic) return -6;
#ifdef __APPLE__
    if (!record_image(journal, (const void *)diagnostic_callback, true) ||
        !record_image(journal, (const void *)api.check_jit_diagnostic, false)) return -6;
#endif
    return api.check_jit_diagnostic(&sink);
}
void *ir_psp_native_open(const char *component, const char *game, const char *memory_stick,
                         const char *assets, bool jit, IRPSPNativeEvent event, IRPSPNativeInput input)
{
    if (!game || !memory_stick || !assets || !event || !input || !load(component, NULL)) return NULL;
    if (!ir_audio_volume_bind(handle, "ir_native_psp_set_volume")) return NULL;
    // Objective-C classes and native globals cannot safely be unloaded with dlclose.
    return api.create(game, memory_stick, assets, jit, event, input);
}
void ir_psp_native_pause(void) { if (api.pause) api.pause(); }
void ir_psp_native_resume(void) { if (api.resume) api.resume(); }
bool ir_psp_native_request(unsigned operation, int value) { return api.request && api.request(operation, value); }
int ir_psp_native_resolution(void) { return api.resolution ? api.resolution() : 2; }
void ir_psp_native_stop(void) { if (api.stop) api.stop(); }
uint64_t ir_psp_native_frames(void) { return api.frames ? api.frames() : 0; }

static struct {
    uint32_t (*version)(void);
    int (*prepare)(const IRPSPExecHost *, const IRJITDiagnosticSink *);
    int (*detach)(uint64_t), (*shutdown)(const IRPSPExecShutdown *);
    int (*restored)(uint64_t, bool, const IRJITDiagnosticSink *), (*end)(uint64_t);
    void (*cancel)(uint64_t);
} executable;
int ir_psp_native_exec_prepare(const char *component, const IRPSPExecHost *host, IRPSPJITDiagnostic *journal) {
    if (!ir_psp_jit_diagnostic_healthy(journal)) return IR_PSP_EXEC_PREPARATION;
    IRJITDiagnosticSink sink = {journal, diagnostic_callback};
    if (!load(component, &sink)) return IR_PSP_EXEC_UNAVAILABLE;
    unsigned index = 16;
#define EXEC_LOAD(field, symbol) if (!ir_jit_diagnostic_mark(&sink, IR_JIT_SYMBOL_ENTER, ++index, 0, 0)) return IR_PSP_EXEC_PREPARATION; executable.field = (__typeof__(executable.field))dlsym(handle, "ir_native_psp_exec_" symbol); if (!ir_jit_diagnostic_mark(&sink, IR_JIT_SYMBOL, index, executable.field != NULL, 0)) return IR_PSP_EXEC_PREPARATION; if (!executable.field) return IR_PSP_EXEC_UNAVAILABLE;
    EXEC_LOAD(version, "version")
    uint32_t version = executable.version();
    if (version != IR_PSP_EXEC_VERSION) {
        ir_jit_diagnostic_mark(&sink, IR_JIT_PREPARE_REJECT, 11, version, 0);
        memset(&executable, 0, sizeof executable); return IR_PSP_EXEC_UNAVAILABLE;
    }
    EXEC_LOAD(prepare, "prepare_diagnostic") EXEC_LOAD(detach, "detach")
    EXEC_LOAD(shutdown, "accept_shutdown") EXEC_LOAD(restored, "restored_diagnostic") EXEC_LOAD(end, "end") EXEC_LOAD(cancel, "cancel")
#undef EXEC_LOAD
#ifdef __APPLE__
    if (!record_image(journal, (const void *)diagnostic_callback, true) ||
        !record_image(journal, (const void *)executable.prepare, false)) return IR_PSP_EXEC_PREPARATION;
#endif
    return executable.prepare(host, &sink);
}
bool ir_psp_native_exec_supports_shared(const char *component) {
    return load(component, NULL) && dlsym(handle, "ir_native_psp_exec_prepare_shared") != NULL;
}
int ir_psp_native_exec_prepare_shared(const char *component, uint64_t owner, const IRJITMemoryAPI *api, IRPSPJITDiagnostic *journal) {
    if (!ir_psp_jit_diagnostic_healthy(journal)) return IR_PSP_EXEC_PREPARATION;
    IRJITDiagnosticSink sink = {journal, diagnostic_callback};
    if (!load(component, &sink)) return IR_PSP_EXEC_UNAVAILABLE;
    int (*prepare)(uint64_t, const IRJITMemoryAPI *, const IRJITDiagnosticSink *) =
        (int (*)(uint64_t, const IRJITMemoryAPI *, const IRJITDiagnosticSink *))dlsym(handle, "ir_native_psp_exec_prepare_shared");
    executable.end = (int (*)(uint64_t))dlsym(handle, "ir_native_psp_exec_end");
    uint32_t (*version)(void) = (uint32_t (*)(void))dlsym(handle, "ir_native_psp_exec_version");
    if (!prepare || !executable.end || !version || version() != IR_PSP_EXEC_VERSION) return IR_PSP_EXEC_UNAVAILABLE;
#ifdef __APPLE__
    if (!record_image(journal, (const void *)diagnostic_callback, true) ||
        !record_image(journal, (const void *)prepare, false)) return IR_PSP_EXEC_PREPARATION;
#endif
    return prepare(owner, api, &sink);
}
int ir_psp_native_exec_detach(uint64_t owner) { return executable.detach ? executable.detach(owner) : IR_PSP_EXEC_UNAVAILABLE; }
int ir_psp_native_exec_shutdown(const IRPSPExecShutdown *receipt) { return executable.shutdown ? executable.shutdown(receipt) : IR_PSP_EXEC_UNAVAILABLE; }
int ir_psp_native_exec_restored_diagnostic(uint64_t owner, bool success, IRPSPJITDiagnostic *journal) {
    IRJITDiagnosticSink sink = {journal, diagnostic_callback};
    return executable.restored ? executable.restored(owner, success, journal ? &sink : NULL) : IR_PSP_EXEC_UNAVAILABLE;
}
int ir_psp_native_exec_restored(uint64_t owner, bool success) { return ir_psp_native_exec_restored_diagnostic(owner, success, NULL); }
void ir_psp_native_exec_cancel(uint64_t owner) { if (executable.cancel) executable.cancel(owner); }
int ir_psp_native_exec_end(uint64_t owner) { return executable.end ? executable.end(owner) : IR_PSP_EXEC_OK; }
