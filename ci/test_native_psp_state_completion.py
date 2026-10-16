"""Run the pinned save-state admission paths against the actual native adapter."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from test_native_psp_frontend import function

ROOT = Path(__file__).resolve().parents[1]


class NativePSPStateCompletionTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('clang++'), 'Objective-C++ compiler required')
    def test_upstream_policy_rejections_complete_without_releasing_queued_work(self):
        upstream = ROOT / 'vendor/PPSSPP/Core/SaveState.cpp'
        if not upstream.exists(): self.skipTest('Pinned checkout required')
        saved = upstream.read_text()
        native = (ROOT / 'iridium/apps/ios/RuntimeBridge/IRPPSSPPNative.mm').read_text()
        harness = r'''#import <Foundation/Foundation.h>
#include <atomic>
#include <cassert>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>
#define ERROR_LOG(...) ((void)0)
@interface Owner : NSObject
@property BOOL closing;
@property BOOL initialized;
@end
@implementation Owner
@end
static Owner *container;
static std::atomic<int> pendingResolution, currentResolution, pendingState;
static std::atomic<bool> stateBusy, acceptingCallbacks;
static std::atomic<uint64_t> generation;
static bool reportedCoreError, hardcore;
static unsigned events, lastKind, networkChecks, rejectNetworkFrom;
static std::string lastMessage;
enum CoreState { CORE_RUNNING, CORE_RUNTIME_ERROR };
static CoreState coreState=CORE_RUNNING;
enum class BreakReason { SavestateLoad, SavestateSave };
void Core_Break(BreakReason,int) {}
bool PSP_IsInited() { return true; }
bool NetworkAllowSaveState() { return !rejectNetworkFrom || ++networkChecks<rejectNetworkFrom; }
bool ir_native_psp_generation_current(uint64_t owner) { return acceptingCallbacks && generation==owner; }
void event(unsigned kind,const char *message) { ++events;lastKind=kind;lastMessage=message; }
struct Config {
 int iInternalResolution=2, iStateUndoLastSaveSlot=0;
 bool bEnableStateUndo=false, bAchievementsSaveStateInHardcoreMode=false;
 std::string sStateLoadUndoGame,sStateUndoLastSaveGame;
 void Save(const char*) {}
} g_Config;
namespace Achievements { bool HardcoreModeActive() { return hardcore; } }
namespace Reporting { void UpdateConfig() {} }
enum class UIMessage { GPU_RENDER_RESIZED };
void System_PostUIMessage(UIMessage) {}
static int g_paramSFO;
struct Path {
 std::string value;
 Path()=default;
 Path(std::string text):value(text) {}
 bool empty() const { return value.empty(); }
 Path WithExtraExtension(const char *extension) const { return Path(value+extension); }
 Path operator/(const char *part) const { return Path(value+"/"+part); }
};
namespace File { void Rename(const Path&,const Path&) {} }
static constexpr int DIRECTORY_SAVESTATE=1, LOAD_UNDO_SLOT=-2;
static const char *STATE_EXTENSION="ppst",*UNDO_STATE_EXTENSION="undo.ppst";
static const char *SCREENSHOT_EXTENSION="jpg",*UNDO_SCREENSHOT_EXTENSION="undo.jpg";
static const char *LOAD_UNDO_NAME="load_undo.ppst";
Path GetSysDirectory(int) { return Path("fixture"); }
enum class I18NCat { SYSTEM };
struct Category { const char *T(const char *value) { return value; } };
Category *GetI18NCategory(I18NCat) { static Category category;return &category; }
namespace SaveState {
 enum class Status { FAILURE,WARNING,SUCCESS };
 using Callback=std::function<void(Status,std::string_view)>;
 OPERATION_TYPE;
 OPERATION;
 static std::vector<Operation> g_pendingOperations;
 static std::mutex mutex;
 static bool needsProcess;
 static struct Rewind { void NotifyState() {} } rewindStates;
 std::string GetGamePrefix(int) { return "fixture"; }
 Path GenerateSaveSlotPath(std::string_view prefix,int slot,const char *ext) {
  return Path(std::string(prefix)+std::to_string(slot)+ext);
 }
 void DeleteIfExists(const Path&) {}
 void RenameIfExists(const Path&,const Path&) {}
 void ScheduleSaveScreenshot(const Path&) {}
 void Rescan(std::string_view) {}
 UPSTREAM_FUNCTIONS
}
ADAPTER_FUNCTIONS
static void fresh() {
 ++generation; acceptingCallbacks=true;
 SaveState::g_pendingOperations.clear();
 pendingState=0;stateBusy=false;events=0;lastKind=0;lastMessage.clear();
 networkChecks=0;rejectNetworkFrom=0;hardcore=false;
 g_Config.bEnableStateUndo=false;g_Config.bAchievementsSaveStateInHardcoreMode=false;
}
static void submit(unsigned operation) {
 assert(ir_native_psp_request(operation,0));
 ir_native_psp_frontend_frame();
}
static void completeFirst(SaveState::Status status=SaveState::Status::SUCCESS) {
 assert(!SaveState::g_pendingOperations.empty());
 auto op=SaveState::g_pendingOperations.front();
 SaveState::g_pendingOperations.erase(SaveState::g_pendingOperations.begin());
 op.callback(status,"fixture completion");
}
static void rejected() {
 assert(!stateBusy && events==1 && lastKind==6);
 assert(lastMessage.find("declined")!=std::string::npos);
 assert(SaveState::g_pendingOperations.empty());
 // The UI can accept another request immediately after the rejected one.
 rejectNetworkFrom=0;hardcore=false;
 assert(ir_native_psp_request(2,1));ir_native_psp_frontend_frame();assert(stateBusy);
 completeFirst();assert(!stateBusy && events==2 && lastKind==5);
}
int main() { @autoreleasepool {
 container=[Owner new];container.initialized=YES;
 // Every network early-return layer: SaveSlot/Save/Enqueue and LoadSlot/Load/Enqueue.
 for(unsigned operation:{2u,3u}) for(unsigned layer=1;layer<=3;++layer) {
  fresh();rejectNetworkFrom=layer;submit(operation);rejected();
 }
 // Load with undo has an asynchronous backup, then a second admission path.
 for(unsigned layer=1;layer<=5;++layer) {
  fresh();g_Config.bEnableStateUndo=true;rejectNetworkFrom=layer;submit(3);
  if(layer>=4) {
   assert(stateBusy && events==0 && SaveState::g_pendingOperations.size()==1);
   assert(!ir_native_psp_request(2,1));completeFirst();
  }
  rejected();
 }
 // Hardcore rejects saving unless explicitly allowed, and always rejects loading.
 fresh();hardcore=true;submit(2);rejected();
 for(bool undo:{false,true}) for(bool allowSave:{false,true}) {
  fresh();hardcore=true;g_Config.bEnableStateUndo=undo;
  g_Config.bAchievementsSaveStateInHardcoreMode=allowSave;submit(3);
  if(undo && allowSave) { assert(stateBusy && events==0);completeFirst(); }
  rejected();
 }
 fresh();hardcore=true;g_Config.bAchievementsSaveStateInHardcoreMode=true;submit(2);
 assert(stateBusy && events==0);completeFirst();assert(!stateBusy && events==1 && lastKind==5);
 // Real queued ownership persists across frames; elapsed frames cannot unlock it.
 fresh();submit(2);
 for(int i=0;i<1000;++i) ir_native_psp_frontend_frame();
 assert(stateBusy && events==0 && !ir_native_psp_request(3,0));
 auto old=SaveState::g_pendingOperations.front().callback;
 completeFirst();assert(!stateBusy && events==1);
 submit(3);old(SaveState::Status::FAILURE,"duplicate");
 assert(stateBusy && events==1);completeFirst();assert(!stateBusy && events==2);
 // An abandoned callback from a retired session cannot clear its successor.
 fresh();submit(2);++generation;stateBusy=true;SaveState::g_pendingOperations.clear();
 assert(stateBusy && events==0);
 // The normal upstream callback also completes a failed operation exactly once.
 fresh();submit(3);completeFirst(SaveState::Status::FAILURE);
 assert(!stateBusy && events==1 && lastKind==6);
 puts("PASS upstream network/hardcore rejection, undo chain, queued ownership and once-only generation-safe completion");
} }
'''
        harness = harness.replace('OPERATION_TYPE', function(saved, 'enum class OperationType'))
        harness = harness.replace('OPERATION', function(saved, 'struct Operation'))
        harness = harness.replace('UPSTREAM_FUNCTIONS', '\n'.join(function(saved, signature) for signature in (
            'void Enqueue(', 'void Load(', 'void Save(', 'void LoadSlot(', 'void SaveSlot(')))
        harness = harness.replace('ADAPTER_FUNCTIONS', '\n'.join(function(native, signature) for signature in (
            'bool ir_native_psp_request(', 'void ir_native_psp_frontend_frame(')))
        with tempfile.TemporaryDirectory() as folder:
            code = Path(folder) / 'state.mm'; code.write_text(harness)
            binary = Path(folder) / 'state'
            result = subprocess.run(['clang++', '-std=c++17', '-fobjc-arc', '-framework', 'Foundation',
                                     str(code), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('PASS upstream network/hardcore rejection', result.stdout)


if __name__ == '__main__': unittest.main()
