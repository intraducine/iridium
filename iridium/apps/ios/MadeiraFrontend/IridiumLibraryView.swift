// Iridium presentation. Launch, input, Steam, saves and settings belong to Madeira.
import SwiftUI

struct IridiumLibraryView: View {
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void
    var startDock: (DockGame, Bool) -> Void
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var controller = LibraryController.shared
    @ObservedObject private var steamGames = SteamGamesModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var onboarding = OnboardingModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("iridium.favoriteGames") private var favoriteIDs = ""
    @AppStorage("iridium.selectedGame") private var pageArtwork = ""
    @State private var favorites = false
    @State private var search = ""
    @State private var searching = false
    @State private var selectedID: UUID?
    @State private var detail: LibraryEntry?
    @State private var features: Int?
    @State private var adding = false
    @State private var pendingDetail: LibraryEntry?
    @State private var choosingAdd = false
    @State private var pendingAdd: Int?
    @State private var showHints = false
    @State private var showFocus = false
    @State private var focus = "games"
    @State private var importedBackdrop: (UUID, UIImage)?
    @FocusState private var searchFocus: Bool
    @FocusState private var keyboardFocus: Bool

    private var games: [LibraryEntry] {
        library.entries.filter {
            $0.desktop != true && (!favorites || isFavorite($0)) &&
                (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        }
    }
    private var selected: LibraryEntry? { games.first { $0.id == selectedID } ?? games.first }
    private func isFavorite(_ entry: LibraryEntry) -> Bool {
        favoriteIDs.split(separator: ",").contains(Substring(entry.id.uuidString))
    }
    private func keepSelection() {
        if !games.contains(where: { $0.id == selectedID }) { selectedID = games.first?.id }
    }

    var body: some View {
        GeometryReader { geometry in
            let gutter: CGFloat = geometry.size.width > 700 ? 32 : 20
            ZStack {
                Color.black.ignoresSafeArea()
                if let selected {
                    Group {
                        if let importedBackdrop, importedBackdrop.0 == selected.id {
                            Image(uiImage: importedBackdrop.1).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        } else if selected.coverFile != nil || selected.steamID != nil || selected.steamAppID != nil {
                            LibraryArtwork(entry: selected, backdrop: true)
                        }
                    }
                        .id(selected.id).transition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: selected.id)
                        .ignoresSafeArea().allowsHitTesting(false)
                    Color.black.opacity(0.55).ignoresSafeArea().allowsHitTesting(false)
                }
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if searching {
                        HStack {
                            TextField("Search games", text: $search, prompt: Text("Search games").foregroundStyle(.white.opacity(0.7)))
                                .focused($searchFocus).textInputAutocapitalization(.never)
                                .autocorrectionDisabled().submitLabel(.search)
                                .padding(12).modifier(IridiumSearchSurface()).tint(.white)
                            Button("Done", action: endSearch).buttonStyle(.bordered).tint(.white)
                        }
                    }
                    if let selected {
                        if geometry.size.width > geometry.size.height {
                            HStack(spacing: 24) { title(selected); actions(selected) }
                        } else {
                            VStack(alignment: .leading, spacing: 14) { title(selected); actions(selected) }
                        }
                        GeometryReader { space in
                            let height = max(60, min(space.size.height - 12, (geometry.size.width - 2 * gutter) * 1.5))
                            ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                HStack(spacing: 20) {
                                    ForEach(games) { entry in
                                        cover(entry, height: height)
                                    }
                                    // Real content space lets even the last cover reach
                                    // the leading edge when every cover fits on screen.
                                    Color.clear.frame(width: max(0, geometry.size.width - height / 1.5 - 2 * gutter - 20), height: 1)
                                }.scrollTargetLayout()
                            }.scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                                .scrollPosition(id: $selectedID, anchor: .leading)
                                .contentMargins(.horizontal, gutter, for: .scrollContent)
                                .padding(.horizontal, -gutter)
                                .onChange(of: selectedID) { _, id in
                                    if let id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { proxy.scrollTo(id, anchor: .leading) } }
                                }
                                .onChange(of: height) { _, _ in if let id = selectedID { proxy.scrollTo(id, anchor: .leading) } }
                            }
                        }
                    } else {
                        Group {
                            if !search.isEmpty { ContentUnavailableView.search(text: search) }
                            else if favorites {
                                ContentUnavailableView("No favorites yet", systemImage: "heart",
                                    description: Text("Add favorites through Game Options."))
                            } else {
                                ContentUnavailableView("Add your first game", systemImage: "gamecontroller",
                                    description: Text("Use Add Game (+) to open Steam or choose a Windows executable."))
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if showHints {
                        HStack(spacing: 20) {
                            HStack(spacing: 6) { faceHint(bottom: true); Text("Select") }
                            HStack(spacing: 6) { faceHint(bottom: false); Text("Back") }
                            Label("Move", systemImage: "dpad")
                            Text("LB / RB: Library")
                        }.font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.bottom, 4)
                    }
                }.padding(.horizontal, gutter).padding(.vertical, 12)
            }
        }.preferredColorScheme(.dark).navigationBarHidden(true)
            .focusable().focusEffectDisabled().focused($keyboardFocus)
            .simultaneousGesture(TapGesture().onEnded { showHints = false; showFocus = false })
            .onKeyPress(.leftArrow) { key("left") }
            .onKeyPress(.rightArrow) { key("right") }
            .onKeyPress(.upArrow) { key("up") }
            .onKeyPress(.downArrow) { key("down") }
            .onKeyPress(.return) { key("accept") }
            .onKeyPress(.escape) { command("back"); return .handled }
            .onReceive(controller.commands) { value in
                guard features == nil, detail == nil, !adding, !choosingAdd, !onboarding.presented else { return }
                showHints = true; showFocus = true; command(value)
            }
            .onAppear {
                library.refreshFlag(); keepSelection(); steamGames.refresh(); keyboardFocus = true
                pageArtwork = selected?.id.uuidString ?? ""
                EndedSessionSurface.install(); EndedSessionSurface.hide(reason: "library-appeared")
                onboarding.presentIfNeeded()
                if SteamOwnedLibrary.enabled { steam.start(); steam.reconcileSession() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    library.refreshFlag(); steamGames.refresh()
                    if SteamOwnedLibrary.enabled { steam.reconcileSession() }
                }
            }
            .onChange(of: library.current) { _, value in if value != nil { closePages() } }
            .onChange(of: library.error) { _, value in if value != nil { closePages() } }
            .onChange(of: library.restartNotice) { _, value in if value != nil { closePages() } }
            .onChange(of: library.jitNotice) { _, value in if value != nil { closePages() } }
            .onChange(of: library.cloudNotice) { _, value in if value != nil { closePages() } }
            .onChange(of: jit.showSetup) { _, value in if value { closePages() } else { restoreKeyboardFocus() } }
            .onChange(of: library.showDetail) { _, id in
                guard let id else { return }
                library.showDetail = nil; features = nil; adding = false
                detail = library.entries.first { $0.id == id }
            }
            .onChange(of: search) { _, _ in keepSelection() }
            .onChange(of: favoriteIDs) { _, _ in keepSelection() }
            .onChange(of: selectedID) { _, _ in pageArtwork = selected?.id.uuidString ?? "" }
            .onChange(of: library.entries.map(\.id)) { _, _ in keepSelection() }
            .task(id: steamGames.games) {
                for game in steamGames.games where game.installed {
                    guard !Task.isCancelled else { return }
                    await library.refreshSteamMetadata(game, title: game.name)
                }
            }
            .task(id: selected?.id) {
                importedBackdrop = nil
                guard let id = selected?.id else { return }
                let data = try? await Task.detached(priority: .utility) { () -> Data? in
                    guard let name = try IridiumImportPreferences.appearances()[id]?.background else { return nil }
                    return try Data(contentsOf: IridiumImportPreferences.image(name))
                }.value
                if !Task.isCancelled, let data, let image = UIImage(data: data) { importedBackdrop = (id, image) }
            }
            .sheet(item: $detail, onDismiss: restoreKeyboardFocus) { entry in
                LibraryDetail(entry: entry, play: play)
            }
            .sheet(isPresented: Binding(get: { features != nil }, set: { if !$0 { features = nil } }), onDismiss: {
                if let entry = pendingDetail { detail = entry; pendingDetail = nil }
                restoreKeyboardFocus()
            }) {
                if features == 2 {
                    IridiumLibraryImportView { selectedID = $0; features = nil }
                } else {
                    if features == 0 {
                        IridiumSteamView(startDock: startDock) { entry in
                            pendingDetail = entry; features = nil
                        }
                    } else {
                        LibraryView(play: play, enableJIT: enableJIT, startDock: startDock, tab: 1)
                    }
                }
            }
            .sheet(isPresented: $adding, onDismiss: {
                detail = pendingDetail; pendingDetail = nil
                restoreKeyboardFocus()
            }) {
                NavigationStack {
                    ExecutableBrowser(folder: LibraryModel.drive) { entry in
                        library.save(entry); selectedID = entry.id; pendingDetail = entry; adding = false
                    }
                }
            }
            .sheet(isPresented: $choosingAdd, onDismiss: finishAdding) {
                IridiumAddGameView { pendingAdd = $0; choosingAdd = false }
            }
            .fullScreenCover(isPresented: $onboarding.presented, onDismiss: restoreKeyboardFocus) { OnboardingView() }
            .alert("Could not start", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                if let problem = JITCoordinator.shared.connectionProblem, library.error == problem.message {
                    jitConnectionActions(problem, retry: enableJIT) { library.error = nil }
                }
                Button("OK", role: .cancel) { library.error = nil }
            } message: { Text(library.error ?? "") }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { Text("Iridium").font(.largeTitle.bold()); filters; toolbar }
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("Iridium").font(.largeTitle.bold()); Spacer(); toolbar }
                filters
            }
        }
    }
    private func cover(_ entry: LibraryEntry, height: CGFloat) -> some View {
        Button { selectedID = entry.id; focus = "games" } label: {
            LibraryArtwork(entry: entry)
                .frame(width: height / 1.5, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    if selectedID == entry.id && (!showFocus || focus == "games") {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white, lineWidth: 3)
                    }
                }
        }.buttonStyle(.plain).id(entry.id)
            .accessibilityLabel(entry.title)
            .accessibilityAddTraits(selectedID == entry.id ? .isSelected : [])
    }
    private var filters: some View {
        Picker("Library", selection: Binding(get: { favorites }, set: { favorites = $0; keepSelection() })) {
            Text("All Games").tag(false); Text("Favorites").tag(true)
        }.pickerStyle(.segmented).frame(minWidth: 220, maxWidth: 380).background(focusShape("filters"))
    }
    private var toolbar: some View {
        HStack(spacing: 16) {
            tool("Search", icon: "magnifyingglass", id: "search") { searching = true; searchFocus = true }
            tool("Add Game", icon: "plus", id: "add") { choosingAdd = true }
            tool("Settings", icon: "gearshape", id: "settings") { features = 1 }
        }.frame(maxWidth: .infinity, alignment: .trailing)
    }
    private func tool(_ label: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 44, height: 44) }
            .accessibilityLabel(label).buttonStyle(.plain).background(focusShape(id))
    }
    private func title(_ entry: LibraryEntry) -> some View {
        Text(entry.title).font(.title.bold()).lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
    }
    private func actions(_ entry: LibraryEntry) -> some View {
        HStack(spacing: 18) {
            Button { play(entry) } label: { Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 22).padding(.vertical, 12) }
                .buttonStyle(.plain).foregroundStyle(.black).background(.white, in: Capsule())
                .overlay { Capsule().strokeBorder(showFocus && focus == "play" ? .white : .clear, lineWidth: 3).padding(-5) }
                .disabled(library.launching).keyboardShortcut("p", modifiers: [])
            Button { detail = entry } label: { Label("Game Options", systemImage: "ellipsis").padding(.vertical, 12) }
                .buttonStyle(.plain).background(focusShape("options"))
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func focusShape(_ id: String) -> some View {
        Capsule().fill(showFocus && focus == id ? Color.white.opacity(0.2) : .clear)
    }
    private func faceHint(bottom: Bool) -> some View {
        // Positions, rather than controller-brand letters, identify Select/Back.
        ZStack {
            ForEach(0..<4) { index in
                Circle().fill(index == (bottom ? 2 : 1) ? Color.white : Color.white.opacity(0.25))
                    .frame(width: 6, height: 6)
                    .offset(x: index == 1 ? 7 : index == 3 ? -7 : 0,
                            y: index == 0 ? -7 : index == 2 ? 7 : 0)
            }
        }.frame(width: 22, height: 22).accessibilityHidden(true)
    }
    private func endSearch() { searching = false; search = ""; searchFocus = false; keyboardFocus = true }
    private func key(_ value: String) -> KeyPress.Result {
        guard !searchFocus else { return .ignored }
        showFocus = true; showHints = false; command(value); return .handled
    }
    private func closePages() { detail = nil; features = nil; pendingDetail = nil; adding = false; pendingAdd = nil; choosingAdd = false }
    private func finishAdding() {
        defer { pendingAdd = nil; restoreKeyboardFocus() }
        switch pendingAdd {
        case 0: features = 0
        case 1: adding = true
        case 2: features = 2
        case 3: detail = library.entries.first { $0.desktop == true } ?? .desktopEntry
        default: break
        }
    }
    private func restoreKeyboardFocus() {
        keyboardFocus = detail == nil && features == nil && !adding && !choosingAdd && !onboarding.presented
    }
    private func command(_ value: String) {
        guard !searchFocus else { if value == "back" { endSearch() }; return }
        let toolbar = ["search", "add", "settings"], actions = ["play", "options"]
        switch value {
        case "tab": favorites.toggle(); keepSelection()
        case "up": focus = actions.contains(focus) ? "search" : toolbar.contains(focus) ? "filters" : "play"
        case "down": focus = focus == "filters" ? "search" : toolbar.contains(focus) ? "play" : "games"
        case "left", "right":
            let step = value == "left" ? -1 : 1
            if focus == "filters" {
                favorites = step > 0; keepSelection()
            } else if focus == "games", let index = games.firstIndex(where: { $0.id == selectedID }), !games.isEmpty {
                let next = min(max(index + step, 0), games.count - 1)
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { selectedID = games[next].id }
            } else {
                let row = toolbar.contains(focus) ? toolbar : actions
                focus = row[min(max((row.firstIndex(of: focus) ?? 0) + step, 0), row.count - 1)]
            }
        case "play": if let selected { play(selected) }
        case "add": choosingAdd = true
        case "menu": detail = selected
        case "accept":
            switch focus {
            case "filters": favorites.toggle(); keepSelection()
            case "search": searching = true; searchFocus = true
            case "add": choosingAdd = true
            case "settings": features = 1
            case "options", "games": detail = selected
            default: if let selected { play(selected) }
            }
        case "back": if searching { endSearch() } else { focus = "games" }
        default: break
        }
    }
}

private struct IridiumSearchSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16)) }
        else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
    }
}
