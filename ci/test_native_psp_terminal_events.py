"""Execute terminal error delivery across retirement and replacement generations."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from test_native_psp_lifecycle import method

ROOT=Path(__file__).resolve().parents[1]


class TerminalEventTests(unittest.TestCase):
    def test_error_survives_close_but_never_reaches_a_replacement(self):
        if not shutil.which('clang++') or not Path('/Applications/Xcode.app').exists():self.skipTest('Apple Foundation required')
        body=method((ROOT/'iridium/apps/ios/RuntimeBridge/IRPPSSPPNative.mm').read_text(),'static void event(unsigned kind, const char *message) {')
        code=r'''#import <Foundation/Foundation.h>
#include <atomic>
#include <string>
#include <stdio.h>
#include <stdlib.h>
typedef void(*IRNativePSPEvent)(unsigned,const char*);
@interface IRPPSSPPContainer:NSObject
@property BOOL closing;
@end
@implementation IRPPSSPPContainer @end
static IRPPSSPPContainer *container;
static std::atomic<uint64_t> generation;
static std::atomic<IRNativePSPEvent> eventSink;
static NSMutableArray *pending;
static unsigned errors,ready;
static void sink(unsigned kind,const char*){if(kind==2)errors++;if(kind==3)ready++;}
#define dispatch_async(queue,block) [pending addObject:[block copy]]
BODY
static void require(bool ok){if(!ok)exit(1);}
static void drain(){while(pending.count){void(^b)(void)=pending.firstObject;[pending removeObjectAtIndex:0];b();}}
int main(){@autoreleasepool {
 pending=[NSMutableArray array];eventSink=sink;generation=1;container=[IRPPSSPPContainer new];
 event(2,"renderer failed");container.closing=YES;generation++;drain();require(errors==1);
 container.closing=NO;generation++;event(3,"ready");container.closing=YES;generation++;drain();require(ready==0);
 event(2,"retired error");container=[IRPPSSPPContainer new];generation++;drain();require(errors==1);
 event(2,"prior renderer");container.closing=YES;generation++;container.closing=NO;generation++;drain();require(errors==1);
 event(2,"closed error");container=nil;generation++;drain();require(errors==1);
 puts("PASS terminal renderer failure survives close and rejects replaced/restarted owners");
}}
'''.replace('BODY',body)
        with tempfile.TemporaryDirectory() as folder:
            source=Path(folder)/'event.mm';binary=Path(folder)/'event';source.write_text(code)
            result=subprocess.run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation',str(source),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)


if __name__=='__main__':unittest.main()
