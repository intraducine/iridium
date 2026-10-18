// SPDX-License-Identifier: AGPL-3.0-only
// Simulator-only adapter harness. It executes the production native player.
import UIKit

private let inputLock = NSLock()
private var buttons: UInt16 = 0

@main final class Phase3Smoke: UIResponder, UIApplicationDelegate {
    static var active: Phase3Smoke?
    var window: UIWindow?
    private var player: UIViewController?
    private var events: [[String: Any]] = []
    private var engine = ""
    private var output: URL!
    private var monitor: Timer?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Self.active = self
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = Phase3SmokeScene.self
        return configuration
    }

    func start(in scene: UIWindowScene) {
        let args = ProcessInfo.processInfo.arguments
        func argument(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        output = documents.appendingPathComponent("phase3-smoke.json")
        engine = argument("--engine") ?? ""
        let filename = argument("--game") ?? ""
        guard ["dolphin", "azahar", "play", "flycast"].contains(engine),
              !filename.isEmpty, URL(fileURLWithPath: filename).lastPathComponent == filename else {
            record(3, "A whitelisted engine and private fixture filename are required."); return
        }
        let saves = documents.appendingPathComponent("saves/" + engine)
        let system = documents.appendingPathComponent("system/" + engine)
        do {
            try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        } catch { record(3, "The fixture storage could not be created."); return }
        let content = documents.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: content.path), let frameworks = Bundle.main.privateFrameworksURL else {
            record(3, "Fixture or component is absent."); return
        }
        window = UIWindow(windowScene: scene)
        let idle = UIViewController(); idle.view.backgroundColor = .black
        window?.rootViewController = idle; window?.makeKeyAndVisible()
        let controller = engine.withCString { runtime in frameworks.path.withCString { binaries in content.path.withCString { game in saves.path.withCString { save in system.path.withCString { firmware in
            ir_phase3_open(runtime, binaries, game, save, firmware, true, 1, { _, kind, message in
                let text = message.map { String(cString: $0) } ?? ""
                DispatchQueue.main.async { Phase3Smoke.active?.record(kind, text) }
            }, { value in
                guard let value else { return }
                inputLock.lock(); defer { inputLock.unlock() }
                value.pointee = IRPhase3Input(); value.pointee.buttons = buttons
            })
        } } } } }
        guard let controller else { record(3, "The production player declined creation."); return }
        player = Unmanaged<UIViewController>.fromOpaque(controller).takeRetainedValue()
        window?.rootViewController = player
        record(0, "Production native player created; waiting for actual video.")
        monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.persist() }
        // Exercise the real shared digital-input boundary without asserting
        // that a particular homebrew program reacted to these buttons.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            inputLock.lock(); buttons = 1 << 8; inputLock.unlock()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            inputLock.lock(); buttons = 0; inputLock.unlock()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { ir_phase3_pause(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.3) { ir_phase3_pause(false) }
        let seconds = min(120, max(8, Double(argument("--seconds") ?? "12") ?? 12))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.record(0, "Stop requested."); ir_phase3_stop() }
    }

    private func record(_ kind: UInt32, _ message: String) {
        if events.count < 128 { events.append(["kind": kind, "message": message]) }
        print("Phase3 \(engine) event=\(kind) \(message)")
        if kind == 2 { monitor?.invalidate(); monitor = nil; player = nil }
        persist()
    }
    private func persist() {
        guard let output else { return }
        let result: [String: Any] = ["engine": engine, "frames": ir_phase3_frames(), "events": events]
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic) }
        catch { print("Phase3 result could not be persisted.") }
    }
}

final class Phase3SmokeScene: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        Phase3Smoke.active?.start(in: scene)
    }
}
