import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Darwin
import ImageIO
import Combine

// ============================================================================
// Library front end.
//
// A game library in front of the existing launch path: entries are Windows
// executables inside the prefix's drive_c, each with its own launch profile
// (arguments, resolution and scaling, frame limit, x87 precision, on-screen
// controls). Play starts the same runWineFullSequence the developer interface
// uses; the session runs full screen with a small in-game menu.
//
// The developer interface stays available: Settings › Interface switches back
// to it (FrontendChoice), and it has a "Use New Interface" button to return.
// Every switch below is read with MadeiraConfig.flag, so `env.NAME = 0` in
// madeira.cfg turns it off.
// ============================================================================

/// Thermal state, Low Power Mode, screen capture, battery and brightness every
/// 10 s while a session runs: the device conditions that explain a slow run in
/// a log (447: the CPU was held at 1.31/1.70 GHz from the start of play with
/// thermal=nominal; charging and screen recording also draw from the power
/// budget). MADEIRA_DEVICE_STATS=0 turns the line off.
enum DeviceLoadDiagnostics {
    private static var lastReport = 0.0
    private static var timer: Timer?
    /// Opt-in (env.MADEIRA_DEVICE_STATS = 1): a line every 10 s during every
    /// session is a diagnostic, so it is off by default.
    static func start() {
        guard timer == nil, MadeiraConfig.flag("MADEIRA_DEVICE_STATS", fallback: false) else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let value = Timer(timeInterval: 10, repeats: true) { _ in report() }
        timer = value
        RunLoop.main.add(value, forMode: .common)
    }
    static func report() {
        guard wine_process_is_running() != 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastReport >= 10 else { return }
        lastReport = now
        let process = ProcessInfo.processInfo
        let thermal = thermalName(process.thermalState)
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }   // the HUD turns it off when it closes
        let level = device.batteryLevel < 0 ? "?" : String(Int((device.batteryLevel * 100).rounded()))
        let battery: String
        switch device.batteryState {
        case .charging: battery = "charging"
        case .full: battery = "full"
        case .unplugged: battery = "unplugged"
        default: battery = "unknown"
        }
        fputs("[device-load] thermal=\(thermal) low-power=\(process.isLowPowerModeEnabled ? 1 : 0) capture=\(UIScreen.main.isCaptured ? 1 : 0) "
              + "battery=\(level)% \(battery) brightness=\(String(format: "%.2f", UIScreen.main.brightness))\n", stderr)
    }
    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Which build is installed, shown in light grey in the developer interface, and
/// logged once at start ([build]). A build that
/// writes `MadeiraBuild` into Info.plist (a round tag and build time) shows that;
/// other builds show the bundle version. MADEIRA_BUILD_LABEL=0 hides the label
/// (the log line stays).
enum BuildStamp {
    static let text: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        if let stamp = info["MadeiraBuild"] as? String, !stamp.isEmpty { return stamp }
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }()
    static let visible = MadeiraConfig.flag("MADEIRA_BUILD_LABEL")
}

/// Controller navigation of the library, fed by GamepadInput's sampler (player
/// 1's physical pad) so there is no second timer. While the library owns input
/// (no session, or the in-game menu is open) GamepadInput publishes a neutral
/// pad to Windows. D-pad or left stick moves the focus, A opens, B goes back,
/// Y adds a game, a shoulder switches tabs; in a session Back+Start opens the
/// menu. MADEIRA_FRONTEND_CONTROLLER=0 turns navigation off.
final class LibraryController: ObservableObject, @unchecked Sendable {
    static let shared = LibraryController()
    @Published var connected = false
    let commands = PassthroughSubject<String, Never>()
    private let lock = NSLock()
    private var enabled = false
    private var owns = false
    private var last: UInt16 = 0
    private var announced = false
    private let allowed = MadeiraConfig.flag("MADEIRA_FRONTEND_CONTROLLER")
    var ownsInput: Bool { lock.lock(); defer { lock.unlock() }; return enabled && owns }
    func configure(enabled: Bool, ownsInput: Bool) {
        lock.lock(); self.enabled = enabled && allowed; owns = ownsInput; lock.unlock()
    }
    /// One sample of player 1's pad, in XInput button bits and stick units.
    func sample(buttons raw: UInt16, lx: Int16, ly: Int16) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        var buttons = raw
        if owns {
            if lx < -16000 { buttons |= 4 }; if lx > 16000 { buttons |= 8 }
            if ly > 16000 { buttons |= 1 }; if ly < -16000 { buttons |= 2 }
        }
        let pressed = buttons & ~last; last = buttons
        let own = owns, announce = !announced; announced = true
        lock.unlock()
        if announce { DispatchQueue.main.async { self.connected = true; fputs("[frontend-controller] navigation active\n", stderr) } }
        var command: String?
        // Reserve the Back+Start chord in gameplay, leaving ordinary Start intact.
        if !own, buttons & 0x30 == 0x30, pressed & 0x30 != 0 { command = "menu" }
        if own {
            for (mask, name): (UInt16, String) in [(1, "up"), (2, "down"), (4, "left"), (8, "right"), (0x1000, "accept"), (0x2000, "back"), (0x8000, "add"), (0x10, "menu"), (0x4000, "play"), (0x100, "tab"), (0x200, "tab")] {
                if pressed & mask != 0 { command = name; break }
            }
        }
        if let command { DispatchQueue.main.async { self.commands.send(command) } }
    }
}

/// Which interface Madeira starts with: the library (the default) or the
/// developer interface. The choice is made in either interface, stored in
/// UserDefaults and read once per run, so a change applies at the next start.
/// Without a stored choice, MADEIRA_FRONTEND=0/1 in madeira.cfg (env.) or in
/// madeira-env.txt decides; MADEIRA_FRONTEND_DEFAULT_NEW=0 makes the developer
/// interface the default.
enum FrontendChoice {
    static let key = "madeiraFrontend"
    static let startup: (useNew: Bool, source: String) = {
        if let stored = UserDefaults.standard.string(forKey: key), ["new", "old"].contains(stored) {
            return (stored == "new", "setting")
        }
        if let configured = MadeiraConfig.get("env.MADEIRA_FRONTEND") { return (configured != "0", "config") }
        if let value = getenv("MADEIRA_FRONTEND").map({ String(cString: $0) }) { return (value != "0", "environment") }
        return (MadeiraConfig.flag("MADEIRA_FRONTEND_DEFAULT_NEW"), "default")
    }()
    /// The interface the next start uses.
    static var preferNew: Bool {
        guard let stored = UserDefaults.standard.string(forKey: key), ["new", "old"].contains(stored) else { return startup.useNew }
        return stored == "new"
    }
    static func choose(new useNew: Bool) {
        UserDefaults.standard.set(useNew ? "new" : "old", forKey: key)
        LogStore.shared.log("[frontend] next-start choice=\(useNew ? "library" : "developer") source=setting")
    }
    private static var logged = false
    static func logStartup() {
        guard !logged else { return }
        logged = true
        LogStore.shared.log("[frontend] choice=\(startup.useNew ? "library" : "developer") source=\(startup.source)")
    }
}
