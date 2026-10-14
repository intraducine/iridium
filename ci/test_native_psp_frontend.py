"""Exercise the native frontend boundary without claiming device acceptance."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import ppsspp_native_overlay as overlay
from ppsspp_frontend_overlay import body

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'iridium/apps/ios/RuntimeBridge/IRPPSSPPNative.mm'


def function(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        end += 1
    return text[start:end]


class NativePSPFrontendTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('clang++'), 'C++ compiler required')
    def test_preserved_autorun_false_boots_without_entering_removed_debugger(self):
        source = NATIVE.read_text()
        upstream = ROOT / 'vendor/PPSSPP/UI/EmuScreen.cpp'
        if not upstream.exists(): self.skipTest('Pinned checkout required')
        emu = overlay.apply('UI/EmuScreen.cpp', upstream.read_text())
        # Execute the real frontend normalization and real upstream boot decision.
        start = source.index('    // Presentation and input belong to Iridium')
        end = source.index('    currentResolution = ', start)
        normalization = source[start:end]
        self.assertLess(source.index('    NativeInit(2,'), start)
        self.assertLess(end, source.index('    self.player = requestedBackend'))
        start_break = next(line for line in emu.splitlines() if 'coreParam.startBreak =' in line)
        boot_start = emu.index('if (PSP_CoreParameter().startBreak)')
        boot_end = emu.index('\n\n\t\tAchievements::Initialize();', boot_start)
        completion = emu[boot_start:boot_end]
        harness = r'''#include <cassert>
struct Config {
 bool bAutoRun=false, bShowTouchControls=true, bShowImDebugger=true, bShowDeveloperMenu=true;
 int iScreenRotation=99, iCpuCore=0, iInternalResolution=4;
 bool bSoftwareRendering=true;
} g_Config;
constexpr int ROTATION_AUTO=0;
enum CoreState { CORE_RUNNING_CPU, CORE_STEPPING_CPU };
CoreState coreState;
enum class SystemNotification { DEBUG_MODE_CHANGE };
static unsigned debugNotifications;
void System_Notify(SystemNotification) { ++debugNotifications; }
struct CoreParameter { bool startBreak; } coreParam;
CoreParameter &PSP_CoreParameter() { return coreParam; }
int main() {
 for(bool savedAutoRun:{false,true}) {
  g_Config.bAutoRun=savedAutoRun;
  NORMALIZATION
  START_BREAK
  coreState=CORE_STEPPING_CPU;
  BOOT_COMPLETION
  assert(g_Config.bAutoRun && !coreParam.startBreak);
  assert(coreState==CORE_RUNNING_CPU && debugNotifications==0);
  // Engine compatibility selections survive the frontend-only normalization.
  assert(g_Config.iCpuCore==0 && g_Config.iInternalResolution==4 && g_Config.bSoftwareRendering);
 }
}
'''.replace('NORMALIZATION', normalization).replace('START_BREAK', start_break).replace('BOOT_COMPLETION', completion)
        with tempfile.TemporaryDirectory() as folder:
            code = Path(folder) / 'boot.cpp'; code.write_text('#include <initializer_list>\n'+harness)
            binary = Path(folder) / 'boot'
            result = subprocess.run(['clang++', '-std=c++17', str(code), '-o', str(binary)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            subprocess.run([str(binary)], check=True, capture_output=True, timeout=10)

    def test_composed_frontend_has_no_secondary_widgets_or_input_targets(self):
        upstream = ROOT / 'vendor/PPSSPP'
        if not (upstream / 'UI/EmuScreen.cpp').exists(): self.skipTest('Pinned checkout required')
        emu = overlay.apply('UI/EmuScreen.cpp', (upstream / 'UI/EmuScreen.cpp').read_text())
        views = function(emu, 'void EmuScreen::CreateViews()')
        self.assertIn('new UI::AnchorLayout', views)
        for unexpected in ('CreatePadLayout', 'new Button', 'new Spinner', 'new ChatMenu'):
            self.assertNotIn(unexpected, views)
        self.assertNotIn('new GamePauseScreen', emu)
        self.assertNotIn('new MainScreen', emu)
        self.assertNotIn('new PromptScreen', function(emu, 'void EmuScreen::update()'))
        for signature in ('bool EmuScreen::UnsyncKey(', 'void EmuScreen::UnsyncAxis(', 'void EmuScreen::touch('):
            self.assertNotIn('g_controlMapper', function(emu, signature))
        native = overlay.apply('UI/NativeApp.cpp', (upstream / 'UI/NativeApp.cpp').read_text())
        self.assertIn('bool skipLogo = true;', native)
        self.assertNotIn('new OSDOverlayScreen', native)
        common = overlay.apply('ios/ViewControllerCommon.mm', (upstream / 'ios/ViewControllerCommon.mm').read_text())
        self.assertNotIn('InitController', function(common, '- (void)setupController:'))
        self.assertNotIn('becomeFirstResponder', function(common, '- (void)showKeyboard'))
        ctrl = overlay.apply('Core/HLE/sceCtrl.cpp', (upstream / 'Core/HLE/sceCtrl.cpp').read_text())
        sample = function(ctrl, 'static void __CtrlDoSample()')
        self.assertLess(sample.index('ir_native_psp_poll_input();'), sample.index('__CtrlUpdateLatch();'))
        # The entire emulation/sample implementation is unchanged after removing
        # the single frontend sampling hook and its declaration include.
        self.assertEqual(ctrl.replace('#include "IRPPSSPPNative.h"\n', '', 1)
                         .replace('\tir_native_psp_poll_input();\n', '', 1),
                         (upstream / 'Core/HLE/sceCtrl.cpp').read_text())

    @unittest.skipUnless(shutil.which('clang++'), 'C++ compiler required')
    def test_actual_input_adapter_maps_all_buttons_and_retires_to_neutral(self):
        source = NATIVE.read_text()
        harness = '''#include <atomic>
#include <cassert>
#include <cmath>
#include "Core/HLE/sceCtrl.h"
using Input = void (*)(uint16_t*,int16_t*,int16_t*);
static std::atomic<Input> inputSource;
static std::atomic<bool> acceptingCallbacks;
static uint32_t outputButtons;
static float outputX,outputY;
static uint16_t supplied;
static unsigned polls;
void __CtrlUpdateButtons(u32 set,u32 clear) { assert(clear==CTRL_MASK_USER); outputButtons=set; }
void __CtrlSetAnalogXY(int stick,float x,float y) { assert(stick==0); outputX=x;outputY=y; }
static void poll(uint16_t*b,int16_t*x,int16_t*y) { ++polls; *b=supplied; *x=-32768; *y=32767; }
''' + function(source, 'void ir_native_psp_poll_input(void)') + '''
int main() {
 inputSource=poll; acceptingCallbacks=true;
 const uint32_t expected[]={CTRL_CROSS,CTRL_SQUARE,CTRL_SELECT,CTRL_START,CTRL_UP,CTRL_DOWN,
   CTRL_LEFT,CTRL_RIGHT,CTRL_CIRCLE,CTRL_TRIANGLE,CTRL_LTRIGGER,CTRL_RTRIGGER};
 for(unsigned i=0;i<12;++i) { supplied=1u<<i;ir_native_psp_poll_input(); assert(outputButtons==expected[i]); }
 assert(polls==12 && outputX==-1.0f && outputY<-.99f);
 supplied=0xffff;ir_native_psp_poll_input();
 uint32_t all=0;for(auto b:expected)all|=b;assert(outputButtons==all);
 acceptingCallbacks=false;ir_native_psp_poll_input();
 assert(polls==13 && outputButtons==0 && outputX==0 && outputY==0);
 acceptingCallbacks=true;inputSource=nullptr;ir_native_psp_poll_input();assert(outputButtons==0);
}
'''
        with tempfile.TemporaryDirectory() as folder:
            cpp = Path(folder) / 'input.cpp'; cpp.write_text(harness)
            binary = Path(folder) / 'input'
            compiled = subprocess.run(['clang++', '-std=c++17', '-I'+str(ROOT/'vendor/PPSSPP'),
                                       str(cpp), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            subprocess.run([str(binary)], check=True, capture_output=True)

    @unittest.skipUnless(shutil.which('clang++'), 'Objective-C++ compiler required')
    def test_commands_wait_for_engine_owner_and_retired_completion_cannot_finish_new_work(self):
        source = NATIVE.read_text()
        harness = r'''#import <Foundation/Foundation.h>
#include <atomic>
#include <cassert>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
@interface Owner : NSObject
@property BOOL closing;
@property BOOL initialized;
@end
@implementation Owner
@end
static Owner *container;
static std::atomic<int> pendingResolution, currentResolution, pendingState;
static std::atomic<bool> stateBusy,acceptingCallbacks;
static std::atomic<uint64_t> generation;
static bool reportedCoreError, initialized;
static int coreState;
static const int CORE_RUNTIME_ERROR = 99;
static unsigned notifications, saves, loads, events, lastKind;
static int lastSlot;
bool PSP_IsInited() { return initialized; }
bool ir_native_psp_generation_current(uint64_t owner) { return acceptingCallbacks && generation==owner; }
void event(unsigned kind,const char *) { ++events;lastKind=kind; }
struct Config { int iInternalResolution=2; void Save(const char*) { ++saves; } } g_Config;
namespace Reporting { void UpdateConfig() {} }
enum class UIMessage { GPU_RENDER_RESIZED };
void System_PostUIMessage(UIMessage) { ++notifications; }
static int g_paramSFO;
namespace SaveState {
 enum class Status { FAILURE,WARNING,SUCCESS };
 using Callback=std::function<void(Status,std::string_view)>;
 static Callback completion;
 std::string GetGamePrefix(int) { return "fixture"; }
 void SaveSlot(std::string_view prefix,int slot,Callback cb) { assert(prefix=="fixture");++saves;lastSlot=slot;completion=cb; }
 void LoadSlot(std::string_view prefix,int slot,Callback cb) { assert(prefix=="fixture");++loads;lastSlot=slot;completion=cb; }
}
''' + function(source, 'bool ir_native_psp_request(') + '\n' + function(source, 'void ir_native_psp_frontend_frame(') + r'''
int main() { @autoreleasepool {
 assert(!ir_native_psp_request(1,2));
 container=[Owner new];container.initialized=YES;acceptingCallbacks=true;generation=10;
 assert(!ir_native_psp_request(1,0) && !ir_native_psp_request(1,5));
 assert(!ir_native_psp_request(2,-1) && !ir_native_psp_request(3,5));
 assert(ir_native_psp_request(1,1));assert(ir_native_psp_request(1,4));
 assert(ir_native_psp_request(2,3));assert(!ir_native_psp_request(3,2));
 ir_native_psp_frontend_frame();assert(pendingState==23 && pendingResolution==4 && saves==0);
 initialized=true;ir_native_psp_frontend_frame();
 assert(currentResolution==4 && notifications==1 && saves==2 && lastSlot==3 && stateBusy);
 ir_native_psp_frontend_frame();assert(saves==2);
 SaveState::completion(SaveState::Status::SUCCESS,"saved");assert(!stateBusy && lastKind==5);
 assert(ir_native_psp_request(3,1));ir_native_psp_frontend_frame();assert(loads==1 && lastSlot==1);
 auto old=SaveState::completion;
 generation=11;stateBusy=true;unsigned before=events;
 old(SaveState::Status::SUCCESS,"retired");assert(stateBusy && events==before);
 stateBusy=false;assert(ir_native_psp_request(3,2));ir_native_psp_frontend_frame();
 SaveState::completion(SaveState::Status::FAILURE,"failed");assert(!stateBusy && lastKind==6);
 container.closing=YES;assert(!ir_native_psp_request(2,0));
 coreState=CORE_RUNTIME_ERROR;ir_native_psp_frontend_frame();assert(lastKind==2);
 unsigned errors=events;ir_native_psp_frontend_frame();assert(events==errors);
} }
'''
        with tempfile.TemporaryDirectory() as folder:
            code = Path(folder) / 'commands.mm'; code.write_text(harness)
            binary = Path(folder) / 'commands'
            result = subprocess.run(['clang++', '-std=c++17', '-fobjc-arc', '-framework', 'Foundation',
                                     str(code), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            subprocess.run([str(binary)], check=True, capture_output=True)


if __name__ == '__main__': unittest.main()
