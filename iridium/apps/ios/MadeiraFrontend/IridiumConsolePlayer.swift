// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import AVFoundation

struct IridiumConsolePlayer: View {
    @ObservedObject private var session = IridiumConsoleSession.shared
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var keyboardFocus: Bool
    private let keys: [String: UInt16] = ["z": 1 << 8, "x": 1, " ": 1 << 2, "\r": 1 << 3]

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                HStack {
                    Text(session.game?.title ?? "Game").font(.headline).lineLimit(1)
                    Spacer()
                    if session.phase == .restartRequired {
                        Button("Library") { session.returnToLibraryAfterTimeout() }
                    }
                    Button(session.phase == .paused ? "Resume" : "Pause",
                           systemImage: session.phase == .paused ? "play.fill" : "pause.fill") {
                        if session.phase == .paused { session.resume() } else { session.pause() }
                    }.disabled(session.phase != .running && session.phase != .paused)
                    Button("Quit", systemImage: "xmark") { session.stop() }
                        .disabled(session.phase == .stopping || session.phase == .restartRequired)
                }
                ZStack {
                    Color.black
                    if let image = session.image {
                        Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                    } else {
                        ProgressView("Starting runtime…").tint(.white)
                    }
                    if session.phase == .paused { Text("Paused").font(.headline).padding().background(.regularMaterial, in: Capsule()) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                controls
                    .frame(maxWidth: 700)
            }.padding(geometry.size.width > 700 ? 24 : 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black).foregroundStyle(.white)
        }.preferredColorScheme(.dark).interactiveDismissDisabled()
            .focusable().focusEffectDisabled().focused($keyboardFocus)
            .onAppear { keyboardFocus = true }
            .onKeyPress(phases: [.down, .up]) { press in
                let bit: UInt16?
                switch press.key {
                case .upArrow: bit = 1 << 4
                case .downArrow: bit = 1 << 5
                case .leftArrow: bit = 1 << 6
                case .rightArrow: bit = 1 << 7
                case .return: bit = 1 << 3
                default: bit = keys[press.characters.lowercased()]
                }
                guard let bit else { return .ignored }
                session.setButton(bit, pressed: press.phase == .down, keyboard: true)
                return .handled
            }
            .onReceive(LibraryController.shared.commands) { command in
                if command == "menu" {
                    if session.phase == .paused { session.resume() } else { session.pause() }
                } else if session.phase == .paused {
                    if command == "accept" { session.resume() }
                    if command == "back" { session.stop() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in session.pause() }
            .onKeyPress(.escape) { session.pause(); return .handled }
            .onChange(of: scenePhase) { _, phase in if phase != .active { session.pause() } }
            .onDisappear { session.releaseButtons() }
            .alert("Runtime", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
                Button("OK") { session.error = nil }
            } message: { Text(session.error ?? "") }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { directionalPad; Spacer(minLength: 0); actionPad }
            VStack(spacing: 12) { directionalPad; actionPad }
        }.disabled(session.phase != .running)
    }
    private var directionalPad: some View {
        VStack(spacing: 4) {
            pad("Up", icon: "arrow.up", bit: 1 << 4)
            HStack(spacing: 8) {
                pad("Left", icon: "arrow.left", bit: 1 << 6)
                pad("Right", icon: "arrow.right", bit: 1 << 7)
            }
            pad("Down", icon: "arrow.down", bit: 1 << 5)
        }
    }
    private var actionPad: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) { pad("B", bit: 1); pad("A", bit: 1 << 8) }
            HStack(spacing: 8) { pad("Select", bit: 1 << 2); pad("Start", bit: 1 << 3) }
        }
    }

    private func pad(_ label: String, icon: String? = nil, bit: UInt16) -> some View {
        Group {
            if let icon { Image(systemName: icon) } else { Text(label).font(.callout.bold()) }
        }.frame(minWidth: 48, minHeight: 44).padding(.horizontal, 4)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in session.setButton(bit, pressed: true) }
                .onEnded { _ in session.setButton(bit, pressed: false) })
            .accessibilityLabel(label).accessibilityAddTraits(.isButton)
            .accessibilityAction {
                session.setButton(bit, pressed: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { session.setButton(bit, pressed: false) }
            }
    }
}
