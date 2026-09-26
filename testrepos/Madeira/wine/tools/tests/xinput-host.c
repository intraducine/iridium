/* Host-path regression test. LGPL-2.1-or-later, like the source under test.
 * Standalone native Windows test: includes the production XInput implementation
 * and supplies a synthetic NtUserCallTwoParam import. Never starts Wine or uses
 * a physical controller. See xinput-host.md for build instructions. */
#include "../../dlls/xinput1_3/main.c"
#include <stdio.h>

static XINPUT_STATE sample;
static BOOL connected[XUSER_MAX_COUNT] = { TRUE, FALSE, FALSE, FALSE };

static ULONG_PTR WINAPI query(ULONG_PTR arg1, ULONG_PTR arg2, ULONG code)
{
    UINT index = arg1 & 0xff, op = (arg1 >> 8) & 0xff;
    assert(code == NtUserCallTwoParam_GetGamepadState);
    assert(index < XUSER_MAX_COUNT && arg2);
    if (!connected[index]) return 0;
    if (op == NtUserGamepadOp_State) *(XINPUT_STATE *)arg2 = sample;
    else if (op == NtUserGamepadOp_Caps)
    {
        XINPUT_CAPABILITIES *caps = (void *)arg2;
        memset(caps, 0, sizeof(*caps));
        caps->Type = XINPUT_DEVTYPE_GAMEPAD;
        caps->SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
    }
    else assert(0);
    return 1;
}

/* Redirect only the test binary's import. No installed DLL is modified. */
ULONG_PTR (WINAPI *__imp_NtUserCallTwoParam)(ULONG_PTR, ULONG_PTR, ULONG) = query;
const char * __cdecl __wine_dbg_strdup(const char *str) { return str; }
int __cdecl __wine_dbg_output(const char *str) { return 0; }
int __cdecl __wine_dbg_header(enum __wine_debug_class cls,
        struct __wine_debug_channel *channel, const char *function) { return -1; }

int main(void)
{
    XINPUT_STATE state;
    XINPUT_CAPABILITIES caps;
    XINPUT_KEYSTROKE key;
    XINPUT_VIBRATION vibration = {0};
    XINPUT_BATTERY_INFORMATION battery;
    GUID render, capture;

    sample.dwPacketNumber = 42;
    sample.Gamepad.wButtons = XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_GUIDE;
    sample.Gamepad.sThumbLX = -32768;
    sample.Gamepad.sThumbLY = 32767;
    sample.Gamepad.bLeftTrigger = 255;
    assert(XInputGetState(0, &state) == ERROR_SUCCESS);
    assert(state.dwPacketNumber == 42 && state.Gamepad.wButtons == XINPUT_GAMEPAD_A);
    assert(state.Gamepad.sThumbLX == -32768 && state.Gamepad.sThumbLY == 32767);
    assert(XInputGetStateEx(0, &state) == ERROR_SUCCESS);
    assert(state.Gamepad.wButtons & XINPUT_GAMEPAD_GUIDE);
    assert(XInputGetState(4, &state) == ERROR_BAD_ARGUMENTS);
    assert(XInputGetState(0, NULL) == ERROR_BAD_ARGUMENTS);
    assert(XInputGetCapabilities(0, 0, &caps) == ERROR_SUCCESS && caps.Flags == 0);
    assert(XInputGetCapabilities(0, 0, NULL) == ERROR_BAD_ARGUMENTS);
    assert(XInputSetState(0, &vibration) == ERROR_SUCCESS);
    assert(XInputSetState(0, NULL) == ERROR_BAD_ARGUMENTS);
    assert(XInputGetKeystroke(0, 0, &key) == ERROR_SUCCESS);
    assert(key.VirtualKey == VK_PAD_A && key.Flags == XINPUT_KEYSTROKE_KEYDOWN);
    sample.Gamepad.wButtons = 0;
    assert(XInputGetKeystroke(0, 0, &key) == ERROR_SUCCESS);
    assert(key.VirtualKey == VK_PAD_A && key.Flags == XINPUT_KEYSTROKE_KEYUP);
    assert(XInputGetKeystroke(0, 0, NULL) == ERROR_BAD_ARGUMENTS);
    XInputEnable(FALSE);
    assert(XInputGetState(0, &state) == ERROR_SUCCESS);
    XINPUT_GAMEPAD zero = {0};
    assert(!memcmp(&state.Gamepad, &zero, sizeof(zero)));
    XInputEnable(TRUE);
    assert(XInputGetState(0, &state) == ERROR_SUCCESS && state.Gamepad.bLeftTrigger == 255);
    assert(XInputGetBatteryInformation(0, BATTERY_DEVTYPE_GAMEPAD, &battery) == ERROR_SUCCESS);
    assert(battery.BatteryType == BATTERY_TYPE_UNKNOWN);
    assert(XInputGetDSoundAudioDeviceGuids(0, &render, &capture) == ERROR_NOT_SUPPORTED);
    assert(XInputGetDSoundAudioDeviceGuids(1, &render, &capture) == ERROR_DEVICE_NOT_CONNECTED);
    connected[0] = FALSE;
    assert(!host_pad_state(0, &state));
    assert(!memcmp(&state.Gamepad, &zero, sizeof(zero)));
    puts("PASS: host XInput state/caps/edges/disable, invalid arguments, battery and per-index audio");
    return 0;
}
