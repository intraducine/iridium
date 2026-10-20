// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CoreGraphics

/// Setup owns only its visible page. Routing never activates a replacement for a removed control.
struct SetupControllerTarget: Equatable {
    enum Role { case control, back, next, skip }
    let id: String
    let page: String
    let order: Int
    let frame: CGRect
    let enabled: Bool
    var role = Role.control
    let action: () -> Void
    var adjust: ((Int) -> Void)?
    var reveal: () -> Void = {}
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.page == rhs.page && lhs.order == rhs.order && lhs.frame == rhs.frame
            && lhs.enabled == rhs.enabled && lhs.role == rhs.role && (lhs.adjust != nil) == (rhs.adjust != nil)
    }
}

/// A registration keeps this identity while each committed view refreshes its current Binding callbacks.
/// Updating callbacks does not publish state or invalidate geometry preferences.
final class SetupControllerCallbacks {
    private var enabled = false
    private var action: () -> Void = {}
    private var adjustment: ((Int) -> Void)?
    func update(enabled: Bool, action: @escaping () -> Void, adjust: ((Int) -> Void)?) {
        self.enabled = enabled; self.action = action; adjustment = adjust
    }
    func activate() { if enabled { action() } }
    func adjust(_ direction: Int) { if enabled { adjustment?(direction) } }
}

struct SetupControllerPolicy {
    private(set) var page = "library"
    private(set) var selected: String?
    private(set) var visible = false
    private var targets: [SetupControllerTarget] = []
    var available: [SetupControllerTarget] {
        targets.filter { $0.page == page && $0.enabled }.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return abs($0.frame.minY - $1.frame.minY) < 4 ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
    }
    mutating func update(_ targets: [SetupControllerTarget], page: String) {
        if self.page != page { selected = nil }
        self.page = page
        self.targets = targets
        if !available.contains(where: { $0.id == selected }) { selected = nil }
    }
    mutating func hide() { visible = false }
    mutating func receive(_ command: String, suspended: Bool, back: () -> Void) {
        guard !suspended, ["up", "down", "left", "right", "accept", "back"].contains(command) else { return }
        visible = true
        if command == "back" { back(); return }
        let rows = available
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selected }
        if command == "left" || command == "right" {
            let direction = command == "left" ? -1 : 1
            if let index, let adjust = rows[index].adjust { adjust(direction) }
            else if let footer = rows.first(where: { $0.role == (direction < 0 ? .back : .next) }) {
                selected = footer.id; footer.reveal()
            }
        } else if command == "accept", let index {
            rows[index].action()
        } else {
            let next = index.map { max(0, min(rows.count - 1, $0 + (command == "up" ? -1 : 1))) }
                ?? (command == "up" ? rows.count - 1 : 0)
            selected = rows[next].id
            rows[next].reveal()
        }
    }
    static func cycled<Value: Equatable>(_ value: Value, in values: [Value], direction: Int) -> Value {
        guard !values.isEmpty else { return value }
        let index = values.firstIndex(of: value) ?? 0
        return values[(index + (direction < 0 ? values.count - 1 : 1)) % values.count]
    }
}

// MARK: - SwiftUI registration and the existing scroll-view reveal mechanism
import SwiftUI

@MainActor final class SetupControllerFocus: ObservableObject {
    @Published private(set) var policy = SetupControllerPolicy()
    @Published var sharing = false
    private var targets: [SetupControllerTarget] = []
    func update(_ targets: [SetupControllerTarget], page: String) {
        self.targets = targets
        var next = policy; next.update(targets, page: page)
        if next.selected != policy.selected || next.page != policy.page { policy = next }
        else { policy.update(targets, page: page) }
    }
    func receive(_ command: String, page: String, suspended: Bool, back: () -> Void) {
        var next = policy; next.update(targets, page: page)
        next.receive(command, suspended: suspended || sharing, back: back)
        policy = next
    }
    func hide() {
        guard policy.visible else { return }
        policy.hide()
    }
    func clear() { targets = []; policy = SetupControllerPolicy(); sharing = false }
}

private struct SetupControllerFocusKey: EnvironmentKey { static let defaultValue: SetupControllerFocus? = nil }
private struct SetupControllerPageKey: EnvironmentKey { static let defaultValue = "library" }
extension EnvironmentValues {
    var setupControllerFocus: SetupControllerFocus? {
        get { self[SetupControllerFocusKey.self] }
        set { self[SetupControllerFocusKey.self] = newValue }
    }
    var setupControllerPage: String {
        get { self[SetupControllerPageKey.self] }
        set { self[SetupControllerPageKey.self] = newValue }
    }
}
struct SetupControllerTargetsKey: PreferenceKey {
    static let defaultValue: [SetupControllerTarget] = []
    static func reduce(value: inout [SetupControllerTarget], nextValue: () -> [SetupControllerTarget]) { value += nextValue() }
}
private struct SetupControllerProbe: UIViewRepresentable {
    let view: UIView
    let callbacks: SetupControllerCallbacks
    let enabled: Bool
    let action: () -> Void
    let adjust: ((Int) -> Void)?
    func makeUIView(context: Context) -> UIView {
        callbacks.update(enabled: enabled, action: action, adjust: adjust)
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        callbacks.update(enabled: enabled, action: action, adjust: adjust)
    }
}
@MainActor private func revealSetupControl(_ view: UIView) {
    var parent = view.superview
    while let node = parent {
        if let scroll = node as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
            scroll.scrollRectToVisible(view.convert(view.bounds, to: scroll).insetBy(dx: 0, dy: -24), animated: true)
            return
        }
        parent = node.superview
    }
}
private struct SetupControllerItem<Content: View>: View {
    let content: Content
    let id: String
    let order: Int
    let role: SetupControllerTarget.Role
    let action: () -> Void
    let adjust: ((Int) -> Void)?
    @ObservedObject var focus: SetupControllerFocus
    @Environment(\.setupControllerPage) private var page
    @Environment(\.isEnabled) private var enabled
    @State private var probe = UIView()
    @State private var callbacks = SetupControllerCallbacks()
    var body: some View {
        let selected = focus.policy.visible && focus.policy.page == page && focus.policy.selected == id
        content
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(IridiumTheme.accent, lineWidth: selected ? 3 : 0).allowsHitTesting(false) }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: SetupControllerTargetsKey.self, value: [SetupControllerTarget(
                        id: id, page: page, order: order, frame: geometry.frame(in: .global), enabled: enabled,
                        role: role, action: callbacks.activate, adjust: adjust == nil ? nil : callbacks.adjust,
                        reveal: { revealSetupControl(probe) })])
                }
            }
            .background(SetupControllerProbe(view: probe, callbacks: callbacks, enabled: enabled, action: action, adjust: adjust))
            .simultaneousGesture(TapGesture().onEnded { focus.hide() })
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
private struct SetupControllerFocusable: ViewModifier {
    let id: String
    let order: Int
    let role: SetupControllerTarget.Role
    let action: () -> Void
    let adjust: ((Int) -> Void)?
    @Environment(\.setupControllerFocus) private var focus
    @ViewBuilder func body(content: Content) -> some View {
        if let focus { SetupControllerItem(content: content, id: id, order: order, role: role, action: action, adjust: adjust, focus: focus) }
        else { content }
    }
}
extension View {
    func setupControllerTarget(_ id: String, order: Int, role: SetupControllerTarget.Role = .control,
                               action: @escaping () -> Void, adjust: ((Int) -> Void)? = nil) -> some View {
        modifier(SetupControllerFocusable(id: id, order: order, role: role, action: action, adjust: adjust))
    }
    func setupControllerValue<Value: Equatable>(_ id: String, order: Int, selection: Binding<Value>, values: [Value]) -> some View {
        let change: (Int) -> Void = { selection.wrappedValue = SetupControllerPolicy.cycled(selection.wrappedValue, in: values, direction: $0) }
        return setupControllerTarget(id, order: order, action: { change(1) }, adjust: change)
    }
    func setupControllerToggle(_ id: String, order: Int, value: Binding<Bool>) -> some View {
        setupControllerTarget(id, order: order, action: { value.wrappedValue.toggle() }, adjust: { value.wrappedValue = $0 > 0 })
    }
}

struct SetupControllerLink: View {
    let title: String
    let destination: URL
    let id: String
    let order: Int
    @Environment(\.openURL) private var openURL
    init(_ title: String, destination: URL, id: String, order: Int) {
        self.title = title; self.destination = destination; self.id = id; self.order = order
    }
    var body: some View {
        Link(title, destination: destination).setupControllerTarget(id, order: order, action: { openURL(destination) })
    }
}

/// Both touch and controller present the same real share sheet; its lifetime suspends Setup routing.
struct SetupControllerShare: View {
    let title: String
    let url: URL
    let id: String
    let order: Int
    @State private var presented = false
    @Environment(\.setupControllerFocus) private var focus
    private func share() { focus?.sharing = true; presented = true }
    var body: some View {
        Button(action: share) { Label(title, systemImage: "square.and.arrow.up") }
            .setupControllerTarget(id, order: order, action: share)
            .sheet(isPresented: $presented, onDismiss: { focus?.sharing = false }) {
                ActivitySheet(items: [url]).environment(\.setupControllerFocus, nil)
            }
    }
}

/// Preview-only command-bus harness. These controls never substitute for Setup actions.
struct SetupControllerReviewPad: ViewModifier {
    @ObservedObject var focus: SetupControllerFocus
    let suspended: Bool
    @ViewBuilder func body(content: Content) -> some View {
        #if IRIDIUM_UX_PREVIEW
        if Bundle.main.bundleIdentifier == "software.iridium.uipreview",
           ProcessInfo.processInfo.arguments.contains("--setup-controller-review") {
            content.safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 4) {
                    Text("Controller QA · \(focus.policy.selected ?? "none")")
                        .font(.caption2).accessibilityIdentifier("setupControllerSelection")
                        .accessibilityValue(focus.policy.selected ?? "none")
                    Text(focus.policy.available.map(\.id).joined(separator: ","))
                        .font(.system(size: 8)).lineLimit(1).accessibilityIdentifier("setupControllerTargets")
                        .accessibilityValue(focus.policy.available.map(\.id).joined(separator: ","))
                    HStack {
                        ForEach(["up", "down", "left", "right", "accept", "back"], id: \.self) { command in
                            Button(command == "accept" ? "A" : command == "back" ? "B" : command.capitalized) {
                                LibraryController.shared.commands.send(command)
                            }.font(.caption).accessibilityIdentifier("setupCommand.\(command)")
                        }
                    }
                    Text(suspended ? "Suspended" : "Active").font(.system(size: 8))
                        .accessibilityIdentifier("setupControllerSuspension")
                }.padding(4).frame(maxWidth: .infinity).background(.black)
            }
        } else { content }
        #else
        content
        #endif
    }
}
