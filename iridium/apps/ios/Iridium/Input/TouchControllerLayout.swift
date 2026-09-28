import Foundation

enum TouchControllerMapping: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftStick
    case rightStick
    case dpad
    case a
    case b
    case x
    case y
    case leftBumper
    case rightBumper
    case leftTrigger
    case rightTrigger
    case leftStickButton
    case rightStickButton
    case menu
    case view

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftStick: "Left Stick"
        case .rightStick: "Right Stick"
        case .dpad: "D-Pad"
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .leftBumper: "LB"
        case .rightBumper: "RB"
        case .leftTrigger: "LT"
        case .rightTrigger: "RT"
        case .leftStickButton: "L3"
        case .rightStickButton: "R3"
        case .menu: "Menu"
        case .view: "View"
        }
    }

    var compactLabel: String {
        switch self {
        case .leftStick: "L"
        case .rightStick: "R"
        case .dpad: "D"
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .leftBumper: "LB"
        case .rightBumper: "RB"
        case .leftTrigger: "LT"
        case .rightTrigger: "RT"
        case .leftStickButton: "L3"
        case .rightStickButton: "R3"
        case .menu: "≡"
        case .view: "◫"
        }
    }

    var systemImage: String {
        switch self {
        case .leftStick, .rightStick: "circle.circle"
        case .dpad: "dpad.fill"
        case .a, .b, .x, .y: "circle.fill"
        case .leftBumper, .rightBumper: "rectangle.roundedtop.fill"
        case .leftTrigger, .rightTrigger: "rectangle.fill"
        case .leftStickButton, .rightStickButton: "dot.circle.fill"
        case .menu: "line.3.horizontal"
        case .view: "rectangle.on.rectangle"
        }
    }

    var kind: TouchControllerControlKind {
        switch self {
        case .leftStick, .rightStick: .stick
        case .dpad: .dpad
        case .leftTrigger, .rightTrigger: .trigger
        default: .button
        }
    }

    var buttonMask: UInt16? {
        switch self {
        case .a: 0x1000
        case .b: 0x2000
        case .x: 0x4000
        case .y: 0x8000
        case .leftBumper: 0x0100
        case .rightBumper: 0x0200
        case .leftStickButton: 0x0040
        case .rightStickButton: 0x0080
        case .menu: 0x0010
        case .view: 0x0020
        default: nil
        }
    }
}

enum TouchControllerControlKind: String, Codable, Sendable {
    case button
    case stick
    case dpad
    case trigger
}

struct TouchControllerControl: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var mapping: TouchControllerMapping
    var centerX: Double
    var centerY: Double
    var size: Double
    var opacity: Double
    var isHidden: Bool

    init(
        id: UUID = UUID(),
        mapping: TouchControllerMapping,
        centerX: Double,
        centerY: Double,
        size: Double,
        opacity: Double = 0.72,
        isHidden: Bool = false
    ) {
        self.id = id
        self.mapping = mapping
        self.centerX = min(0.98, max(0.02, centerX))
        self.centerY = min(0.98, max(0.02, centerY))
        self.size = min(0.34, max(0.055, size))
        self.opacity = min(1, max(0.15, opacity))
        self.isHidden = isHidden
    }
}

struct TouchControllerLayout: Codable, Hashable, Sendable {
    var version: Int = 1
    var controls: [TouchControllerControl]

    static let xboxDefault = TouchControllerLayout(controls: [
        .init(mapping: .leftTrigger, centerX: 0.10, centerY: 0.12, size: 0.105, opacity: 0.62),
        .init(mapping: .leftBumper, centerX: 0.21, centerY: 0.12, size: 0.095, opacity: 0.66),
        .init(mapping: .view, centerX: 0.43, centerY: 0.14, size: 0.070, opacity: 0.62),
        .init(mapping: .menu, centerX: 0.57, centerY: 0.14, size: 0.070, opacity: 0.62),
        .init(mapping: .rightBumper, centerX: 0.79, centerY: 0.12, size: 0.095, opacity: 0.66),
        .init(mapping: .rightTrigger, centerX: 0.90, centerY: 0.12, size: 0.105, opacity: 0.62),

        .init(mapping: .leftStick, centerX: 0.15, centerY: 0.70, size: 0.205),
        .init(mapping: .leftStickButton, centerX: 0.15, centerY: 0.47, size: 0.065, opacity: 0.58),
        .init(mapping: .dpad, centerX: 0.35, centerY: 0.77, size: 0.155, opacity: 0.66),

        .init(mapping: .rightStick, centerX: 0.67, centerY: 0.76, size: 0.165),
        .init(mapping: .rightStickButton, centerX: 0.67, centerY: 0.52, size: 0.065, opacity: 0.58),
        .init(mapping: .x, centerX: 0.80, centerY: 0.68, size: 0.082),
        .init(mapping: .y, centerX: 0.87, centerY: 0.58, size: 0.082),
        .init(mapping: .a, centerX: 0.87, centerY: 0.78, size: 0.082),
        .init(mapping: .b, centerX: 0.94, centerY: 0.68, size: 0.082)
    ])
}

enum TouchControllerLayoutStore {
    static let defaultEnabledKey = "IridiumTouchControlsDefaultEnabled"
    static let settingsChanged = Notification.Name("IridiumTouchControllerSettingsChanged")

    private static func layoutKey(gameID: UUID) -> String {
        "IridiumTouchControllerLayout.\(gameID.uuidString)"
    }

    private static func enabledKey(gameID: UUID) -> String {
        "IridiumTouchControllerEnabled.\(gameID.uuidString)"
    }

    static func layout(for gameID: UUID, defaults: UserDefaults = .standard) -> TouchControllerLayout {
        guard let data = defaults.data(forKey: layoutKey(gameID: gameID)),
              let layout = try? JSONDecoder().decode(TouchControllerLayout.self, from: data),
              layout.version == 1,
              !layout.controls.isEmpty else {
            return .xboxDefault
        }
        return layout
    }

    static func save(_ layout: TouchControllerLayout, for gameID: UUID, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: layoutKey(gameID: gameID))
        NotificationCenter.default.post(name: settingsChanged, object: gameID)
    }

    static func resetLayout(for gameID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: layoutKey(gameID: gameID))
        NotificationCenter.default.post(name: settingsChanged, object: gameID)
    }

    static func isEnabled(for gameID: UUID, defaults: UserDefaults = .standard) -> Bool {
        let key = enabledKey(gameID: gameID)
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        return defaults.bool(forKey: defaultEnabledKey)
    }

    static func setEnabled(_ enabled: Bool, for gameID: UUID, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey(gameID: gameID))
        NotificationCenter.default.post(name: settingsChanged, object: gameID)
    }

    static func clearPerGameEnabledOverride(for gameID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: enabledKey(gameID: gameID))
        NotificationCenter.default.post(name: settingsChanged, object: gameID)
    }
}
