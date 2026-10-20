// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

enum OnboardingRules {
    static let revisionKey = "iridium.setup.revision"
    static let revision = 2
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_ONBOARDING") }
    enum Step: String, CaseIterable { case welcome, library, controls, options, jit, signIn, dockClient, wineMono, done }
    static func steps(windows: Bool, steam: Bool, pspJIT: Bool, consoleJIT: Bool, signIn: Bool, dock: Bool, mono: Bool) -> [Step] {
        [.library] +
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
    @Published private(set) var step = Step.library
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
        let saved = UserDefaults.standard.string(forKey: "iridium.setup.step").flatMap(Step.init(rawValue:)) ?? .library
        if saved == .wineMono && windows { needsMono = true; offerMono = true } // Preserve a skipped build 43 .NET step.
        // Build 45’s introductory page now resumes at the first functional step.
        step = saved == .welcome ? .library : steps.contains(saved) ? saved : .options
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
        UserDefaults.standard.removeObject(forKey: "iridium.setup.step"); step = .library; presented = false
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
    @State private var skip = false
    @State private var controls = false
    @State private var jitSetup = false
    @State private var steamSignIn = false
    @State private var importing = false
    @State private var source: IridiumImportSource?
    @State private var failure: String?
    private var game: IridiumGame? { findGame(model.firstGameID) }
    private var hosted: Bool { getenv("LC_HOME_PATH") != nil }
    private func findGame(_ id: String) -> IridiumGame? {
        if let entry = library.entries.first(where: { $0.id.uuidString == id }) { return IridiumGame(windows: entry) }
        return consoles.games.first(where: { $0.id.uuidString == id }).map(IridiumGame.init(console:))
    }
    var body: some View {
        NavigationStack {
            TabView(selection: Binding(get: { model.step }, set: { model.go($0) })) {
                ForEach(model.steps, id: \.self) { step in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            heading(for: step)
                            page(for: step)
                        }
                        .padding(.horizontal, 24).padding(.top, heightClass == .compact ? 12 : 28).padding(.bottom, 24)
                        .frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .tag(step).accessibilityHidden(model.step != step)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background { IridiumPageBackdrop() }
            .navigationTitle("Iridium Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Skip") { skip = true }.foregroundStyle(.primary) } }
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
                if command == "back" { if model.step == model.steps.first { skip = true } else { model.back() } }
                if command == "accept" || command == "right" { advance() }
                if command == "left" { model.back() }
            }
            .onKeyPress(.escape) {
                guard !controls, !jitSetup, !steamSignIn, !skip, !importing, source == nil, failure == nil else { return .ignored }
                skip = true; return .handled
            }
        }.tint(IridiumTheme.accent).preferredColorScheme(.dark).interactiveDismissDisabled()
    }
    private var title: String { title(for: model.step) }
    private func title(for step: OnboardingRules.Step) -> String {
        switch step {
        case .welcome, .library: "Add Games"
        case .controls: "Controls"
        case .options: "Game Setup"
        case .jit: "Enable JIT"
        case .signIn: "Steam Account"
        case .dockClient: "Steam Components"
        case .wineMono: ".NET Framework"
        case .done: "Finish Setup"
        }
    }
    private func subtitle(for step: OnboardingRules.Step) -> String {
        switch step {
        case .welcome, .library, .options, .done: ""
        case .controls: "Use touch controls or connect a controller."
        case .jit: hosted ? "Enable JIT for Iridium in LiveContainer." : "JIT enables this game to run on your device."
        case .signIn: "Sign in to choose downloads."
        case .dockClient: "Required to start Steam games."
        case .wineMono: "Wine Mono adds .NET support. Install only if your game asks for it."
        }
    }
    private func heading(for step: OnboardingRules.Step) -> some View {
        let subtitle = subtitle(for: step)
        return VStack(alignment: .leading, spacing: 12) {
            Text(title(for: step)).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("onboardingTitle")
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var footer: some View {
        VStack(spacing: 12) {
            if let index = model.steps.firstIndex(of: model.step) {
                Text("\(index + 1) of \(model.steps.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel("Step \(index + 1) of \(model.steps.count)").accessibilityIdentifier("onboardingProgress")
            }
            HStack(spacing: 12) {
                Button { model.back() } label: {
                    navigationLabel("Back")
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .overlay { Capsule().strokeBorder(.white.opacity(0.12)) }
                }.foregroundStyle(.white)
                    .disabled(OnboardingRules.previous(before: model.step, in: model.steps) == nil)
                    .opacity(OnboardingRules.previous(before: model.step, in: model.steps) == nil ? 0.35 : 1)
                    .accessibilityIdentifier("onboardingBack")
                    .accessibilityShowsLargeContentViewer { Text("Back") }
                Button { advance() } label: {
                    navigationLabel(typeSize.isAccessibilitySize && model.step == .done ? (game != nil ? "Library" : model.steam ? "Steam" : "Add Game") : primaryTitle)
                        .foregroundStyle(.black).background(.white, in: Capsule())
                }.accessibilityLabel(primaryTitle).accessibilityIdentifier("onboardingNext")
                    .accessibilityShowsLargeContentViewer { Text(primaryTitle) }
            }.buttonStyle(.plain).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24).padding(.vertical, heightClass == .compact ? 8 : 12)
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
        .background { Color.black.opacity(opaque || typeSize.isAccessibilitySize ? 1 : 0.74).ignoresSafeArea(edges: .bottom) }
    }
    private func navigationLabel(_ title: String) -> some View {
        Text(title).font(.headline).multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 48)
            .contentShape(Capsule())
    }
    private func advance() {
        if model.step == .done { model.finishOpeningLibrary(gameAvailable: game != nil) }
        else { model.next() }
    }
    private var primaryTitle: String { model.step == .done ? (game != nil ? "Open Library" : model.steam ? "Open Steam Library" : "Add a Game") : "Next" }
    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if !text.isEmpty { Text(text).font(.subheadline).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func action(_ title: String, _ text: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 14) {
                if !typeSize.isAccessibilitySize { Image(systemName: symbol).font(.title3).frame(width: 24).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    if !text.isEmpty { Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true) }
            }.padding(16).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .modifier(IridiumGlassSurface(radius: 20))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.primary)
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
    @ViewBuilder private func page(for step: OnboardingRules.Step) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            switch step {
            case .welcome, .library:
                if let game {
                    IridiumGameOptionsHeader(game: game)
                    Label("Added to Library", systemImage: "checkmark").font(.subheadline).foregroundStyle(IridiumTheme.accent)
                }
                VStack(spacing: 10) {
                    action("Choose Files", "Game files or folders", symbol: "folder") { model.chooseFiles(); importing = true }
                    if SteamSignIn.isEnabled || MadeiraDock.enabled {
                        action("Use Steam", "Steam library", symbol: "network") { model.chooseSteam() }
                    }
                }
                Text("Disc games: choose the complete folder.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Supported Systems") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Madeira · Windows")
                        ForEach(IridiumConsoleSystem.all) { system in Text(system.title) }
                    }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 12)
                }.font(.subheadline)
            case .controls:
                if let game { IridiumGameOptionsHeader(game: game) }
                action("Edit Touch Controls", "Size, position and saved layouts", symbol: "slider.horizontal.3") { controls = true }
            case .options:
                if let game { IridiumGameOptionsHeader(game: game) }
                if model.requiresJIT {
                    note("JIT Required", "Choose a JIT method next.")
                } else if model.pspJIT {
                    note("PSP JIT", "Enable JIT to use this mode.")
                } else if !model.firstGameID.isEmpty {
                    note("No JIT Required", "Leave JIT off.")
                } else {
                    Text("Play shows any setup still needed.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("Which systems need JIT?") {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("JIT enables games to run on this device.").font(.subheadline).foregroundStyle(.secondary)
                            note("JIT Required", systems(using: .required))
                            note("No JIT Required", systems(using: .none))
                            if !systems(using: .optional).isEmpty { note("Optional JIT", systems(using: .optional)) }
                        }.padding(.top, 12)
                    }.font(.subheadline)
                }
                if model.optionalJIT || model.pspJIT {
                    Toggle("Use JIT for PSP", isOn: pspMode).disabled(consoles.working)
                }
                if model.windows {
                    Toggle("Requires .NET Framework", isOn: $model.needsMono)
                    Text("Only if the game asks for .NET.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .jit:
                note(jit.enabled ? "Enabled for This Session" : "Not Enabled", hosted ? "" : "Enable again after closing Iridium.")
                action("Choose JIT Method", "Setup instructions", symbol: "bolt") { jitSetup = true }
            case .signIn:
                if let name = signIn.accountName { note("Signed In", name) }
                action(signIn.accountName == nil ? "Sign In to Steam" : "Manage Steam Account", "", symbol: "person.crop.circle") { steamSignIn = true }
            case .dockClient:
                if dock.clientInstalled { Label("Components Installed", systemImage: "checkmark").foregroundStyle(IridiumTheme.accent) }
                else if dock.preparing { ProgressView(dock.progress) }
                else { action("Download Steam Components", "", symbol: "arrow.down.circle") { dock.prepareClient() } }
                if let error = dock.error { Text(error).font(.subheadline).foregroundStyle(.red) }
                Text("Also in Settings → Steam.").font(.footnote).foregroundStyle(.secondary)
            case .wineMono:
                if mono.installed { Label("Wine Mono Installed", systemImage: "checkmark").foregroundStyle(IridiumTheme.accent) }
                else {
                    switch mono.phase {
                    case .idle: action("Install Wine Mono", "", symbol: "arrow.down.circle") { mono.install() }
                    case .downloading(let progress), .installing(let progress): ProgressView(value: progress); Text(mono.status).font(.subheadline)
                    }
                }
                if let error = mono.error { Text(error).foregroundStyle(.red) }
                Text("Also available in Settings.").font(.footnote).foregroundStyle(.secondary)
            case .done:
                if let game { IridiumGameOptionsHeader(game: game) }
                if (model.requiresJIT || model.pspJIT) && !jit.enabled {
                    action("Set Up JIT", model.requiresJIT ? "Required before this game can start" : "Required for your selected PSP mode", symbol: "bolt") { jitSetup = true }
                }
                Text("Game Options: covers, names and settings.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Revisit in Settings → Getting Started.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
