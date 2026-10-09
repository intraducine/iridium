// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import AVFoundation

struct IridiumConsolePlayer: View {
    @ObservedObject private var session = IridiumConsoleSession.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var keyboardFocus: Bool
    @State private var analogKeys: Set<String> = []
    @State private var analogOffset = CGSize.zero
    @State private var analogPulse = UUID()
    private var isPSP: Bool { session.game?.platform == .psp }
    private var keys: [String: UInt16] {
        if isPSP {
            return ["x": 1 << 0, "z": 1 << 8, "c": 1 << 1, "v": 1 << 9,
                    "q": 1 << 10, "e": 1 << 11, " ": 1 << 2, "\r": 1 << 3]
        }
        return ["z": 1 << 8, "x": 1, " ": 1 << 2, "\r": 1 << 3]
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let padding: CGFloat = isPSP && landscape ? 12 : (geometry.size.width > 700 ? 24 : 16)
            ScrollView {
                VStack(spacing: 12) {
                    header
                    if isPSP, landscape, geometry.size.width >= 600, !dynamicTypeSize.isAccessibilitySize {
                        landscapePSP
                    } else {
                        screen.frame(height: screenHeight(in: geometry.size, padding: padding))
                        controls.frame(maxWidth: 700)
                    }
                    if isPSP {
                        Text("Keyboard: arrows move the D-pad; WASD moves the analog stick; X/Z are Cross/Circle; C/V are Square/Triangle; Q/E are L/R; Enter is Start; Space is Select. Escape pauses Iridium. On a controller, Back + Start opens Iridium's pause controls.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 800, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 2 * padding), alignment: .top)
                    .padding(padding)
            }.background(.black).foregroundStyle(.white)
                .onChange(of: geometry.size) { _, _ in releaseInput() }
        }.preferredColorScheme(.dark).interactiveDismissDisabled()
            .focusable().focusEffectDisabled().focused($keyboardFocus)
            .onAppear { keyboardFocus = true }
            .onKeyPress(phases: [.down, .up], action: handleKey)
            .onReceive(LibraryController.shared.commands) { command in
                // Madeira reserves Back+Start while playing. An ordinary
                // controller Start is still delivered to the console game.
                if command == "menu" { togglePause() }
                else if session.phase == .paused {
                    if command == "accept" { session.resume() }
                    if command == "back" { session.stop() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
                releaseInput(); session.pause()
            }
            .onKeyPress(.escape) { releaseInput(); session.pause(); return .handled }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { releaseInput(); session.pause() }
            }
            .onChange(of: session.phase) { _, phase in if phase != .running { releaseInput() } }
            .onChange(of: keyboardFocus) { _, focused in if !focused { releaseInput() } }
            .onChange(of: dynamicTypeSize) { _, _ in releaseInput() }
            .onDisappear { releaseInput() }
            .alert("Runtime", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
                Button("OK") { session.error = nil }
            } message: { Text(session.error ?? "") }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { gameTitle; Spacer(minLength: 0); sessionActions }
            VStack(alignment: .leading, spacing: 8) { gameTitle; sessionActions }
        }
    }
    private var gameTitle: some View {
        Text(session.game?.title ?? "Game").font(.headline).lineLimit(2)
            .accessibilityAddTraits(.isHeader)
    }
    private var sessionActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { sessionButtons }
            VStack(alignment: .leading, spacing: 8) { sessionButtons }
        }
    }
    @ViewBuilder private var sessionButtons: some View {
        if session.phase == .restartRequired {
            Button("Library") { releaseInput(); session.returnToLibraryAfterTimeout() }
        }
        Button(session.phase == .paused ? "Resume" : "Pause",
               systemImage: session.phase == .paused ? "play.fill" : "pause.fill", action: togglePause)
            .disabled(session.phase != .starting && session.phase != .running && session.phase != .paused)
            .accessibilityHint("Pause or resume Iridium. This does not press the game's Start button.")
        Button("Quit", systemImage: "xmark") { releaseInput(); session.stop() }
            .disabled(session.phase == .stopping || session.phase == .restartRequired)
    }
    private var screen: some View {
        ZStack {
            Color.black
            if let image = session.image {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                    .accessibilityLabel("Game display")
            } else {
                ProgressView("Starting runtime…").tint(.white)
            }
            if session.phase == .paused {
                Text("Paused").font(.headline).padding().background(.regularMaterial, in: Capsule())
            }
        }.frame(maxWidth: .infinity).clipped()
    }
    private func screenHeight(in size: CGSize, padding: CGFloat) -> CGFloat {
        let aspectHeight = (size.width - 2 * padding) * (isPSP ? 272.0 / 480.0 : 144.0 / 160.0)
        return max(160, min(aspectHeight, size.height * (isPSP ? 0.5 : 0.58)))
    }
    private var landscapePSP: some View {
        HStack(spacing: 12) {
            VStack(spacing: 8) {
                pad("L", bit: 1 << 10)
                HStack(spacing: 8) { directionalPad; analogStick }
            }.fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 8) {
                screen.aspectRatio(480.0 / 272.0, contentMode: .fit)
                startSelect
            }.frame(maxWidth: .infinity)
            VStack(spacing: 8) {
                pad("R", bit: 1 << 11)
                pspFacePad
            }.fixedSize(horizontal: true, vertical: false)
        }.disabled(session.phase != .running)
    }
    private var controls: some View {
        Group {
            if isPSP {
                VStack(spacing: 12) {
                    HStack { pad("L", bit: 1 << 10); Spacer(); pad("R", bit: 1 << 11) }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 20) {
                            VStack(spacing: 12) { directionalPad; analogStick }
                            Spacer(minLength: 0)
                            VStack(spacing: 12) { pspFacePad; startSelect }
                        }
                        VStack(spacing: 12) { directionalPad; analogStick; pspFacePad; startSelect }
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { directionalPad; Spacer(minLength: 0); actionPad }
                    VStack(spacing: 12) { directionalPad; actionPad }
                }
            }
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
        }.accessibilityElement(children: .contain).accessibilityLabel("D-pad")
    }
    private var actionPad: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) { pad("B", bit: 1); pad("A", bit: 1 << 8) }
            startSelect
        }
    }
    private var pspFacePad: some View {
        VStack(spacing: 4) {
            pad("Triangle", icon: "triangle", bit: 1 << 9)
            HStack(spacing: 8) {
                pad("Square", icon: "square", bit: 1 << 1)
                pad("Circle", icon: "circle", bit: 1 << 8)
            }
            pad("Cross", icon: "xmark", bit: 1 << 0)
        }.accessibilityElement(children: .contain).accessibilityLabel("PSP action buttons")
    }
    private var startSelect: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { pad("Select", bit: 1 << 2); pad("Start", bit: 1 << 3) }
            VStack(spacing: 8) { pad("Select", bit: 1 << 2); pad("Start", bit: 1 << 3) }
        }
    }
    private var analogStick: some View {
        ZStack {
            Circle().fill(.white.opacity(0.10))
            Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1)
            Circle().fill(.white.opacity(0.75)).frame(width: 36, height: 36).offset(analogOffset)
        }.frame(width: 104, height: 104).contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard session.phase == .running else { return }
                    analogPulse = UUID()
                    let x = value.location.x - 52, y = value.location.y - 52
                    let scale = max(34, sqrt(x * x + y * y))
                    analogOffset = CGSize(width: x / scale * 34, height: y / scale * 34)
                    session.setAnalog(x: Int16((x / scale * 32767).rounded()),
                                      y: Int16((-y / scale * 32767).rounded()))
                }
                .onEnded { _ in resetTouchAnalog() })
            .accessibilityElement().accessibilityLabel("Left analog stick")
            .accessibilityHint("Drag in any direction. Release to center. Keyboard: W, A, S, D.")
            .accessibilityAction(named: Text("Up")) { pulseAnalog(x: 0, y: 32767) }
            .accessibilityAction(named: Text("Down")) { pulseAnalog(x: 0, y: -32767) }
            .accessibilityAction(named: Text("Left")) { pulseAnalog(x: -32767, y: 0) }
            .accessibilityAction(named: Text("Right")) { pulseAnalog(x: 32767, y: 0) }
            .accessibilityAction(named: Text("Center")) { resetTouchAnalog() }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let key = press.characters.lowercased()
        let pressed = press.phase == .down
        if isPSP, ["w", "a", "s", "d"].contains(key) {
            guard session.phase == .running else { return .ignored }
            if pressed { analogKeys.insert(key) } else { analogKeys.remove(key) }
            let x = (analogKeys.contains("d") ? 32767 : 0) - (analogKeys.contains("a") ? 32767 : 0)
            let y = (analogKeys.contains("w") ? 32767 : 0) - (analogKeys.contains("s") ? 32767 : 0)
            session.setAnalog(x: Int16(x), y: Int16(y), keyboard: true)
            return .handled
        }
        let bit: UInt16?
        switch press.key {
        case .upArrow: bit = 1 << 4
        case .downArrow: bit = 1 << 5
        case .leftArrow: bit = 1 << 6
        case .rightArrow: bit = 1 << 7
        case .return: bit = 1 << 3
        default: bit = keys[key]
        }
        guard let bit, session.phase == .running else { return .ignored }
        session.setButton(bit, pressed: pressed, keyboard: true)
        return .handled
    }
    private func togglePause() {
        releaseInput()
        if session.phase == .paused { session.resume() } else { session.pause() }
    }
    private func resetTouchAnalog() {
        analogPulse = UUID(); analogOffset = .zero
        session.setAnalog(x: 0, y: 0)
    }
    private func pulseAnalog(x: Int16, y: Int16) {
        guard session.phase == .running else { return }
        let pulse = UUID(); analogPulse = pulse
        analogOffset = CGSize(width: CGFloat(x) / 32767 * 34, height: -CGFloat(y) / 32767 * 34)
        session.setAnalog(x: x, y: y)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if analogPulse == pulse { resetTouchAnalog() }
        }
    }
    private func releaseInput() {
        analogKeys.removeAll(); resetTouchAnalog(); session.releaseButtons()
    }
    private func pad(_ label: String, icon: String? = nil, bit: UInt16) -> some View {
        Group {
            if let icon { Image(systemName: icon) } else { Text(label).font(.callout.bold()) }
        }.frame(minWidth: 48, minHeight: 44).padding(.horizontal, 4)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if session.phase == .running { session.setButton(bit, pressed: true) } }
                .onEnded { _ in session.setButton(bit, pressed: false) })
            .accessibilityLabel(label).accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard session.phase == .running else { return }
                session.setButton(bit, pressed: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { session.setButton(bit, pressed: false) }
            }
    }
}
