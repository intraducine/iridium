#!/usr/bin/env python3
"""Exercise the production keyboard sender with keypad-ambiguous scan codes."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[4]
source = (root / "testrepos/Madeira/build/win32u-unix/driver_ios.c").read_text()
start = source.index("void winios_drv_post_key(")
end = source.index("/* [winios-tree]", start)
helper_start = source.index("static UINT winios_key_extended_flag(")
helper_end = source.index("/* end winios_key_extended_flag */", helper_start)
prefix = r"""
#include <assert.h>
#include <stdio.h>
#include <stddef.h>
#include <stdlib.h>
typedef unsigned UINT;
typedef unsigned NTSTATUS;
static void winios_log_input(const char *kind, unsigned code, NTSTATUS status) {}
typedef struct { int type; struct { unsigned wVk, wScan, dwFlags, time, dwExtraInfo; } ki; } INPUT;
#define INPUT_KEYBOARD 1
#define KEYEVENTF_EXTENDEDKEY 1
#define MAPVK_VK_TO_VSC_EX 4
#define VK_PRIOR 0x21
#define VK_NEXT 0x22
#define VK_END 0x23
#define VK_HOME 0x24
#define VK_LEFT 0x25
#define VK_UP 0x26
#define VK_RIGHT 0x27
#define VK_DOWN 0x28
#define VK_INSERT 0x2d
#define VK_DELETE 0x2e
#define VK_DIVIDE 0x6f
#define VK_RCONTROL 0xa3
#define VK_RMENU 0xa5
#define VK_LWIN 0x5b
#define VK_RWIN 0x5c
#define VK_APPS 0x5d
#define VK_SNAPSHOT 0x2c
static UINT lookup;
static INPUT delivered;
static int NtUserGetKeyboardLayout(int thread) { return 0; }
static UINT NtUserMapVirtualKeyEx(UINT vk, UINT type, int layout) { return lookup; }
static NTSTATUS send_hardware_message(void *h, int f, const INPUT *i, int l) { delivered=*i; return 0; }
"""
test = r"""
int main(void) {
    const unsigned scans[] = {0x49,0x51,0x4f,0x47,0x4b,0x48,0x4d,0x50};
    for (unsigned vk=0x21; vk<=0x28; vk++) {
        lookup=scans[vk-0x21];
        for (unsigned up=0; up<=2; up+=2) {
            winios_drv_post_key(vk,up);
            assert(delivered.ki.wVk==vk && delivered.ki.wScan==lookup);
            assert(delivered.ki.dwFlags==(up|1));
        }
    }
    const unsigned plain[] = {0x41,0x57,0x58,0x5a,0x14,0x0d,0x64,0x68};
    for(unsigned i=0;i<sizeof(plain)/sizeof(*plain);i++) {
        lookup=0x4b;
        winios_drv_post_key(plain[i],0);
        assert(delivered.ki.dwFlags==0);
        winios_drv_post_key(plain[i],2);
        assert(delivered.ki.dwFlags==2);
    }
    lookup=0xe01d;
    winios_drv_post_key(VK_RCONTROL,0);
    assert(delivered.ki.wScan==0x1d && delivered.ki.dwFlags==1);
}
"""
with tempfile.TemporaryDirectory() as d:
    c=Path(d)/"keys.c"
    c.write_text(prefix+source[helper_start:helper_end]+source[start:end]+test)
    exe=Path(d)/"keys"
    subprocess.run(["xcrun","clang",str(c),"-o",str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
print("PASS dedicated arrows stay extended; ordinary keys and keypad stay distinct")
