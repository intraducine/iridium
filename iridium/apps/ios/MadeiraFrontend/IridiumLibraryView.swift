// Unified presentation; Windows behavior remains owned by Madeira.
import SwiftUI
import UniformTypeIdentifiers

struct IridiumLibraryView: View {
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void
    var startDock: (DockGame, Bool) -> Void
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var consoles = IridiumConsoleLibrary.shared
    @ObservedObject private var consoleSession = IridiumConsoleSession.shared
    @ObservedObject private var controller = LibraryController.shared
    @ObservedObject private var steamGames = SteamGamesModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var jitState = LibraryJITState.shared
    @ObservedObject private var artwork = IridiumArtworkModel.shared
    @ObservedObject private var onboarding = OnboardingModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("iridium.favoriteGames") private var favoriteIDs = ""
    @AppStorage("iridium.selectedGame") private var pageArtwork = ""
    @State private var favorites = false
    @State private var search = ""
    @State private var searching = false
    @State private var selectedID: UUID?
    @State private var selection = IridiumLibrarySelection()
    @State private var carouselPosition = ScrollPosition(idType: UUID.self)
    @State private var detail: LibraryEntry?
    @State private var consoleDetail: IridiumConsoleGame?
    @State private var importingFiles = false
    @State private var features: Int?
    @State private var fileSource: IridiumImportSource?
    @State private var pendingDetail: LibraryEntry?
    @State private var choosingAdd = false
    @State private var pendingAdd: IridiumAddGameSource?
    @State private var artworkDetail: IridiumGame?
    @State private var showHints = false
    @State private var showFocus = false
    @State private var focus = "games"
    @FocusState private var searchFocus: Bool
    @FocusState private var keyboardFocus: Bool

    private var games: [IridiumGame] {
        let all = library.entries.filter { $0.desktop != true }.map { IridiumGame(windows: $0) }
            + consoles.games.map { IridiumGame(console: $0) }
        return all.filter {
            (!favorites || isFavorite($0)) && (search.isEmpty || artwork.title($0).localizedCaseInsensitiveContains(search))
        }
    }
    private var selected: IridiumGame? { games.first { $0.id == selectedID } ?? games.first }
    private func isFavorite(_ entry: IridiumGame) -> Bool {
        favoriteIDs.split(separator: ",").contains(Substring(entry.id.uuidString))
    }
    private func launch(_ game: IridiumGame) {
        do {
            if game.windows != nil {
                try IridiumWindowsDriver(start: play).launch(gameID: game.id)
            } else if let console = game.console {
                try IridiumConsoleDriver(game: console).launch(gameID: game.id)
            }
        } catch { library.error = error.localizedDescription }
    }
    private func options(_ game: IridiumGame) {
        if let windows = game.windows { detail = windows }
        else { consoleDetail = game.console }
    }
    private func keepSelection() {
        let target = selection.reconcile(games.map(\.id))
        selectedID = selection.selectedID
        if let target { carouselPosition.scrollTo(id: target, anchor: .leading) }
    }
    private func select(_ id: UUID) {
        if let target = selection.select(id) {
            selectedID = selection.selectedID
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                carouselPosition.scrollTo(id: target, anchor: .leading)
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let gutter: CGFloat = geometry.size.width > 700 ? 32 : 20
            ZStack {
                Color.black.ignoresSafeArea()
                IridiumLibraryBackdrop(game: selected)
                    .overlay { IridiumBackdropScrim() }
                    .ignoresSafeArea().allowsHitTesting(false)
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
                                .scrollPosition($carouselPosition, anchor: .leading)
                                .contentMargins(.horizontal, gutter, for: .scrollContent)
                                .padding(.horizontal, -gutter)
                                .onScrollGeometryChange(for: Int.self) { scroll in
                                    Int(((scroll.contentOffset.x + scroll.contentInsets.leading) / (height / 1.5 + 20)).rounded())
                                } action: { _, index in
                                    guard games.indices.contains(index) else { return }
                                    selection.observed(games[index].id)
                                }
                                .onScrollPhaseChange { _, phase in
                                    let next: IridiumLibrarySelection.Phase
                                    switch phase {
                                    case .idle: next = .idle
                                    case .tracking: next = .tracking
                                    case .interacting: next = .interacting
                                    case .decelerating: next = .decelerating
                                    case .animating: next = .animating
                                    @unknown default: next = .idle
                                    }
                                    if next == .tracking || next == .interacting { showFocus = false; showHints = false }
                                    let target = selection.transition(to: next)
                                    selectedID = selection.selectedID
                                    if let target { carouselPosition.scrollTo(id: target, anchor: .leading) }
                                }
                                .onChange(of: height) { _, _ in keepSelection() }
                        }
                    } else {
                        Group {
                            if !search.isEmpty { ContentUnavailableView.search(text: search) }
                            else if favorites {
                                ContentUnavailableView("No favorites yet", systemImage: "heart",
                                    description: Text("Add favorites through Game Options."))
                            } else {
                                ContentUnavailableView("Add your first game", systemImage: "gamecontroller",
                                    description: Text(IridiumConsoleLibrary.supportsPSP ?
                                        "Choose Files or Steam from Add Game (+). Windows, Game Boy and PSP games appear together." :
                                        "Choose Files or Steam from Add Game (+). Windows and Game Boy games appear together."))
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
                guard !consoleSession.isActive, consoleDetail == nil, !importingFiles, features == nil, detail == nil, fileSource == nil, !choosingAdd, artworkDetail == nil, !onboarding.presented else { return }
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
                if phase == .active && !consoleSession.isActive {
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
                library.showDetail = nil; features = nil; fileSource = nil
                detail = library.entries.first { $0.id == id }
            }
            .onChange(of: selectedID) { _, _ in pageArtwork = selected?.id.uuidString ?? "" }
            // Display-name edits can change search membership without changing
            // either runtime's records. Reconcile only the effective identities.
            .onChange(of: games.map(\.id)) { _, _ in keepSelection() }
            .onChange(of: consoles.error) { _, error in if let error { library.error = error; consoles.error = nil } }
            .onChange(of: consoleSession.error) { _, error in
                if !consoleSession.isActive, let error { library.error = error; consoleSession.error = nil }
            }
            .task(id: steamGames.games) {
                for game in steamGames.games where game.installed {
                    guard !Task.isCancelled else { return }
                    await library.refreshSteamMetadata(game, title: game.name)
                }
            }
            .task(id: selected?.id) {
                if let selected { await artwork.prepare(selected) }
            }
            .task(id: games.map(\.id)) {
                for game in games {
                    guard !Task.isCancelled else { return }
                    await artwork.prepare(game)
                }
            }
            .sheet(item: $artworkDetail, onDismiss: restoreKeyboardFocus) { game in
                IridiumArtworkEditor(game: game)
            }
            .sheet(item: $consoleDetail, onDismiss: restoreKeyboardFocus) { game in
                IridiumConsoleOptions(game: game) { launch(IridiumGame(console: $0)) }
            }
            .fullScreenCover(isPresented: Binding(get: { consoleSession.presented }, set: { _ in }), onDismiss: restoreKeyboardFocus) {
                IridiumConsolePlayer()
            }
            .fileImporter(isPresented: $importingFiles, allowedContentTypes: IridiumImportSource.contentTypes, allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        if IridiumConsoleLibrary.importExtensions.contains(url.pathExtension.lowercased()) {
                            consoles.importROM(url) { select($0.id) }
                        } else { fileSource = IridiumImportSource(url: url) }
                    }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { library.error = error.localizedDescription }
                }
                restoreKeyboardFocus()
            }
            .sheet(item: $detail, onDismiss: restoreKeyboardFocus) { entry in
                LibraryDetail(entry: entry, play: play)
            }
            .sheet(isPresented: Binding(get: { features != nil }, set: { if !$0 { features = nil } }), onDismiss: {
                if let entry = pendingDetail { detail = entry; pendingDetail = nil }
                restoreKeyboardFocus()
            }) {
                if features == 0 {
                        IridiumSteamView(startDock: startDock) { entry in
                            pendingDetail = entry; features = nil
                        }
                    } else {
                        LibraryView(play: play, enableJIT: enableJIT, startDock: startDock, tab: 1)
                }
            }
            .sheet(item: $fileSource, onDismiss: restoreKeyboardFocus) { source in
                IridiumFilesImportView(source: source) { entry in
                    guard IridiumFilesImport.shouldPresentCompletion(of: source.id, currentSourceID: fileSource?.id) else { return }
                    select(entry.id); fileSource = nil
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
    private func cover(_ entry: IridiumGame, height: CGFloat) -> some View {
        Button { select(entry.id); focus = "games" } label: {
            IridiumGameArtwork(game: entry)
                .frame(width: height / 1.5, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    if selectedID == entry.id && (!showFocus || focus == "games") {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white, lineWidth: 3)
                    }
                }
        }.buttonStyle(.plain).id(entry.id)
            .accessibilityLabel(artwork.title(entry))
            .accessibilityHint("Select game. Use Play to launch.")
            .contextMenu {
                Button("Game Options", systemImage: "slider.horizontal.3") { options(entry) }
                Button("Edit Artwork", systemImage: "photo") { artworkDetail = entry }
            }
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
    private func title(_ entry: IridiumGame) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(artwork.title(entry)).font(.title.bold()).lineLimit(2).truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            Text(entry.platform.title + " · " + readiness(entry)).font(.caption).foregroundStyle(.white.opacity(0.75))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func readiness(_ game: IridiumGame) -> String {
        guard let runtime = try? IridiumRuntimeRegistry.resolve(platform: game.platform, preferred: game.console?.runtimeID) else { return "Runtime unavailable" }
        if LibraryModel.sessionsThisRun > 0 || consoleSession.phase == .restartRequired { return "Restart required" }
        if runtime.jit == .required { return jitState.enabled ? "JIT ready" : "JIT setup required" }
        if runtime.jit == .optional { return jitState.enabled ? "JIT ready" : "Interpreter available" }
        return "JIT not required"
    }
    private func actions(_ entry: IridiumGame) -> some View {
        HStack(spacing: 18) {
            Button { launch(entry) } label: { Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 22).padding(.vertical, 12) }
                .buttonStyle(.plain).foregroundStyle(.black).background(.white, in: Capsule())
                .overlay { Capsule().strokeBorder(showFocus && focus == "play" ? .white : .clear, lineWidth: 3).padding(-5) }
                .disabled(library.launching || consoleSession.isActive || consoles.working).keyboardShortcut("p", modifiers: [])
            Button { options(entry) } label: { Label("Game Options", systemImage: "ellipsis").padding(.vertical, 12) }
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
        guard !searchFocus, !consoleSession.isActive else { return .ignored }
        showFocus = true; showHints = false; command(value); return .handled
    }
    private func closePages() { artworkDetail = nil; detail = nil; features = nil; pendingDetail = nil; fileSource = nil; pendingAdd = nil; choosingAdd = false }
    private func finishAdding() {
        defer { pendingAdd = nil; restoreKeyboardFocus() }
        switch pendingAdd {
        case .steam: features = 0
        case .files: importingFiles = true
        default: break
        }
    }
    private func restoreKeyboardFocus() {
        keyboardFocus = detail == nil && consoleDetail == nil && !consoleSession.isActive && !importingFiles && features == nil && fileSource == nil && !choosingAdd && artworkDetail == nil && !onboarding.presented
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
            } else if focus == "games", let index = games.firstIndex(where: { $0.id == (selection.deferredFocusID ?? selectedID) }), !games.isEmpty {
                let next = min(max(index + step, 0), games.count - 1)
                select(games[next].id)
            } else {
                let row = toolbar.contains(focus) ? toolbar : actions
                focus = row[min(max((row.firstIndex(of: focus) ?? 0) + step, 0), row.count - 1)]
            }
        case "play": if let selected { launch(selected) }
        case "add": choosingAdd = true
        case "menu": if let selected { options(selected) }
        case "accept":
            switch focus {
            case "filters": favorites.toggle(); keepSelection()
            case "search": searching = true; searchFocus = true
            case "add": choosingAdd = true
            case "settings": features = 1
            case "options", "games": if let selected { options(selected) }
            default: if let selected { launch(selected) }
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
