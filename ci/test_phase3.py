"""Phase 3 build reuse and corresponding-source boundaries."""
from host_tests import module_cache
import importlib.util
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'ci' / file)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


builder = load('phase3_test_builder', 'build-phase3.py')
collector = load('phase3_test_collector', 'collect-madeira-source.py')


class Phase3Tests(unittest.TestCase):

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for player ownership checks')
    def test_failed_jit_configuration_releases_retained_player(self):
        source = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumConsoleSession.swift').read_text()
        start = source.index('        guard let controller else {')
        gate = source[start:source.index('        if game.runtimeID == "dolphin" {', start)]
        handoff = next(line for line in source[start:].splitlines() if line.strip().startswith('phase3Controller ='))
        fixture = '''import Foundation
final class UIViewController {
    static var live = 0
    init() { Self.live += 1 }
    deinit { Self.live -= 1 }
}
struct Game { var runtimeID: String }
final class Queue { func async(execute: () -> Void) { execute() } }
@MainActor var configurationAccepted = false
@MainActor var stops = 0
let jit26_prepare_region = 1
@MainActor func ir_phase3_configure_memory(_ prepare: Int) -> Bool { configurationAccepted }
func ir_jit_memory_api() -> Int { 1 }
@MainActor func ir_phase3_stop() { stops += 1 }
@MainActor final class Host {
    let queue = Queue(), owner = 1
    var error: String?, terminalFailure = false, completions = 0
    var phase3Controller: UIViewController?
    func complete(_ owner: Int) { completions += 1 }
    func open(_ controller: UnsafeMutableRawPointer?, game: Game) {
GATE
HANDOFF
    }
}
MainActor.assumeIsolated {
    for runtime in ["azahar", "play", "flycast"] {
        let failed = Host()
        failed.open(Unmanaged.passRetained(UIViewController()).toOpaque(), game: Game(runtimeID: runtime))
        precondition(UIViewController.live == 0 && failed.phase3Controller == nil && failed.error != nil && failed.terminalFailure)
    }
    precondition(stops == 3)
    configurationAccepted = true
    let ready = Host()
    ready.open(Unmanaged.passRetained(UIViewController()).toOpaque(), game: Game(runtimeID: "play"))
    precondition(UIViewController.live == 1 && ready.phase3Controller != nil && ready.error == nil)
    ready.phase3Controller = nil
    precondition(UIViewController.live == 0)
    let unavailable = Host()
    unavailable.open(nil, game: Game(runtimeID: "play"))
    precondition(unavailable.terminalFailure && unavailable.completions == 1 && UIViewController.live == 0)
}
'''.replace('GATE', gate).replace('HANDOFF', handoff)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'main.swift').write_text(fixture)
            subprocess.run(['swiftc', '-module-cache-path', module_cache('macosx'), str(root / 'main.swift'), '-o', str(root / 'check')], check=True, timeout=30)
            subprocess.run([str(root / 'check')], check=True, timeout=5)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for resume checks')
    def test_shared_jit_resume_uses_prepared_memory_and_preserves_stop(self):
        source = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumConsoleSession.swift').read_text()
        resume = source[source.index('    func resume() {'):source.index('        lock.lock(); intent.resume();', source.index('    func resume() {'))]
        fixture = '''import Foundation
@MainActor var attached = false
@MainActor var stopped = 0
@MainActor func ir_jit_memory_ready() -> Bool { attached }
@MainActor func ir_phase3_stop() { stopped += 1 }
@MainActor final class JITCoordinator {
    static let shared = JITCoordinator()
    var calls = 0
    var callback: ((Result<Void, Error>) -> Void)?
    func prepareConsoleMemory(completion: @escaping (Result<Void, Error>) -> Void) {
        calls += 1; callback = completion
    }
    func finish(_ result: Result<Void, Error>) { let cb = callback; callback = nil; cb?(result) }
}
@MainActor final class Host {
    enum Phase { case paused, running }
    enum Request { case play, stop }
    var lease: Int? = 1, phase = Phase.paused, requested = Request.play
    var dolphinStatePending = false, phase3JITRequested = true, phase3PreparingJIT = false
    var phase3Controller: Int? = 1, resumed = 0, error: String?
    let lock = NSLock()
    var intentGeneration = 0
RESUME
        resumed += 1; phase = .running
    }
}
MainActor.assumeIsolated {
    let service = JITCoordinator.shared
    let ready = Host(); attached = true; ready.resume()
    precondition(ready.resumed == 1 && service.calls == 0)
    let lost = Host(); attached = false; lost.resume(); lost.resume()
    precondition(lost.resumed == 0 && service.calls == 1 && lost.phase3PreparingJIT)
    attached = true; service.finish(.success(()))
    precondition(lost.resumed == 1 && !lost.phase3PreparingJIT)
    let cancelled = Host(); attached = false; cancelled.resume(); cancelled.requested = .stop
    service.finish(.success(()))
    precondition(cancelled.resumed == 0 && stopped == 1)
    let failed = Host(); failed.resume()
    service.finish(.failure(NSError(domain: "fixture", code: 1)))
    precondition(failed.resumed == 0 && failed.phase == .paused && failed.error != nil)
    let stale = Host(); stale.resume(); stale.lease = 2
    service.finish(.success(()))
    precondition(stale.resumed == 0 && stopped == 1)
    let backgrounded = Host(); backgrounded.resume(); backgrounded.intentGeneration += 1
    attached = true; service.finish(.success(()))
    precondition(backgrounded.resumed == 0 && !backgrounded.phase3PreparingJIT)
}
'''.replace('RESUME', resume)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'main.swift').write_text(fixture)
            subprocess.run(['swiftc', '-module-cache-path', module_cache('macosx'), str(root / 'main.swift'), '-o', str(root / 'check')], check=True, timeout=30)
            subprocess.run([str(root / 'check')], check=True, timeout=5)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for Dolphin launch checks')
    def test_advanced_launches_require_shared_jit_and_preserve_cancellation(self):
        source = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumConsoleSession.swift').read_text()
        launch = source[source.index('    @MainActor private func openPhase3('):source.index('        guard let frameworks =', source.index('    @MainActor private func openPhase3('))]
        settings = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumDolphinSettings.swift').read_text()
        settings = settings[settings.index('struct IridiumDolphinSettings:'):settings.index('/// Sensor samples')]
        fixture = r'''import Foundation
struct IRDolphinOptions { var resolution: Int32, aspect: Int32, remote: Int32, players: Int32; var dual_core: Bool, use_jit: Bool, muted: Bool }
SETTINGS
typealias IridiumRuntimeLease = Int
struct IridiumConsoleGame { var runtimeID = "dolphin"; var id = UUID() }
enum IridiumRuntimeError: Error { case jitRequired; var localizedDescription: String { "JIT required" } }
@MainActor final class JITCoordinator {
    static let shared = JITCoordinator()
    var consoleMemoryRequiresRestart = false
    var callback: ((Result<Void, Error>) -> Void)?
    func prepareConsoleMemory(completion: @escaping (Result<Void, Error>) -> Void) {
        callback = completion
    }
    func finish(_ result: Result<Void, Error>) { let saved = callback; callback = nil; saved?(result) }
}
final class Queue { func async(execute: () -> Void) { execute() } }
@MainActor final class Host {
    enum Request { case play, stop }
    var requested = Request.play, phase3PreparingJIT = false, phase3JITRequested = false
    var lease = 1, phase3Status = "", dolphinSettings = IridiumDolphinSettings()
    var nativeStarts = 0, completions = 0, error: String?
    let queue = Queue()
    func complete(_ owner: Int) { precondition(owner == lease); completions += 1 }
    func fail(_ message: String, owner: Int) { error = message; complete(owner) }
    func requireRestart(_ owner: Int) { error = "restart" }
LAUNCH
        nativeStarts += 1
    }
    func start(_ ready: Bool? = nil, runtimeID: String = "dolphin") {
        let url = URL(fileURLWithPath: "/fixture")
        openPhase3(game: IridiumConsoleGame(runtimeID: runtimeID), url: url, folder: url, system: url, owner: lease, phase3JITReady: ready)
    }
}
MainActor.assumeIsolated {
    // Legacy per-game JIT=false must not erase mute, saves or other settings.
    let id = UUID()
    let legacy = Data(#"{"resolution":2,"aspect":1,"remote":2,"players":3,"dualCore":false,"motion":false,"jit":false,"muted":true}"#.utf8)
    UserDefaults.standard.set(legacy, forKey: "Dolphin.\(id)")
    defer { UserDefaults.standard.removeObject(forKey: "Dolphin.\(id)") }
    let restored = IridiumDolphinSettings.load(id)
    precondition(restored.resolution == 2 && restored.players == 3 && restored.muted == true && !restored.dualCore)
    for runtimeID in ["dolphin", "azahar", "play", "flycast"] {
    let failed = Host(); failed.start(runtimeID: runtimeID)
    precondition(failed.nativeStarts == 0 && failed.phase3PreparingJIT && failed.phase3JITRequested)
    JITCoordinator.shared.finish(.failure(IridiumRuntimeError.jitRequired))
    precondition(failed.nativeStarts == 0 && failed.completions == 1 && failed.error!.contains("JIT could not start"))
    precondition(!failed.phase3PreparingJIT)
    let cancelled = Host(); cancelled.start(runtimeID: runtimeID); cancelled.requested = .stop
    JITCoordinator.shared.finish(.success(()))
    precondition(cancelled.nativeStarts == 0 && cancelled.completions == 1)
    let unclean = Host(); unclean.start(runtimeID: runtimeID); unclean.requested = .stop
    JITCoordinator.shared.consoleMemoryRequiresRestart = true
    JITCoordinator.shared.finish(.failure(IridiumRuntimeError.jitRequired))
    precondition(unclean.nativeStarts == 0 && unclean.completions == 0 && unclean.error == "restart")
    JITCoordinator.shared.consoleMemoryRequiresRestart = false
    let stale = Host(); stale.start(runtimeID: runtimeID); stale.lease = 2
    JITCoordinator.shared.finish(.success(()))
    precondition(stale.nativeStarts == 0 && stale.completions == 0)
    let ready = Host(); ready.start(runtimeID: runtimeID); JITCoordinator.shared.finish(.success(()))
    precondition(ready.nativeStarts == 1 && ready.error == nil && !ready.phase3PreparingJIT)
    let invalid = Host(); invalid.start(false, runtimeID: runtimeID)
    precondition(invalid.nativeStarts == 0 && invalid.completions == 1)
    }
}
'''.replace('SETTINGS', settings).replace('LAUNCH', launch)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); unit = folder / 'main.swift'; unit.write_text(fixture)
            binary = folder / 'check'
            subprocess.run(['swiftc', '-module-cache-path', module_cache('macosx'), str(unit), '-o', str(binary)], check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=5)

    @unittest.skipUnless(shutil.which('c++'), 'C++ compiler required for Dolphin native JIT gate')
    def test_dolphin_native_boot_rejects_missing_or_failed_jit(self):
        source = (ROOT / 'iridium/apps/ios/RuntimeBridge/IRDolphin.mm').read_text()
        gate = source[source.index('    if(!options.use_jit||!prepareNativeJIT())'):source.index('    DolphinAnalytics::Instance().ReportDolphinStart')]
        gate = gate.replace('[self finish]', 'finish()')
        fixture = r'''#include <cassert>
#include <atomic>
#include "IRDolphinAPI.h"
namespace PowerPC { enum class CPUCore { JITARM64 }; }
enum class VertexLoaderType { Native };
namespace Config {
enum Key { MAIN_CPU_CORE,MAIN_FASTMEM,MAIN_FASTMEM_ARENA,MAIN_DSP_HLE,MAIN_DSP_JIT,MAIN_GFX_BACKEND,MAIN_AUDIO_BACKEND,GFX_VERTEX_LOADER_TYPE };
static int writes=0;
template<class T> void SetCurrent(Key,T) { ++writes; }
}
#include <string>
#define BACKEND_COREAUDIO "CoreAudio"
static unsigned probes=0,boots=0,stops=0,errors=0,verified=0;
static bool probeResult=false;
struct Player {
    IRDolphinOptions options{};std::atomic<bool> jitVerified{false};unsigned generation=1;
    bool prepareNativeJIT(){++probes;return probeResult;}
    void event(unsigned,unsigned kind,const char*){if(kind==3)++errors;if(kind==5)++verified;}
    void finish(){++stops;}
    void boot(){
GATE
        ++boots;
    }
};
int main(){
    Player p;p.boot();assert(!probes&&!boots&&stops==1&&errors==1&&!Config::writes);
    p.options.use_jit=true;p.boot();assert(probes==1&&!boots&&stops==2&&errors==2&&!Config::writes&&!p.jitVerified);
    probeResult=true;p.boot();assert(probes==2&&boots==1&&stops==2&&errors==2&&verified==1&&p.jitVerified);
}
'''.replace('GATE', gate)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); unit = folder / 'main.cpp'; unit.write_text(fixture)
            binary = folder / 'check'
            subprocess.run(['c++', '-std=c++20', '-I', str(ROOT / 'iridium/apps/ios/RuntimeBridge'), str(unit), '-o', str(binary)], check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=5)

    @unittest.skipUnless(shutil.which('clang++') and (ROOT / 'vendor/Dolphin/Source/Core/Core/PowerPC/Interpreter/Interpreter_FPUtils.h').is_file(), 'Dolphin source and Clang required')
    def test_dolphin_interpreter_preserves_guest_rounding_modes(self):
        recipe = (ROOT / 'ci/dolphin-targets.cmake').read_text()
        flags = {}
        for target in ('core', 'common'):
            match = re.search(r'target_compile_options\(' + target + r' PRIVATE ([^)]+)\)', recipe)
            self.assertIsNotNone(match, target + ' must retain the floating-point build contract')
            flags[target] = match.group(1).split()
        self.assertEqual(flags['core'], flags['common'])
        source = (ROOT / 'vendor/Dolphin/Source/Core/Core/PowerPC/Interpreter/Interpreter_FPUtils.h').read_text()
        conversion = source[source.index('inline float ForceSingle('):source.index('inline double ForceDouble(')]
        fixture = r'''#include <bit>
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cassert>
using u64=uint64_t;using u32=uint32_t;
struct UReg_FPSCR { bool NI=false; };
struct { bool bFlushToZero=true; } cpu_info;
namespace Common {
constexpr u64 DOUBLE_EXP=0x7ff0000000000000ULL,DOUBLE_FRAC=0xfffffffffffffULL,DOUBLE_SIGN=0x8000000000000000ULL;
float FlushToZero(float x) { return std::fpclassify(x)==FP_SUBNORMAL?std::copysign(0.f,x):x; }
}
''' + conversion + r'''
int main() {
    UReg_FPSCR fpscr;
    const double halfway=1.0+0x1p-24;
    const int modes[]={FE_TONEAREST,FE_DOWNWARD,FE_UPWARD,FE_TOWARDZERO};
    const u32 positive[]={0x3f800000,0x3f800000,0x3f800001,0x3f800000};
    const u32 negative[]={0xbf800000,0xbf800001,0xbf800000,0xbf800000};
    for(unsigned n=0;n<4;++n) {
        assert(std::fesetround(modes[n])==0);
        assert(std::bit_cast<u32>(ForceSingle(fpscr,halfway))==positive[n]);
        assert(std::bit_cast<u32>(ForceSingle(fpscr,-halfway))==negative[n]);
    }
    assert(std::fesetround(FE_TONEAREST)==0);
    fpscr.NI=true;
    assert(std::bit_cast<u32>(ForceSingle(fpscr,0x1p-130))==0);
    assert(std::bit_cast<u32>(ForceSingle(fpscr,-0x1p-130))==0x80000000);
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); unit = folder / 'rounding.cpp'; unit.write_text(fixture)
            binary = folder / 'check'
            subprocess.run(['clang++', '-std=c++20', '-O3', *flags['core'], str(unit), '-o', str(binary)], check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=5)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for controller reconnect checks')
    def test_dolphin_controller_slots_reuse_disconnects_without_player_aliasing(self):
        source = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumConsoleSession.swift').read_text()
        slots = source[source.index('    private func updateDolphinControllers('):source.index('    private func fillDolphinInput(')]
        inputs = source[source.index('    private func fillPhase3Input('):source.index('    private func startTimer(')]
        fixture = '''import Foundation
final class Button { var isPressed = false }
final class Axis { var value: Float = 0 }
final class Stick { let xAxis = Axis(), yAxis = Axis() }
final class DPad { let up = Button(), down = Button(), left = Button(), right = Button() }
final class Pad {
    let buttonA = Button(), buttonB = Button(), buttonX = Button(), buttonY = Button(), buttonMenu = Button()
    let leftShoulder = Button(), rightShoulder = Button(), leftTrigger = Button(), rightTrigger = Button()
    var buttonOptions: Button? = Button(), leftThumbstickButton: Button? = Button(), rightThumbstickButton: Button? = Button()
    let dpad = DPad(), leftThumbstick = Stick(), rightThumbstick = Stick()
}
final class GCController {
    static var current: GCController?
    static var live: [GCController] = []
    static func controllers() -> [GCController] { live }
    var extendedGamepad: Pad? = Pad()
}
struct IRPhase3Input {
    var buttons: UInt16 = 0
    var right_x: Int16 = 0, right_y: Int16 = 0, pointer_x: Int16 = 0, pointer_y: Int16 = 0
    var pointer_down = false
}
final class Host {
    enum Backend { case sameBoy, psp, advanced }
    enum Request { case play, pause }
    struct Intent { var request = Request.play }
    let lock = NSLock()
    var dolphinControllers = [GCController?](repeating: nil, count: 4)
    var digitalInput = IridiumPolledInput(), intent = Intent(), backend = Backend.advanced
    var touchAnalog: (Int16, Int16) = (0, 0), keyboardAnalog: (Int16, Int16) = (0, 0), rightAnalog: (Int16, Int16) = (0, 0)
    var consolePointer: (Int16, Int16, Bool) = (0, 0, false)
    var suppressController = false
METHODS
    func check() {
        let a = GCController(), b = GCController(), c = GCController(), d = GCController(), e = GCController()
        updateDolphinControllers([a,b])
        precondition(dolphinControllers[0] === a && dolphinControllers[1] === b)
        updateDolphinControllers([b,a])
        precondition(dolphinControllers[0] === a && dolphinControllers[1] === b)
        updateDolphinControllers([b])
        precondition(dolphinControllers[0] == nil && dolphinControllers[1] === b)
        GCController.current = b; GCController.live = [b]
        b.extendedGamepad!.buttonA.isPressed = true
        b.extendedGamepad!.rightTrigger.isPressed = true
        b.extendedGamepad!.leftThumbstick.xAxis.value = 1
        b.extendedGamepad!.rightThumbstick.xAxis.value = 1
        // An empty player-1 slot must not read player 2's live or current controller.
        let empty = input(controller: dolphinControllers[0])
        precondition(empty.digital.buttons == 0 && empty.x == 0 && empty.y == 0)
        var output = IRPhase3Input()
        withUnsafeMutablePointer(to: &output) { fillPhase3Input($0, controller: dolphinControllers[0]) }
        precondition(output.buttons == 0 && output.right_x == 0)
        // Other engines keep their existing default-controller behavior.
        let selected = input()
        precondition(selected.digital.buttons & (1 << 8) != 0 && selected.x == 32767)
        withUnsafeMutablePointer(to: &output) { fillPhase3Input($0) }
        precondition(output.buttons & (1 << 13) != 0 && output.right_x == 32767)
        updateDolphinControllers([b,c,d,e])
        precondition(dolphinControllers[0] === c && dolphinControllers[1] === b)
        precondition(dolphinControllers[2] === d && dolphinControllers[3] === e)
        updateDolphinControllers([a,b,c,d,e])
        precondition(dolphinControllers.count == 4 && !dolphinControllers.contains { $0 === a })
        updateDolphinControllers([])
        precondition(dolphinControllers.allSatisfy { $0 == nil })
        for _ in 0..<20 {
            let replacement = GCController()
            updateDolphinControllers([replacement])
            precondition(dolphinControllers.count == 4 && dolphinControllers[0] === replacement)
        }
    }
}
Host().check()
'''.replace('METHODS', slots + inputs)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); unit = folder / 'main.swift'; unit.write_text(fixture)
            binary = folder / 'check'
            subprocess.run(['swiftc', str(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumPolledInput.swift'),
                            str(unit), '-o', str(binary)], check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=5)

    @unittest.skipUnless(shutil.which('c++') and (ROOT / 'vendor/Dolphin/Source/Core/Common/MemoryUtil_iOS_LuckTXM.cpp').is_file(), 'Dolphin source and C++ compiler required')
    def test_dolphin_allocator_calls_shared_memory_service(self):
        native = (ROOT / 'iridium/apps/ios/RuntimeBridge/IRDolphin.mm').read_text()
        bridge = native[native.index('static std::atomic<ptrdiff_t> sharedDifference'):native.index('static bool dolphinAlert(')]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            generated = builder.generated('dolphin', folder)
            memory = (generated / 'MemoryUtil_iOS_LuckTXM.cpp').read_text().replace('#include "Common/MemoryUtil.h"', '')
            main = folder / 'allocator.cpp'
            main.write_text(r'''#include <atomic>
#include <cassert>
#include <cstddef>
#include <cstdint>
static int getpagesize() { return 16384; }
alignas(16384) static char bytes[32768];
static unsigned allocations, releases;
static bool fail, wrong;
void *ir_shared_jit_allocate(size_t size, void **write) {
    assert(size == 16384); ++allocations;
    if (fail) return nullptr;
    *write = bytes + (wrong ? 8192 : 16384); return bytes;
}
void ir_shared_jit_release(void *p) { assert(p == bytes); ++releases; }
''' + bridge + memory + r'''
int main() {
    Common::AllocateExecutableMemoryRegion_LuckTXM(); assert(allocations == 0);
    fail = true; assert(!Common::AllocateExecutableMemory_LuckTXM(4096));
    fail = false; assert(Common::AllocateExecutableMemory_LuckTXM(4096) == bytes);
    assert(Common::AllocateWritableRegionAndGetDiff_LuckTXM() == 16384);
    Common::FreeExecutableMemory_LuckTXM(bytes); assert(releases == 1);
    wrong = true; assert(!Common::AllocateExecutableMemory_LuckTXM(4096) && releases == 2);
}
''')
            executable = folder / 'allocator'
            subprocess.run(['c++', '-std=c++17', str(main), '-o', str(executable)], check=True, timeout=30)
            subprocess.run([str(executable)], check=True, timeout=5)

    @unittest.skipUnless(shutil.which('c++'), 'C++ compiler required for Dolphin installer tests')
    def test_dolphin_installer_reports_cleanup_and_blocks_uncertain_reuse(self):
        source = (ROOT / 'iridium/apps/ios/RuntimeBridge/IRDolphin.mm').read_text()
        install = source[source.index('[](const char *root,const char *wad,IRDolphinCompletion completion)'):source.index('};return &api;')]
        install = install.replace('DOLHostQueueRunAsync(^{', 'DOLHostQueueRunAsync([=]{')
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory);main = folder / 'install.cpp'
            main.write_text('''#include <atomic>
#include <cassert>
#include <functional>
#include <string>
#include "IRDolphinAPI.h"
struct Player { std::atomic<bool> ended{false}; };static Player* active=nullptr;
static std::atomic<bool> maintenanceUncertain{false};
static bool initThrows=false,installThrows=false,shutdownThrows=false,installed=true;
static bool result=false,restart=false;static int callbacks=0,shutdowns=0;
static void dolphinAlert() {}
namespace Common { void RegisterMsgAlertHandler(void(*)()) {} }
namespace Core {
  enum class State { Uninitialized, Running };static State state=State::Uninitialized;
  struct System { static System& GetInstance(){ static System s;return s;} };
  State GetState(System&) { return state; }
}
namespace UICommon {
  void SetUserDirectory(const std::string&) {} void CreateDirectories() {}
  void Init() { if(initThrows)throw 1; }
  void Shutdown() { ++shutdowns;if(shutdownThrows)throw 1; }
}
namespace WiiUtils { bool InstallWAD(const std::string&) { if(installThrows)throw 1;return installed; } }
static void DOLHostQueueRunAsync(std::function<void()> work) { work(); }
static void completed(bool ok,bool needsRestart,const char*) { result=ok;restart=needsRestart;++callbacks; }
int main() {
  auto install=''' + install + ''';
  install("save","wad",completed);assert(callbacks==1 && result && !restart && shutdowns==1);
  installed=false;install("save","wad",completed);assert(callbacks==2 && !result && !restart && shutdowns==2);
  installThrows=true;install("save","wad",completed);assert(callbacks==3 && !result && !restart && shutdowns==3);
  installThrows=false;initThrows=true;install("save","wad",completed);assert(callbacks==4 && !result && restart && maintenanceUncertain);
  initThrows=false;install("save","wad",completed);assert(callbacks==5 && !result && restart && shutdowns==3);
  maintenanceUncertain=false;shutdownThrows=true;install("save","wad",completed);
  assert(callbacks==6 && !result && restart && maintenanceUncertain && shutdowns==4);
  maintenanceUncertain=false;shutdownThrows=false;Core::state=Core::State::Running;
  install("save","wad",completed);assert(callbacks==7 && !result && !restart && shutdowns==4);
}
''')
            executable = folder / 'install'
            subprocess.run(['c++', '-std=c++17', '-I', str(ROOT / 'iridium/apps/ios/RuntimeBridge'), str(main), '-o', str(executable)], check=True, timeout=30)
            subprocess.run([str(executable)], check=True, timeout=5)

    @unittest.skipUnless(shutil.which('c++'), 'C++ compiler required for Dolphin profile tests')
    def test_dolphin_controller_extension_is_a_name_not_a_boolean(self):
        source = (ROOT / 'iridium/apps/ios/RuntimeBridge/IRDolphin.mm').read_text()
        assignment = next(line.strip() for line in source.splitlines() if 'profile->Set("Extension",' in line)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            main = folder / 'profile.cpp'
            main.write_text('''#include <cassert>
#include <string>
struct Profile {
    std::string value;
    void Set(const char*, const std::string& text) { value=text; }
    void Set(const char*, bool) { value="True"; }
};
struct Player { struct { int remote; } options; };
int main() {
    Profile config;auto profile=&config;Player player;auto p=&player;
    const char* expected[]={"None","Nunchuk","Classic"};
    for(int mode=0;mode<3;++mode) {
        p->options.remote=mode;
''' + assignment + '''
        assert(config.value==expected[mode]);
    }
}
''')
            executable = folder / 'profile'
            subprocess.run(['c++', '-std=c++17', str(main), '-o', str(executable)], check=True, timeout=30)
            subprocess.run([str(executable)], check=True, timeout=5)

    @unittest.skipUnless(shutil.which('c++'), 'C++ compiler required for Dolphin input boundary tests')
    def test_dolphin_inputs_preserve_players_signed_axes_triggers_and_motion(self):
        source = (ROOT / 'iridium/apps/ios/RuntimeBridge/IRDolphin.mm').read_text()
        sample = source[source.index('static void sampleController('):source.index('\n@implementation')]
        buttons = sorted(set(re.findall(r'\b(?:BUTTON|STICK|TRIGGER|WIIMOTE|NUNCHUK|CLASSIC)_[A-Z0-9_]+\b', sample)))
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            main = folder / 'input.cpp'
            main.write_text('''#include <algorithm>
#include <atomic>
#include <cassert>
#include <cmath>
#include <initializer_list>
#include <map>
#include "IRDolphinAPI.h"
namespace ciface::iOS {
enum ButtonType { ''' + ','.join(buttons) + ''' };
struct StateManager {
    std::map<std::pair<int,ButtonType>,bool> buttons;
    std::map<std::pair<int,ButtonType>,float> axes;
    static StateManager* GetInstance() { static StateManager manager; return &manager; }
    void SetButtonPressed(int id,ButtonType button,bool value) { buttons[{id,button}]=value; }
    void SetAxisValue(int id,ButtonType axis,float value) { axes[{id,axis}]=value; }
};
}
struct IRDolphinPlayer {
    IRDolphinOptions options{}; IRDolphinPoll dolphinInput; IRPhase3Poll input;
    std::atomic<unsigned> inputSamples{};
};
''' + sample + '''
static void poll(unsigned player,IRDolphinInput* sample) {
    sample->controls.buttons=(player==0?(1<<8)|(1<<12):1)|(player==1?(1<<11):0)|(player==2?(1<<13):0)|(player==3?(1<<14):0);
    sample->controls.left_x=-16384; sample->controls.left_y=-8192;
    sample->controls.right_x=8192; sample->controls.right_y=16384;
    sample->left_trigger=0.3f;sample->right_trigger=0.7f;
    sample->controls.pointer_down=true;sample->controls.pointer_x=16384;sample->controls.pointer_y=-8192;
    sample->acceleration[0]=-12.3f;sample->acceleration[2]=9.81f;sample->rotation[1]=-2.5f;
}
int main() {
    using namespace ciface::iOS;
    IRDolphinPlayer player;player.options.players=4;player.dolphinInput=poll;
    auto manager=StateManager::GetInstance();sampleController(&player);
    assert(player.inputSamples==1);
    assert(manager->buttons[std::make_pair(0,BUTTON_A)]);
    assert(!manager->buttons[std::make_pair(0,BUTTON_B)]);
    assert(manager->buttons[std::make_pair(1,BUTTON_B)]);
    assert(manager->buttons[std::make_pair(7,WIIMOTE_BUTTON_B)]);
    assert(manager->buttons[std::make_pair(4,WIIMOTE_SHAKE_X)]);
    // The upstream Touchscreen axes apply -1 for left/up themselves.
    assert(manager->axes[std::make_pair(0,STICK_MAIN_LEFT)]==-0.5f);
    assert(manager->axes[std::make_pair(0,STICK_MAIN_RIGHT)]==-0.5f);
    assert(manager->axes[std::make_pair(0,STICK_MAIN_UP)]==-0.25f);
    assert(manager->axes[std::make_pair(4,WIIMOTE_IR_RIGHT)]==0.5f);
    assert(manager->axes[std::make_pair(4,WIIMOTE_IR_UP)]==-0.25f);
    assert(manager->axes[std::make_pair(0,TRIGGER_L)]==0.3f);
    assert(manager->axes[std::make_pair(0,TRIGGER_R)]==0.7f);
    assert(manager->axes[std::make_pair(4,WIIMOTE_ACCEL_RIGHT)]==-12.3f);
    assert(manager->axes[std::make_pair(4,NUNCHUK_ACCEL_UP)]==9.81f);
    assert(manager->axes[std::make_pair(4,WIIMOTE_GYRO_ROLL_LEFT)]==-2.5f);
    assert(manager->buttons[std::make_pair(1,BUTTON_Z)]);
    assert(!manager->buttons[std::make_pair(2,BUTTON_Z)]);
    assert(manager->axes[std::make_pair(1,TRIGGER_R)]==0.7f);
    assert(manager->buttons[std::make_pair(6,WIIMOTE_BUTTON_HOME)]);
    assert(manager->buttons[std::make_pair(7,WIIMOTE_BUTTON_HOME)]);
    player.options.remote=2;sampleController(&player);
    assert(!manager->buttons[std::make_pair(6,WIIMOTE_BUTTON_HOME)]);
    assert(manager->buttons[std::make_pair(7,CLASSIC_BUTTON_HOME)]);
    assert(manager->buttons[std::make_pair(5,CLASSIC_BUTTON_ZR)]);
    assert(!manager->buttons[std::make_pair(6,CLASSIC_BUTTON_ZR)]);
    assert(!manager->buttons[std::make_pair(4,WIIMOTE_SHAKE_X)]);
    assert(manager->axes[std::make_pair(5,CLASSIC_TRIGGER_R)]==0.7f);
    player.options.players=1;sampleController(&player);
    assert(!manager->buttons[std::make_pair(1,BUTTON_B)]);
    assert(manager->axes[std::make_pair(1,TRIGGER_L)]==0);
}
''')
            executable = folder / 'input'
            subprocess.run(['c++', '-std=c++17', '-I', str(ROOT / 'iridium/apps/ios/RuntimeBridge'),
                            str(main), '-o', str(executable)], check=True, timeout=30)
            subprocess.run([str(executable)], check=True, timeout=5)

    @unittest.skipUnless(shutil.which('c++'), 'C++ compiler required for native session adapter tests')
    def test_generated_vm_pause_pumps_without_destroying_graphics(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'vendor/Play/Source/ui_libretro/main_libretro.cpp'
            source.parent.mkdir(parents=True)
            shared = source.parent.parent / 'app_shared'
            shared.mkdir()
            (shared / 'AppConfig.h').write_text('class CAppConfig {\n\tCAppConfig();\n};\n')
            for name in ('AppConfig.cpp', 'Log.cpp'): (shared / name).write_text('')
            source.write_text('''#include <filesystem>
#include <thread>
#include <cassert>
namespace fs = std::filesystem;
struct CAppConfig { fs::path GetBasePath() const; };
#include "DefaultAppConfig.h"
struct CVirtualMachine { enum { PAUSED, RUNNING }; };
static int status = CVirtualMachine::RUNNING, flushes = 0;
static bool pauseRequested = false;
struct CGSH_OpenGL_Libretro {
    void FlushMailBox() { assert(pauseRequested); if (++flushes == 2) status = CVirtualMachine::PAUSED; }
};
struct CPS2VM {
    CGSH_OpenGL_Libretro gs;
    int GetStatus() { return status; }
    void* GetGSHandler() { return &gs; }
    void PauseAsync() { pauseRequested = true; }
    void Resume() { status = CVirtualMachine::RUNNING; }
};
static CPS2VM vm;
static CPS2VM* m_virtualMachine = &vm;
static bool first_run = false;
void retro_init()\n{\n}\nvoid checkVarsUpdates() {\n\tstatic bool updates = true;\n}
extern "C" const char* ir_play_save_root() { return "isolated-root"; }
''')
            memory = root / 'vendor/Play/deps/CodeGen/src/MemoryFunction.cpp'
            memory.parent.mkdir(parents=True)
            memory.write_text('\tvm_size_t page_size = 0;\nold allocation\n#elif defined(MEMFUNC_USE_MMAP)\n'
                'vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), m_size);\n' + ''.join(
                '\tkern_return_t result = vm_protect(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), m_size, 0, ' + protection + ');\n\tassert(result == 0);\n'
                for protection in ('VM_PROT_READ | VM_PROT_WRITE', 'VM_PROT_READ | VM_PROT_EXECUTE')))
            (source.parent.parent / 'BasicBlock.cpp').write_text('auto code = reinterpret_cast<uint8*>(m_function.GetCode());\n' * 2)
            (root / 'ci').mkdir()
            shutil.copy2(ROOT / 'ci/phase3_play.py', root / 'ci/phase3_play.py')
            with patch.object(builder, 'ROOT', root): generated = builder.generated('play', root / 'output')
            main = generated / 'main_libretro.cpp'
            main.write_text(main.read_text() + '''
int main() {
    assert(ir_phase3_core_pause(true) && !pauseRequested);
    first_run = true;
    assert(ir_phase3_core_pause(true));
    assert(status == CVirtualMachine::PAUSED && flushes == 2);
    assert(ir_phase3_core_pause(false) && status == CVirtualMachine::RUNNING);
    assert(CAppConfig().GetBasePath() == "isolated-root");
}
''')
            executable = root / 'pause-test'
            subprocess.run(['c++', '-std=c++17', str(main), '-o', str(executable)], check=True, timeout=30)
            subprocess.run([str(executable)], check=True, timeout=5)

    def test_reuse_rejects_changed_abi_generated_and_compiled_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            # Source CI deliberately leaves optional engine submodules absent.
            # Discover the production input paths without reading those files,
            # then exercise real hashing against a complete temporary fixture.
            with patch.object(builder, 'digest', return_value='fixture'):
                inputs = builder.fixed_inputs('host')
            for name in inputs:
                target = root / name; target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('fixture input: ' + name + '\n')
            generated = root / '.build/phase3/host/iphoneos/embedding/native.exports'
            generated.parent.mkdir(parents=True); generated.write_text('_export\n')
            compiled = root / 'generated.c'; compiled.write_text('int value;\n')
            with patch.object(builder, 'ROOT', root):
                record = dict(engine='host', sdk='iphoneos', buildInputs=builder.fixed_inputs('host'),
                    compiledInputs={'generated.c': builder.digest(compiled)},
                    embedding={'native.exports': builder.digest(generated)})
                builder.verify_inputs(record)
                for target in (root / 'iridium/apps/ios/RuntimeBridge/IRPhase3.h',
                               root / 'vendor/Flycast/core/deps/libretro-common/include/libretro.h',
                               generated, compiled):
                    original = target.read_bytes(); target.write_bytes(original + b'changed')
                    with self.assertRaises(ValueError): builder.verify_inputs(record)
                    target.write_bytes(original)

    def test_source_state_rejects_dirty_source_and_changed_nested_pin(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'vendor/Engine'; source.mkdir(parents=True)
            env = dict(os.environ, GIT_AUTHOR_NAME='intraducine', GIT_COMMITTER_NAME='intraducine',
                GIT_AUTHOR_EMAIL='265588704+intraducine@users.noreply.github.com',
                GIT_COMMITTER_EMAIL='265588704+intraducine@users.noreply.github.com')
            def git(path, *args):
                return subprocess.check_output(['git', '-C', str(path), *args], env=env, stderr=subprocess.DEVNULL)
            git(source, 'init', '-q')
            child = source / 'dependency'; child.mkdir(); git(child, 'init', '-q')
            (child / 'source.c').write_text('int first;\n'); git(child, 'add', '.'); git(child, 'commit', '-qm', 'Fixture')
            (source / 'source.c').write_text('int root;\n'); git(source, 'add', '.'); git(source, 'commit', '-qm', 'Fixture')
            with patch.object(builder, 'ROOT', root):
                self.assertEqual(len(builder.source_state(source)), 2)
                (source / 'source.c').write_text('modified\n')
                with self.assertRaises(ValueError): builder.source_state(source)
                git(source, 'checkout', '--', 'source.c')
                (child / 'source.c').write_text('int second;\n'); git(child, 'add', '.'); git(child, 'commit', '-qm', 'Fixture changed')
                with self.assertRaises(ValueError): builder.source_state(source)

    def test_only_byte_identical_cmake_zconf_rename_is_allowed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'vendor/libchdr'; source.mkdir(parents=True)
            env = dict(os.environ, GIT_AUTHOR_NAME='intraducine', GIT_COMMITTER_NAME='intraducine',
                GIT_AUTHOR_EMAIL='265588704+intraducine@users.noreply.github.com',
                GIT_COMMITTER_EMAIL='265588704+intraducine@users.noreply.github.com')
            def git(*args): subprocess.run(['git', '-C', str(source), *args], env=env, check=True, stdout=subprocess.DEVNULL)
            git('init', '-q')
            header = source / 'deps/zlib-1.3.1/zconf.h'; header.parent.mkdir(parents=True); header.write_text('original\n')
            git('add', '.'); git('commit', '-qm', 'Fixture')
            included = header.with_name('zconf.h.included'); header.rename(included)
            with patch.object(builder, 'ROOT', root):
                builder.source_state(source)
                included.write_text('modified\n')
                with self.assertRaises(ValueError): builder.source_state(source)

    def test_every_new_binary_has_a_source_component(self):
        for name in ('libIridiumRetroPlayer.dylib', 'libIridiumDolphin.dylib', 'azahar_libretro.dylib',
                     'play_libretro_ios.dylib', 'flycast_libretro.dylib'):
            self.assertTrue(collector.binary_component('Frameworks/' + name))
        with self.assertRaises(ValueError): collector.binary_component('Frameworks/unknown.dylib')

    def test_flycast_context_overlay_is_checked_against_upstream(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'vendor/Flycast/core/deps/libretro-common/glsm/glsm.c'
            source.parent.mkdir(parents=True)
            source.write_text('#ifdef HAVE_OPENGLES\n   hw_render.context_type       = RETRO_HW_CONTEXT_OPENGLES2;\n#endif\n')
            main = root / 'vendor/Flycast/shell/libretro/libretro.cpp'
            main.parent.mkdir(parents=True); main.write_text('static bool first_run = true;\n')
            memory = root / 'vendor/Flycast/core/linux/posix_vmem.cpp'
            memory.parent.mkdir(parents=True)
            memory.write_text('// Prepares the code region for JIT operations\nold allocator\n} // namespace virtmem\n')
            for name, function in [('rec-ARM64/rec_arm64.cpp', 'jitWriteProtect'),
                                   ('hw/arm7/arm7_rec_arm64.cpp', 'JITWriteProtect'),
                                   ('hw/aica/dsp_arm64.cpp', 'JITWriteProtect')]:
                path = root / 'vendor/Flycast/core' / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('static void ' + function + '(bool enable)\n{\nold protection\n}\n' +
                    ('DynCode = pCodeBuffer;\n' if name.endswith('dsp_arm64.cpp') else ''))
            (root / 'ci').mkdir()
            shutil.copy2(ROOT / 'ci/phase3_flycast.py', root / 'ci/phase3_flycast.py')
            with patch.object(builder, 'ROOT', root):
                generated = builder.generated('flycast', root / 'output')
                self.assertIn('#ifdef HAVE_OPENGLES3', (generated / 'glsm.c').read_text())
                self.assertIn('emu.stop()', (generated / 'libretro.cpp').read_text())
                source.write_text('upstream changed\n')
                with self.assertRaises(ValueError): builder.generated('flycast', root / 'output')

    def test_dolphin_simulator_capability_overlay_requires_pinned_hook(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'vendor/Dolphin/Source/Core/VideoBackends/Metal/MTLUtil.mm'
            source.parent.mkdir(parents=True)
            capability = 'backend_info->bSupportsFramebufferFetch = [device supportsFamily:MTLGPUFamilyApple1];'
            source.write_text(capability + '\n')
            header = root / 'vendor/Dolphin/Source/Core/Common/CodeBlock.h'
            header.parent.mkdir(parents=True)
            header.write_text('''#include <cassert>
#include <cstdlib>
static int pages = 0, executablePages = 0, aliases = 0;
namespace Common {
void* AllocateMemoryPages(size_t n) { ++pages; return malloc(n); }
void* AllocateExecutableMemory(size_t n) { ++executablePages; return malloc(n); }
ptrdiff_t AllocateWritableRegionAndGetDiff(void*, size_t) { ++aliases; return 0; }
void FreeMemoryPages(void* p, size_t) { --pages; free(p); }
void FreeWritableRegion(void*, size_t, ptrdiff_t) { --aliases; }
void FreeExecutableMemory(void* p, size_t) { --executablePages; free(p); }
}
template<bool executable> struct Block {
void* region;
size_t total_region_size;
ptrdiff_t writable_region_diff = 0;
void Allocate(size_t size) {
total_region_size = size;
if constexpr (executable) region = Common::AllocateExecutableMemory(size);
else region = Common::AllocateMemoryPages(size);
    writable_region_diff = Common::AllocateWritableRegionAndGetDiff(region, size);
}
void Release() {
    Common::FreeWritableRegion(region, total_region_size, writable_region_diff);
    Common::FreeExecutableMemory(region, total_region_size);
}
};
''')
            state = root / 'vendor/Dolphin/Source/Core/Core/State.cpp'
            state.parent.mkdir(parents=True)
            state.write_text('if (s_on_after_load_callback)\n  s_on_after_load_callback();\n')
            (header.parent / 'MemoryUtil_iOS_LuckTXM.cpp').write_text((ROOT / 'vendor/Dolphin/Source/Core/Common/MemoryUtil_iOS_LuckTXM.cpp').read_text())
            audio_root = root / 'vendor/Dolphin/Source/Core/AudioCommon'
            audio_root.mkdir(parents=True)
            (audio_root / 'CoreAudioSoundStream.h').write_text('''#pragma once
  bool Init() override;
  AudioUnit audio_unit;
  int m_volume;
''')
            (audio_root / 'CoreAudioSoundStream.cpp').write_text('''#include <AudioUnit/AudioUnit.h>
OSStatus CoreAudioSound::callback(void* ref_con, AudioUnitRenderActionFlags*,
                                  const AudioTimeStamp*, UInt32, UInt32, AudioBufferList* io_data)
{
  auto* const sound = static_cast<CoreAudioSound*>(ref_con);
  for (UInt32 i = 0; i < io_data->mNumberBuffers; i++)
  {
    const AudioBuffer buffer = io_data->mBuffers[i];
    sound->m_mixer->Mix(static_cast<short*>(buffer.mData), buffer.mDataByteSize / 4);
  }
  return noErr;
}
bool CoreAudioSound::Init() {
  err = AudioUnitSetParameter(audio_unit, kHALOutputParam_Volume, kAudioUnitScope_Output, 0,
                              m_volume / 100., 0);
  if (err != noErr)
    ERROR_LOG_FMT(AUDIO, "error setting volume");
}
void CoreAudioSound::SetVolume(int volume) {}
''')
            (root / 'ci').mkdir()
            shutil.copy2(ROOT / 'ci/phase3_dolphin.py', root / 'ci/phase3_dolphin.py')
            with patch.object(builder, 'ROOT', root):
                generated = builder.generated('dolphin', root / 'output')
                self.assertIn(capability[:-1] + ' && !TARGET_OS_SIMULATOR;',
                              (generated / 'MTLUtil.mm').read_text())
                self.assertEqual((generated / 'mbedtls-user-config.h').read_text(),
                                 '#undef MBEDTLS_SELF_TEST\n#undef MBEDTLS_CERTS_C\n')
                if shutil.which('c++'):
                    main = root / 'allocator.cpp'
                    main.write_text('#include <cstddef>\n#include "Common/CodeBlock.h"\n' + '''
int main() {
    Block<false> cached; cached.Allocate(4096);
    assert(pages == 1 && executablePages == 0 && aliases == 0);
    cached.Release(); assert(pages == 0 && executablePages == 0 && aliases == 0);
    Block<true> jit; jit.Allocate(4096);
    assert(pages == 0 && executablePages == 1 && aliases == 1);
    jit.Release(); assert(pages == 0 && executablePages == 0 && aliases == 0);
}
''')
                    executable = root / 'allocator'
                    subprocess.run(['c++', '-std=c++17', '-DIPHONEOS', '-I', str(generated / 'include'),
                                    str(main), '-o', str(executable)], check=True, timeout=30)
                    subprocess.run([str(executable)], check=True, timeout=5)
                    audio = (generated / 'CoreAudioSoundStream.cpp').read_text()
                    callback = audio[audio.index('OSStatus CoreAudioSound::callback'):audio.index('bool CoreAudioSound::Init()')]
                    volume = audio[audio.index('void CoreAudioSound::SetVolume'):audio.index('CoreAudioSound::~CoreAudioSound')]
                    main.write_text('''#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstring>
#include "IRAudioVolume.h"
using UInt32=unsigned;using OSStatus=int;using AudioUnitRenderActionFlags=unsigned;
struct AudioTimeStamp {};constexpr int noErr=0;
struct AudioBuffer { void* mData;unsigned mDataByteSize; };
struct AudioBufferList { unsigned mNumberBuffers;AudioBuffer mBuffers[1]; };
struct Mixer { void Mix(short* out,unsigned frames) {
  for(unsigned n=0;n<frames*2;++n)out[n]=n%2?-32768:32767;
} };
struct CoreAudioSound {
  std::atomic<int> m_volume{100};Mixer mixer;Mixer* m_mixer=&mixer;
  static OSStatus callback(void*,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32,AudioBufferList*);
  void SetVolume(int);
};
''' + callback + volume + '''
int main() {
  CoreAudioSound sound;short samples[4];AudioBufferList buffers{1,{{samples,sizeof samples}}};
  for(int gain : {100,50,0,-1,200}) {
    sound.SetVolume(gain);CoreAudioSound::callback(&sound,nullptr,nullptr,0,2,&buffers);
    int expected=std::clamp(gain,0,100);
    assert(samples[0]==32767*expected/100 && samples[1]==-32768*expected/100);
    assert(samples[2]==samples[0] && samples[3]==samples[1]);
  }
  sound.SetVolume(100);ir_audio_volume_set(0.25f);
  CoreAudioSound::callback(&sound,nullptr,nullptr,0,2,&buffers);
  assert(samples[0]==8191 && samples[1]==-8192);
  ir_audio_volume_set(0);
  CoreAudioSound::callback(&sound,nullptr,nullptr,0,2,&buffers);
  assert(samples[0]==0 && samples[1]==0);
}
''')
                    subprocess.run(['c++', '-std=c++17', '-I', str(ROOT / 'iridium/apps/ios/RuntimeBridge'), str(main),
                                    str(ROOT / 'iridium/apps/ios/RuntimeBridge/IRAudioVolume.c'), '-o', str(executable)], check=True, timeout=30)
                    subprocess.run([str(executable)], check=True, timeout=5)
                source.write_text('upstream changed\n')
                with self.assertRaises(ValueError): builder.generated('dolphin', root / 'output')
