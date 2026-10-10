// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import GameController
import Combine

@MainActor enum IridiumControlHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    static func press() {
        let generator: UIImpactFeedbackGenerator
        switch IridiumTouchHaptics.current() {
        case .off: return
        case .light: generator = light
        case .medium: generator = medium
        }
        generator.impactOccurred(); generator.prepare()
    }
}

/// Observe availability only; never replace the runtime's GameController handlers.
final class IridiumPhysicalController: ObservableObject {
    static let shared = IridiumPhysicalController()
    @Published private(set) var isActive = false
    @Published var forceTouchVisible = false
    var hidesTouchControls: Bool { isActive && !forceTouchVisible }
    private var observations: [AnyCancellable] = []
    private init() {
        refresh()
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observations.append(NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() })
        }
    }
    func refresh() {
        let active = GCController.controllers().contains { $0.extendedGamepad != nil }
        if active != isActive { forceTouchVisible = false }
        isActive = active
    }
}

enum IridiumControlShape { case round, pill, shoulder }

/// This exact face is used by console controls and the generated Windows overlay.
/// Simple translucent layers avoid the animated-glass press renderer failure.
struct IridiumControlFace: View {
    let label: String
    var symbol: String? = nil
    var shape: IridiumControlShape = .round
    var pressed = false
    var compresses = true
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    private var state: IridiumControlPressState {
        var value = IridiumControlPressState(); value.set(pressed); return value
    }
    private var outline: AnyShape {
        switch shape {
        case .round: return AnyShape(Circle())
        case .pill: return AnyShape(Capsule())
        case .shoulder: return AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                outline.fill(.black.opacity(opaque ? 0.92 : 0.38))
                outline.fill(.white.opacity(state.fillOpacity))
                outline.stroke(.white.opacity(contrast == .increased ? 0.95 : state.strokeOpacity), lineWidth: pressed ? 1.5 : 1)
                Group {
                    if let symbol { Image(systemName: symbol) }
                    else { Text(label).lineLimit(1).minimumScaleFactor(0.65) }
                }
                .font(.system(size: min(21, geo.size.height * (label.count > 2 && symbol == nil ? 0.29 : 0.40)), weight: .semibold))
                .foregroundStyle(.white.opacity(pressed ? 1 : 0.88))
                .padding(.horizontal, 4)
            }
        }
        .scaleEffect(compresses ? state.scale : 1)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

struct IridiumPlayerTouchButton: View {
    let label: String
    var symbol: String? = nil
    var shape: IridiumControlShape = .round
    let enabled: Bool
    let input: (Bool) -> Void
    let accessibilityTap: () -> Void
    @State private var state = IridiumControlPressState()
    var body: some View {
        IridiumControlFace(label: label, symbol: symbol, shape: shape, pressed: state.isDown)
            .overlay {
                IridiumControlTouchSurface(enabled: enabled) { location, size in
                    update(location.map { CGRect(origin: .zero, size: size).contains($0) } ?? false)
                }
            }
            .accessibilityElement().accessibilityLabel(label).accessibilityAddTraits(.isButton)
            .accessibilityAction { guard enabled else { return }; accessibilityTap() }
            .onChange(of: enabled) { _, value in if !value { update(false) } }
            .onDisappear { update(false) }
    }
    private func update(_ down: Bool) {
        if state.set(down && enabled) {
            if state.isDown { IridiumControlHaptics.press() }
            input(state.isDown)
        }
    }
}

struct IridiumPlayerDPad: View {
    let enabled: Bool
    let input: (UInt16) -> Void
    let accessibilityTap: (UInt16) -> Void
    @State private var state = IridiumDirectionControlState()
    private let directions: [(String, String, UInt16, CGFloat, CGFloat)] = [
        ("Up", "arrow.up", 1 << 4, 0, -44), ("Down", "arrow.down", 1 << 5, 0, 44),
        ("Left", "arrow.left", 1 << 6, -44, 0), ("Right", "arrow.right", 1 << 7, 44, 0)]
    var body: some View {
        ZStack {
            ForEach(directions, id: \.0) { item in
                IridiumControlFace(label: item.0, symbol: item.1, shape: .shoulder, pressed: state.bits & item.2 != 0)
                    .frame(width: 44, height: 44).offset(x: item.3, y: item.4)
            }
        }
        .frame(width: 132, height: 132)
        .overlay {
            IridiumControlTouchSurface(enabled: enabled) { location, size in
                update(location.map { IridiumControlGeometry.directions(location: $0, size: size) } ?? 0)
            }
        }
        .accessibilityElement().accessibilityLabel("D-pad")
        .accessibilityHint("Drag to move, including diagonals")
        .accessibilityAction(named: Text("Up")) { pulse(1 << 4) }
        .accessibilityAction(named: Text("Down")) { pulse(1 << 5) }
        .accessibilityAction(named: Text("Left")) { pulse(1 << 6) }
        .accessibilityAction(named: Text("Right")) { pulse(1 << 7) }
        .onChange(of: enabled) { _, value in if !value { update(0) } }
        .onDisappear { update(0) }
    }
    private func pulse(_ bit: UInt16) { guard enabled else { return }; accessibilityTap(bit) }
    private func update(_ value: UInt16) {
        let wasEngaged = state.bits != 0
        if let next = state.update(enabled ? value : 0) {
            if !wasEngaged && next != 0 { IridiumControlHaptics.press() }
            input(next)
        }
    }
}

/// Shared by native Windows sticks, keyboard-mapped sticks, and console analog input.
struct IridiumStickFace: View {
    let vector: CGPoint
    var pressed = false
    var symbol: String? = nil
    var body: some View {
        GeometryReader { geo in
            ZStack {
                IridiumControlFace(label: "", pressed: pressed, compresses: false)
                Circle().fill(.white.opacity(pressed ? 0.76 : 0.42))
                    .frame(width: geo.size.width * 0.42, height: geo.size.height * 0.42)
                    .overlay { if let symbol { Image(systemName: symbol).font(.caption).foregroundStyle(.black.opacity(0.7)) } }
                    .offset(x: vector.x * geo.size.width * 0.28, y: -vector.y * geo.size.height * 0.28)
            }
        }.transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

struct IridiumPlayerStick: View {
    let enabled: Bool
    let input: (Int16, Int16) -> Void
    @State private var vector = CGPoint.zero
    @State private var haptic = IridiumControlHapticTransition()
    var body: some View {
        IridiumStickFace(vector: vector, pressed: vector != .zero)
            .overlay {
                IridiumControlTouchSurface(enabled: enabled) { location, size in
                    update(location.map { IridiumControlGeometry.stick(location: $0, size: size) } ?? .zero)
                }
            }
        .accessibilityElement().accessibilityLabel("Left analog stick")
        .accessibilityHint("Drag in any direction. Release to center. Actions hold a direction until Center is chosen.")
        .accessibilityAction(named: Text("Up")) { update(CGPoint(x: 0, y: 1)) }
        .accessibilityAction(named: Text("Down")) { update(CGPoint(x: 0, y: -1)) }
        .accessibilityAction(named: Text("Left")) { update(CGPoint(x: -1, y: 0)) }
        .accessibilityAction(named: Text("Right")) { update(CGPoint(x: 1, y: 0)) }
        .accessibilityAction(named: Text("Center")) { update(.zero) }
        .onChange(of: enabled) { _, value in if !value { update(.zero) } }
        .onDisappear { update(.zero) }
    }
    private func update(_ value: CGPoint) {
        vector = enabled ? value : .zero
        if haptic.update(vector != .zero) { IridiumControlHaptics.press() }
        input(Int16((vector.x * 32767).rounded()), Int16((vector.y * 32767).rounded()))
    }
}

/// Each control owns one UIKit touch, supporting simultaneous controls and cancellation.
/// No enclosing scroll recognizer or minimum-duration gesture delays touch-down.
struct IridiumControlTouchSurface: UIViewRepresentable {
    let enabled: Bool
    let changed: (CGPoint?, CGSize) -> Void
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.changed = changed
        if !enabled { view.release() }
        view.isUserInteractionEnabled = enabled
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.release() }
    final class Surface: UIView {
        var changed: ((CGPoint?, CGSize) -> Void)?
        private var tracking: UITouch?
        override init(frame: CGRect) {
            super.init(frame: frame); backgroundColor = .clear; isMultipleTouchEnabled = false
            NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
                name: UIApplication.willResignActiveNotification, object: nil)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { release() } }
        @objc private func interrupted() { release() }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard tracking == nil, let touch = touches.first else { return }
            tracking = touch; changed?(touch.location(in: self), bounds.size)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = tracking, touches.contains(touch) else { return }
            changed?(touch.location(in: self), bounds.size)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release() }
        func release() {
            guard tracking != nil else { return }
            tracking = nil; changed?(nil, bounds.size)
        }
    }
}

struct IridiumControlFeedbackSettings: View {
    @AppStorage(IridiumTouchHaptics.settingsKey) private var feedback = IridiumTouchHaptics.light.rawValue
    var body: some View {
        Picker("Touch feedback", selection: $feedback) {
            Text("Off").tag(IridiumTouchHaptics.off.rawValue)
            Text("Light").tag(IridiumTouchHaptics.light.rawValue)
            Text("Medium").tag(IridiumTouchHaptics.medium.rawValue)
        }
        Text("A short tap when a control engages. Holding a button or moving a stick won’t repeatedly vibrate.")
            .font(.caption).foregroundStyle(.secondary)
    }
}


/// A scalable face for the editor's composite, eight-way D-pad. The touch
/// adapter remains the same per-control surface used by all console buttons.
struct IridiumDPadFace: View {
    var vector: CGSize = .zero
    var pressed = false
    private let directions: [(String, String, CGFloat, CGFloat)] = [
        ("Up", "arrow.up", 0, -1), ("Down", "arrow.down", 0, 1),
        ("Left", "arrow.left", -1, 0), ("Right", "arrow.right", 1, 0)]
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height) / 3
            ZStack {
                ForEach(directions, id: \.0) { item in
                    let down = pressed && (item.2 == 0 ? vector.height * item.3 > 0 : vector.width * item.2 > 0)
                    IridiumControlFace(label: item.0, symbol: item.1, shape: .shoulder,
                                       pressed: down, compresses: false)
                        .frame(width: side, height: side)
                        .offset(x: item.2 * side, y: item.3 * side)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.allowsHitTesting(false)
    }
}
