#include <stdio.h>

int madeira_request_guest_close(void) {
    /* The caller is UIKit's main thread, not a Wine thread. NtUser APIs require
     * a Wine TEB; NtUserGetForegroundWindow dereferenced NULL+0x8a8 here.
     * Returning 0 selects the adapter's existing queued Alt+F4 path. Winios
     * processes those key events on the guest side. Do not move NtUser calls
     * onto a GCD worker: an arbitrary worker has no Wine TEB either.
     * The adapter still waits for real exit and reports an unresponsive guest. */
    dprintf(2, "[IridiumClose] using queued Alt+F4; host thread must not call NtUser APIs\n");
    return 0;
}
