"""Presentation-only edits to the pinned SwiftUI views. Native actions stay upstream."""
import json
import re
import madeira_player_presentation
import madeira_artwork_presentation
import madeira_jit_lifecycle


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Madeira presentation changed: ' + old[:100])
    return text.replace(old, new)


def between(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a)]


def page(title, sections, destinations):
    destinations[title] = sections
    return f'''NavigationLink("{title}", value: "{title}").id("{title}")
                    .listRowBackground(iridiumGuided && iridiumFocus == "{title}" ? Color.white.opacity(0.2) : Color.white.opacity(0.07))'''


def destination_pages(destinations):
    cases = '\n'.join(f'''case "{title}": {sections[6:] if sections.startswith('@view:') else 'Form { Group { ' + sections + ' }.iridiumRowSurface() }'}.iridiumPageSurface().navigationTitle("{'Madeira' if title == 'Madeira · Windows' else title}")
                    .navigationBarBackButtonHidden()
                    .toolbar {{ ToolbarItem(placement: .topBarLeading) {{
                        Button("Back", systemImage: "chevron.backward") {{ iridiumNavigate("back") }}
                            .keyboardShortcut(.cancelAction)
                    }} }}'''
                      for title, sections in destinations.items())
    return '''.navigationDestination(for: String.self) { page in
                switch page {
''' + cases + '''
                default: EmptyView()
                }
            }'''


def hub_navigation(titles, dismiss):
    order = ', '.join('"' + title + '"' for title in titles)
    return f'''
    private func iridiumNavigate(_ command: String) {{
        if command == "back" {{
            if !iridiumPages.isEmpty {{ iridiumPages.removeLast() }} else {{ {dismiss} }}
            return
        }}
        guard iridiumPages.isEmpty else {{ return }}
        let order = [{order}]
        let index = order.firstIndex(of: iridiumFocus) ?? 0
        if ["left", "right", "up", "down"].contains(command) {{
            iridiumGuided = true
            let step = command == "up" || command == "left" ? -1 : 1
            iridiumFocus = order[min(max(index + step, 0), order.count - 1)]
        }} else if command == "accept" {{ iridiumPages.append(iridiumFocus) }}
    }}
'''


def navigation_state(first):
    return f'''
    @State private var iridiumPages: [String] = []
    @State private var iridiumFocus = "{first}"
    @State private var iridiumGuided = false
    @FocusState private var iridiumKeyboard: Bool
'''


def keyboard_navigation():
    keys = [('upArrow', 'up'), ('downArrow', 'down'), ('leftArrow', 'left'), ('rightArrow', 'right'), ('return', 'accept')]
    return '''.focusable().focusEffectDisabled().focused($iridiumKeyboard)
            .onAppear { iridiumKeyboard = true }
            .onChange(of: iridiumPages) { _, pages in if pages.isEmpty { iridiumKeyboard = true } }
            .onKeyPress(.escape) { iridiumNavigate("back"); return .handled }
''' + '\n'.join(f'''.onKeyPress(.{key}) {{
                guard iridiumPages.isEmpty else {{ return .ignored }}
                iridiumNavigate("{command}"); return .handled
            }}''' for key, command in keys)


def library(text):
    settings_pages = {}
    def setting(title, sections): return page(title, sections, settings_pages)
    # Keep LibraryView installed: its @State owns settings sheets and bindings.
    start = '        TabView(selection: Binding(get: { tab }, set: { switchTab(to: $0) })) {'
    end = '        // On the tab view, not inside one tab'
    old = between(text, start, end)
    settings_body = old
    # The settings hub reuses the complete upstream sections, including callbacks.
    original = between(text, '    private var settings: some View {', '        .alert("Restart Madeira"')
    credits = between(original, '                Section {\n                    MadeiraCredit', '\n            }\n        }')
    launch_support_link = setting('Performance & Compatibility', '@view:IridiumCapabilitiesView()')
    previous_pages = set(settings_pages)
    display_link = setting('Display', '@view:iridiumDisplaySettings')
    saves_link = setting('Saves & Backups', 'SavesSection()')
    steam_link = setting('Steam', 'SteamSettingsSection(open: { settingsSheet = $0 })')
    components_link = setting('Windows Components', 'WineMonoSettingsSection()')
    advanced_link = setting('Advanced Compatibility', 'if MadeiraConfig.flag("MADEIRA_RUNTIME_SETTINGS") { RuntimeMemorySyncSettings(open: { settingsSheet = $0 }, refresh: settingsRefresh) }\nSection("Diagnostics") { Toggle("Detailed logging", isOn: $input.diagnostics) }\nSection { Toggle("Desktop reflections", isOn: $liquidMetal.on) } header: { Text("Appearance") } footer: { Text("Adds moving reflections to Windows desktop controls.") }')
    madeira_order = [title for title in settings_pages if title not in previous_pages]
    controls_link = setting('Controls', '@view:IridiumControlsSettingsView()')
    madeira_link = setting('Madeira · Windows', 'Section { ForEach(model.entries.filter { $0.desktop != true }) { entry in Button { selected = entry } label: { HStack { Text(IridiumArtworkModel.shared.title(IridiumGame(windows: entry))); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) } } }\nif model.entries.filter({ $0.desktop != true }).isEmpty { Text("Add a Windows game to change its options.").foregroundStyle(.secondary) } } header: { Text("Games") } footer: { Text("Open a game to change its display, controls and compatibility options.") }\nSection("Preferences") { ' + display_link + '\n' + saves_link + '\n' + steam_link + ' }\nSection("Compatibility") { ' + components_link + '\n' + advanced_link + ' }')
    console_links = '''ForEach(IridiumConsoleSystem.all) { system in
                NavigationLink(system.title, value: system.title).id(system.title)
                    .listRowBackground(iridiumGuided && iridiumFocus == system.title ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
            }'''
    diagnostics_link = setting('Diagnostics', 'IridiumDiagnosticsSections()\nRuntimeDiagnosticsExportSection()')
    contributors = between(credits, '                    MadeiraCredit', '\n                } header:')
    credits = 'IridiumSoftwareCreditsSections()'
    credits_view = '\nstruct IridiumCreditsSections: View {\n    var body: some View {\n' + credits + '\n    }\n}\n'
    credits_link = setting('Credits', 'IridiumCreditsSections()')
    about_link = setting('About', '@view:IridiumAboutView()')
    setup_link = 'if onboarding.available { Button("Getting Started", systemImage: "wand.and.stars") { onboarding.rerun() }.id("Getting Started") }'
    root_order = ['Getting Started', 'Controls', 'Performance & Compatibility', 'Madeira · Windows', 'About']
    settings = '''    private var settings: some View {
        Form {
            Section { ''' + setup_link + '\n' + controls_link + '\n' + launch_support_link + ''' }.iridiumRowSurface()
            Section("Systems") { ''' + madeira_link + '\n' + console_links + ''' }.iridiumRowSurface()
            Section { ''' + about_link + ''' }.iridiumRowSurface()
        }
'''
    text = replace(text, original, settings)
    text = replace(text, settings_body, '''        NavigationStack(path: $iridiumPages) {
          ScrollViewReader { proxy in
            settings
            .iridiumPageSurface().navigationTitle("Settings")
            .toolbar { settingsToolbar }
            ''' + destination_pages(settings_pages).replace('.navigationBarBackButtonHidden()', '.toolbar { settingsToolbar }.navigationBarBackButtonHidden()').replace('default: EmptyView()', '''default:
                    if let system = IridiumConsoleSystem.system(titled: page) {
                        Form { Group {
                            IridiumSystemGameSettings(platform: system.primaryPlatform, focus: iridiumGuided ? iridiumFocus : nil)
                        }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle(system.runtime.name)
                            .toolbar { settingsToolbar }.navigationBarBackButtonHidden()
                            .toolbar { ToolbarItem(placement: .topBarLeading) {
                                Button("Back", systemImage: "chevron.backward") { iridiumNavigate("back") }
                                    .keyboardShortcut(.cancelAction)
                            } }
                    } else if let game = IridiumSystemGameSettings.game(for: page) {
                        IridiumConsoleOptions(game: game, embedded: true)
                    } else { EmptyView() }''') + '''
            .onChange(of: iridiumPages) { _, _ in
                if !iridiumSettingsOrder.contains(iridiumFocus) { iridiumFocus = iridiumSettingsOrder.first ?? "" }
            }
            .onChange(of: iridiumFocus) { _, title in proxy.scrollTo(title, anchor: .center) }
          }
        }
        ''' + keyboard_navigation().replace('guard iridiumPages.isEmpty', 'guard !iridiumSettingsOrder.isEmpty').replace('if pages.isEmpty', 'if !iridiumSettingsOrder.isEmpty') + '''
''')
    text = replace(text, 'struct LibraryView: View {', 'struct LibraryView: View {\n    @Environment(\\.dismiss) private var iridiumDismiss\n' + navigation_state('Controls'))
    settings_navigation = hub_navigation(root_order, 'iridiumDismiss()').replace('guard iridiumPages.isEmpty else { return }', 'guard !iridiumSettingsOrder.isEmpty else { return }')
    settings_navigation = settings_navigation.replace('let order = ["Getting Started", "Controls", "Performance & Compatibility", "Madeira · Windows", "About"]', 'let order = iridiumSettingsOrder')
    settings_navigation = settings_navigation.replace('        if command == "back" {', '        guard TouchControlsModel.shared.iridiumSettingsContext == nil else { return }\n        if command == "back" {')
    settings_navigation = settings_navigation.replace('        if command == "accept" {', '        if command == "accept", iridiumFocus == "Getting Started" { onboarding.rerun(); return }\n        if command == "accept" {')
    settings_navigation += '''
    private var iridiumSettingsOrder: [String] {
        switch iridiumPages.last {
        case nil: return ["Getting Started", "Controls", "Performance & Compatibility", "Madeira · Windows"] + IridiumConsoleSystem.all.map(\\.title) + ["About"]
        case "Madeira · Windows": return ''' + json.dumps(madeira_order) + '''
        default:
            guard let title = iridiumPages.last, let system = IridiumConsoleSystem.system(titled: title) else { return [] }
            return IridiumSystemGameSettings.routes(for: system.primaryPlatform)
        }
    }
'''
    text = replace(text, '    @ToolbarContentBuilder private var libraryToolbar:', settings_navigation + '    @ToolbarContentBuilder private var libraryToolbar:')
    display_view = '''    private var iridiumDisplaySettings: some View {
        Form { Group {
            DisplayRateSettings()
            Section {
                ForEach(model.entries.filter { $0.desktop != true }) { entry in
                    Button(IridiumArtworkModel.shared.title(IridiumGame(windows: entry))) { iridiumDetailPage = "Display"; selected = entry }
                }
                Button("Windows Desktop") { iridiumDetailPage = "Display"; selected = model.entries.first { $0.id == LibraryEntry.desktopID } ?? LibraryEntry.desktopEntry }
            } header: { Text("Games") } footer: { Text("Resolution, aspect and scaling, MetalFX, FPS limit and frame generation are set per game.") }
        }.iridiumRowSurface() }.iridiumPageSurface()
    }
'''
    text = replace(text, '    @ToolbarContentBuilder private var libraryToolbar:', display_view + '    @ToolbarContentBuilder private var libraryToolbar:')
    text = replace(text, '    @State private var selected: LibraryEntry?', '    @State private var selected: LibraryEntry?\n    @State private var iridiumDetailPage: String?')
    text = replace(text, '            LibraryDetail(entry: entry, play: { profile in', '            LibraryDetail(iridiumInitialPage: iridiumDetailPage, entry: entry, play: { profile in')
    text = replace(text, '.sheet(item: $selected) { entry in', '.sheet(item: $selected, onDismiss: { iridiumDetailPage = nil }) { entry in')
    # The legacy library page is no longer mounted in the settings-only root.
    # Present per-game Display from the live root, with its existing launch/notices.
    detail_start = text.index('        .sheet(item: $selected, onDismiss: { iridiumDetailPage = nil }) { entry in')
    detail_end = text.index('        .onChange(of: scenePhase)', detail_start)
    detail_presentation = text[detail_start:detail_end]
    text = text[:detail_start] + text[detail_end:]
    text = replace(text, '        .fullScreenCover(isPresented: $onboarding.presented) { OnboardingView() }',
                   detail_presentation + '        .fullScreenCover(isPresented: $onboarding.presented) { OnboardingView() }')
    text = replace(text, '.fullScreenCover(isPresented: $onboarding.presented) { OnboardingView() }', '.fullScreenCover(isPresented: onboarding.binding(for: .settings)) { OnboardingView() }')
    text = replace(text, '            onboarding.presentIfNeeded()', '            onboarding.presentIfNeeded(owner: .settings)')

    text = replace(text, '    @ToolbarContentBuilder private var settingsToolbar: some ToolbarContent {', '''    @ToolbarContentBuilder private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { iridiumDismiss() } }''')
    toolbar = between(text, '    @ToolbarContentBuilder private var settingsToolbar:', '    private func switchTab(')
    text = replace(text, toolbar, '''    @ToolbarContentBuilder private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { iridiumDismiss() } }
    }
''')
    text = replace(text, 'if selected == nil, !browser, !onboarding.presented, command == "tab" { switchTab(to: 1 - tab) }', 'guard selected == nil, !browser, !onboarding.presented, settingsSheet == nil else { return }\n            iridiumNavigate(command)')
    text = replace(text, '.onAppear { GlassSkin.shared.start() }\n        .onDisappear', '.onAppear {}\n        .onDisappear')
    text = replace(text, '''            .foregroundStyle(.white)
            .background(pending || configuration.isPressed ? Color(uiColor: .darkGray) : .accentColor,
                        in: RoundedRectangle(cornerRadius: 14))''', '''            .foregroundStyle(pending ? Color.white : Color.black)
            .background(pending ? Color(uiColor: .darkGray) : Color.white.opacity(configuration.isPressed ? 0.8 : 1),
                        in: Capsule())''')

    # Preserve each per-game binding and action, but put advanced options one level down.
    form = between(text, '            Form {\n                Section {\n                    HStack(spacing: 20)', '\n            .navigationTitle("Game details")')
    header = between(form, '                Section {', '                if entry.desktop != true { Section("Library details")')
    rename = between(form, '                if entry.desktop != true { Section("Library details")', '                // A Steam game\'s cloud saves')
    display = between(form, '                Section {\n                    // The Windows screen', '                // ml1163: how the program starts')
    launch = between(form, '                // ml1163: how the program starts', '                Section("On screen")')
    controls = between(form, '                Section("On screen")', '                Section {\n                    NavigationLink {\n                        LibraryGameConfigEditor')
    config = between(form, '                Section {\n                    NavigationLink {\n                        LibraryGameConfigEditor', '                // A link that starts this game')
    files = between(form, '                // A link that starts this game', '                if let error')
    # Keep each pinned binding; group rendering separately from frame pacing.
    resolution = between(display, '                    // The Windows screen', '                    // Every setting here')
    upscale = between(display, '                    Picker("MetalFX upscaling",', '                    FPSChoice(')
    frames = between(display, '                    FPSChoice(', '                } header: { Text("Display") }')
    frames = frames.replace("Shows a MetalFX-generated frame between every two rendered frames: twice the frames on screen, at the cost of GPU time, some latency and artifacts at edges and on the HUD. FPS limits do not apply while it is on.", "Generates extra frames. FPS limits are ignored while enabled.")
    filtering = between(launch, '                    Picker("D3D9 anisotropic filtering",', '                    Toggle("Report an NVIDIA GPU",')
    launch = replace(launch, filtering, '')
    display = '                Section("Resolution & Scaling") {\n' + resolution + '                }\n                Section("Rendering") {\n' + upscale + filtering + '                }\n                Section("Frame Rate") {\n' + frames + '                }\n'
    launch = launch.replace('Settings › Memory & sync', 'Settings → Madeira → Advanced Compatibility')
    # The new upstream reset remains last for every entry, including Desktop.
    marker = '                // madeira-bcd: always last'
    reset = files[files.index(marker):]
    reset = reset.replace('Button("Reset to Recommended",', 'Button(recommended == nil ? "Clear Game Configuration" : "Restore Game Configuration",')
    reset = reset.replace('Text(GameRecommendations.note(recommended, desktop: entry.desktop == true))', 'Text("Restores configuration and any recommended compatibility/display values. Keeps controls, artwork, files and saves.")')
    files = files[:files.index(marker)]
    # Use the same identity header as console games; retain native launch state.
    play_button = between(header, '                            Button(action: start)', '\n                        }')
    header = '''                Section {
                    IridiumGameOptionsHeader(game: IridiumGame(windows: entry))
                    if let played = entry.lastPlayed { LabeledContent("Last Played", value: played.formatted(.relative(presentation: .named))) }
                    if DockOffline.enabled, let appID = entry.steamAppID, !entry.startsSteamGameDirectly { DockOfflineMark(appID: appID) }
''' + play_button + '''
                }.listRowBackground(Color.clear)
                Section("Runtime") { LabeledContent("Emulator", value: "Madeira"); LibraryBadges(entry: entry) }
'''
    detail_pages = {}
    def detail(title, sections): return page(title, sections, detail_pages)
    body = '            Form {\n' + header + '\n                Section("Library") {\n'
    body += '                    if entry.desktop != true { ' + detail('Rename & Artwork', rename) + ' }\n'
    body += '                }.iridiumRowSurface()\n                Section("Controls") { ' + detail('Controls', controls) + ' }.iridiumRowSurface()\n'
    body += '                Section("Display") { ' + detail('Display', display) + ' }.iridiumRowSurface()\n'
    body += '                Section("Files & Saves") { ' + detail('Files & Saves', 'if let appID = entry.steamAppID { SteamCloudSection(appID: appID) }\n' + files) + ' }.iridiumRowSurface()\n'
    body += '                Section("Compatibility") { ' + detail('Advanced', launch + config + '\nif entry.steamAppID != nil { SteamEntrySection(entry: $entry) { leaving = true; dismiss() } }') + ' }.iridiumRowSurface()\n'
    body += '                if entry.desktop != true { Section { IridiumFavoriteButton(entry: entry).id("Favorites") }.iridiumRowSurface() }\n' + reset + '                if let error { Section { Text(error).foregroundStyle(.red) } }\n            }\n' + destination_pages(detail_pages) + '\n'
    text = replace(text, form, body)
    text = replace(text, '.navigationTitle("Game details").navigationBarTitleDisplayMode(.inline)', '.navigationTitle("Game details").navigationBarTitleDisplayMode(.inline)\n            ' + keyboard_navigation())
    text = replace(text, 'struct LibraryDetail: View {', 'struct LibraryDetail: View {\n    var iridiumInitialPage: String? = nil\n' + navigation_state('Controls'))
    text = replace(text, '                reloadBCD()\n            }\n            .onDisappear { if !leaving', '                reloadBCD()\n                if let iridiumInitialPage, iridiumPages.isEmpty { iridiumPages = [iridiumInitialPage] }\n            }\n            .onDisappear { if !leaving')
    game_navigation = hub_navigation([*detail_pages, 'Favorites'], 'model.save(entry); dismiss()')
    game_navigation = game_navigation.replace('\n        let index =', '.filter { entry.desktop != true || !["Rename & Artwork", "Favorites"].contains($0) }\n        let index =')
    game_navigation = game_navigation.replace('iridiumPages.append(iridiumFocus)', 'if iridiumFocus == "Favorites" { IridiumFavoriteButton.toggle(entry) } else { iridiumPages.append(iridiumFocus) }')
    text = replace(text, '    @State var entry: LibraryEntry\n    var play:', '    @State var entry: LibraryEntry\n' + game_navigation + '\n    var play:')
    text = replace(text, '        NavigationStack {\n            Form {\n' + header[:25], '        NavigationStack(path: $iridiumPages) {\n            Form {\n' + header[:25])
    text = replace(text, '.navigationTitle("Game details")', '.navigationTitle("Game Options")')
    text = replace(text, '            .toolbarBackground(.regularMaterial, for: .navigationBar)\n            .toolbarBackground(.visible, for: .navigationBar)', '')
    # Accept must activate the focused native control, not start a game from any row.
    text = replace(text, '                if command == "accept" { start() }', '                if command == "play" { start() }')
    text = replace(text, '                if command == "back" { model.save(entry); dismiss() }', '                iridiumNavigate(command)')
    detail_body = between(text, '        NavigationStack(path: $iridiumPages) {\n            Form', '\n}\n\n/// madeira-bcd: a game')
    new_body = detail_body.replace('        NavigationStack', '      ScrollViewReader { proxy in\n        NavigationStack', 1)
    end = '\n        }\n    }'
    if not new_body.endswith(end): raise ValueError('Game Options closing scope changed')
    new_body = new_body[:-len(end)] + '''
        }.onChange(of: iridiumFocus) { _, title in proxy.scrollTo(title, anchor: .center) }
      }
    }'''
    text = replace(text, detail_body, new_body)

    # Player appearance and hierarchy. Input, close requests and metrics stay upstream.
    text = replace(text, '    @State private var bindsPage = false', '''    @State private var bindsPage = false
    @State private var menuPage = "Session"
    @State private var menuFocus = "Resume"
    @State private var menuGuided = false
    @State private var confirmClose = false
    @State private var menuContentHeight: CGFloat = 650
    @FocusState private var menuKeyboard: Bool''')
    panel = between(text, '                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28))', '\n                        .position(x: geo.size.width / 2')
    text = replace(text, panel, '                        .modifier(IridiumGlassSurface(radius: 28))')
    text = replace(text, '''                    (bindsPage ? AnyView(bindsMenu) : AnyView(menu))
                        .frame(width: min(460, geo.size.width - 32), height: min(650, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom - 24))''',
                   '''                    (bindsPage ? AnyView(bindsMenu) : AnyView(menu))
                        .frame(width: min(460, geo.size.width - 32),
                               height: min(bindsPage ? 650 : menuContentHeight, min(650, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom - 24)))''')
    text = replace(text, 'if !open { bindsPage = false }', 'if !open { bindsPage = false; menuPage = "Session" }')
    text = replace(text, '            else if command == "back", model.menu { model.menu = false }', '            else if model.menu { iridiumMenuNavigate(command) }')
    text = replace(text, '.clipShape(RoundedRectangle(cornerRadius: 14)).shadow(radius: 20)', '.clipShape(RoundedRectangle(cornerRadius: 14))')
    text = replace(text, '''                        .opacity(launchVisible ? 1 : 0)
                    launchView(entry, geometry: geo)
                        .opacity(launchVisible ? 1 : 0)
                        .scaleEffect(launchVisible || reduceMotion ? 1 : 0.96)''', '''                    launchView(entry, geometry: geo)''')
    menu_header = '                HStack { Label("Session", systemImage: "gamecontroller.fill").font(.title2.bold()); Spacer(); Button("Done") { model.menu = false }.buttonStyle(.bordered) }'
    text = replace(text, menu_header, '''                HStack(spacing: 16) {
                    if menuPage != "Session" { Button("Back", systemImage: "chevron.left") { iridiumMenuNavigate("back") }.font(.headline) }
                    Text(menuPage).font(.title2.bold())
                    Spacer()
                    Button("Done") { model.menu = false }
                }
                if menuPage == "Session" {
                    iridiumMenuButton("Resume", symbol: "play.fill")
                    iridiumMenuButton("Controls", symbol: "gamecontroller")
                    iridiumMenuButton("Performance", symbol: "chart.xyaxis.line")
                    iridiumMenuButton("Advanced", symbol: "slider.horizontal.3")
                    iridiumMenuButton("Show Device Keyboard", symbol: "keyboard")
                    iridiumMenuButton("View Log", symbol: "text.alignleft")
                }
                if menuPage == "Log" { LibraryLiveLogs().frame(minHeight: 250) }
                if menuPage == "Controls" {''')
    text = replace(text, '                Button("Keyboard", systemImage: "keyboard") { model.menu = false; LibraryKeyboard.show() }', '')
    text = replace(text, '                FPSChoice(mode: Binding(get: { model.fpsMode }', '                }\n                if menuPage == "Performance" {\n                FPSChoice(mode: Binding(get: { model.fpsMode }')
    text = replace(text, '                // ml1133\'s ECO switch, live:', '                }\n                if menuPage == "Advanced" {\n                // ml1133\'s ECO switch, live:')
    text = replace(text, '                Text("Mouse & pointer").font(.headline)', '                }\n                if menuPage == "Controls" {\n                Text("Mouse & pointer").font(.headline)')
    text = replace(text, '                Toggle("Performance overlay", isOn: $model.performance)', '                }\n                if menuPage == "Performance" {\n                Toggle("Performance overlay", isOn: $model.performance)')
    text = replace(text, '                if sessionTools && sessionDiagnostics {', '                }\n                if menuPage == "Advanced", sessionTools && sessionDiagnostics {')
    text = replace(text, '''                Button(role: .destructive) { model.requestQuit() } label: {
                    Label("Quit game", systemImage: "stop.circle").foregroundStyle(.red)
                }.tint(.red)''', '                iridiumMenuButton("Close Game", symbol: "stop.circle").foregroundStyle(.red)')
    text = replace(text, 'Closes the running session. Unsaved progress will be lost.',
                   'Requests a normal game exit. Confirm any game prompt.')
    text = replace(text, 'Text("Game\'s own support").tag("")', 'Text("XInput").tag("")')
    text = replace(text, 'w.windowLevel = .normal + 102; w.backgroundColor = .clear',
                   'w.windowLevel = .normal + 102; w.backgroundColor = .clear; w.tintColor = UIColor(red: 0.66, green: 0.82, blue: 0.76, alpha: 1)')
    text = replace(text, '    private var menu: some View {\n        ScrollView {', '    private var menu: some View {\n      ScrollViewReader { proxy in\n        ScrollView {')
    text = replace(text, '''            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                .foregroundStyle(.primary)''', '''            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                .foregroundStyle(.primary)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuContentHeight = $0 }''')
    text = replace(text, '''        .scrollIndicators(.visible)
    }
}

struct LibraryLiveLogs''', '''        .scrollIndicators(.visible)
        .tint(Color(red: 0.66, green: 0.82, blue: 0.76))
        .focusable().focusEffectDisabled().focused($menuKeyboard)
        .onAppear { menuKeyboard = true }
        .onKeyPress(.escape) { iridiumMenuNavigate("back"); return .handled }
        .onKeyPress(.upArrow) { guard menuPage == "Session" else { return .ignored }; iridiumMenuNavigate("up"); return .handled }
        .onKeyPress(.downArrow) { guard menuPage == "Session" else { return .ignored }; iridiumMenuNavigate("down"); return .handled }
        .onKeyPress(.return) { guard menuPage == "Session" else { return .ignored }; iridiumMenuNavigate("accept"); return .handled }
        .onChange(of: menuFocus) { _, title in proxy.scrollTo(title, anchor: .center) }
        .confirmationDialog("Close this game?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close Game", role: .destructive) { model.requestQuit() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Unsaved progress can be lost.") }
      }
    }
    private func iridiumMenuButton(_ title: String, symbol: String) -> some View {
        Button { iridiumMenuActivate(title) } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.id(title).buttonStyle(.plain)
            .background(menuGuided && menuFocus == title ? Color.white.opacity(0.2) : .clear,
                        in: RoundedRectangle(cornerRadius: 12))
    }
    private func iridiumMenuActivate(_ title: String) {
        switch title {
        case "Resume": model.menu = false
        case "Show Device Keyboard": model.menu = false; LibraryKeyboard.show()
        case "View Log": menuPage = "Log"
        case "Close Game": confirmClose = true
        default: menuPage = title
        }
    }
    private func iridiumMenuNavigate(_ command: String) {
        guard !confirmClose else { return }
        if command == "back" {
            if bindsPage { bindsPage = false }
            else if menuPage != "Session" { menuPage = "Session" }
            else { model.menu = false }
            return
        }
        guard menuPage == "Session" else { return }
        let order = ["Resume", "Controls", "Performance", "Advanced", "Show Device Keyboard", "View Log", "Close Game"]
        if ["up", "down", "left", "right"].contains(command) {
            menuGuided = true
            let step = command == "up" || command == "left" ? -1 : 1
            menuFocus = order[min(max((order.firstIndex(of: menuFocus) ?? 0) + step, 0), order.count - 1)]
        } else if command == "accept" { iridiumMenuActivate(menuFocus) }
    }
}

struct LibraryLiveLogs''')
    return text + credits_view


# All user-facing native pages. Never patch SwiftSteam auth/network implementations.
PAGES = {
    'Library.swift': ['folder.lastPathComponent', '"Game Options"', '"Controller binds"', '"This game\'s config"', '"Find on Steam"'],
    'JITSetup.swift': ['"JIT setup"'],
    'ConfigCatalog.swift': ['"All settings"'],
    'MadeiraDockView.swift': ['"Madeira Dock"'],
    'SteamGames.swift': ['"Steam"'],
    'SteamSignInView.swift': ['"Steam"'],
}


def settings_notes(text):
    # Runtime comments describe investigations, not help for people using settings.
    pattern = r'(note: )("(?:[^"\\]|\\.)*")'
    def clean(match):
        note = json.loads(match[2])
        if re.search(r'\bml\d+\b|as before|previous (?:bar|gate|behavior)', note, re.I):
            note = ""
        return match[1] + json.dumps(note, ensure_ascii=False)
    return re.sub(pattern, clean, text)


def apply(name, text):
    if name == 'ConfigCatalog.generated.swift': text = settings_notes(text)
    if name == 'Library.swift': text = library(text)
    for title in PAGES.get(name, []):
        old = '.navigationTitle(' + title + ')'
        text = replace(text, old, '.iridiumPageSurface()' + old)
    if name == 'Onboarding.swift':
        # One app-level model/view owns setup. Keep the native Steam and Dock actions.
        text = text[:text.index('// First-run setup')] + text[text.index('struct SteamSettingsSection:'):]
        text = replace(text, '''            if onboarding.available {
                Button { onboarding.rerun() } label: { Label("Run setup again", systemImage: "wand.and.stars") }
            }
''', '')
        text = text.replace("Madeira keeps a Steam sign-in token in this device's Keychain, for this device only. Signing out removes it.", "Signing out removes this device’s saved Steam sign-in.")
    if name == 'JITSetup.swift':
        start = text.index('struct JITSettingsSection: View')
        text = text[:start] + re.sub(r'\bMadeira\b(?! (?:Dock|JIT))', 'Iridium', text[start:])
    if name == 'JITSetup.swift':
        text = replace(text, '''            if onboarding.available {
                Button {
                    onboarding.rerun()
                } label: {
                    Label("Run setup again", systemImage: "wand.and.stars")
                }
            }
''', '')
        text = text.replace('"StikDebug is installed, so Madeira will open it directly."', '"The selected StikDebug route is detected."')
        text = text.replace('"StikDebug was not detected, so Madeira will use its built-in helper."', '"The selected StikDebug route was not detected. Automatic will use the built-in helper."')
        text = text.replace('let message = "StikDebug is not installed. Install it or choose Built-in StikJIT."', 'let message = IridiumStikDebugRoute.current.unavailableMessage')
        text = replace(text, '    @State private var importing = false', '    @State private var importing = false\n    @AppStorage(IridiumStikDebugRoute.settingsKey) private var iridiumStikRoute = IridiumStikDebugRoute.standalone.rawValue')
        text = replace(text, '                    LabeledContent("StikDebug",', '                    LabeledContent(IridiumStikDebugRoute.current == .standalone ? "StikDebug" : "Container route",')
        text = text.replace('value: StikJITHelper.isAvailable ? "Installed" : "Not detected")', 'value: StikJITHelper.isAvailable ? "Detected" : "Not detected")')
        text = replace(text, '                if coordinator.method != .stikDebug {', '''                if coordinator.method != .builtIn {
                    Section {
                        Picker("Open StikDebug In", selection: $iridiumStikRoute) {
                            ForEach(IridiumStikDebugRoute.allCases) { route in Text(route.title).tag(route.rawValue) }
                        }.disabled(coordinator.busy)
                    } footer: {
                        if IridiumStikDebugRoute.current != .standalone { Text("Install StikDebug inside the selected container.") }
                    }
                }
                if coordinator.method != .stikDebug {''')

    if name == 'StikJITHelper.swift':
        text = replace(text, '        guard let url = URL(string: "stikdebug://enable-jit") else { return false }', '        let url = IridiumStikDebugRoute.current.probeURL')
        text = replace(text, '        guard let url = components.url else {', '''        let route = IridiumStikDebugRoute.current
        guard route == .standalone || getenv("LC_HOME_PATH") == nil else {
            completion(.failure(NSError(domain: "IridiumJITRoute", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Start Iridium with JIT from LiveContainer, or choose standalone StikDebug."])))
            return
        }
        guard let request = components.url, let url = route.destination(for: request) else {''')

    if name == 'JITSetup.swift':
        text = replace(text, '''                            Link("Install StikDebug",
                                 destination: URL(string: "https://github.com/StikDebug/StikDebug/releases/latest")!)''', '''                            if IridiumStikDebugRoute.current == .standalone {
                                Link("Install StikDebug", destination: URL(string: "https://github.com/StikDebug/StikDebug/releases/latest")!)
                            } else {
                                Text(IridiumStikDebugRoute.current.unavailableMessage).foregroundStyle(.secondary)
                                Link("Get LiveContainer", destination: URL(string: "https://github.com/LiveContainer/LiveContainer/releases/latest")!)
                            }''')
        text = text.replace('Label("JIT setup",', 'Label("Set Up JIT",')
        text = text.replace('Picker("JIT method",', 'Picker("Connection method",')
        text = text.replace('Text("JIT method")', 'Text("Connection method")')
        text = text.replace('Text("JIT")', 'Text("JIT · Faster Execution")')
        text = text.replace('When LocalDevVPN can\'t reach this device, Enable JIT runs your \\(JITNetworkShortcut.name) shortcut: it turns Cellular Data off when there\'s no Wi-Fi and connects LocalDevVPN, then puts both back once the game has started. Each run opens Shortcuts for a moment.', 'The shortcut connects LocalDevVPN for you. Without Wi-Fi it temporarily turns off cellular data, then restores your network settings after launch.')
        text = replace(text, 'Automatic uses StikDebug when it is installed. Iridium does not silently change methods after a failure.',
                       'Automatic opens StikDebug when it is installed. Otherwise, it uses the built-in helper.')
    if name == 'Library.swift':
        text = text.replace("Off by default. On a 120 Hz display, keeps the panel at 120 Hz during a game's 60 FPS limit so a frame that misses one refresh waits 8 ms instead of 17 ms. Uses more power.", "Keeps supported displays at their highest refresh rate during games. Uses more power.")
        concise = {
            "Reduced-precision x87 can make older games faster": "Use compatibility options when a game needs them. Changes apply next launch; precision changes may require restarting Iridium.",
            "Directly: the game is Wine's first program": "Start the game on its own, or use the Wine desktop for launchers and desktop windows.",
            "The working folder is a C:": "Use a Windows path for the working folder. Enable Windows services only if your launcher needs them.",
            "Lines in madeira.cfg's format for this game only.": "Keys here override shared settings for this game. Changes apply next launch.",
        }
        for prefix, copy in concise.items():
            original = next(line for line in text.splitlines() if ('Text("' + prefix) in line)
            text = replace(text, original, original[:len(original) - len(original.lstrip())] + 'Text(' + json.dumps(copy) + ')')
        text = text.replace('Arrange buttons and choose XInput, mouse, or keyboard actions from the in-game menu.', 'Edit layouts and reusable profiles above.')
        text = text.replace("XInput and DirectInput: for games older than XInput, which read the pad through DirectInput. The same pad is offered through both APIs, so a game that reads both may list two controllers. Applies to the next launch.", "DirectInput supports older games. Changes apply next launch.")
        text = text.replace("Keyboard and mouse: for games without controller support. The controller presses keys and moves the mouse (left stick WASD, right stick mouse, triggers click, D-pad arrows, Start Esc, Select Tab) and the game sees no controller. Change what each button does under Controller binds, here or in the in-game menu.", "Map the controller to keys and pointer movement under Controller Binds.")
        text = text.replace('Passed to the program on every start; the line above is the command that runs. The flags add or remove themselves; the renderer flags exclude each other, as do -windowed and -fullscreen.', 'Applied when this game starts. The command above includes your selected flags.')
    if name == 'Library.swift':
        text = text.replace('mbPicker("JIT pool",', 'mbPicker("Code translation memory",')
        text = text.replace('mbPicker("Swap tier",', 'mbPicker("Extra storage for memory",')
        text = text.replace('Picker("Swap coverage",', 'Picker("Memory fallback coverage",')
        text = text.replace('Picker("Sync engine",', 'Picker("Synchronization method",')
        text = text.replace('Toggle("Eco mode",', 'Toggle("Lower power priority",')
        text = text.replace('Text("Memory & sync")', 'Text("Advanced Runtime Tuning")')
        text = text.replace('All settings (\\(ConfigCatalog.generated.count - Self.featuredKeys.count) more)', 'All Compatibility Options')
        text = text.replace('JIT pool is the memory reserved at launch for translated x86 code (256 to 1152 MB; below 512 MB, large games can run out of room for it).', 'Code translation memory is reserved when a game starts. Low values can prevent large games from running.')
        text = text.replace('Video memory is how much graphics memory games are told they have. Automatic sizes it from the memory free at launch. Too high can get Madeira closed for using too much memory; too low makes games keep reloading textures.', 'Video memory is reported to the game. Automatic is recommended; high values can cause memory-related exits.')
        text = text.replace("Swap tier moves game data to a file on this device's storage when memory runs short, up to the chosen size, at some speed cost. Coverage decides which allocations it moves: large ones only (8 MB and up, the default), every allocation of 1 MB and up, or those plus allocations that overflow the game's address range. Broad backs every new reservation of 4 MB and up (madeira.cfg swap-min-mb moves the floor) as it is made, so the small commits games make inside it are covered too, and the swap tier size limits the storage it uses. Wider coverage saves more memory but can slow a game down.", 'Memory fallback uses device storage when memory runs short. It can help a game finish loading, but uses storage and may reduce performance. Turn it on before changing coverage.')
        text = text.replace("Sync engine: Fastsync (the default) handles events and semaphores in-process; its per-game options are in each game's details. Madsync is the older in-process engine. Wine standard sync uses neither. Only one engine runs at a time.", 'Keep the default synchronization method unless a game needs another method. Per-game synchronization options are in Game Options.')
        text = text.replace('Eco mode starts every game with its threads at a low priority, which saves power but makes games run slower. Off by default. It is meant for loading screens: Eco mode in the in-game menu turns it on and off while a game runs.', 'Lower power priority can reduce power use and game performance. It can also be changed while playing.')
        text = text.replace('Restart Madeira (close it from the app switcher) for these changes to apply.', 'Close and reopen Iridium to apply these changes.')
    if name == 'ContentView.swift':
        text = text.replace('Button("Choose") {', 'Button("Review Save Conflicts") {')
        text = text.replace('Button("Launch anyway") {', 'Button("Play with This Device’s Saves") {')
        text = text.replace('Madeira does not know whether', 'Iridium could not check whether')
    if name == 'SteamGames.swift':
        text = text.replace('Upload saves and close Madeira', 'Upload Saves & Close Iridium')
        text = text.replace('Not uploaded, Madeira stays open:', 'Upload failed. Iridium stays open:')
        text = text.replace('Files › Madeira › Steam Cloud Backups', 'Files › Iridium › Steam Cloud Backups')
        text = text.replace("Save in the game first. Uploads this game's saves to Steam Cloud, then closes Madeira; Steam in this session is signed out when the upload starts.",
                            "Save in the game first. Uploading signs out this Steam session and closes Iridium when it finishes.")
        text = text.replace("Saves sync with Steam Cloud when Madeira starts and when this page opens, not while you play: use Upload Saves & Close Iridium in the game menu when you stop, or what you played is uploaded the next time Madeira starts. A save that differs on both sides, or that is missing on this device, is never replaced without asking, and a save a sync replaces is kept in Files › Iridium › Steam Cloud Backups.",
                            "Saves sync when Iridium opens or when you open this page. After playing, use Upload Saves & Close Iridium in the game menu. Conflicts need your choice; replaced saves are kept in Files › Iridium › Steam Cloud Backups.")
        text = replace(text, 'See your Steam games here and install them without leaving Madeira.', 'View and download your Steam games.')
        text = replace(text, '''            }.padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))''',
                       '''            }.padding(14).modifier(IridiumGlassSurface(radius: 20))''')
    if name == 'SteamSignInView.swift':
        text = replace(text, 'Madeira keeps a Steam sign-in so it can start your Steam games with your own account.', 'Sign in to view, download, and start your Steam games.')
        text = replace(text, 'Madeira signs in with Steam directly.', 'Iridium signs in with Steam directly.')
    if name in PAGES:
        # Group distributes a row material across a Form's native sections.
        # The pin's multiline Forms have a closing brace at their opening indent.
        for match in reversed(list(re.finditer(r'(?m)^( +)Form \{$', text))):
            indent = match.group(1)
            close = re.search(r'(?m)^' + indent + r'}(?=[.\n])', text[match.end():])
            if not close: raise ValueError('Unbalanced presentation Form: ' + name)
            end = match.end() + close.start()
            text = text[:end] + indent + '    }.iridiumRowSurface()\n' + text[end:]
            text = text[:match.end()] + '\n' + indent + '    Group {' + text[match.end():]
    return madeira_jit_lifecycle.apply(name, madeira_artwork_presentation.apply(name, madeira_player_presentation.apply(name, text)))
