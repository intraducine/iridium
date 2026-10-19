// Iridium-owned library presentation; engine operations use explicit services.
import SwiftUI
import UniformTypeIdentifiers

struct IridiumLibraryView: View {
    let services: IridiumLibraryServices
    private var play: (LibraryEntry) -> Void { services.windows.launch }
    private var enableJIT: () -> Void { services.jit.enableForPlaying }
    private var startDock: (DockGame, Bool) -> Void { { services.windows.launchSteam($0, compactPool: $1) } }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("iridium.favoriteGames") private var favoriteIDs = ""
    @AppStorage("iridium.selectedGame") private var pageArtwork = ""
    @AppStorage(IridiumLibraryOrder.settingsKey) private var savedOrder = ""
    @State private var reorderSession = IridiumLibraryDragSession()
    @State private var selectionFeedback = UISelectionFeedbackGenerator()
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
    @State private var supportPrompt = false
    @State private var pendingSupportGame: IridiumConsoleGame?
    @State private var supportLaunchRequested = false
    @State private var lastLaunchNeedsSupport = false
    @State private var artworkDetail: IridiumGame?
    @State private var showHints = false
    @State private var showFocus = false
    @State private var focus = "games"
    @State private var chromeHeight: CGFloat = 0
    @State private var wideLayout = false
    @State private var touchCoverHeight: CGFloat?
    @FocusState private var searchFocus: Bool
    @FocusState private var keyboardFocus: Bool

    private var allGames: [IridiumGame] {
        let all = library.entries.filter { $0.desktop != true }.map { IridiumGame(windows: $0) }
            + consoles.games.map { IridiumGame(console: $0) }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return IridiumLibraryOrder.ordered(all.map(\.id), saved: savedOrder).compactMap { byID[$0] }
    }
    private var games: [IridiumGame] {
        allGames.filter {
            (!favorites || isFavorite($0)) && (search.isEmpty || artwork.title($0).localizedCaseInsensitiveContains(search))
        }
    }
    private var selected: IridiumGame? { games.first { $0.id == selection.highlightedID } ?? games.first }
    private func isFavorite(_ entry: IridiumGame) -> Bool {
        favoriteIDs.split(separator: ",").contains(Substring(entry.id.uuidString))
    }
    private func launch(_ game: IridiumGame) {
        #if IRIDIUM_UX_PREVIEW
        IridiumSimulatorLaunch.shared.attempt(game)
        return
        #endif
        lastLaunchNeedsSupport = false
        do {
            if game.windows != nil {
                try IridiumWindowsDriver(start: play).launch(gameID: game.id)
            } else if let console = game.console {
                try consoleSession.validateLaunchAdmission()
                let runtime = try IridiumRuntimeRegistry.resolve(platform: console.platform, preferred: console.runtimeID)
                lastLaunchNeedsSupport = runtime.jit == .required
                if lastLaunchNeedsSupport && !jitState.enabled {
                    supportLaunchRequested = false; pendingSupportGame = console; supportPrompt = true; return
                }
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
            let gutter: CGFloat = geometry.size.width > 1000 ? 32 : 20
            let compact = geometry.size.width > geometry.size.height
            let spacing: CGFloat = compact ? 8 : 12
            let layout = IridiumLibraryLayoutMetrics(viewportHeight: geometry.size.height, viewportWidth: geometry.size.width,
                compact: compact, chromeHeight: chromeHeight, hasSelection: selected != nil,
                showsHints: showHints, frozenCoverHeight: touchCoverHeight)
            ZStack {
                Color.black.ignoresSafeArea()
                IridiumLibraryBackdrop(game: selected, portrait: !compact)
                    .overlay { IridiumBackdropScrim() }
                    .ignoresSafeArea().allowsHitTesting(false)
                ScrollViewReader { page in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: spacing) {
                            VStack(alignment: .leading, spacing: spacing) {
                                header
                            }.fixedSize(horizontal: false, vertical: true)
                                .modifier(IridiumLibraryMeasureHeight()).id("header")
                            if let selected {
                                if layout.freeSpace > 0 {
                                    Color.clear.frame(height: layout.freeSpace).accessibilityHidden(true)
                                }
                                if !compact { details(selected, compact: compact) }
                                carousel(height: layout.coverHeight, width: geometry.size.width, gutter: gutter, landscape: compact)
                                    .frame(height: layout.coverHeight).id("games")
                                if compact { details(selected, compact: compact) }
                            } else {
                                Group {
                                    if !search.isEmpty { ContentUnavailableView.search(text: search) }
                                    else if favorites {
                                        ContentUnavailableView("No favorites yet", systemImage: "heart",
                                            description: Text("Add favorites through Game Options."))
                                    } else {
                                        ContentUnavailableView("Add your first game", systemImage: "gamecontroller",
                                            description: Text("Choose Files, Steam or a console system from Add Game (+). Games appear together in this library."))
                                    }
                                }.frame(maxWidth: .infinity, minHeight: layout.freeSpace)
                            }
                            if showHints {
                                controllerHints.fixedSize(horizontal: false, vertical: true)
                                    .modifier(IridiumLibraryMeasureHeight())
                            }
                        }.padding(.horizontal, gutter).padding(.vertical, 12)
                            .onPreferenceChange(IridiumLibraryChromeHeight.self) { chromeHeight = $0 }
                    }.scrollBounceBehavior(.basedOnSize, axes: .vertical)
                        .onChange(of: focus) { _, _ in revealFocusedSection(in: page) }
                        .onChange(of: showFocus) { _, shown in if shown { revealFocusedSection(in: page) } }
                        .onChange(of: chromeHeight) { _, _ in if showFocus { revealFocusedSection(in: page) } }
                        .onChange(of: searching) { _, active in touchCoverHeight = nil; if active { page.scrollTo("header", anchor: .top) } }
                }
            }.onChange(of: compact, initial: true) { _, value in wideLayout = value }
                .onChange(of: geometry.size.height) { _, _ in touchCoverHeight = nil }
        }.preferredColorScheme(.dark).tint(IridiumTheme.accent).navigationBarHidden(true)
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
                library.refreshFlag(); keepSelection(); services.steam.refreshInstalledGames(); keyboardFocus = true
                pageArtwork = selected?.id.uuidString ?? ""
                EndedSessionSurface.install(); EndedSessionSurface.hide(reason: "library-appeared")
                onboarding.presentIfNeeded()
                services.steam.connectAndReconcile()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && !consoleSession.isActive {
                    library.refreshFlag(); services.steam.refreshInstalledGames()
                    services.steam.reconcileIfEnabled()
                }
            }
            .onChange(of: library.current) { _, value in if value != nil { closePages() } }
            .onChange(of: library.error) { _, value in if value != nil { pendingSupportGame = nil; closePages() } }
            .onChange(of: library.restartNotice) { _, value in if value != nil { closePages() } }
            .onChange(of: library.jitNotice) { _, value in if value != nil { closePages() } }
            .onChange(of: library.cloudNotice) { _, value in if value != nil { closePages() } }
            .onChange(of: jit.showSetup) { _, value in
                if value { closePages() }
                else {
                    if jitState.enabled, let game = pendingSupportGame { pendingSupportGame = nil; launch(IridiumGame(console: game)) }
                    else { pendingSupportGame = nil }
                    supportLaunchRequested = false; restoreKeyboardFocus()
                }
            }
            .onChange(of: jitState.enabled) { _, enabled in
                if enabled, !jit.showSetup, let game = pendingSupportGame {
                    pendingSupportGame = nil; supportLaunchRequested = false; launch(IridiumGame(console: game))
                }
            }
            .onChange(of: library.showDetail) { _, id in
                guard let id else { return }
                library.showDetail = nil; features = nil; fileSource = nil
                detail = library.entries.first { $0.id == id }
            }
            .onChange(of: selection.highlightedID) { old, value in
                pageArtwork = selected?.id.uuidString ?? ""
                if old != nil, value != nil, reorderSession.active == nil, (selection.userIsScrolling || showFocus),
                   IridiumTouchHaptics.current() != .off {
                    let ids = games.map(\.id)
                    let boundaries = IridiumLibrarySelection.boundaries(from: old, to: value, in: ids)
                    // Emit now; no timer, throttle or queued work outlives this scroll update.
                    for _ in 0..<boundaries { selectionFeedback.selectionChanged() }
                    selectionFeedback.prepare()
                }
            }
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
            .fileImporter(isPresented: $importingFiles, allowedContentTypes: IridiumImportSource.contentTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    if !urls.isEmpty { fileSource = IridiumImportSource(urls: urls) }
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
                IridiumGameImportView(source: source, importedConsole: { game in
                    guard IridiumFilesImport.shouldPresentCompletion(of: source.id, currentSourceID: fileSource?.id) else { return }
                    select(game.id); fileSource = nil
                }) { entry in
                    guard IridiumFilesImport.shouldPresentCompletion(of: source.id, currentSourceID: fileSource?.id) else { return }
                    select(entry.id); fileSource = nil
                }
            }
            .sheet(isPresented: $choosingAdd, onDismiss: finishAdding) {
                IridiumAddGameView(choose: { pendingAdd = $0; choosingAdd = false })
            }
            .fullScreenCover(isPresented: onboarding.binding(for: .library), onDismiss: restoreKeyboardFocus) { OnboardingView() }
            .confirmationDialog("Enable JIT to Play", isPresented: Binding(get: { supportPrompt }, set: { value in
                supportPrompt = value
                if !value && !supportLaunchRequested { pendingSupportGame = nil }
            }), titleVisibility: .visible) {
                if let game = pendingSupportGame {
                    Button("Enable & Play") {
                        do {
                            try consoleSession.validateLaunchAdmission()
                            pendingSupportGame = game; supportLaunchRequested = true; enableJIT()
                        } catch {
                            pendingSupportGame = nil; lastLaunchNeedsSupport = false
                            library.error = error.localizedDescription
                        }
                    }
                }
                Button("Set Up JIT") { pendingSupportGame = nil; jit.showSetup = true }
                Button("Cancel", role: .cancel) { pendingSupportGame = nil }
            }
            .alert("Could not start", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                if let problem = JITCoordinator.shared.connectionProblem, library.error == problem.message {
                    jitConnectionActions(problem, retry: enableJIT) { library.error = nil }
                }
                if lastLaunchNeedsSupport { Button("Set Up JIT") { library.error = nil; jit.showSetup = true } }
                Button("OK", role: .cancel) { library.error = nil }
            } message: { Text(library.error ?? "") }
    }

    private var header: some View {
        Group {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { if !searching { filters }; toolbar }
                VStack(alignment: .leading, spacing: 8) { toolbar; if !searching { filters } }
            }
        }
    }
    private func details(_ game: IridiumGame, compact: Bool) -> some View {
        Group {
            if compact && !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 20) { title(game); actions(game) }
            } else {
                VStack(alignment: .leading, spacing: 12) { title(game); actions(game) }
            }
        }.fixedSize(horizontal: false, vertical: true)
            .modifier(IridiumLibraryMeasureHeight()).id("details")
    }
    private func carousel(height: CGFloat, width: CGFloat, gutter: CGFloat, landscape: Bool) -> some View {
        let featuredWidth = landscape ? min(height * 460 / 215, width - 2 * gutter) : height / 1.5
        return ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(games) { entry in
                    cover(entry, height: height, width: entry.id == games.first?.id ? featuredWidth : height / 1.5, featured: landscape && entry.id == games.first?.id)
                }
                // Real content space lets even the last cover reach
                // the leading edge when every cover fits on screen.
                Color.clear.frame(width: max(0, width - (games.count == 1 ? featuredWidth : height / 1.5) - 2 * gutter - 10), height: 1)
            }
                .overlayPreferenceValue(IridiumLibraryCardBounds.self) { anchors in
                    GeometryReader { proxy in
                        if let id = selection.highlightedID, let anchor = anchors[id],
                           !showFocus || focus == "games" {
                            let rect = proxy[anchor]
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white, lineWidth: 2)
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: id)
                                .accessibilityIdentifier("librarySelectionBorder")
                        }
                        if let slot = reorderSession.insertion {
                            let remaining = games.filter { $0.id != reorderSession.active?.gameID }
                            let anchor = slot.beforeID.flatMap { anchors[$0] } ?? remaining.last.flatMap { anchors[$0.id] }
                            if let anchor {
                                let rect = proxy[anchor]
                                Capsule().fill(Color.blue)
                                    .frame(width: 4, height: height)
                                    .offset(x: slot.beforeID == nil ? rect.maxX + 3 : rect.minX - 7, y: rect.minY)
                                    .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: slot)
                                    .accessibilityIdentifier("libraryInsertionLine")
                            }
                        }
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }.scrollTargetLayout()
        }.scrollIndicators(.hidden).accessibilityIdentifier("libraryCarousel")
            .scrollTargetBehavior(IridiumLibrarySnapBehavior(
                widths: games.indices.map { Double($0 == 0 ? featuredWidth : height / 1.5) },
                focusWidth: Double(height / 1.5), leadingInset: Double(gutter), enabled: selection.userIsScrolling))
            .scrollPosition($carouselPosition, anchor: .leading)
            .contentMargins(.horizontal, gutter, for: .scrollContent)
            .padding(.horizontal, -gutter)
            .onScrollGeometryChange(for: Double.self) { scroll in
                Double(scroll.contentOffset.x + scroll.contentInsets.leading)
            } action: { _, offset in
                guard let index = IridiumLibrarySelection.visibleIndex(offset: offset,
                    widths: games.indices.map { Double($0 == 0 ? featuredWidth : height / 1.5) },
                    spacing: 10, focusWidth: Double(height / 1.5),
                    previous: games.firstIndex(where: { $0.id == selection.highlightedID })) else { return }
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
                // Hiding controller hints and previewing another game's status
                // must not change the stride while touch still owns the carousel.
                if [.tracking, .interacting, .decelerating].contains(next), touchCoverHeight == nil {
                    touchCoverHeight = height
                }
                if next == .tracking || next == .interacting { showFocus = false; showHints = false }
                let target = selection.transition(to: next)
                selectedID = selection.selectedID
                // Keep this stride after release too. Restoring a larger cover
                // when controller hints disappear would snap an idle touch scroll.
                // A real viewport, text-size or search change can reflow it.
                if let target { carouselPosition.scrollTo(id: target, anchor: .leading) }
            }
            .onChange(of: dynamicTypeSize) { _, _ in touchCoverHeight = nil }
            .onChange(of: height) { _, _ in keepSelection() }
            .onChange(of: width) { _, _ in touchCoverHeight = nil; keepSelection() }
    }
    private func revealFocusedSection(in page: ScrollViewProxy) {
        let section = focus == "games" ? "games" : ["play", "jit", "options"].contains(focus) ? "details" : "header"
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            page.scrollTo(section, anchor: section == "header" ? .top : .bottom)
        }
    }
    private var controllerHints: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { selectionHints; navigationHints }
            VStack(alignment: .leading, spacing: 8) { selectionHints; navigationHints }
        }.font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.bottom, 4)
    }
    private var selectionHints: some View {
        HStack(spacing: 20) {
            HStack(spacing: 6) { faceHint(bottom: true); Text("Select") }
            HStack(spacing: 6) { faceHint(bottom: false); Text("Back") }
        }
    }
    private var navigationHints: some View {
        HStack(spacing: 20) {
            Label("Move", systemImage: "dpad")
            Text("LB / RB: Library")
        }
    }
    private func cover(_ entry: IridiumGame, height: CGFloat, width: CGFloat, featured: Bool) -> some View {
        IridiumLibraryReorderCard(id: entry.id, session: reorderSession, order: games.map(\.id), commit: { id, target, after in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                savedOrder = IridiumLibraryOrder.encoded(IridiumLibraryOrder.moving(id, relativeTo: target, after: after, in: allGames.map(\.id)))
                select(id)
            }
        }, feedbackEnabled: IridiumTouchHaptics.current() != .off,
           trace: { LogStore.shared.log("[Library Drag] phase=\($0)") }) {
            Button { select(entry.id); focus = "games" } label: {
                IridiumGameArtwork(game: entry, featured: featured)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }.buttonStyle(.plain).id(entry.id)
                .accessibilityIdentifier("game-cover-" + entry.id.uuidString)
                .accessibilityLabel(artwork.title(entry))
                .accessibilityHint("Select game. Use Play to launch.")
                .contextMenu {
                    Button("Game Options", systemImage: "slider.horizontal.3") { options(entry) }
                    Button("Edit Artwork", systemImage: "photo") { artworkDetail = entry }
                }
                .accessibilityAction(named: "Move to beginning") {
                    if let first = allGames.first {
                        savedOrder = IridiumLibraryOrder.encoded(IridiumLibraryOrder.moving(entry.id, relativeTo: first.id, after: false, in: allGames.map(\.id)))
                    }
                }
                .accessibilityAddTraits(selection.highlightedID == entry.id ? .isSelected : [])
        }.frame(width: width, height: height).id(entry.id)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: featured)
            .anchorPreference(key: IridiumLibraryCardBounds.self, value: .bounds) { [entry.id: $0] }
    }
    private var filters: some View {
        Picker("Library", selection: Binding(get: { favorites }, set: { favorites = $0; keepSelection() })) {
            Text("All Games").tag(false); Text("Favorites").tag(true)
        }.pickerStyle(.segmented).frame(minWidth: 164, maxWidth: 240).background(focusShape("filters"))
    }
    private var toolbar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                if searching {
                    TextField("Search games", text: $search, prompt: Text("Search games").foregroundStyle(.white.opacity(0.7)))
                        .accessibilityIdentifier("libraryInlineSearch")
                        .focused($searchFocus).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().submitLabel(.search).padding(.leading, 14)
                        .clipped().transition(.opacity)
                }
                tool(searching ? "Done searching" : "Search", icon: searching ? "xmark" : "magnifyingglass", id: "search") {
                    if searching { endSearch() } else { beginSearch() }
                }
            }.frame(maxWidth: searching ? .infinity : nil, alignment: .trailing)
                .clipped()
                .modifier(IridiumSearchSurface(active: searching)).tint(.white)
            tool("Add Game", icon: "plus", id: "add") { choosingAdd = true }
            tool("Settings", icon: "gearshape", id: "settings") { features = 1 }
        }.frame(maxWidth: .infinity, alignment: .trailing)
    }
    private func tool(_ label: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel(label).buttonStyle(.plain).background(focusShape(id))
    }
    private func title(_ entry: IridiumGame) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(artwork.title(entry)).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                .accessibilityIdentifier("libraryGameTitle").accessibilityAddTraits(.isHeader)
            Text(entry.platform.title + (readiness(entry).isEmpty ? "" : " · " + readiness(entry))).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .font(.caption).foregroundStyle(.white.opacity(0.75))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func readiness(_ game: IridiumGame) -> String {
        guard (try? IridiumRuntimeRegistry.resolve(platform: game.platform, preferred: game.console?.runtimeID)) != nil else { return "Unavailable" }
        if LibraryModel.sessionsThisRun > 0 || consoleSession.phase == .restartRequired { return "Reopen Iridium" }
        return ""
    }
    private func needsJITSetup(_ game: IridiumGame) -> Bool {
        !jitState.enabled && ((try? IridiumRuntimeRegistry.resolve(platform: game.platform, preferred: game.console?.runtimeID).jit) == .required ||
            (game.platform == .psp && game.console?.pspJITEnabled == true))
    }
    private func actions(_ entry: IridiumGame) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { gameActions(entry) }
            VStack(alignment: .leading, spacing: 10) { gameActions(entry) }
        }.fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func gameActions(_ entry: IridiumGame) -> some View {
        Button { launch(entry) } label: { Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 22).padding(.vertical, 12) }
            .buttonStyle(.plain).foregroundStyle(.black).background(.white, in: Capsule())
            .overlay { Capsule().strokeBorder(showFocus && focus == "play" ? .white : .clear, lineWidth: 3).padding(-5) }
            .disabled(library.launching || consoleSession.isActive || consoles.working).keyboardShortcut("p", modifiers: [])
        if needsJITSetup(entry) { IridiumJITSetupButton().background(focusShape("jit")) }
        Button { options(entry) } label: { Label("Options", systemImage: "ellipsis").frame(minHeight: 44) }
            .buttonStyle(.plain).accessibilityLabel("Game Options").background(focusShape("options"))
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
    private func beginSearch() {
        focus = "search"
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { searching = true }
        searchFocus = true
    }
    private func endSearch() {
        searchFocus = false; keyboardFocus = true
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { searching = false; search = "" }
    }
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
        let toolbar = ["search", "add", "settings"], actions = ["play"] + (selected.map { needsJITSetup($0) } == true ? ["jit"] : []) + ["options"]
        switch value {
        case "tab": favorites.toggle(); keepSelection()
        case "up", "down":
            focus = IridiumLibrarySelection.verticalFocus(focus == "jit" ? "play" : focus, down: value == "down", wide: wideLayout)
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
            case "search": beginSearch()
            case "add": choosingAdd = true
            case "settings": features = 1
            case "games": focus = "play"
            case "jit": jit.showSetup = true
            case "options": if let selected { options(selected) }
            default: if let selected { launch(selected) }
            }
        case "back": if searching { endSearch() } else { focus = "games" }
        default: break
        }
    }
}

private struct IridiumSearchSurface: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @ViewBuilder func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: 16)
            Group {
                if opaque { shape.fill(Color(uiColor: .secondarySystemBackground)) }
                else if #available(iOS 26, *) { shape.fill(.clear).glassEffect(.regular, in: shape) }
                else { shape.fill(.regularMaterial) }
            }.opacity(active ? 1 : 0)
        }
    }
}

// Measure text and controls at their real Dynamic Type sizes. This excludes the
// carousel and flexible space, so resizing the covers cannot change the budget.
private struct IridiumLibraryChromeHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private struct IridiumLibraryMeasureHeight: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(key: IridiumLibraryChromeHeight.self, value: geometry.size.height)
            }
        }
    }
}

// Kept independent of SwiftUI layout callbacks for executable geometry checks.

private struct IridiumLibraryCardBounds: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct IridiumLibrarySnapBehavior: ScrollTargetBehavior {
    let widths: [Double]
    let focusWidth: Double
    let leadingInset: Double
    let enabled: Bool
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard enabled, let x = IridiumLibrarySelection.restingOffset(Double(target.rect.minX) + leadingInset,
            widths: widths, spacing: 10, focusWidth: focusWidth) else { return }
        target.rect.origin.x = x
        target.anchor = .leading
    }
}

struct IridiumLibraryLayoutMetrics {
    let coverHeight: CGFloat
    let freeSpace: CGFloat

    init(viewportHeight: CGFloat, viewportWidth: CGFloat = 844, compact: Bool, chromeHeight: CGFloat,
         hasSelection: Bool, showsHints: Bool, frozenCoverHeight: CGFloat? = nil) {
        let spacing: CGFloat = compact ? 8 : 12
        let gaps = (hasSelection ? 3 : 1) + (showsHints ? 1 : 0)
        let available = max(0, viewportHeight - chromeHeight - 24 - CGFloat(gaps) * spacing)
        if hasSelection {
            let minimum: CGFloat = 72
            let preferred: CGFloat = compact ? min(220, max(96, viewportHeight * 0.28)) :
                min(180, max(96, (viewportWidth - 40) * 0.44))
            coverHeight = frozenCoverHeight ?? min(preferred, max(minimum, available))
        } else {
            coverHeight = 0
        }
        // When even the minimum cover cannot fit, the vertical ScrollView keeps
        // the full cover and every action reachable instead of clipping content.
        freeSpace = max(0, available - coverHeight)
    }
}
