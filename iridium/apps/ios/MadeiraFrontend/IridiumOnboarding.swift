// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

enum OnboardingRules {
    static let revisionKey = "iridium.setup.revision"
    static let revision = 1
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_ONBOARDING") }
    enum Step: String, CaseIterable { case welcome, library, controls, options, jit, signIn, dockClient, wineMono, done }
    static func steps(windows: Bool, steam: Bool, pspJIT: Bool, consoleJIT: Bool, signIn: Bool, dock: Bool, mono: Bool) -> [Step] {
        [.welcome, .library, .controls, .options] +
        (windows || pspJIT || steam || consoleJIT ? [.jit] : []) +
        (steam && signIn ? [.signIn] : []) + (steam && dock ? [.dockClient] : []) +
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
    private var considered = false
    private var offerMono = false
    static var enabled: Bool { OnboardingRules.enabled }
    var available: Bool { Self.enabled }
    var steps: [Step] {
        OnboardingRules.steps(windows: windows, steam: steam, pspJIT: pspJIT,
            consoleJIT: consoleJIT, signIn: SteamSignIn.isEnabled, dock: MadeiraDock.enabled, mono: offerMono)
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
        guard available, LibraryModel.shared.current == nil, !IridiumConsoleSession.shared.isActive, wine_process_is_running() == 0 else { return }
        offerMono = !WineMonoModel.available
        presentation = owner
        let saved = UserDefaults.standard.string(forKey: "iridium.setup.step").flatMap(Step.init(rawValue:)) ?? .welcome
        step = steps.contains(saved) ? saved : .options
        presented = true
    }
    func go(_ next: Step) {
        guard steps.contains(next) else { return }
        step = next; UserDefaults.standard.set(next.rawValue, forKey: "iridium.setup.step")
    }
    func back() { if let previous = OnboardingRules.previous(before: step, in: steps) { go(previous) } }
    func next() { if let next = OnboardingRules.next(after: step, in: steps) { go(next) } else { finish() } }
    func skip() { UserDefaults.standard.set(OnboardingRules.revision, forKey: OnboardingRules.revisionKey); presented = false }
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
    @State private var skip = false
    @State private var controls = false
    @State private var jitSetup = false
    @State private var steamSignIn = false
    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        if let index = model.steps.firstIndex(of: model.step) { Text("Step \(index + 1) of \(model.steps.count)").font(.caption).foregroundStyle(.secondary) }
                    }.listRowBackground(Color.clear)
                    page
                }.iridiumRowSurface()
            }.iridiumPageSurface().navigationTitle("Getting Started")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Skip") { skip = true } } }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Button("Back", systemImage: "chevron.backward") { model.back() }
                            .disabled(OnboardingRules.previous(before: model.step, in: model.steps) == nil)
                        Spacer()
                        Button(model.step == .done ? "Finish" : "Next", systemImage: "chevron.forward") { model.next() }
                            .buttonStyle(.borderedProminent).foregroundStyle(.black)
                    }.padding().background(.ultraThinMaterial)
                }
                .alert("Skip setup?", isPresented: $skip) {
                    Button("Skip Setup") { model.skip() }
                    Button("Keep Going", role: .cancel) { }
                } message: { Text("Resume in Settings → Getting Started.") }
                .sheet(isPresented: $controls) {
                    NavigationStack { IridiumControlsSettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { controls = false } } } }
                }
                .sheet(isPresented: $jitSetup, onDismiss: { JITCoordinator.shared.showSetup = false }) { JITSetupView() }
                .sheet(isPresented: $steamSignIn) { SteamSignInView() }
                .onAppear { signIn.refresh(); dock.refresh() }
                .onReceive(LibraryController.shared.commands) { command in
                    guard !controls, !jitSetup, !steamSignIn, !skip else { return }
                    if command == "back" { if model.step == .welcome { skip = true } else { model.back() } }
                    if command == "accept" || command == "right" { model.next() }
                    if command == "left" { model.back() }
                }
                .onKeyPress(.escape) { skip = true; return .handled }
        }.tint(IridiumTheme.accent).preferredColorScheme(.dark).interactiveDismissDisabled()
    }
    private var title: String {
        switch model.step {
        case .welcome: "Welcome to Iridium"
        case .library: "Build Your Library"
        case .controls: "Make It Yours"
        case .options: "Choose Optional Setup"
        case .jit: "Set Up JIT"
        case .signIn: "Connect Steam"
        case .dockClient: "Steam Game Components"
        case .wineMono: "Windows .NET Games"
        case .done: "Ready to Add Games"
        }
    }
    @ViewBuilder private var page: some View {
        switch model.step {
        case .welcome:
            Section { Text("Your Windows and console games, together.") }
            Section("Available Systems") {
                LabeledContent("Madeira", value: "Windows")
                ForEach(IridiumConsoleSystem.all) { system in LabeledContent(system.runtime.name, value: system.subtitle) }
            }
        case .library:
            Section {
                Label("Use Add Game (+) in the library.", systemImage: "plus")
                Text("Choose a game file or its complete folder. Iridium identifies the system and keeps disc tracks together.")
            }
            Section("Artwork & Saves") { Text("Change a title or cover in Game Options → Rename & Artwork."); Text("Use the game’s Save command before closing.") }
        case .controls:
            Section {
                Text("Use touch controls, a controller, or a keyboard and mouse.")
                Button("Customize Controls", systemImage: "hand.draw") { controls = true }
            } footer: { Text("Settings → Controls has system defaults, reusable profiles and game overrides.") }
        case .options:
            Section("What Will You Use?") {
                Toggle("Windows games", isOn: $model.windows)
                if IridiumRuntimeRegistry.all.contains(where: { $0.platforms.contains(.playStation2) || $0.platforms.contains(.dreamcast) }) { Toggle("PlayStation 2, Dreamcast & Arcade", isOn: $model.consoleJIT) }
                if SteamSignIn.isEnabled || MadeiraDock.enabled { Toggle("Steam library", isOn: $model.steam) }
                if IridiumRuntimeRegistry.all.contains(where: { $0.id == "ppsspp" }) { Toggle("Faster PSP games with JIT", isOn: $model.pspJIT) }
            }
            Section { Text("Console game files need no account. Required setup is also available when you choose Play.") }
        case .jit:
            Section {
                LabeledContent("JIT", value: jit.enabled ? "Enabled for this session" : "Not enabled")
                Button("Set Up JIT", systemImage: "bolt") { jitSetup = true }
            } footer: { Text("Windows, PlayStation 2, Dreamcast and arcade games require JIT. PSP can use it for speed.") }
        case .signIn:
            Section {
                if let name = signIn.accountName { LabeledContent("Steam account", value: name) }
                Button(signIn.accountName == nil ? "Sign In to Steam" : "Manage Steam Account") { steamSignIn = true }
            }
        case .dockClient:
            Section {
                if dock.clientInstalled { Label("Components installed", systemImage: "checkmark.circle") }
                else if dock.preparing { ProgressView(dock.progress) }
                else { Button("Download Steam Components", systemImage: "arrow.down.circle") { dock.prepareClient() } }
                if let error = dock.error { Text(error).foregroundStyle(.red) }
            } footer: { Text("Required to start Steam games through Madeira Dock.") }
        case .wineMono:
            Section {
                if mono.installed { Label("Wine Mono installed", systemImage: "checkmark.circle") }
                else {
                    switch mono.phase {
                    case .idle: Button("Install Wine Mono", systemImage: "arrow.down.circle") { mono.install() }
                    case .downloading(let progress), .installing(let progress): ProgressView(value: progress); Text(mono.status).font(.caption)
                    }
                }
                if let error = mono.error { Text(error).foregroundStyle(.red) }
            } footer: { Text("Only needed by Windows games that use .NET Framework.") }
        case .done:
            Section { Label("Add Game (+) to choose your files.", systemImage: "plus"); Text("Return to Settings → Getting Started whenever you need setup.") }
        }
    }
}
