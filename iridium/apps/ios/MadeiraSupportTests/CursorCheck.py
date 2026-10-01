#!/usr/bin/env python3
"""Check that cursor display follows the server position, including relative input."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[4]
source = (root / "testrepos/Madeira/build/win32u-unix/driver_ios.c").read_text()
start = source.index("void winios_drv_post_mouse(")
end = source.index("\n}", start) + 2
code = r"""
#include <assert.h>
#include <stdio.h>
#include <stddef.h>
typedef void *HWND;
typedef unsigned NTSTATUS;
static void winios_log_input(const char *kind, unsigned code, NTSTATUS status) {}
typedef struct { int x, y; } POINT;
typedef struct { int type; struct { int dx, dy; unsigned mouseData, dwFlags, time, dwExtraInfo; } mi; } INPUT;
#define INPUT_MOUSE 0
#define MOUSEEVENTF_ABSOLUTE 0x8000
#define MOUSEEVENTF_MOVE 1
static int winios_direct_cursor_on(void) { return 0; }
static void winios_report_cursor_pos(void) { assert(0); }
static int desktop;
static int winios_desktop_mode(void) { return desktop; }
static HWND NtUserGetForegroundWindow(void) { return (HWND)1; }
static unsigned get_thread_dpi(void) { return 96; }
static void map_window_points(HWND a, HWND b, POINT *p, int n, unsigned dpi) { p->x += 8; p->y += 31; }
static void screen_to_client(HWND h, POINT *p) { p->x -= 8; p->y -= 31; }
static INPUT delivered;
static unsigned result;
static int calls;
static POINT shown;
static NTSTATUS send_hardware_message(HWND h, int a, INPUT *i, int b) { delivered = *i; return result; }
static int NtUserGetCursorPos(POINT *p) { *p = (POINT){400, 200}; return 1; }
static void winios_cursor_move(int x, int y) { calls++; shown = (POINT){x,y}; }
""" + source[start:end] + r"""
int main(void) {
    winios_drv_post_mouse(5, -2, 1, 0, NULL);
    assert(calls == 1 && shown.x == 392 && shown.y == 169);
    winios_drv_post_mouse(1200, 900, 0x8001, 0, NULL);
    assert(calls == 2 && shown.x == 392 && shown.y == 169);
    assert(delivered.mi.dx == 1208 && delivered.mi.dy == 931);
    desktop = 1;
    winios_drv_post_mouse(400, 200, 0x8001, 0, NULL);
    assert(shown.x == 400 && shown.y == 200 && delivered.mi.dy == 200);
    result = 1;
    winios_drv_post_mouse(5, 2, 1, 0, NULL);
    assert(calls == 3);
}
"""
with tempfile.TemporaryDirectory() as directory:
    c = Path(directory) / "cursor.c"
    c.write_text(code)
    exe = Path(directory) / "cursor"
    subprocess.run(["xcrun", "clang", str(c), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print("PASS cursor follows accepted server position, not relative deltas")
