import SwiftUI
import IridiumCore
import IridiumRuntime

@main struct InterfacePreviewApp: App {
    @StateObject private var controller = LibraryController()
    @State private var testSelection: UUID?
    @State private var testSearch = ""
    @State private var testFavorites = false
    @State private var plays = 0
    @State private var options = 0
    @StateObject private var model: AppViewModel
    init() {
        let empty = ProcessInfo.processInfo.arguments.contains("--empty")
        let games = (empty ? [] : ["Unreleased Project", "Mountain Walk", "A Very Long Custom Game Title For Layout Testing"]).enumerated().map { index, title in
            GameRecord(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!, title: title, source: .manualImport, installPath: "/preview", savePathMapping: "", compatibilityProfileName: "", inputProfileName: "", touchOverlayName: "", controllerPresetName: "", keyboardMouseEnabled: true, prefixState: .clean, deviceTier: .tier1, rendererPreset: .dxvkBalanced, launchProfile: .init(executablePath: title + ".exe", arguments: [], prefixID: UUID(), rendererPreset: .dxvkBalanced, deviceTier: .tier1, titleFlags: []), summary: "")
        }
        let candidates = [DiscoveredExecutable(path: "/Custom/Custom.exe", filename: "Custom.exe", score: 10), DiscoveredExecutable(path: "/Custom/Launcher.exe", filename: "Launcher.exe", score: 5)]
        let scan: ImportScanResult? = ProcessInfo.processInfo.arguments.contains("--import") ? .init(installPath: "/Custom", executables: candidates, recommendedExecutable: candidates[0], warnings: []) : nil
        if ProcessInfo.processInfo.arguments.contains("--covers") {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).pngData { context in
                UIColor.darkGray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            }
            for (index, game) in games.enumerated() {
                try? LibraryArtwork.shared.setImage(data, id: game.id, background: false)
                let backdrop = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600)).pngData { context in
                    [UIColor.darkGray, UIColor.brown, UIColor.darkGray][index].setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
                    UIColor.white.setFill(); context.fill(CGRect(x: 150, y: 0, width: 40, height: 600))
                }
                try? LibraryArtwork.shared.setImage(backdrop, id: game.id, background: true)
            }
        } else {
            for game in games { try? LibraryArtwork.shared.update(game.id) { $0.cover = nil } }
        }
        _model = StateObject(wrappedValue: AppViewModel.makeForTesting(games: games, importScanResult: scan,
            activeRuntimePlayerSession: ProcessInfo.processInfo.arguments.contains("--presented-player") ? Self.playerSession(game: games[0]) : nil))
    }
    static func playerSession(game: GameRecord) -> RuntimePlayerSession {
        .init(sessionIdentifier: "ui-only", gameID: game.id, gameTitle: "UI Test Player",
            runtimeBundleID: "none", runtimeBundleVersion: "none", graphicsStack: .dxvkViaMoltenVK,
            launchTicketPath: "", sessionLogPath: "", telemetryPath: "", state: .queued,
            stateHistory: [.queued], statusSummary: "Presentation test only", launchedAt: .now)
    }
    static var playerConfiguration: RuntimePlayerBridgeConfiguration {
        let root = FileManager.default.temporaryDirectory.path
        return .init(sessionIdentifier: "ui-only", surfaceIdentifier: "ui-only", bridgeRootPath: root,
            bridgeConfigPath: root + "/config", framebufferPath: root + "/frame", frameReadyPath: root + "/ready",
            inputEventsPath: root + "/input", audioStatePath: root + "/audio", tracePath: root + "/trace",
            wineDebugLogPath: root + "/wine", surfaceWidth: 640, surfaceHeight: 480)
    }
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--presented-player") {
                Text("Player closed").accessibilityIdentifier("returnedFromPlayer")
                    .background { MadeiraPlayerPresentation(viewModel: model, presentationConfiguration: Self.playerConfiguration) }
            } else if ProcessInfo.processInfo.arguments.contains("--checks") {
                NavigationStack { GameCompatibilityView(game: model.games[0], viewModel: model) }
                    .environmentObject(controller).environment(\.menuController, controller)
            } else if ProcessInfo.processInfo.arguments.contains("--contrast") {
                NavigationStack { ContrastPreview().iridiumListChrome() }
                    .environmentObject(controller).environment(\.menuController, controller)
            } else if ProcessInfo.processInfo.arguments.contains("--settings") {
                NavigationStack { SettingsView(viewModel: model) }
                    .environmentObject(controller).environment(\.menuController, controller)
            } else if ProcessInfo.processInfo.arguments.contains("--player") {
                let root = FileManager.default.temporaryDirectory.path
                let session = RuntimePlayerSession(sessionIdentifier: "ui-only", gameID: model.games[0].id,
                    gameTitle: "UI Test Player", runtimeBundleID: "none", runtimeBundleVersion: "none",
                    graphicsStack: .dxvkViaMoltenVK, launchTicketPath: "", sessionLogPath: "", telemetryPath: "",
                    state: .queued, stateHistory: [.queued], statusSummary: "Presentation test only", launchedAt: .now)
                let config = RuntimePlayerBridgeConfiguration(sessionIdentifier: "ui-only", surfaceIdentifier: "ui-only",
                    bridgeRootPath: root, bridgeConfigPath: root + "/config", framebufferPath: root + "/frame",
                    frameReadyPath: root + "/ready", inputEventsPath: root + "/input", audioStatePath: root + "/audio",
                    tracePath: root + "/trace", wineDebugLogPath: root + "/wine", surfaceWidth: 640, surfaceHeight: 480)
                RuntimePlayerView(session: session, viewModel: model, presentationConfiguration: config)
            } else {
                Group {
                    if ProcessInfo.processInfo.arguments.contains("--actions") {
                        LibraryShelf(games: model.games, artwork: .shared, controller: controller,
                            play: { _ in plays += 1 }, disabled: { _ in false }, launchTitle: { _ in "Play" },
                            details: { _ in options += 1 }, search: $testSearch, favorites: $testFavorites, selectedID: $testSelection)
                            .overlay(alignment: .bottomLeading) { Text("Plays \(plays) Options \(options)").accessibilityIdentifier("actionCounts").padding(.bottom, 60) }
                    } else {
                        RootTabView(viewModel: model, controller: ProcessInfo.processInfo.arguments.contains("--controller") || ProcessInfo.processInfo.arguments.contains("--hints") ? controller : nil)
                    }
                }
                    .onAppear { if ProcessInfo.processInfo.arguments.contains("--hints") { controller.showingControllerHints = true } }
                    .overlay(alignment: .bottom) {
                        if ProcessInfo.processInfo.arguments.contains("--controller") && !controller.hasMenuScope {
                            ControllerTestPad(controller: controller)
                        }
                    }
            }
        }
    }
}

struct ControllerTestPad: View {
    @ObservedObject var controller: LibraryController
    var scopeID: UUID? = nil
    var body: some View {
        if controller.activeMenuID == scopeID {
                            HStack {
                                ForEach(0..<11) { index in
                                    Button("\(index)") { controller.process(pressed: [index]); controller.process(pressed: [index]); controller.process(pressed: []) }
                                        .accessibilityIdentifier("pad\(index)")
                                        .frame(width: 22, height: 44)
                                }
                                Button("Burst") {
                                    Task { @MainActor in
                                        for direction in [1, 0, 1, 0, 1, 0, 1, 0] {
                                            controller.send(LibraryController.Input(rawValue: direction)!)
                                            try? await Task.sleep(for: .milliseconds(55))
                                        }
                                    }
                                }.accessibilityIdentifier("rapidDirections")
                                Button("LS") {
                                    controller.process(pressed: [], stickX: 0.9)
                                    controller.process(pressed: [])
                                }.accessibilityIdentifier("stickRight").frame(width: 24, height: 44)
                            }.background(.black)
    }
    }
}

private struct ContrastPreview: View {
    @State private var enabled = false
    @State private var selected = 0
    var body: some View {
        List {
            Section("Native control states") {
                MenuToggle("Enabled switch", isOn: $enabled)
                MenuToggle("Disabled switch", isOn: .constant(true)).disabled(true)
                Picker("Selection", selection: $selected) {
                    Text("First").tag(0)
                    Text("Second").tag(1)
                }.pickerStyle(.segmented)
                MenuButton("Import Pairing File") {}
                Button("Play") {}.libraryGlass(prominent: true)
                Button("Unavailable") {}.libraryGlass(prominent: true).disabled(true)
                Button("Remove", role: .destructive) {}
                Text("Supporting text").foregroundStyle(.secondary)
            }
        }.navigationTitle("Contrast")
    }
}
