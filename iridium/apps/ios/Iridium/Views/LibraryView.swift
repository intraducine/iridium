import IridiumCore
import IridiumRuntime
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var viewModel: AppViewModel
    var showDownloads: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPresentingImportPicker = false
    @State private var isShowingImportChoices = false
    @State private var isPresentingGamesFolder = false
    @State private var filesGameFolders: [URL] = []
    @State private var filesGamesError: String?
    @State private var isLoadingFilesGames = false
    @State private var filesGamesRequestID = UUID()
    @State private var selectedFilesGame: URL?
    @State private var liveContainerStatus = LiveContainerIntegration.processLaunchStatus
    @State private var isShowingLiveContainerRepair = false
    @State private var isShowingLiveContainerRelaunchRequired = false
    @State private var liveContainerRepairRequiresRelaunch = false
    @State private var liveContainerIntegrationMessage: String?

    @StateObject private var artwork = LibraryArtwork.shared
    @EnvironmentObject private var controller: LibraryController
    @State private var selectedID: UUID?
    @State private var search = ""
    @State private var favorites = false
    @State private var detailGame: GameRecord?
    @State private var appSettings = false
    @State private var importName = ""
    @State private var chooseAnotherFolder = false
    @State private var relocatingGame: GameRecord?

    var body: some View {
        Group {
        if appSettings {
            SettingsView(viewModel: viewModel, onBack: { appSettings = false })
        } else {
        LibraryShelf(games: viewModel.games, artwork: artwork, controller: controller,
            play: { requestGameLaunch($0) },
            disabled: { viewModel.isLaunchActionDisabled(for: $0) && !isPlayerTakingOver($0) },
            launchTitle: { isPlayerTakingOver($0) ? "Play" : viewModel.launchActionTitle(for: $0) },
            launchDetail: { viewModel.isLaunchActionDisabled(for: $0) ? viewModel.launchActionDetail(for: $0) : nil },
            details: { detailGame = $0 },
            search: $search, favorites: $favorites, selectedID: $selectedID,
            importGame: { relocatingGame = nil; isShowingImportChoices = true }, settings: { appSettings = true },
            acceptsControllerInput: detailGame == nil && !appSettings && !isPresentingImportPicker && !isShowingImportChoices && !isPresentingGamesFolder && viewModel.importScanResult == nil && !isShowingLiveContainerRepair && !isShowingLiveContainerRelaunchRequired && artwork.error == nil)
            .toolbar(.hidden, for: .navigationBar)
        }
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            if !appSettings, detailGame == nil, let message = liveContainerIntegrationMessage ?? viewModel.importStatusMessage ?? artwork.lookupNote {
                Text(message).font(.footnote).padding(12).frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { viewModel.importScanResult != nil }, set: { if !$0 { viewModel.dismissImportScan() } }), onDismiss: {
            if chooseAnotherFolder { chooseAnotherFolder = false; requestGameImport() }
        }) {
            NavigationStack {
                if let result = viewModel.importScanResult { importReviewCard(result) }
            }
        }
        .sheet(isPresented: $isPresentingGamesFolder, onDismiss: {
            filesGamesRequestID = UUID()
            isLoadingFilesGames = false
            if let selectedFilesGame {
                self.selectedFilesGame = nil
                viewModel.scanImportFolder(at: selectedFilesGame, storage: .filesFolder(filesGamesRoot))
            }
        }) {
            gamesFolderSheet
        }
        .navigationDestination(item: $detailGame) { game in
            GameDetailView(game: game, viewModel: viewModel, locate: {
                relocatingGame = game; requestGameImport()
            }, launch: { requestGameLaunch(game) })
        }
        .task(id: "\(viewModel.games.map(\.id))-\(artwork.connected)") { await artwork.prepare(viewModel.games) }
        .alert("Artwork", isPresented: Binding(get: { artwork.error != nil }, set: { if !$0 { artwork.error = nil } })) {
            Button("OK") { artwork.error = nil }
        } message: { Text(artwork.error ?? "") }
        .confirmationDialog(relocatingGame == nil ? "Add Game" : "Locate Game", isPresented: $isShowingImportChoices) {
            if relocatingGame == nil { Button("Download from Steam", action: showDownloads) }
            Button("Choose Folder") { openImportPicker() }
            if !liveContainerStatus.isHosted {
                Button("Find Games in Iridium Folder") { isPresentingGamesFolder = true }
            }
        } message: {
            Text("To use Files, place each game in \(filesDeviceLocation) → Iridium → Games.")
        }
        .fullScreenCover(isPresented: $isPresentingImportPicker) {
            GameImportDocumentPicker(
                selection: {
                    isPresentingImportPicker = false
                    switch $0 {
                    case let .success(url):
                        viewModel.scanImportFolder(at: url)
                    case let .failure(error):
                        viewModel.reportImportSelectionFailure(error)
                    }
                },
                cancellation: {
                    isPresentingImportPicker = false
                }
            )
            .ignoresSafeArea()
        }
        .alert("Repair LiveContainer Setup", isPresented: $isShowingLiveContainerRepair) {
            Button("Repair Settings") {
                repairLiveContainerIntegration()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Iridium will enable LiveContainer's file-picker fixes, Launch with JIT, and install Iridium's persistent TXM script. Fully close and relaunch Iridium afterward.")
        }
        .alert("Restart Iridium", isPresented: $isShowingLiveContainerRelaunchRequired) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("LiveContainer settings are repaired. Fully close Iridium, then reopen it from LiveContainer so the updated launch settings take effect.")
        }
        .onAppear { refreshLiveContainerSetup() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshLiveContainerSetup() }
        }
    }

    private func importReviewCard(_ result: ImportScanResult) -> some View {
        Form {
            Section {
                MenuTextField("Game name", text: $importName).disabled(viewModel.isImportingGame || relocatingGame != nil)
                LabeledContent("Folder", value: URL(fileURLWithPath: result.installPath).lastPathComponent)
                if result.executables.count > 1 || result.recommendedExecutable == nil {
                    Text("Executable").font(.headline)
                    ForEach(result.executables) { executable in
                        MenuButton {
                            viewModel.chooseImportExecutable(path: executable.path)
                        } label: {
                            HStack {
                                Text(executable.filename)
                                if result.recommendedExecutable?.path == executable.path {
                                    Spacer(); Image(systemName: "checkmark")
                                }
                            }
                        }.accessibilityValue(result.recommendedExecutable?.path == executable.path ? "Selected" : "")
                    }
                } else if let executable = result.recommendedExecutable {
                    LabeledContent("Executable", value: executable.filename)
                }
            } header: { Text("Game") } footer: { Text("Add the game with its own name and optional artwork. You can edit both in Game Options. Compatibility varies by game.") }
            if result.executables.isEmpty {
                Text("No Windows executable was found. Choose the folder that contains the game's .exe file.")
            }
            if let message = viewModel.importStatusMessage { Text(message).font(.footnote) }
            ForEach(result.warnings, id: \.self) { Text($0).font(.footnote) }
            Section {
                MenuButton(relocatingGame == nil ? "Add Game" : "Use This Folder") {
                    if let game = relocatingGame { viewModel.relocateScannedImport(game) }
                    else { viewModel.registerScannedImport(title: importName) }
                }
                    .libraryGlass(prominent: true).disabled(viewModel.isImportingGame || result.recommendedExecutable == nil || importName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                MenuButton("Choose Another Folder") { chooseAnotherFolder = true; viewModel.dismissImportScan() }.disabled(viewModel.isImportingGame)
            }
        }
        .interactiveDismissDisabled(viewModel.isImportingGame)
        .iridiumListChrome().navigationTitle("Confirm Game").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { viewModel.dismissImportScan() }.disabled(viewModel.isImportingGame).keyboardShortcut(.cancelAction) } }
        .onAppear { importName = URL(fileURLWithPath: result.installPath).lastPathComponent }
    }

    private func refreshLiveContainerSetup() {
        liveContainerStatus = LiveContainerIntegration.currentStatus()
        let launchStatus = LiveContainerIntegration.processLaunchStatus
        liveContainerRepairRequiresRelaunch = liveContainerStatus.isHosted
            && liveContainerStatus.fullyConfigured
            && (!launchStatus.fullyConfigured
                || launchStatus.launchWithJITEnabled != liveContainerStatus.launchWithJITEnabled)
        // Normal LiveContainer state belongs in the setup flow, not a permanent
        // library banner. Keep this slot for an actual repair failure only.
        liveContainerIntegrationMessage = nil
    }

    private func requestGameLaunch(_ game: GameRecord) {
        refreshLiveContainerSetup()
        guard liveContainerStatus.isHosted else {
            viewModel.recordLaunchPreparation(for: game)
            return
        }

        let launchStatus = LiveContainerIntegration.processLaunchStatus
        if !liveContainerStatus.fullyConfigured || !liveContainerStatus.launchWithJITEnabled {
            do {
                liveContainerStatus = try LiveContainerIntegration.repairCurrentProcessConfiguration()
                refreshLiveContainerSetup()
                liveContainerIntegrationMessage = nil
                isShowingLiveContainerRelaunchRequired = true
                print("[IridiumRuntime] livecontainer: game launch repaired configuration; relaunch required")
            } catch {
                liveContainerStatus = LiveContainerIntegration.currentStatus()
                liveContainerIntegrationMessage = "Could not repair LiveContainer settings: \(error.localizedDescription)"
                print("[IridiumRuntime] livecontainer: game launch repair failed: \(error.localizedDescription)")
            }
            return
        }

        guard launchStatus.fullyConfigured,
              launchStatus.launchWithJITEnabled,
              launchStatus.launchWithJITEnabled == liveContainerStatus.launchWithJITEnabled else {
            isShowingLiveContainerRelaunchRequired = true
            return
        }

        viewModel.recordLaunchPreparation(for: game)
    }

    private func isPlayerTakingOver(_ game: GameRecord) -> Bool {
        #if MADEIRA_RUNTIME
        return MadeiraRuntimeAdapter.enabled && viewModel.activeRuntimePlayerSession?.gameID == game.id
        #else
        return false
        #endif
    }

    private func requestGameImport() {
        if !liveContainerStatus.isHosted {
            isShowingImportChoices = true
            return
        }
        openImportPicker()
    }

    private var filesDeviceLocation: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
    }

    private var filesGamesRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Games", directoryHint: .isDirectory)
    }

    private var gamesFolderSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Place each game in its own folder at \(filesDeviceLocation) → Iridium → Games. Your files stay there when you add a game.")
                        .foregroundStyle(.secondary)
                }
                if isLoadingFilesGames {
                    ProgressView("Finding game folders")
                } else if let filesGamesError {
                    Text(filesGamesError).foregroundStyle(.secondary)
                } else if filesGameFolders.isEmpty {
                    Text("No game folders yet. In Files, open \(filesDeviceLocation) → Iridium → Games, add a game folder, then tap Refresh.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filesGameFolders, id: \.self) { folder in
                        MenuButton(folder.lastPathComponent) {
                            selectedFilesGame = folder
                            isPresentingGamesFolder = false
                        }
                    }
                }
                MenuButton("Refresh") { Task { await loadFilesGames() } }
                    .disabled(isLoadingFilesGames)
            }
            .iridiumListChrome(onBack: { isPresentingGamesFolder = false })
            .navigationTitle("Games in Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresentingGamesFolder = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .task { await loadFilesGames() }
        }
    }

    @MainActor private func loadFilesGames() async {
        let requestID = UUID()
        filesGamesRequestID = requestID
        isLoadingFilesGames = true
        filesGamesError = nil
        do {
            let root = filesGamesRoot
            let folders = try await Task.detached(priority: .userInitiated) {
                try ManagedGameFiles.gameFolders(in: root)
            }.value
            guard requestID == filesGamesRequestID, isPresentingGamesFolder else { return }
            filesGameFolders = folders
        } catch {
            guard requestID == filesGamesRequestID, isPresentingGamesFolder else { return }
            filesGameFolders = []
            filesGamesError = "Could not read Iridium's Games folder: \(error.localizedDescription)"
        }
        isLoadingFilesGames = false
    }

    private func openImportPicker() {
        refreshLiveContainerSetup()
        // Saved settings cannot activate hooks in an already-running guest.
        if liveContainerRepairRequiresRelaunch {
            isShowingLiveContainerRelaunchRequired = true
            return
        }
        guard !liveContainerStatus.isHosted
            || LiveContainerIntegration.processLaunchStatus.filePickerConfigured
        else {
            isShowingLiveContainerRepair = true
            return
        }
        isPresentingImportPicker = true
    }

    private func repairLiveContainerIntegration() {
        do {
            liveContainerStatus = try LiveContainerIntegration.repairCurrentProcessConfiguration()
            refreshLiveContainerSetup()
            liveContainerIntegrationMessage = nil
            isShowingLiveContainerRelaunchRequired = true
            print("[IridiumRuntime] livecontainer: configuration repaired; relaunch required")
        } catch {
            liveContainerStatus = LiveContainerIntegration.currentStatus()
            liveContainerIntegrationMessage = "Could not repair LiveContainer settings: \(error.localizedDescription)"
            print("[IridiumRuntime] livecontainer: configuration repair failed: \(error.localizedDescription)")
        }
    }
}

private struct GameImportDocumentPicker: UIViewControllerRepresentable {
    let selection: (Result<URL, Error>) -> Void
    let cancellation: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: selection, cancellation: cancellation)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Opening a folder must use asCopy: false on both standalone and hosted installs.
        let picker = UIDocumentPickerViewController(
            // LiveContainer's safe picker hook recognizes an exact folder-only
            // request and translates it into its hosted-app compatibility flow.
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        print("[IridiumRuntime] importPicker: presented folder picker")
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let selection: (Result<URL, Error>) -> Void
        private let cancellation: () -> Void
        private var completed = false

        init(
            selection: @escaping (Result<URL, Error>) -> Void,
            cancellation: @escaping () -> Void
        ) {
            self.selection = selection
            self.cancellation = cancellation
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard !completed else {
                return
            }
            completed = true
            guard let url = urls.first else {
                let error = CocoaError(.fileReadUnknown)
                print("[IridiumRuntime] importPicker: empty selection")
                selection(.failure(error))
                return
            }
            print("[IridiumRuntime] importPicker: folder selected")
            selection(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !completed else {
                return
            }
            completed = true
            print("[IridiumRuntime] importPicker: cancelled")
            cancellation()
        }
    }
}
