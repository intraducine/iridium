import Foundation
import SwiftUI
import UIKit

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

func touchControllerRenderedSize(_ control: TouchControllerControl, minimumDimension: CGFloat) -> CGSize {
    let base = max(38, CGFloat(control.size) * minimumDimension)
    switch control.mapping.kind {
    case .stick, .dpad:
        return CGSize(width: base, height: base)
    case .trigger:
        return CGSize(width: base, height: base)
    case .button:
        switch control.mapping {
        case .menu, .view:
            return CGSize(width: base * 1.45, height: base * 0.65)
        default:
            return CGSize(width: base, height: base)
        }
    }
}

extension TouchControllerMapping {
    var moonlightImageName: String {
        switch self {
        case .a: "AButton"
        case .b: "BButton"
        case .x: "XButton"
        case .y: "YButton"
        case .leftBumper: "L1"
        case .rightBumper: "R1"
        case .leftTrigger: "L2"
        case .rightTrigger: "R2"
        case .leftStickButton: "L3"
        case .rightStickButton: "R3"
        case .menu: "StartButton"
        case .view: "SelectButton"
        case .leftStick, .rightStick, .dpad: "StickOuter"
        }
    }
}

struct MoonlightStickArtwork: View {
    let size: CGSize
    let knobOffset: CGSize

    var body: some View {
        ZStack {
            Image("StickOuter").resizable().scaledToFit()
            Image("StickInner").resizable().scaledToFit()
                .frame(width: size.width * 0.60, height: size.height * 0.60)
                .offset(knobOffset)
        }
        .frame(width: size.width, height: size.height)
    }
}

struct MoonlightDPadArtwork: View {
    let size: CGSize

    var body: some View {
        ZStack {
            Image("UpButton").resizable().scaledToFit()
                .frame(width: size.width * 0.31, height: size.height * 0.38)
                .offset(y: -size.height * 0.30)
            Image("DownButton").resizable().scaledToFit()
                .frame(width: size.width * 0.31, height: size.height * 0.38)
                .offset(y: size.height * 0.30)
            Image("LeftButton").resizable().scaledToFit()
                .frame(width: size.width * 0.38, height: size.height * 0.31)
                .offset(x: -size.width * 0.30)
            Image("RightButton").resizable().scaledToFit()
                .frame(width: size.width * 0.38, height: size.height * 0.31)
                .offset(x: size.width * 0.30)
        }
        .frame(width: size.width, height: size.height)
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
    @State private var pressedAt = 0.0
    @State private var releaseTask: Task<Void, Never>?

    var body: some View {
        Image(control.mapping.moonlightImageName)
            .resizable()
            .scaledToFit()
            .brightness(pressed ? 0.25 : 0)
        .opacity(control.opacity)
        .contentShape(Rectangle())
        .overlay {
            MoonlightTouchArea(round: control.mapping != .menu && control.mapping != .view,
                               label: control.mapping.displayName) { phase, _ in
                switch phase {
                case .began: press()
                case .moved: break
                case .ended: finishPress()
                }
            }
        }
        .onDisappear { release() }
        .accessibilityLabel(control.mapping.displayName)
        .accessibilityAddTraits(.isButton)
    }

    private func press() {
        // A second quick tap needs a new up/down edge for XInput polling.
        if releaseTask != nil { release() }
        guard !pressed else { return }
        pressed = true
        pressedAt = ProcessInfo.processInfo.systemUptime
        TouchControllerRuntimeBridge.setButton(source: control.id, mapping: control.mapping, pressed: true)
    }

    private func finishPress() {
        guard pressed else { return }
        let remaining = max(0, 0.10 - (ProcessInfo.processInfo.systemUptime - pressedAt))
        releaseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            release()
        }
    }

    private func release() {
        releaseTask?.cancel()
        releaseTask = nil
        guard pressed else { return }
        pressed = false
        TouchControllerRuntimeBridge.setButton(source: control.id, mapping: control.mapping, pressed: false)
    }
}

private struct TouchControllerTrigger: View {
    let control: TouchControllerControl
    @State private var pressed = false
    @State private var pressedAt = 0.0
    @State private var releaseTask: Task<Void, Never>?

    var body: some View {
        Image(control.mapping.moonlightImageName)
            .resizable()
            .scaledToFit()
            .brightness(pressed ? 0.25 : 0)
        .opacity(control.opacity)
        .contentShape(Rectangle())
        .overlay {
            MoonlightTouchArea(round: true, label: control.mapping.displayName) { phase, _ in
                switch phase {
                case .began:
                    if releaseTask != nil { release() }
                    guard !pressed else { return }
                    pressed = true
                    pressedAt = ProcessInfo.processInfo.systemUptime
                    TouchControllerRuntimeBridge.setTrigger(source: control.id, mapping: control.mapping, value: 1)
                case .moved: break
                case .ended:
                    guard pressed else { return }
                    let remaining = max(0, 0.10 - (ProcessInfo.processInfo.systemUptime - pressedAt))
                    releaseTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(remaining))
                        guard !Task.isCancelled else { return }
                        release()
                    }
                }
            }
        }
        .onDisappear { release() }
        .accessibilityLabel(control.mapping.displayName)
        .accessibilityAddTraits(.isButton)
    }

    private func release() {
        releaseTask?.cancel()
        releaseTask = nil
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
        MoonlightStickArtwork(size: renderedSize, knobOffset: knobOffset)
        .opacity(control.opacity)
        .contentShape(Circle())
        .overlay {
            MoonlightTouchArea(round: true, label: control.mapping.displayName) { phase, location in
                switch phase {
                case .began, .moved: update(location: location)
                case .ended: reset()
                }
            }
        }
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
    @State private var pressedAt = 0.0
    @State private var releaseTask: Task<Void, Never>?

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
        MoonlightDPadArtwork(size: renderedSize)
        .opacity(control.opacity)
        .contentShape(Rectangle())
        .overlay {
            MoonlightTouchArea(round: false, label: "D-Pad") { phase, location in
                switch phase {
                case .began:
                    if releaseTask != nil { releaseAll() }
                    update(location: location)
                case .moved: update(location: location)
                case .ended: finishPress()
                }
            }
        }
        .onDisappear { releaseAll() }
        .accessibilityLabel("D-Pad")
    }

    private func update(location: CGPoint) {
        releaseTask?.cancel()
        releaseTask = nil
        let center = CGPoint(x: renderedSize.width / 2, y: renderedSize.height / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let threshold = min(renderedSize.width, renderedSize.height) * 0.14
        var next = Set<Direction>()
        if dx > threshold { next.insert(.right) }
        if dx < -threshold { next.insert(.left) }
        if dy > threshold { next.insert(.down) }
        if dy < -threshold { next.insert(.up) }

        if directions.isEmpty && !next.isEmpty {
            pressedAt = ProcessInfo.processInfo.systemUptime
        }

        for direction in Direction.allCases where directions.contains(direction) != next.contains(direction) {
            TouchControllerRuntimeBridge.setDPad(source: control.id, mask: direction.mask, pressed: next.contains(direction))
        }
        directions = next
    }

    private func finishPress() {
        guard !directions.isEmpty else { return }
        let remaining = max(0, 0.10 - (ProcessInfo.processInfo.systemUptime - pressedAt))
        releaseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            releaseAll()
        }
    }

    private func releaseAll() {
        releaseTask?.cancel()
        releaseTask = nil
        for direction in directions {
            TouchControllerRuntimeBridge.setDPad(source: control.id, mask: direction.mask, pressed: false)
        }
        directions.removeAll()
    }
}

// Follows the touch-down/move/up pattern in Moonlight iOS OnScreenControls.m.
// This per-control UIView and Iridium's XInput bridge are separate code.
// Copyright (c) 2014 Moonlight Stream. GPL-3.0; see Moonlight-LICENSE.txt.
private enum MoonlightTouchPhase { case began, moved, ended }

@MainActor
private struct MoonlightTouchArea: UIViewRepresentable {
    let round: Bool
    let label: String
    let onEvent: (MoonlightTouchPhase, CGPoint) -> Void

    func makeUIView(context: Context) -> MoonlightTouchView {
        MoonlightTouchView()
    }

    func updateUIView(_ view: MoonlightTouchView, context: Context) {
        view.round = round
        view.accessibilityLabel = label
        view.accessibilityIdentifier = "touchControl-\(label)"
        view.onEvent = onEvent
    }
}

@MainActor
private final class MoonlightTouchView: UIView {
    var round = false
    var onEvent: ((MoonlightTouchPhase, CGPoint) -> Void)?
    private var activeTouches = Set<UITouch>()
    private var primaryTouch: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        isAccessibilityElement = true
        accessibilityTraits = [.button, .allowsDirectInteraction]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard round else { return bounds.contains(point) }
        let x = point.x - bounds.midX
        let y = point.y - bounds.midY
        let radius = min(bounds.width, bounds.height) / 2
        return x * x + y * y <= radius * radius
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.formUnion(touches)
        guard primaryTouch == nil, let touch = touches.first else { return }
        primaryTouch = touch
        onEvent?(.began, touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = primaryTouch, touches.contains(touch) else { return }
        onEvent?(.moved, touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        activeTouches.subtract(touches)
        guard let touch = primaryTouch, touches.contains(touch) else { return }
        if let next = activeTouches.first {
            primaryTouch = next
            onEvent?(.moved, next.location(in: self))
        } else {
            primaryTouch = nil
            onEvent?(.ended, touch.location(in: self))
        }
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
        #if INTERFACE_PREVIEW
        if pressed { NotificationCenter.default.post(name: .init("IridiumPreviewTouchButton"), object: mapping) }
        #endif
        #if MADEIRA_RUNTIME
        MadeiraController.setTouchButton(source: source, mask: mask, pressed: pressed)
        #endif
    }

    static func setDPad(source: UUID, mask: UInt16, pressed: Bool) {
        #if INTERFACE_PREVIEW
        if pressed { NotificationCenter.default.post(name: .init("IridiumPreviewTouchButton"), object: mask) }
        #endif
        #if MADEIRA_RUNTIME
        MadeiraController.setTouchButton(source: source, mask: mask, pressed: pressed)
        #endif
    }

    static func setTrigger(source: UUID, mapping: TouchControllerMapping, value: Float) {
        #if INTERFACE_PREVIEW
        if value > 0 { NotificationCenter.default.post(name: .init("IridiumPreviewTouchButton"), object: mapping) }
        #endif
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
