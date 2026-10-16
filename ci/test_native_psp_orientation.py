"""Execute the active orientation policy against the pinned iOS frontend policy."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class NativeOrientationTests(unittest.TestCase):
    def test_host_policy_matches_release_for_phone_and_tablet(self):
        if not shutil.which('clang++'):self.skipTest('C++ compiler required')
        adapter=(ROOT/'iridium/apps/ios/RuntimeBridge/IRPPSSPPNative.mm').read_text()
        upstream=(ROOT/'vendor/PPSSPP/ios/AppDelegate.mm').read_text()
        a=adapter.index('        switch (rotation) {');b=adapter.index('        container.rotationMask',a)
        actual=adapter[a:b]
        a=upstream.index('\tswitch (g_Config.iScreenRotation) {');b=upstream.index('\n\treturn UIInterfaceOrientationMaskAll;',a)
        expected=upstream[a:b].replace('g_Config.iScreenRotation','rotation')
        constants=('ROTATION_LOCKED_HORIZONTAL','ROTATION_LOCKED_VERTICAL','ROTATION_LOCKED_VERTICAL180',
                   'ROTATION_LOCKED_HORIZONTAL180','ROTATION_AUTO_HORIZONTAL','ROTATION_AUTO')
        code='''#include <stdio.h>
enum { UIUserInterfaceIdiomPhone, UIUserInterfaceIdiomPad };
static int idiom;
#define UI_USER_INTERFACE_IDIOM() idiom
using UIInterfaceOrientationMask=int;
enum { UIInterfaceOrientationMaskLandscapeRight=1, UIInterfaceOrientationMaskLandscapeLeft=2,
 UIInterfaceOrientationMaskPortrait=4, UIInterfaceOrientationMaskPortraitUpsideDown=8,
 UIInterfaceOrientationMaskLandscape=3, UIInterfaceOrientationMaskAll=15 };
'''+ 'enum {'+','.join(constants)+'};\n'
        code+='int actual(int rotation) { UIInterfaceOrientationMask mask;\n'+actual+'return mask; }\n'
        code+='int expected(int rotation) {\n'+expected+'return 15; }\n'
        code+='''int main() { for(idiom=0;idiom<2;idiom++) for(int rotation=-1;rotation<8;rotation++) {
 if(actual(rotation)!=expected(rotation)) {fprintf(stderr,"orientation mismatch %d %d",idiom,rotation);return 1;}}
 puts("PASS phone/tablet portrait, reversed portrait, both landscapes, auto and invalid policy");}
'''
        with tempfile.TemporaryDirectory() as folder:
            source=Path(folder)/'policy.cpp';binary=Path(folder)/'policy';source.write_text(code)
            subprocess.run(['clang++',str(source),'-o',str(binary)],check=True,capture_output=True)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)


if __name__=='__main__':unittest.main()
