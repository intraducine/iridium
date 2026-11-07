// SPDX-License-Identifier: AGPL-3.0-only
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <stdlib.h>

static wchar_t request_path[1100], status_path[1100], temporary_path[1100], stop_path[1100];
#include "IRWindowsSession.h"

static bool same_key(const wchar_t *a, const wchar_t *b) {
    const wchar_t *end = wcschr(a, L'=');
    size_t length = end ? (size_t)(end - a) : wcslen(a);
    const wchar_t *other = wcschr(b, L'=');
    return other && (size_t)(other - b) == length && !_wcsnicmp(a, b, length);
}
static wchar_t *environment(const wchar_t *base, const uint16_t *overrides) {
    wchar_t *block = calloc(32768, sizeof(*block));
    if (!block) return NULL;
    size_t used = 0;
    for (const wchar_t *item = base; *item; item += wcslen(item) + 1) {
        bool replaced = !_wcsnicmp(item, L"MADEIRA_", 8) || !_wcsnicmp(item, L"FEX_", 4) ||
            !_wcsnicmp(item, L"DXMT_", 5) || !_wcsnicmp(item, L"SteamAppId=", 11) ||
            !_wcsnicmp(item, L"SteamGameId=", 12) || !_wcsnicmp(item, L"SteamAppPath=", 13);
        for (const wchar_t *value = (const wchar_t *)overrides; !replaced && *value; value += wcslen(value) + 1)
            replaced = same_key(value, item);
        if (replaced) continue;
        size_t length = wcslen(item) + 1;
        if (length >= 32767 - used) { free(block); return NULL; }
        memcpy(block + used, item, length * sizeof(*item)); used += length;
    }
    for (const wchar_t *item = (const wchar_t *)overrides; *item; item += wcslen(item) + 1) {
        size_t length = wcslen(item) + 1;
        if (!wcschr(item, L'=') || item[0] == L'=' || length >= 32767 - used) { free(block); return NULL; }
        memcpy(block + used, item, length * sizeof(*item)); used += length;
    }
    return block;
}

static bool read_file(const wchar_t *path, void *bytes, size_t size) {
    FILE *file = _wfopen(path, L"rb");
    if (!file) return false;
    bool ok = fread(bytes, 1, size, file) == size && fgetc(file) == EOF && !ferror(file);
    fclose(file);
    return ok;
}
static bool publish(const IRWindowsStatus *status) {
    FILE *file = _wfopen(temporary_path, L"wb");
    if (!file) return false;
    bool ok = fwrite(status, 1, sizeof(*status), file) == sizeof(*status);
    if (fclose(file)) ok = false;
    return ok && MoveFileExW(temporary_path, status_path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

static int session(const wchar_t *directory) {
    if (!*directory || wcslen(directory) > 1024) return 1;
    swprintf(request_path, 1100, L"%ls\\request.bin", directory);
    swprintf(status_path, 1100, L"%ls\\status.bin", directory);
    swprintf(temporary_path, 1100, L"%ls\\status.tmp", directory);
    swprintf(stop_path, 1100, L"%ls\\stop.bin", directory);
    IRWindowsStatus status = { .magic = IR_WINDOWS_SESSION_MAGIC, .version = IR_WINDOWS_SESSION_VERSION };
    HANDLE job = NULL, process = NULL;
    wchar_t *base_environment = GetEnvironmentStringsW();
    if (!base_environment) return 1;
    bool terminating = false, failed = false;
    unsigned heartbeat = 0;
    if (!publish(&status)) return 2;
    for (;;) {
        if (!job) {
            IRWindowsLaunch request;
            if (GetFileAttributesW(request_path) != INVALID_FILE_ATTRIBUTES) {
                bool valid = read_file(request_path, &request, sizeof(request)) && ir_windows_launch_valid(&request);
                if (!DeleteFileW(request_path)) return 3;
                if (!valid) return 4;
                memcpy(status.token, request.token, sizeof(status.token));
                status.phase = IR_WINDOWS_FAILED; status.result = 0;
                job = CreateJobObjectW(NULL, NULL);
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
                limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                STARTUPINFOW startup = { .cb = sizeof(startup) };
                PROCESS_INFORMATION child = {0};
                wchar_t command[5124];
                wchar_t *variables = environment(base_environment, request.environment);
                if (!variables) SetLastError(ERROR_BAD_ENVIRONMENT);
                int length = swprintf(command, sizeof(command) / sizeof(*command), L"\"%ls\" %ls",
                    (wchar_t *)request.executable, (wchar_t *)request.arguments);
                if (!job || !variables || length < 0 || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) ||
                    !CreateProcessW((wchar_t *)request.executable, command, NULL, NULL, FALSE,
                        CREATE_SUSPENDED | CREATE_NEW_PROCESS_GROUP | CREATE_UNICODE_ENVIRONMENT, variables, (wchar_t *)request.directory, &startup, &child)) {
                    status.result = GetLastError();
                    if (job) CloseHandle(job);
                    job = NULL;
                } else {
                    process = child.hProcess;
                    if (!AssignProcessToJobObject(job, process) || ResumeThread(child.hThread) == (DWORD)-1) {
                        status.result = GetLastError();
                        if (!TerminateProcess(process, status.result)) return 5;
                        terminating = true; failed = true; status.phase = IR_WINDOWS_DRAINING;
                    } else status.phase = IR_WINDOWS_RUNNING;
                    CloseHandle(child.hThread);
                }
                free(variables);
                if (!publish(&status)) return 6;
            }
        } else {
            IRWindowsStatus stop;
            if (read_file(stop_path, &stop, sizeof(stop))) {
                if (!DeleteFileW(stop_path)) return 7;
                if (stop.magic == status.magic && stop.version == status.version && !memcmp(stop.token, status.token, sizeof(stop.token))) {
                    if (!TerminateJobObject(job, ERROR_CANCELLED)) return 8;
                    terminating = true;
                }
            }
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting = {0};
            if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &accounting, sizeof(accounting), NULL)) return 9;
            if (WaitForSingleObject(process, 0) == WAIT_OBJECT_0) {
                if (!terminating) {
                    if (!GetExitCodeProcess(process, (DWORD *)&status.result)) return 10;
                    status.phase = IR_WINDOWS_DRAINING;
                    if (!publish(&status)) return 11;
                }
                // A short-lived launcher can exit while its game still runs in this job.
                terminating = true;
                if (!accounting.ActiveProcesses) {
                    CloseHandle(process); CloseHandle(job); process = job = NULL;
                    terminating = false;
                    status.phase = failed ? IR_WINDOWS_FAILED : IR_WINDOWS_EXITED; failed = false;
                    if (!publish(&status)) return 13;
                }
            }
        }
        if (++heartbeat == 10) {
            heartbeat = 0;
            if (!publish(&status)) return 14;
        }
        Sleep(100);
    }
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, wchar_t *command, int show) {
    (void)instance; (void)previous; (void)show;
    size_t length = wcslen(command);
    if (length >= 2 && command[0] == L'"' && command[length-1] == L'"') { ++command; length -= 2; }
    if (!length || length > 1024) return 1;
    wchar_t directory[1025];
    memcpy(directory, command, length * sizeof(*command)); directory[length] = 0;
    return session(directory);
}
