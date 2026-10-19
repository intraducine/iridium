// SPDX-License-Identifier: AGPL-3.0-only
#if IRIDIUM_UX_PREVIEW
#if !targetEnvironment(simulator)
#error("The UI preview must never be built for a physical device")
#endif
import SwiftUI

@MainActor enum IridiumPreviewSupport {
    struct Sample: Decodable {
        let id: UUID
        let title: String
        let platform: IridiumPlatform
        let runtime: String
        let ext: String
        let steamID: Int?
        let cover: String
        let background: String?
    }
    static func seed() async throws {
        guard Bundle.main.bundleIdentifier == "software.iridium.uipreview" else { return }
        guard let root = Bundle.main.url(forResource: "PreviewSamples", withExtension: nil) else { return }
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: root.appendingPathComponent("samples.json")))
        for sample in samples where sample.platform == .windows {
            if var entry = LibraryModel.shared.entries.first(where: { $0.id == sample.id }), entry.relativePath.hasPrefix("Artwork Samples/"),
               !FileManager.default.fileExists(atPath: LibraryEntry.hostURL(ofWindowsPath: entry.windowsPath)?.path ?? "") {
                entry.relativePath = "Games/\(sample.title)/\(sample.title).exe"
                LibraryModel.shared.save(entry)
            }
        }
        guard !UserDefaults.standard.bool(forKey: "iridium.preview.seeded.v1") else { return }
        let consoleStore = IridiumConsoleLibrary.shared.store
        var games = try consoleStore.load()
        for sample in samples {
            if sample.platform == .windows {
                LibraryModel.shared.save(LibraryEntry(id: sample.id, title: sample.title,
                    relativePath: "Games/\(sample.title)/\(sample.title).exe", bits: 64, steamID: sample.steamID))
            } else if !games.contains(where: { $0.id == sample.id }) {
                games.append(.init(id: sample.id, title: sample.title, platform: sample.platform,
                    runtimeID: sample.runtime, fileExtension: sample.ext, importedAt: Date(),
                    originalFilename: sample.platform == .arcade ? "sample.zip" : nil))
            }
            try IridiumArtworkModel.shared.update(sample.id) { $0.automaticLookup = false }
            try await IridiumArtworkModel.shared.setImage(Data(contentsOf: root.appendingPathComponent(sample.cover)), for: sample.id, background: false)
            if let background = sample.background {
                try await IridiumArtworkModel.shared.setImage(Data(contentsOf: root.appendingPathComponent(background)), for: sample.id, background: true)
            }
        }
        try consoleStore.save(games); IridiumConsoleLibrary.shared.reload()
        UserDefaults.standard.set(samples.prefix(3).map { $0.id.uuidString }.joined(separator: ","), forKey: "iridium.favoriteGames")
        UserDefaults.standard.set(true, forKey: "iridium.preview.seeded.v1")
    }
}

@MainActor final class IridiumSimulatorLaunch: ObservableObject {
    static let shared = IridiumSimulatorLaunch()
    @Published var missingGame: IridiumGame?
    func attempt(_ game: IridiumGame) {
        let url: URL?
        if let entry = game.windows {
            url = LibraryEntry.hostURL(ofWindowsPath: entry.windowsPath)
        } else if let console = game.console {
            url = try? IridiumConsoleLibrary.shared.store.rom(console)
        } else { url = nil }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            missingGame = game; return
        }
        LibraryModel.shared.error = "Playing \(game.platform.title) games requires an iPhone or iPad."
    }
}

struct IridiumPreviewRoot: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var launch = IridiumSimulatorLaunch.shared
    @State private var ready = false
    @State private var error: String?
    @State private var locating = false
    @State private var source: IridiumImportSource?
    private var screen: String {
        let args = ProcessInfo.processInfo.arguments
        return args.firstIndex(of: "--screen").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "library"
    }
    var body: some View {
        Group {
            if ready {
                switch screen {
                case "settings": LibraryView(play: play, enableJIT: enableJIT, startDock: { _, _ in unavailableWindows() }, tab: 1)
                case "controls": NavigationStack { IridiumControlsSettingsView() }
                case "credits": NavigationStack { Form { Group { IridiumCreditsSections() }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Credits") }
                case "notices": NavigationStack { IridiumSoftwareNoticesView() }
                case "capabilities": NavigationStack { IridiumCapabilitiesView() }
                case "diagnostics": NavigationStack { Form { Group { IridiumDiagnosticsSections() }.iridiumRowSurface() }.iridiumPageSurface().navigationTitle("Diagnostics") }
                case "layout": IridiumTouchLayoutEditor(target: .init(platform: .psp, title: "PSP"))
                default: IridiumLibraryView(play: play, enableJIT: enableJIT, startDock: { _, _ in unavailableWindows() })
                }
            } else if let error { ContentUnavailableView("Library Could Not Open", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ProgressView("Loading Library…") }
        }.preferredColorScheme(.dark)
            .task {
                do { try await IridiumPreviewSupport.seed(); ready = true }
                catch { self.error = error.localizedDescription }
            }
            .alert("Game File Not Found", isPresented: Binding(get: { launch.missingGame != nil }, set: { if !$0 { launch.missingGame = nil } })) {
                Button("Locate Game") { launch.missingGame = nil; locating = true }
                Button("Cancel", role: .cancel) { launch.missingGame = nil }
            } message: { Text("Choose the game file or its complete folder to play \(launch.missingGame.map { IridiumArtworkModel.shared.title($0) } ?? "this game").") }
            .fileImporter(isPresented: $locating, allowedContentTypes: IridiumImportSource.contentTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): if !urls.isEmpty { source = .init(urls: urls) }
                case .failure(let failure): if (failure as NSError).code != NSUserCancelledError { LibraryModel.shared.error = failure.localizedDescription }
                }
            }
            .sheet(item: $source) { source in
                IridiumGameImportView(source: source, importedConsole: { _ in self.source = nil }) { _ in self.source = nil }
            }
            .sheet(isPresented: $jit.showSetup) { JITSetupView() }
    }
    private func play(_ entry: LibraryEntry) { launch.attempt(IridiumGame(windows: entry)) }
    private func enableJIT() { jit.enable { _ in } }
    private func unavailableWindows() { LibraryModel.shared.error = "Playing Windows games requires an iPhone or iPad." }
}
#endif
