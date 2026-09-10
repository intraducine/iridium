import SwiftUI
import GameController
import Combine

/// Reads menu input without replacing the runtime's controller handlers.
@MainActor final class LibraryController: ObservableObject {
    @Published private(set) var connected = false
    @Published var showingControllerHints = false
    @Published var libraryNavigationActive = false
    @Published var nativeMenuActive = false
    @Published var backAction: (() -> Void)?
    enum Input: Int { case left, right, up, down, select, back, play, search, previousTab, nextTab, options }
    let input = PassthroughSubject<Input, Never>()
    @Published private(set) var activeMenuID: UUID?
    var hasMenuScope: Bool { activeMenuID != nil }
    private var menuHandlers: [(UUID, (Input) -> Void)] = []
    func pushMenu(id: UUID, handler: @escaping (Input) -> Void) {
        menuHandlers.removeAll { $0.0 == id }; menuHandlers.append((id, handler)); activeMenuID = id
    }
    func popMenu(id: UUID) { menuHandlers.removeAll { $0.0 == id }; activeMenuID = menuHandlers.last?.0 }
    private var held = Set<Int>()
    private var device: ObjectIdentifier?
    private var stickDirection: Int?
    private var repeatingDirection: Int?
    private var nextRepeat: TimeInterval = 0
    func poll() {
        guard !nativeMenuActive else { held = []; stickDirection = nil; repeatingDirection = nil; return }
        let controller = GCController.current ?? GCController.controllers().first
        let detected = controller?.extendedGamepad != nil
        if connected != detected { connected = detected }
        guard let controller, let pad = controller.extendedGamepad else { held = []; device = nil; stickDirection = nil; repeatingDirection = nil; showingControllerHints = false; return }
        if device != ObjectIdentifier(controller) { held = []; stickDirection = nil; repeatingDirection = nil }
        let buttons = [
            pad.dpad.left.isPressed, pad.dpad.right.isPressed,
            pad.dpad.up.isPressed, pad.dpad.down.isPressed,
            pad.buttonA.isPressed, pad.buttonB.isPressed,
            pad.buttonX.isPressed, pad.buttonY.isPressed,
            pad.leftShoulder.isPressed, pad.rightShoulder.isPressed, pad.buttonMenu.isPressed
        ]
        let pressed = Set(buttons.indices.filter { buttons[$0] })
        device = ObjectIdentifier(controller)
        process(pressed: pressed, stickX: pad.leftThumbstick.xAxis.value, stickY: pad.leftThumbstick.yAxis.value)
    }
    func process(pressed buttons: Set<Int>, stickX: Float = 0, stickY: Float = 0,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        var pressed = buttons
        let magnitude = max(abs(stickX), abs(stickY))
        if magnitude < 0.3 { stickDirection = nil }
        else if magnitude >= 0.55 {
            stickDirection = abs(stickX) >= abs(stickY) ? (stickX < 0 ? 0 : 1) : (stickY > 0 ? 2 : 3)
        }
        if !pressed.contains(where: { $0 < 4 }), let stickDirection { pressed.insert(stickDirection) }
        defer { held = pressed }
        let newlyPressed = pressed.subtracting(held)
        for index in newlyPressed.sorted() {
            if let action = Input(rawValue: index) { send(action) }
        }
        let direction = pressed.filter { $0 < 4 }.sorted().first
        if direction != repeatingDirection {
            repeatingDirection = direction
            nextRepeat = now + 0.4
        } else if let direction, now >= nextRepeat {
            send(Input(rawValue: direction)!)
            nextRepeat = now + 0.12
        }
    }
    func send(_ action: Input) {
        guard !nativeMenuActive else { return }
        showingControllerHints = true
        print("[IridiumUI] controller: \(action)")
        if let handler = menuHandlers.last?.1 { handler(action) }
        else { input.send(action) }
    }
}

/// Let UIKit handle controller navigation in native forms and settings.
struct ControllerMenuHost<Content: View>: UIViewControllerRepresentable {
    var nativeNavigation: Bool
    var backAction: (() -> Void)? = nil
    var fullScreen = false
    @ViewBuilder var content: () -> Content
    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        let child = Hosting(rootView: content())
        if fullScreen { child.safeAreaRegions = [.keyboard] }
        host.addChild(child)
        host.view.backgroundColor = .clear
        child.view.backgroundColor = .clear
        host.view.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: host.view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor)
        ])
        child.didMove(toParent: host)
        host.child = child
        host.child?.backAction = backAction
        host.controllerUserInteractionEnabled = nativeNavigation
        return host
    }
    func updateUIViewController(_ host: Host, context: Context) {
        withTransaction(context.transaction) { host.child?.rootView = content() }
        host.child?.backAction = backAction
        host.controllerUserInteractionEnabled = nativeNavigation
    }
    final class Host: GCEventViewController { var child: Hosting? }
    final class Hosting: UIHostingController<Content> {
        var backAction: (() -> Void)?
        override var canBecomeFirstResponder: Bool { true }
        override var keyCommands: [UIKeyCommand]? {
            guard backAction != nil else { return super.keyCommands }
            let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeMenu))
            command.wantsPriorityOverSystemBehavior = true
            return (super.keyCommands ?? []) + [command]
        }
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if presses.contains(where: { $0.key?.keyCode == .keyboardEscape || $0.type == .menu }), let backAction {
                backAction()
                return
            }
            super.pressesBegan(presses, with: event)
        }
        @objc private func closeMenu() { backAction?() }
    }
}

private struct MenuControllerKey: EnvironmentKey { static let defaultValue: LibraryController? = nil }
private struct MenuFocusKey: EnvironmentKey { static let defaultValue: MenuFocus? = nil }
extension EnvironmentValues {
    var menuController: LibraryController? {
        get { self[MenuControllerKey.self] }
        set { self[MenuControllerKey.self] = newValue }
    }
    fileprivate var menuFocus: MenuFocus? {
        get { self[MenuFocusKey.self] }
        set { self[MenuFocusKey.self] = newValue }
    }
}

private struct MenuItem: Equatable {
    let id: UUID
    let frame: CGRect
    let enabled: Bool
    let action: () -> Void
    var reveal: ((Int) -> Void)? = nil
    var adjust: ((Int) -> Void)? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.frame == rhs.frame && lhs.enabled == rhs.enabled
    }
}
private struct MenuItemsKey: PreferenceKey {
    static let defaultValue: [MenuItem] = []
    static func reduce(value: inout [MenuItem], nextValue: () -> [MenuItem]) { value += nextValue() }
}
@MainActor private final class MenuFocus: ObservableObject {
    @Published var selected: UUID?
    @Published var visible = false
    var items: [MenuItem] = []
    var rememberedIndex = 0
    var pendingDirection = 0
    var endEditing: (() -> Bool)?
    func receive(_ input: LibraryController.Input) {
        pendingDirection = 0
        visible = true
        let rows = items.filter(\.enabled).sorted {
            abs($0.frame.minY - $1.frame.minY) < 4 ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selected } ?? min(rememberedIndex, rows.count - 1)
        switch input {
        case .up: pendingDirection = index == 0 ? -1 : 0; rememberedIndex = max(0, index - 1); selected = rows[rememberedIndex].id; rows[rememberedIndex].reveal?(index == 0 ? -1 : 0)
        case .down: pendingDirection = index == rows.count - 1 ? 1 : 0; rememberedIndex = min(rows.count - 1, index + 1); selected = rows[rememberedIndex].id; rows[rememberedIndex].reveal?(index == rows.count - 1 ? 1 : 0)
        case .left: rows[index].adjust?(-1)
        case .right: rows[index].adjust?(1)
        case .select: rememberedIndex = index; rows[index].action()
        default: break
        }
    }
}
private struct MenuFocusItem<Content: View>: View {
    let content: Content
    @ObservedObject var focus: MenuFocus
    let action: () -> Void
    let adjust: ((Int) -> Void)?
    @Environment(\.isEnabled) private var enabled
    @State private var id = UUID()
    @State private var rowView = UIView()
    var body: some View {
        let rowProbe = rowView
        return content
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(focus.visible && focus.selected == id ? 0.16 : 0))
                    .padding(.horizontal, -8).padding(.vertical, -3)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: MenuItemsKey.self, value: [MenuItem(id: id, frame: geometry.frame(in: .global), enabled: enabled, action: action, reveal: { direction in revealMenuRow(rowProbe, direction: direction) }, adjust: adjust)])
                }
            }
            .background(MenuRowProbe(view: rowView))
            .id(id)
            .accessibilityAddTraits(focus.visible && focus.selected == id ? [.isSelected] : [])
    }
}
private struct MenuFocusable: ViewModifier {
    @Environment(\.menuFocus) private var focus
    var action: () -> Void = {}
    var adjust: ((Int) -> Void)? = nil
    @ViewBuilder func body(content: Content) -> some View {
        if let focus { MenuFocusItem(content: content, focus: focus, action: action, adjust: adjust) }
        else { content }
    }
}
private struct ControllerMenuScope: ViewModifier {
    var onBack: (() -> Void)? = nil
    @Environment(\.menuController) private var controller
    @Environment(\.dismiss) private var dismiss
    @StateObject private var focus = MenuFocus()
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
                .environment(\.menuFocus, focus)
                .onPreferenceChange(MenuItemsKey.self) { items in
                    focus.items = items
                    if focus.pendingDirection != 0, let selected = focus.selected,
                       let current = items.first(where: { $0.id == selected }) {
                        let direction = focus.pendingDirection
                        let candidates = items.filter { $0.enabled && (direction > 0 ? $0.frame.minY > current.frame.minY + 4 : $0.frame.minY < current.frame.minY - 4) }
                        if let next = candidates.min(by: { abs($0.frame.minY - current.frame.minY) < abs($1.frame.minY - current.frame.minY) }) {
                            focus.pendingDirection = 0
                            focus.selected = next.id
                            next.reveal?(0)
                        }
                    }
                    if focus.selected == nil {
                        focus.selected = items.filter(\.enabled).min(by: { $0.frame.minY < $1.frame.minY })?.id
                    }
                }
                .onAppear {
                    focus.visible = controller?.showingControllerHints == true
                    controller?.pushMenu(id: id) { input in
                        if input == .back {
                            if focus.endEditing?() != true { if let onBack { onBack() } else { dismiss() } }
                        } else { focus.receive(input) }
                    }
                }
                .onDisappear { controller?.popMenu(id: id) }
                .onKeyPress(.upArrow) { guard focus.endEditing == nil else { return .ignored }; focus.receive(.up); return .handled }
                .onKeyPress(.downArrow) { guard focus.endEditing == nil else { return .ignored }; focus.receive(.down); return .handled }
                .onKeyPress(.leftArrow) { guard focus.endEditing == nil else { return .ignored }; focus.receive(.left); return .handled }
                .onKeyPress(.rightArrow) { guard focus.endEditing == nil else { return .ignored }; focus.receive(.right); return .handled }
                .onKeyPress(.return) { guard focus.endEditing == nil else { return .ignored }; focus.receive(.select); return .handled }
                .onKeyPress(.escape) { if focus.endEditing?() != true { if let onBack { onBack() } else { dismiss() } }; return .handled }

        .transformPreference(MenuItemsKey.self) { $0 = [] }
#if INTERFACE_PREVIEW
        .overlay(alignment: .bottom) {
            if ProcessInfo.processInfo.arguments.contains("--controller"), let controller {
                ControllerTestPad(controller: controller, scopeID: id)
            }
        }
#endif
    }
}
extension View {
    func menuFocusable(action: @escaping () -> Void = {}, adjust: ((Int) -> Void)? = nil) -> some View {
        modifier(MenuFocusable(action: action, adjust: adjust))
    }
    func controllerMenuScope(onBack: (() -> Void)? = nil) -> some View { modifier(ControllerMenuScope(onBack: onBack)) }
}

struct MenuButton<Label: View>: View {
    var role: ButtonRole? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.menuFocus) private var focus
    @Environment(\.menuController) private var controller
    var body: some View {
        Button(role: role, action: {
            focus?.visible = false
            controller?.showingControllerHints = false
            action()
        }, label: label).menuFocusable(action: action)
    }
}
extension MenuButton where Label == Text {
    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.role = role; self.action = action; label = { Text(title) }
    }
}
extension MenuButton where Label == SwiftUI.Label<Text, Image> {
    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.action = action; label = { SwiftUI.Label(title, systemImage: systemImage) }
    }
}
struct MenuNavigationLink<Destination: View, Label: View>: View {
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label
    @State private var presented = false
    var body: some View {
        NavigationLink(isActive: $presented, destination: destination, label: label)
            .menuFocusable(action: { presented = true })
    }
}
extension MenuNavigationLink where Label == Text {
    init(_ title: String, @ViewBuilder destination: @escaping () -> Destination) {
        self.destination = destination; label = { Text(title) }
    }
}
struct MenuToggle: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    var body: some View { Toggle(title, isOn: $isOn).menuFocusable(action: { isOn.toggle() }, adjust: { isOn = $0 > 0 }) }
}
struct MenuTextField: View {
    let title: String
    @Binding var text: String
    var secure = false
    @FocusState private var editing: Bool
    @Environment(\.menuFocus) private var focus
    init(_ title: String, text: Binding<String>, secure: Bool = false) { self.title = title; _text = text; self.secure = secure }
    var body: some View {
        let fieldFocus = $editing
        return Group {
            if secure { SecureField(title, text: $text) }
            else { TextField(title, text: $text) }
        }.focused($editing)
            .menuFocusable(action: { fieldFocus.wrappedValue = true })
            .onChange(of: editing) { _, editing in
                if editing { focus?.endEditing = { fieldFocus.wrappedValue = false; return true } }
                else { focus?.endEditing = nil }
            }
    }
}
struct MenuValue: View {
    let title: String
    let value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View { LabeledContent(title, value: value).menuFocusable() }
}
struct ControllerHelp: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                Label { Text("Select") } icon: { ControllerFaceButton(position: 0) }
                Label { Text("Back") } icon: { ControllerFaceButton(position: 3) }
                Label("Move", systemImage: "dpad")
                Image(systemName: "l.joystick")
            }
            HStack(spacing: 18) {
                Label { Text("Select") } icon: { ControllerFaceButton(position: 0) }
                Label { Text("Back") } icon: { ControllerFaceButton(position: 3) }
                Label("Move", systemImage: "dpad")
            }
        }.font(.footnote).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity).frame(minHeight: 36)
    }
}

struct ControllerFaceButton: View {
    let position: Int
    var body: some View {
        ZStack {
            ForEach(0..<4) { index in
                Circle().fill(.primary.opacity(index == position ? 1 : 0.25))
                    .frame(width: 6, height: 6)
                    .offset(x: index == 1 ? -7 : index == 3 ? 7 : 0,
                            y: index == 0 ? 7 : index == 2 ? -7 : 0)
            }
        }.frame(width: 22, height: 22).accessibilityHidden(true)
    }
}

private struct MenuRowProbe: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view.isUserInteractionEnabled = false; return view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
@MainActor private func revealMenuRow(_ view: UIView, direction: Int) {
    var parent = view.superview
    while let node = parent {
        if let scroll = node as? UIScrollView {
            if direction != 0 {
                let maximum = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                let y = min(maximum, max(-scroll.adjustedContentInset.top, scroll.contentOffset.y + CGFloat(direction) * max(60, view.bounds.height)))
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: true)
            } else {
                scroll.scrollRectToVisible(view.convert(view.bounds, to: scroll).insetBy(dx: 0, dy: -40), animated: true)
            }
            return
        }
        parent = node.superview
    }
}
