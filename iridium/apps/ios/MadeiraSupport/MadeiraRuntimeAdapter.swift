// Private integration adapter, 2026-09-08. Reused Madeira code is GPL-3.0-or-later.
import Foundation
import UIKit
import MadeiraNative

enum MadeiraRuntimeAdapter {
    static let enabled: Bool = {
        let selection = ProcessInfo.processInfo.environment["IRIDIUM_RUNTIME"]
        if let test = ProcessInfo.processInfo.environment["IRIDIUM_MADEIRA_TEST"] {
            UserDefaults.standard.set(test, forKey: "IridiumMadeiraTest")
        }
        return selection != "legacy"
    }()
    private(set) static var started = false
    static var resolution = MadeiraResolution.selected
    private static var launchID = UUID()
    private static var bootInProgress = false
    private static var bootWasRequested = false
    private static var launchCancelled = false
    private static var failureReported = false
    private static var combatProfile: MadeiraCombatProfile?
    private static var monitorTask: Task<Void, Never>?
    private static var closeTask: Task<Void, Never>?

    // Lifecycle entry points are called on the main queue. Native boot stays on a worker.
    @MainActor
    static func start(executable: String, gameRoot: String, gameID: UUID,
                      arguments: [String] = [],
                      report: @escaping (String) -> Void,
                      fail: @escaping (String) -> Void,
                      exited: @escaping () -> Void = {}) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { fail("Restart Iridium before another Madeira session."); return }
        let encodedArguments: String
        do { encodedArguments = try MadeiraLaunchArguments.encode(arguments) }
        catch { fail("Invalid launch arguments: \(error.localizedDescription)"); return }
        let prefix = MadeiraGamePreparation.prefix(for: gameID)
        do { try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true) }
        catch { fail("Cannot create the game environment: \(error.localizedDescription)"); return }
        // Once native/JIT state is touched this process remains single-session,
        // including failures and cancellation. Never race a canceled worker with a retry.
        started = true
        let token = UUID()
        launchID = token
        resolution = .selected
        #if BUILTIN_STIKJIT
        var useBuiltinJIT = BuiltinJIT.selected && !StikJITHelper.persistentScriptRequested
        #endif
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
        setenv("IRIDIUM_MADEIRA_ARGS_JSON", cube ? "[]" : encodedArguments, 1)
        jit_install_trap_handler()
        _ = LogStore.shared
        RuntimeLogCapture.writeLine("[Launch] Waiting for JIT permission.")

        let failure: (String) -> Void = { message in
            DispatchQueue.main.async {
                guard launchID == token, !failureReported else { return }
                failureReported = true
                monitorTask?.cancel()
                MadeiraController.stop()
                MadeiraHardwareInput.acceptingInput = false
                combatProfile?.stop()
                combatProfile = nil
                RuntimeLogCapture.writeLine("[Launch] \(message)")
                fail(message)
            }
        }
        let boot = {
            guard launchID == token, !bootWasRequested, !launchCancelled, !failureReported else { return }
            bootWasRequested = true
            bootInProgress = true
            UserDefaults.standard.removeObject(forKey: "IridiumPendingMadeiraLaunchTitle")
            RuntimeLogCapture.writeLine("[Launch] JIT handoff complete. Automatic resume request cleared.")
            #if BUILTIN_STIKJIT
            let usingBuiltinJIT = useBuiltinJIT
            #endif
            DispatchQueue.global(qos: .userInitiated).async {
                defer { DispatchQueue.main.async { bootInProgress = false } }
                func current() -> Bool { DispatchQueue.main.sync { launchID == token && !launchCancelled && !failureReported } }
                guard current() else { return }
                if !cube {
                    do {
                        RuntimeLogCapture.writeLine("[Launch] Preparing the isolated game environment.")
                        madeira_seed_prefix_if_needed(prefix.path)
                        try MadeiraMediaInstall.install(prefix: prefix)
                        let path = try MadeiraGamePreparation.prepare(
                            executable: URL(fileURLWithPath: executable),
                            gameRoot: URL(fileURLWithPath: gameRoot), prefix: prefix)
                        guard current() else { return }
                        try MadeiraControllerInstall.install(prefix: prefix, windowsExecutable: path)
                        guard current() else { return }
                        RuntimeLogCapture.writeLine("[Launch] Game files and controller bridge are ready.")
                        DispatchQueue.main.async {
                            guard launchID == token, !launchCancelled, !failureReported else { return }
                            MadeiraController.start(prefix: prefix)
                        }
                        setenv("WINEDLLOVERRIDES", "xinput1_1,xinput1_2,xinput1_3,xinput1_4,xinput9_1_0=n,b;windows.gaming.input=", 1)
                        setenv("MADEIRA_EXE", path, 1)
                        if UserDefaults.standard.string(forKey: "IridiumMadeiraTest") == "media" {
                            guard let probe = Bundle.main.url(forResource: "iridium-mfprobe", withExtension: "exe", subdirectory: "MediaRuntime") else { throw CocoaError(.fileNoSuchFile) }
                            try Data(contentsOf: probe).write(to: prefix.appendingPathComponent("drive_c/iridium-mfprobe.exe"), options: .atomic)
                            setenv("MADEIRA_EXE", "C:\\iridium-mfprobe.exe", 1)
                            setenv("IRIDIUM_MADEIRA_ARGS_JSON", "[]", 1)
                        }
                    } catch {
                        failure("Cannot prepare the isolated game copy: \(error.localizedDescription)")
                        return
                    }
                }
                guard current() else { return }
                RuntimeLogCapture.writeLine("[Launch] Reserving memory for translated game code.")
                let requestedPoolMB = UserDefaults.standard.integer(forKey: MadeiraJITPoolPolicy.preferenceKey)
                let effectivePoolMB = MadeiraJITPoolPolicy.effectiveLimitMB(requested: requestedPoolMB)
                if effectivePoolMB != requestedPoolMB {
                    RuntimeLogCapture.writeLine("[Launch] Automatic JIT memory capped at \(effectivePoolMB) MB because debugger-backed pages count toward the app memory footprint.")
                }
                guard let pool = MadeiraJITPoolPolicy.withEffectiveLimit({ StikJITHelper.allocateAdaptivePool() }) else {
                    failure("Cannot allocate JIT memory. Restart Iridium, then try a smaller JIT memory limit.")
                    return
                }
                setenv("WINE_IOS_JIT_RX", String(UInt(bitPattern: pool.rx), radix: 16), 1)
                setenv("WINE_IOS_JIT_RW", String(UInt(bitPattern: pool.rw), radix: 16), 1)
                setenv("WINE_IOS_JIT_SIZE", String(pool.size, radix: 16), 1)
                // Complete detach even if Close was requested during allocation.
                StikJITHelper.detachDebugger()
                #if BUILTIN_STIKJIT
                if usingBuiltinJIT && !BuiltinJIT.shared.waitForDetach() {
                    failure("Built-in JIT did not confirm memory preparation. Restart Iridium before retrying.")
                    return
                }
                #endif
                guard current() else { return }
                guard winios_reserve_fex_memory() != 0 else {
                    failure("Cannot start the runtime: too little usable address space. Restart Iridium and try again.")
                    return
                }
                guard current() else { return }
                ws_log_quiet = 1
                guard wineserver_start(prefix.path) == 0 else {
                    failure("Madeira Wine server failed to start. Restart Iridium before retrying.")
                    return
                }
                Thread.sleep(forTimeInterval: 2)
                guard current() else { wineserver_stop(); return }
                guard wineserver_is_running() != 0 else {
                    failure("Madeira Wine server stopped during startup. Restart Iridium before retrying.")
                    return
                }
                RuntimeLogCapture.writeLine("[Launch] Starting the game process. Waiting for display output.")
                let result = wine_process_start(prefix.path)
                guard result == 0 else {
                    failure("Madeira Wine launch failed. Restart Iridium before retrying.")
                    wineserver_stop() // worker only; never join a native thread on the UI queue
                    return
                }
                DispatchQueue.main.async {
                    guard launchID == token else {
                        requestGuestClose()
                        return
                    }
                    if launchCancelled { requestGuestClose() }
                    else if !failureReported { report("Madeira started; waiting for rendered frames.") }
                    monitorTask?.cancel()
                    monitorTask = Task { @MainActor in
                        while wine_process_is_running() != 0 {
                            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                            guard launchID == token else { return }
                        }
                        guard !Task.isCancelled, launchID == token else { return }
                        MadeiraController.stop()
                        MadeiraHardwareInput.acceptingInput = false
                        combatProfile?.stop()
                        combatProfile = nil
                        let code = wine_process_exit_code()
                        if code != 0 {
                            failure("The game exited with code \(code). Restart Iridium before retrying.")
                            return
                        }
                        let deadline = ProcessInfo.processInfo.systemUptime + 8
                        while wineserver_is_running() != 0 {
                            guard ProcessInfo.processInfo.systemUptime < deadline else {
                                failure("The game exited but runtime shutdown is unconfirmed. Restart Iridium.")
                                return
                            }
                            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                            guard launchID == token else { return }
                        }
                        exited()
                    }
                }
            }
        }
        let finishExternalJIT: (Bool, String) -> Void = { ready, message in
            guard launchID == token, !launchCancelled, !failureReported else { return }
            if ready { StikJITHelper.consumePersistentScriptRequest(); boot() }
            else { failure(message) }
        }
        let startExternalJIT = {
            guard launchID == token, !launchCancelled, !failureReported else { return }
            if jit_check_debugged() && StikJITHelper.persistentScriptRequested {
                StikJITHelper.consumePersistentScriptRequest()
                boot()
            } else if StikJITHelper.route == .automatic {
                MadeiraAutomaticExternalJIT.enableJIT { ready in
                    finishExternalJIT(
                        ready,
                        ready ? "" : MadeiraAutomaticExternalJIT.lastFailure
                    )
                }
            } else {
                StikJITHelper.enableJIT { ready in
                    guard launchID == token, !launchCancelled, !failureReported else { return }
                    finishExternalJIT(ready, ready ? "" : StikJITHelper.lastFailure)
                }
            }
        }
        #if BUILTIN_STIKJIT
        if useBuiltinJIT {
            _ = BuiltinJIT.shared.start(onListening: boot, report: failure, onUnavailable: {
                useBuiltinJIT = false
                report("Opening the external JIT app.")
                startExternalJIT()
            })
            return
        }
        #endif
        startExternalJIT()
    }

    @MainActor
    private static func requestGuestClose() {
        releaseKeys()
        winios_post_key(0x12, 1)
        winios_post_key(0x73, 1)
        winios_post_key(0x73, 0)
        winios_post_key(0x12, 0)
    }

    /// A timeout is not a successful shutdown. Keep the player reachable then.
    @MainActor
    static func requestClose(completion: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard closeTask == nil else { return }
        launchCancelled = true
        MadeiraHardwareInput.acceptingInput = false
        MadeiraController.acceptingInput = false
        UserDefaults.standard.removeObject(forKey: "IridiumPendingMadeiraLaunchTitle")
        StikJITHelper.cancel()
        MadeiraLiveContainer3JIT.cancel()
        #if BUILTIN_STIKJIT
        BuiltinJIT.shared.cancel()
        #endif
        if wine_process_is_running() != 0 { requestGuestClose() }
        closeTask = Task { @MainActor in
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while bootInProgress || wine_process_is_running() != 0 || wineserver_is_running() != 0 {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    closeTask = nil
                    completion(false)
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { closeTask = nil; return }
            }
            closeTask = nil
            completion(true)
        }
    }

    private static let controllerQueue = DispatchQueue(label: "iridium.madeira.keys")
    private static var controllerKeys = MadeiraKeys()
    static func releaseKeys() {
        controllerQueue.sync {
            for key in controllerKeys.releaseAll() { winios_post_key(key, 0) }
        }
    }

    @MainActor
    static func stop() {
        launchID = UUID()
        monitorTask?.cancel()
        closeTask?.cancel()
        closeTask = nil
        MadeiraAutomaticExternalJIT.cancel()
        StikJITHelper.cancel()
        MadeiraLiveContainer3JIT.cancel()
        #if BUILTIN_STIKJIT
        BuiltinJIT.shared.cancel()
        #endif
        MadeiraController.stop()
        MadeiraHardwareInput.acceptingInput = false
        MadeiraHardwareInput.stop()
        combatProfile?.stop()
        combatProfile = nil
        releaseKeys()
        // No unsafe pthread cancellation or process-global runtime reinitialization.
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
