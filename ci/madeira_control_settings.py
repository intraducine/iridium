"""Settings access to the shipping control canvas; native dispatch stays owned by the player."""


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Control settings overlay changed: ' + old[:100])
    return text.replace(old, new)


def apply(text):
    for signature in ['    private func startLibraryEntry(_ entry: LibraryEntry) {',
                      '    private func runWineFullSequence(profile: LibraryEntry? = nil) {',
                      '    private func startDock(_ game: DockGame, compactPool: Bool, profile: LibraryEntry? = nil) {']:
        text = replace(text, signature, signature + '''
        guard TouchControlsModel.shared.iridiumSettingsContext == nil else {
            LibraryModel.shared.error = "Finish editing controls before starting a game."
            return
        }''')
    text = replace(text, 'guard StikJITHelper.ready, wine_process_is_running() == 0, wineserver_is_running() == 0,',
                   'guard TouchControlsModel.shared.iridiumSettingsContext == nil, StikJITHelper.ready, wine_process_is_running() == 0, wineserver_is_running() == 0,')
    text = replace(text, '    private func launchLibraryEntry(_ entry: LibraryEntry) {', '''    private func launchLibraryEntry(_ entry: LibraryEntry) {
        guard TouchControlsModel.shared.iridiumSettingsContext == nil else {
            LibraryModel.shared.error = "Finish editing controls before starting a game."
            return
        }''')
    text = replace(text, '    @Published var iridiumConsoleScope: UUID?', '''    struct SettingsContext { let owner: UUID; let platform: IridiumPlatform }
    @Published private(set) var iridiumSettingsContext: SettingsContext?
    @Published var iridiumSettingsOpacity = 0.78
    private var iridiumSettingsSnapshot: (controls: [TouchControl], visible: Bool, size: Double, layout: String?, selected: UUID?, pending: Bool)?
    func iridiumBeginSettings(owner: UUID, platform: IridiumPlatform, state: IridiumControlLayoutState, admission: Bool) throws {
        guard admission, iridiumSettingsContext == nil, iridiumConsoleScope == nil, !editing else { throw IridiumRuntimeError.busy }
        try state.validate(for: platform)
        iridiumSettingsSnapshot = (controls, visible, sizeScale, layoutID, selected, needsDefaultLayout)
        loading = true
        iridiumSettingsContext = SettingsContext(owner: owner, platform: platform)
        controls = state.controls; visible = state.visible; sizeScale = state.size
        iridiumSettingsOpacity = state.opacity ?? 0.78
        layoutID = nil; selected = nil; editing = true
        loading = false
    }
    @discardableResult func iridiumEndSettings(owner: UUID) -> Bool {
        guard iridiumSettingsContext?.owner == owner, let saved = iridiumSettingsSnapshot else { return false }
        loading = true
        editing = false; controls = saved.controls; visible = saved.visible; sizeScale = saved.size
        layoutID = saved.layout; selected = saved.selected; needsDefaultLayout = saved.pending
        iridiumSettingsSnapshot = nil; iridiumSettingsContext = nil
        loading = false
        return true
    }
    var iridiumEditingPlatform: IridiumPlatform? { iridiumSettingsContext?.platform ?? IridiumConsoleSession.shared.game?.platform }
    @Published var iridiumConsoleOpacity = 0.78
    private var iridiumConsoleOpacityBaseline = 0.78
    private var iridiumConsolePlatform: IridiumPlatform?
    var iridiumConsoleSaveFailure: ((String) -> Void)?
    @Published var iridiumConsoleScope: UUID?''')
    text = replace(text, 'if oldValue && !editing && iridiumConsoleScope == nil {',
                   'if oldValue && !editing && iridiumConsoleScope == nil && iridiumSettingsContext == nil {')
    text = replace(text, '        guard !loading else { return }\n        if iridiumConsoleScope != nil',
                   '        guard !loading, iridiumSettingsContext == nil else { return }\n        if iridiumConsoleScope != nil')
    text = replace(text, 'visible defaultVisible: Bool) {\n        guard iridiumConsoleScope == nil else { return }',
                   'visible defaultVisible: Bool, platform: IridiumPlatform? = nil) {\n        guard iridiumConsoleScope == nil, iridiumSettingsContext == nil else { return }')
    text = replace(text, '        layoutID = nil; selected = nil; editing = false\n        iridiumConsoleBaseline', '''        iridiumConsolePlatform = platform
        if let platform {
            let builtIn = IridiumControlLayoutState(controls: controlsDefault, visible: defaultVisible, size: 1, automatic: true,
                opacity: UserDefaults.standard.object(forKey: "IridiumConsoleControlOpacity") as? Double ?? 0.78)
            if let resolved = try? IridiumControlProfileStore.shared.resolve(platform: platform, gameID: game, builtIn: builtIn) {
                controls = resolved.controls; visible = resolved.visible; sizeScale = resolved.size
                iridiumConsoleOpacity = resolved.opacity ?? 0.78
                iridiumConsoleDefaults = resolved.automatic == true ? controls : nil
            }
        }
        iridiumConsoleOpacityBaseline = iridiumConsoleOpacity
        layoutID = nil; selected = nil; editing = false
        iridiumConsoleBaseline''')
    text = replace(text, '        UserDefaults.standard.set(data, forKey: "IridiumConsoleControlLayout." + game.uuidString)', '''        if let platform = iridiumConsolePlatform {
            do {
                let layout = IridiumControlLayoutState(controls: controls, visible: visible, size: sizeScale,
                    automatic: value.automatic, opacity: iridiumConsoleOpacity)
                try IridiumControlProfileStore.shared.set(.init(layout: layout), platform: platform, gameID: game)
            } catch { iridiumConsoleSaveFailure?(error.localizedDescription); return }
        } else { UserDefaults.standard.set(data, forKey: "IridiumConsoleControlLayout." + game.uuidString) }''')
    text = replace(text, '        if value == iridiumConsoleBaseline { return }',
                   '        if value == iridiumConsoleBaseline && (iridiumConsolePlatform == nil || iridiumConsoleOpacity == iridiumConsoleOpacityBaseline) { return }')
    text = replace(text, '        iridiumConsoleHadUnreadableData = false\n        iridiumConsoleBaseline = value\n        if let platform',
                   '        if let platform')
    text = replace(text, '        } else { UserDefaults.standard.set(data, forKey: "IridiumConsoleControlLayout." + game.uuidString) }',
                   '''        } else { UserDefaults.standard.set(data, forKey: "IridiumConsoleControlLayout." + game.uuidString) }
        iridiumConsoleHadUnreadableData = false
        iridiumConsoleBaseline = value; iridiumConsoleOpacityBaseline = iridiumConsoleOpacity''')
    text = replace(text, '        iridiumConsoleScope = nil; iridiumSaved = nil',
                   '        iridiumConsoleScope = nil; iridiumSaved = nil; iridiumConsolePlatform = nil; iridiumConsoleSaveFailure = nil')
    text = replace(text, '        guard !IridiumConsoleSession.shared.isActive else { return nil }\n        let m = TouchControlsModel.shared',
                   '        guard !IridiumConsoleSession.shared.isActive, TouchControlsModel.shared.iridiumSettingsContext == nil else { return nil }\n        let m = TouchControlsModel.shared')
    text = replace(text, '    var iridiumEmbedded = false\n    @ObservedObject private var console',
                   '    var iridiumEmbedded = false\n    var iridiumSettings = false\n    @ObservedObject private var console')
    text = replace(text, 'private var iridiumConsole: Bool { iridiumEmbedded && console.isActive }',
                   'private var iridiumConsole: Bool { iridiumEmbedded && (console.isActive || (iridiumSettings && m.iridiumSettingsContext?.platform != .windows)) }')
    text = replace(text, 'private var iridiumSuspended: Bool { !iridiumEmbedded && (console.isActive || m.iridiumConsoleScope != nil) }',
                   'private var iridiumSuspended: Bool { !iridiumEmbedded && (console.isActive || m.iridiumConsoleScope != nil || m.iridiumSettingsContext != nil) }')
    text = replace(text, 'private var iridiumBlocked: Bool { iridiumConsole ?',
                   'private var iridiumBlocked: Bool { iridiumSettings ? false : iridiumConsole ?')
    text = replace(text, 'let session = library.current != nil || iridiumConsole', 'let session = library.current != nil || iridiumConsole || iridiumSettings')
    text = replace(text, 'if iridiumConsole { if m.editing { topBar } } else if session',
                   'if iridiumSettings { EmptyView() } else if iridiumConsole { if m.editing { topBar } } else if session')
    text = replace(text, '.onChange(of: m.iridiumConsoleScope) { _, _ in configureGamepad(landscape: landscape) }',
                   '.onChange(of: m.iridiumConsoleScope) { _, _ in configureGamepad(landscape: landscape) }\n            .onChange(of: m.iridiumSettingsContext?.owner) { _, _ in configureGamepad(landscape: landscape) }')
    text = replace(text, 'guard !console.isActive, m.iridiumConsoleScope == nil else {',
                   'guard !console.isActive, m.iridiumConsoleScope == nil, m.iridiumSettingsContext == nil else {')
    text = replace(text, 'guard !iridiumEmbedded, !console.isActive, m.iridiumConsoleScope == nil, m.needsDefaultLayout',
                   'guard !iridiumEmbedded, !console.isActive, m.iridiumConsoleScope == nil, m.iridiumSettingsContext == nil, m.needsDefaultLayout')
    text = replace(text, 'iridiumLayoutOpacity: session && !m.editing\n                    ? (iridiumConsole ? ((UserDefaults.standard.object(forKey: "IridiumConsoleControlOpacity") as? Double) ?? 0.78) : library.opacity) : 1)',
                   'iridiumLayoutOpacity: iridiumSettings ? m.iridiumSettingsOpacity : session && !m.editing\n                    ? (iridiumConsole ? m.iridiumConsoleOpacity : library.opacity) : 1)')
    text = replace(text, '            ZStack(alignment: .top) {\n                if (landscape || iridiumConsole) && !iridiumSuspended {',
                   '            ZStack(alignment: .top) {\n                if m.editing { IridiumControlDeselectSurface() }\n                if (landscape || iridiumConsole) && !iridiumSuspended {')
    text = replace(text, '        .frame(width: layout.size.width, height: layout.size.height)\n        .background(GlassShape())',
                   '        .frame(width: layout.size.width, height: layout.size.height)\n        .background { Color.clear.contentShape(Rectangle()).onTapGesture {} }\n        .background(GlassShape())')
    text = replace(text, '''            HStack(spacing: 0) {
                if !IridiumConsoleSession.shared.isActive { tabButton(0, "keyboard") }
                tabButton(1, "gamecontroller")
            }
            Rectangle().fill(.white.opacity(0.15)).frame(height: 1)''', '''            if m.iridiumEditingPlatform == nil || m.iridiumEditingPlatform == .windows {
                Picker("Input", selection: $tab) {
                    Text("Keyboard & Mouse").tag(0)
                    Text("Gamepad").tag(1)
                }.pickerStyle(.segmented).padding(10)
            }''')
    # Labels and supported action choices follow the editor target, never a fake running session.
    text = text.replace('console.isActive ? IridiumConsoleControlMapping',
                        'm.iridiumEditingPlatform != nil && m.iridiumEditingPlatform != .windows ? IridiumConsoleControlMapping')
    text = text.replace('profile: console.game?.platform == .psp ? .psp : .gameBoy',
                        'profile: .consoleProfile(m.iridiumEditingPlatform?.rawValue)')
    text = text.replace('if console.isActive && action.padName == "DPad"',
                        'if m.iridiumEditingPlatform != nil && m.iridiumEditingPlatform != .windows && action.padName == "DPad"')
    text = text.replace('tab == 0 && !IridiumConsoleSession.shared.isActive ?',
                        'tab == 0 && (m.iridiumEditingPlatform == nil || m.iridiumEditingPlatform == .windows) ?')
    start = text.index('        if IridiumConsoleSession.shared.isActive {\n            let psp =')
    end = text.index('        } else {\n        VStack(alignment:', start)
    text = text[:start] + '''        if let platform = m.iridiumEditingPlatform, platform != .windows {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose an input. Drag controls to move them, or pinch to resize.")
                    .font(.caption).foregroundStyle(.secondary)
                section("Game controls", IridiumControlActions.names(for: platform).map { name in
                    (IridiumConsoleControlMapping.label(name, profile: .consoleProfile(platform.rawValue)), ControlAction.pad(name))
                })
            }
''' + text[end:]
    return text


def library_model(text):
    text = replace(text, '    private var savedControls: [TouchControl] = []',
                   '    private var iridiumWindowsControlsBaseline: IridiumControlLayoutState?\n    private var savedControls: [TouchControl] = []')
    text = replace(text, '        controls.sizeScale = min(max(entry.controlSize ?? 1, 0.5), 2)', '''        controls.sizeScale = min(max(entry.controlSize ?? 1, 0.5), 2)
        iridiumWindowsControlsBaseline = nil
        let profileStore = IridiumControlProfileStore.shared
        let selected = profileStore.document.games[entry.id.uuidString] != nil ||
            (entry.controls == nil && entry.controlLayout == nil && profileStore.hasSelection(platform: .windows, gameID: nil))
        if selected {
            let fallback = IridiumControlLayoutState(controls: savedControls, visible: savedVisible, size: savedSize,
                opacity: entry.controlOpacity ?? 0.7)
            do {
                let value = try profileStore.resolve(platform: .windows, gameID: entry.id, builtIn: fallback)
                controls.controls = value.controls; controls.visible = value.visible; controls.sizeScale = value.size
                controls.layoutID = nil; opacity = value.opacity ?? 0.7
                iridiumWindowsControlsBaseline = IridiumControlLayoutState(controls: controls.controls, visible: controls.visible,
                    size: controls.sizeScale, opacity: opacity)
            } catch { self.error = error.localizedDescription }
        }''')
    text = replace(text, '''            entry.controls = controls.controls
            if ControlPresetsModel.enabled { entry.controlLayout = controls.layoutID }
            entry.touchControls = controls.visible''', '''            if let baseline = iridiumWindowsControlsBaseline {
                let value = IridiumControlLayoutState(controls: controls.controls, visible: controls.visible,
                    size: controls.sizeScale, opacity: opacity)
                if value != baseline {
                    do { try IridiumControlProfileStore.shared.set(.init(layout: value), platform: .windows, gameID: id) }
                    catch { self.error = error.localizedDescription; return }
                }
            } else {
                entry.controls = controls.controls
                if ControlPresetsModel.enabled { entry.controlLayout = controls.layoutID }
                entry.touchControls = controls.visible
                entry.controlOpacity = opacity; entry.controlSize = controls.sizeScale
            }''')
    text = replace(text, '            entry.controlOpacity = opacity; entry.controlSize = controls.sizeScale\n            if GamepadInput.keyboardMouseAvailable',
                   '            if GamepadInput.keyboardMouseAvailable')
    text = replace(text, '        current = nil; activeEntry = nil; menu = false; sessionMessage = ""',
                   '        iridiumWindowsControlsBaseline = nil\n        current = nil; activeEntry = nil; menu = false; sessionMessage = ""')
    return text


def library(text):
    text = library_model(text)
    text = replace(text, 'case "Controls": Form { Group {', '''case "Controls": Form { Group {
                Section {
                    IridiumGameControlsButton(target: .init(platform: .windows, title: IridiumArtworkModel.shared.title(IridiumGame(windows: entry)), gameID: entry.id,
                        windowsLayout: entry.controls.map { IridiumControlLayoutState(controls: $0, visible: entry.touchControls,
                            size: entry.controlSize ?? 1, opacity: entry.controlOpacity ?? 0.7) }))
                }
''')
    text = text.replace('Arrange buttons and choose XInput, mouse, or keyboard actions from the in-game menu.',
                        'Use Touch Layout & Profiles to arrange controls before playing. Changes apply on the next launch.')
    return text
