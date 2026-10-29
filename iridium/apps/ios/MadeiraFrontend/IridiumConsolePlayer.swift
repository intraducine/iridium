// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import AVFoundation

struct IridiumConsolePlayer: View {
    @ObservedObject private var session = IridiumConsoleSession.shared
    @ObservedObject private var controller = IridiumPhysicalController.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var keyboardFocus: Bool
    @AppStorage("IridiumConsoleTouchControls") private var touchEnabled = true
    private var controlOpacity: Binding<Double> { Binding(get: { controls.iridiumConsoleOpacity }, set: { controls.iridiumConsoleOpacity = $0; controls.iridiumSaveConsole() }) }
    @State private var analogKeys: Set<String> = []
    @State private var inputGeneration = 0
    @State private var menuPage = "Session"
    @State private var menuFocus = "Resume"
    @State private var menuGuided = false
    @State private var menuContentHeight: CGFloat = 600
    @State private var menuHeaderHeight: CGFloat = 0
    @State private var confirmClose = false
    @State private var closeConfirmation = IridiumCloseConfirmation()
    @State private var helpSection = 0
    @State private var showingLogs = false
    private var isPSP: Bool { session.game?.platform == .psp }
    private var isDolphin: Bool { session.game?.runtimeID == "dolphin" }
    private var stateSlot: Int {
        get { isDolphin ? session.dolphinStateSlot : session.pspStateSlot }
        nonmutating set { if isDolphin { session.dolphinStateSlot = newValue } else { session.pspStateSlot = newValue } }
    }
    private var stateStatus: String? { isDolphin ? session.dolphinStateStatus : session.pspStateStatus }
    private var remoteName: String { ["Sideways Wii Remote", "Wii Remote and Nunchuk", "Classic Controller"][session.dolphinSettings.remote] }
    private var aspectName: String { ["Auto", "16:9", "4:3"][session.dolphinSettings.aspect] }
    private var profile: IridiumPlayerProfile { .consoleProfile(session.game?.platform.rawValue) }
    private var touchVisible: Bool { controls.visible && !controller.hidesTouchControls }
    private var menuVisible: Bool { !controls.editing && (session.phase == .paused || session.phase == .restartRequired) }
    private var platform: String { session.game?.platform.title ?? "Game" }
    private var keys: [String: UInt16] {
        if session.game?.platform.isPhase3 == true {
            return ["z": 1 << 8, "x": 1 << 0, "c": 1 << 9, "v": 1 << 1,
                    "q": 1 << 10, "e": 1 << 11, "1": 1 << 12, "3": 1 << 13,
                    " ": 1 << 2, "\r": 1 << 3]
        }
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
                if (touchVisible && session.phase == .running) || controls.editing {
                    TouchControlsOverlay(iridiumEmbedded: true).id(inputGeneration)
                }
                if menuVisible { menu(in: geometry.size).allowsHitTesting(!confirmClose).accessibilityHidden(confirmClose) }
                if confirmClose {
                    IridiumPlayerCloseConfirmation(selection: closeConfirmation.selection,
                        cancel: cancelClose, close: closeGame, command: command)
                }
                if session.phase == .stopping {
                    ProgressView("Closing game…").padding(24).modifier(IridiumGlassSurface())
                }
            }.overlay(alignment: .topLeading) {
                if !menuVisible && !controls.editing {
                    // The renderer uses safe content bounds. Menu coordinates
                    // cover the complete window and clamp its safe insets once.
                    IridiumMovablePlayerMenu(action: openMenu, safeAreaInsets: geometry.safeAreaInsets)
                        .frame(width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
                               height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
                        .offset(x: -geometry.safeAreaInsets.leading, y: -geometry.safeAreaInsets.top)
                        .disabled(session.phase != .running && session.phase != .starting)
                }
            }.foregroundStyle(.white)
                .onChange(of: geometry.size) { _, _ in
                    releaseInput()
                    session.updateDolphinOrientation()
                    controls.iridiumResizeConsole(defaults: IridiumConsoleControlLayout.defaults(profile: profile, bounds: bounds))
                }
                .onAppear {
                    if let game = session.game {
                        controls.iridiumBeginConsole(game.id,
                            defaults: IridiumConsoleControlLayout.defaults(profile: profile, bounds: bounds), visible: touchEnabled, platform: game.platform)
                        controls.iridiumConsoleSaveFailure = { LibraryModel.shared.error = $0 }
                    }
                }
        }
        .background(.black).preferredColorScheme(.dark).interactiveDismissDisabled()
        .statusBarHidden().persistentSystemOverlays(.hidden)
        .focusable().focusEffectDisabled().focused($keyboardFocus)
        .onAppear { keyboardFocus = true; controller.refresh() }
        .onChange(of: session.dolphinSettings.remote) { _, _ in inputGeneration += 1 }
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
        .onChange(of: controls.editing) { _, _ in releaseInput(); controls.iridiumSaveConsole() }
        .onChange(of: controls.visible) { _, _ in releaseInput(); controls.iridiumSaveConsole() }
        .onChange(of: keyboardFocus) { _, focused in if !focused { releaseInput() } }
        .onChange(of: dynamicTypeSize) { _, _ in releaseInput() }
        .onDisappear { releaseInput(); controls.iridiumEndConsole() }
        .sheet(isPresented: $showingLogs) {
            RuntimeDiagnosticsLogView(progress: session.diagnostics,
                playbackTitle: session.phase == .paused ? "Resume while viewing logs" : "Pause runtime",
                togglePlayback: session.phase == .paused || session.phase == .running || session.phase == .starting ? {
                    releaseInput()
                    if session.phase == .paused { session.resume() } else { session.pause() }
                } : nil)
        }
        .alert("Runtime", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
    }

    private var screen: some View {
        ZStack {
            Color.black
            if isPSP, let controller = session.nativePSPController {
                IridiumNativePSPSurface(controller: controller).allowsHitTesting(false)
                    .accessibilityLabel("Game display")
                    .overlay { if !session.pspReady { starting.background(.black) } }
            } else if let controller = session.phase3Controller {
                IridiumNativePSPSurface(controller: controller)
                    .accessibilityLabel("Game display")
                    .overlay { if !session.phase3Ready { starting.background(.black.opacity(0.8)).allowsHitTesting(false) } }
                    .overlay {
                        if session.game?.platform == .nintendo3DS || session.game?.platform == .wii {
                            GeometryReader { geometry in
                                Color.clear.contentShape(Rectangle())
                                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                        session.setConsolePointer(value.location, size: geometry.size)
                                    }.onEnded { _ in session.setConsolePointer(nil, size: .zero) })
                            }
                        }
                    }
            } else if let image = session.image {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit().accessibilityLabel("Game display")
            } else {
                starting
            }
        }.clipped()
    }
    private var starting: some View {
        ScrollView {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text(session.game?.title ?? "Game").font(.headline).lineLimit(1).truncationMode(.tail)
            Text(session.phase == .stopping ? "Closing game…" : "Starting \(platform)…")
                .font(.subheadline).foregroundStyle(.secondary)
            if isDolphin { Text(session.phase3Status).font(.footnote).multilineTextAlignment(.center) }
            IridiumLaunchMemoryView().frame(maxWidth: 360)
        }.padding(24).frame(maxWidth: .infinity)
        }.scrollBounceBehavior(.basedOnSize).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func menu(in size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 16) {
                IridiumPlayerMenuHeader(title: menuPage,
                    subtitle: menuPage == "Session" ? "\(platform) · \(session.game?.title ?? "Game")" : nil,
                    back: menuPage == "Session" ? nil : { command("back") }, done: { if session.phase == .restartRequired { session.returnToLibraryAfterTimeout() } else { resume() } })
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeaderHeight = $0 }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if session.phase == .restartRequired {
                                Text("The runtime is still closing. Restart Iridium before playing another game.")
                                IridiumPlayerMenuRow(title: "Library", symbol: "square.grid.2x2") { session.returnToLibraryAfterTimeout() }
                            } else if menuPage == "Session" {
                                IridiumSessionMenuActions(focused: menuGuided ? menuFocus : nil, activate: activate)
                                if isPSP { menuRow("PSP Settings", "slider.horizontal.3") }
                                if isDolphin {
                                    Text(session.dolphinPerformance).monospacedDigit().font(.subheadline)
                                    menuRow("Dolphin Settings", "slider.horizontal.3")
                                }
                                if isPSP || isDolphin { menuRow("Save States", "square.and.arrow.down") }
                                menuRow("Close Game", "stop.circle")
                            } else if menuPage == "Controls" {
                                menuRow(controls.visible ? "Hide Touch Controls" : "Show Touch Controls", "hand.tap")
                                if controller.isActive {
                                    menuRow(controller.forceTouchVisible ? "Use Controller" : "Use Touch Controls", "gamecontroller")
                                    Text(controller.forceTouchVisible ? "Touch controls stay visible until the controller disconnects." : "Touch controls hide automatically with a controller. Choose Use Touch Controls to show them temporarily.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                HStack { Text("Opacity"); Slider(value: controlOpacity, in: 0.15...1); Text("\(Int(controls.iridiumConsoleOpacity * 100))%").monospacedDigit() }.padding(.vertical, 12)
                                menuRow("Edit Controls", "slider.horizontal.3")
                                IridiumControlFeedbackSettings()
                                if controller.isActive {
                                    Text("Up/down chooses a control. A selects. Left/right changes opacity. B goes back.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            } else if menuPage == "PSP Settings" {
                                Text("PPSSPP 1.20.4 · Native graphics and media").font(.subheadline)
                                Text("CPU: \(session.pspCPUMode)").font(.footnote).foregroundStyle(.secondary)
                                Text(session.pspJITStatus).font(.footnote).foregroundStyle(.secondary)
                                ForEach(1...4, id: \.self) { scale in
                                    menuRow("Resolution \(scale)×", session.pspResolution == scale ? "checkmark.circle.fill" : "circle")
                                }
                                Text("Resolution changes apply when you resume. Lower values reduce graphics work.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else if menuPage == "Dolphin Settings" {
                                Text("Dolphin · Metal · \(session.dolphinCPUMode)").font(.subheadline)
                                Text(session.dolphinPerformance).monospacedDigit().font(.footnote)
                                ForEach(1...4, id: \.self) { scale in
                                    menuRow("Resolution \(scale)×", session.dolphinSettings.resolution == scale ? "checkmark.circle.fill" : "circle")
                                }
                                menuRow("Aspect: \(aspectName)", "aspectratio")
                                if session.game?.platform == .wii {
                                    menuRow(remoteName, "gamecontroller")
                                    menuRow(session.dolphinSettings.motion ? "Phone Motion: On" : "Phone Motion: Off", "gyroscope")
                                    Text("LT or L2 shakes the Wii Remote. The right stick points. Touch the game display to point directly.").font(.footnote).foregroundStyle(.secondary)
                                }
                                menuRow("Players: \(session.dolphinSettings.players)", "person.2")
                                menuRow(session.dolphinSettings.dualCore ? "Dual Core: On" : "Dual Core: Off", "cpu")
                                Text("Player count and dual core apply after you close and reopen the game. Players follow controller connection order. Touch and keyboard control player 1.").font(.footnote).foregroundStyle(.secondary)
                            } else if menuPage == "Save States" {
                                menuRow("Slot \(stateSlot + 1)", "number.square")
                                menuRow("Save State and Resume", "square.and.arrow.down")
                                menuRow("Load State and Resume", "square.and.arrow.up")
                                Text("Five slots per game. Saving replaces the selected slot. Loading replaces current unsaved progress. In-game saves stay separate.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                if let status = stateStatus { Text(status).font(.footnote) }
                            } else { help }
                        }.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuContentHeight = $0 }
                    }.id(menuPage).onChange(of: menuFocus) { _, title in
                        if menuGuided { proxy.scrollTo(title, anchor: .center) }
                    }
                        .onChange(of: helpSection) { _, section in proxy.scrollTo("help.\(section)", anchor: .top) }
                }
            }
            .padding(22).frame(maxWidth: 460)
            .frame(height: min(menuHeaderHeight + 16 + menuContentHeight + 44, min(600, max(0, size.height - 24))))
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
                Text(session.game?.platform.isPhase3 == true ? "Arrows: D-pad\nW/A/S/D: left stick\nZ/X: A/B · C/V: X/Y\nQ/E: L/R · 1/3: L2/R2\nEnter: Start · Space: Select" : isPSP ? "Arrows: D-pad\nW/A/S/D: analog stick\nX/Z: Cross/Circle\nC/V: Square/Triangle\nQ/E: L/R\nEnter: Start · Space: Select" : "Arrows: D-pad\nZ/X: A/B\nEnter: Start · Space: Select")
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
        case "Slot \(stateSlot + 1)": stateSlot = (stateSlot + 1) % 5; menuFocus = "Slot \(stateSlot + 1)"
        case "Save State and Resume", "Load State and Resume":
            releaseInput()
            if isDolphin { session.requestDolphinState(load: title == "Load State and Resume") }
            else { session.requestPSPState(load: title == "Load State and Resume") }
        case let value where value.hasPrefix("Resolution "):
            if let scale = Int(value.dropFirst(11).prefix(1)) {
                if isDolphin { session.setDolphin { $0.resolution = scale } }
                else { session.setPSPResolution(scale) }
            }
        case "Aspect: \(aspectName)": session.setDolphin { $0.aspect = ($0.aspect + 1) % 3 }
        case remoteName where isDolphin: session.setDolphin { $0.remote = ($0.remote + 1) % 3 }
        case "Phone Motion: On", "Phone Motion: Off": session.setDolphin { $0.motion.toggle() }
        case "Volume": break
        case "Players: \(session.dolphinSettings.players)": session.setDolphin { $0.players = $0.players % 4 + 1 }
        case "Dual Core: On", "Dual Core: Off": session.setDolphin { $0.dualCore.toggle() }
        case "Close Game": closeConfirmation = IridiumCloseConfirmation(); confirmClose = true
        case "View Log": releaseInput(); showingLogs = true
        case "Edit Controls":
            releaseInput(); controls.visible = true; controls.editing = true
            controls.selected = controls.controls.first?.id
        case "Hide Touch Controls", "Show Touch Controls":
            controls.visible.toggle(); menuFocus = controls.visible ? "Hide Touch Controls" : "Show Touch Controls"
        case "Use Touch Controls":
            controls.visible = true; controller.forceTouchVisible = true; menuFocus = "Use Controller"
        case "Use Controller": controller.forceTouchVisible = false; menuFocus = "Use Touch Controls"
        default:
            menuPage = title
            if title == "Controls" { menuFocus = controls.visible ? "Hide Touch Controls" : "Show Touch Controls" }
            if title == "Help" { helpSection = 0 }
            if title == "PSP Settings" { menuFocus = "Resolution \(session.pspResolution)×" }
            if title == "Dolphin Settings" { menuFocus = "Resolution \(session.dolphinSettings.resolution)×" }
            if title == "Save States" { menuFocus = "Slot \(stateSlot + 1)" }
        }
    }
    private func command(_ value: String) {
        if showingLogs { if value == "back" || value == "menu" { showingLogs = false }; return }
        if controls.editing {
            if value == "back" || value == "menu" { controls.editing = false; controls.selected = nil }
            return
        }
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
        if menuPage == "Session", menuFocus == "Volume", value == "left" || value == "right" {
            IridiumGameAudio.shared.adjust(value); return
        }
        if menuPage == "Controls" {
            let order = IridiumPlayerMenuNavigation.touchControlItems(enabled: controls.visible,
                controller: controller.isActive, overrideEnabled: controller.forceTouchVisible) + ["Edit Controls"]
            if value == "up" || value == "down" { menuGuided = true; menuFocus = IridiumPlayerMenuNavigation.next(menuFocus, order: order, command: value) }
            if value == "accept" { activate(order.contains(menuFocus) ? menuFocus : order[0]) }
            if value == "left" { controlOpacity.wrappedValue = max(0.15, controlOpacity.wrappedValue - 0.1) }
            if value == "right" { controlOpacity.wrappedValue = min(1, controlOpacity.wrappedValue + 0.1) }
            return
        }
        if menuPage == "Help" {
            if value == "up" { helpSection = max(0, helpSection - 1) }
            if value == "down" { helpSection = min(2, helpSection + 1) }
            return
        }
        let order: [String]
        switch menuPage {
        case "Session": order = IridiumSessionMenuActions.items(windows: false).map { $0.0 }
            + (isPSP ? ["PSP Settings", "Save States"] : isDolphin ? ["Dolphin Settings", "Save States"] : []) + ["Close Game"]
        case "PSP Settings": order = (1...4).map { "Resolution \($0)×" }
        case "Dolphin Settings": order = (1...4).map { "Resolution \($0)×" } + ["Aspect: \(aspectName)"]
            + (session.game?.platform == .wii ? [remoteName, session.dolphinSettings.motion ? "Phone Motion: On" : "Phone Motion: Off"] : [])
            + ["Players: \(session.dolphinSettings.players)", session.dolphinSettings.dualCore ? "Dual Core: On" : "Dual Core: Off"]
        case "Save States": order = ["Slot \(stateSlot + 1)", "Save State and Resume", "Load State and Resume"]
        default: return
        }
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
        if profile != .gameBoy, ["w", "a", "s", "d"].contains(key) {
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
