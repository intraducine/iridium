"""Execute the host close adapter and its Swift fallback, without a Wine TEB."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = ROOT / "iridium/apps/ios/MadeiraSupport"


def run(args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True, timeout=45)


class HostGuestCloseTests(unittest.TestCase):
    def test_host_close_never_enters_wine_on_main_or_worker_thread(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            harness = tmp / "close.c"
            harness.write_text(r'''
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
extern int madeira_request_guest_close(void);
/* These are deliberately fatal: neither thread in this harness has a TEB. */
void *NtUserGetForegroundWindow(void) { abort(); }
int NtUserPostMessage(void *w,unsigned m,uintptr_t p,intptr_t l) {
    (void)w; (void)m; (void)p; (void)l; abort();
}
static void *worker(void *unused) {
    (void)unused;
    assert(madeira_request_guest_close()==0); return NULL;
}
int main(void) {
    assert(madeira_request_guest_close()==0);
    pthread_t thread;
    assert(pthread_create(&thread,NULL,worker,NULL)==0);
    assert(pthread_join(thread,NULL)==0);
    assert(madeira_request_guest_close()==0);
    return 0;
}
''')
            exe = tmp / "close"
            run(["cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror",
                 "-pthread", harness, SUPPORT / "MadeiraGuestControl.c", "-o", exe])
            result = run([exe])
            self.assertEqual(result.stderr.count("using queued Alt+F4"), 3)

    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler unavailable")
    def test_actual_swift_request_queues_balanced_alt_f4_with_real_c_adapter(self):
        source = (SUPPORT / "MadeiraRuntimeAdapter.swift").read_text()
        start = "    @MainActor\n    private static func requestGuestClose(keyboardFallback: Bool = false) {"
        end = "    /// A timeout is not a successful shutdown."
        self.assertEqual(source.count(start), 1)
        self.assertEqual(source.count(end), 1)
        helper = source[source.index(start):source.index(end)]
        self.assertTrue(helper.rstrip().endswith("}"))
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            obj = tmp / "close.o"
            run(["cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-c", SUPPORT / "MadeiraGuestControl.c", "-o", obj])
            swift = tmp / "close.swift"
            swift.write_text('''import Foundation
@_silgen_name("madeira_request_guest_close") func madeira_request_guest_close() -> Int32
@MainActor enum Queue {
    static var keys: [Int32] = []
    static var states: [Int32] = []
    static var releases = 0
}
@MainActor func winios_post_key(_ key: Int32, _ down: Int32) {
    precondition(Queue.releases == 1)
    Queue.keys.append(key); Queue.states.append(down)
}
enum RuntimeLogCapture { static func writeLine(_ line: String) {} }
@MainActor enum UnderTest {
    static func releaseKeys() { Queue.releases += 1 }
''' + helper + '''
    static func check(_ force: Bool) {
        Queue.keys = []; Queue.states = []; Queue.releases = 0
        requestGuestClose(keyboardFallback: force)
        precondition(Queue.keys == [0x12, 0x73, 0x73, 0x12])
        precondition(Queue.states == [1, 1, 0, 0])
        precondition(Queue.releases == 1)
    }
}
@main struct Test {
    @MainActor static func main() {
        UnderTest.check(false); UnderTest.check(true)
        print("Actual Swift close helper queued both key-downs and both key-ups.")
    }
}
''')
            exe = tmp / "swift-close"
            run(["swiftc", "-parse-as-library", "-swift-version", "5", swift, obj, "-o", exe])
            result = run([exe])
            self.assertIn("both key-downs and both key-ups", result.stdout)


if __name__ == "__main__":
    unittest.main()
