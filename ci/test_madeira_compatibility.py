"""Execute the scoped v0.2.1 memory/startup ports with host platform stubs."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MADEIRA = ROOT / "testrepos/Madeira"
VIRTUAL = (MADEIRA / "build/ntdll-unix/virtual_ios.c").read_text()


def function(source, signature):
    """Extract a complete source function; braces in these bodies are balanced."""
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end] + "\n"


def run_c(code, variants=({},)):
    with tempfile.TemporaryDirectory() as folder:
        source = Path(folder) / "test.c"
        binary = Path(folder) / "test"
        source.write_text(code)
        subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                        "-pthread", str(source), "-o", str(binary)], check=True,
                       capture_output=True, text=True, timeout=45)
        for extra in variants:
            env = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
            env.update(extra)
            subprocess.run([str(binary)], check=True, env=env, capture_output=True,
                           text=True, timeout=10)


@unittest.skipUnless(shutil.which("cc"), "C compiler required")
class MadeiraMemoryCompatibilityTests(unittest.TestCase):
    def test_rwx_heap_eligibility_and_host_page_neighbours(self):
        start = VIRTUAL.index("static int ios_alloc_ec_code;")
        end = VIRTUAL.index("static inline int mprotect_exec", start)
        code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#define WINE_IOS 1
#define SEC_IMAGE 1
#define VPROT_ARM64EC 2
#define VPROT_SYSTEM 4
#define VPROT_WRITE 8
#define VPROT_EXEC 16
#define SEC_FILE 32
struct file_view { void *base; size_t size; unsigned protect; int valloc; };
static struct file_view views[3];
static int arm64ec_view = 1, alias;
void *ios_jit_rx_base_global;
size_t ios_jit_pool_size_global;
static int is_view_valloc(const struct file_view *v) { return v->valloc; }
static struct file_view *find_view(const void *p, size_t size) {
    uintptr_t a = (uintptr_t)p;
    for (int i = 0; i < 3; i++)
        if (a >= (uintptr_t)views[i].base && a + size <= (uintptr_t)views[i].base + views[i].size)
            return &views[i];
    return NULL;
}
int ios_jit_anon_alias_find_cover(void *p, size_t n, void **rw, void **rx) {
    (void)p; (void)n; (void)rw; (void)rx; return alias;
}
''' + VIRTUAL[start:end] + r'''
int main(void) {
    views[0] = (struct file_view){(void *)0x100000, 0x41000, VPROT_WRITE | VPROT_EXEC, 1};
    if (!ios_guest_rwx_data_enabled()) {
        assert(!ios_guest_anon_rwx_is_host_data(views[0].base, 0x44000)); return 0;
    }
    assert(ios_guest_anon_rwx_is_host_data(views[0].base, 0x44000));
    views[1] = (struct file_view){(void *)0x141000, 0x1000, VPROT_WRITE | VPROT_EXEC, 1};
    assert(!ios_guest_anon_rwx_is_host_data(views[0].base, 0x44000));
    views[1].size = 0x41000;
    assert(ios_guest_anon_rwx_is_host_data(views[0].base, 0x44000));
    views[1].size = 0;
    views[0].protect = VPROT_WRITE; // mandatory follow-up: RW then RX is code
    assert(!ios_guest_anon_rwx_is_host_data(views[0].base, 0x44000));
    unsigned excluded[] = {SEC_IMAGE, VPROT_ARM64EC, VPROT_SYSTEM};
    for (unsigned i = 0; i < sizeof excluded / sizeof excluded[0]; i++) {
        views[0].protect = VPROT_WRITE | VPROT_EXEC | excluded[i];
        assert(!ios_guest_anon_rwx_is_host_data(views[0].base, 0x44000));
    }
    views[0].protect = VPROT_WRITE | VPROT_EXEC;
    views[0].valloc = 0; assert(!ios_guest_anon_rwx_is_host_data(views[0].base, 0x44000));
    views[0].valloc = 1;
    size_t excluded_sizes[] = {0x1000, 0xf000, 0x10000, 0x100000};
    for (unsigned i = 0; i < sizeof excluded_sizes / sizeof excluded_sizes[0]; i++) {
        views[0].size = excluded_sizes[i]; assert(!ios_guest_anon_rwx_view_ok(&views[0]));
    }
    views[0].size = 0x41000;
    ios_alloc_ec_code = 1; assert(!ios_guest_anon_rwx_is_host_data(views[0].base, 0x44000));
    ios_alloc_ec_code = 0;
    alias = 1; assert(!ios_guest_anon_rwx_is_host_data(views[0].base, 0x44000)); alias = 0;
    ios_jit_rx_base_global = (void *)0x140000; ios_jit_pool_size_global = 0x100000;
    assert(!ios_guest_anon_rwx_is_host_data(views[0].base, 0x44000));
    ios_jit_rx_base_global = NULL;
    arm64ec_view = 0; assert(!ios_guest_anon_rwx_is_host_data(views[0].base, 0x44000)); arm64ec_view = 1;
    assert(!ios_guest_anon_rwx_is_host_data((void *)UINTPTR_MAX, 2));
    assert(!ios_guest_anon_rwx_is_host_data((void *)0x200000, 0x4000));
    return 0;
}
'''
        run_c(code, ({}, {"MADEIRA_GUEST_RWX_DATA": "0"}, {"MADEIRA_GUEST_RWX_DATA": "N"}))
        allocation = function(VIRTUAL, "static NTSTATUS allocate_virtual_memory(")
        self.assertLess(allocation.index("ios_alloc_ec_code ="), allocation.index("map_view("))
        self.assertLess(allocation.index("ios_alloc_ec_code = 0;"), allocation.index("server_leave_uninterrupted_section"))
        protect = function(VIRTUAL, "static inline int mprotect_exec(")
        heap_arm = protect[protect.index("else if ((unix_prot & PROT_EXEC) && ios_guest_anon_rwx_is_host_data"):]
        self.assertIn("unix_prot &= ~PROT_EXEC;", heap_arm)

    def test_small_fixed_exe_window_claim_preserves_bounds_and_retirement(self):
        code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>
typedef uintptr_t vm_address_t;
typedef size_t vm_size_t;
typedef int kern_return_t;
#define KERN_SUCCESS 0
#define IOS_EXEWIN_HELD_READY 1
#define IOS_EXEWIN_CLAIMING 2
static uint64_t ios_exe_win_base = 0x140000000ULL, ios_exe_win_size = 0x10000000;
static int ios_exe_win_state = 1, ios_exe_win_stripped_request;
static void *ios_exe_win_held_base, *ios_exewin_pending_base;
static size_t ios_exe_win_held_size, ios_exewin_pending_size;
static int ios_exewin_st, deallocations, dealloc_fail, pending;
static pthread_mutex_t ios_exewin_lock = PTHREAD_MUTEX_INITIALIZER;
static int mach_task_self(void) { return 1; }
static int vm_deallocate(int t, uintptr_t a, size_t n) {
    (void)t; assert(a >= ios_exe_win_base && n <= ios_exe_win_size); deallocations++; return dealloc_fail;
}
static void ios_exe_win_init(void) { abort(); }
static const char *ios_exewin_state_name(int state) { (void)state; return "test"; }
static void ios_exe_win_note_pending(const void *a, size_t n) { (void)a; (void)n; pending++; }
''' + function(VIRTUAL, "static int ios_exe_win_small_fixed(") + function(VIRTUAL, "static int ios_exe_win_claim(") + r'''
int main(void) {
    void *base = (void *)(uintptr_t)ios_exe_win_base;
    assert(!ios_exe_win_claim(base, 0x100000)); assert(!deallocations);
    ios_exe_win_stripped_request = 1;
    if (!ios_exe_win_small_fixed()) { assert(!ios_exe_win_claim(base, 0x100000)); return 0; }
    assert(!ios_exe_win_claim((char *)base - 1, 0x100000));
    assert(!ios_exe_win_claim((char *)base + ios_exe_win_size - 1, 0x100000));
    dealloc_fail = 1; assert(!ios_exe_win_claim(base, 0x100000)); assert(ios_exe_win_state == 1);
    dealloc_fail = 0; assert(ios_exe_win_claim(base, 0x100000)); assert(pending == 1);
    ios_exe_win_held_base = base; ios_exe_win_held_size = 0x100000;
    ios_exewin_st = 0; assert(!ios_exe_win_claim(base, 0x100000)); // retirement incomplete
    ios_exewin_st = IOS_EXEWIN_HELD_READY;
    assert(!ios_exe_win_claim(base, 0x110000)); // wrong interval
    assert(ios_exe_win_claim(base, 0x100000)); assert(ios_exewin_st == IOS_EXEWIN_CLAIMING);
    assert(ios_exewin_pending_base == base && ios_exewin_pending_size == 0x100000);
    ios_exe_win_state = 1; ios_exe_win_stripped_request = 0;
    assert(ios_exe_win_claim(base, 0x4000000)); // original large relocatable path
    return 0;
}
'''
        run_c(code, ({}, {"MADEIRA_EXE_WINDOW_SMALL_FIXED": "0"}))
        image = function(VIRTUAL, "static NTSTATUS map_image_view(")
        claim = image[image.index("ios_exe_win_stripped_request ="):]
        self.assertLess(claim.index("IMAGE_FILE_RELOCS_STRIPPED"), claim.index("status = map_view("))
        self.assertLess(claim.index("status = map_view("), claim.index("ios_exe_win_stripped_request = 0;"))
        self.assertLess(claim.index("ios_exe_win_stripped_request = 0;"), claim.index("ios_exe_win_commit_claim("))

    def test_shared_section_fallback_uses_original_image_and_keeps_shared_offsets(self):
        start = VIRTUAL.index("        if ((sec[i].Characteristics & IMAGE_SCN_MEM_SHARED)")
        end = VIRTUAL.index("    private_section:", start)
        code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
typedef size_t SIZE_T;
typedef uintptr_t UINT_PTR;
typedef unsigned NTSTATUS;
#define IMAGE_SCN_MEM_SHARED 1
#define IMAGE_SCN_MEM_WRITE 2
#define VPROT_COMMITTED 4
#define VPROT_READ 8
#define VPROT_WRITE 16
#define VPROT_WRITECOPY 32
#define FALSE 0
#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER 1
#define STATUS_ACCESS_DENIED 2
#define ROUND_SIZE(a,b,m) (((b) + ((a) & (m)) + (m)) & ~(m))
#define TRACE_(x) noop
#define ERR_(x) noop
#define IOS_IMG_FAIL(n) (void)(n)
#define debugstr_us(n) (n)
#define noop(...) ((void)0)
static unsigned host_page_size = 0x4000, host_page_mask = 0x3fff;
static int calls, private_calls;
static size_t offsets[4];
static unsigned answer;
static unsigned map_file_into_view(void *view, int fd, unsigned start, size_t size,
                                  size_t offset, unsigned prot, int removable) {
    (void)view; (void)start; (void)size; (void)prot; (void)removable;
    offsets[calls++] = offset;
    if (fd == 4) return answer;
    assert(fd == 3 && prot == (VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY));
    private_calls++; return STATUS_SUCCESS;
}
''' + function(VIRTUAL, "static int ios_shared_section_private(") + r'''
static int map_sections(unsigned result) {
    struct section { unsigned Characteristics, VirtualAddress, PointerToRawData; char Name[8]; };
    struct section sec[2] = {{3, 0x1000, 0x600, "first"}, {3, 0x8000, 0x800, "second"}};
    struct directory { unsigned VirtualAddress, Size; } *imports = NULL;
    unsigned i; size_t pos = 0, map_size = 0x4000, file_size = 0x200;
    const char *nt_name = "fixture"; char *ptr = NULL; void *view = NULL;
    int shared_fd = 4; answer = result; (void)ptr; (void)file_size;
    for (i = 0; i < 2; i++) {
''' + VIRTUAL[start:end] + r'''
    private_section:
        assert(map_file_into_view(view, 3, sec[i].VirtualAddress, file_size,
                                  sec[i].PointerToRawData, VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY, 0) == 0);
    }
    return 0;
done:
    return -1;
}
int main(void) {
    assert(map_sections(STATUS_SUCCESS) == 0);
    assert(calls == 2 && offsets[0] == 0 && offsets[1] == 0x4000 && !private_calls);
    calls = 0;
    assert(map_sections(STATUS_ACCESS_DENIED) == -1); assert(!private_calls);
    calls = 0;
    if (!ios_shared_section_private()) { assert(map_sections(STATUS_INVALID_PARAMETER) == -1); return 0; }
    assert(map_sections(STATUS_INVALID_PARAMETER) == 0);
    assert(calls == 4 && private_calls == 2);
    assert(offsets[0] == 0 && offsets[1] == 0x600 && offsets[2] == 0x4000 && offsets[3] == 0x800);
    return 0;
}
'''
        run_c(code, ({}, {"MADEIRA_SHARED_SECTION_PRIVATE": "0"}))
        # The private label must enter the existing file/zero-fill path.
        private = VIRTUAL[end:VIRTUAL.index("    /* sections mapped OK */", end)]
        self.assertIn("map_file_into_view( view, fd,", private)
        self.assertIn("memset(", private)

    def test_native_ready_child_machine_and_guest_window_arm_agree(self):
        source = (MADEIRA / "build/ntdll-unix/process_ios.c").read_text()
        assignment = re.search(r"    ios_child_main_machine = .*?;", source, re.S)[0]
        arm = re.search(r"    if \(machine == IMAGE_FILE_MACHINE_I386 && .*?ios_wow_session_arm\(\);", source, re.S)[0]
        run_c(r'''
#include <assert.h>
#define IMAGE_FLAGS_ComPlusNativeReady 1
#define IMAGE_FILE_MACHINE_I386 0x14c
static int armed;
static void ios_wow_session_arm(void) { armed++; }
static void check(unsigned machine, unsigned flags, unsigned expected, int wow) {
    struct info { unsigned machine, image_flags; } pe_info = {machine, flags};
    struct args_t { struct info pe_info; } storage = {pe_info}, *args = &storage;
    unsigned native_machine = 0xaa64, ios_child_main_machine;
    armed = 0;
''' + assignment + arm + r'''
    assert(ios_child_main_machine == expected && armed == wow);
}
int main(void) {
    check(0x14c, 1, 0xaa64, 0); // IL-only AnyCPU
    check(0x14c, 0, 0x14c, 1); // 32BITREQUIRED/native i386
    check(0x8664, 0, 0x8664, 0); check(0xaa64, 0, 0xaa64, 0);
    return 0;
}
''')


class MadeiraStartupCompatibilityTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("cc"), "C compiler required")
    def test_registry_is_loaded_before_readiness_and_cleanup_resets_it(self):
        source = (MADEIRA / "build/wineserver/main_ios.c").read_text()
        main = function(source, "int wineserver_main(")
        bridge = (MADEIRA / "app/Madeira/WineServerBridge.m").read_text()
        cleanup = function(bridge, "static void wineserver_mark_stopped(")
        read = function(bridge, "int wineserver_is_ready(")
        definitions = "\n".join("static void " + name + "(void) { assert(!wineserver_ready); }"
                                for name in ("init_limits", "sock_init", "open_master_socket", "set_current_time",
                                             "init_signals", "init_memory", "init_threading"))
        code = r'''
#include <assert.h>
#include <stdio.h>
#include <signal.h>
#include <stdatomic.h>
#define ws_log(...) ((void)0)
#define TIMEOUT_INFINITE -1
#define parse_options(...) ((void)0)
static int wineserver_ready, registry_loaded;
static _Atomic int g_wineserver_running = 1;
static const char *server_argv0;
static long long master_socket_timeout;
static int load_intl_file(void) { assert(!wineserver_ready); return 1; }
static void init_directories(int x) { assert(x == 1 && !wineserver_ready); }
static void init_registry(void) { assert(!wineserver_ready); registry_loaded = 1; }
static void main_loop(void) { assert(registry_loaded && wineserver_ready); }
''' + definitions + main + cleanup + read + r'''
int main(void) {
    char *args[] = {"fixture", NULL};
    assert(!wineserver_is_ready()); assert(wineserver_main(1, args) == 0);
    assert(wineserver_is_ready()); wineserver_mark_stopped(NULL);
    assert(!wineserver_is_ready() && !g_wineserver_running);
    return 0;
}
'''
        # parse_options is stubbed, so argc is otherwise unused.
        run_c(code.replace("static int wineserver_ready,", "int wineserver_ready,").replace(
            "#define parse_options(...) ((void)0)", "#define parse_options(a,b,...) ((void)(a), (void)(b))"))
        request = (MADEIRA / "build/wineserver/request_ios.c").read_text()
        self.assertNotIn("wineserver_ready", function(request, "void open_master_socket("))
        start = function(bridge, "int wineserver_start(")
        self.assertLess(start.index("__atomic_store_n(&wineserver_ready, 0"), start.index("pthread_create("))
        adapter = (ROOT / "iridium/apps/ios/MadeiraSupport/MadeiraRuntimeAdapter.swift").read_text()
        launch = adapter[adapter.index("let serverReady = waitForWineserverReady"):adapter.index("let result = wine_process_start(")]
        self.assertIn("guard current()", launch)
        self.assertIn("guard serverReady", launch)
        self.assertIn("wineserver_stop()", launch)

    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler unavailable")
    def test_actual_swift_wait_handles_ready_exit_cancel_timeout_and_rollback(self):
        source = (ROOT / "iridium/apps/ios/MadeiraSupport/MadeiraRuntimeAdapter.swift").read_text()
        start = source.index("    private static func waitForWineserverReady(")
        helper = source[start:source.index("    // Lifecycle entry points", start)]
        code = '''import Foundation
var running: Int32 = 1
var ready: Int32 = 0
var polls = 0
var readyAfter = 0
var readyAt = Double.infinity
func wineserver_is_running() -> Int32 { running }
func wineserver_is_ready() -> Int32 {
    polls += 1
    return (readyAfter > 0 && polls >= readyAfter) || ProcessInfo.processInfo.systemUptime >= readyAt ? 1 : ready
}
enum UnderTest {
''' + helper + '''
    static func check() {
        unsetenv("MADEIRA_FAST_SERVER_START")
        ready = 1
        let now = ProcessInfo.processInfo.systemUptime
        precondition(waitForWineserverReady(timeout: 1, isCurrent: { true }))
        precondition(ProcessInfo.processInfo.systemUptime - now < 0.5)
        ready = 0; readyAfter = 3; polls = 0
        precondition(waitForWineserverReady(timeout: 0.5, isCurrent: { true }))
        precondition(polls >= 3)
        readyAfter = 0
        let slow = ProcessInfo.processInfo.systemUptime
        readyAt = slow + 2.1
        precondition(waitForWineserverReady(isCurrent: { true }))
        precondition(ProcessInfo.processInfo.systemUptime - slow >= 2.1)
        readyAt = Double.infinity; running = 0
        precondition(!waitForWineserverReady(isCurrent: { true }))
        running = 1
        precondition(!waitForWineserverReady(isCurrent: { false }))
        precondition(!waitForWineserverReady(timeout: 0.02, isCurrent: { true }))
        var current = 0
        precondition(!waitForWineserverReady(isCurrent: { current += 1; return current < 2 }))
        ready = 1; setenv("MADEIRA_FAST_SERVER_START", "0", 1)
        let delayed = ProcessInfo.processInfo.systemUptime
        precondition(waitForWineserverReady(timeout: 0.5, legacyDelay: 0.02, isCurrent: { true }))
        precondition(ProcessInfo.processInfo.systemUptime - delayed >= 0.02)
        ready = 0; readyAt = ProcessInfo.processInfo.systemUptime + 0.04
        precondition(waitForWineserverReady(timeout: 0.5, legacyDelay: 0.02, isCurrent: { true }))
        readyAt = Double.infinity; ready = 0
        precondition(!waitForWineserverReady(timeout: 0.02, legacyDelay: 0.01, isCurrent: { true }))
    }
}
UnderTest.check()
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "main.swift"
            binary = Path(folder) / "wait"
            path.write_text(code)
            subprocess.run(["swiftc", str(path), "-o", str(binary)], check=True, timeout=45)
            subprocess.run([str(binary)], check=True, timeout=10)


    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler unavailable")
    def test_shared_stub_and_actual_adapter_readiness_lifecycle(self):
        subprocess.run(["python3", str(ROOT / "iridium/apps/ios/MadeiraSupportTests/ReviewRegressionCheck.py"),
                        "--group", "lifecycle"], check=True, capture_output=True, text=True, timeout=120)


if __name__ == "__main__":
    unittest.main()
