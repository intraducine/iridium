"""Check the desktop/iOS boundary without configuring all of Wine."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WineIOSHooksTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("cc"), "C compiler required")
    def test_loader_notification_suppresses_recursive_memory_callbacks(self):
        relative = "testrepos/Madeira/wine/dlls/ntdll/signal_arm64ec.c"
        # Actions checks an unpatched checkout; local builds leave it patched.
        # Apply the same tracked build patch in isolation for either input state.
        with tempfile.TemporaryDirectory() as folder:
            tree = Path(folder)
            target = tree / relative
            target.parent.mkdir(parents=True)
            shutil.copy2(ROOT / relative, target)
            subprocess.run(["git", "init", "-q", folder], check=True)
            patch = ["git", "apply", "--include=" + relative,
                     str(ROOT / "ci/patches/fex-thread-init-failure.patch")]
            applied = subprocess.run(patch + ["--reverse", "--check"], cwd=tree,
                                     capture_output=True).returncode == 0
            if not applied:
                subprocess.run(patch, cwd=tree, check=True, capture_output=True)
            source = target.read_text()

        def function(signature):
            start = source.index(signature)
            end = source.index("\n}", start) + 2
            return source[start:end]

        # Compile the real loader wrapper, free wrapper, and callback gate. A
        # translator allocation is freed while its interval lock is held. The
        # memory callback must not reenter that lock, and the caller's previous
        # callback state must survive both initially-clear and nested calls.
        program = r'''
#include <assert.h>
#include <stddef.h>
typedef int BOOL;
typedef int NTSTATUS;
typedef unsigned long ULONG;
typedef size_t SIZE_T;
typedef void *HANDLE;
typedef void *PVOID;
typedef struct { unsigned char InSyscallCallback; } CHPE_V2_CPU_AREA_INFO;
typedef struct { int unused; } MEMORY_BASIC_INFORMATION;
#define TRUE 1
#define FALSE 0
#define SYSCALL_API
#define ERR(...) ((void)0)
#define NtQueryVirtualMemory(...) ((void)0)
#define send_cross_process_notification(...) ((void)0)
static CHPE_V2_CPU_AREA_INFO cpu;
static CHPE_V2_CPU_AREA_INFO *area = &cpu;
static CHPE_V2_CPU_AREA_INFO *get_arm64ec_cpu_area(void) { return area; }
static BOOL RtlIsCurrentProcess(HANDLE process) { return TRUE; }
static int raw_frees, notifications, images, interval_locked;
static NTSTATUS syscall_NtFreeVirtualMemory(HANDLE process, PVOID *addr, SIZE_T *size, ULONG type)
{
    ++raw_frees;
    return 0;
}
static void notify_free(void *addr, SIZE_T size, ULONG type, BOOL after, NTSTATUS status)
{
    if (!after) return;
    ++notifications;
    assert(!interval_locked && "translator memory callback reenters its held interval lock");
}
static void (*pNotifyMemoryFree)(void *, SIZE_T, ULONG, BOOL, NTSTATUS) = notify_free;
static void (*pNotifyImageMap)(void *);
'''
        for signature in ("static inline BOOL enter_syscall_callback(void)",
                          "static inline void leave_syscall_callback(void)",
                          "NTSTATUS SYSCALL_API NtFreeVirtualMemory(",
                          "void arm64ec_notify_image_map( void *base )"):
            program += function(signature) + "\n"
        program += r'''
static void image_map(void *base)
{
    ++images;
    if (!area) return; /* Native thread without a translator CPU area. */
    void *allocation = &cpu;
    SIZE_T size = 0xf000;
    interval_locked = 1;
    assert(!NtFreeVirtualMemory(NULL, &allocation, &size, 0x4000));
    interval_locked = 0;
}
int main(void)
{
    pNotifyImageMap = image_map;
    for (int previous = 0; previous <= 1; ++previous) {
        cpu.InSyscallCallback = previous;
        arm64ec_notify_image_map(&cpu);
        assert(cpu.InSyscallCallback == previous);
    }
    assert(images == 2 && raw_frees == 2 && notifications == 0);
    /* Ordinary guest frees must still notify FEX. */
    cpu.InSyscallCallback = 0;
    void *allocation = &cpu;
    SIZE_T size = 0xf000;
    assert(!NtFreeVirtualMemory(NULL, &allocation, &size, 0x4000));
    assert(raw_frees == 3 && notifications == 1 && !cpu.InSyscallCallback);
    area = NULL;
    arm64ec_notify_image_map(&cpu);
    assert(images == 3);
    area = &cpu;
    cpu.InSyscallCallback = 1;
    arm64ec_notify_image_map(NULL);
    pNotifyImageMap = NULL;
    arm64ec_notify_image_map(&cpu);
    assert(images == 3 && cpu.InSyscallCallback == 1);
}
'''
        with tempfile.TemporaryDirectory() as folder:
            binary = str(Path(folder) / "loader-callback")
            subprocess.run(["cc", "-x", "c", "-", "-o", binary], input=program,
                           text=True, capture_output=True, check=True)
            result = subprocess.run([binary], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("cc"), "C preprocessor required")
    def test_bitmap_hooks_only_exist_in_ios_build(self):
        source = (ROOT / "testrepos/Madeira/wine/dlls/win32u/dibdrv/bitblt.c").read_text()
        # Headers need a configured Wine tree; retain all source conditionals.
        source = "\n".join(line for line in source.splitlines()
                           if not line.lstrip().startswith("#include"))
        hooks = ("winios_dump_srcbits", "ios_srcwatch_arm_geom", "ios_srcwatch_arm")
        for ios in (False, True):
            command = ["cc", "-E", "-P", "-x", "c", "-"]
            if ios:
                command.insert(1, "-DWINE_IOS=1")
            result = subprocess.run(command, input=source, text=True,
                                    capture_output=True, check=True).stdout
            for hook in hooks:
                self.assertEqual(hook in result, ios, hook)

    @unittest.skipUnless(shutil.which("cc"), "C preprocessor required")
    def test_loader_jit_alias_calls_only_exist_in_arm64ec_build(self):
        source = (ROOT / "testrepos/Madeira/wine/dlls/ntdll/loader.c").read_text()
        source = "\n".join(line for line in source.splitlines()
                           if not line.lstrip().startswith("#include"))
        for arch in ("__aarch64__", "__x86_64__", "__i386__", "__arm64ec__"):
            result = subprocess.run(
                ["cc", "-E", "-P", "-undef", "-D" + arch, "-x", "c", "-"],
                input=source, text=True, capture_output=True, check=True).stdout
            for hook in ("xlate_ios_jit", "iat_life_sweep"):
                self.assertEqual(hook in result, arch == "__arm64ec__", (arch, hook))
