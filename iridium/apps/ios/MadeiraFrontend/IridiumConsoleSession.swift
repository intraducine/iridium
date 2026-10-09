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
    private var pendingFrame = false
    private var pendingAudio = 0
    private var audioGeneration = UUID()
    private var timer: DispatchSourceTimer?
    private var ownership = IridiumRuntimeOwnership() // main thread only
    private var lease: IridiumRuntimeLease?
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
            guard LibraryModel.shared.current == nil, !LibraryModel.shared.launching,
                  wine_process_is_running() == 0, wineserver_is_running() == 0 else { throw IridiumRuntimeError.busy }
            guard LibraryModel.sessionsThisRun == 0 else { throw IridiumRuntimeError.restartRequired }
            let runtime = try IridiumRuntimeRegistry.resolve(platform: game.platform, preferred: game.runtimeID)
            guard runtime.id == "sameboy" else { throw IridiumRuntimeError.unavailable }
            _ = try runtime.executionMode(jitAvailable: false)
            let owner = try ownership.acquire(runtime)
            self.lease = owner; self.game = game; image = nil; error = nil; phase = .starting; presented = true
            LibraryController.shared.configure(enabled: true, ownsInput: false)
            queue.async { [self] in
                do {
                    let url = try store.rom(game)
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          let size = values.fileSize, size >= 0x150, size <= 8 * 1024 * 1024 else { throw IridiumRuntimeError.invalidGame }
                    let rom = try Data(contentsOf: url)
                    guard rom.count == size else { throw IridiumRuntimeError.invalidGame }
                    let folder = try store.saveDirectory(game)
                    let opened = rom.withUnsafeBytes { bytes in
                        folder.path.withCString { ir_core_open(bytes.baseAddress, bytes.count, $0) }
                    }
                    guard opened else { throw IridiumRuntimeError.invalidGame }
                    saveFolder = folder; runningGame = game
                    try restoreSaves()
                    // Obtain timing from the actual loaded core, not a stale
                    // documentation constant. The first frame is also retained.
                    var first = IRCoreFrame()
                    guard ir_core_step(0, &first) else { throw IridiumRuntimeError.invalidGame }
                    fps = first.frames_per_second; rate = first.samples_per_second
                    try startAudio()
                    deliver(first, owner: owner)
                    lastSave = Date()
                    startTimer(owner: owner)
                    DispatchQueue.main.async {
                        guard self.lease == owner else { return }
                        if self.phase == .starting { self.phase = .running }
                    }
                } catch {
                    stopTimer(); stopAudio(); ir_core_close()
                    runningGame = nil; saveFolder = nil
                    DispatchQueue.main.async {
                        guard self.lease == owner else { return }
                        self.error = error.localizedDescription
                        self.finish(owner)
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func pause() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner = lease, phase == .running || phase == .starting else { return }
        phase = .paused; releaseButtons()
        LibraryController.shared.configure(enabled: true, ownsInput: true)
        queue.async { [self] in
            stopTimer(); player?.pause()
            do { try persistSaves() }
            catch { reportSaveError(owner) }
        }
    }

    func resume() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner = lease, phase == .paused else { return }
        phase = .running
        LibraryController.shared.configure(enabled: true, ownsInput: false)
        queue.async { [self] in
            guard runningGame != nil else { return }
            do {
                if engine?.isRunning != true { try engine?.start() }
                player?.play(); startTimer(owner: owner)
            } catch {
                DispatchQueue.main.async {
                    guard self.lease == owner else { return }
                    self.phase = .paused; self.error = "Audio could not resume. Try Resume again."
                    LibraryController.shared.configure(enabled: true, ownsInput: true)
                }
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner = lease, phase != .stopping, phase != .restartRequired else { return }
        phase = .stopping; releaseButtons()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard self.lease == owner, self.phase == .stopping else { return }
            self.phase = .restartRequired
            self.error = "The runtime has not stopped. You can return to the library, but fully close and reopen Iridium before launching another game."
        }
        queue.async { [self] in
            stopTimer(); player?.pause()
            do { try persistSaves() }
            catch {
                // Preserve the paused core's RAM if the save cannot be written.
                // The user can free space and retry Quit; don't discard saves.
                reportSaveError(owner); return
            }
            ir_core_close(); stopAudio(); runningGame = nil; saveFolder = nil
            DispatchQueue.main.async { if self.lease == owner { self.finish(owner) } }
        }
    }

    private func finish(_ owner: IridiumRuntimeLease) {
        ownership.release(owner)
        lease = nil; game = nil; image = nil; phase = .idle; presented = false
        LibraryModel.shared.refreshFlag()
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
        if keyboard {
            if pressed { keyboardButtons |= bit } else { keyboardButtons &= ~bit }
        } else {
            if pressed { touchButtons |= bit } else { touchButtons &= ~bit }
        }
    }
    func releaseButtons() { lock.lock(); touchButtons = 0; keyboardButtons = 0; lock.unlock() }

    private func buttons() -> UInt16 {
        lock.lock(); var bits = touchButtons | keyboardButtons; lock.unlock()
        // Sampling leaves Madeira's existing controller handlers untouched.
        if let pad = (GCController.current ?? GCController.controllers().first)?.extendedGamepad {
            if pad.buttonA.isPressed { bits |= 1 << 8 }
            if pad.buttonB.isPressed { bits |= 1 << 0 }
            if pad.buttonMenu.isPressed { bits |= 1 << 3 }
            if pad.buttonOptions?.isPressed == true { bits |= 1 << 2 }
            if pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value > 0.5 { bits |= 1 << 4 }
            if pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value < -0.5 { bits |= 1 << 5 }
            if pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value < -0.5 { bits |= 1 << 6 }
            if pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value > 0.5 { bits |= 1 << 7 }
        }
        return bits
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
        var frame = IRCoreFrame()
        guard ir_core_step(buttons(), &frame) else {
            stopTimer()
            DispatchQueue.main.async {
                guard self.lease == owner else { return }
                self.phase = .paused; self.error = "The runtime stopped producing valid frames. Quit and reopen the game."
                LibraryController.shared.configure(enabled: true, ownsInput: true)
            }
            return
        }
        deliver(frame, owner: owner)
        if Date().timeIntervalSince(lastSave) >= 5 {
            do { try persistSaves(); lastSave = Date() }
            catch { stopTimer(); player?.pause(); reportSaveError(owner) }
        }
    }

    private func reportSaveError(_ owner: IridiumRuntimeLease) {
        DispatchQueue.main.async {
            guard self.lease == owner else { return }
            self.phase = .paused
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
        guard runningGame != nil else { return }
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
        oldAudio = (session.category, session.mode, session.categoryOptions)
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw IridiumRuntimeError.invalidGame }
        engine.attach(player)
        // The mixer performs sample-rate conversion to the hardware format.
        engine.connect(player, to: engine.mainMixerNode, format: format)
        self.engine = engine; self.player = player
        try engine.start(); player.play()
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
        lock.lock(); let send = !pendingFrame; if send { pendingFrame = true }; lock.unlock()
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
                guard self.lease == owner, let cg else { return }
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
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.audioGeneration == generation { self.pendingAudio = max(0, self.pendingAudio - 1) }
            self.lock.unlock()
        }
    }
}
