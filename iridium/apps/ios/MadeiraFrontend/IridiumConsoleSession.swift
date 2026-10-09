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
    @Published var error: String?
    @Published private(set) var presented = false
    var isActive: Bool { game != nil }

    private let queue = DispatchQueue(label: "software.iridium.console", qos: .userInteractive)
    private let lock = NSLock()
    private var touchButtons: UInt16 = 0
    private var keyboardButtons: UInt16 = 0
    private var touchAnalog: (Int16, Int16) = (0, 0)
    private var keyboardAnalog: (Int16, Int16) = (0, 0)
    private var suppressController = false
    private var intent = IridiumConsoleIntent() // protected by lock
    private enum Backend { case sameBoy, psp }
    private var backend = Backend.sameBoy // queue-owned below
    private var queueOwner: IridiumRuntimeLease?
    private var bootComplete = false
    private var stopRequested = false
    private var terminalFailure = false
    private var pendingFrame = false
    private var pendingAudio = 0
    private var audioGeneration = UUID()
    private var timer: DispatchSourceTimer?
    private var ownership = IridiumRuntimeOwnership() // main thread only
    private var lease: IridiumRuntimeLease?
    private var stopWatch = UUID() // main-thread stop-attempt generation
    private var saveFolder: URL?
    private var runningGame: IridiumConsoleGame?
    private var rate = 384000.0
    private var fps = 60.0
    private var lastSave = Date.distantPast
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var oldAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    func start(_ game: IridiumConsoleGame, store: IridiumConsoleStore) {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            guard phase != .restartRequired else { throw IridiumRuntimeError.restartRequired }
            guard LibraryModel.shared.current == nil, !LibraryModel.shared.launching,
                  wine_process_is_running() == 0, wineserver_is_running() == 0 else { throw IridiumRuntimeError.busy }
            guard LibraryModel.sessionsThisRun == 0 else { throw IridiumRuntimeError.restartRequired }
            let runtime = try IridiumRuntimeRegistry.resolve(platform: game.platform, preferred: game.runtimeID)
            guard runtime.id == "sameboy" || runtime.id == "ppsspp" else { throw IridiumRuntimeError.unavailable }
            _ = try runtime.executionMode(jitAvailable: false)
            let owner = try ownership.acquire(runtime)
            lock.lock(); intent = IridiumConsoleIntent(); lock.unlock()
            releaseButtons()
            self.lease = owner; self.game = game; image = nil; error = nil; phase = .starting; presented = true
            LibraryController.shared.configure(enabled: true, ownsInput: false)
            queue.async { [self] in
                queueOwner = owner; bootComplete = false; stopRequested = false; terminalFailure = false
                backend = runtime.id == "ppsspp" ? .psp : .sameBoy
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
                        if requested == .play { deliver(first, owner: owner) }
                    case .psp:
                        #if IRIDIUM_PPSSPP
                        // Native code and assets have fixed signed-bundle locations.
                        // Never resolve an executable path from a library record.
                        guard let frameworks = Bundle.main.privateFrameworksURL,
                              let resources = Bundle.main.resourceURL else { throw IridiumRuntimeError.unavailable }
                        let component = frameworks.appendingPathComponent("ppsspp_libretro.dylib")
                        let assets = resources.appendingPathComponent("PSP", isDirectory: true)
                        let opened = component.path.withCString { componentPath in
                            url.path.withCString { gamePath in
                                assets.path.withCString { assetPath in
                                    folder.path.withCString { ir_psp_open(componentPath, gamePath, assetPath, $0) }
                                }
                            }
                        }
                        guard opened else { throw IridiumRuntimeError.unavailable }
                        // True means accepted ownership, even if async boot fails.
                        saveFolder = folder; runningGame = game; fps = 60
                        startTimer(owner: owner)
                        #else
                        throw IridiumRuntimeError.unavailable
                        #endif
                    }
                } catch {
                    fail(error.localizedDescription, owner: owner)
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    private var requested: IridiumConsoleIntent.Request {
        lock.lock(); defer { lock.unlock() }; return intent.request
    }

    func pause() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner = lease, phase == .running || phase == .starting else { return }
        lock.lock(); intent.pause(); lock.unlock()
        phase = .paused; releaseButtons()
        LibraryController.shared.configure(enabled: true, ownsInput: true)
        queue.async { [self] in
            guard queueOwner == owner, requested == .pause else { return }
            // Async PSP boot still needs the single pump to reach a safe state.
            if bootComplete { stopTimer() }
            silenceAudio()
            do { try persistSaves() }
            catch { reportSaveError(owner) }
        }
    }

    func resume() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner = lease, phase == .paused else { return }
        lock.lock(); intent.resume(); lock.unlock()
        phase = .starting
        LibraryController.shared.configure(enabled: true, ownsInput: false)
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
        lock.lock(); intent.stop(); lock.unlock()
        phase = .stopping; releaseButtons()
        watchStop(owner)
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
            self.error = "The runtime has not stopped. You can return to the library, but fully close and reopen Iridium before launching another game."
        }
    }

    private func beginStop(_ owner: IridiumRuntimeLease) {
        silenceAudio()
        switch backend {
        case .sameBoy:
            stopTimer()
            do { try persistSaves() }
            catch {
                // SameBoy alone has recoverable in-memory battery/RTC data.
                lock.lock(); intent = IridiumConsoleIntent(); intent.pause(); lock.unlock()
                reportSaveError(owner); return
            }
            ir_core_close(); complete(owner)
        case .psp:
            #if IRIDIUM_PPSSPP
            if !stopRequested { ir_psp_request_stop(); stopRequested = true }
            startTimer(owner: owner) // Drain, never force unload, including failed boot.
            #else
            complete(owner)
            #endif
        }
    }

    private func fail(_ message: String, owner: IridiumRuntimeLease) {
        terminalFailure = true
        lock.lock(); intent.stop(); lock.unlock()
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
        stopTimer(); stopAudio(); runningGame = nil; saveFolder = nil; queueOwner = nil
        DispatchQueue.main.async {
            guard self.lease == owner else { return }
            self.ownership.release(owner)
            // Async drain can dismiss the player after its error observer ran.
            // Preserve an unacknowledged launch/runtime failure at the library.
            if failed, let error = self.error { LibraryModel.shared.error = error }
            self.error = nil
            self.lease = nil; self.game = nil; self.image = nil; self.phase = .idle; self.presented = false
            LibraryModel.shared.refreshFlag()
        }
    }

    private func requireRestart(_ owner: IridiumRuntimeLease) {
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
        if play { player?.play() }
        lock.unlock()
        guard play else {
            if requested == .stop { beginStop(owner) } else { stopTimer(); silenceAudio() }
            return
        }
        startTimer(owner: owner)
        DispatchQueue.main.async {
            guard self.lease == owner, self.phase == .starting, self.requested == .play else { return }
            self.phase = .running
        }
    }

    private func pauseAfterAudioFailure(_ owner: IridiumRuntimeLease) {
        lock.lock(); intent.pause(); lock.unlock()
        stopTimer(); silenceAudio()
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

    func setButton(_ bit: UInt16, pressed: Bool, keyboard: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard !pressed || intent.request == .play else { return }
        if keyboard {
            if pressed { keyboardButtons |= bit } else { keyboardButtons &= ~bit }
        } else {
            if pressed { touchButtons |= bit } else { touchButtons &= ~bit }
        }
    }
    func setAnalog(x: Int16, y: Int16, keyboard: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard intent.request == .play else { return }
        if keyboard { keyboardAnalog = (x, y) } else { touchAnalog = (x, y) }
    }

    func releaseButtons() {
        lock.lock()
        touchButtons = 0; keyboardButtons = 0
        touchAnalog = (0, 0); keyboardAnalog = (0, 0); suppressController = true
        lock.unlock()
    }

    private func input() -> (UInt16, Int16, Int16) {
        lock.lock()
        let enabled = intent.request == .play
        var bits = touchButtons | keyboardButtons
        var analog = touchAnalog != (0, 0) ? touchAnalog : keyboardAnalog
        let suppressed = suppressController
        lock.unlock()
        guard enabled else { return (0, 0, 0) }
        // Polling leaves Madeira's existing controller handlers untouched.
        var physical: UInt16 = 0
        var stick: (Int16, Int16) = (0, 0)
        if let pad = (GCController.current ?? GCController.controllers().first)?.extendedGamepad {
            if pad.buttonA.isPressed { physical |= backend == .psp ? 1 : 1 << 8 }
            if pad.buttonB.isPressed { physical |= backend == .psp ? 1 << 8 : 1 }
            if pad.buttonMenu.isPressed { physical |= 1 << 3 }
            if pad.buttonOptions?.isPressed == true { physical |= 1 << 2 }
            if pad.dpad.up.isPressed { physical |= 1 << 4 }
            if pad.dpad.down.isPressed { physical |= 1 << 5 }
            if pad.dpad.left.isPressed { physical |= 1 << 6 }
            if pad.dpad.right.isPressed { physical |= 1 << 7 }
            if backend == .psp {
                if pad.buttonX.isPressed { physical |= 1 << 1 }
                if pad.buttonY.isPressed { physical |= 1 << 9 }
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
        if suppressed {
            if physical == 0, abs(Int(stick.0)) < 4096, abs(Int(stick.1)) < 4096 {
                lock.lock(); suppressController = false; lock.unlock()
            }
        } else {
            bits |= physical
            if analog == (0, 0) { analog = stick }
        }
        // UI and GameController are up-positive; libretro is down-positive.
        return (bits, analog.0, Int16(clamping: -Int(analog.1)))
    }

    private func startTimer(owner: IridiumRuntimeLease) {
        guard timer == nil, runningGame != nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.tick(owner) }
        timer = source; source.resume()
    }
    private func stopTimer() { timer?.cancel(); timer = nil }

    private func tick(_ owner: IridiumRuntimeLease) {
        guard queueOwner == owner else { return }
        if requested == .stop, !stopRequested { beginStop(owner) }
        guard queueOwner == owner else { return }
        switch backend {
        case .sameBoy:
            guard requested == .play else { return }
            var frame = IRCoreFrame()
            guard ir_core_step(input().0, &frame) else {
                lock.lock(); intent.pause(); lock.unlock()
                stopTimer(); silenceAudio()
                DispatchQueue.main.async {
                    guard self.lease == owner, self.requested == .pause else { return }
                    self.phase = .paused; self.releaseButtons()
                    self.error = "The runtime stopped producing valid frames. Quit and reopen the game."
                    LibraryController.shared.configure(enabled: true, ownsInput: true)
                }
                return
            }
            deliver(frame, owner: owner)
            if Date().timeIntervalSince(lastSave) >= 5 {
                do { try persistSaves(); lastSave = Date() }
                catch { stopTimer(); silenceAudio(); reportSaveError(owner) }
            }
        case .psp:
            #if IRIDIUM_PPSSPP
            if bootComplete, requested == .pause { stopTimer(); silenceAudio(); return }
            let controls = requested == .play ? input() : (UInt16(0), Int16(0), Int16(0))
            var frame = IRPSPFrame()
            switch ir_psp_step(controls.0, controls.1, controls.2, &frame) {
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
                output.pixels = frame.pixels; output.width = frame.width; output.height = frame.height
                output.audio = frame.audio; output.audio_frames = frame.audio_frames
                output.frames_per_second = frame.fps; output.samples_per_second = frame.sample_rate
                deliver(output, owner: owner)
            default: break // One bounded pump keeps BOOTING/STOPPING moving.
            }
            #endif
        }
    }

    private func reportSaveError(_ owner: IridiumRuntimeLease) {
        lock.lock(); intent.pause(); lock.unlock()
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
    }
    private func silenceAudio() {
        player?.stop()
        lock.lock(); pendingAudio = 0; audioGeneration = UUID(); lock.unlock()
    }
    private func stopAudio() {
        player?.stop(); engine?.stop(); player = nil; engine = nil
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
            }
        }
        guard let samples = frame.audio, frame.audio_frames > 0, let player,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        lock.lock(); let generation = audioGeneration
        let sendAudio = pendingAudio < 4; if sendAudio { pendingAudio += 1 }; lock.unlock()
        guard sendAudio else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.audio_frames)),
              let channels = buffer.floatChannelData else {
            lock.lock(); pendingAudio = max(0, pendingAudio - 1); lock.unlock(); return
        }
        buffer.frameLength = AVAudioFrameCount(frame.audio_frames)
        for index in 0..<Int(frame.audio_frames) {
            channels[0][index] = Float(samples[index * 2]) / 32768
            channels[1][index] = Float(samples[index * 2 + 1]) / 32768
        }
        lock.lock()
        guard intent.request == .play, audioGeneration == generation else {
            if audioGeneration == generation { pendingAudio = max(0, pendingAudio - 1) }
            lock.unlock(); return
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.audioGeneration == generation { self.pendingAudio = max(0, self.pendingAudio - 1) }
            self.lock.unlock()
        }
        lock.unlock()
    }
}
