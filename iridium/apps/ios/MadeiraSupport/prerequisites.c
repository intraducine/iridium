/* SPDX-License-Identifier: GPL-3.0-or-later
 * Service-manager startup adapted from willfaust/madeira-dock src/scm.c
 * at 3cadfbea700e4da4b04e331dd7ef1ba633dfacef. Copyright 2026 125hz.
 * Madeira Converter Exception: see testrepos/Madeira/LICENSE-EXCEPTION.md.
 * Iridium: run only included prerequisites, then the selected game. No Dock client.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsvc.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#define CAP 32768
static wchar_t executable[CAP], command[CAP], directory[CAP], key[CAP], name[CAP];
static const wchar_t *config;
static void status(const char *phase, UINT run, UINT runs, UINT process, UINT processes)
{
    FILE *file = fopen("C:\\IridiumPrerequisites\\status.txt", "w");
    if (!file) return; /* Status reporting must not change installer exit handling. */
    if (!strcmp(phase, "installer")) fprintf(file, "%s %u %u %u %u\n", phase, run, runs, process, processes);
    else fprintf(file, "%s\n", phase);
    fclose(file);
}
static BOOL cancelled(void)
{
    return GetFileAttributesW(L"C:\\IridiumPrerequisites\\cancel.flag") != INVALID_FILE_ATTRIBUTES;
}

static BOOL field(const wchar_t *section, const wchar_t *key_name, wchar_t *value)
{
    DWORD size = GetPrivateProfileStringW(section, key_name, L"", value, CAP, config);
    /* Sentinels preserve quotes and leading/trailing whitespace in INI values. */
    if (size < 2 || size == CAP - 1 || value[0] != L'x' || value[size - 1] != L'x') return FALSE;
    memmove(value, value + 1, (size - 2) * sizeof(*value));
    value[size - 2] = 0;
    return TRUE;
}

static DWORD services_start(void)
{
    SC_HANDLE manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    if (manager) { CloseServiceHandle(manager); return 0; }
    DWORD first = GetLastError();
    if (first != RPC_S_SERVER_UNAVAILABLE) return first;
    /* services.exe signals this event when its svcctl RPC endpoint is ready.
     * Reuse an existing start instead of spawning a second service manager.
     */
    HANDLE event = CreateEventW(NULL, TRUE, FALSE, L"__wine_SvcctlStartedEvent");
    if (!event) return GetLastError();
    BOOL other = GetLastError() == ERROR_ALREADY_EXISTS;
    PROCESS_INFORMATION process = {0};
    DWORD error = ERROR_TIMEOUT;
    if (!other) {
        STARTUPINFOW startup = {0};
        startup.cb = sizeof(startup);
        if (!GetSystemDirectoryW(directory, CAP - 32)) { error = GetLastError(); goto out; }
        swprintf(executable, CAP, L"%ls\\services.exe", directory);
        if (!CreateProcessW(executable, NULL, NULL, NULL, FALSE, DETACHED_PROCESS,
                            NULL, directory, &startup, &process)) { error = GetLastError(); goto out; }
        CloseHandle(process.hThread);
    }
    ULONGLONG deadline = GetTickCount64() + 30000;
    do {
        if (cancelled()) { error = ERROR_CANCELLED; break; }
        manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
        if (manager) { CloseServiceHandle(manager); error = 0; break; }
        DWORD rpc = GetLastError();
        if (rpc != RPC_S_SERVER_UNAVAILABLE && rpc != RPC_S_SERVER_TOO_BUSY) { error = rpc; break; }
        if (process.hProcess && WaitForSingleObject(process.hProcess, 0) == WAIT_OBJECT_0) {
            error = ERROR_PROCESS_ABORTED; break;
        }
        /* The event alone is insufficient on the iOS port: also probe RPC. */
        Sleep(100);
    } while (GetTickCount64() < deadline);
out:
    if (process.hProcess) {
        if (error) { TerminateProcess(process.hProcess, error); WaitForSingleObject(process.hProcess, 5000); }
        CloseHandle(process.hProcess);
    }
    CloseHandle(event);
    return error;
}

static BOOL installed(DWORD code) { return code == 0 || code == 3010 || code == 1641; }

static DWORD run_process(DWORD timeout, BOOL *exited)
{
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup);
    if (exited) *exited = FALSE;
    if (!CreateProcessW(executable, command, NULL, NULL, FALSE, 0, NULL,
                        directory, &startup, &process)) return GetLastError();
    CloseHandle(process.hThread);
    DWORD code = ERROR_PROCESS_ABORTED;
    ULONGLONG deadline = GetTickCount64() + timeout;
    DWORD waited;
    do {
        waited = WaitForSingleObject(process.hProcess, timeout == INFINITE ? INFINITE : 100);
        if (waited != WAIT_TIMEOUT || timeout == INFINITE) break;
        if (cancelled() || GetTickCount64() >= deadline) break;
    } while (TRUE);
    if (waited == WAIT_OBJECT_0) {
        if (!GetExitCodeProcess(process.hProcess, &code)) code = GetLastError();
        else if (exited) *exited = TRUE;
    } else {
        code = cancelled() ? ERROR_CANCELLED : waited == WAIT_TIMEOUT ? ERROR_TIMEOUT : GetLastError();
        /* End only this helper's stuck installer, never a host/runtime thread. */
        if (TerminateProcess(process.hProcess, code)) WaitForSingleObject(process.hProcess, 5000);
    }
    CloseHandle(process.hProcess);
    return code;
}

static DWORD record_run(const wchar_t *section)
{
    UINT hive = GetPrivateProfileIntW(section, L"hive", 0, config);
    UINT count = GetPrivateProfileIntW(section, L"keys", 0, config);
    DWORD value = GetPrivateProfileIntW(section, L"value", 0, config);
    if ((hive != 1 && hive != 2) || !count || count > 2 || !value || !field(section, L"name", name))
        return ERROR_INVALID_DATA;
    for (UINT i = 0; i < count; i++) {
        wchar_t key_name[16];
        swprintf(key_name, 16, L"key%u", i);
        if (!field(section, key_name, key)) return ERROR_INVALID_DATA;
        HKEY handle;
        LSTATUS error = RegCreateKeyExW(hive == 1 ? HKEY_LOCAL_MACHINE : HKEY_CURRENT_USER,
            key, 0, NULL, 0, KEY_QUERY_VALUE | KEY_SET_VALUE | KEY_WOW64_64KEY, NULL, &handle, NULL);
        if (error) return error;
        DWORD previous = 0, type = 0, size = sizeof(previous);
        error = RegQueryValueExW(handle, name, NULL, &type, (BYTE *)&previous, &size);
        if (!error && type == REG_DWORD && size == sizeof(previous) && previous >= value) {
            RegCloseKey(handle);
            continue;
        }
        if (!error || error == ERROR_FILE_NOT_FOUND || error == ERROR_MORE_DATA)
            error = RegSetValueExW(handle, name, 0, REG_DWORD, (const BYTE *)&value, sizeof(value));
        if (!error) error = RegFlushKey(handle);
        RegCloseKey(handle);
        if (error) return error;
    }
    return 0;
}

int wmain(int argc, wchar_t **argv)
{
    if (argc != 2) return ERROR_INVALID_PARAMETER;
    if (cancelled()) return ERROR_CANCELLED;
    config = argv[1];
    UINT runs = GetPrivateProfileIntW(L"plan", L"runs", 0, config);
    if (!runs || runs > 64) return ERROR_INVALID_DATA;
    status("services", 0, 0, 0, 0);
    DWORD code = services_start();
    fprintf(stderr, "[Prerequisites] Wine services: %lu\n", code);
    if (code) return code;
    for (UINT i = 0; i < runs; i++) {
        if (cancelled()) return ERROR_CANCELLED;
        wchar_t section[32];
        swprintf(section, 32, L"run%u", i);
        UINT count = GetPrivateProfileIntW(section, L"processes", 0, config);
        if (!count || count > 64) return ERROR_INVALID_DATA;
        for (UINT j = 0; j < count; j++) {
            wchar_t step[32];
            swprintf(step, 32, L"process%u_%u", i, j);
            if (!field(step, L"executable", executable) || !field(step, L"command", command)
                || !field(step, L"directory", directory)) return ERROR_INVALID_DATA;
            fprintf(stderr, "[Prerequisites] Running installer %u/%u, process %u/%u\n", i + 1, runs, j + 1, count);
            status("installer", i + 1, runs, j + 1, count);
            BOOL exited;
            code = run_process(600000, &exited);
            fprintf(stderr, "[Prerequisites] Installer %u process %u exited: %lu\n", i + 1, j + 1, code);
            if (!exited || !installed(code)) return code ? code : ERROR_PROCESS_ABORTED;
        }
        /* A shared HasRunKey is complete only after ALL its processes succeed. */
        code = record_run(section);
        if (code) return code;
    }
    if (cancelled()) return ERROR_CANCELLED;
    if (!field(L"game", L"executable", executable) || !field(L"game", L"command", command)
        || !field(L"game", L"directory", directory)) return ERROR_INVALID_DATA;
    fprintf(stderr, "[Prerequisites] Complete. Starting the selected game.\n");
    status("game", 0, 0, 0, 0);
    return run_process(INFINITE, NULL);
}
