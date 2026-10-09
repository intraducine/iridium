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
    if name == 'ContentView.swift': text = controls(text)
    if name == 'Library.swift': text = menu(text)
    return text
