import Foundation

// Adapted from Madeira PR128 and 6722178dd9b93898b812ae9be6130565d92652fc.
// See CHANGES-FROM-UPSTREAM.md for source revisions and retained licensing.
enum PhysicalControllerMode: String, Codable, CaseIterable, Identifiable {
    case native, keyboardMouse
    var id: String { rawValue }
    var displayName: String { self == .native ? "Native Controller" : "Keyboard & Mouse" }
}

enum PhysicalControllerStick: String, Codable, CaseIterable, Identifiable {
    case wasd, arrows, mouse, none
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .wasd: "WASD"
        case .arrows: "Arrow Keys"
        case .mouse: "Mouse"
        case .none: "Unassigned"
        }
    }
    var keys: [Int32]? {
        switch self {
        case .wasd: [0x57, 0x44, 0x53, 0x41] // up, right, down, left
        case .arrows: [0x26, 0x27, 0x28, 0x25]
        default: nil
        }
    }
}

enum PhysicalControllerButton: String, Codable, CaseIterable, Identifiable {
    case a, b, x, y, lb, rb, lt, rt, l3, r3, menu, view
    case up, down, left, right
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .menu: "Menu / Start"
        case .view: "View / Select"
        case .up: "D-Pad Up"
        case .down: "D-Pad Down"
        case .left: "D-Pad Left"
        case .right: "D-Pad Right"
        default: rawValue.uppercased()
        }
    }
    var mask: UInt16 {
        switch self {
        case .up: 1
        case .down: 2
        case .left: 4
        case .right: 8
        case .menu: 0x10
        case .view: 0x20
        case .l3: 0x40
        case .r3: 0x80
        case .lb: 0x100
        case .rb: 0x200
        case .a: 0x1000
        case .b: 0x2000
        case .x: 0x4000
        case .y: 0x8000
        case .lt, .rt: 0
        }
    }
}

enum PhysicalControllerAction: Codable, Hashable {
    case key(Int32), mouseLeft, mouseRight, mouseMiddle, none

    static let keyChoices: [(String, Int32)] = [
        ("Space", 0x20), ("Escape", 0x1b), ("Tab", 0x09), ("Return", 0x0d),
        ("Backspace", 0x08), ("Shift", 0x10), ("Control", 0x11), ("Alt", 0x12),
        ("Up Arrow", 0x26), ("Down Arrow", 0x28), ("Left Arrow", 0x25), ("Right Arrow", 0x27),
        ("Insert", 0x2d), ("Delete", 0x2e), ("Home", 0x24), ("End", 0x23),
        ("Page Up", 0x21), ("Page Down", 0x22)
    ] + (0x41...0x5a).map { (String(UnicodeScalar($0)!), Int32($0)) }
      + (0x30...0x39).map { (String(UnicodeScalar($0)!), Int32($0)) }
      + (1...12).map { ("F\($0)", Int32(0x6f + $0)) }

    static let choices: [Self] = [.none, .mouseLeft, .mouseRight, .mouseMiddle] + keyChoices.map { .key($0.1) }
    var displayName: String {
        switch self {
        case .none: "Unassigned"
        case .mouseLeft: "Left Mouse Button"
        case .mouseRight: "Right Mouse Button"
        case .mouseMiddle: "Middle Mouse Button"
        case .key(let key): Self.keyChoices.first { $0.1 == key }?.0 ?? "Unassigned"
        }
    }
}

struct PhysicalControllerConfiguration: Codable, Equatable {
    var version = 1
    var mode = PhysicalControllerMode.native
    var leftStick = PhysicalControllerStick.wasd
    var rightStick = PhysicalControllerStick.mouse
    var deadZone = 0.35
    var mouseSpeed = 900.0 // pixels per second at full deflection
    var bindings: [String: PhysicalControllerAction] = [:]

    func action(for button: PhysicalControllerButton) -> PhysicalControllerAction {
        if let action = bindings[button.rawValue] { return action }
        switch button {
        case .a: return .key(0x20)
        case .b: return .key(0x11)
        case .x: return .key(0x45)
        case .y: return .key(0x52)
        case .lb: return .key(0x51)
        case .rb: return .key(0x46)
        case .lt: return .mouseRight
        case .rt: return .mouseLeft
        case .l3: return .key(0x10)
        case .r3: return .key(0x43)
        case .menu: return .key(0x1b)
        case .view: return .key(0x09)
        case .up: return .key(0x26)
        case .down: return .key(0x28)
        case .left: return .key(0x25)
        case .right: return .key(0x27)
        }
    }

    var validated: Self {
        var value = self
        value.deadZone = deadZone.isFinite ? min(0.8, max(0.1, deadZone)) : 0.35
        value.mouseSpeed = mouseSpeed.isFinite ? min(2400, max(100, mouseSpeed)) : 900
        value.bindings = bindings.filter { key, action in
            PhysicalControllerButton(rawValue: key) != nil && PhysicalControllerAction.choices.contains(action)
        }
        return value
    }
}

// Same UUID-scoped preferences as TouchControllerLayoutStore. No library or
// touch-layout file migration is necessary, and an unreadable value is retained.
enum PhysicalControllerMappingStore {
    static let settingsChanged = Notification.Name("IridiumPhysicalControllerSettingsChanged")
    static func key(for gameID: UUID) -> String { "IridiumPhysicalControllerMapping.\(gameID.uuidString)" }

    static func configuration(for gameID: UUID, defaults: UserDefaults = .standard) -> PhysicalControllerConfiguration {
        guard let data = defaults.data(forKey: key(for: gameID)),
              let value = try? JSONDecoder().decode(PhysicalControllerConfiguration.self, from: data),
              value.version == 1 else { return .init() }
        return value.validated
    }

    static func save(_ configuration: PhysicalControllerConfiguration, for gameID: UUID,
                     defaults: UserDefaults = .standard) {
        guard configuration.version == 1,
              let data = try? JSONEncoder().encode(configuration.validated) else { return }
        defaults.set(data, forKey: key(for: gameID))
        NotificationCenter.default.post(name: settingsChanged, object: gameID)
    }
}
