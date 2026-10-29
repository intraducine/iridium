// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import Security

@MainActor enum OnboardingCompletion {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "software.iridium.setup",
         kSecAttrAccount as String: "completed"]
    }
    static func load() -> Bool? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { NSLog("[setup] Completion read failed: %d", status); return nil }
        return item as? Data == Data([1])
    }
    static func save() {
        let attributes: [String: Any] = [kSecValueData as String: Data([1]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
        }
        if status != errSecSuccess { NSLog("[setup] Completion save failed: %d", status) }
    }
}

enum OnboardingRules {
    static let revisionKey = "iridium.setup.revision"
    static let revision = 2
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_ONBOARDING") }
    enum Step: String, CaseIterable { case library, downloads, jit }
    static let steps: [Step] = [.library, .downloads, .jit]
    static func restoredStep(_ saved: String?) -> Step {
        switch saved {
        case "downloads", "wineMono", "dockClient", "steamComponents": .downloads
        case "controls", "options", "jit", "done": .jit
        default: .library // Includes the old welcome and sign-in pages.
        }
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
    enum LibraryAction: Equatable { case library }
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
        steam = true
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
    func setPSPMode(_ value: Bool) {
        pspJIT = value
    }
    func finishOpeningLibrary() {
        libraryAction = .library
        finish()
    }
    func presentationDidDismiss() { dismissalGeneration += 1 }
    func takeLibraryAction() -> LibraryAction? { defer { libraryAction = nil }; return libraryAction }
    private var considered = false
    static var enabled: Bool { OnboardingRules.enabled }
    var available: Bool { Self.enabled }
    var steps: [Step] { OnboardingRules.steps }
    func binding(for owner: Presentation) -> Binding<Bool> {
        Binding(get: { self.presented && self.presentation == owner }, set: { if !$0, self.presentation == owner { self.presented = false } })
    }
    func presentIfNeeded(owner: Presentation = .library) {
        guard !considered else { return }
        if UserDefaults.standard.integer(forKey: OnboardingRules.revisionKey) > 0 {
            markCompleted(); considered = true; return
        }
        // A replacement install can lose preferences while keeping its Keychain.
        guard let completed = OnboardingCompletion.load() else { return }
        considered = true
        if completed { UserDefaults.standard.set(OnboardingRules.revision, forKey: OnboardingRules.revisionKey); return }
        open(owner: owner)
    }
    func rerun() { open(owner: .settings) }
    private func open(owner: Presentation) {
        guard available, LibraryModel.shared.current == nil, !LibraryModel.shared.launching,
              !IridiumConsoleSession.shared.isActive, wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }
        libraryAction = nil
        presentation = owner
        let saved = UserDefaults.standard.string(forKey: "iridium.setup.step")
        if saved == "wineMono" && windows { needsMono = true } // Preserve a skipped build 43 .NET choice.
        step = OnboardingRules.restoredStep(saved)
        presented = true
    }
    func go(_ next: Step) {
        guard steps.contains(next) else { return }
        step = next; UserDefaults.standard.set(next.rawValue, forKey: "iridium.setup.step")
    }
    func back() { if let previous = OnboardingRules.previous(before: step, in: steps) { go(previous) } }
    func next() { if let next = OnboardingRules.next(after: step, in: steps) { go(next) } else { finishOpeningLibrary() } }
    private func markCompleted() {
        UserDefaults.standard.set(OnboardingRules.revision, forKey: OnboardingRules.revisionKey)
        OnboardingCompletion.save()
    }
    func skip() { libraryAction = nil; markCompleted(); presented = false }
    func finish() {
        markCompleted()
        UserDefaults.standard.removeObject(forKey: "iridium.setup.step"); step = .library; presented = false
    }
}

struct OnboardingView: View {
    @ObservedObject private var model = OnboardingModel.shared
    @ObservedObject private var signIn = SteamSignInModel.shared
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var mono = WineMonoModel.shared
    @ObservedObject private var jit = LibraryJITState.shared
    @ObservedObject private var jitCoordinator = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var consoles = IridiumConsoleLibrary.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var heightClass
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controllerFocus = SetupControllerFocus()
    @State private var skip = false
    @State private var showingJITImporter = false
    @State private var steamSignIn = false
    @State private var importing = false
    @State private var source: IridiumImportSource?
    @State private var failure: String?
    @State private var systemsExpanded = false
    @State private var jitSystemsExpanded = false
    private var game: IridiumGame? { findGame(model.firstGameID) }
    private var scrollsFooter: Bool { typeSize.isAccessibilitySize }
    private var stacksFooter: Bool { typeSize.isAccessibilitySize && heightClass != .compact && widthClass != .regular }
    private var footerLayout: AnyLayout {
        stacksFooter ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
    }
    private func findGame(_ id: String) -> IridiumGame? {
        if let entry = library.entries.first(where: { $0.id.uuidString == id }) { return IridiumGame(windows: entry) }
        return consoles.games.first(where: { $0.id.uuidString == id }).map(IridiumGame.init(console:))
    }
    var body: some View {
        NavigationStack {
            ZStack {
                IridiumPageBackdrop()
                TabView(selection: Binding(get: { model.step }, set: { model.go($0) })) {
                    ForEach(model.steps, id: \.self) { step in
                        ScrollView {
                            VStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: 28) {
                                    heading(for: step)
                                    page(for: step)
                                }
                                .padding(.horizontal, 24).padding(.top, heightClass == .compact ? 12 : 28).padding(.bottom, 24)
                                .frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
                                // Accessibility text keeps the reading viewport; navigation scrolls with the page.
                                if scrollsFooter { footer }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .environment(\.setupControllerPage, step.rawValue)
                        .tag(step).accessibilityHidden(model.step != step)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .safeAreaInset(edge: .bottom, spacing: 0) { if !scrollsFooter { footer } }
            }
            .modifier(SetupControllerReviewPad(focus: controllerFocus, suspended: controllerSuspended))
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { skip = true }.foregroundStyle(.primary)
                        .setupControllerTarget("setup.skip", order: 10000, role: .skip, action: { skip = true })
                }
            }
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
                    source = nil
                }) { entry in
                    guard source?.id == value.id else { return }
                    model.recordGame(id: entry.id.uuidString, title: entry.title, platform: "windows", requiredJIT: true, optionalJIT: false)
                    source = nil
                }.environment(\.setupControllerFocus, nil)
            }
            .sheet(isPresented: $steamSignIn) { SteamSignInView().environment(\.setupControllerFocus, nil) }
            .onAppear {
                signIn.refresh(); dock.refresh(); mono.refresh()
                if let entry = game?.console, entry.platform == .psp { model.setPSPMode(entry.pspJITEnabled) }
            }
            .onChange(of: consoles.error) { _, message in
                guard let message, model.optionalJIT else { return }
                model.setPSPMode(game?.console?.pspJITEnabled ?? false); failure = message
            }
            .onReceive(LibraryController.shared.commands) { command in
                controllerFocus.receive(command, page: model.step.rawValue, suspended: controllerSuspended, back: controllerBack)
            }
            .onKeyPress(.escape) {
                guard !controllerSuspended else { return .ignored }
                controllerBack(); return .handled
            }
        }
        .environment(\.setupControllerFocus, controllerFocus)
        .environment(\.setupControllerPage, model.step.rawValue)
        .onPreferenceChange(SetupControllerTargetsKey.self) { controllerFocus.update($0, page: model.step.rawValue) }
        .onChange(of: model.presented) { _, presented in if !presented { controllerFocus.clear() } }
        .modifier(ClaimGamepadEvents())
        .tint(IridiumTheme.accent).preferredColorScheme(.dark).interactiveDismissDisabled()
    }
    private var controllerSuspended: Bool {
        !model.presented || showingJITImporter || steamSignIn || skip || importing || source != nil || failure != nil || controllerFocus.sharing || scenePhase != .active
    }
    private func controllerBack() {
        if pairing.active { pairing.cancel() }
        else if model.step == .library { skip = true }
        else { model.back() }
    }
    private var title: String { title(for: model.step) }
    private func title(for step: OnboardingRules.Step) -> String {
        switch step {
        case .library: "Add Games"
        case .downloads: "Downloads"
        case .jit: "JIT Setup"
        }
    }
    private func heading(for step: OnboardingRules.Step) -> some View {
        Text(title(for: step)).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("onboardingTitle")
    }
    private var footer: some View {
        VStack(spacing: 12) {
            if let index = model.steps.firstIndex(of: model.step) {
                Text("\(index + 1) of \(model.steps.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel("Step \(index + 1) of \(model.steps.count)").accessibilityIdentifier("onboardingProgress")
            }
            footerLayout {
                Button { model.back() } label: {
                    navigationLabel("Back")
                }.foregroundStyle(.white)
                    .modifier(IridiumFloatingActionStyle())
                    .setupControllerTarget("setup.back", order: 9000, role: .back, action: { model.back() })
                    .disabled(OnboardingRules.previous(before: model.step, in: model.steps) == nil)
                    .opacity(OnboardingRules.previous(before: model.step, in: model.steps) == nil ? 0.35 : 1)
                    .accessibilityIdentifier("onboardingBack")
                    .accessibilityShowsLargeContentViewer { Text("Back") }
                Button { advance() } label: {
                    navigationLabel(primaryTitle)
                }.accessibilityLabel(primaryTitle).accessibilityIdentifier("onboardingNext")
                    .modifier(IridiumFloatingActionStyle(primary: true))
                    .setupControllerTarget("setup.next", order: 9001, role: .next, action: advance)
                    .accessibilityShowsLargeContentViewer { Text(primaryTitle) }
            }.tint(.white).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24).padding(.vertical, heightClass == .compact ? 8 : 12)
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
    }
    private func navigationLabel(_ title: String) -> some View {
        ZStack {
            Text("Open Library").fontWeight(.bold).hidden().accessibilityHidden(true)
            Text(title)
        }.font(.headline).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 48)
            .contentShape(Capsule())
    }
    private func advance() { model.next() }
    private var primaryTitle: String { model.step == model.steps.last ? "Open Library" : "Next" }
    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if !text.isEmpty { Text(text).font(.subheadline).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func action(_ title: String, _ text: String, symbol: String, id: String, order: Int, perform: @escaping () -> Void) -> some View {
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
        }.buttonStyle(.plain).foregroundStyle(.primary).setupControllerTarget(id, order: order, action: perform)
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
    private func downloadSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private var steamComponents: some View {
        VStack(alignment: .leading, spacing: 12) {
            note("Steam Components", "Required to start Steam games.")
            if dock.clientInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(IridiumTheme.accent)
            } else {
                Text("\(downloadSize(SteamRuntimeFiles.packages.reduce(Int64(0)) { $0 + Int64($1.bytes) })) download")
                    .font(.subheadline).foregroundStyle(.secondary)
                if dock.preparing {
                    ProgressView(dock.progress).frame(maxWidth: .infinity, alignment: .leading)
                } else if MadeiraDock.enabled {
                    action(dock.error == nil ? "Download Steam Components" : "Retry", "", symbol: "arrow.down.circle", id: "downloads.steam", order: 10) {
                        dock.prepareClient()
                    }
                } else {
                    Text("Steam Components are unavailable in this build.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let error = dock.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.red)
            }
        }
    }
    private var wineMono: some View {
        VStack(alignment: .leading, spacing: 12) {
            note("Wine Mono", "For Windows games that use .NET Framework.")
            if WineMonoModel.available {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(IridiumTheme.accent)
            } else {
                Text("\(downloadSize(WineMonoPin.tarBytes)) download").font(.subheadline).foregroundStyle(.secondary)
                switch mono.phase {
                case .idle:
                    action(mono.error == nil ? "Download Wine Mono" : "Retry", "", symbol: "arrow.down.circle", id: "downloads.mono", order: 20) { mono.install() }
                case .downloading(let progress), .installing(let progress):
                    ProgressView(value: progress)
                    Text(mono.status).font(.subheadline)
                }
            }
            if let error = mono.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.red)
            }
        }
    }
    @ViewBuilder private func page(for step: OnboardingRules.Step) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            switch step {
            case .library:
                Text("Import games from Files or connect your Steam account.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let game {
                    IridiumGameOptionsHeader(game: game)
                    Label("Added to Library", systemImage: "checkmark").font(.subheadline).foregroundStyle(IridiumTheme.accent)
                }
                action("Import from Files", "", symbol: "folder", id: "games.files", order: 10) { model.chooseFiles(); importing = true }
                Text("Choose a complete game folder to include its supporting files.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(isExpanded: $systemsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        note("Madeira · Windows", ".exe or game folder")
                        ForEach(IridiumConsoleSystem.all) { system in
                            note(system.title, system.extensions.map { "." + $0 }.joined(separator: " · "))
                        }
                    }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Supported Systems").frame(maxWidth: .infinity, alignment: .leading)
                        .setupControllerToggle("games.systems", order: 20, value: $systemsExpanded, hidesFocusOnTouch: false)
                }.font(.subheadline).multilineTextAlignment(.leading)
                if SteamSignIn.isEnabled {
                    Divider()
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Steam (Optional)").font(.headline).accessibilityAddTraits(.isHeader)
                        if let name = signIn.accountName {
                            Label("Connected as \(name)", systemImage: "checkmark.circle.fill")
                                .font(.subheadline).foregroundStyle(IridiumTheme.accent)
                        }
                        action(signIn.accountName == nil ? "Sign In to Steam" : "Manage Steam Account", "", symbol: "person.crop.circle", id: "games.steam", order: 30) {
                            model.chooseSteam(); steamSignIn = true
                        }
                    }
                }
            case .downloads:
                Text("Install additional components for Windows games.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                steamComponents
                Divider()
                wineMono
            case .jit:
                if jit.enabled {
                    Label("JIT Enabled", systemImage: "checkmark.circle.fill").foregroundStyle(IridiumTheme.accent)
                }
                JITSetupContent(modalPresented: $showingJITImporter, includeShortcut: true)
                DisclosureGroup(isExpanded: $jitSystemsExpanded) {
                    VStack(alignment: .leading, spacing: 16) {
                        note("Required", systems(using: .required))
                        note("Not Required", systems(using: .none))
                        if !systems(using: .optional).isEmpty { note("Optional", systems(using: .optional)) }
                        if model.optionalJIT || model.pspJIT {
                            Toggle("Use JIT for PSP", isOn: pspMode)
                                .setupControllerToggle("jit.psp", order: 210, value: pspMode).disabled(consoles.working)
                        }
                    }.padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Which games need JIT?").setupControllerToggle("jit.systems", order: 200, value: $jitSystemsExpanded, hidesFocusOnTouch: false)
                }
                .font(.subheadline)
            }
        }
    }
}
