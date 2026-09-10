#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xinput.h>
#include <string.h>
#include "controller_packet.h"

// Host publishes one atomic snapshot: sequence + four (connected, XINPUT_GAMEPAD).
// No game-specific keyboard mapping. Unsupported output APIs report that fact.
static BOOL enabled = TRUE;
static void diagnostic(const char *message) {
    DWORD written;
    HANDLE file = CreateFileW(L"C:\\iridium-xinput.log", FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, 0, NULL);
    if (file != INVALID_HANDLE_VALUE) {
        WriteFile(file, message, (DWORD)strlen(message), &written, NULL);
        CloseHandle(file);
    }
}
static DWORD read_state(DWORD index, XINPUT_STATE *state) {
    static LONG first_call, first_connected;
    if (!InterlockedExchange(&first_call, 1)) diagnostic("XInput reader active\n");
    BYTE bytes[68]; DWORD count = 0;
    if (index >= 4) return ERROR_DEVICE_NOT_CONNECTED;
    if (!state) return ERROR_BAD_ARGUMENTS;
    HANDLE file = CreateFileW(L"C:\\iridium-controller.bin", GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE) return ERROR_DEVICE_NOT_CONNECTED;
    BOOL ok = ReadFile(file, bytes, sizeof(bytes), &count, NULL);
    CloseHandle(file);
    uint32_t sequence;
    if (!ok || !controller_packet(bytes, count, index, &sequence, &state->Gamepad)) return ERROR_DEVICE_NOT_CONNECTED;
    state->dwPacketNumber = sequence;
    if (!InterlockedExchange(&first_connected, 1)) diagnostic("XInput read connected controller\n");
    if (!enabled) memset(&state->Gamepad, 0, sizeof(state->Gamepad));
    return ERROR_SUCCESS;
}
DWORD WINAPI XInputGetState(DWORD index, XINPUT_STATE *state) { return read_state(index, state); }
DWORD WINAPI XInputSetState(DWORD index, XINPUT_VIBRATION *vibration) {
    XINPUT_STATE state;
    DWORD result = read_state(index, &state);
    return result ? result : ERROR_NOT_SUPPORTED;
}
void WINAPI XInputEnable(BOOL value) { enabled = value; }
DWORD WINAPI XInputGetCapabilities(DWORD index, DWORD flags, XINPUT_CAPABILITIES *caps) {
    XINPUT_STATE state; DWORD result = read_state(index, &state);
    if (result) return result;
    if (!caps) return ERROR_BAD_ARGUMENTS;
    memset(caps, 0, sizeof(*caps));
    caps->Type = XINPUT_DEVTYPE_GAMEPAD; caps->SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
    caps->Gamepad.wButtons = 0xf3ff;
    caps->Gamepad.bLeftTrigger = caps->Gamepad.bRightTrigger = 255;
    caps->Gamepad.sThumbLX = caps->Gamepad.sThumbLY = 32767;
    caps->Gamepad.sThumbRX = caps->Gamepad.sThumbRY = 32767;
    return ERROR_SUCCESS;
}
DWORD WINAPI XInputGetBatteryInformation(DWORD index, BYTE type, XINPUT_BATTERY_INFORMATION *battery) {
    XINPUT_STATE state; DWORD result = read_state(index, &state);
    if (result) return result;
    if (!battery) return ERROR_BAD_ARGUMENTS;
    battery->BatteryType = BATTERY_TYPE_UNKNOWN; battery->BatteryLevel = BATTERY_LEVEL_EMPTY;
    return ERROR_SUCCESS;
}
DWORD WINAPI XInputGetKeystroke(DWORD index, DWORD reserved, PXINPUT_KEYSTROKE key) { return ERROR_NOT_SUPPORTED; }
DWORD WINAPI XInputGetDSoundAudioDeviceGuids(DWORD index, GUID *render, GUID *capture) { return ERROR_NOT_SUPPORTED; }
DWORD WINAPI XInputGetAudioDeviceIds(DWORD index, LPWSTR render, UINT *renderCount, LPWSTR capture, UINT *captureCount) { return ERROR_NOT_SUPPORTED; }
