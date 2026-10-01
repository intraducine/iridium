"""Run the real script planner and helper control flow. Wine APIs are stubbed."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "iridium/apps/ios"


class GamePrerequisitesTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("cc"), "requires C compiler")
    def test_installer_session_selects_native_wine_from_pe_header(self):
        source = (ROOT / "testrepos/Madeira/app/Madeira/WineProcessBridge.m").read_text()
        probe = source[source.index("static uint16_t madeira_pe_machine("):
                       source.index("/* The machine of the file the launch below will run")]
        heuristic = source[source.index('        const char *force_ec = getenv("MADEIRA_USE_ARM64EC");'):
                           source.index("        /* WoW64: a 32-bit (i386) target")]
        override = re.search(r"        if \(is_i386_target.*use_arm64ec = NO;", source).group()
        constants = "\n".join(re.findall(r"^#define MADEIRA_IMAGE_FILE_MACHINE_.*$", source, re.M))
        harness = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef int BOOL;
#define NO 0
''' + constants + "\n" + probe + r'''
static BOOL select_runtime(const char *madeira_exe, uint16_t target_machine, BOOL has_i386_set) {
    const BOOL is_i386_target = has_i386_set && target_machine == MADEIRA_IMAGE_FILE_MACHINE_I386;
''' + heuristic + override + r'''
    return use_arm64ec;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    /* This full Windows path used to force ARM64EC despite the native header. */
    uint16_t machine = madeira_pe_machine(argv[1]);
    assert(machine == 0xaa64);
    assert(!select_runtime("C:\\IridiumPrerequisites\\iridium-prerequisites.exe", machine, 1));
    assert(!select_runtime("C:\\Game\\setup.exe", 0x14c, 1));
    assert(select_runtime("C:\\Game\\Game.exe", 0x8664, 1));
    assert(select_runtime("C:\\Game\\Game.exe", 0xa641, 1));
    assert(select_runtime("C:\\Game\\Unknown.exe", 0, 1));
    assert(select_runtime("cube-x64.exe", 0x8664, 1));
    assert(!select_runtime("cube.exe", 0xaa64, 1));
    assert(select_runtime("C:\\Game\\setup.exe", 0x14c, 0));
    assert(!setenv("MADEIRA_USE_ARM64EC", "1", 1));
    assert(!select_runtime("C:\\IridiumPrerequisites\\iridium-prerequisites.exe", machine, 1));
}
'''
        with tempfile.TemporaryDirectory() as temp:
            binary = str(Path(temp) / "check")
            executable = Path(temp) / "helper.exe"
            header = bytearray(70)
            header[:2] = b"MZ"
            header[60:64] = (64).to_bytes(4, "little")
            header[64:70] = b"PE\0\0\x64\xaa"
            executable.write_bytes(header)
            subprocess.run(["cc", "-x", "c", "-", "-o", binary],
                           input=harness, text=True, check=True, capture_output=True, timeout=30)
            subprocess.run([binary, str(executable)], check=True, capture_output=True, timeout=5)

    @unittest.skipUnless(shutil.which("xcrun"), "requires Apple Swift compiler")
    def test_adapter_launch_and_cancellation(self):
        subprocess.run([
            sys.executable, str(IOS / "MadeiraSupportTests/ReviewRegressionCheck.py"),
            "--group", "lifecycle",
        ], check=True, capture_output=True, timeout=120)

    @unittest.skipUnless(shutil.which("xcrun"), "requires Apple Swift compiler")
    def test_script_and_prefix_preparation(self):
        support = IOS / "MadeiraSupport"
        with tempfile.TemporaryDirectory() as temp:
            binary = Path(temp) / "check"
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors",
                *[str(support / name) for name in (
                    "MadeiraGamePreparation.swift", "MadeiraLaunchArguments.swift",
                    "IridiumSteamInstallScript.swift", "IridiumGamePrerequisites.swift")],
                str(IOS / "MadeiraSupportTests/GamePrerequisitesCheck.swift"), "-o", str(binary),
            ], check=True, capture_output=True, timeout=90)
            subprocess.run([str(binary)], check=True, capture_output=True, timeout=15)

    @unittest.skipUnless(shutil.which("cc"), "requires C compiler")
    def test_helper_marks_only_complete_successful_groups(self):
        source = (IOS / "MadeiraSupport/prerequisites.c").read_text()
        installed = re.search(r"static BOOL installed\(.*?\n", source).group()
        entry = source[source.index("int wmain("):]
        harness = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>
#include <string.h>
typedef unsigned long DWORD;
typedef unsigned int UINT;
typedef int BOOL;
#define INFINITE 0xffffffff
#define ERROR_INVALID_PARAMETER 87
#define ERROR_INVALID_DATA 13
#define ERROR_CANCELLED 1223
#define ERROR_PROCESS_ABORTED 1067
static wchar_t executable[128], command[128], directory[128];
static const wchar_t *config;
static void status(const char *phase, UINT run, UINT runs, UINT process, UINT processes) {
    (void)run; (void)runs; (void)process; (void)processes;
    assert(!strcmp(phase,"services") || !strcmp(phase,"installer") || !strcmp(phase,"game"));
}
static DWORD codes[4], service_error, registry_error;
static int calls, marked, game, cancelled_flag, bad_field, unconfirmed;
static BOOL cancelled(void) { return cancelled_flag; }
static DWORD services_start(void) { return service_error; }
static UINT GetPrivateProfileIntW(const wchar_t *s, const wchar_t *k, UINT d, const wchar_t *p) {
    (void)s; (void)d; (void)p;
    return !wcscmp(k,L"runs") || !wcscmp(k,L"processes") ? 2 : 0;
}
static BOOL field(const wchar_t *s, const wchar_t *k, wchar_t *v) {
    (void)s; (void)k; (void)v; return !bad_field;
}
static DWORD record_run(const wchar_t *s) { (void)s; if (!registry_error) marked++; return registry_error; }
static DWORD run_process(DWORD timeout, BOOL *exited) {
    if (timeout == INFINITE) { game++; return 0; }
    *exited = !unconfirmed;
    assert(timeout == 600000); assert(calls < 4); return codes[calls++];
}
''' + installed + entry + r'''
static void reset(void) {
    memset(codes,0,sizeof(codes)); calls=marked=game=cancelled_flag=bad_field=unconfirmed=0;
    service_error=registry_error=0;
}
int main(void) {
    wchar_t *argv[]={L"helper",L"plan"};
    reset(); codes[1]=3010; codes[3]=1641;
    assert(wmain(2,argv)==0 && calls==4 && marked==2 && game==1);
    for (int failure=0; failure<4; failure++) {
        reset(); codes[failure]=5;
        assert(wmain(2,argv)==5 && calls==failure+1 && marked==failure/2 && !game);
    }
    reset(); registry_error=5;
    assert(wmain(2,argv)==5 && calls==2 && !marked && !game);
    reset(); service_error=1722;
    assert(wmain(2,argv)==1722 && !calls && !marked && !game);
    reset(); bad_field=1;
    assert(wmain(2,argv)==ERROR_INVALID_DATA && !calls && !marked && !game);
    reset(); cancelled_flag=1;
    assert(wmain(2,argv)==ERROR_CANCELLED && !calls && !marked && !game);
    reset(); unconfirmed=1;
    assert(wmain(2,argv)==ERROR_PROCESS_ABORTED && calls==1 && !marked && !game);
    for (DWORD code=0; code<65536; code++)
        assert(installed(code)==(code==0 || code==3010 || code==1641));
}
'''
        with tempfile.TemporaryDirectory() as temp:
            binary = str(Path(temp) / "check")
            subprocess.run(["cc", "-x", "c", "-", "-o", binary],
                           input=harness, text=True, check=True, capture_output=True, timeout=30)
            subprocess.run([binary], check=True, capture_output=True, timeout=5)


if __name__ == "__main__":
    unittest.main()
