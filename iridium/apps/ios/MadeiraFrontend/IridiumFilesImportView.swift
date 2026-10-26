// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

struct IridiumImportSource: Identifiable {
    let id = UUID()
    let urls: [URL]
    var url: URL { urls[0] }
    init(url: URL) { urls = [url] }
    init(urls: [URL]) { self.urls = urls }
    static var contentTypes: [UTType] {
        [.folder] + ["exe", "plist", "mobiledevicepairing", "zip", "7z"].compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
            + IridiumConsoleLibrary.importContentTypes + ["bin", "raw"].compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
    }
}

/// Setup and Locate Game use the same queue as the library's file picker.
struct IridiumGameImportView: View {
    let source: IridiumImportSource
    var importingEnabled = true
    let importedConsole: (IridiumConsoleGame) -> Void
    let imported: (LibraryEntry) -> Void
    @ObservedObject private var imports = IridiumImportCoordinator.shared
    @ObservedObject private var consoles = IridiumConsoleLibrary.shared
    @State private var previousID: UUID?
    @State private var completed = false
    var body: some View {
        IridiumImportFolderView(automaticallyScan: importingEnabled)
            .task(id: source.id) {
                guard importingEnabled else { return }
                previousID = imports.lastImportedGameID
                imports.receive(source.urls)
            }
            .onChange(of: imports.isWorking) { _, _ in finish() }
            .onChange(of: consoles.games.map(\.id)) { _, _ in finish() }
    }
    private func finish() {
        guard importingEnabled, !completed, !imports.isWorking, imports.choices.isEmpty, imports.failures.isEmpty,
              let id = imports.lastImportedGameID, id != previousID else { return }
        if let entry = LibraryModel.shared.entries.first(where: { $0.id == id }) { completed = true; imported(entry) }
        else if let game = consoles.games.first(where: { $0.id == id }) { completed = true; importedConsole(game) }
    }
}
