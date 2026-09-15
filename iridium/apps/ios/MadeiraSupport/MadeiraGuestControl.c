#include <stdint.h>
#include <stdio.h>

// Keep this adapter independent from Wine headers so the app target does not
// inherit win32u's private include graph. These signatures match ntuser.h.
typedef void *HWND;
extern HWND NtUserGetForegroundWindow(void);
extern int NtUserPostMessage(HWND hwnd, unsigned int message, uintptr_t wparam, intptr_t lparam);

int madeira_request_guest_close(void) {
    static const unsigned int WM_CLOSE = 0x0010;
    HWND hwnd = NtUserGetForegroundWindow();
    if (!hwnd) {
        dprintf(2, "[IridiumClose] no foreground guest window for WM_CLOSE\n");
        return 0;
    }
    int posted = NtUserPostMessage(hwnd, WM_CLOSE, 0, 0) ? 1 : 0;
    dprintf(2, "[IridiumClose] WM_CLOSE hwnd=%p posted=%d\n", hwnd, posted);
    return posted;
}
