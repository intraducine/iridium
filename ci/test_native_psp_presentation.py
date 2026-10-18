"""Execute the host presenter and generated picker's once-only cancellation."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import ppsspp_picker_overlay as picker
from test_native_psp_lifecycle import method

ROOT=Path(__file__).resolve().parents[1]


class NativePresentationTests(unittest.TestCase):
    def test_active_player_routing_close_cancel_and_late_results(self):
        if not shutil.which('clang++') or not Path('/Applications/Xcode.app').exists():self.skipTest('Apple Foundation required')
        source=(ROOT/'iridium/apps/ios/RuntimeBridge/IRPPSSPPNative.mm').read_text()
        present=method(source,'void ir_native_psp_present(')
        finish=method(source,'void ir_native_psp_presentation_finished(')
        adapted=picker.apply((ROOT/'vendor/PPSSPP'/picker.NAME).read_text())
        resolve=method(adapted,'- (void)iridiumFinish:')
        code=r'''#import <Foundation/Foundation.h>
#include <functional>
#include <string>
#include <stdio.h>
#include <stdlib.h>
struct Path { std::string value;Path(){}Path(const char*s):value(s){} };
typedef std::function<void(bool,Path)> DarwinDirectoryPanelCallback;
static unsigned clears;
class DarwinFileSystemServices{public:static void ClearDelegate(){clears++;}};
@interface View:NSObject @property id window; @end
@implementation View @end
@interface UIViewController:NSObject
@property View *view;
@property UIViewController *presentedViewController;
@property unsigned presentations;
- (void)presentViewController:(UIViewController*)p animated:(BOOL)a completion:(void(^)(void))c;
@end
@implementation UIViewController
- (instancetype)init{self=[super init];self.view=[View new];self.view.window=[NSObject new];return self;}
- (void)presentViewController:(UIViewController*)p animated:(BOOL)a completion:(void(^)(void))c{self.presentedViewController=p;self.presentations++;if(c)c();}
@end
@interface IRPPSSPPContainer:UIViewController
@property BOOL closing;
@property NSMutableDictionary *presentationCancels;
@end
@implementation IRPPSSPPContainer @end
static IRPPSSPPContainer *container;
PRESENT
FINISH
@interface UIDocumentPickerViewController:UIViewController @property(weak) id delegate; @end
@implementation UIDocumentPickerViewController @end
@interface DocumentPickerDelegate:NSObject
@property BOOL iridiumResolved;
@property DarwinDirectoryPanelCallback panelCallback;
@property(weak) UIDocumentPickerViewController *iridiumPicker;
-(void)iridiumFinish:(bool)success path:(Path)path;
@end
@implementation DocumentPickerDelegate
RESOLVE
@end
static void require(bool ok,const char*why){if(!ok){fprintf(stderr,"FAIL %s\n",why);exit(1);}}
int main(void){@autoreleasepool{
 IRPPSSPPContainer *player=[IRPPSSPPContainer new];player.presentationCancels=[NSMutableDictionary dictionary];container=player;
 UIViewController *coveredLibrary=[UIViewController new];coveredLibrary.presentedViewController=player;
 UIDocumentPickerViewController *panel=[UIDocumentPickerViewController new];
 DocumentPickerDelegate *delegate=[DocumentPickerDelegate new];delegate.iridiumPicker=panel;panel.delegate=delegate;
 unsigned callbacks=0;bool success=true;
 delegate.panelCallback=[&](bool ok,Path){callbacks++;success=ok;};
 ir_native_psp_present(panel,^{[delegate iridiumFinish:false path:Path()];});
 require(player.presentations==1 && coveredLibrary.presentations==0,"picker belongs to visible player, not covered library");
 require(player.presentationCancels.count==1,"close owns pending cancellation");
 player.closing=YES;
 for(void(^cancel)(void) in player.presentationCancels.allValues)cancel();
 require(callbacks==1 && !success && player.presentationCancels.count==0 && panel.delegate==nil,"close resolves pending picker exactly once");
 [delegate iridiumFinish:true path:Path("late-file")];require(callbacks==1 && clears==1,"late success cannot revive canceled request");
 __block unsigned rejected=0;ir_native_psp_present([UIViewController new],^{rejected++;});
 require(rejected==1 && player.presentations==1,"closing owner rejects new presentation");
 puts("PASS player routing, close cancellation and late-picker rejection");return 0;
}}
'''.replace('PRESENT',present).replace('FINISH',finish).replace('RESOLVE',resolve)
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);file=root/'check.mm';binary=root/'check';file.write_text(code)
            r=subprocess.run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation',str(file),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stderr)
            r=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertIn('PASS player routing',r.stdout)


if __name__=='__main__':unittest.main()
