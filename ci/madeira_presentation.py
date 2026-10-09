"""Presentation-only edits to the pinned SwiftUI views. Native actions stay upstream."""
import json
import re
import madeira_player_presentation
import madeira_artwork_presentation


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
    cases = '\n'.join(f'''case "{title}": Form {{ Group {{ {sections} }}.iridiumRowSurface() }}.iridiumPageSurface().navigationTitle("{title}")
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
    settings = '''    private var settings: some View {
        Form {
            Section { LibraryStatus() }.iridiumRowSurface()
            Section {
                ''' + setting('Launch Support', 'JITSettingsSection()') + '''
                ''' + setting('Pointer', 'Section { LibraryPointerSettings() }.iridiumRowSurface()') + '''
                ''' + setting('Display & Runtime', '''DisplayRateSettings()
                        if MadeiraConfig.flag("MADEIRA_RUNTIME_SETTINGS") {
                            RuntimeMemorySyncSettings(open: { settingsSheet = $0 }, refresh: settingsRefresh)
                        }''') + '''
                ''' + setting('Files & Saves', 'SavesSection()') + '''
            }.iridiumRowSurface()
            Section {
                if SteamSettingsSection.shown {
                    ''' + setting('Steam Account & Dock', 'SteamSettingsSection(open: { settingsSheet = $0 })') + '''
                }
                ''' + setting('Windows Components', 'WineMonoSettingsSection()') + '''
                ''' + setting('Advanced', '''Section { Toggle("Extended logging", isOn: $input.diagnostics) }.iridiumRowSurface()
                        Section { Button("All Runtime Settings") { settingsSheet = .allSettings } }.iridiumRowSurface()''') + '''
                ''' + setting('Appearance', '''Section { Toggle("Liquid metal", isOn: $liquidMetal.on) } footer: {
                            Text("Adds moving reflections to Madeira's desktop controls.")
                        }.iridiumRowSurface()''') + '''
                ''' + setting('Credits', credits) + '''
            }.iridiumRowSurface()
        }
'''
    text = replace(text, original, settings)
    text = replace(text, settings_body, '''        NavigationStack(path: $iridiumPages) {
          ScrollViewReader { proxy in
            settings
            .iridiumPageSurface().navigationTitle("Settings")
            .toolbar { settingsToolbar }
            ''' + destination_pages(settings_pages) + '''
            ''' + keyboard_navigation() + '''
            .onChange(of: iridiumFocus) { _, title in proxy.scrollTo(title, anchor: .center) }
          }
        }
''')
    text = replace(text, 'struct LibraryView: View {', 'struct LibraryView: View {\n    @Environment(\\.dismiss) private var iridiumDismiss\n' + navigation_state('Launch Support'))
    text = replace(text, '    @ToolbarContentBuilder private var libraryToolbar:', hub_navigation(settings_pages, 'iridiumDismiss()') + '    @ToolbarContentBuilder private var libraryToolbar:')
    text = replace(text, '    @ToolbarContentBuilder private var settingsToolbar: some ToolbarContent {', '''    @ToolbarContentBuilder private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { iridiumDismiss() } }''')
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
    # Art remains the page's background. No opaque mini-background inside its header.
    art_background = between(header, '                        .listRowBackground(', '\n                }')
    header = header.replace(art_background, '.listRowBackground(Color.clear)')
    header = header.replace('width: 120, height: 180', 'width: 80, height: 120').replace('.padding(.vertical, 24)', '.padding(.vertical, 12)')
    header = header.replace('Text(entry.title).font(.title2.bold())', 'Text(entry.title).font(.title2.bold()).lineLimit(2)')
    detail_pages = {}
    def detail(title, sections): return page(title, sections, detail_pages)
    body = '            Form {\n' + header + '\n                Section {\n'
    body += '                    if entry.desktop != true { ' + detail('Rename & Artwork', rename) + ' }\n'
    body += '                    ' + detail('Controls', controls) + '\n'
    body += '                    ' + detail('Display', display) + '\n'
    body += '                    ' + detail('Files & Saves', 'if let appID = entry.steamAppID { SteamCloudSection(appID: appID) }\n' + files) + '\n'
    body += '                    ' + detail('Advanced', launch + config + '\nif entry.steamAppID != nil { SteamEntrySection(entry: $entry) { leaving = true; dismiss() } }') + '\n'
    body += '                }.iridiumRowSurface()\n                if entry.desktop != true { Section { IridiumFavoriteButton(entry: entry).id("Favorites").listRowBackground(iridiumGuided && iridiumFocus == "Favorites" ? Color.white.opacity(0.2) : Color.white.opacity(0.07)) } }\n                if let error { Section { Text(error).foregroundStyle(.red) } }\n            }\n' + destination_pages(detail_pages) + '\n'
    text = replace(text, form, body)
    text = replace(text, '.navigationTitle("Game details").navigationBarTitleDisplayMode(.inline)', '.navigationTitle("Game details").navigationBarTitleDisplayMode(.inline)\n            ' + keyboard_navigation())
    text = replace(text, 'struct LibraryDetail: View {', 'struct LibraryDetail: View {' + navigation_state('Controls'))
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
    detail_body = between(text, '        NavigationStack(path: $iridiumPages) {\n            Form', '\n}\n\n/// Game details')
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
    return text


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
        text = replace(text, '.background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())', '.iridiumPageSurface()')
        # Product names in the onboarding copy; protocol names/keys stay untouched.
        text = text.replace('Welcome to Madeira', 'Welcome to Iridium')
    if name in ['Onboarding.swift', 'JITSetup.swift']:
        boundary = 'struct OnboardingView: View' if name == 'Onboarding.swift' else 'struct JITSettingsSection: View'
        start = text.index(boundary)
        # Keep the Dock and actual shortcut names, identifiers and services upstream.
        text = text[:start] + re.sub(r'\bMadeira\b(?! (?:Dock|JIT))', 'Iridium', text[start:])
    if name == 'JITSetup.swift':
        text = replace(text, 'Automatic uses StikDebug when it is installed. Iridium does not silently change methods after a failure.',
                       'Automatic opens StikDebug when it is installed. Otherwise, it uses the built-in helper.')
    if name == 'SteamGames.swift':
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
    return madeira_artwork_presentation.apply(name, madeira_player_presentation.apply(name, text))
