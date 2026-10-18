// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// App-owned presentation profiles. Native runtimes keep ownership of input and rendering.
enum IridiumPlayerProfile: String, CaseIterable {
    case windows, psp, gameBoy, console, nintendo3DS
    static func consoleProfile(_ platform: String?) -> Self {
        if platform == "psp" { return .psp }
        if platform == "nintendo3DS" { return .nintendo3DS }
        return ["gameCube", "wii", "playStation2", "dreamcast", "arcade"].contains(platform ?? "") ? .console : .gameBoy
    }
    var aspectRatio: CGFloat {
        switch self {
        case .psp: return 480.0 / 272.0
        case .gameBoy: return 160.0 / 144.0
        case .windows: return 16.0 / 9.0
        case .console: return 4.0 / 3.0
        case .nintendo3DS: return 400.0 / 480.0
        }
    }
}

enum IridiumTouchMouseMode: String, CaseIterable {
    case off, trackpad, direct
    static let settingsKey = "IridiumTouchMouseMode"
    static func current(_ defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: settingsKey) ?? "") ?? .trackpad
    }
}

/// The same saved menu position follows the window size; temporary safe-area
/// clamping never rewrites it during rotation.
enum IridiumMenuPlacement {
    static func draggedCenter(normalized: CGPoint, translation: CGSize, size: CGSize,
                              leading: CGFloat, trailing: CGFloat, top: CGFloat, bottom: CGFloat) -> CGPoint {
        let visible = center(normalized: normalized, size: size, leading: leading, trailing: trailing, top: top, bottom: bottom)
        let dx = translation.width.isFinite ? translation.width : 0
        let dy = translation.height.isFinite ? translation.height : 0
        return center(normalized: CGPoint(x: (visible.x + dx) / max(1, size.width),
                                          y: (visible.y + dy) / max(1, size.height)),
                      size: size, leading: leading, trailing: trailing, top: top, bottom: bottom)
    }
    static func center(normalized: CGPoint, size: CGSize, leading: CGFloat, trailing: CGFloat,
                       top: CGFloat, bottom: CGFloat) -> CGPoint {
        let x = normalized.x.isFinite ? min(1, max(0, normalized.x)) : 0.92
        let y = normalized.y.isFinite ? min(1, max(0, normalized.y)) : 0.12
        let minX = min(size.width / 2, max(0, leading) + 32)
        let minY = min(size.height / 2, max(0, top) + 32)
        return CGPoint(x: min(max(minX, size.width * x), max(minX, size.width - trailing - 32)),
                       y: min(max(minY, size.height * y), max(minY, size.height - bottom - 32)))
    }
}

enum Iridium3DSTouchProjection {
    /// Azahar's selected top-bottom layout is a 400x480 canvas. Its lower
    /// 320x240 touchscreen is centered below the top screen. Rejecting other
    /// taps also prevents upstream from pressing the last valid touch point.
    static func project(point: CGPoint, size: CGSize) -> (Int16, Int16)? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let canvas = IridiumPlayerLayout.aspectFit(400.0 / 480.0, in: CGRect(origin: .zero, size: size))
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let x = (point.x - canvas.minX) / canvas.width
        let y = (point.y - canvas.minY) / canvas.height
        guard x >= 0.1, x < 0.9, y >= 0.5, y < 1 else { return nil }
        // Encode pixel centers so upstream's truncating conversion cannot
        // round an edge onto the adjacent non-touch area.
        let px = min(359, max(40, floor(x * 400))) + 0.5
        let py = min(479, max(240, floor(y * 480))) + 0.5
        return (Int16((px / 400 * 65534 - 32767).rounded()), Int16((py / 480 * 65534 - 32767).rounded()))
    }
}

enum IridiumPointerProjection {
    static func frame(point: CGPoint, guest: CGSize, host: CGRect, image: CGSize, hotspot: CGPoint) -> CGRect {
        let width = max(1, guest.width), height = max(1, guest.height)
        let sx = host.width / width, sy = host.height / height
        let imageScale = max(1, min(sx, sy))
        let x = point.x.isFinite ? min(width - 1, max(0, point.x)) : 0
        let y = point.y.isFinite ? min(height - 1, max(0, point.y)) : 0
        return CGRect(x: host.minX + x * sx - hotspot.x * imageScale,
                      y: host.minY + y * sy - hotspot.y * imageScale,
                      width: image.width * imageScale, height: image.height * imageScale)
    }
}

struct IridiumTouchMouseMotion {
    private var remainder = CGPoint.zero
    mutating func reset() { remainder = .zero }
    mutating func delta(_ translation: CGPoint, sensitivity: Double) -> (Int32, Int32) {
        guard translation.x.isFinite, translation.y.isFinite else { return (0, 0) }
        let gain = sensitivity.isFinite ? min(32, max(0.025, sensitivity)) : 1
        let dx = min(CGFloat(30000), max(-30000, remainder.x + translation.x * CGFloat(gain)))
        let dy = min(CGFloat(30000), max(-30000, remainder.y + translation.y * CGFloat(gain)))
        let x = Int32(dx), y = Int32(dy)
        remainder = CGPoint(x: dx - CGFloat(x), y: dy - CGFloat(y))
        return (x, y)
    }
}

enum IridiumTouchHaptics: String, CaseIterable {
    case off, light, medium
    static let settingsKey = "IridiumTouchHaptics"
    static func current(_ defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: settingsKey) ?? "") ?? .light
    }
}

/// The saved layout keeps Madeira's action names; only the runtime mapping differs.
enum IridiumConsoleControlMapping {
    static func button(_ action: String, profile: IridiumPlayerProfile) -> UInt16? {
        let common: [String: UInt16] = ["D↑": 1 << 4, "D↓": 1 << 5, "D←": 1 << 6,
            "D→": 1 << 7, "Menu": 1 << 3, "View": 1 << 2]
        if let bit = common[action] { return bit }
        switch profile {
        case .psp: return ["A": UInt16(1), "B": 1 << 8, "X": 1 << 1,
                          "Y": 1 << 9, "LB": 1 << 10, "RB": 1 << 11][action]
        case .gameBoy: return ["A": UInt16(1 << 8), "B": 1][action]
        case .console, .nintendo3DS:
            return ["A": UInt16(1 << 8), "B": 1, "X": 1 << 9, "Y": 1 << 1,
                    "LB": 1 << 10, "RB": 1 << 11, "LT": 1 << 12, "RT": 1 << 13,
                    "L3": 1 << 14, "R3": 1 << 15][action]
        case .windows: return nil
        }
    }
    static func symbol(_ action: String, profile: IridiumPlayerProfile) -> String? {
        if let arrow = ["D↑": "arrow.up", "D↓": "arrow.down", "D←": "arrow.left", "D→": "arrow.right"][action] { return arrow }
        guard profile == .psp else { return nil }
        return ["A": "xmark", "B": "circle", "X": "square", "Y": "triangle"][action]
    }
    static func label(_ action: String, profile: IridiumPlayerProfile) -> String {
        if action == "DPad" { return "D-pad" }; if action == "Menu" { return "Start" }; if action == "View" { return "Select" }
        if profile == .psp {
            return ["A": "Cross", "B": "Circle", "X": "Square", "Y": "Triangle", "LB": "L", "RB": "R"][action] ?? action
        }
        return action
    }
}

/// Feedback is tied to engagement, never repeated vector or held-button updates.
struct IridiumControlHapticTransition {
    private(set) var engaged = false
    mutating func update(_ down: Bool) -> Bool {
        guard down != engaged else { return false }
        engaged = down
        return down
    }
}

struct IridiumPlayerButton: Identifiable {
    let id: String
    let symbol: String?
    let bit: UInt16
    let frame: CGRect
    var isPill: Bool { id == "Start" || id == "Select" || id == "L" || id == "R" }
}

struct IridiumPlayerLayout {
    let viewport: CGRect
    let dpad: CGRect
    let stick: CGRect?
    let buttons: [IridiumPlayerButton]
    let menu: CGPoint

    /// The viewport is solved before controls. Landscape controls never subtract game area.
    init(profile: IridiumPlayerProfile, bounds: CGRect, touchVisible: Bool) {
        let landscape = bounds.width > bounds.height
        var display = bounds
        if !landscape && touchVisible {
            display.size.height = max(0, bounds.height - min(300, bounds.height * 0.48))
        }
        viewport = Self.aspectFit(profile.aspectRatio, in: display)
        menu = CGPoint(x: bounds.midX, y: bounds.minY + 26)
        let left = bounds.minX, right = bounds.maxX, bottom = bounds.maxY
        let dpadCenter = CGPoint(x: left + 76, y: bottom - (landscape ? 132 : 166))
        dpad = Self.frame(center: dpadCenter, size: CGSize(width: 132, height: 132))
        stick = profile != .gameBoy && profile != .windows ? Self.frame(
            center: CGPoint(x: landscape ? dpad.maxX + 8 + 44 : left + 76, y: bottom - 54),
            size: CGSize(width: 88, height: 88)) : nil
        var result: [IridiumPlayerButton] = []
        func add(_ id: String, _ symbol: String? = nil, bit: UInt16, x: CGFloat, y: CGFloat, width: CGFloat = 48) {
            result.append(IridiumPlayerButton(id: id, symbol: symbol, bit: bit,
                frame: Self.frame(center: CGPoint(x: x, y: y), size: CGSize(width: width, height: 44))))
        }
        if profile == .psp {
            let cx = right - 76, cy = bottom - (landscape ? 112 : 166)
            add("Triangle", "triangle", bit: 1 << 9, x: cx, y: cy - 46)
            add("Square", "square", bit: 1 << 1, x: cx - 46, y: cy)
            add("Circle", "circle", bit: 1 << 8, x: cx + 46, y: cy)
            add("Cross", "xmark", bit: 1 << 0, x: cx, y: cy + 46)
            let shoulderY = landscape ? bounds.minY + 26 : bottom - 264
            add("L", bit: 1 << 10, x: left + 54, y: shoulderY, width: 72)
            add("R", bit: 1 << 11, x: right - 54, y: shoulderY, width: 72)
        } else if profile == .gameBoy {
            add("B", bit: 1, x: right - 112, y: bottom - 148)
            add("A", bit: 1 << 8, x: right - 52, y: bottom - 172)
        } else if profile == .console || profile == .nintendo3DS {
            let cx = right - 76, cy = bottom - (landscape ? 132 : 166)
            add("Y", bit: 1 << 1, x: cx - 46, y: cy)
            add("X", bit: 1 << 9, x: cx, y: cy - 46)
            add("B", bit: 1, x: cx, y: cy + 46)
            add("A", bit: 1 << 8, x: cx + 46, y: cy)
            let shoulderY = landscape ? bounds.minY + 26 : bottom - 264
            add("L", bit: 1 << 10, x: left + 44, y: shoulderY, width: 60)
            add("R", bit: 1 << 11, x: right - 44, y: shoulderY, width: 60)
            add("L2", bit: 1 << 12, x: left + 112, y: shoulderY, width: 60)
            add("R2", bit: 1 << 13, x: right - 112, y: shoulderY, width: 60)
        }
        let selectX = landscape ? bounds.midX - 84 : right - 116
        let startX = landscape ? bounds.midX + 84 : right - 44
        let systemY = landscape ? bounds.minY + 26 : bottom - 44
        add("Select", bit: 1 << 2, x: selectX, y: systemY, width: 64)
        add("Start", bit: 1 << 3, x: startX, y: systemY, width: 64)
        buttons = result
    }

    static func aspectFit(_ aspect: CGFloat, in bounds: CGRect) -> CGRect {
        guard aspect.isFinite, aspect > 0, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let width = min(bounds.width, bounds.height * aspect)
        let height = width / aspect
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    private static func frame(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

/// Shared touch math is independent of frame rate and UIKit delivery.
enum IridiumControlGeometry {
    static func directionVector(_ sector: Int) -> CGPoint {
        guard (0...7).contains(sector) else { return .zero }
        let angle = CGFloat(sector) * .pi / 4
        return CGPoint(x: sin(angle), y: cos(angle))
    }
    static func stick(location: CGPoint, size: CGSize) -> CGPoint {
        let radius = max(1, min(size.width, size.height) * 0.32)
        let x = location.x - size.width / 2, y = location.y - size.height / 2
        let length = max(radius, hypot(x, y))
        return CGPoint(x: x / length, y: -y / length)
    }
    static func directions(location: CGPoint, size: CGSize) -> UInt16 {
        guard CGRect(origin: .zero, size: size).contains(location) else { return 0 }
        let x = location.x / max(1, size.width) - 0.5
        let y = location.y / max(1, size.height) - 0.5
        var bits: UInt16 = 0
        if x < -0.16 { bits |= 1 << 6 }; if x > 0.16 { bits |= 1 << 7 }
        if y < -0.16 { bits |= 1 << 4 }; if y > 0.16 { bits |= 1 << 5 }
        return bits
    }
}

/// Immediate visual state, deliberately without press animations or delayed releases.
struct IridiumControlPressState {
    private(set) var isDown = false
    var fillOpacity: Double { isDown ? 0.25 : 0.06 }
    var strokeOpacity: Double { isDown ? 0.85 : 0.32 }
    var scale: CGFloat { isDown ? 0.94 : 1 }
    @discardableResult mutating func set(_ down: Bool) -> Bool {
        guard isDown != down else { return false }
        isDown = down
        return true
    }
}

/// Per-control appearance composes with the existing session preference. It
/// never participates in input registration or hit testing.
enum IridiumControlOpacity {
    static let minimum = 0.15
    static func normalized(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 1 }
        return min(1, max(minimum, value))
    }
    static func visual(control: Double?, layout: Double, pressed: Bool) -> Double {
        let idle = max(minimum, normalized(control) * normalized(layout))
        return pressed ? max(0.55, idle) : idle
    }
}

enum IridiumPlayerMenuNavigation {
    static func ownsCommands(page: String, nativeEditor: Bool) -> Bool {
        !nativeEditor && (page == "Session" || page == "Controls")
    }
    static func touchControlItems(enabled: Bool, controller: Bool, overrideEnabled: Bool, includeSettings: Bool = false) -> [String] {
        var items = [enabled ? "Hide Touch Controls" : "Show Touch Controls"]
        if controller { items.append(overrideEnabled ? "Use Controller" : "Use Touch Controls") }
        if includeSettings { items.append("Control Settings") }
        return items
    }
    static func next(_ focused: String, order: [String], command: String) -> String {
        guard !order.isEmpty else { return focused }
        let step = command == "up" || command == "left" ? -1 : 1
        return order[min(max((order.firstIndex(of: focused) ?? 0) + step, 0), order.count - 1)]
    }
}


/// Confirmation remains app-owned so every supported input can cancel or confirm.
/// The safe default also prevents a repeated accept from immediately closing a game.
struct IridiumCloseConfirmation {
    enum Outcome: Equatable { case pending, cancel, close }
    private(set) var selection = "Cancel"
    mutating func receive(_ command: String) -> Outcome {
        if command == "back" || command == "menu" { return .cancel }
        if ["up", "down", "left", "right"].contains(command) {
            selection = IridiumPlayerMenuNavigation.next(selection, order: ["Cancel", "Close Game"], command: command)
        }
        if command == "accept" { return selection == "Close Game" ? .close : .cancel }
        return .pending
    }
}


/// A single directional transition is submitted atomically, never as per-bit edges.
struct IridiumDirectionControlState {
    private(set) var bits: UInt16 = 0
    mutating func update(_ next: UInt16) -> UInt16? {
        guard next != bits else { return nil }
        bits = next
        return bits
    }
}

/// Each on-screen stick owns its own value. Releasing one cannot release a
/// different held stick; the most recently moved active stick has priority.
struct IridiumAnalogSources {
    private var values: [String: (Int16, Int16)] = [:]
    private var order: [String] = []
    mutating func set(x: Int16, y: Int16, source: String) {
        order.removeAll { $0 == source }
        if x == 0 && y == 0 { values.removeValue(forKey: source) }
        else { values[source] = (x, y); order.append(source) }
    }
    var value: (Int16, Int16) { order.last.flatMap { values[$0] } ?? (0, 0) }
    mutating func clear() { values.removeAll(); order.removeAll() }
}
