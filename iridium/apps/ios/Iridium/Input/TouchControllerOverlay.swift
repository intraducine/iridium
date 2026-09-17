import Foundation
import SwiftUI

struct TouchControllerOverlay: View {
    private static let inputResetNotification = Notification.Name("IridiumTouchControllerInputReset")
    static let playerMenuRequested = Notification.Name("IridiumTouchControllerPlayerMenuRequested")

    let gameID: UUID
    @State private var layout: TouchControllerLayout
    @State private var resetGeneration = 0
    @AppStorage("IridiumPlayerMenuHandleYFraction") private var menuHandleYFraction = 0.5
    @State private var menuHandleMoved = false

    init(gameID: UUID) {
        self.gameID = gameID
        _layout = State(initialValue: TouchControllerLayoutStore.layout(for: gameID))
    }

    var body: some View {
        GeometryReader { geometry in
            let minimumDimension = min(geometry.size.width, geometry.size.height)
            let handleY = max(44, min(geometry.size.height - 44, CGFloat(menuHandleYFraction) * geometry.size.height))

            ZStack {
                ForEach(layout.controls.filter { !$0.isHidden }) { control in
                    let size = touchControllerRenderedSize(control, minimumDimension: minimumDimension)
                    TouchControllerRuntimeControl(control: control, renderedSize: size)
                        .frame(width: size.width, height: size.height)
                        .position(
                            x: CGFloat(control.centerX) * geometry.size.width,
                            y: CGFloat(control.centerY) * geometry.size.height
                        )
                }

                // This is an actual hit target, not just a visual hint. It sits above the
                // customizable controls, opens on a tap, and can be moved vertically.
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.48))
                        .frame(width: 18, height: 56)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.34), lineWidth: 1)
                        .frame(width: 18, height: 56)
                    Image(systemName: "ellipsis")
                        .font(.caption2.bold())
                        .foregroundStyle(.white.opacity(0.88))
                        .rotationEffect(.degrees(90))
                }
                .frame(width: 44, height: 72)
                .contentShape(Rectangle())
                .position(x: geometry.size.width - 22, y: handleY)
                .zIndex(10_000)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("touch-controller-overlay"))
                        .onChanged { value in
                            let distance = hypot(value.translation.width, value.translation.height)
                            if distance > 8 { menuHandleMoved = true }
                            guard menuHandleMoved, geometry.size.height > 0 else { return }
                            let y = max(44, min(geometry.size.height - 44, value.location.y))
                            menuHandleYFraction = Double(y / geometry.size.height)
                        }
                        .onEnded { value in
                            let distance = hypot(value.translation.width, value.translation.height)
                            if distance <= 8 {
                                NotificationCenter.default.post(name: Self.playerMenuRequested, object: gameID)
                            } else if geometry.size.height > 0 {
                                let y = max(44, min(geometry.size.height - 44, value.location.y))
                                menuHandleYFraction = Double(y / geometry.size.height)
                            }
                            menuHandleMoved = false
                        }
                )
                .accessibilityLabel("Player Menu")
                .accessibilityHint("Tap to open the player menu. Drag up or down to move this handle.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    NotificationCenter.default.post(name: Self.playerMenuRequested, object: gameID)
                }
            }
            .coordinateSpace(name: "touch-controller-overlay")
            .id(resetGeneration)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .onAppear { TouchControllerRuntimeBridge.setActive(true) }
        .onDisappear { TouchControllerRuntimeBridge.setActive(false) }
        .onReceive(NotificationCenter.default.publisher(for: Self.inputResetNotification)) { _ in
            resetGeneration &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: TouchControllerLayoutStore.settingsChanged)) { notification in
            guard let changedGame = notification.object as? UUID, changedGame == gameID else { return }
            layout = TouchControllerLayoutStore.layout(for: gameID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On-screen controller")
        .accessibilityHint("Use the right-edge Player Menu handle to open Iridium controls")
    }
}

private func touchControllerRenderedSize(_ control: TouchControllerControl, minimumDimension: CGFloat) -> CGSize {
    let base = max(38, CGFloat(control.size) * minimumDimension)
    switch control.mapping.kind {
    case .stick, .dpad:
        return CGSize(width: base, height: base)
    case .trigger:
        return CGSize(width: base * 1.55, height: base * 0.68)
    case .button:
        switch control.mapping {
        case .leftBumper, .rightBumper:
            return CGSize(width: base * 1.45, height: base * 0.70)
        case .menu, .view:
            return CGSize(width: base * 1.15, height: base * 0.80)
        default:
            return CGSize(width: base, height: base)
        }
    }
}

private struct TouchControllerRuntimeControl: View {
    let control: TouchControllerControl
    let renderedSize: CGSize

    var body: some View {
        switch control.mapping.kind {
        case .button:
            TouchControllerButton(control: control)
        case .trigger:
            TouchControllerTrigger(control: control)
        case .stick:
            TouchControllerStick(control: control, renderedSize: renderedSize)
        case .dpad:
            TouchControllerDPad(control: control, renderedSize: renderedSize)
        }
    }
}

private struct TouchControllerButton: View {
    let control: TouchControllerControl
    @State private var pressed = false

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(pressed ? 0.58 : 0.36))
            Circle().stroke(.white.opacity(pressed ? 0.88 : 0.58), lineWidth: 2)
            Text(control.mapping.compactLabel)
                .font(.system(.body, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
        }
        .opacity(control.opacity)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    TouchControllerRuntimeBridge.setButton(source: control.id, mapping: control.mapping, pressed: true)
                }
                .onEnded { _ in release() }
        )
        .onDisappear { release() }
        .accessibilityLabel(control.mapping.displayName)
        .accessibilityAddTraits(.isButton)
    }

    private func release() {
        guard pressed else { return }
        pressed = false
        TouchControllerRuntimeBridge.setButton(source: control.id, mapping: control.mapping, pressed: false)
    }
}

private struct TouchControllerTrigger: View {
    let control: TouchControllerControl
    @State private var pressed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.black.opacity(pressed ? 0.60 : 0.38))
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(.white.opacity(pressed ? 0.90 : 0.60), lineWidth: 2)
            Text(control.mapping.compactLabel)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
        }
        .opacity(control.opacity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    TouchControllerRuntimeBridge.setTrigger(source: control.id, mapping: control.mapping, value: 1)
                }
                .onEnded { _ in release() }
        )
        .onDisappear { release() }
        .accessibilityLabel(control.mapping.displayName)
        .accessibilityAddTraits(.isButton)
    }

    private func release() {
        guard pressed else { return }
        pressed = false
        TouchControllerRuntimeBridge.setTrigger(source: control.id, mapping: control.mapping, value: 0)
    }
}

private struct TouchControllerStick: View {
    let control: TouchControllerControl
    let renderedSize: CGSize
    @State private var knobOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.32))
            Circle().stroke(.white.opacity(0.45), lineWidth: 2)
            Circle()
                .fill(.white.opacity(0.42))
                .frame(width: renderedSize.width * 0.46, height: renderedSize.height * 0.46)
                .offset(knobOffset)
            Text(control.mapping.compactLabel)
                .font(.caption2.bold())
                .foregroundStyle(.white.opacity(0.85))
        }
        .opacity(control.opacity)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in update(location: value.location) }
                .onEnded { _ in reset() }
        )
        .onDisappear { reset() }
        .accessibilityLabel(control.mapping.displayName)
    }

    private func update(location: CGPoint) {
        let radius = max(1, min(renderedSize.width, renderedSize.height) * 0.38)
        var x = location.x - renderedSize.width / 2
        var y = location.y - renderedSize.height / 2
        let length = sqrt(x * x + y * y)
        if length > radius {
            x *= radius / length
            y *= radius / length
        }
        knobOffset = CGSize(width: x, height: y)
        TouchControllerRuntimeBridge.setStick(
            source: control.id,
            mapping: control.mapping,
            x: Float(x / radius),
            y: Float(-y / radius),
            active: true
        )
    }

    private func reset() {
        knobOffset = .zero
        TouchControllerRuntimeBridge.setStick(source: control.id, mapping: control.mapping, x: 0, y: 0, active: false)
    }
}

private struct TouchControllerDPad: View {
    let control: TouchControllerControl
    let renderedSize: CGSize
    @State private var directions: Set<Direction> = []

    private enum Direction: CaseIterable, Hashable {
        case up, down, left, right

        var mask: UInt16 {
            switch self {
            case .up: 0x0001
            case .down: 0x0002
            case .left: 0x0004
            case .right: 0x0008
            }
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.30))
                .frame(width: renderedSize.width * 0.34, height: renderedSize.height)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.30))
                .frame(width: renderedSize.width, height: renderedSize.height * 0.34)
            Image(systemName: "dpad.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.55))
                .padding(renderedSize.width * 0.10)
        }
        .opacity(control.opacity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in update(location: value.location) }
                .onEnded { _ in releaseAll() }
        )
        .onDisappear { releaseAll() }
        .accessibilityLabel("D-Pad")
    }

    private func update(location: CGPoint) {
        let center = CGPoint(x: renderedSize.width / 2, y: renderedSize.height / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let threshold = min(renderedSize.width, renderedSize.height) * 0.14
        var next = Set<Direction>()
        if dx > threshold { next.insert(.right) }
        if dx < -threshold { next.insert(.left) }
        if dy > threshold { next.insert(.down) }
        if dy < -threshold { next.insert(.up) }

        for direction in Direction.allCases where directions.contains(direction) != next.contains(direction) {
            TouchControllerRuntimeBridge.setDPad(source: control.id, mask: direction.mask, pressed: next.contains(direction))
        }
        directions = next
    }

    private func releaseAll() {
        for direction in directions {
            TouchControllerRuntimeBridge.setDPad(source: control.id, mask: direction.mask, pressed: false)
        }
        directions.removeAll()
    }
}

@MainActor
private enum TouchControllerRuntimeBridge {
    static func setActive(_ active: Bool) {
        #if MADEIRA_RUNTIME
        MadeiraController.setTouchControlsActive(active)
        #endif
    }

    static func setButton(source: UUID, mapping: TouchControllerMapping, pressed: Bool) {
        guard let mask = mapping.buttonMask else { return }
        #if MADEIRA_RUNTIME
        MadeiraController.setTouchButton(source: source, mask: mask, pressed: pressed)
        #endif
    }

    static func setDPad(source: UUID, mask: UInt16, pressed: Bool) {
        #if MADEIRA_RUNTIME
        MadeiraController.setTouchButton(source: source, mask: mask, pressed: pressed)
        #endif
    }

    static func setTrigger(source: UUID, mapping: TouchControllerMapping, value: Float) {
        #if MADEIRA_RUNTIME
        switch mapping {
        case .leftTrigger:
            MadeiraController.setTouchTrigger(source: source, left: true, value: value)
        case .rightTrigger:
            MadeiraController.setTouchTrigger(source: source, left: false, value: value)
        default:
            break
        }
        #endif
    }

    static func setStick(source: UUID, mapping: TouchControllerMapping, x: Float, y: Float, active: Bool) {
        #if MADEIRA_RUNTIME
        switch mapping {
        case .leftStick:
            MadeiraController.setTouchStick(source: source, left: true, x: x, y: y, active: active)
        case .rightStick:
            MadeiraController.setTouchStick(source: source, left: false, x: x, y: y, active: active)
        default:
            break
        }
        #endif
    }
}
