"""Execute a production gamepad callback with delayed delivery across sessions."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import re
import ppsspp_native_overlay as overlay

ROOT=Path(__file__).resolve().parents[1]


class CallbackOwnershipTests(unittest.TestCase):
    def test_queued_gamepad_event_cannot_reach_closed_or_replacement_session(self):
        if not shutil.which('clang++') or not Path('/Applications/Xcode.app').exists():self.skipTest('Apple Foundation required')
        source=overlay.apply('ios/Controls.mm',(ROOT/'vendor/PPSSPP/ios/Controls.mm').read_text())
        body=re.search(r'extendedProfile.buttonA.valueChangedHandler = (\^\(.*?\n\t\};)',source,re.S)[1]
        code=r'''#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
@interface GCControllerButtonInput:NSObject @end
@implementation GCControllerButtonInput @end
static NSMutableArray *work;
static uint64_t current=1;
static BOOL accepting=YES;
static unsigned inputs;
static int NKCODE_BUTTON_2=2;
static bool ir_native_psp_generation_current(uint64_t epoch){return accepting && epoch==current;}
static void controllerButtonPressed(BOOL,int){inputs++;}
static void later(void(^b)(void)){[work addObject:[b copy]];}
#define dispatch_async(queue,block) later(block)
static void require(bool ok){if(!ok)exit(1);}
static void drain(){while(work.count){void(^b)(void)=work.firstObject;[work removeObjectAtIndex:0];b();}}
int main(){@autoreleasepool {
 work=[NSMutableArray array]; uint64_t iridiumCallbackOwner=1;
 void(^handler)(GCControllerButtonInput*,float,BOOL)=BODY;
 handler(nil,1,YES);require(inputs==0&&work.count==1);drain();require(inputs==1);
 handler(nil,1,YES);accepting=NO;drain();require(inputs==1);
 handler(nil,1,YES);accepting=YES;current=2;drain();require(inputs==1);
 handler(nil,1,YES);drain();require(inputs==1);
 puts("PASS callback queues native input on main and rejects closed/replaced owners");
}}
'''.replace('BODY',body.rstrip(';'))
        with tempfile.TemporaryDirectory() as folder:
            source=Path(folder)/'callback.mm';binary=Path(folder)/'callback';source.write_text(code)
            result=subprocess.run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation',str(source),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)


if __name__=='__main__':unittest.main()
