// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

struct IridiumCoreFiles: View {
    let game: IridiumConsoleGame
    @ObservedObject private var session = IridiumConsoleSession.shared
    @State private var importing = false
    @State private var importingCIA = false
    @State private var selectedFolder: String?
    @State private var busy = false
    @State private var message: String?
    @State private var export: URL?
    private var folders: [String: String] { IridiumCoreContent.folders(game) }

    var body: some View {
        Form {
          Group {
            if game.runtimeID == "azahar" {
                Section("3DS Content") {
                    Button("Install CIA Game, Update, or DLC", systemImage: "square.and.arrow.down") { importingCIA = true }
                    Text("Choose an unencrypted CIA. Base games join the library and share this game's 3DS storage. Updates and DLC use this storage. Existing files are backed up before replacement.")
                        .font(.footnote)
                }
            }
            if folders.isEmpty {
                Text("Open this game once so its emulator can identify the content folders.")
            }
            ForEach(folders.keys.sorted(), id: \.self) { title in
                Section(title) {
                    Button("Import Files or Folder", systemImage: "square.and.arrow.down") {
                        selectedFolder = folders[title]; importing = true
                    }
                    Button("Export Folder", systemImage: "square.and.arrow.up") {
                        do {
                            let root = try IridiumConsoleLibrary.shared.store.saveDirectory(game)
                            export = try IridiumCoreContent.directory(folders[title]!, root: root, create: true)
                        } catch { message = error.localizedDescription }
                    }
                }
            }
            Section {
                Text("Close the game before importing. Existing files are backed up before replacement. Reopen the game to apply changes. For a texture pack, choose the folder that contains its texture files and settings.")
                if game.runtimeID == "dolphin" {
                    Text("Game patches use Dolphin Game INI files. Keep the original game ID as the file name. Enable patches in the INI before importing.")
                }
                if game.runtimeID == "flycast" {
                    Text("VMU files keep their original names. Export this folder before moving a VMU to another game.")
                }
                if busy || session.dolphinMaintenance { ProgressView("Working on content files…") }
                if let message { Text(message) }
                if let status = session.dolphinSystemStatus { Text(status) }
            }.font(.footnote)
            Section("Backups") {
                Button("Export Content Backups", systemImage: "square.and.arrow.up") {
                    do {
                        export = try IridiumConsoleLibrary.shared.store.checked(["Saves", game.runtimeID, "Content Backups", (game.storageOwnerID ?? game.id).uuidString], createDirectory: true)
                    } catch { message = error.localizedDescription }
                }
            }
          }.iridiumRowSurface()
        }
        .iridiumPageSurface()
        .navigationTitle("Emulator Files")
        .disabled(busy || session.isActive || session.dolphinMaintenance)
        .interactiveDismissDisabled(busy || session.dolphinMaintenance)
        .navigationBarBackButtonHidden(busy || session.dolphinMaintenance)
        .fileImporter(isPresented: $importingCIA, allowedContentTypes: [UTType(filenameExtension: "cia") ?? .data]) { result in
            switch result {
            case .success(let url): session.install3DSCIA(url, game: game)
            case .failure(let error): message = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .data], allowsMultipleSelection: false) { result in
            guard let relative = selectedFolder else { return }
            switch result {
            case .failure(let error): message = error.localizedDescription
            case .success(let sources):
                guard session.beginContentMaintenance() else { return }
                busy = true
                Task { @MainActor in
                    defer { busy = false; session.endContentMaintenance() }
                    do {
                        let root = try IridiumConsoleLibrary.shared.store.saveDirectory(game)
                        let target = try IridiumCoreContent.directory(relative, root: root)
                        let backupRoot = try IridiumConsoleLibrary.shared.store.checked(["Saves", game.runtimeID, "Content Backups", (game.storageOwnerID ?? game.id).uuidString], createDirectory: true)
                        try await Task.detached {
                            for source in sources {
                                let scoped = source.startAccessingSecurityScopedResource()
                                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                                try IridiumFilesAccess.read(source) { coordinated in
                                    try IridiumFilesImport.importContent(from: coordinated, to: target,
                                        backup: backupRoot.appendingPathComponent(UUID().uuidString))
                                }
                            }
                        }.value
                        message = "Files imported. Previous files are in Content Backups."
                    } catch { message = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } })) {
            if let export { IridiumCoreExport(url: export) }
        }
    }
}

struct IridiumCoreExport: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { UIDocumentPickerViewController(forExporting: [url], asCopy: true) }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

struct IridiumCIAImport: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = IridiumConsoleSession.shared
    @ObservedObject private var library = IridiumConsoleLibrary.shared
    @State private var selected: UUID?
    @State private var importing = false
    @State private var started = false
    @State private var message: String?
    private var targets: [IridiumConsoleGame] {
        var owners = Set<UUID>()
        return library.games.filter { $0.runtimeID == "azahar" && owners.insert($0.storageOwnerID ?? $0.id).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section("3DS Storage") {
                        Picker("Install into", selection: $selected) {
                            Text("New 3DS Storage").tag(nil as UUID?)
                            ForEach(targets) { game in Text(game.title).tag(Optional(game.id)) }
                        }
                        Text("Use new storage for a base game. For updates and DLC, choose the game's existing storage.")
                            .font(.footnote)
                    }
                    Section {
                        Button("Choose CIA File", systemImage: "square.and.arrow.down") { importing = true }
                        Text("Choose an unencrypted CIA. Installed games join the library. Existing storage is backed up before replacement.")
                            .font(.footnote)
                    }
                    if session.dolphinMaintenance { ProgressView("Installing 3DS content…") }
                    if started, let status = session.dolphinSystemStatus { Text(status).font(.footnote) }
                    if let message { Text(message).font(.footnote) }
                }.iridiumRowSurface()
            }.iridiumPageSurface()
                .navigationTitle("Install 3DS CIA").navigationBarTitleDisplayMode(.inline)
                .disabled(session.isActive || session.dolphinMaintenance)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }.disabled(session.dolphinMaintenance)
                    }
                }
        }
        .interactiveDismissDisabled(session.dolphinMaintenance)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "cia") ?? .data]) { result in
            switch result {
            case .success(let url):
                let game = targets.first { $0.id == selected }
                guard selected == nil || game != nil else { message = "Choose the game's storage again."; return }
                message = nil; started = true
                session.install3DSCIA(url, game: game)
            case .failure(let error): message = error.localizedDescription
            }
        }
    }
}
