"""Exercise the app-owned arena handoff without a phone or a Wine build."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ArenaHandoffTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("cc"), "C compiler required")
    def test_adoption_publishes_one_range_and_does_not_rereserve(self):
        source = (ROOT / "testrepos/Madeira/build/ntdll-unix/virtual_ios.c").read_text()
        start = source.index("void ios_reserve_fex_arena(void)")
        function = source[start:source.index("\n}", start) + 2]
        program = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
typedef uintptr_t ULONG_PTR;
typedef size_t SIZE_T;
#define min(a,b) ((a)<(b)?(a):(b))
static ULONG_PTR iridium_fex_arena[2], ios_fex_arena_base_unix, ios_fex_arena_end_unix;
static ULONG_PTR ios_furniture_ceiling = UINTPTR_MAX;
static int registrations, accept_registration;
static int mmap_add_fex_reserved_area(void *base, SIZE_T size) {
    assert((uintptr_t)base == 0x200000000ULL && size == 0x40000000ULL);
    ++registrations;
    return accept_registration;
}
''' + function + r'''
int main(void) {
    unsetenv("WINE_IOS_FEX_ARENA_BASE"); unsetenv("WINE_IOS_FEX_ARENA_SIZE");
    ios_reserve_fex_arena(); assert(!registrations);
    setenv("WINE_IOS_FEX_ARENA_BASE", "200000001", 1);
    setenv("WINE_IOS_FEX_ARENA_SIZE", "40000000", 1);
    ios_reserve_fex_arena(); assert(!registrations);
    setenv("WINE_IOS_FEX_ARENA_BASE", "200000000", 1);
    ios_reserve_fex_arena(); assert(registrations == 1 && !ios_fex_arena_base_unix);
    accept_registration = 1;
    ios_reserve_fex_arena();
    assert(registrations == 2 && ios_fex_arena_base_unix == 0x200000000ULL);
    assert(ios_fex_arena_end_unix == 0x240000000ULL);
    assert(iridium_fex_arena[1] + 1 == ios_fex_arena_end_unix);
    ios_reserve_fex_arena(); assert(registrations == 2);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "test.c"
            binary = Path(folder) / "test"
            source.write_text(program)
            subprocess.run(["cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", str(source), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True, capture_output=True)
