// Private integration adapter, 2026-09-08. Reused Madeira code is GPL-3.0-or-later.
import Foundation
import UIKit
import MadeiraNative

enum MadeiraRuntimeAdapter {
    static let enabled: Bool = {
        // Madeira is the normal runtime. A test launch can explicitly select legacy.
        let selection = ProcessInfo.processInfo.environment["IRIDIUM_RUNTIME"]
        if let test = ProcessInfo.processInfo.environment["IRIDIUM_MADEIRA_TEST"] {
            UserDefaults.standard.set(test, forKey: "IridiumMadeiraTest")
        }
        return selection != "legacy"
    }()
    private(set) static var started = false
    static var resolution = MadeiraResolution.selected
    private static var launchID = UUID()
    private static var wineStarted = false
    private static var combatProfile: MadeiraCombatProfile?

    static func start(executable: String, gameRoot: String, gameID: UUID, report: @escaping (String) -> Void, fail: @escaping (String) -> Void) {
        guard !started else { report("Restart Iridium before another Madeira session."); return }
        started = true
        let token = UUID()
        launchID = token
        resolution = .selected
        #if BUILTIN_STIKJIT
        var useBuiltinJIT = BuiltinJIT.selected && !StikJITHelper.persistentScriptRequested
        #endif
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let prefix = docs.appendingPathComponent("MadeiraTestPrefixes/\(gameID.uuidString)")
        do { try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true) }
        catch { report("Cannot create test prefix: \(error.localizedDescription)"); return }
        if let trace = ProcessInfo.processInfo.environment["IRIDIUM_MEDIA_TRACE"] {
            UserDefaults.standard.set(trace == "1", forKey: "IridiumMediaTrace")
        }
        setenv("IRIDIUM_MEDIA_TRACE", UserDefaults.standard.bool(forKey: "IridiumMediaTrace") ? "1" : "0", 1)
        if let profile = ProcessInfo.processInfo.environment["IRIDIUM_HOLLOW_KNIGHT_DIAGNOSTICS"] {
            UserDefaults.standard.set(profile == "1", forKey: "IridiumHollowKnightDiagnostics")
        }
        if UserDefaults.standard.bool(forKey: "IridiumHollowKnightDiagnostics"),
           URL(fileURLWithPath: executable).lastPathComponent.lowercased() == "hollow_knight.exe" {
            do { combatProfile = try MadeiraCombatProfile(prefix: prefix) }
            catch { report("Combat log could not start: \(error.localizedDescription)") }
        }
        let cube = UserDefaults.standard.string(forKey: "IridiumMadeiraTest") == "cube"
        setenv("MADEIRA_EXE", cube ? "cube-x64.exe" : executable, 1)
        setenv("MADEIRA_USE_ARM64EC", "1", 1)
        setenv("MADEIRA_SCREEN_W", String(resolution.rawValue), 1)
        setenv("MADEIRA_SCREEN_H", String(resolution.height), 1)
        unsetenv("MADEIRA_ARGS")
        jit_install_trap_handler()
        _ = LogStore.shared
        RuntimeLogCapture.writeLine("[Launch] Waiting for JIT permission.")
        let boot = {
            guard launchID == token else { return }
            // Keep the request only across the JIT handoff, never across a game crash.
            UserDefaults.standard.removeObject(forKey: "IridiumPendingMadeiraLaunchTitle")
            RuntimeLogCapture.writeLine("[Launch] JIT handoff complete. Automatic resume request cleared.")
            DispatchQueue.global(qos: .userInitiated).async {
                if !cube {
                    do {
                        RuntimeLogCapture.writeLine("[Launch] Preparing the isolated game environment.")
                        madeira_seed_prefix_if_needed(prefix.path)
                        try MadeiraMediaInstall.install(prefix: prefix)
                        let path = try MadeiraGamePreparation.prepare(executable: URL(fileURLWithPath: executable),
                            gameRoot: URL(fileURLWithPath: gameRoot), prefix: prefix)
                        try MadeiraControllerInstall.install(prefix: prefix, windowsExecutable: path)
                        RuntimeLogCapture.writeLine("[Launch] Game files and controller bridge are ready.")
                        DispatchQueue.main.async { MadeiraController.start(prefix: prefix) }
                        setenv("WINEDLLOVERRIDES", "xinput1_1,xinput1_2,xinput1_3,xinput1_4,xinput9_1_0=n,b;windows.gaming.input=", 1)
                        setenv("MADEIRA_EXE", path, 1)
                        if UserDefaults.standard.string(forKey: "IridiumMadeiraTest") == "media" {
                            guard let probe = Bundle.main.url(forResource: "iridium-mfprobe", withExtension: "exe", subdirectory: "MediaRuntime") else { throw CocoaError(.fileNoSuchFile) }
                            try Data(contentsOf: probe).write(to: prefix.appendingPathComponent("drive_c/iridium-mfprobe.exe"), options: .atomic)
                            setenv("MADEIRA_EXE", "C:\\iridium-mfprobe.exe", 1)
                        }
                    } catch {
                        DispatchQueue.main.async { report("Cannot prepare isolated game copy: \(error.localizedDescription)") }
                        return
                    }
                }
                guard DispatchQueue.main.sync(execute: { launchID == token }) else { return }
                RuntimeLogCapture.writeLine("[Launch] Reserving memory for translated game code.")
                let requestedPoolMB = UserDefaults.standard.integer(forKey: MadeiraJITPoolPolicy.preferenceKey)
                let effectivePoolMB = MadeiraJITPoolPolicy.effectiveLimitMB(requested: requestedPoolMB)
                if effectivePoolMB != requestedPoolMB {
                    RuntimeLogCapture.writeLine(
                        "[Launch] Automatic JIT memory capped at \(effectivePoolMB) MB because debugger-backed JIT pages count toward the app memory footprint."
                    )
                }
                guard let pool = MadeiraJITPoolPolicy.withEffectiveLimit({
                    StikJITHelper.allocateAdaptivePool()
                }) else {
                    DispatchQueue.main.async { fail("Cannot allocate JIT memory. Restart Iridium, then try a smaller JIT memory limit in Runtime settings.") }
                    return
                }
                setenv("WINE_IOS_JIT_RX", String(UInt(bitPattern: pool.rx), radix: 16), 1)
                setenv("WINE_IOS_JIT_RW", String(UInt(bitPattern: pool.rw), radix: 16), 1)
                setenv("WINE_IOS_JIT_SIZE", String(pool.size, radix: 16), 1)
                RuntimeLogCapture.writeLine("[Launch] Code memory is ready. Starting the Windows runtime.")
                StikJITHelper.detachDebugger()
                #if BUILTIN_STIKJIT
                if useBuiltinJIT && !BuiltinJIT.shared.waitForDetach() {
                    DispatchQueue.main.async { report("Built-in JIT did not confirm memory preparation. Restart Iridium before retrying.") }
                    return
                }
                #endif
                guard DispatchQueue.main.sync(execute: { launchID == token }) else { return }
                guard winios_reserve_fex_memory() != 0 else {
                    DispatchQueue.main.async {
                        fail("Cannot start the runtime: this app process has too little usable address space. Restart Iridium and try again.")
                    }
                    return
                }
                DispatchQueue.main.sync { wineStarted = true }
                ws_log_quiet = 1
                guard wineserver_start(prefix.path) == 0 else {
                    DispatchQueue.main.async { report("Madeira Wine server failed to start.") }
                    return
                }
                Thread.sleep(forTimeInterval: 2)
                RuntimeLogCapture.writeLine("[Launch] Starting the game process. Waiting for display output.")
                let result = wine_process_start(prefix.path)
                DispatchQueue.main.async {
                    report(result == 0 ? "Madeira started; waiting for rendered frames." : "Madeira Wine launch failed.")
                }
            }
        }
        let startExternalJIT = {
            if jit_check_debugged() && StikJITHelper.persistentScriptRequested {
                StikJITHelper.consumePersistentScriptRequest()
                boot()
            } else {
                StikJITHelper.enableJIT { ready in
                    if ready {
                        StikJITHelper.consumePersistentScriptRequest()
                        boot()
                    } else { started = false; fail(StikJITHelper.lastFailure) }
                }
            }
        }
        #if BUILTIN_STIKJIT
        if useBuiltinJIT {
            if !BuiltinJIT.shared.start(onListening: boot, report: fail, onUnavailable: {
                useBuiltinJIT = false
                report("Opening the external JIT app.")
                startExternalJIT()
            }) { started = false }
            return
        }
        #endif
        startExternalJIT()
    }

    private static let controllerQueue = DispatchQueue(label: "iridium.madeira.keys")
    private static var controllerKeys = MadeiraKeys()

    static func releaseKeys() {
        controllerQueue.sync {
            for key in controllerKeys.releaseAll() { winios_post_key(key, 0) }
        }
    }

    static func stop() {
        launchID = UUID()
        StikJITHelper.cancel()
        #if BUILTIN_STIKJIT
        BuiltinJIT.shared.cancel()
        #endif
        combatProfile?.stop()
        combatProfile = nil
        guard wineStarted else { started = false; return }
        releaseKeys()
        // Madeira cannot safely reinitialize all process-global Wine/FEX state yet.
        // Keep this process single-session; preserve the test prefix on shutdown.
        winios_post_key(0x12, 1)
        winios_post_key(0x73, 1)
        winios_post_key(0x73, 0)
        winios_post_key(0x12, 0)
    }

    static func input(type: String, phase: String, x: CGFloat?, y: CGFloat?, value: Double, name: String) {
        if type == "touch", let x, let y {
            let px = Int32(min(max(x, 0), 1) * CGFloat(resolution.rawValue - 1))
            let py = Int32(min(max(y, 0), 1) * CGFloat(resolution.height - 1))
            switch phase {
            case "began": winios_post_touch_down(px, py)
            case "ended", "cancelled": winios_post_touch_up(px, py)
            default: winios_post_touch_move(px, py)
            }
        } else if type == "keyboard" {
            controllerQueue.sync {
                for (key, down) in controllerKeys.update(name: name, value: phase == "up" || phase == "ended" || phase == "cancelled" ? 0 : value) {
                    winios_post_key(key, down ? 1 : 0)
                }
            }
        }
    }
}
