// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import AVFoundation
import GameController

/// The C interpreter, disk I/O and audio producer have one serial owner. UIKit
/// receives immutable frames with at most one pending delivery, never raw core
/// memory. No executable memory or debugger attachment is requested here.
final class IridiumConsoleSession: ObservableObject, @unchecked Sendable {
    static let shared = IridiumConsoleSession()
    enum Phase { case idle, starting, running, paused, stopping, restartRequired }
    @Published private(set) var game: IridiumConsoleGame?
    @Published private(set) var phase = Phase.idle
    @Published private(set) var image: UIImage?
    @Published private(set) var nativePSPController: UIViewController?
    @Published private(set) var phase3Controller: UIViewController?
    @Published private(set) var phase3Ready = false
    @Published private(set) var phase3JITVerified = false
    @Published private(set) var phase3Status = "Waiting for the engine"
    private var phase3Generation: UInt64 = 0 // main-thread callback admission
    @Published private(set) var pspReady = false
    @Published private(set) var pspResolution = 2
    @Published private(set) var pspCPUMode = "Not reported"
    @Published private(set) var pspJITStatus = "Off — using IR interpreter"
    @Published private(set) var pspJITFallbackReason: String?
    @Published var pspStateSlot = 0
    @Published private(set) var pspStateStatus: String?
    @Published private(set) var dolphinSettings = IridiumDolphinSettings()
    @Published private(set) var dolphinMaintenance = false
    @Published private(set) var dolphinSystemStatus: String?
    private var dolphinSystemFiles: (save: URL, backup: URL, staging: URL)?
    @Published private(set) var dolphinCPUMode = "Waiting for JIT"
    private var phase3PreparingJIT = false
    private var phase3JITRequested = false
    @Published private(set) var dolphinPerformance = "Waiting for speed data"
    @Published private(set) var dolphinStateStatus: String?
    @Published private(set) var dolphinStatePending = false
    @Published var dolphinStateSlot = 0
    private let dolphinMotion = IridiumDolphinMotion()
    private var dolphinMonitor: Timer?
    private var dolphinControllers = [GCController?](repeating: nil, count: 4)
    @Published var error: String?
    @Published private(set) var presented = false
    @Published private(set) var diagnostics = IridiumRuntimeProgress()
    var isActive: Bool { game != nil }

    private let queue = DispatchQueue(label: "software.iridium.console", qos: .userInteractive)
    private let lock = NSLock()
    private var digitalInput = IridiumPolledInput() // protected by lock
    private var touchAnalogSources = IridiumAnalogSources()
    private var touchAnalog: (Int16, Int16) { touchAnalogSources.value }
    private var keyboardAnalog: (Int16, Int16) = (0, 0)
    private var rightAnalog: (Int16, Int16) = (0, 0) // protected by lock
    private var consolePointer: (Int16, Int16, Bool) = (0, 0, false)
    private var suppressController = false
    private var intent = IridiumConsoleIntent() // protected by lock
    private var intentGeneration: UInt64 = 0 // protected by lock
    private enum Backend { case sameBoy, psp, advanced }
    private var backend = Backend.sameBoy // queue-owned below
    private var queueOwner: IridiumRuntimeLease?
    private var bootComplete = false
    private var stopRequested = false
    private var terminalFailure = false
    private var pendingFrame = false
    private var pendingAudio = 0
    private var audioBuffering = IridiumAudioBuffering() // runtime queue only
    private var framePacer = IridiumFramePacer() // runtime queue only
    private var audioGeneration = UUID()
    private var timer: DispatchSourceTimer?
    private var ownership = IridiumRuntimeOwnership() // main thread only
    private var lease: IridiumRuntimeLease?
    private var finalizing = false // main thread only
    private var stopWatch = UUID() // main-thread stop-attempt generation
    private var saveFolder: URL?
    private var runningGame: IridiumConsoleGame?
    private var rate = 384000.0
    private var fps = 60.0
    private var lastSave = Date.distantPast
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var oldAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private var progress = IridiumRuntimeProgress() // serial queue only
    private var progressStarted = ProcessInfo.processInfo.systemUptime
    private var lastFreshImage: Double?
    private var lastChangedImage: Double?
    private var lastProgressPublished = 0.0
    private var lastProgressLogged = 0.0
    private var lastProgressPhase = ""
    private var lastSameBoyPixels: Data?
    private var preparedJIT: IridiumPSPExecutableLaunch?
    private var pspJITVerifiedForLaunch = false
    private var jitDiagnostic: IridiumJITDiagnostic? // main-thread reference; workers retain their own owner
    private var displayedImageCount: UInt64 = 0 // protected by lock

    func validateLaunchAdmission() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !dolphinMaintenance else { throw IridiumRuntimeError.busy }
        guard TouchControlsModel.shared.iridiumSettingsContext == nil else { throw IridiumRuntimeError.busy }
        guard phase != .restartRequired, !ownership.requiresRestart else { throw IridiumRuntimeError.restartRequired }
        guard LibraryModel.shared.current == nil, !LibraryModel.shared.launching,
              wine_process_is_running() == 0, wineserver_is_running() == 0 else { throw IridiumRuntimeError.busy }
        guard LibraryModel.sessionsThisRun == 0 else { throw IridiumRuntimeError.restartRequired }
        guard ownership.lease == nil else { throw IridiumRuntimeError.busy }
    }

    func start(_ game: IridiumConsoleGame, store: IridiumConsoleStore) {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            try validateLaunchAdmission()
            let runtime = try IridiumRuntimeRegistry.resolve(platform: game.platform, preferred: game.runtimeID)
            if !game.platform.isPhase3 { _ = try runtime.executionMode(jitAvailable: false) }
            let owner = try ownership.acquire(runtime)
            lock.lock(); intent = IridiumConsoleIntent(); intentGeneration &+= 1; lock.unlock()
            releaseButtons()
            self.lease = owner; self.game = game; image = nil; error = nil; phase = .starting; presented = true
            finalizing = false
            diagnostics = IridiumRuntimeProgress()
            phase3Ready = false; phase3JITVerified = false; phase3Status = "Waiting for the engine"; phase3Generation &+= 1
            phase3JITRequested = false
            dolphinCPUMode = "Waiting for JIT"
            dolphinPerformance = "Waiting for speed data"
            pspReady = false; pspStateStatus = nil; pspCPUMode = "Not reported"
            pspJITStatus = "Off — using IR interpreter"
            pspJITFallbackReason = nil; pspJITVerifiedForLaunch = false
            jitDiagnostic = nil
            lock.lock(); displayedImageCount = 0; lock.unlock()
            LibraryController.shared.configure(enabled: true, ownsInput: false)
            queue.async { [self] in
                queueOwner = owner; bootComplete = false; stopRequested = false; terminalFailure = false
                backend = game.platform.isPhase3 ? .advanced : runtime.id == "ppsspp" ? .psp : .sameBoy
                audioBuffering = IridiumAudioBuffering()
                progress = IridiumRuntimeProgress(); progressStarted = ProcessInfo.processInfo.systemUptime
                lastFreshImage = nil; lastChangedImage = nil
                lastProgressPublished = 0; lastProgressLogged = 0; lastProgressPhase = ""; lastSameBoyPixels = nil
                RuntimeDiagnosticLogFiles.writeConsoleLine("[Console] launch runtime=\(runtime.id) platform=\(game.platform.rawValue)")
                do {
                    let url = try store.validateROM(game)
                    let folder = try store.saveDirectory(game)
                    guard requested != .stop else { complete(owner); return }
                    switch backend {
                    case .sameBoy:
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        guard let rom = try handle.read(upToCount: 8 * 1024 * 1024 + 1),
                              rom.count >= 0x150, rom.count <= 8 * 1024 * 1024,
                              try handle.seekToEnd() == UInt64(rom.count) else { throw IridiumRuntimeError.invalidGame }
                        let opened = rom.withUnsafeBytes { bytes in
                            folder.path.withCString { ir_core_open(bytes.baseAddress, bytes.count, $0) }
                        }
                        guard opened else { throw IridiumRuntimeError.invalidGame }
                        saveFolder = folder; runningGame = game
                        try restoreSaves()
                        var first = IRCoreFrame()
                        guard ir_core_step(0, &first) else { throw IridiumRuntimeError.invalidGame }
                        fps = first.frames_per_second; rate = first.samples_per_second
                        bootComplete = true; lastSave = Date()
                        try activate(owner)
                        recordSameBoyProgress(first, owner: owner)
                        if requested == .play { deliver(first, owner: owner) }
                    case .psp:
                        DispatchQueue.main.async {
                            guard self.lease == owner else { return }
                            guard self.requested != .stop else {
                                self.queue.async { self.complete(owner) }; return
                            }
                            self.prepareNativePSP(game: url, memoryStick: folder, owner: owner)
                        }
                    case .advanced:
                        let system = try store.systemDirectory(game)
                        DispatchQueue.main.async {
                            guard self.lease == owner else { return }
                            guard self.requested != .stop else { self.queue.async { self.complete(owner) }; return }
                            self.openPhase3(game: game, url: url, folder: folder, system: system, owner: owner)
                        }
                    }
                } catch {
                    fail(error.localizedDescription, owner: owner)
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func openPhase3(game: IridiumConsoleGame, url: URL, folder: URL, system: URL, owner: IridiumRuntimeLease, phase3JITReady: Bool? = nil) {
        let ownsSharedJIT = game.runtimeID == "dolphin" || game.runtimeID == "azahar"
        if ownsSharedJIT, phase3JITReady == nil {
            if game.runtimeID == "dolphin" { dolphinSettings = .load(game.id) }
            let name = game.runtimeID == "azahar" ? "Azahar" : "Dolphin"
            phase3PreparingJIT = true; phase3JITRequested = true; phase3Status = "Preparing \(name) JIT"
            JITCoordinator.shared.enable(requiresAttachedDebugger: true) { result in
                self.phase3PreparingJIT = false
                guard self.lease == owner else { return }
                if self.requested == .stop { self.queue.async { self.complete(owner) }; return }
                switch result {
                case .success:
                    self.openPhase3(game: game, url: url, folder: folder, system: system, owner: owner, phase3JITReady: true)
                case .failure(let failure):
                    let message = "\(name) needs the shared JIT system. Check JIT Settings and try again. " + failure.localizedDescription
                    self.queue.async { self.fail(message, owner: owner) }
                }
            }
            return
        }
        if ownsSharedJIT, phase3JITReady != true {
            queue.async { self.fail(IridiumRuntimeError.jitRequired.localizedDescription, owner: owner) }; return
        }
        guard let frameworks = Bundle.main.privateFrameworksURL else {
            queue.async { self.fail(IridiumRuntimeError.unavailable.localizedDescription, owner: owner) }; return
        }
        // These are upstream allocators. Helper readiness only authorizes the
        // engine's own probe; it never substitutes for successful execution.
        let controller = game.runtimeID.withCString { runtime in
            frameworks.path.withCString { binaries in
                url.path.withCString { content in
                    folder.path.withCString { saves in
                        system.path.withCString { assets in
                            ir_phase3_open(runtime, binaries, content, saves, assets, StikJITHelper.ready,
                                phase3Generation, { generation, kind, message in
                                    let text = message.map { String(cString: $0) } ?? ""
                                    DispatchQueue.main.async {
                                        IridiumConsoleSession.shared.phase3Event(generation, kind: kind, message: text)
                                    }
                                }, { output in
                                    guard let output else { return }
                                    let session = IridiumConsoleSession.shared
                                    let sample = session.input()
                                    output.pointee.buttons = sample.digital.buttons
                                    output.pointee.left_x = sample.x; output.pointee.left_y = sample.y
                                    session.fillPhase3Input(output)
                                    session.acknowledge(sample, polled: true)
                                })
                        }
                    }
                }
            }
        }
        guard let controller else {
            error = "The bundled \(game.runtimeID) player could not start. Its saved files have been retained."
            queue.async { self.terminalFailure = true; self.complete(owner) }; return
        }
        if game.runtimeID == "azahar", !ir_phase3_azahar_configure_jit(jit26_prepare_region) {
            ir_phase3_stop(); error = "The 3DS core could not configure shared JIT."; return
        }
        if game.runtimeID == "dolphin" {
            dolphinSettings = .load(game.id); dolphinStateStatus = nil; dolphinStatePending = false
            lock.lock(); dolphinControllers = [GCController?](repeating: nil, count: 4); lock.unlock()
            var options = dolphinSettings.native; options.use_jit = phase3JITReady == true
            guard ir_phase3_dolphin_configure(options, { player, output in
                guard let output else { return }
                IridiumConsoleSession.shared.fillDolphinInput(player, output)
            }, jit26_prepare_region) else {
                ir_phase3_stop(); error = "This Dolphin component does not support the app interface."; return
            }
            dolphinMotion.start(enabled: dolphinSettings.motion)
            monitorDolphin()
        }
        phase3Controller = Unmanaged<UIViewController>.fromOpaque(controller).takeRetainedValue()
        diagnostics.phase = "upstream engine starting"
        if requested == .pause { ir_phase3_pause(true) }
    }

    private func phase3Event(_ generation: UInt64, kind: UInt32, message: String) {
        guard generation == phase3Generation, let owner = lease, game?.platform.isPhase3 == true else { return }
        RuntimeDiagnosticLogFiles.writeConsoleLine("[Console engine] " + message)
        phase3Status = message
        switch kind {
        case 1:
            phase3Ready = true; diagnostics.phase = "engine produced video"
            if phase == .starting && requested == .play { phase = .running }
        case 2:
            dolphinMonitor?.invalidate(); dolphinMonitor = nil; dolphinMotion.stop()
            phase3Controller = nil
            queue.async { self.complete(owner) }
        case 3:
            error = message
            queue.async { self.terminalFailure = true }
            if phase3Controller != nil { stop() }
        case 4: pause()
        case 5: phase3JITVerified = true
        case 6:
            dolphinStatePending = false; dolphinStateStatus = message; resume()
        case 7:
            dolphinStatePending = false; dolphinStateStatus = message; error = message
        default: break
        }
    }

    @MainActor private func prepareNativePSP(game: URL, memoryStick: URL, owner: IridiumRuntimeLease) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.game?.pspJITEnabled == true else {
            prepareNativePSP(game: game, memoryStick: memoryStick, owner: owner, diagnostic: nil); return
        }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            pspJITFallbackReason = "JIT diagnostics could not be opened."
            pspJITStatus = "Using IR interpreter. JIT diagnostics could not be opened."
            openNativePSP(game: game, memoryStick: memoryStick, owner: owner, jitVerified: false); return
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let identity = "source=\(info["IridiumRootRevision"] as? String ?? "Unknown") build=\(info["CFBundleVersion"] as? String ?? "Unknown")"
        IridiumJITDiagnostic.create(directory: documents, identity: identity) { [weak self] diagnostic in
            guard let self, self.lease == owner, self.requested != .stop else { return }
            guard let diagnostic else {
                self.pspJITFallbackReason = "JIT diagnostics could not be opened."
                self.pspJITStatus = "Using IR interpreter. JIT diagnostics could not be opened."
                self.openNativePSP(game: game, memoryStick: memoryStick, owner: owner, jitVerified: false)
                return
            }
            self.jitDiagnostic = diagnostic
            self.prepareNativePSP(game: game, memoryStick: memoryStick, owner: owner, diagnostic: diagnostic)
        }
    }

    @MainActor private func prepareNativePSP(game: URL, memoryStick: URL, owner: IridiumRuntimeLease,
                                           diagnostic: IridiumJITDiagnostic?) {
        pspJITVerifiedForLaunch = false
        guard self.game?.pspJITEnabled == true else {
            pspJITFallbackReason = "JIT is turned off for this game."
            pspJITStatus = "Off — using IR interpreter"
            openNativePSP(game: game, memoryStick: memoryStick, owner: owner, jitVerified: false); return
        }
        guard let diagnostic,
              let component = Bundle.main.privateFrameworksURL?.appendingPathComponent("libIridiumPPSSPPNative.dylib") else {
            pspJITFallbackReason = "JIT diagnostics are unavailable."
            pspJITStatus = "Using IR interpreter. JIT diagnostics are unavailable."
            openNativePSP(game: game, memoryStick: memoryStick, owner: owner, jitVerified: false); return
        }
        let launch = IridiumPSPExecutableLaunch(diagnostic: diagnostic, component: component.path)
        preparedJIT = launch
        launch.changed = { [weak self] message in
            guard let self, self.lease == owner else { return }
            self.pspJITStatus = message
            RuntimeDiagnosticLogFiles.writeConsoleLine("[PSP JIT] " + message)
        }
        launch.completed = { [weak self] outcome in
            guard let self, self.lease == owner else { return }
            switch outcome {
            case .restart(let message):
                self.phase = .restartRequired; self.error = message
                self.pspJITStatus = message; self.diagnostics.phase = "JIT restart required"
                return // Retain admission/context/journal around any uncertain worker.
            case .ready:
                self.pspJITVerifiedForLaunch = true
                self.pspJITStatus = "PPSSPP JIT executed 42 and 7 after owned teardown and network restoration."
            case .fallback(let reason):
                self.pspJITFallbackReason = reason
                self.pspJITStatus = "Using IR interpreter. " + reason
            }
            if self.requested == .stop {
                self.queue.async { self.complete(owner) }; return
            }
            guard self.phase != .restartRequired else { return }
            diagnostic.mark(IR_JIT_COMPLETION, value: self.pspJITVerifiedForLaunch ? 1 : 0)
            self.openNativePSP(game: game, memoryStick: memoryStick, owner: owner, jitVerified: self.pspJITVerifiedForLaunch)
        }
        launch.start()
    }

    private func openNativePSP(game: URL, memoryStick: URL, owner: IridiumRuntimeLease, jitVerified: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let frameworks = Bundle.main.privateFrameworksURL,
              let resources = Bundle.main.resourceURL else {
            error = IridiumRuntimeError.unavailable.localizedDescription
            queue.async { self.terminalFailure = true; self.complete(owner) }; return
        }
        let component = frameworks.appendingPathComponent("libIridiumPPSSPPNative.dylib")
        let assets = resources.appendingPathComponent("PSP/PPSSPP", isDirectory: true)
        let controller = component.path.withCString { binary in
            game.path.withCString { gamePath in
                memoryStick.path.withCString { savePath in
                    assets.path.withCString { assetPath in
                        ir_psp_native_open(binary, gamePath, savePath, assetPath, jitVerified, { kind, message in
                            let text = message.map { String(cString: $0) } ?? ""
                            if kind == 0 {
                                RuntimeDiagnosticLogFiles.writeConsoleLine("[PSP native] \(text)")
                            } else {
                                IridiumConsoleSession.shared.nativePSPEvent(kind, text: text)
                            }
                        }, { buttons, x, y in
                            let session = IridiumConsoleSession.shared
                            let sample = session.input()
                            buttons?.pointee = sample.digital.buttons
                            x?.pointee = sample.x
                            y?.pointee = sample.y
                            session.acknowledge(sample, polled: true)
                        })
                    }
                }
            }
        }
        guard let controller else {
            error = "The full native PPSSPP component could not initialize. Its saves have been retained."
            queue.async { self.terminalFailure = true; self.complete(owner) }; return
        }
        nativePSPController = Unmanaged<UIViewController>.fromOpaque(controller).takeRetainedValue()
        if requested == .pause { ir_psp_native_pause() }
        diagnostics.phase = "native graphics starting"
        RuntimeDiagnosticLogFiles.writeConsoleLine("[PSP native] release=v1.20.4 jit_verified=\(jitVerified ? "true" : "false"); renderer pending; game_progress=unknown")
        LibraryController.shared.configure(enabled: true, ownsInput: requested == .pause)
    }

    private func nativePSPEvent(_ kind: UInt32, text: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner = lease, game?.platform == .psp else { return }
        RuntimeDiagnosticLogFiles.writeConsoleLine("[PSP native] \(text)")
        switch kind {
        case 1:
            nativePSPController = nil
            queue.async { self.complete(owner) }
        case 2:
            error = text
            queue.async { self.terminalFailure = true }
            stop()
        case 3:
            diagnostics.phase = pspReady ? "native renderer initialized" : "native renderer initialized; game boot pending"
        case 4:
            pspReady = true; pspResolution = Int(ir_psp_native_resolution())
            if phase == .starting { phase = .running }
            diagnostics.phase = "native game boot complete"
        case 5, 6:
            pspStateStatus = text
            if kind == 6 { error = text }
        case 7: pause()
        case 9:
            phase = .restartRequired; error = text; diagnostics.phase = "native JIT cleanup incomplete"
        case 8:
            pspCPUMode = text
            if pspJITVerifiedForLaunch && text != "JIT" && text != "JIT using IR" {
                pspJITFallbackReason = "PPSSPP selected the interpreter after JIT verification."
                pspJITStatus = "PPSSPP selected the interpreter after launch."
            }
        default: break
        }
    }

    func setPSPResolution(_ scale: Int) {
        guard game?.platform == .psp, (1...4).contains(scale), phase == .paused,
              ir_psp_native_request(1, Int32(scale)) else { return }
        pspResolution = scale
    }

    func requestPSPState(load: Bool) {
        guard game?.platform == .psp, pspReady, phase == .paused else {
            error = "Wait for this game to finish starting before using save states."; return
        }
        guard ir_psp_native_request(load ? 3 : 2, Int32(pspStateSlot)) else {
            error = "A save-state operation is already pending. Resume the game and try again."; return
        }
        pspStateStatus = load ? "Loading state…" : "Saving state…"
        resume()
    }

    func installDolphinWAD(_ source: URL, game: IridiumConsoleGame) {
        do { try validateLaunchAdmission() } catch { dolphinSystemStatus = error.localizedDescription; return }
        guard let frameworks = Bundle.main.privateFrameworksURL else { dolphinSystemStatus = "The Dolphin component is unavailable."; return }
        dolphinMaintenance = true; dolphinSystemStatus = "Backing up Wii files…"
        let scoped = source.startAccessingSecurityScopedResource()
        queue.async {
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            var staging: URL?
            do {
                let store = IridiumConsoleLibrary.shared.store
                guard source.pathExtension.lowercased() == "wad" else { throw IridiumRuntimeError.invalidGame }
                _ = try IridiumROMInspection.inspect(source, fileExtension: "wad")
                let save = try store.saveDirectory(game)
                let backup = save.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
                    .appendingPathComponent(game.id.uuidString + "-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard backup.deletingLastPathComponent().resolvingSymlinksInPath() == backup.deletingLastPathComponent().standardizedFileURL else {
                    throw IridiumRuntimeError.unsafePath
                }
                try FileManager.default.copyItem(at: save, to: backup)
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Dolphin-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
                staging = temporary
                let wad = temporary.appendingPathComponent("content.wad")
                try FileManager.default.copyItem(at: source, to: wad)
                DispatchQueue.main.async {
                    self.dolphinSystemFiles = (save, backup, temporary)
                    self.dolphinSystemStatus = "Installing Wii content…"
                    let queued = ir_phase3_dolphin_install_wad(frameworks.path, save.path, wad.path) { success, restart, message in
                        let text = message.map { String(cString: $0) } ?? "Dolphin did not report an installation result."
                        DispatchQueue.main.async { IridiumConsoleSession.shared.finishDolphinWAD(success: success, message: text, restart: restart) }
                    }
                    if !queued { self.finishDolphinWAD(success: false, message: "The Dolphin installer could not be loaded.") }
                }
            } catch {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                let message = error.localizedDescription
                DispatchQueue.main.async { self.dolphinMaintenance = false; self.dolphinSystemStatus = message }
            }
        }
    }

    private func finishDolphinWAD(success: Bool, message: String, restart: Bool = false) {
        guard let files = dolphinSystemFiles else { return }
        dolphinSystemFiles = nil
        if restart {
            phase = .restartRequired
            dolphinMaintenance = false; dolphinSystemStatus = message
            return // The installer may still own these files. Keep both copies in place.
        }
        queue.async {
            var status = message
            do {
                if !success {
                    let failed = files.backup.appendingPathExtension("failed")
                    try FileManager.default.moveItem(at: files.save, to: failed)
                    try FileManager.default.copyItem(at: files.backup, to: files.save)
                    status += " The original files were restored."
                }
                try FileManager.default.removeItem(at: files.staging)
            } catch { status += " File recovery or temporary-file cleanup failed. The backup is kept. " + error.localizedDescription }
            let result = status
            DispatchQueue.main.async { self.dolphinMaintenance = false; self.dolphinSystemStatus = result }
        }
    }

    func setDolphin(_ update: (inout IridiumDolphinSettings) -> Void) {
        guard let game, game.runtimeID == "dolphin", phase == .paused, !dolphinStatePending else { return }
        update(&dolphinSettings); dolphinSettings.save(game.id)
        ir_phase3_dolphin_settings(dolphinSettings.native)
        dolphinMotion.stop()
    }

    func requestDolphinState(load: Bool) {
        guard game?.runtimeID == "dolphin", phase3Ready, phase == .paused, !dolphinStatePending else {
            error = "Wait for Dolphin to start and pause the game before using save states."; return
        }
        dolphinStatePending = true; dolphinStateStatus = load ? "Loading state…" : "Saving state…"
        ir_phase3_dolphin_state(load, UInt32(dolphinStateSlot))
    }

    func updateDolphinOrientation() { dolphinMotion.updateOrientation() }

    private func monitorDolphin() {
        dolphinMonitor?.invalidate()
        var previous: UInt64 = 0, stalled = 0, samples = 0
        dolphinMonitor = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.game?.runtimeID == "dolphin" else { return }
            let stats = ir_phase3_dolphin_stats()
            self.dolphinCPUMode = stats.jit ? "Native JIT" : "Waiting for JIT"
            if self.phase == .running {
                self.dolphinPerformance = String(format: "%.1f FPS · %.0f%% speed", stats.fps, stats.speed * 100)
                stalled = stats.frames == previous ? stalled + 1 : 0
                if stalled >= 3 { self.phase3Status = "No new Metal frame for \(stalled) seconds." }
                else { self.phase3Status = self.dolphinPerformance }
                samples += 1
                if samples % 10 == 0 {
                    RuntimeDiagnosticLogFiles.writeConsoleLine(String(format: "[Dolphin] fps=%.2f vps=%.2f speed=%.3f frames=%llu input_samples=%llu",
                        stats.fps, stats.vps, stats.speed, stats.frames, stats.input_samples))
                }
            }
            previous = stats.frames
        }
        if let dolphinMonitor { RunLoop.main.add(dolphinMonitor, forMode: .common) }
    }

    private func updateDolphinControllers(_ connected: [GCController]) {
        for index in dolphinControllers.indices {
            if let old = dolphinControllers[index], !connected.contains(where: { $0 === old }) {
                dolphinControllers[index] = nil
            }
        }
        for controller in connected where !dolphinControllers.contains(where: { $0 === controller }) {
            if let slot = dolphinControllers.firstIndex(where: { $0 == nil }) { dolphinControllers[slot] = controller }
        }
    }

    private func fillDolphinInput(_ player: UInt32, _ output: UnsafeMutablePointer<IRDolphinInput>) {
        let connected = GCController.controllers()
        lock.lock()
        updateDolphinControllers(connected)
        let controller = Int(player) < dolphinControllers.count ? dolphinControllers[Int(player)] : nil
        let playing = intent.request == .play
        lock.unlock()
        output.pointee = IRDolphinInput()
        output.pointee.acceleration.2 = 9.81
        guard playing else { return }
        if player == 0 {
            let sample = input(controller: controller)
            output.pointee.controls.buttons = sample.digital.buttons
            output.pointee.left_trigger = sample.digital.buttons & (1 << 12) != 0 ? 1 : 0
            output.pointee.right_trigger = sample.digital.buttons & (1 << 13) != 0 ? 1 : 0
            output.pointee.controls.left_x = sample.x; output.pointee.controls.left_y = sample.y
            withUnsafeMutablePointer(to: &output.pointee.controls) { fillPhase3Input($0, controller: controller) }
            acknowledge(sample, polled: true)
            dolphinMotion.fill(&output.pointee)
        } else if let pad = controller?.extendedGamepad {
            let bindings: [(GCControllerButtonInput?, String)] = [(pad.buttonA,"A"),(pad.buttonB,"B"),
                (pad.buttonX,"X"),(pad.buttonY,"Y"),(pad.buttonMenu,"Menu"),(pad.buttonOptions,"View"),
                (pad.leftShoulder,"LB"),(pad.rightShoulder,"RB"),(pad.dpad.up,"D↑"),(pad.dpad.down,"D↓"),
                (pad.dpad.left,"D←"),(pad.dpad.right,"D→"),(pad.leftTrigger,"LT"),(pad.rightTrigger,"RT"),
                (pad.leftThumbstickButton,"L3"),(pad.rightThumbstickButton,"R3")]
            for (button, action) in bindings where button?.isPressed == true {
                output.pointee.controls.buttons |= IridiumConsoleControlMapping.button(action, profile: .console) ?? 0
            }
            output.pointee.controls.left_x = Int16(max(-1,min(1,pad.leftThumbstick.xAxis.value)) * 32767)
            output.pointee.controls.left_y = Int16(max(-1,min(1,-pad.leftThumbstick.yAxis.value)) * 32767)
            output.pointee.controls.right_x = Int16(max(-1,min(1,pad.rightThumbstick.xAxis.value)) * 32767)
            output.pointee.controls.right_y = Int16(max(-1,min(1,-pad.rightThumbstick.yAxis.value)) * 32767)
        }
        if let pad = controller?.extendedGamepad {
            output.pointee.left_trigger = max(output.pointee.left_trigger, pad.leftTrigger.value)
            output.pointee.right_trigger = max(output.pointee.right_trigger, pad.rightTrigger.value)
        }
    }

    private var currentIntentGeneration: UInt64 {
        lock.lock(); defer { lock.unlock() }; return intentGeneration
    }

    private var requested: IridiumConsoleIntent.Request {
        lock.lock(); defer { lock.unlock() }; return intent.request
    }

    func pause() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner = lease, phase == .running || phase == .starting else { return }
        lock.lock(); intent.pause(); intentGeneration &+= 1; lock.unlock()
        phase = .paused; releaseButtons(); dolphinMotion.stop()
        diagnostics.phase = "pause requested"
        LibraryController.shared.configure(enabled: true, ownsInput: true)
        if phase3Controller != nil { ir_phase3_pause(true); return }
        if nativePSPController != nil { ir_psp_native_pause(); return }
        queue.async { [self] in
            guard queueOwner == owner, requested == .pause else { return }
            // Async PSP boot still needs the single pump to reach a safe state.
            if bootComplete { stopTimer() }
            progress.phase = bootComplete ? "paused" : "booting (pause requested)"
            publishProgress(owner, force: true)
            silenceAudio()
            do { try persistSaves() }
            catch { reportSaveError(owner) }
        }
    }

    func resume() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner = lease, phase == .paused, !dolphinStatePending else { return }
        if phase3Controller != nil, phase3JITRequested, !isDebuggerAttached() {
            guard !phase3PreparingJIT else { return }
            phase3PreparingJIT = true
            lock.lock(); let generation = intentGeneration; lock.unlock()
            MainActor.assumeIsolated {
                JITCoordinator.shared.enable(requiresAttachedDebugger: true) { [weak self] result in
                    guard let self, self.lease == owner else { return }
                    self.phase3PreparingJIT = false
                    if self.requested == .stop { ir_phase3_stop(); return }
                    self.lock.lock(); let currentGeneration = self.intentGeneration; self.lock.unlock()
                    guard self.phase == .paused, currentGeneration == generation else { return }
                    switch result {
                    case .success: self.error = nil; self.resume()
                    case .failure(let failure): self.error = failure.localizedDescription
                    }
                }
            }
            return
        }
        lock.lock(); intent.resume(); intentGeneration &+= 1; lock.unlock()
        phase = .starting
        diagnostics.phase = "resume requested"
        LibraryController.shared.configure(enabled: true, ownsInput: false)
        if phase3Controller != nil {
            if game?.runtimeID == "dolphin" { dolphinMotion.start(enabled: dolphinSettings.motion) }
            ir_phase3_pause(false); phase = phase3Ready ? .running : .starting; return
        }
        if nativePSPController != nil {
            ir_psp_native_resume(); phase = pspReady ? .running : .starting; return
        }
        queue.async { [self] in
            guard queueOwner == owner, requested == .play else { return }
            do {
                if bootComplete { try activate(owner) }
                else { startTimer(owner: owner) }
            } catch {
                self.pauseAfterAudioFailure(owner)
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner = lease, phase != .stopping, phase != .restartRequired else { return }
        preparedJIT?.cancel()
        jitDiagnostic?.mark(IR_JIT_CANCEL)
        lock.lock(); intent.stop(); intentGeneration &+= 1; lock.unlock()
        phase = .stopping; releaseButtons()
        diagnostics.phase = "stop requested"
        watchStop(owner)
        if phase3PreparingJIT { return } // Its callback stops the engine after JIT returns.
        if phase3Controller != nil { ir_phase3_stop(); return }
        if nativePSPController != nil { ir_psp_native_stop(); return }
        if let preparedJIT, !preparedJIT.finished { return } // Its owned cleanup releases this lease.
        queue.async { [self] in
            guard queueOwner == owner, requested == .stop else { return }
            beginStop(owner)
        }
    }

    private func watchStop(_ owner: IridiumRuntimeLease) {
        let attempt = UUID(); stopWatch = attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard self.lease == owner, self.stopWatch == attempt, self.phase == .stopping else { return }
            self.phase = .restartRequired
            self.diagnostics.phase = "stop timed out"
            self.error = "The runtime has not stopped. You can return to the library, but fully close and reopen Iridium before launching another game."
        }
    }

    private func beginStop(_ owner: IridiumRuntimeLease) {
        progress.phase = "stopping"; publishProgress(owner, force: true)
        silenceAudio()
        switch backend {
        case .advanced: complete(owner)
        case .sameBoy:
            stopTimer()
            do { try persistSaves() }
            catch {
                // SameBoy alone has recoverable in-memory battery/RTC data.
                lock.lock(); intent = IridiumConsoleIntent(); intent.pause(); intentGeneration &+= 1; lock.unlock()
                reportSaveError(owner); return
            }
            ir_core_close(); complete(owner)
        case .psp:
            #if IRIDIUM_PPSSPP_LIBRETRO
            if !stopRequested { ir_psp_request_stop(); stopRequested = true }
            startTimer(owner: owner) // Drain, never force unload, including failed boot.
            #else
            complete(owner)
            #endif
        }
    }

    private func fail(_ message: String, owner: IridiumRuntimeLease) {
        terminalFailure = true
        RuntimeDiagnosticLogFiles.writeConsoleLine("[Console] failure: \(message)")
        progress.phase = "failed"; publishProgress(owner, force: true)
        lock.lock(); intent.stop(); intentGeneration &+= 1; lock.unlock()
        DispatchQueue.main.async {
            guard self.lease == owner else { return }
            self.error = message; self.releaseButtons()
            if self.phase != .restartRequired { self.phase = .stopping; self.watchStop(owner) }
        }
        if backend == .psp, runningGame != nil { beginStop(owner) }
        else { if backend == .sameBoy { ir_core_close() }; complete(owner) }
    }

    private func complete(_ owner: IridiumRuntimeLease) {
        let failed = terminalFailure
        progress.phase = failed ? "failed" : "closed"; publishProgress(owner, force: true)
        stopTimer(); stopAudio(); runningGame = nil; saveFolder = nil; queueOwner = nil
        DispatchQueue.main.async {
            guard self.lease == owner, !self.finalizing else { return }
            self.finalizing = true
            if self.phase3JITRequested {
                self.phase = .stopping
                self.stopWatch = UUID() // The engine stopped; the shared helper has its own bounded wait.
                self.phase3Status = "Closing the shared JIT session"
                JITCoordinator.shared.releaseAttachedDebugger { clean in
                    guard self.lease == owner else { return }
                    if clean { self.finishComplete(owner, failed: failed) }
                    else { self.requireRestart(owner) }
                }
            } else { self.finishComplete(owner, failed: failed) }
        }
    }

    @MainActor private func finishComplete(_ owner: IridiumRuntimeLease, failed: Bool) {
        guard lease == owner else { return }
        let restart = self.game?.runtimeID == "play"
        self.ownership.release(owner, restart: restart)
        self.jitDiagnostic?.mark(IR_JIT_OWNER_RELEASE)
        self.jitDiagnostic = nil
        self.preparedJIT = nil; self.pspJITVerifiedForLaunch = false
        self.pspReady = false; self.pspCPUMode = "Not reported"; self.pspJITFallbackReason = nil
        // Async drain can dismiss the player after its error observer ran.
        // Preserve an unacknowledged launch/runtime failure at the library.
        if failed, let error = self.error { LibraryModel.shared.error = error }
        self.error = nil
        self.lease = nil; self.game = nil; self.image = nil; self.nativePSPController = nil; self.phase3Controller = nil
        self.phase = restart ? .restartRequired : .idle; self.presented = false
        LibraryModel.shared.refreshFlag()
    }

    private func requireRestart(_ owner: IridiumRuntimeLease) {
        progress.phase = "restart required"; publishProgress(owner, force: true)
        stopTimer(); stopAudio()
        DispatchQueue.main.async {
            guard self.lease == owner else { return }
            // Keep the lease and native ownership: this bridge did not close.
            self.phase = .restartRequired; self.releaseButtons()
            self.error = "The runtime cannot safely unload. Fully close and reopen Iridium before launching another game."
        }
    }

    private func activate(_ owner: IridiumRuntimeLease) throws {
        guard requested == .play else {
            if requested == .stop { beginStop(owner) } else { stopTimer(); silenceAudio() }
            return
        }
        // Engine setup can block, so it must not hold the input/intent lock.
        // Only playback is gated under that lock after setup has completed.
        if engine == nil { try startAudio() }
        else if engine?.isRunning != true { try engine?.start() }
        lock.lock()
        let play = intent.request == .play
        if play, backend != .sameBoy { player?.play() }
        lock.unlock()
        guard play else {
            if requested == .stop { beginStop(owner) } else { stopTimer(); silenceAudio() }
            return
        }
        progress.phase = "running"; publishProgress(owner, force: true)
        startTimer(owner: owner)
        DispatchQueue.main.async {
            guard self.lease == owner, self.phase == .starting, self.requested == .play else { return }
            self.phase = .running
        }
    }

    private func pauseAfterAudioFailure(_ owner: IridiumRuntimeLease) {
        lock.lock(); intent.pause(); intentGeneration &+= 1; lock.unlock()
        stopTimer(); silenceAudio()
        progress.phase = "paused"; publishProgress(owner, force: true)
        DispatchQueue.main.async {
            guard self.lease == owner, self.requested == .pause else { return }
            self.phase = .paused; self.releaseButtons()
            self.error = "Audio could not start. Try Resume again."
            LibraryController.shared.configure(enabled: true, ownsInput: true)
        }
    }

    func returnToLibraryAfterTimeout() {
        guard phase == .restartRequired else { return }
        // Keep ownership until the worker truly finishes. Never let another
        // engine race a stuck native call, even after its surface is dismissed.
        presented = false
        LibraryModel.shared.error = IridiumRuntimeError.restartRequired.localizedDescription
    }

    func setButton(_ bit: UInt16, pressed: Bool, keyboard: Bool = false, source: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !pressed || intent.request == .play else { return }
        digitalInput.setButton(bit, pressed: pressed, source: source ?? (keyboard ? "keyboard" : "touch"))
    }

    // Composite controls submit their complete physical state atomically.
    // Updating changed D-pad bits individually could invent an intermediate
    // opposite-direction chord that the input queue would correctly preserve.
    func setButtons(_ buttons: UInt16, source: String) {
        lock.lock(); defer { lock.unlock() }
        guard buttons == 0 || intent.request == .play else { return }
        digitalInput.setButtons(buttons, source: source)
    }

    func setAnalog(x: Int16, y: Int16, keyboard: Bool = false, source: String = "touch") {
        lock.lock(); defer { lock.unlock() }
        guard intent.request == .play else { return }
        if keyboard { keyboardAnalog = (x, y) } else { touchAnalogSources.set(x: x, y: y, source: source) }
    }

    func releaseButtons() {
        lock.lock()
        digitalInput.cancel()
        touchAnalogSources.clear(); keyboardAnalog = (0, 0); suppressController = true
        rightAnalog = (0, 0); consolePointer = (0, 0, false)
        lock.unlock()
    }

    func resetInput() { releaseButtons() }

    func setRightAnalog(x: Int16, y: Int16) {
        lock.lock(); defer { lock.unlock() }
        rightAnalog = intent.request == .play ? (x, y) : (0, 0)
    }
    func setConsolePointer(_ point: CGPoint?, size: CGSize) {
        lock.lock(); defer { lock.unlock() }
        if game?.platform == .wii {
            guard intent.request == .play, let point, size.width > 0, size.height > 0,
                  point.x.isFinite, point.y.isFinite else { consolePointer = (0, 0, false); return }
            consolePointer = (Int16(max(-1, min(1, point.x / size.width * 2 - 1)) * 32767),
                              Int16(max(-1, min(1, point.y / size.height * 2 - 1)) * 32767), true)
            return
        }
        guard intent.request == .play, let point,
              let projected = Iridium3DSTouchProjection.project(point: point, size: size) else {
            consolePointer = (0, 0, false); return
        }
        consolePointer = (projected.0, projected.1, true)
    }
    private func fillPhase3Input(_ value: UnsafeMutablePointer<IRPhase3Input>, controller: GCController? = GCController.current ?? GCController.controllers().first) {
        let pad = controller?.extendedGamepad
        lock.lock(); defer { lock.unlock() }
        guard intent.request == .play else { value.pointee = IRPhase3Input(); return }
        var right = rightAnalog
        if !suppressController, let pad {
            if right == (0, 0) {
                right = (Int16(max(-1, min(1, pad.rightThumbstick.xAxis.value)) * 32767),
                         Int16(max(-1, min(1, pad.rightThumbstick.yAxis.value)) * 32767))
            }
            if pad.leftTrigger.isPressed { value.pointee.buttons |= 1 << 12 }
            if pad.rightTrigger.isPressed { value.pointee.buttons |= 1 << 13 }
            if pad.leftThumbstickButton?.isPressed == true { value.pointee.buttons |= 1 << 14 }
            if pad.rightThumbstickButton?.isPressed == true { value.pointee.buttons |= 1 << 15 }
        }
        value.pointee.right_x = right.0; value.pointee.right_y = Int16(clamping: -Int(right.1))
        value.pointee.pointer_x = consolePointer.0; value.pointee.pointer_y = consolePointer.1
        value.pointee.pointer_down = consolePointer.2
    }

    private struct InputSample {
        let digital: IridiumPolledInput.Snapshot
        let x: Int16
        let y: Int16
    }

    private func acknowledge(_ sample: InputSample, polled: Bool) {
        guard polled else { return }
        lock.lock(); defer { lock.unlock() }
        digitalInput.acknowledge(sample.digital)
    }

    private func input(controller: GCController? = GCController.current ?? GCController.controllers().first) -> InputSample {
        // Polling leaves Madeira's existing controller handlers untouched.
        // Physical taps wholly between these samples still need a native event
        // path; touch and keyboard callbacks already feed every edge above.
        var physical: UInt16 = 0
        var stick: (Int16, Int16) = (0, 0)
        if let pad = controller?.extendedGamepad {
            if pad.buttonA.isPressed { physical |= backend == .psp ? 1 : 1 << 8 }
            if pad.buttonB.isPressed { physical |= backend == .psp ? 1 << 8 : 1 }
            if pad.buttonMenu.isPressed { physical |= 1 << 3 }
            if pad.buttonOptions?.isPressed == true { physical |= 1 << 2 }
            if pad.dpad.up.isPressed { physical |= 1 << 4 }
            if pad.dpad.down.isPressed { physical |= 1 << 5 }
            if pad.dpad.left.isPressed { physical |= 1 << 6 }
            if pad.dpad.right.isPressed { physical |= 1 << 7 }
            if backend == .psp || backend == .advanced {
                if pad.buttonX.isPressed { physical |= backend == .advanced ? 1 << 9 : 1 << 1 }
                if pad.buttonY.isPressed { physical |= backend == .advanced ? 1 << 1 : 1 << 9 }
                if pad.leftShoulder.isPressed { physical |= 1 << 10 }
                if pad.rightShoulder.isPressed { physical |= 1 << 11 }
                stick = (Int16(max(-1, min(1, pad.leftThumbstick.xAxis.value)) * 32767),
                         Int16(max(-1, min(1, pad.leftThumbstick.yAxis.value)) * 32767))
            } else {
                if pad.leftThumbstick.yAxis.value > 0.5 { physical |= 1 << 4 }
                if pad.leftThumbstick.yAxis.value < -0.5 { physical |= 1 << 5 }
                if pad.leftThumbstick.xAxis.value < -0.5 { physical |= 1 << 6 }
                if pad.leftThumbstick.xAxis.value > 0.5 { physical |= 1 << 7 }
            }
        }
        // Recheck intent after controller sampling so pause/reset cannot let a
        // stale UI copy back into the model. Never hold this lock over a step.
        lock.lock(); defer { lock.unlock() }
        guard intent.request == .play else {
            digitalInput.cancel()
            return InputSample(digital: digitalInput.snapshot(), x: 0, y: 0)
        }
        var analog = touchAnalog != (0, 0) ? touchAnalog : keyboardAnalog
        if suppressController {
            if physical == 0, abs(Int(stick.0)) < 4096, abs(Int(stick.1)) < 4096 {
                suppressController = false
            }
            digitalInput.setButtons(0, source: "controller")
        } else {
            digitalInput.setButtons(physical, source: "controller")
            if analog == (0, 0) { analog = stick }
        }
        // UI and GameController are up-positive; libretro is down-positive.
        return InputSample(digital: digitalInput.snapshot(), x: analog.0,
                           y: Int16(clamping: -Int(analog.1)))
    }

    private func startTimer(owner: IridiumRuntimeLease) {
        guard timer == nil, runningGame != nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(1))
        framePacer = IridiumFramePacer()
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let steps = self.backend == .sameBoy ? self.framePacer.steps(at: ProcessInfo.processInfo.systemUptime, fps: self.fps) : 1
            for _ in 0..<steps { self.tick(owner) }
        }
        timer = source; source.resume()
    }
    private func stopTimer() { timer?.cancel(); timer = nil }

    private func tick(_ owner: IridiumRuntimeLease) {
        guard queueOwner == owner else { return }
        if requested == .stop, !stopRequested { beginStop(owner) }
        guard queueOwner == owner else { return }
        switch backend {
        case .advanced: return // Native upstream player owns its frame clock.
        case .sameBoy:
            guard requested == .play else { return }
            var frame = IRCoreFrame()
            let controls = input()
            let valid = ir_core_step(controls.digital.buttons, &frame)
            acknowledge(controls, polled: frame.input_polled)
            guard valid else {
                lock.lock(); intent.pause(); intentGeneration &+= 1; lock.unlock()
                stopTimer(); silenceAudio()
                progress.phase = "paused"; publishProgress(owner, force: true)
                RuntimeDiagnosticLogFiles.writeConsoleLine("[Console] invalid frame; runtime paused")
                DispatchQueue.main.async {
                    guard self.lease == owner, self.requested == .pause else { return }
                    self.phase = .paused; self.releaseButtons()
                    self.error = "The runtime stopped producing valid frames. Quit and reopen the game."
                    LibraryController.shared.configure(enabled: true, ownsInput: true)
                }
                return
            }
            recordSameBoyProgress(frame, owner: owner)
            deliver(frame, owner: owner)
            if Date().timeIntervalSince(lastSave) >= 5 {
                do { try persistSaves(); lastSave = Date() }
                catch { stopTimer(); silenceAudio(); reportSaveError(owner) }
            }
        case .psp:
            #if IRIDIUM_PPSSPP_LIBRETRO
            if bootComplete, requested == .pause {
                stopTimer(); silenceAudio()
                progress.phase = "paused"; publishProgress(owner, force: true); return
            }
            let controls = requested == .play ? input() : nil
            var frame = IRPSPFrame()
            let result = ir_psp_step(controls?.digital.buttons ?? 0, controls?.x ?? 0, controls?.y ?? 0, &frame)
            recordProgress(frame, phase: result, owner: owner)
            if let controls { acknowledge(controls, polled: frame.input_polled) }
            switch result {
            case IR_PSP_CLOSED: complete(owner)
            case IR_PSP_RESTART_REQUIRED: requireRestart(owner)
            case IR_PSP_FAILED:
                fail("PPSSPP could not start or continue this game. Its memory-stick files have been kept.", owner: owner)
            case IR_PSP_RUNNING:
                if !bootComplete {
                    bootComplete = true; fps = frame.fps; rate = frame.sample_rate
                    stopTimer() // Replace boot cadence with the core's actual frame rate.
                    do { try activate(owner) } catch { pauseAfterAudioFailure(owner) }
                }
                guard requested == .play else { return }
                // Buffers must be copied before the next bridge operation.
                var output = IRCoreFrame()
                output.pixels = frame.pixels
                // A retained bridge buffer is not a new frame. Audio can still
                // be delivered on steps where no fresh video callback arrived.
                lock.lock(); let needsFirstImage = displayedImageCount == 0; lock.unlock()
                let presentImage = frame.video_refreshed || needsFirstImage
                output.width = presentImage ? frame.width : 0
                output.height = presentImage ? frame.height : 0
                output.audio = frame.audio; output.audio_frames = frame.audio_frames
                output.frames_per_second = frame.fps; output.samples_per_second = frame.sample_rate
                deliver(output, owner: owner)
            default: break // One bounded pump keeps BOOTING/STOPPING moving.
            }
            #endif
        }
    }

    #if IRIDIUM_PPSSPP_LIBRETRO
    private func recordProgress(_ frame: IRPSPFrame, phase: IRPSPPhase, owner: IridiumRuntimeLease) {
        let now = ProcessInfo.processInfo.systemUptime
        switch phase {
        case IR_PSP_BOOTING: progress.phase = requested == .pause ? "booting (pause requested)" : "booting"
        case IR_PSP_RUNNING: progress.phase = requested == .pause ? "paused" : "running"
        case IR_PSP_STOPPING: progress.phase = "stopping"
        case IR_PSP_FAILED: progress.phase = "failed"
        case IR_PSP_RESTART_REQUIRED: progress.phase = "restart required"
        default: progress.phase = "closed"
        }
        progress.runtimeSteps = max(progress.runtimeSteps, frame.steps)
        progress.videoCallbacks = max(progress.videoCallbacks, frame.video_callbacks)
        progress.freshImages = max(progress.freshImages, frame.video_frames)
        progress.changedImages = max(progress.changedImages, frame.changed_frames)
        progress.inputPolls = max(progress.inputPolls, frame.input_polls); progress.audioFrames += UInt64(frame.audio_frames)
        if frame.video_refreshed { lastFreshImage = now }
        if frame.image_changed { lastChangedImage = now }
        publishProgress(owner)
    }
    #endif

    private func recordSameBoyProgress(_ frame: IRCoreFrame, owner: IridiumRuntimeLease) {
        let now = ProcessInfo.processInfo.systemUptime
        progress.phase = requested == .pause ? "paused" : "running"
        progress.runtimeSteps += 1
        if frame.input_polled { progress.inputPolls += 1 }
        progress.audioFrames += UInt64(frame.audio_frames)
        if let pixels = frame.pixels, frame.width > 0, frame.height > 0,
           frame.width <= 1024, frame.height <= 1024 {
            let data = Data(bytes: pixels, count: Int(frame.width) * Int(frame.height) * 4)
            progress.videoCallbacks += 1; progress.freshImages += 1; lastFreshImage = now
            if data != lastSameBoyPixels { progress.changedImages += 1; lastChangedImage = now }
            lastSameBoyPixels = data
        }
        publishProgress(owner)
    }

    /// Queue-owned samples are throttled, but phase transitions are always kept.
    /// Main-thread intent prevents an older completed step hiding a pending pause.
    private func publishProgress(_ owner: IridiumRuntimeLease, force: Bool = false) {
        lock.lock()
        let sampledGeneration = intentGeneration
        let sampledRequest = intent.request
        lock.unlock()
        if sampledRequest == .stop && !["stopping", "closed", "failed", "restart required"].contains(progress.phase) { progress.phase = "stop requested" }
        if sampledRequest == .pause && progress.phase == "running" { progress.phase = "pause requested" }
        if sampledRequest == .play && progress.phase == "paused" { progress.phase = "resume requested" }
        let now = ProcessInfo.processInfo.systemUptime
        progress.sampledUptime = now
        progress.elapsedSeconds = now - progressStarted
        progress.secondsSinceFreshImage = lastFreshImage.map { now - $0 }
        progress.secondsSinceChangedImage = lastChangedImage.map { now - $0 }
        lock.lock(); progress.displayedImages = displayedImageCount; lock.unlock()
        let changedPhase = progress.phase != lastProgressPhase
        lastProgressPhase = progress.phase
        if force || changedPhase || now - lastProgressLogged >= 5 {
            lastProgressLogged = now
            RuntimeDiagnosticLogFiles.writeConsoleLine(progress.logLine)
            if backend == .sameBoy {
                RuntimeDiagnosticLogFiles.writeConsoleLine("[SameBoy audio] core_rate_hz=\(Int(rate)) queued_ms=\(Int(Double(audioBuffering.queuedFrames) / rate * 1000)) underruns=\(audioBuffering.underruns) dropped_frames=\(audioBuffering.droppedFrames) bridge_dropped_frames=\(ir_core_audio_dropped_frames()) late_timer_events=\(framePacer.lateEvents) discarded_steps=\(framePacer.discardedSteps)")
            }
        }
        if force || changedPhase || now - lastProgressPublished >= 1 {
            lastProgressPublished = now
            let snapshot = progress
            DispatchQueue.main.async {
                guard self.lease == owner, self.currentIntentGeneration == sampledGeneration else { return }
                if self.phase == .restartRequired && !["closed", "failed", "restart required"].contains(snapshot.phase) {
                    var timedOut = snapshot; timedOut.phase = "stop timed out"
                    self.diagnostics = timedOut
                } else { self.diagnostics = snapshot }
            }
        }
    }

    private func reportSaveError(_ owner: IridiumRuntimeLease) {
        lock.lock(); intent.pause(); intentGeneration &+= 1; lock.unlock()
        progress.phase = "paused"; publishProgress(owner, force: true)
        RuntimeDiagnosticLogFiles.writeConsoleLine("[Console] save failed; paused with save retained in memory")
        DispatchQueue.main.async {
            guard self.lease == owner, self.requested == .pause else { return }
            self.phase = .paused; self.releaseButtons()
            LibraryController.shared.configure(enabled: true, ownsInput: true)
            self.error = "The save could not be written. The game is paused with its save in memory. Check free space, then retry Quit."
        }
    }

    private func saveURL(clock: Bool) throws -> URL {
        guard let folder = saveFolder else { throw IridiumRuntimeError.unsafePath }
        return try IridiumConsoleStore(root: folder).checked([clock ? "clock.bin" : "battery.sav"])
    }
    private func restoreSaves() throws {
        for clock in [false, true] {
            let url = try saveURL(clock: clock)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let count = ir_core_save_size(clock)
            // 1.0.3 exposed an RTC region even for cartridges without an RTC.
            // Retain that old file, but do not apply it to a nonexistent clock.
            if clock, count == 0 { continue }
            guard count <= 1024 * 1024,
                  try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == count else { throw IridiumRuntimeError.invalidGame }
            let data = try Data(contentsOf: url)
            guard data.withUnsafeBytes({ ir_core_write_save(clock, $0.baseAddress, $0.count) }) else { throw IridiumRuntimeError.invalidGame }
        }
    }
    private func persistSaves() throws {
        guard runningGame != nil, backend == .sameBoy else { return }
        for clock in [false, true] {
            let count = ir_core_save_size(clock)
            guard count <= 1024 * 1024 else { throw IridiumRuntimeError.invalidGame }
            guard count > 0 else { continue }
            var data = Data(count: count)
            guard data.withUnsafeMutableBytes({ ir_core_read_save(clock, $0.baseAddress, $0.count) }) else { throw IridiumRuntimeError.invalidGame }
            try data.write(to: saveURL(clock: clock), options: .atomic)
        }
    }

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        if oldAudio == nil { oldAudio = (session.category, session.mode, session.categoryOptions) }
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw IridiumRuntimeError.invalidGame }
        engine.attach(player)
        // The mixer performs sample-rate conversion to the hardware format.
        engine.connect(player, to: engine.mainMixerNode, format: format)
        self.engine = engine; self.player = player
        try engine.start()
        if backend == .sameBoy {
            RuntimeDiagnosticLogFiles.writeConsoleLine("[SameBoy] version=1.0.4 model=\(String(cString: ir_core_model())) highpass=accurate correction=modern-balanced core_rate_hz=\(Int(rate)) output_rate_hz=\(Int(engine.outputNode.outputFormat(forBus: 0).sampleRate))")
        }
    }
    private func silenceAudio() {
        player?.stop()
        audioBuffering.resetQueue()
        lock.lock(); pendingAudio = 0; audioGeneration = UUID(); lock.unlock()
    }
    private func stopAudio() {
        player?.stop(); engine?.stop(); player = nil; engine = nil
        audioBuffering.resetQueue()
        lock.lock(); pendingAudio = 0; audioGeneration = UUID(); lock.unlock()
        if let oldAudio {
            try? AVAudioSession.sharedInstance().setCategory(oldAudio.0, mode: oldAudio.1, options: oldAudio.2)
        }
        oldAudio = nil
    }

    private func deliver(_ frame: IRCoreFrame, owner: IridiumRuntimeLease) {
        guard requested == .play else { return }
        lock.lock(); let send = !pendingFrame && frame.width > 0 && frame.height > 0; if send { pendingFrame = true }; lock.unlock()
        if send {
            let count = Int(frame.width * frame.height)
            let data = frame.pixels.map { Data(bytes: $0, count: count * 4) }
            let provider = data.flatMap { CGDataProvider(data: $0 as CFData) }
            let cg = provider.flatMap { CGImage(width: Int(frame.width), height: Int(frame.height), bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: Int(frame.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)),
                provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent) }
            DispatchQueue.main.async {
                self.lock.lock(); self.pendingFrame = false; self.lock.unlock()
                guard self.lease == owner, self.requested == .play, self.phase == .starting || self.phase == .running, let cg else { return }
                self.image = UIImage(cgImage: cg)
                self.lock.lock(); self.displayedImageCount += 1; self.lock.unlock()
            }
        }
        guard let samples = frame.audio, frame.audio_frames > 0, let player,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let audioFrames = Int(frame.audio_frames)
        if backend == .sameBoy, !audioBuffering.enqueue(audioFrames, rate: rate) { return }
        lock.lock(); let generation = audioGeneration
        let sendAudio = backend == .sameBoy || pendingAudio < 4; if sendAudio { pendingAudio += 1 }; lock.unlock()
        guard sendAudio else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.audio_frames)),
              let channels = buffer.floatChannelData else {
            lock.lock(); pendingAudio = max(0, pendingAudio - 1); lock.unlock()
            if backend == .sameBoy { _ = audioBuffering.consumed(audioFrames) }
            return
        }
        buffer.frameLength = AVAudioFrameCount(frame.audio_frames)
        for index in 0..<Int(frame.audio_frames) {
            channels[0][index] = Float(samples[index * 2]) / 32768
            channels[1][index] = Float(samples[index * 2 + 1]) / 32768
        }
        lock.lock()
        guard intent.request == .play, audioGeneration == generation else {
            if audioGeneration == generation { pendingAudio = max(0, pendingAudio - 1) }
            lock.unlock()
            if backend == .sameBoy { _ = audioBuffering.consumed(audioFrames) }
            return
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, weak player] _ in
            guard let self else { return }
            // Never stop/pause AVAudioPlayerNode on its render callback.
            self.queue.async {
                self.lock.lock()
                let current = self.audioGeneration == generation
                if current { self.pendingAudio = max(0, self.pendingAudio - 1) }
                self.lock.unlock()
                if current, self.backend == .sameBoy, self.audioBuffering.consumed(audioFrames) {
                    // An empty queue must prefill again before resuming audio.
                    player?.pause()
                }
            }
        }
        lock.unlock()
        lock.lock()
        if backend == .sameBoy, intent.request == .play, audioGeneration == generation,
           audioBuffering.beginPlayback(rate: rate) { player.play() }
        lock.unlock()
    }
}
