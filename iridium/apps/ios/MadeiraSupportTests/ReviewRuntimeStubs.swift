import Foundation
let scenario = CommandLine.arguments.dropFirst().first ?? "success"
final class NativeState: @unchecked Sendable {
    static let shared = NativeState()
    private let lock = NSLock()
    private var wine = Int32(0), server = Int32(0), code = Int32(0)
    private var begins = 0
    var recorded: [(Int32,Int32)] = []
    func read(_ field: Int) -> Int32 { lock.lock(); defer { lock.unlock() }; return field == 0 ? wine : field == 1 ? server : code }
    func write(_ field: Int, _ value: Int32) { lock.lock(); defer { lock.unlock() }; if field == 0 { wine=value } else if field == 1 { server=value } else { code=value } }
    func start() { lock.lock(); begins += 1; wine=1; lock.unlock() }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return begins }
    func event(_ key: Int32, _ down: Int32) {
        lock.lock(); recorded.append((key,down))
        if key == 0x73 && down == 0 && scenario != "close-timeout" { wine=0; server=0 }
        lock.unlock()
    }
}
struct MadeiraResolution { var rawValue = 960; var height = 540; static let selected = Self() }
final class MadeiraCombatProfile { init(prefix: URL) throws {}; func stop() {} }
enum RuntimeLogCapture { static func writeLine(_ s: String) {} }
final class LogStore { static let shared = LogStore() }
enum MadeiraGamePreparation {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iridium-adapter-"+UUID().uuidString)
    static func prefix(for id: UUID) -> URL { directory }
    static func prepare(executable: URL, gameRoot: URL, prefix: URL) throws -> String {
        if scenario == "prepare-failure" { throw CocoaError(.fileWriteOutOfSpace) }
        return "C:\\IridiumGame\\game.exe"
    }
}
enum MadeiraMediaInstall { static func install(prefix: URL) throws {} }
@MainActor enum MadeiraController { static var acceptingInput = true; static var active = false; static func start(prefix: URL) { active=true }; static func stop() { active=false } }
enum MadeiraControllerInstall { static func install(prefix: URL, windowsExecutable: String) throws {} }
@MainActor enum MadeiraHardwareInput { static var acceptingInput = true; static func stop() {} }
struct MadeiraKeys { mutating func releaseAll()->[Int32] { [] }; mutating func update(name:String,value:Double)->[(Int32,Bool)] { [] } }
enum MadeiraJITPoolPolicy { static let preferenceKey="AdapterTestPool"; static func effectiveLimitMB(requested:Int)->Int { 64 }; static func withEffectiveLimit<T>(_ f:()->T)->T { f() } }
enum StikJITHelper {
    enum Route { case automatic }
    struct Pool { let rx: UnsafeMutableRawPointer; let rw: UnsafeMutableRawPointer; let size: Int }
    static var persistentScriptRequested=false
    static let route=Route.automatic
    static let lastFailure="JIT failure"
    static func consumePersistentScriptRequest() {}
    static func enableJIT(_ done:@escaping(Bool)->Void) { done(scenario != "jit-failure"); if scenario == "duplicate-jit" { done(true) } }
    static func allocateAdaptivePool()->Pool? {
        scenario == "pool-failure" ? nil : Pool(rx: UnsafeMutableRawPointer(bitPattern:65536)!, rw: UnsafeMutableRawPointer(bitPattern:131072)!, size:65536)
    }
    static func detachDebugger() {}
    static func cancel() {}
}
enum MadeiraLiveContainer3JIT { static let lastFailure="missing"; static func enableJIT(_ done:@escaping(Bool)->Void) { done(false) }; static func cancel() {} }
final class BuiltinJIT {
    static let shared=BuiltinJIT()
    static var selected:Bool { scenario.hasPrefix("builtin") }
    func start(onListening: @escaping()->Void, report: @escaping(String)->Void, onUnavailable:@escaping()->Void)->Bool {
        if scenario == "builtin-start-failure" { report("Builtin start failed"); return false }
        onListening(); return true
    }
    func waitForDetach()->Bool { scenario != "builtin-detach-failure" }
    func cancel() {}
}
func jit_check_debugged()->Bool { false }
func jit_install_trap_handler() {}
func madeira_seed_prefix_if_needed(_ path:String) {}
func iridium_reserve_fex_memory()->Int32 { scenario == "arena-failure" ? 0 : 1 }
var ws_log_quiet:Int32=0
func wineserver_start(_ path:String)->Int32 {
    if scenario == "server-failure" { return -1 }
    NativeState.shared.write(1, scenario == "server-died" ? 0 : 1); return 0
}
func wineserver_stop() { NativeState.shared.write(1,0) }
func wineserver_is_running()->Int32 { NativeState.shared.read(1) }
func wine_process_start(_ path:String)->Int32 {
    if scenario == "wine-failure" { return -1 }
    NativeState.shared.start(); return 0
}
func wine_process_is_running()->Int32 { NativeState.shared.read(0) }
func wine_process_exit_code()->Int32 { NativeState.shared.read(2) }
func winios_post_key(_ key:Int32,_ down:Int32) { NativeState.shared.event(key,down) }
func winios_post_touch_down(_ x:Int32,_ y:Int32) {}
func winios_post_touch_up(_ x:Int32,_ y:Int32) {}
func winios_post_touch_move(_ x:Int32,_ y:Int32) {}
