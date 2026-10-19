// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

enum OnboardingRules {
    static let revisionKey = "iridium.setup.revision"
    static let revision = 2
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_ONBOARDING") }
    enum Step: String, CaseIterable { case welcome, library, controls, options, jit, signIn, dockClient, wineMono, done }
    static func steps(windows: Bool, steam: Bool, pspJIT: Bool, consoleJIT: Bool, signIn: Bool, dock: Bool, mono: Bool) -> [Step] {
        [.welcome, .library] +
        (steam && signIn ? [.signIn] : []) + (steam && dock ? [.dockClient] : []) +
        [.controls, .options] + (windows || pspJIT || steam || consoleJIT ? [.jit] : []) +
        (windows && mono ? [.wineMono] : []) + [.done]
    }
    static func previous(before step: Step, in steps: [Step]) -> Step? {
        guard let index = steps.firstIndex(of: step), index > 0 else { return nil }
        return steps[index - 1]
    }
    static func next(after step: Step, in steps: [Step]) -> Step? {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }
}

@MainActor final class OnboardingModel: ObservableObject {
    static let shared = OnboardingModel()
    enum Presentation { case library, settings }
    typealias Step = OnboardingRules.Step
    @Published var presented = false
    @Published private(set) var presentation = Presentation.library
    @Published private(set) var step = Step.welcome
    @Published var windows = UserDefaults.standard.bool(forKey: "iridium.setup.windows") { didSet { UserDefaults.standard.set(windows, forKey: "iridium.setup.windows") } }
    @Published var steam = UserDefaults.standard.bool(forKey: "iridium.setup.steam") { didSet { UserDefaults.standard.set(steam, forKey: "iridium.setup.steam") } }
    @Published var pspJIT = UserDefaults.standard.bool(forKey: "iridium.setup.pspJIT") { didSet { UserDefaults.standard.set(pspJIT, forKey: "iridium.setup.pspJIT") } }
    @Published var consoleJIT = UserDefaults.standard.bool(forKey: "iridium.setup.consoleJIT") { didSet { UserDefaults.standard.set(consoleJIT, forKey: "iridium.setup.consoleJIT") } }
    enum LibraryAction: Equatable { case files, steam, game(String) }
    @Published private(set) var libraryAction: LibraryAction?
    @Published private(set) var dismissalGeneration = 0
    @Published private(set) var firstGameID = UserDefaults.standard.string(forKey: "iridium.setup.gameID") ?? ""
    @Published private(set) var firstGameTitle = UserDefaults.standard.string(forKey: "iridium.setup.gameTitle") ?? ""
    @Published private(set) var firstGamePlatform = UserDefaults.standard.string(forKey: "iridium.setup.gamePlatform") ?? ""
    @Published private(set) var optionalJIT = UserDefaults.standard.bool(forKey: "iridium.setup.optionalJIT")
    @Published var needsMono = UserDefaults.standard.bool(forKey: "iridium.setup.needsMono") {
        didSet { UserDefaults.standard.set(needsMono, forKey: "iridium.setup.needsMono") }
    }
    var requiresJIT: Bool { windows || steam || consoleJIT }
    func chooseSteam() {
        clearGame(); steam = true; windows = false; consoleJIT = false; pspJIT = false; needsMono = false
        next()
    }
    func chooseFiles() {
        steam = false
        if firstGameID.isEmpty { windows = false; consoleJIT = false; pspJIT = false; needsMono = false }
    }
    func recordGame(id: String, title: String, platform: String, requiredJIT: Bool, optionalJIT: Bool) {
        firstGameID = id; firstGameTitle = title; firstGamePlatform = platform; self.optionalJIT = optionalJIT
        for (key, value) in [("gameID", id), ("gameTitle", title), ("gamePlatform", platform)] {
            UserDefaults.standard.set(value, forKey: "iridium.setup." + key)
        }
        UserDefaults.standard.set(optionalJIT, forKey: "iridium.setup.optionalJIT")
        steam = false; windows = platform == "windows"; consoleJIT = requiredJIT && !windows; pspJIT = false
        needsMono = false
    }
    private func clearGame() {
        firstGameID = ""; firstGameTitle = ""; firstGamePlatform = ""; optionalJIT = false
        for key in ["gameID", "gameTitle", "gamePlatform", "optionalJIT"] { UserDefaults.standard.removeObject(forKey: "iridium.setup." + key) }
    }
    func setPSPMode(_ value: Bool) {
        pspJIT = value
        if !steps.contains(step) { go(.options) }
    }
    func finishOpeningLibrary(gameAvailable: Bool = true) {
        libraryAction = firstGameID.isEmpty || !gameAvailable ? (steam ? .steam : .files) : .game(firstGameID)
        finish()
    }
    func presentationDidDismiss() { dismissalGeneration += 1 }
    func takeLibraryAction() -> LibraryAction? { defer { libraryAction = nil }; return libraryAction }
    private var considered = false
    private var offerMono = false
    static var enabled: Bool { OnboardingRules.enabled }
    var available: Bool { Self.enabled }
    var steps: [Step] {
        OnboardingRules.steps(windows: windows, steam: steam, pspJIT: pspJIT,
            consoleJIT: consoleJIT, signIn: SteamSignIn.isEnabled, dock: MadeiraDock.enabled, mono: needsMono && offerMono)
    }
    func binding(for owner: Presentation) -> Binding<Bool> {
        Binding(get: { self.presented && self.presentation == owner }, set: { if !$0, self.presentation == owner { self.presented = false } })
    }
    func presentIfNeeded(owner: Presentation = .library) {
        guard !considered else { return }; considered = true
        guard UserDefaults.standard.integer(forKey: OnboardingRules.revisionKey) < OnboardingRules.revision else { return }
        open(owner: owner)
    }
    func rerun() { open(owner: .settings) }
    private func open(owner: Presentation) {
        guard available, LibraryModel.shared.current == nil, !LibraryModel.shared.launching,
              !IridiumConsoleSession.shared.isActive, wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }
        offerMono = !WineMonoModel.available
        libraryAction = nil
        presentation = owner
        let saved = UserDefaults.standard.string(forKey: "iridium.setup.step").flatMap(Step.init(rawValue:)) ?? .welcome
        if saved == .wineMono && windows { needsMono = true; offerMono = true } // Preserve a skipped build 43 .NET step.
        step = steps.contains(saved) ? saved : .options
        presented = true
    }
    func go(_ next: Step) {
        guard steps.contains(next) else { return }
        step = next; UserDefaults.standard.set(next.rawValue, forKey: "iridium.setup.step")
    }
    func back() { if let previous = OnboardingRules.previous(before: step, in: steps) { go(previous) } }
    func next() { if let next = OnboardingRules.next(after: step, in: steps) { go(next) } else { finishOpeningLibrary() } }
    func skip() { libraryAction = nil; UserDefaults.standard.set(OnboardingRules.revision, forKey: OnboardingRules.revisionKey); presented = false }
    func finish() {
        UserDefaults.standard.set(OnboardingRules.revision, forKey: OnboardingRules.revisionKey)
        UserDefaults.standard.removeObject(forKey: "iridium.setup.step"); step = .welcome; presented = false
    }
}

struct OnboardingView: View {
    @ObservedObject private var model = OnboardingModel.shared
    @ObservedObject private var signIn = SteamSignInModel.shared
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var mono = WineMonoModel.shared
    @ObservedObject private var jit = LibraryJITState.shared
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var consoles = IridiumConsoleLibrary.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var heightClass
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("iridium.selectedGame") private var selectedGame = ""
    @State private var skip = false
    @State private var controls = false
    @State private var jitSetup = false
    @State private var steamSignIn = false
    @State private var importing = false
    @State private var source: IridiumImportSource?
    @State private var failure: String?
    private var game: IridiumGame? { findGame(model.firstGameID) }
    private var backgroundGame: IridiumGame? { game ?? findGame(selectedGame) }
    private var hosted: Bool { getenv("LC_HOME_PATH") != nil }
    private func findGame(_ id: String) -> IridiumGame? {
        if let entry = library.entries.first(where: { $0.id.uuidString == id }) { return IridiumGame(windows: entry) }
        return consoles.games.first(where: { $0.id.uuidString == id }).map(IridiumGame.init(console:))
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let wide = geometry.size.width > 650 && geometry.size.width > geometry.size.height && !typeSize.isAccessibilitySize
                ZStack {
                    Color.black.ignoresSafeArea()
                    if !opaque {
                        IridiumLibraryBackdrop(game: backgroundGame, portrait: !wide).ignoresSafeArea()
                        LinearGradient(colors: [.black.opacity(0.82), .black.opacity(0.72), .black.opacity(0.94)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                    }
                    ScrollView {
                        Group {
                            if wide {
                                HStack(alignment: .top, spacing: 32) {
                                    story.frame(maxWidth: geometry.size.width * 0.40, alignment: .leading)
                                    page.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 28) { story; page }
                            }
                        }.frame(maxWidth: 980, alignment: .leading)
                            .padding(.horizontal, wide ? 32 : 24).padding(.top, 16).padding(.bottom, 28)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }.id(model.step).scrollBounceBehavior(.basedOnSize)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) { chromeHeader }
            .safeAreaInset(edge: .bottom) { footer }
            .alert("Skip for now?", isPresented: $skip) {
                Button("Skip Setup") { model.skip() }
                Button("Keep Going", role: .cancel) { }
            } message: { Text("Resume at “\(title)” in Settings → Getting Started.") }
            .alert("Could Not Complete Setup", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
            .fileImporter(isPresented: $importing, allowedContentTypes: IridiumImportSource.contentTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): if !urls.isEmpty { source = .init(urls: urls) }
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription }
                }
            }
            .sheet(item: $source) { value in
                IridiumGameImportView(source: value, importedConsole: { entry in
                    guard source?.id == value.id else { return }
                    let runtime = try? IridiumRuntimeRegistry.resolve(platform: entry.platform, preferred: entry.runtimeID)
                    model.recordGame(id: entry.id.uuidString, title: entry.title, platform: entry.platform.rawValue,
                        requiredJIT: runtime?.jit == .required, optionalJIT: runtime?.jit == .optional)
                    model.pspJIT = entry.pspJITEnabled
                    source = nil; model.go(.controls)
                }) { entry in
                    guard source?.id == value.id else { return }
                    model.recordGame(id: entry.id.uuidString, title: entry.title, platform: "windows", requiredJIT: true, optionalJIT: false)
                    source = nil; model.go(.controls)
                }
            }
            .sheet(isPresented: $controls) {
                if let game {
                    IridiumTouchLayoutEditor(target: .init(platform: game.platform, title: IridiumArtworkModel.shared.title(game), gameID: game.id,
                        windowsLayout: game.windows.flatMap { entry in entry.controls.map {
                            IridiumControlLayoutState(controls: $0, visible: entry.touchControls,
                                size: entry.controlSize ?? 1, opacity: entry.controlOpacity ?? 0.7)
                        } }))
                } else {
                    NavigationStack { IridiumControlsSettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { controls = false } } } }
                }
            }
            .sheet(isPresented: $jitSetup, onDismiss: { JITCoordinator.shared.showSetup = false }) { JITSetupView() }
            .sheet(isPresented: $steamSignIn) { SteamSignInView() }
            .onAppear {
                signIn.refresh(); dock.refresh()
                if let entry = game?.console, entry.platform == .psp { model.setPSPMode(entry.pspJITEnabled) }
            }
            .onChange(of: consoles.error) { _, message in
                guard let message, model.optionalJIT else { return }
                model.setPSPMode(game?.console?.pspJITEnabled ?? false); failure = message
            }
            .onReceive(LibraryController.shared.commands) { command in
                guard !controls, !jitSetup, !steamSignIn, !skip, !importing, source == nil, failure == nil else { return }
                if command == "back" { if model.step == .welcome { skip = true } else { model.back() } }
                if command == "accept" || command == "right" { advance() }
                if command == "left" { model.back() }
            }
            .onKeyPress(.escape) {
                guard !controls, !jitSetup, !steamSignIn, !skip, !importing, source == nil, failure == nil else { return .ignored }
                skip = true; return .handled
            }
        }.tint(IridiumTheme.accent).preferredColorScheme(.dark).interactiveDismissDisabled()
    }
    private var wordmark: some View {
        Text("IRIDIUM").font(.caption.weight(.bold)).tracking(3).foregroundStyle(IridiumTheme.accent)
            .fixedSize(horizontal: true, vertical: false).accessibilityLabel("Iridium")
    }
    private var skipButton: some View {
        Button("Skip") { skip = true }.font(.headline).lineLimit(1).fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 18).frame(minHeight: 44)
            .modifier(IridiumGlassSurface(radius: 24)).buttonStyle(.plain)
    }
    private var chromeHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { wordmark; Spacer(minLength: 0); skipButton }
            VStack(alignment: .leading, spacing: 8) { wordmark; HStack { Spacer(); skipButton } }
        }.padding(.horizontal, typeSize.isAccessibilitySize ? 12 : 24)
            .padding(.vertical, heightClass == .compact ? 4 : 8)
            .background(opaque || typeSize.isAccessibilitySize ? AnyShapeStyle(Color.black) : AnyShapeStyle(.ultraThinMaterial))
    }
    private var title: String {
        switch model.step {
        case .welcome: "Your games.\nOne library."
        case .library: "Start with a game."
        case .controls: "Play your way."
        case .options: "Know what it needs."
        case .jit: model.requiresJIT ? "This game needs JIT." : "More speed for PSP."
        case .signIn: "Bring your Steam library."
        case .dockClient: "Prepare Steam games."
        case .wineMono: "Add .NET support."
        case .done: game == nil ? "Your library starts here." : "Your game is in."
        }
    }
    private var subtitle: String {
        switch model.step {
        case .welcome: "Windows games, handhelds and consoles — together on your iPhone or iPad."
        case .library: "Choose files you own, or connect Steam. Iridium helps identify the system."
        case .controls: "Start with touch controls or a controller. Change the layout whenever you want."
        case .options: game.map { "Setup for \($0.title), using \($0.platform.title)." } ?? "Setup follows the game you choose. You can add files before configuring anything."
        case .jit: hosted ? "You’re running inside LiveContainer. Enable JIT for Iridium in the host before playing." : "JIT lets this system compile game code as it runs. Re-enable it after closing Iridium."
        case .signIn: "Connect your account, then choose which games to download."
        case .dockClient: "Steam games use these components to start through Madeira Dock."
        case .wineMono: "Wine Mono is for Windows games that ask for .NET Framework."
        case .done: game == nil ? "Open your chosen source and add a game. Required setup is also shown when you press Play." : "Open the library to find your game. Use Play when you’re ready."
        }
    }
    private var story: some View {
        VStack(alignment: .leading, spacing: heightClass == .compact ? 12 : 18) {
            if let index = model.steps.firstIndex(of: model.step) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(typeSize.isAccessibilitySize ? "Step \(index + 1) of \(model.steps.count)" : "GETTING STARTED · \(index + 1) / \(model.steps.count)").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(IridiumTheme.accent)
                    HStack(spacing: 5) {
                        ForEach(Array(model.steps.enumerated()), id: \.element) { position, _ in
                            Capsule().fill(position <= index ? IridiumTheme.accent : Color.white.opacity(0.20)).frame(height: 3)
                        }
                    }.accessibilityHidden(true)
                }.accessibilityIdentifier("onboardingProgress")
            }
            Text(title).font((heightClass == .compact ? Font.title : Font.largeTitle).weight(.bold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("onboardingTitle")
            Text(subtitle).font(heightClass == .compact ? .subheadline : .body).foregroundStyle(.white.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var footer: some View {
        Group {
            if typeSize.isAccessibilitySize { HStack(spacing: 12) {
                Button { model.back() } label: { Image(systemName: "chevron.backward").font(.title2.weight(.semibold)).frame(width: 48, height: 56) }
                    .accessibilityLabel("Back").accessibilityShowsLargeContentViewer { Label("Back", systemImage: "chevron.backward") }
                    .disabled(OnboardingRules.previous(before: model.step, in: model.steps) == nil)
                forward
            } }
            else if heightClass == .compact { HStack(spacing: 16) { back; Spacer(); forward.frame(maxWidth: 280) } }
            else { HStack(spacing: 16) { back; forward } }
        }.padding(.horizontal, 24).padding(.vertical, heightClass == .compact ? 8 : 12)
            .background(opaque || typeSize.isAccessibilitySize ? AnyShapeStyle(Color.black) : AnyShapeStyle(.ultraThinMaterial))
    }
    private var back: some View {
        Button { model.back() } label: { Label("Back", systemImage: "chevron.backward").font(.headline).padding(.horizontal, 8).frame(minHeight: 44) }
            .disabled(OnboardingRules.previous(before: model.step, in: model.steps) == nil)
    }
    private var forward: some View {
        Button { advance() } label: {
            HStack {
                Text(typeSize.isAccessibilitySize && model.step == .done ? (game != nil ? "Library" : model.steam ? "Steam" : "Add Game") : primaryTitle)
                if !typeSize.isAccessibilitySize { Image(systemName: "arrow.right") }
            }
                .font(.headline).multilineTextAlignment(.center).foregroundStyle(.black)
                .padding(.horizontal, 20).padding(.vertical, heightClass == .compact ? 12 : 15).frame(maxWidth: .infinity, minHeight: 48)
                .background(.white, in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel(primaryTitle).accessibilityIdentifier("onboardingNext")
            .accessibilityShowsLargeContentViewer { Text(primaryTitle) }
    }
    private func advance() {
        if model.step == .done { model.finishOpeningLibrary(gameAvailable: game != nil) }
        else { model.next() }
    }
    private var primaryTitle: String { model.step == .done ? (game != nil ? "Open Library" : model.steam ? "Open Steam Library" : "Add a Game") : "Next" }
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18, content: content).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(opaque || contrast == .increased ? 0.92 : 0.55), in: RoundedRectangle(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.14)) }
    }
    @ViewBuilder private func detail(_ title: String, _ text: String, symbol: String) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.80)).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.title3).foregroundStyle(IridiumTheme.accent).frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.80)).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
    private func action(_ title: String, _ text: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(alignment: .center, spacing: 12) {
                detail(title, text, symbol: symbol)
                if !typeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(IridiumTheme.accent).accessibilityHidden(true)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(IridiumGlassSurface(radius: 24))
        }.buttonStyle(.plain).foregroundStyle(.white)
    }
    private var pspMode: Binding<Bool> {
        Binding(get: { model.pspJIT }, set: { value in
            guard !consoles.working else { return }
            if var entry = game?.console, entry.platform == .psp {
                entry.pspJIT = value; consoles.update(entry)
            }
            model.setPSPMode(value)
        })
    }
    private func systems(using requirement: IridiumJITRequirement) -> String {
        IridiumRuntimeRegistry.all.filter { $0.jit == requirement }.map { runtime in
            runtime.platforms.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: " / ")
        }.joined(separator: " · ")
    }
    @ViewBuilder private var page: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.step {
            case .welcome:
                panel {
                    detail("Bring games you own", "Add supported game files, folders or your Steam library.", symbol: "square.stack.3d.up")
                    detail("A home for every system", "Covers, game options and controls stay together in one library.", symbol: "rectangle.stack")
                    DisclosureGroup("Systems you can add") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Madeira · Windows").font(.subheadline)
                            ForEach(IridiumConsoleSystem.all) { system in Text(system.title).font(.subheadline) }
                        }.padding(.top, 10).foregroundStyle(.white.opacity(0.85))
                    }.font(.headline)
                }
            case .library:
                if let game { panel { IridiumGameOptionsHeader(game: game); Label("Added to your library", systemImage: "checkmark.circle.fill").foregroundStyle(IridiumTheme.accent) } }
                action("Choose Files", "Open a game file or its folder. No account needed.", symbol: "folder") { model.chooseFiles(); importing = true }
                if SteamSignIn.isEnabled || MadeiraDock.enabled {
                    action("Use Steam", "Connect your account and choose downloads.", symbol: "network") { model.chooseSteam() }
                }
                panel {
                    detail("Automatic system detection", "If more than one system fits, Iridium asks you to choose.", symbol: "sparkle.magnifyingglass")
                    Text("Disc games: choose the complete folder to keep tracks together.").font(.subheadline).foregroundStyle(.white.opacity(0.80))
                }
            case .controls:
                panel {
                    detail("Touch layouts", "Move buttons, adjust size and opacity, and reuse saved profiles.", symbol: "hand.draw")
                    detail("Game controllers", "Connect a controller before playing. Windows games also offer keyboard and mouse mappings.", symbol: "gamecontroller")
                }
                action(game == nil ? "Explore Controls" : "Customize This Game", "Use system defaults or keep a layout just for one game.", symbol: "slider.horizontal.3") { controls = true }
            case .options:
                panel {
                    if model.requiresJIT {
                        detail("JIT is required", model.steam ? "Steam’s Windows games need JIT before they can start." : "Enable JIT before playing \(model.firstGameTitle.isEmpty ? "this system" : model.firstGameTitle).", symbol: "bolt.fill")
                        Text("Next: choose a JIT method.").font(.subheadline).foregroundStyle(IridiumTheme.accent)
                    } else if model.pspJIT {
                        detail("JIT for faster PSP games", "Enable JIT for this mode, or turn it off to use the default mode.", symbol: "bolt")
                    } else if !model.firstGameID.isEmpty {
                        detail("No JIT setup needed", "You can start with this system’s default execution mode.", symbol: "checkmark.circle")
                    } else {
                        detail("JIT required", systems(using: .required), symbol: "bolt")
                        detail("No JIT setup", systems(using: .none), symbol: "checkmark.circle")
                        if !systems(using: .optional).isEmpty {
                            Text("\(systems(using: .optional)) can use JIT for more speed, or run without it.").font(.subheadline).foregroundStyle(.white.opacity(0.80))
                        }
                    }
                    if model.optionalJIT || model.pspJIT { Toggle("Use JIT for faster PSP games", isOn: pspMode).disabled(consoles.working) }
                    if model.windows { Toggle("This game needs .NET Framework", isOn: $model.needsMono).font(.subheadline) }
                }
                if model.windows { Text("Choose .NET only if your game asks for it. Wine Mono is also available in Windows settings.").font(.footnote).foregroundStyle(.white.opacity(0.80)) }
            case .jit:
                panel {
                    detail(jit.enabled ? "Enabled for this session" : "JIT still needs to be enabled", hosted ? "Use the host’s JIT launch for Iridium. JIT options remain available below." : "Choose StikDebug, a LiveContainer route, or the built-in helper.", symbol: jit.enabled ? "checkmark.circle.fill" : "bolt")
                    if hosted { Text("LiveContainer session").font(.caption.weight(.semibold)).foregroundStyle(IridiumTheme.accent) }
                }
                action("Choose JIT Method", "Standalone StikDebug · LiveContainer · LC2 · LC3 · built-in helper", symbol: "bolt.circle") { jitSetup = true }
            case .signIn:
                panel {
                    if let name = signIn.accountName { detail("Connected as \(name)", "Your Steam library is available in Add Game → Steam.", symbol: "checkmark.circle") }
                    else { detail("Your account, your choice", "Files and console games work without a Steam account.", symbol: "person.crop.circle") }
                }
                action(signIn.accountName == nil ? "Sign In to Steam" : "Manage Steam Account", "Open Steam’s sign-in screen.", symbol: "person.crop.circle.badge.plus") { steamSignIn = true }
            case .dockClient:
                panel {
                    if dock.clientInstalled { detail("Components installed", "Steam games can use Madeira Dock.", symbol: "checkmark.circle") }
                    else if dock.preparing { ProgressView(dock.progress) }
                    else { Button("Download Steam Components", systemImage: "arrow.down.circle") { dock.prepareClient() }.font(.headline).frame(minHeight: 44) }
                    if let error = dock.error { Text(error).font(.subheadline).foregroundStyle(.red) }
                    Text("You can download these later from Steam in Settings.").font(.subheadline).foregroundStyle(.white.opacity(0.80))
                }
            case .wineMono:
                panel {
                    if mono.installed { Label("Wine Mono installed", systemImage: "checkmark.circle") }
                    else {
                        switch mono.phase {
                        case .idle: Button("Install Wine Mono", systemImage: "arrow.down.circle") { mono.install() }.font(.headline).frame(minHeight: 44)
                        case .downloading(let progress), .installing(let progress): ProgressView(value: progress); Text(mono.status).font(.subheadline)
                        }
                    }
                    if let error = mono.error { Text(error).foregroundStyle(.red) }
                }
            case .done:
                if let game { panel { IridiumGameOptionsHeader(game: game); detail("Keep your progress", "Use the game’s Save command before closing. Removing its library entry keeps files and saves.", symbol: "externaldrive") } }
                else { panel { detail(model.steam ? "Next: your Steam library" : "Next: choose your game files", "You choose what to add. Covers and names can be changed in Game Options.", symbol: model.steam ? "network" : "folder") } }
                if (model.requiresJIT || model.pspJIT) && !jit.enabled {
                    action("Set Up JIT", model.requiresJIT ? "Still required before this game can start." : "Your faster PSP mode uses JIT.", symbol: "bolt") { jitSetup = true }
                }
                Text("Come back through Settings → Getting Started. Your choices are kept.").font(.footnote).foregroundStyle(.white.opacity(0.80))
            }
        }
    }
}
