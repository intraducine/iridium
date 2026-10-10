"""Shared Iridium player primitives over Madeira's unchanged native input owners."""


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Madeira player presentation changed: ' + old[:100])
    return text.replace(old, new)


def between(text, start, end):
    if text.count(start) != 1:
        raise ValueError('Madeira player boundary changed: ' + start)
    a = text.index(start)
    return text[a:text.index(end, a)]


def controls(text):
    text = replace(text, 'struct TouchControlsOverlay: View {', '''struct TouchControlsOverlay: View {
    @ObservedObject private var iridiumController = IridiumPhysicalController.shared''')
    text = replace(text, 'if (m.visible || m.editing) && !library.blocksGameplayTouch {',
                   'if (m.editing || (m.visible && !(GamepadInput.enabled && iridiumController.hidesTouchControls))) && !library.blocksGameplayTouch {')
    text = replace(text, 'let ids = landscape && m.visible',
                   'let ids = landscape && m.visible && !(GamepadInput.enabled && iridiumController.hidesTouchControls)')
    text = replace(text, '            .onChange(of: m.visible) { _, _ in configureGamepad(landscape: landscape) }',
                   '''            .onChange(of: m.visible) { _, _ in configureGamepad(landscape: landscape) }
            .onChange(of: iridiumController.hidesTouchControls) { _, _ in configureGamepad(landscape: landscape) }''')
    # Install the host before showing it; reattach on scene activation/rotation.
    text = replace(text, '            w.isHidden = false        // deliberately never made key', '')
    text = replace(text, '        window?.frame = scene.coordinateSpace.bounds',
                   '        window?.frame = scene.coordinateSpace.bounds\n        window?.isHidden = false')
    text = replace(text, '            w.windowLevel = .normal + 101\n            w.backgroundColor = .clear',
                   '            w.windowLevel = .normal + 101\n            w.backgroundColor = .clear\n            w.overrideUserInterfaceStyle = .dark')
    text = replace(text, '            window = w', """            window = w
            for name in [UIDevice.orientationDidChangeNotification, UIScene.didActivateNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { TouchControlsHost.attach() }
                }
            }""")
    # Hidden controls must also stop intercepting the game's pointer/touch window.
    old = between(text, '    func hitsInteractive(_ p: CGPoint, in bounds: CGRect, topBar: Bool = true)', '\n}\n\n/// Click-through')
    new = replace(old, 'guard visible else { return false }',
                  'guard visible && !(GamepadInput.enabled && IridiumPhysicalController.shared.hidesTouchControls) else { return false }')
    new = replace(new, '    func hitsInteractive(', '    @MainActor func hitsInteractive(')
    text = replace(text, old, new)
    old = between(text, '    @ViewBuilder private var padFace: some View {', '\n    var body: some View {')
    text = replace(text, old, '''    private var padFace: some View {
        let action = control.action
        let shape: IridiumControlShape
        switch action.padFace ?? .round {
        case .wide: shape = .shoulder
        case .capsule: shape = .pill
        default: shape = .round
        }
        return IridiumControlFace(label: action.padFaceLabel, symbol: action.padGlyph,
                                  shape: shape, pressed: isDown, compresses: false)
            .frame(width: size.width, height: size.height)
    }
''')
    old = '''                Text(control.action.label)
                    .font(.system(size: diameter * (control.action.label.count > 2 ? 0.22 : 0.34),
                                  weight: .medium))
                    .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.85))
                    .frame(width: size.width, height: size.height)
                    .glassFace(GlassShape(circle: true))'''
    text = replace(text, old, '''                IridiumControlFace(label: control.action.label, pressed: isDown, compresses: false)
                    .frame(width: size.width, height: size.height)''')
    # Preserve vector updates and native TouchPadSurface, share only the stick face.
    old = '''                ZStack {
                    Circle().fill(.white.opacity(isDown ? 0.55 : 0.25))
                        .frame(width: diameter * 0.42, height: diameter * 0.42)
                        .offset(x: padVector.width * diameter * 0.29, y: padVector.height * diameter * 0.29)
                    Text(control.action.label).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                .frame(width: diameter, height: diameter)
                .glassFace(GlassShape(circle: true))'''
    text = replace(text, old, '''                IridiumStickFace(vector: CGPoint(x: padVector.width, y: -padVector.height), pressed: isDown)
                    .frame(width: diameter, height: diameter)''')
    text = replace(text, '''                JoystickFace(held: isDown, dir: stickDir, alwaysExpanded: true,
                              glyph: control.action.stickGlyph, glass: false)
                    .frame(width: JoystickFace.padRadius * 2,
                           height: JoystickFace.padRadius * 2)
                    .scaleEffect(diameter / (JoystickFace.padRadius * 2))
                    .frame(width: diameter, height: diameter)
                    .glassFace(GlassShape(circle: true))''', '''                IridiumStickFace(vector: IridiumControlGeometry.directionVector(stickDir),
                                 pressed: isDown, symbol: control.action.stickGlyph)
                    .frame(width: diameter, height: diameter)''')
    # Non-gamepad key/mouse controls also release if hidden by controller arrival.
    text = replace(text, '        .onDisappear { if control.action.isPad { padVector = .zero; isDown = false } }', '''        .onDisappear {
            if let keys = control.action.stickKeys { applyStick(-1, keys) }
            else if isDown && !control.action.isPad { press(false) }
            padVector = .zero; isDown = false
        }''')
    return text


def menu(text):
    # UIKit owns the visible 48-point accessibility target above native surfaces.
    old = between(text, '                Button { touched += 1; model.showMenu() } label: {',
                  '            } else { LibraryMetrics()')
    text = replace(text, old, """                IridiumPlayerMenuButton(visible: !model.menu) { touched += 1; model.showMenu() }
                    .frame(width: 48, height: 48).opacity(model.menu ? 0 : 1)
                    .allowsHitTesting(!model.menu).accessibilityHidden(model.menu)
""")
    text = replace(text, '        .position(center)',
                   '        .offset(x: center.x - measured.width / 2, y: center.y - measured.height / 2)')
    actions = between(text, '                    iridiumMenuButton("Resume", symbol: "play.fill")', '\n                }\n                if menuPage == "Log"')
    text = replace(text, actions, '                    IridiumSessionMenuActions(windows: true, focused: menuGuided ? menuFocus : nil, activate: iridiumMenuActivate)')
    text = replace(text, 'let order = ["Resume", "Controls", "Performance", "Advanced", "Show Device Keyboard", "View Log", "Close Game"]',
                   'let order = IridiumSessionMenuActions.items(windows: true).map { $0.0 } + ["Close Game"]')
    text = replace(text, 'struct LibraryHUD: View {', 'struct LibraryHUD: View {\n    @ObservedObject private var iridiumController = IridiumPhysicalController.shared')
    old = '''                HStack(spacing: 16) {
                    if menuPage != "Session" { Button("Back", systemImage: "chevron.left") { iridiumMenuNavigate("back") }.font(.headline) }
                    Text(menuPage).font(.title2.bold())
                    Spacer()
                    Button("Done") { model.menu = false }
                }'''
    text = replace(text, old, '''                IridiumPlayerMenuHeader(title: menuPage,
                    subtitle: menuPage == "Session" ? "Windows" : nil,
                    back: menuPage == "Session" ? nil : { iridiumMenuNavigate("back") },
                    done: { model.menu = false })''')
    old = between(text, '    private func iridiumMenuButton(_ title: String, symbol: String) -> some View {',
                  '    private func iridiumMenuActivate(')
    text = replace(text, old, '''    private func iridiumMenuButton(_ title: String, symbol: String) -> some View {
        IridiumPlayerMenuRow(title: title, symbol: symbol,
                            selected: menuGuided && menuFocus == title,
                            destructive: title == "Close Game") { iridiumMenuActivate(title) }
    }
''')
    text = replace(text, '''            let step = command == "up" || command == "left" ? -1 : 1
            menuFocus = order[min(max((order.firstIndex(of: menuFocus) ?? 0) + step, 0), order.count - 1)]''',
                   '            menuFocus = IridiumPlayerMenuNavigation.next(menuFocus, order: order, command: command)')
    text = replace(text, 'if !open { bindsPage = false; menuPage = "Session" }',
                   'if !open { bindsPage = false; menuPage = "Session"; menuFocus = "Resume"; confirmClose = false }')
    text = replace(text, '@State private var confirmClose = false', '@State private var confirmClose = false\n    @State private var closeConfirmation = IridiumCloseConfirmation()')
    text = replace(text, '''        .confirmationDialog("Close this game?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close Game", role: .destructive) { model.requestQuit() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Unsaved progress can be lost.") }''', '')
    text = replace(text, '''            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.menu)''', '''                if confirmClose {
                    IridiumPlayerCloseConfirmation(selection: closeConfirmation.selection,
                        message: "Requests a normal game exit. Confirm any in-game prompt. Unsaved progress may be lost.",
                        cancel: { iridiumCancelClose() },
                        close: { confirmClose = false; model.requestQuit() }, command: iridiumMenuNavigate)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.menu)''')
    text = replace(text, '''                    (bindsPage ? AnyView(bindsMenu) : AnyView(menu))
                        .frame''', '''                    (bindsPage ? AnyView(bindsMenu) : AnyView(menu))
                        .allowsHitTesting(!confirmClose).accessibilityHidden(confirmClose)
                        .frame''')
    text = replace(text, '.onTapGesture { model.menu = false }.transition(.opacity)',
                   '.onTapGesture { model.menu = false }.allowsHitTesting(!confirmClose).transition(.opacity)')
    text = replace(text, '        case "Close Game": confirmClose = true',
                   '        case "Close Game": closeConfirmation = IridiumCloseConfirmation(); menuKeyboard = false; confirmClose = true')
    text = replace(text, '''    private func iridiumMenuNavigate(_ command: String) {
        guard !confirmClose else { return }''', '''    private func iridiumCancelClose() { confirmClose = false; menuKeyboard = true }
    private func iridiumMenuNavigate(_ command: String) {
        if confirmClose {
            switch closeConfirmation.receive(command) {
            case .cancel: iridiumCancelClose()
            case .close: confirmClose = false; model.requestQuit()
            case .pending: break
            }
            return
        }''')
    text = replace(text, '''            if command == "menu" { if model.menu { model.menu = false } else { model.showMenu() } }
            else if model.menu { iridiumMenuNavigate(command) }''', '''            if confirmClose { iridiumMenuNavigate(command) }
            else if command == "menu" { if model.menu { model.menu = false } else { model.showMenu() } }
            else if model.menu { iridiumMenuNavigate(command) }''')
    # Keep native settings/editor key handling isolated from this app-owned hub.
    if text.count('if menuPage == "Controls" {') != 2:
        raise ValueError('Madeira native Controls sections changed')
    text = text.replace('if menuPage == "Controls" {', 'if menuPage == "Control Settings" {')
    text = replace(text, '''                if menuPage == "Performance" {
                FPSChoice''', '''                if menuPage == "Controls" {
                    iridiumMenuButton(controls.visible ? "Hide Touch Controls" : "Show Touch Controls", symbol: "hand.tap")
                    if GamepadInput.enabled && iridiumController.isActive {
                        iridiumMenuButton(iridiumController.forceTouchVisible ? "Use Controller" : "Use Touch Controls", symbol: "gamecontroller")
                        Text("Touch controls hide automatically with a controller. A temporary override lasts until it disconnects.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    iridiumMenuButton("Control Settings", symbol: "slider.horizontal.3")
                }
                if menuPage == "Performance" {
                FPSChoice''')
    text = replace(text, '''        case "Resume": model.menu = false''', '''        case "Resume": model.menu = false
        case "Controls": menuPage = "Controls"; menuFocus = controls.visible ? "Hide Touch Controls" : "Show Touch Controls"
        case "Hide Touch Controls", "Show Touch Controls":
            controls.visible.toggle(); menuFocus = controls.visible ? "Hide Touch Controls" : "Show Touch Controls"
        case "Use Touch Controls":
            controls.visible = true; iridiumController.forceTouchVisible = true; menuFocus = "Use Controller"
        case "Use Controller": iridiumController.forceTouchVisible = false; menuFocus = "Use Touch Controls"''')
    text = replace(text, '''            else if menuPage != "Session" { menuPage = "Session" }''', '''            else if menuPage == "Control Settings" { menuPage = "Controls"; menuFocus = "Control Settings" }
            else if menuPage != "Session" { menuPage = "Session"; menuFocus = "Controls" }''')
    text = replace(text, '''        guard menuPage == "Session" else { return }
        let order =''', '''        guard !bindsPage else { return }
        if menuPage == "Controls" {
            let order = IridiumPlayerMenuNavigation.touchControlItems(enabled: controls.visible,
                controller: GamepadInput.enabled && iridiumController.isActive, overrideEnabled: iridiumController.forceTouchVisible, includeSettings: true)
            if ["up", "down", "left", "right"].contains(command) {
                menuGuided = true
                menuFocus = IridiumPlayerMenuNavigation.next(menuFocus, order: order, command: command)
            } else if command == "accept" { iridiumMenuActivate(order.contains(menuFocus) ? menuFocus : order[0]) }
            return
        }
        guard menuPage == "Session" else { return }
        let order =''')
    for key in ('upArrow', 'downArrow', 'return'):
        command = {'upArrow': 'up', 'downArrow': 'down', 'return': 'accept'}[key]
        old = f'.onKeyPress(.{key}) {{ guard menuPage == "Session" else {{ return .ignored }}; iridiumMenuNavigate("{command}"); return .handled }}'
        phases = ', phases: .down' if key == 'return' else ''
        argument = '_ in ' if phases else ''
        new = f'.onKeyPress(.{key}{phases}) {{ {argument}guard IridiumPlayerMenuNavigation.ownsCommands(page: menuPage, nativeEditor: bindsPage) else {{ return .ignored }}; iridiumMenuNavigate("{command}"); return .handled }}'
        text = replace(text, old, new)
    text = replace(text, '.onKeyPress(.escape) { iridiumMenuNavigate("back"); return .handled }',
                   '.onKeyPress(.escape, phases: .down) { _ in iridiumMenuNavigate("back"); return .handled }')
    return text


def apply(name, text):
    if name == 'ContentView.swift':
        text = shared_console(controls(text))
        text = touch_mouse(text)
    if name == 'Library.swift': text = pointer_settings(menu(text))
    return text


def shared_console(text):
    # One editor/model and serialized layout format for every runtime. A scoped
    # console session never writes Madeira's original controls file or presets.
    text = replace(text, '    private var loading = false\n    private static var url: URL {', '''    var iridiumConsoleScope: UUID?
    private var iridiumConsoleBaseline: ConsoleSaved?
    private var iridiumConsoleDefaults: [TouchControl]?
    private var iridiumConsoleHadUnreadableData = false
    private var iridiumSaved: (controls: [TouchControl], visible: Bool, size: Double, layout: String?)?
    private struct ConsoleSaved: Codable, Equatable {
        var version = 1
        var controls: [TouchControl]
        var visible: Bool
        var size: Double
        // Absent in legacy records: preserve those as custom layouts.
        var automatic: Bool?
    }
    func iridiumBeginConsole(_ game: UUID, defaults controlsDefault: [TouchControl], visible defaultVisible: Bool) {
        guard iridiumConsoleScope == nil else { return }
        iridiumSaved = (controls, visible, sizeScale, layoutID)
        loading = true
        iridiumConsoleScope = game
        iridiumConsoleDefaults = nil
        let key = "IridiumConsoleControlLayout." + game.uuidString
        let stored = UserDefaults.standard.data(forKey: key)
        iridiumConsoleHadUnreadableData = stored != nil
        if let data = stored,
           let saved = try? JSONDecoder().decode(ConsoleSaved.self, from: data), saved.version == 1,
           saved.controls.count <= 128,
           Set(saved.controls.map { $0.id }).count == saved.controls.count,
           saved.controls.allSatisfy({ control in
               control.nx.isFinite && control.ny.isFinite && control.scale.isFinite &&
               (0...1).contains(control.nx) && (0...1).contains(control.ny) &&
               (0.5...3).contains(control.scale) && control.action.padName.map { name in
                   controlsDefault.contains { $0.action.padName == name } || ["D↑", "D↓", "D←", "D→"].contains(name)
               } == true
           }) {
            iridiumConsoleHadUnreadableData = false
            controls = saved.controls; visible = saved.visible
            sizeScale = saved.size.isFinite ? min(2, max(0.5, saved.size)) : 1
            if saved.automatic == true {
                controls = iridiumDefaultControls(controlsDefault, preserving: saved.controls)
                iridiumConsoleDefaults = controls
            }
        } else {
            controls = controlsDefault; visible = defaultVisible; sizeScale = 1
            iridiumConsoleDefaults = controls
        }
        layoutID = nil; selected = nil; editing = false
        iridiumConsoleBaseline = ConsoleSaved(controls: controls, visible: visible, size: sizeScale,
                                             automatic: iridiumConsoleDefaults == nil ? nil : true)
        loading = false
    }
    private func iridiumDefaultControls(_ defaults: [TouchControl], preserving old: [TouchControl]) -> [TouchControl] {
        defaults.map { control in
            var value = control
            if let previous = old.first(where: { $0.action == control.action }) { value.id = previous.id }
            return value
        }
    }
    func iridiumResizeConsole(defaults: [TouchControl]) {
        guard !loading, iridiumConsoleScope != nil, let previous = iridiumConsoleDefaults,
              controls == previous else { return }
        let resized = iridiumDefaultControls(defaults, preserving: previous)
        guard resized != controls else { return }
        // Geometry is presentation, not a layout edit. Keep the no-write
        // baseline in step, including when rejected data is still on disk.
        loading = true
        controls = resized
        iridiumConsoleDefaults = resized
        iridiumConsoleBaseline?.controls = resized
        loading = false
    }
    func iridiumSaveConsole() {
        guard !loading, let game = iridiumConsoleScope else { return }
        if let defaults = iridiumConsoleDefaults, controls != defaults { iridiumConsoleDefaults = nil }
        let value = ConsoleSaved(controls: controls, visible: visible, size: sizeScale,
                                 automatic: iridiumConsoleDefaults == nil ? nil : true)
        // Merely viewing/closing a session must not destroy future/corrupt data.
        if value == iridiumConsoleBaseline { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        iridiumConsoleHadUnreadableData = false
        iridiumConsoleBaseline = value
        UserDefaults.standard.set(data, forKey: "IridiumConsoleControlLayout." + game.uuidString)
    }
    func iridiumEndConsole() {
        guard let saved = iridiumSaved else { return }
        iridiumSaveConsole()
        loading = true
        editing = false; selected = nil
        controls = saved.controls; visible = saved.visible; sizeScale = saved.size; layoutID = saved.layout
        iridiumConsoleScope = nil; iridiumSaved = nil
        iridiumConsoleDefaults = nil; iridiumConsoleBaseline = nil
        loading = false
    }
    private var loading = false
    private static var url: URL {''')
    text = replace(text, 'if oldValue && !editing { ControlPresetsModel.shared.editingEnded(baseline: editBaseline) }',
                   'if oldValue && !editing && iridiumConsoleScope == nil { ControlPresetsModel.shared.editingEnded(baseline: editBaseline) }')
    text = replace(text, '        guard !loading else { return }\n        guard let d = try? JSONEncoder().encode(Saved(',
                   '        guard !loading else { return }\n        if iridiumConsoleScope != nil { iridiumSaveConsole(); return }\n        guard let d = try? JSONEncoder().encode(Saved(')
    text = replace(text, '        let m = TouchControlsModel.shared\n        // Edit mode owns',
                   '        guard !IridiumConsoleSession.shared.isActive else { return nil }\n        let m = TouchControlsModel.shared\n        // Edit mode owns')
    text = replace(text, '''    @ObservedObject private var iridiumController = IridiumPhysicalController.shared
    @ObservedObject private var m = TouchControlsModel.shared''', '''    var iridiumEmbedded = false
    @ObservedObject private var console = IridiumConsoleSession.shared
    @ObservedObject private var iridiumController = IridiumPhysicalController.shared
    @ObservedObject private var m = TouchControlsModel.shared
    private var iridiumConsole: Bool { iridiumEmbedded && console.isActive }
    private var iridiumSuspended: Bool { !iridiumEmbedded && (console.isActive || m.iridiumConsoleScope != nil) }
    private var iridiumBlocked: Bool { iridiumConsole ? (console.phase != .running && !m.editing) : library.blocksGameplayTouch }''')
    text = replace(text, 'let session = library.current != nil', 'let session = library.current != nil || iridiumConsole')
    text = replace(text, '                if landscape {\n                    if (m.editing',
                   '                if (landscape || iridiumConsole) && !iridiumSuspended {\n                    if (m.editing')
    text = replace(text, '            .onDisappear { GamepadInput.shared.configureTouch(controls: []); TouchMouseGate.padOverlay = false }',
                   '''            .onChange(of: console.isActive) { _, _ in configureGamepad(landscape: landscape) }
            .onDisappear {
                if !iridiumEmbedded { GamepadInput.shared.configureTouch(controls: []); TouchMouseGate.padOverlay = false }
            }''')
    text = replace(text, '&& !library.blocksGameplayTouch {\n                        controls(', '&& !iridiumBlocked {\n                        controls(')
    text = replace(text, 'if session && !m.editing { LibraryHUD() } else { topBar }',
                   'if iridiumConsole { if m.editing { topBar } } else if session && !m.editing { LibraryHUD() } else { topBar }')
    text = replace(text, '''        .ignoresSafeArea()
    }

    /// Every control in ONE''', '''        .ignoresSafeArea(edges: iridiumEmbedded ? [] : .all)
    }

    /// Every control in ONE''')
    text = replace(text, '    private func configureGamepad(landscape: Bool) {', '''    private func configureGamepad(landscape: Bool) {
        guard !iridiumEmbedded else { return }
        guard !console.isActive, m.iridiumConsoleScope == nil else {
            GamepadInput.shared.configureTouch(controls: []); TouchMouseGate.padOverlay = false
            return
        }''')
    text = replace(text, '        guard m.needsDefaultLayout, geo.size.width > geo.size.height else { return }',
                   '        guard !iridiumEmbedded, !console.isActive, m.iridiumConsoleScope == nil, m.needsDefaultLayout, geo.size.width > geo.size.height else { return }')
    text = replace(text, 'if m.editing && Self.editorDone {', 'if m.editing && (Self.editorDone || iridiumConsole) {')
    text = replace(text, '                    var c = TouchControl()\n                    // Stagger',
                   '                    guard !iridiumConsole || m.controls.count < 128 else { return }\n                    var c = TouchControl()\n                    if iridiumConsole { c.action = .pad("A") }\n                    // Stagger')
    text = replace(text, '.opacity(session && !m.editing ? library.opacity : 1)',
                   '.opacity(session && !m.editing ? (iridiumConsole ? ((UserDefaults.standard.object(forKey: "IridiumConsoleControlOpacity") as? Double) ?? 0.78) : library.opacity) : 1)')
    text = replace(text, '            TouchControlButton(control: c, screen: screen)', '''            TouchControlButton(control: iridiumConsole
                ? IridiumConsoleControlLayout.fitted(c, screen: screen, sizeScale: m.sizeScale, editing: m.editing)
                : c, screen: screen)''')
    # The D-pad's hollow center must still select/drag the whole control in the
    # actual Madeira editor. Gameplay retains its existing UIKit touch surface.
    text = replace(text, '''        .frame(width: size.width, height: size.height)
        .overlay(outline.stroke''', '''        .frame(width: size.width, height: size.height)
        .background { if m.editing { Color.clear.contentShape(Rectangle()) } }
        .overlay(outline.stroke''')
    text = replace(text, 'return IridiumControlFace(label: action.padFaceLabel, symbol: action.padGlyph,',
                   '''let console = IridiumConsoleSession.shared
        let label = console.isActive ? IridiumConsoleControlMapping.label(action.padName ?? "", profile: console.game?.platform == .psp ? .psp : .gameBoy) : action.padFaceLabel
        return Group {
            if console.isActive && action.padName == "DPad" {
                IridiumDPadFace(vector: padVector, pressed: isDown)
            } else {
                IridiumControlFace(label: label, symbol: console.isActive ? IridiumConsoleControlMapping.symbol(action.padName ?? "", profile: console.game?.platform == .psp ? .psp : .gameBoy) : action.padGlyph,''')
    text = replace(text, 'shape: shape, pressed: isDown, compresses: false)\n            .frame(width: size.width, height: size.height)\n    }',
                   'shape: shape, pressed: isDown, compresses: false)\n            }\n        }.frame(width: size.width, height: size.height)\n    }')
    text = replace(text, '''                TouchPadSurface(control: control.id, action: action) { vector, down in
                    padVector = vector; isDown = down
                }''', '''                if IridiumConsoleSession.shared.isActive {
                    IridiumConsoleControlSurface(control: control.id, action: action) { vector, down in
                        padVector = vector; isDown = down
                    }
                } else {
                    TouchPadSurface(control: control.id, action: action) { vector, down in
                        padVector = vector; isDown = down
                    }
                }''')
    # Emit feedback in the input callback, not SwiftUI onChange: a quick press
    # and release can be coalesced into a single render transaction.
    text = text.replace('padVector = vector; isDown = down',
                        'if !isDown && down { IridiumControlHaptics.press() }; padVector = vector; isDown = down')
    text = replace(text, '''                tabButton(0, "keyboard")
                tabButton(1, "gamecontroller")''', '''                if !IridiumConsoleSession.shared.isActive { tabButton(0, "keyboard") }
                tabButton(1, "gamecontroller")''')
    text = replace(text, '(tab == 0 ? AnyView(keyboardTab) : AnyView(controllerTab))',
                   '(tab == 0 && !IridiumConsoleSession.shared.isActive ? AnyView(keyboardTab) : AnyView(controllerTab))')
    original = between(text, '    private var controllerTab: some View {', '\n    /// Keyboard-and-mouse controller mode:')
    text = replace(text, original, original.replace('        VStack(alignment:', '''        Group {
        if IridiumConsoleSession.shared.isActive {
            let psp = IridiumConsoleSession.shared.game?.platform == .psp
            VStack(alignment: .leading, spacing: 12) {
                Text("Controls are saved for this game. Drag to move, pinch the selected control to resize.")
                    .font(.caption).foregroundStyle(.secondary)
                section("Face", psp ? [("Cross", .pad("A")), ("Circle", .pad("B")), ("Square", .pad("X")), ("Triangle", .pad("Y"))] : [("A", .pad("A")), ("B", .pad("B"))])
                section("D-pad", [("D-pad", .pad("DPad")), ("Up", .pad("D↑")), ("Down", .pad("D↓")), ("Left", .pad("D←")), ("Right", .pad("D→"))])
                if psp { section("Shoulders & stick", [("L", .pad("LB")), ("R", .pad("RB")), ("Analog", .pad("LS"))]) }
                section("System", [("Start", .pad("Menu")), ("Select", .pad("View"))])
            }
        } else {
        VStack(alignment:''', 1)[:-6] + '        }\n        }\n    }\n')
    marker = text.index('struct TouchControlsOverlay: View {')
    before, control_views = text[:marker], text[marker:]
    control_views = control_views.replace('UIImpactFeedbackGenerator(style: .light).impactOccurred()', 'IridiumControlHaptics.press()')
    return before + control_views


def touch_mouse(text):
    # Reuse Madeira's Direct gesture resolver and Trackpad implementation.
    text = replace(text, 'private var touchPointerMode: Bool { InputSettings.shared.touchMode }',
                   '''private var iridiumTouchMode: IridiumTouchMouseMode?
    private var iridiumMotion = IridiumTouchMouseMotion()
    private var iridiumPointerContacts: [ObjectIdentifier: UITouch] = [:]
    private var iridiumTrackpadHadDrag = false
    private var touchPointerMode: Bool { (iridiumTouchMode ?? IridiumTouchMouseMode.current()) == .direct }
    func iridiumReleasePointer() {
        // Revoked contacts cannot start a different gesture until they lift.
        tmgSwallowed.formUnion(iridiumPointerContacts.keys)
        iridiumPointerContacts.removeAll()
        if let touch = tmDragTouch { let (x, y) = mapTouch(touch); winios_post_touch_up(x, y) }
        tmResetGesture()
        touchGeneration += 1
        if dragActive { postPointer(F_LUP) }
        dragActive = false; dragTouch = nil; twoFingerActive = false
        iridiumMotion.reset(); iridiumTouchMode = nil; iridiumTrackpadHadDrag = false
    }''')
    text = replace(text, '(event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }',
                   'iridiumPointerContacts.values.filter { $0.phase != .ended && $0.phase != .cancelled }')
    start = text.index('    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {', text.index('private var tmgSwallowed'))
    end = text.index('\n}\n\n/// Arrow-key button', start)
    pointer = text[start:end]
    pointer = replace(pointer, '        if touchPointerMode { touchModeBegan(touches); return }', '''        guard !LibraryModel.shared.blocksGameplayTouch, !TouchControlsModel.shared.editing else { return }
        let eligibleTouches = Set(touches.filter { $0.view === self && $0.type != .indirectPointer && gameRect().contains($0.location(in: self)) })
        for touch in touches.subtracting(eligibleTouches) { tmgSwallowed.insert(ObjectIdentifier(touch)) }
        for touch in eligibleTouches { iridiumPointerContacts[ObjectIdentifier(touch)] = touch }
        guard !eligibleTouches.isEmpty else { return }
        if iridiumTouchMode == nil { iridiumTouchMode = IridiumTouchMouseMode.current() }
        if touchPointerMode { touchModeBegan(eligibleTouches); return }''')
    pointer = replace(pointer, '        if touchPointerMode { touchModeMoved(touches, event); return }', '''        let touches = Set(filteredTouches.filter { iridiumPointerContacts[ObjectIdentifier($0)] != nil })
        guard !touches.isEmpty else { return }
        guard !LibraryModel.shared.blocksGameplayTouch, !TouchControlsModel.shared.editing else { iridiumReleasePointer(); return }
        if touchPointerMode { touchModeMoved(touches, event); return }''')
    pointer = replace(pointer, '        if touchPointerMode { touchModeEnded(touches, event); return }', '''        let touches = Set(filteredTouches.filter { iridiumPointerContacts[ObjectIdentifier($0)] != nil })
        guard !touches.isEmpty else { return }
        defer {
            for touch in touches { iridiumPointerContacts.removeValue(forKey: ObjectIdentifier(touch)) }
            if iridiumPointerContacts.isEmpty { iridiumTouchMode = nil; iridiumMotion.reset(); iridiumTrackpadHadDrag = false }
        }
        if touchPointerMode { touchModeEnded(touches, event); return }''')
    pointer = replace(pointer, '        if touchPointerMode { touchModeCancelled(touches); return }', '''        defer { iridiumTouchMode = nil; iridiumMotion.reset() }
        if touchPointerMode { touchModeCancelled(touches); return }''')
    for phase in ('moved', 'ended'):
        pointer = replace(pointer,
                          'guard let touches = tmgFilter(touches, .' + phase + ') else { return }',
                          'guard let filteredTouches = tmgFilter(touches, .' + phase + ') else { return }')
    # Trackpad works in both direct game and desktop sessions; Direct alone maps
    # absolute coordinates through mapPoint/GameSurfaceLayout.
    for phase in ('down', 'move', 'up'):
        old = '''        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_''' + phase + '''(x, y)
            return
        }
'''
        if pointer.count(old) != (2 if phase == 'up' else 1):
            raise ValueError('Madeira touch lifecycle changed: ' + phase)
        pointer = pointer.replace(old, '')
    began = between(pointer, '    override func touchesBegan(', '    override func touchesMoved(')
    pointer = replace(pointer, began, replace(began, '        guard let t = touches.first else { return }', '        guard let t = eligibleTouches.first else { return }'))
    pointer = replace(pointer, '            self.dragActive = true',
                      '            self.dragActive = true\n            self.iridiumTrackpadHadDrag = true')
    pointer = replace(pointer, '''        let now = Date().timeIntervalSinceReferenceDate
        if twoFingerActive {''', '''        let now = Date().timeIntervalSinceReferenceDate
        // The drag owner can lift while another finger remains. Release before
        // the multi-touch branch returns, and never turn this drag into a click.
        if twoFingerActive, dragActive, let owner = dragTouch, touches.contains(owner) {
            postPointer(F_LUP)
            dragActive = false; dragTouch = nil
        }
        if twoFingerActive {''')
    pointer = replace(pointer, 'if !twoFingerMoved && now - twoFingerStartTime < 0.40',
                      'if !iridiumTrackpadHadDrag && !twoFingerMoved && now - twoFingerStartTime < 0.40')
    pointer = pointer.replace('!InputSettings.shared.relative', '!self.touchPointerMode')
    # One occurrence outside the captured self of the long-press closure.
    pointer = pointer.replace('&& !self.touchPointerMode', '&& !touchPointerMode')
    pointer = replace(pointer, '        if InputSettings.shared.relative {', '        if !touchPointerMode {')
    pointer = replace(pointer, '            let sens = CGFloat(InputSettings.shared.sensRel)',
                      '            let sens = CGFloat(InputSettings.shared.sensRel) * CGFloat(max(0.25, min(4, (UserDefaults.standard.object(forKey: "IridiumMouseSensitivity") as? Double) ?? 1)))')
    old_motion = between(pointer, '            relCarryX += dx * sens', '            if ix != 0 || iy != 0')
    pointer = replace(pointer, old_motion, '            let (ix, iy) = iridiumMotion.delta(CGPoint(x: dx, y: dy), sensitivity: Double(sens))\n')
    pointer = replace(pointer, '        relCarryX = 0; relCarryY = 0   // ml641: never carry motion across a lift', '        iridiumMotion.reset()')
    pointer = pointer.replace('UIImpactFeedbackGenerator(style: .medium).impactOccurred()', 'IridiumControlHaptics.press()')
    cancelled = pointer[pointer.index('    override func touchesCancelled('):]
    pointer = replace(pointer, cancelled, '''    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if HardwareInput.shared.interceptTouches(touches, event, .cancelled) { return }
        guard let touches = tmgFilter(touches, .cancelled),
              touches.contains(where: { iridiumPointerContacts[ObjectIdentifier($0)] != nil }) else { return }
        // Cancel the entire owned gesture, including a drag whose owner was not
        // among the contacts cancelled by UIKit. Remaining fingers stay revoked.
        iridiumReleasePointer()
        for touch in touches { tmgSwallowed.remove(ObjectIdentifier(touch)) }
    }
''')
    text = text[:start] + pointer + text[end:]
    # Explicit mouse modes own empty surface touches; controls/menu own their hit
    # regions in ControlsWindow. Retain the existing gesture-long swallowed set.
    text = replace(text, 'guard TouchMouseGate.suppressing(touchpad: touchPointerMode) else { return touches }',
                   'guard TouchMouseGate.mode == .off || LibraryModel.shared.blocksGameplayTouch || TouchControlsModel.shared.editing else { return touches }')
    text = replace(text, '            .onChange(of: library.blocksGameplayTouch) { _, _ in configureGamepad(landscape: landscape) }',
                   '''            .onChange(of: library.blocksGameplayTouch) { _, blocked in
                if blocked { MetalBackedView.keyboardTarget?.iridiumReleasePointer() }
                configureGamepad(landscape: landscape)
            }''')
    text = replace(text, '            .onChange(of: m.editing) { _, _ in configureGamepad(landscape: landscape) }',
                   '''            .onChange(of: m.editing) { _, editing in
                if editing { MetalBackedView.keyboardTarget?.iridiumReleasePointer() }
                configureGamepad(landscape: landscape)
            }''')
    text = replace(text, '        super.didMoveToWindow()',
                   '        super.didMoveToWindow()\n        if window == nil { iridiumReleasePointer() }')
    return text


def pointer_settings(text):
    old = between(text, 'struct LibraryPointerSettings: View {', '\nstruct LibraryPillGlass: ViewModifier {')
    text = replace(text, 'if menuPage == \"Log\" { LibraryLiveLogs().frame(minHeight: 250) }', 'if menuPage == \"Log\" { RuntimeDiagnosticsLogContent().frame(minHeight: 250) }')
    return replace(text, old, """struct LibraryPointerSettings: View {
    @AppStorage(IridiumTouchMouseMode.settingsKey) private var mode = IridiumTouchMouseMode.trackpad.rawValue
    @AppStorage("IridiumMouseSensitivity") private var sensitivity = 1.0
    var body: some View {
        IridiumControlFeedbackSettings()
        if TouchMouseGate.mode == .off {
            Text("Touch mouse is disabled by MADEIRA_TOUCH_MOUSE=0. Remove that override and restart Iridium to use these modes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Picker("Touch mouse", selection: $mode) {
            Text("Trackpad").tag(IridiumTouchMouseMode.trackpad.rawValue)
            Text("Direct").tag(IridiumTouchMouseMode.direct.rawValue)
        }.pickerStyle(.segmented)
            .onChange(of: mode) { _, _ in MetalBackedView.keyboardTarget?.iridiumReleasePointer() }
        Text(mode == IridiumTouchMouseMode.direct.rawValue
            ? "Tap where you want to click. Hold and move to drag. Two fingers right-click or scroll."
            : "Drag anywhere between controls to move the pointer. Tap to click; hold to drag. Two fingers right-click or scroll.")
            .font(.caption).foregroundStyle(.secondary)
        if mode == IridiumTouchMouseMode.trackpad.rawValue {
            LabeledContent("Pointer speed") { Slider(value: $sensitivity, in: 0.25...4) }
        }
    }
}
""")
