"""Execute the app's loader against complete, incomplete and wrong-version ABIs."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'


class NativePSPLoaderTests(unittest.TestCase):
    def exercise(self, abi, omit='', expected=True):
        if not shutil.which('clang'): self.skipTest('C compiler required')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            component = root / 'component.c'
            component.write_text('''#include <stdint.h>
#include <stdbool.h>
static unsigned calls;
uint32_t ir_native_psp_abi(void) { return ABI; }
void *ir_native_psp_create(const char *g,const char *m,const char *a,bool j,void (*e)(unsigned,const char*)) {
    e(0,"created"); return (void*)1;
}
void ir_native_psp_pause(void) { calls |= 1; }
void ir_native_psp_resume(void) { calls |= 2; }
void ir_native_psp_menu(void) { calls |= 4; }
void ir_native_psp_stop(void) { calls |= 8; }
uint64_t ir_native_psp_frames(void) { return calls; }
'''.replace('ABI', str(abi)).replace('void ir_native_psp_' + omit + '(void)', 'void missing_' + omit + '(void)' if omit else 'void ir_native_psp_(void)'))
            lib = root / 'component.dylib'
            subprocess.run(['clang', '-shared', '-fPIC', str(component), '-o', str(lib)], check=True, capture_output=True)
            harness = root / 'check.c'
            harness.write_text('''#include "IRPSPNativeBridge.h"
#include <assert.h>
static unsigned created;
static void event(unsigned k,const char *m) { assert(k==0 && m); created++; }
int main(int argc,char**argv) {
    assert(argc==2);
    assert(!ir_psp_native_open(argv[1],0,"memory","assets",false,event));
    void *first=ir_psp_native_open(argv[1],"game","memory","assets",false,event);
    assert((first != 0) == EXPECTED);
    if (EXPECTED) {
        assert(created==1);
        ir_psp_native_pause(); ir_psp_native_resume(); ir_psp_native_menu(); ir_psp_native_stop();
        assert(ir_psp_native_frames()==15);
    } else {
        assert(!ir_psp_native_open(argv[1],"game","memory","assets",false,event));
        assert(created==0);
    }
}
'''.replace('EXPECTED', '1' if expected else '0'))
            executable = root / 'check-loader'
            result = subprocess.run(['clang', '-I' + str(BRIDGE), str(harness), str(BRIDGE / 'IRPSPNativeBridge.c'),
                            '-ldl', '-o', str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            subprocess.run([str(executable), str(lib)], check=True, capture_output=True, timeout=10)

    def test_complete_component_forwards_each_command(self): self.exercise(1)
    def test_wrong_version_never_opens(self): self.exercise(2, expected=False)
    def test_partial_component_remains_rejected_on_retry(self): self.exercise(1, omit='resume', expected=False)


if __name__ == '__main__': unittest.main()
