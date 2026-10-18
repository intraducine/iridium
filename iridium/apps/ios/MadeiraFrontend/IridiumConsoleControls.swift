// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Adapts the existing Madeira control canvas to a sampled console runtime.
/// Windows retains TouchPadSurface and its native GamepadInput ownership.
struct IridiumConsoleControlSurface: View {
    let control: UUID
    let action: String
    let changed: (CGSize, Bool) -> Void
    @ObservedObject private var session = IridiumConsoleSession.shared
    private var profile: IridiumPlayerProfile { session.game?.platform == .psp ? .psp : .gameBoy }
    var body: some View {
        IridiumControlTouchSurface(enabled: session.phase == .running) { point, size in
            let down = point != nil
            if action == "DPad" {
                let bits = point.map { IridiumControlGeometry.directions(location: $0, size: size) } ?? 0
                session.setButtons(bits, source: "touch.layout." + control.uuidString)
                let x = (bits & (1 << 7) != 0 ? 1.0 : 0) - (bits & (1 << 6) != 0 ? 1.0 : 0)
                let y = (bits & (1 << 5) != 0 ? 1.0 : 0) - (bits & (1 << 4) != 0 ? 1.0 : 0)
                changed(CGSize(width: x, height: y), bits != 0)
            } else if action == "LS", profile == .psp {
                let vector = point.map { IridiumControlGeometry.stick(location: $0, size: size) } ?? .zero
                session.setAnalog(x: Int16((vector.x * 32767).rounded()), y: Int16((vector.y * 32767).rounded()), source: "touch.layout." + control.uuidString)
                changed(CGSize(width: vector.x, height: -vector.y), down)
            } else if let bit = IridiumConsoleControlMapping.button(action, profile: profile) {
                let inside = point.map { CGRect(origin: .zero, size: size).contains($0) } ?? false
                session.setButton(bit, pressed: inside, source: "touch.layout." + control.uuidString)
                changed(.zero, inside)
            } else { changed(.zero, false) }
        }
        .accessibilityElement().accessibilityLabel(IridiumConsoleControlMapping.label(action, profile: profile))
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            if action == "DPad" {
                Button("Up") { pulse(1 << 4) }; Button("Down") { pulse(1 << 5) }
                Button("Left") { pulse(1 << 6) }; Button("Right") { pulse(1 << 7) }
            } else if action == "LS" {
                Button("Up") { analog(0, 32767) }; Button("Down") { analog(0, -32767) }
                Button("Left") { analog(-32767, 0) }; Button("Right") { analog(32767, 0) }
                Button("Center") { analog(0, 0) }
            }
        }
        .onDisappear { analog(0, 0) }
        .accessibilityAction {
            guard session.phase == .running,
                  let bit = IridiumConsoleControlMapping.button(action, profile: profile) else { return }
            pulse(bit)
        }
    }
    private func analog(_ x: Int16, _ y: Int16) {
        guard action == "LS" else { return }
        if x != 0 || y != 0 { IridiumControlHaptics.press() }
        session.setAnalog(x: x, y: y, source: "accessibility.layout." + control.uuidString)
    }
    private func pulse(_ bit: UInt16) {
        guard session.phase == .running else { return }
        IridiumControlHaptics.press()
        let source = "accessibility.layout." + control.uuidString
        session.setButton(bit, pressed: true, source: source)
        session.setButton(bit, pressed: false, source: source)
    }
}

enum IridiumConsoleControlLayout {
    /// Clamp only the rendered copy. Saved custom coordinates and sizes survive
    /// rotation unchanged, and the Madeira editor still owns explicit edits.
    static func fitted(_ control: TouchControl, screen: CGSize, sizeScale: Double, editing: Bool) -> TouchControl {
        guard screen.width > 0, screen.height > 0 else { return control }
        // Keep the selected control's 22pt delete handle (+8pt offset) reachable.
        let inset = min(editing ? CGFloat(10) : 2, min(screen.width, screen.height) / 4)
        let available = CGSize(width: screen.width - inset * 2, height: screen.height - inset * 2)
        let diameter = TouchControlsModel.baseDiameter * CGFloat(control.scale * sizeScale)
        let size = control.action.controlSize(diameter: diameter)
        let factor = min(1, min(available.width / max(1, size.width), available.height / max(1, size.height)))
        var value = control
        value.scale *= Double(factor)
        let halfWidth = size.width * factor / 2, halfHeight = size.height * factor / 2
        value.nx = Double(min(screen.width - inset - halfWidth, max(inset + halfWidth, CGFloat(control.nx) * screen.width)) / screen.width)
        value.ny = Double(min(screen.height - inset - halfHeight, max(inset + halfHeight, CGFloat(control.ny) * screen.height)) / screen.height)
        return value
    }

    static func defaults(profile: IridiumPlayerProfile, bounds: CGRect) -> [TouchControl] {
        let layout = IridiumPlayerLayout(profile: profile, bounds: bounds, touchVisible: true)
        func control(_ action: String, _ frame: CGRect) -> TouchControl {
            TouchControl(nx: Double((frame.midX - bounds.minX) / max(1, bounds.width)),
                         ny: Double((frame.midY - bounds.minY) / max(1, bounds.height)),
                         scale: Double(max(44, min(frame.width, frame.height)) / TouchControlsModel.baseDiameter),
                         action: .pad(action))
        }
        var values = [control("DPad", layout.dpad)]
        if let stick = layout.stick { values.append(control("LS", stick)) }
        let actions = ["Cross": "A", "Circle": "B", "Square": "X", "Triangle": "Y",
                       "L": "LB", "R": "RB", "Start": "Menu", "Select": "View", "A": "A", "B": "B"]
        values += layout.buttons.compactMap { button in actions[button.id].map { control($0, button.frame) } }
        return values
    }
}
