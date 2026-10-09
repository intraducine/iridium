// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import AVFoundation

struct IridiumConsolePlayer: View {
    @ObservedObject private var session = IridiumConsoleSession.shared
    @ObservedObject private var controller = IridiumPhysicalController.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var keyboardFocus: Bool
    @AppStorage("IridiumConsoleTouchControls") private var touchEnabled = true
    @AppStorage("IridiumConsoleControlOpacity") private var controlOpacity = 0.78
    @State private var analogKeys: Set<String> = []
    @State private var inputGeneration = 0
    @State private var menuPage = "Session"
    @State private var menuFocus = "Resume"
    @State private var menuGuided = false
    @State private var confirmClose = false
    @State private var closeConfirmation = IridiumCloseConfirmation()
    @State private var helpSection = 0
    private var isPSP: Bool { session.game?.platform == .psp }
    private var profile: IridiumPlayerProfile { isPSP ? .psp : .gameBoy }
    private var touchVisible: Bool { touchEnabled && !controller.hidesTouchControls }
    private var menuVisible: Bool { session.phase == .paused || session.phase == .restartRequired }
    private var platform: String { session.game?.platform.title ?? "Game" }
    private var keys: [String: UInt16] {
        if isPSP {
            return ["x": 1 << 0, "z": 1 << 8, "c": 1 << 1, "v": 1 << 9,
                    "q": 1 << 10, "e": 1 << 11, " ": 1 << 2, "\r": 1 << 3]
        }
        return ["z": 1 << 8, "x": 1, " ": 1 << 2, "\r": 1 << 3]
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let layout = IridiumPlayerLayout(profile: profile, bounds: bounds, touchVisible: touchVisible)
            ZStack {
                Color.black.ignoresSafeArea()
                screen.frame(width: layout.viewport.width, height: layout.viewport.height)
                    .position(x: layout.viewport.midX, y: layout.viewport.midY)
                if touchVisible, session.phase == .running {
                    touchControls(layout).id(inputGeneration).opacity(controlOpacity)
                }
                if !menuVisible {
                    Button(action: openMenu) {
                        IridiumControlFace(label: "Session", symbol: "ellipsis", shape: .pill)
                            .frame(width: 52, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("Player Menu")
                        .accessibilityHint("Pause the game and open Iridium controls")
                        .disabled(session.phase != .running && session.phase != .starting)
                        .position(layout.menu)
                }
                if menuVisible { menu(in: geometry.size).allowsHitTesting(!confirmClose).accessibilityHidden(confirmClose) }
                if confirmClose {
                    IridiumPlayerCloseConfirmation(selection: closeConfirmation.selection,
                        cancel: cancelClose, close: closeGame, command: command)
                }
                if session.phase == .stopping {
                    ProgressView("Closing game…").padding(24).modifier(IridiumGlassSurface())
                }
            }.foregroundStyle(.white)
                .onChange(of: geometry.size) { _, _ in releaseInput() }
        }
        .background(.black).preferredColorScheme(.dark).interactiveDismissDisabled()
        .statusBarHidden().persistentSystemOverlays(.hidden)
        .focusable().focusEffectDisabled().focused($keyboardFocus)
        .onAppear { keyboardFocus = true; controller.refresh() }
        .onKeyPress(phases: [.down, .up], action: handleKey)
        .onReceive(LibraryController.shared.commands, perform: command)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in openMenu() }
        .onKeyPress(.escape, phases: .down) { _ in if menuVisible { command("back") } else { openMenu() }; return .handled }
        .onChange(of: scenePhase) { _, phase in if phase != .active { openMenu() } }
        .onChange(of: session.phase) { _, phase in
            if phase != .running { releaseInput() }
            if phase == .paused { menuPage = "Session"; menuFocus = "Resume"; keyboardFocus = true }
        }
        .onChange(of: controller.hidesTouchControls) { _, _ in releaseInput() }
        .onChange(of: touchEnabled) { _, _ in releaseInput() }
        .onChange(of: keyboardFocus) { _, focused in if !focused { releaseInput() } }
        .onChange(of: dynamicTypeSize) { _, _ in releaseInput() }
        .onDisappear { releaseInput() }
        .alert("Runtime", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
    }

    private var screen: some View {
        ZStack {
            Color.black
            if let image = session.image {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit().accessibilityLabel("Game display")
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(session.game?.title ?? "Game").font(.headline).multilineTextAlignment(.center)
                    Text("Starting \(platform)…").font(.subheadline).foregroundStyle(.secondary)
                }.padding(24)
            }
        }.clipped()
    }
    private func touchControls(_ layout: IridiumPlayerLayout) -> some View {
        ZStack {
            IridiumPlayerDPad(enabled: session.phase == .running, input: { mask in
                session.setButtons(mask, source: "touch.dpad")
            }, accessibilityTap: { bit in
                session.setButtons(bit, source: "accessibility.dpad")
                session.setButtons(0, source: "accessibility.dpad")
            }).position(x: layout.dpad.midX, y: layout.dpad.midY)
            if let stick = layout.stick {
                IridiumPlayerStick(enabled: session.phase == .running) { x, y in session.setAnalog(x: x, y: y) }
                    .frame(width: stick.width, height: stick.height).position(x: stick.midX, y: stick.midY)
            }
            ForEach(layout.buttons) { button in
                IridiumPlayerTouchButton(label: button.id, symbol: button.symbol,
                    shape: button.isPill ? .pill : .round, enabled: session.phase == .running, input: { down in
                        session.setButton(button.bit, pressed: down, source: "touch." + button.id)
                    }, accessibilityTap: {
                        session.setButton(button.bit, pressed: true, source: "accessibility." + button.id)
                        session.setButton(button.bit, pressed: false, source: "accessibility." + button.id)
                    }).frame(width: button.frame.width, height: button.frame.height)
                    .position(x: button.frame.midX, y: button.frame.midY)
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("\(platform) touch controls")
    }
    private func menu(in size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 16) {
                IridiumPlayerMenuHeader(title: menuPage,
                    subtitle: menuPage == "Session" ? "\(platform) · \(session.game?.title ?? "Game")" : nil,
                    back: menuPage == "Session" ? nil : { command("back") }, done: { if session.phase == .restartRequired { session.returnToLibraryAfterTimeout() } else { resume() } })
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if session.phase == .restartRequired {
                                Text("The runtime is still closing. Restart Iridium before playing another game.")
                                IridiumPlayerMenuRow(title: "Library", symbol: "square.grid.2x2") { session.returnToLibraryAfterTimeout() }
                            } else if menuPage == "Session" {
                                menuRow("Resume", "play.fill")
                                menuRow("Controls", "gamecontroller")
                                menuRow("Help", "questionmark.circle")
                                menuRow("Close Game", "stop.circle")
                            } else if menuPage == "Controls" {
                                menuRow(touchEnabled ? "Hide Touch Controls" : "Show Touch Controls", "hand.tap")
                                if controller.isActive {
                                    menuRow(controller.forceTouchVisible ? "Use Controller" : "Use Touch Controls", "gamecontroller")
                                    Text(controller.forceTouchVisible ? "Touch controls stay visible until the controller disconnects." : "Touch controls hide automatically with a controller. Choose Use Touch Controls to show them temporarily.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                HStack { Text("Opacity"); Slider(value: $controlOpacity, in: 0.35...1) }.padding(.vertical, 12)
                                if controller.isActive {
                                    Text("Up/down chooses a control. A selects. Left/right changes opacity. B goes back.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            } else { help }
                        }
                    }.onChange(of: menuFocus) { _, title in proxy.scrollTo(title, anchor: .center) }
                        .onChange(of: helpSection) { _, section in proxy.scrollTo("help.\(section)", anchor: .top) }
                }
            }
            .padding(22).frame(maxWidth: 460, maxHeight: min(600, max(0, size.height - 24)))
            .modifier(IridiumGlassSurface(radius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.15)))
            .padding(.horizontal, 12)
        }.tint(Color(red: 0.66, green: 0.82, blue: 0.76))
    }
    private func menuRow(_ title: String, _ symbol: String) -> some View {
        IridiumPlayerMenuRow(title: title, symbol: symbol, selected: menuGuided && menuFocus == title,
                            destructive: title == "Close Game") { activate(title) }
    }
    private var help: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Player Menu", systemImage: "ellipsis").font(.headline)
                Text("Tap the menu handle or press Escape. The game's Start button stays separate.")
                if controller.isActive { Text("Back + Start opens this menu. Use up/down to scroll through help, and B to return.") }
            }.id("help.0")
            VStack(alignment: .leading, spacing: 12) {
                Label("Keyboard", systemImage: "keyboard").font(.headline)
                Text(isPSP ? "Arrows: D-pad\nW/A/S/D: analog stick\nX/Z: Cross/Circle\nC/V: Square/Triangle\nQ/E: L/R\nEnter: Start · Space: Select" : "Arrows: D-pad\nZ/X: A/B\nEnter: Start · Space: Select")
                Text("In help, up/down scrolls through sections. Escape returns to the session menu.")
            }.id("help.1")
            VStack(alignment: .leading, spacing: 12) {
                Label("Display", systemImage: "rectangle").font(.headline)
                Text("The game keeps its original proportions. In landscape, translucent controls overlay the largest available game view.")
            }.id("help.2")
        }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func activate(_ title: String) {
        switch title {
        case "Resume": resume()
        case "Close Game": closeConfirmation = IridiumCloseConfirmation(); confirmClose = true
        case "Hide Touch Controls", "Show Touch Controls":
            touchEnabled.toggle(); menuFocus = touchEnabled ? "Hide Touch Controls" : "Show Touch Controls"
        case "Use Touch Controls":
            touchEnabled = true; controller.forceTouchVisible = true; menuFocus = "Use Controller"
        case "Use Controller": controller.forceTouchVisible = false; menuFocus = "Use Touch Controls"
        default:
            menuPage = title
            if title == "Controls" { menuFocus = touchEnabled ? "Hide Touch Controls" : "Show Touch Controls" }
            if title == "Help" { helpSection = 0 }
        }
    }
    private func command(_ value: String) {
        if confirmClose {
            switch closeConfirmation.receive(value) {
            case .cancel: cancelClose()
            case .close: closeGame()
            case .pending: break
            }
            return
        }
        if value == "menu" { if menuVisible { resume() } else { openMenu() }; return }
        guard menuVisible else { return }
        if session.phase == .restartRequired {
            if value == "accept" || value == "back" { session.returnToLibraryAfterTimeout() }
            return
        }
        if value == "back" { if menuPage == "Session" { resume() } else { menuPage = "Session"; menuFocus = "Resume" }; return }
        if menuPage == "Controls" {
            let order = IridiumPlayerMenuNavigation.touchControlItems(enabled: touchEnabled,
                controller: controller.isActive, overrideEnabled: controller.forceTouchVisible)
            if value == "up" || value == "down" { menuGuided = true; menuFocus = IridiumPlayerMenuNavigation.next(menuFocus, order: order, command: value) }
            if value == "accept" { activate(order.contains(menuFocus) ? menuFocus : order[0]) }
            if value == "left" { controlOpacity = max(0.35, controlOpacity - 0.1) }
            if value == "right" { controlOpacity = min(1, controlOpacity + 0.1) }
            return
        }
        if menuPage == "Help" {
            if value == "up" { helpSection = max(0, helpSection - 1) }
            if value == "down" { helpSection = min(2, helpSection + 1) }
            return
        }
        guard menuPage == "Session" else { return }
        let order = ["Resume", "Controls", "Help", "Close Game"]
        if ["up", "down", "left", "right"].contains(value) {
            menuGuided = true
            menuFocus = IridiumPlayerMenuNavigation.next(menuFocus, order: order, command: value)
        } else if value == "accept" { activate(menuFocus) }
    }
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if menuVisible {
            guard press.phase == .down else { return .handled }
            switch press.key {
            case .upArrow: command("up")
            case .downArrow: command("down")
            case .leftArrow: command("left")
            case .rightArrow: command("right")
            case .return: command("accept")
            default: return .ignored
            }
            return .handled
        }
        let key = press.characters.lowercased(), pressed = press.phase == .down
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
    private func cancelClose() { confirmClose = false; keyboardFocus = true }
    private func closeGame() { confirmClose = false; releaseInput(); session.stop() }
    private func openMenu() { releaseInput(); session.pause() }
    private func resume() { guard session.phase == .paused else { return }; releaseInput(); session.resume(); keyboardFocus = true }
    private func releaseInput() {
        analogKeys.removeAll(); inputGeneration &+= 1
        session.resetInput()
    }
}
