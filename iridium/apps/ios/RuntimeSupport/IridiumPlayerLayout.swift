// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// App-owned presentation profiles. Native runtimes keep ownership of input and rendering.
enum IridiumPlayerProfile: String, CaseIterable {
    case windows, psp, gameBoy
    var aspectRatio: CGFloat {
        switch self { case .psp: return 480.0 / 272.0; case .gameBoy: return 160.0 / 144.0; case .windows: return 16.0 / 9.0 }
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
        stick = profile == .psp ? Self.frame(
            center: CGPoint(x: left + (landscape ? 176 : 76), y: bottom - 54),
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
