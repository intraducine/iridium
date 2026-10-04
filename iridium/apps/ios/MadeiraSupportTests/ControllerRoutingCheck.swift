import Foundation

// Platform stand-ins. The runner compiles the production bridge, replacing only imports.
@MainActor final class UIScene {
    enum Activation { case foregroundActive, background }
    var activationState = Activation.foregroundActive
    static let willDeactivateNotification = Notification.Name("TestSceneDeactivate")
    static let didActivateNotification = Notification.Name("TestSceneActivate")
}
@MainActor final class UIApplication {
    enum State { case active, inactive }
    static let shared = UIApplication()
    var connectedScenes = [UIScene()]
    var applicationState = State.active
    static let willResignActiveNotification = Notification.Name("TestResign")
    static let didBecomeActiveNotification = Notification.Name("TestActive")
}
extension Notification.Name {
    static let GCControllerDidConnect = Self("TestControllerConnect")
    static let GCControllerDidDisconnect = Self("TestControllerDisconnect")
}
@MainActor final class GCControllerButtonInput { var isPressed = false; var value: Float = 0 }
@MainActor final class TestAxis { var value: Float = 0 }
@MainActor final class TestDirectionPad {
    let xAxis = TestAxis(), yAxis = TestAxis()
    let up = GCControllerButtonInput(), down = GCControllerButtonInput()
    let left = GCControllerButtonInput(), right = GCControllerButtonInput()
}
@MainActor final class TestGamepad {
    let dpad = TestDirectionPad(), leftThumbstick = TestDirectionPad(), rightThumbstick = TestDirectionPad()
    let buttonA = GCControllerButtonInput(), buttonB = GCControllerButtonInput()
    let buttonX = GCControllerButtonInput(), buttonY = GCControllerButtonInput(), buttonMenu = GCControllerButtonInput()
    var buttonOptions: GCControllerButtonInput? = GCControllerButtonInput()
    var leftThumbstickButton: GCControllerButtonInput? = GCControllerButtonInput()
    var rightThumbstickButton: GCControllerButtonInput? = GCControllerButtonInput()
    let leftShoulder = GCControllerButtonInput(), rightShoulder = GCControllerButtonInput()
    let leftTrigger = GCControllerButtonInput(), rightTrigger = GCControllerButtonInput()
}
@MainActor final class GCController {
    static var connected: [GCController] = []
    static func controllers() -> [GCController] { connected }
    let extendedGamepad: TestGamepad? = TestGamepad()
}
@MainActor enum RuntimeLogCapture { static func writeLine(_ value: String) {} }
@MainActor enum MadeiraHardwareInput {
    static var acceptingInput = true, softwareKeyboardActive = false
    static var events: [MadeiraControllerMappingState.Event] = []
    static func controllerAction(_ action: PhysicalControllerAction, pressed: Bool) { events.append(.action(action, pressed)) }
    static func controllerMotion(x: Int32, y: Int32) { events.append(.motion(x, y)) }
}

@main struct ControllerRoutingCheck {
    @MainActor static func main() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("iridium-controller-route-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        let game = UUID(), nextGame = UUID()
        defer {
            MadeiraController.stop()
            UserDefaults.standard.removeObject(forKey: PhysicalControllerMappingStore.key(for: game))
            UserDefaults.standard.removeObject(forKey: PhysicalControllerMappingStore.key(for: nextGame))
            try? FileManager.default.removeItem(at: prefix)
        }
        let first = GCController(), second = GCController()
        first.extendedGamepad!.buttonA.isPressed = true
        second.extendedGamepad!.buttonA.isPressed = true
        GCController.connected = [first]
        func data() -> Data { try! Data(contentsOf: prefix.appendingPathComponent("drive_c/iridium-controller.bin")) }
        func buttons() -> UInt16 { UInt16(data()[8]) | UInt16(data()[9]) << 8 }
        func poll() { NotificationCenter.default.post(name: .GCControllerDidConnect, object: nil) }
        func clear() { MadeiraHardwareInput.events.removeAll() }
        var config = PhysicalControllerConfiguration()
        MadeiraController.start(prefix: prefix, touchControlsEnabled: false, gameID: game)
        precondition(buttons() == 0x1000 && MadeiraHardwareInput.events.isEmpty, "default native must never map")
        config.mode = .keyboardMouse
        PhysicalControllerMappingStore.save(config, for: game)
        precondition(MadeiraHardwareInput.events == [.action(.key(0x20), true)])
        precondition(data()[4] == 0 && buttons() == 0, "mapped physical pad must not be exposed to XInput")
        clear(); poll(); precondition(MadeiraHardwareInput.events.isEmpty)
        MadeiraController.setTouchControlsActive(true)
        MadeiraController.setTouchButton(source: game, mask: 0x2000, pressed: true)
        precondition(data()[4] == 1 && buttons() == 0x2000, "touch stays on XInput independently")
        MadeiraController.acceptingInput = false
        precondition(MadeiraHardwareInput.events == [.action(.key(0x20), false)] && buttons() == 0)
        clear(); poll(); precondition(MadeiraHardwareInput.events.isEmpty)
        config.bindings["a"] = .key(0x45)
        PhysicalControllerMappingStore.save(config, for: game)
        precondition(MadeiraHardwareInput.events.isEmpty, "settings changes cannot inject input in a menu")
        MadeiraController.acceptingInput = true
        precondition(MadeiraHardwareInput.events == [.action(.key(0x45), true)])
        clear(); config.bindings["a"] = .key(0x52)
        PhysicalControllerMappingStore.save(config, for: game)
        precondition(MadeiraHardwareInput.events == [.action(.key(0x45), false), .action(.key(0x52), true)])
        clear()
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: nil)
        precondition(MadeiraHardwareInput.events == [.action(.key(0x52), false)])
        clear(); poll(); precondition(MadeiraHardwareInput.events.isEmpty, "deactivation latches before scene state changes")
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: nil)
        precondition(MadeiraHardwareInput.events == [.action(.key(0x52), true)])
        clear()
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        precondition(MadeiraHardwareInput.events == [.action(.key(0x52), false)])
        clear(); poll(); precondition(MadeiraHardwareInput.events.isEmpty)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        clear(); GCController.connected = [first, second]; poll()
        precondition(MadeiraHardwareInput.events.isEmpty)
        GCController.connected = [second]
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: first)
        precondition(MadeiraHardwareInput.events.isEmpty, "one disconnect cannot lift another pad's hold")
        GCController.connected = []
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: second)
        precondition(MadeiraHardwareInput.events == [.action(.key(0x52), false)])
        clear(); GCController.connected = [second]; poll()
        precondition(MadeiraHardwareInput.events == [.action(.key(0x52), true)])
        clear(); MadeiraHardwareInput.softwareKeyboardActive = true; poll()
        precondition(MadeiraHardwareInput.events == [.action(.key(0x52), false)])
        clear(); MadeiraHardwareInput.softwareKeyboardActive = false; poll()
        clear(); MadeiraController.stop()
        precondition(MadeiraHardwareInput.events == [.action(.key(0x52), false)])
        precondition(data().dropFirst(4).allSatisfy { $0 == 0 }, "session stop publishes disconnected state")
        clear(); MadeiraController.start(prefix: prefix, touchControlsEnabled: false, gameID: nextGame)
        precondition(MadeiraHardwareInput.events.isEmpty && buttons() == 0x1000, "next game keeps native default")
        PhysicalControllerMappingStore.save(config, for: game)
        precondition(MadeiraHardwareInput.events.isEmpty, "old settings must not affect new session")
        config.bindings.removeValue(forKey: "menu")
        PhysicalControllerMappingStore.save(config, for: nextGame)
        clear(); second.extendedGamepad!.buttonA.isPressed = false
        second.extendedGamepad!.buttonMenu.isPressed = true; poll()
        precondition(MadeiraHardwareInput.events.contains(.action(.key(0x1b), true)), "Menu maps to Escape during gameplay")
        clear(); MadeiraController.acceptingInput = false
        precondition(MadeiraHardwareInput.events == [.action(.key(0x1b), false)])
        clear(); poll()
        precondition(MadeiraHardwareInput.events.isEmpty, "app-menu focus reserves Menu for native navigation")
        print("PASS production routing: native/touch isolation, menu/focus/background, disconnect, remap, keyboard and session transitions")
    }
}
