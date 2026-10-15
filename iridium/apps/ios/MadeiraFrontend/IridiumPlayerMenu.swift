// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UIKit

struct IridiumMovablePlayerMenu: View {
    let action: () -> Void
    var safeAreaInsets: EdgeInsets? = nil
    @AppStorage("madeiraLibraryMenuX") private var x = 0.92
    @AppStorage("madeiraLibraryMenuY") private var y = 0.12
    @GestureState private var translation = CGSize.zero
    var body: some View {
        GeometryReader { geometry in
            let center = position(in: geometry, translation: translation)
            IridiumPlayerMenuButton(action: action)
                .frame(width: 48, height: 48)
                .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global).updating($translation) { value, state, transaction in
                    transaction.animation = nil
                    state = value.translation
                }.onEnded { value in
                    let end = position(in: geometry, translation: value.translation)
                    x = end.x / max(1, geometry.size.width)
                    y = end.y / max(1, geometry.size.height)
                })
                .position(center)
        }
    }
    private func position(in geometry: GeometryProxy, translation: CGSize) -> CGPoint {
        let size = geometry.size
        let insets = safeAreaInsets ?? geometry.safeAreaInsets
        return IridiumMenuPlacement.center(normalized: CGPoint(x: x + translation.width / max(1, size.width),
            y: y + translation.height / max(1, size.height)), size: size,
            leading: insets.leading, trailing: insets.trailing,
            top: insets.top, bottom: insets.bottom)
    }
}

/// A native target keeps its accessibility bounds at the visible button even
/// when the surrounding HUD fills a separate window above a native renderer.
struct IridiumPlayerMenuButton: UIViewRepresentable {
    var visible = true
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> UIButton {
        let button = MenuTarget(type: .custom)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)), for: .normal)
        button.tintColor = .white
        button.backgroundColor = .black.withAlphaComponent(0.72)
        button.layer.cornerRadius = 24
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.55).cgColor
        button.accessibilityLabel = "Game menu"
        button.accessibilityHint = "Drag to move"
        button.addAction(UIAction { _ in context.coordinator.action() }, for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        button.isHidden = !visible
        button.isUserInteractionEnabled = visible
    }
    final class MenuTarget: UIButton {
        private var dimming: DispatchWorkItem?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            dimming?.cancel()
            guard window != nil else { return }
            restoreVisibility()
        }
        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            restoreVisibility()
            return super.beginTracking(touch, with: event)
        }
        private func restoreVisibility() {
            dimming?.cancel()
            layer.removeAllAnimations()
            alpha = 1
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.window != nil else { return }
                UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.35) { self.alpha = 0.55 }
            }
            dimming = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
        deinit {
            dimming?.cancel()
        }
        override var accessibilityFrame: CGRect {
            get { UIAccessibility.convertToScreenCoordinates(bounds, in: self) }
            set { }
        }
    }
    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }
}

struct IridiumPlayerMenuHeader: View {
    let title: String
    var subtitle: String? = nil
    var back: (() -> Void)? = nil
    let done: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            if let back {
                Button("Back", systemImage: "chevron.left", action: back)
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
            }
            Spacer(minLength: 8)
            Button("Done", action: done).frame(minWidth: 44, minHeight: 44)
        }
    }
}

struct IridiumPlayerMenuRow: View {
    let title: String
    let symbol: String
    var selected = false
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 12)
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .background(selected ? Color.white.opacity(0.16) : Color.white.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }.buttonStyle(.plain).id(title)
    }
}


struct IridiumPlayerCloseConfirmation: View {
    let selection: String
    var message = "The runtime will close and save supported game data. Unsaved in-game progress may be lost."
    let cancel: () -> Void
    let close: () -> Void
    let command: (String) -> Void
    @FocusState private var keyboard: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.65).ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Close this game?").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                            Text(message).font(.subheadline)
                            IridiumPlayerMenuRow(title: "Cancel", symbol: "arrow.uturn.backward",
                                                 selected: selection == "Cancel", action: cancel)
                            IridiumPlayerMenuRow(title: "Close Game", symbol: "stop.circle",
                                                 selected: selection == "Close Game", destructive: true, action: close)
                        }.padding(22)
                    }.onChange(of: selection) { _, title in proxy.scrollTo(title, anchor: .center) }
                }.frame(maxWidth: 420, maxHeight: min(420, max(0, geometry.size.height - 32)))
                    .modifier(IridiumGlassSurface(radius: 28)).padding(16)
            }
        }.accessibilityAddTraits(.isModal)
            .focusable().focusEffectDisabled().focused($keyboard)
            .onAppear { keyboard = true }
            .onKeyPress(.escape, phases: .down) { _ in command("back"); return .handled }
            .onKeyPress(.return, phases: .down) { _ in command("accept"); return .handled }
            .onKeyPress(.upArrow) { command("up"); return .handled }
            .onKeyPress(.downArrow) { command("down"); return .handled }
            .onKeyPress(.leftArrow) { command("left"); return .handled }
            .onKeyPress(.rightArrow) { command("right"); return .handled }
    }
}

/// The session's common actions come from one definition for every runtime.
struct IridiumSessionMenuActions: View {
    var windows = false
    var focused: String?
    let activate: (String) -> Void
    static func items(windows: Bool) -> [(String, String)] {
        var rows = [("Resume", "play.fill"), ("Controls", "gamecontroller"), ("View Log", "doc.text")]
        if windows {
            rows += [("Performance", "chart.xyaxis.line"), ("Advanced", "slider.horizontal.3"), ("Show Device Keyboard", "keyboard")]
        } else { rows += [("Help", "questionmark.circle")] }
        return rows
    }
    var body: some View {
        ForEach(Self.items(windows: windows), id: \.0) { title, icon in
            IridiumPlayerMenuRow(title: title, symbol: icon, selected: focused == title) { activate(title) }
        }
    }
}
