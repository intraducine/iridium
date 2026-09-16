"""Execute Wine's real ARM64EC thread-init guard with syscall stubs.

This checks error propagation, loader-lock release and callback ordering, not
Wine execution or the ARM64EC ABI on a device.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WineThreadInitTests(unittest.TestCase):
    def test_failed_fex_thread_cannot_enter_guest_callbacks(self):
        source = (ROOT / 'testrepos/Madeira/wine/dlls/ntdll/loader.c').read_text()
        loader = source[source.index('void loader_init( CONTEXT *context, void **entry )'):]
        end = loader.index('        if (NtCurrentTeb()->SkipThreadAttach)')
        start = loader.rfind('#ifdef __arm64ec__', 0, end)
        self.assertGreaterEqual(start, 0)
        guard = loader[start:end]
        self.assertEqual(guard.count('arm64ec_thread_init()'), 1)
        with tempfile.TemporaryDirectory() as directory:
            test = Path(directory) / 'thread.c'
            test.write_text(r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
typedef int32_t NTSTATUS;
#define STATUS_SUCCESS 0
#define __arm64ec__ 1
#define ERR(...) ((void)0)
static NTSTATUS init_result, exit_status;
static int loader_section, locked, releases, terminations, callbacks, calls;
static NTSTATUS arm64ec_thread_init(void) { ++calls; return init_result; }
static void RtlLeaveCriticalSection(int *section) {
    assert(section == &loader_section && locked == 1);
    locked = 0; ++releases;
}
static void *GetCurrentThread(void) { return (void *)(intptr_t)-2; }
static void NtTerminateThread(void *thread, NTSTATUS status) {
    assert(thread == GetCurrentThread() && !locked && !callbacks);
    ++terminations; exit_status = status;
    /* Return deliberately: even a returning stub must not reach callbacks. */
}
static void run_loader_guard(void) {
    NTSTATUS status;
''' + guard + r'''
    assert(locked && !terminations);
    ++callbacks;
    RtlLeaveCriticalSection(&loader_section);
}
static void check(NTSTATUS status) {
    calls = releases = terminations = callbacks = 0;
    locked = 1; init_result = status; exit_status = 0;
    run_loader_guard();
    assert(calls == 1 && releases == 1 && !locked);
    if (status) {
        assert(terminations == 1 && exit_status == status && callbacks == 0);
    } else {
        assert(terminations == 0 && callbacks == 1);
    }
}
int main(void) {
    check((NTSTATUS)0xc0000017u); /* STATUS_NO_MEMORY */
    check((NTSTATUS)0xc000000du); /* another initialization failure */
    check(STATUS_SUCCESS);
    puts("Wine init failure preserves status, releases loader lock and skips guest callbacks");
}
''')
            exe = Path(directory) / 'thread'
            build = subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                                    '-fsanitize=undefined', '-fno-sanitize-recover=undefined',
                                    str(test), '-o', str(exe)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('skips guest callbacks', result.stdout)


if __name__ == '__main__':
    unittest.main()
