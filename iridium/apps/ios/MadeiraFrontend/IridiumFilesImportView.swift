// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

struct IridiumImportSource: Identifiable {
    let id = UUID()
    let url: URL
    static var contentTypes: [UTType] {
        [.folder] + ["exe"].compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
            + IridiumConsoleLibrary.importContentTypes
    }
}

/// The picker grants access only to what the user selected. Selecting a folder
/// permits copying its dependencies; selecting an EXE never reads its siblings.
struct IridiumFilesImportView: View {
    let source: IridiumImportSource
    var imported: (LibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [String] = []
    @State private var folder = false
    @State private var working = true
    @State private var failure: String?
    @State private var operation: Task<Void, Never>?
    @State private var publication: IridiumFilesImport.Publication?
    @State private var cancelled = false
    @State private var finishing = false

    var body: some View {
        NavigationStack {
            List {
                if working { ProgressView(finishing ? "Finishing import…" : candidates.isEmpty ? "Reading game files…" : "Importing game…") }
                if let failure { Text(failure).foregroundStyle(.red) }
                if !working {
                    Section(folder ? "Choose the game's executable" : "Windows game") {
                        ForEach(candidates, id: \.self) { path in
                            Button { begin(path) } label: {
                                Label(folder ? path : source.url.lastPathComponent, systemImage: "app.dashed")
                            }
                        }
                    }
                    if candidates.isEmpty && failure == nil { Text("No supported Windows executables were found.") }
                    Text(folder ? "The selected folder and its dependencies are copied into Iridium. Original files stay where they are." :
                        "Only this EXE will be copied. If the game needs DLLs or other files, cancel and choose its game folder instead.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.iridiumPageSurface().navigationTitle("Import from Files")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel).disabled(finishing) } }
                .interactiveDismissDisabled(working)
                .task {
                    recordImport("[Files Import] phase=scan outcome=started")
                    do {
                        let url = source.url
                        let worker = Task.detached(priority: .userInitiated) {
                            try IridiumFilesAccess.read(url) { coordinated in
                                try Task.checkCancellation()
                                let isFolder = try coordinated.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                                let paths = isFolder ? try IridiumFilesImport.executablePaths(in: coordinated,
                                    isCancelled: { Task.isCancelled }) : [""]
                                // Provider-coordinated URLs need not outlive the accessor.
                                return (isFolder, paths)
                            }
                        }
                        let result = try await withTaskCancellationHandler {
                            try await worker.value
                        } onCancel: { worker.cancel() }
                        guard !cancelled, !Task.isCancelled else {
                            recordImport("[Files Import] phase=scan outcome=cancelled")
                            return
                        }
                        folder = result.0
                        candidates = result.1
                        working = false
                        recordImport("[Files Import] phase=scan outcome=ready candidates=\(candidates.count) folder=\(folder)")
                    } catch is CancellationError {
                        recordImport("[Files Import] phase=scan outcome=cancelled")
                    } catch {
                        guard !cancelled, !Task.isCancelled else {
                            recordImport("[Files Import] phase=scan outcome=cancelled")
                            return
                        }
                        recordImport("[Files Import] phase=scan outcome=failed code=\(IridiumFilesImport.diagnosticCode(error))")
                        if !cancelled, !Task.isCancelled { failure = error.localizedDescription; working = false }
                    }
                }
                .onDisappear { _ = cancelOperation() }
        }
    }
    private func recordImport(_ line: String) {
        LogStore.shared.log(line)
        RuntimeDiagnosticLogFiles.writeConsoleLine(line)
    }
    private func begin(_ path: String) {
        guard !working else { return }
        working = true; failure = nil
        recordImport("[Files Import] phase=copy outcome=started folder=\(folder)")
        let sourceURL = source.url
        let root = folder ? source.url : nil
        let drive = LibraryModel.drive.resolvingSymlinksInPath()
        let publication = IridiumFilesImport.Publication()
        self.publication = publication
        operation = Task { @MainActor in
            var phase = "copy"
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try IridiumFilesAccess.read(sourceURL) { coordinated in
                        let executable = root == nil ? coordinated : coordinated.appendingPathComponent(path)
                        return try IridiumFilesImport.importExecutable(at: executable, drive: drive,
                            sourceRoot: root == nil ? nil : coordinated, publication: publication,
                            isCancelled: { Task.isCancelled })
                    }
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { if publication.cancel() { worker.cancel() } }
                recordImport("[Files Import] phase=copy outcome=published")
                phase = "register"
                // A successful result has won the publication gate. Do not
                // discard it because cancellation arrived after the move.
                let model = LibraryModel.shared
                // Selecting an already imported executable retains every setting,
                // artwork key, favorite and save identity rather than duplicating it.
                if let existing = model.entries.first(where: { $0.relativePath == result.relativePath && $0.steamAppID == nil }) {
                    recordImport("[Files Import] phase=register outcome=reused")
                    imported(existing); return
                }
                let entry = LibraryEntry(id: result.importID ?? UUID(), title: result.title,
                                         relativePath: result.relativePath, bits: result.bits)
                model.save(entry)
                guard model.entries.contains(where: { $0.id == entry.id }) else {
                    throw LibraryError.message(model.error ?? "The library entry could not be saved. The copied files have been kept.")
                }
                imported(entry)
                recordImport("[Files Import] phase=register outcome=saved")
            } catch is CancellationError {
                recordImport("[Files Import] phase=copy outcome=cancelled")
            }
            catch {
                recordImport("[Files Import] phase=\(phase) outcome=failed code=\(IridiumFilesImport.diagnosticCode(error))")
                self.publication = nil
                finishing = false
                failure = error.localizedDescription; working = false
            }
        }
    }
    private func cancelOperation() -> Bool {
        if let publication, !publication.cancel() { return false }
        cancelled = true; operation?.cancel(); operation = nil
        return true
    }
    private func cancel() {
        if cancelOperation() { dismiss() }
        else { finishing = true }
    }
}

private enum IridiumFilesAccess {
    static func read<Value>(_ url: URL, operation: (URL) throws -> Value) throws -> Value {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        var coordinationError: NSError?
        var result: Result<Value, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            result = Result { try Task.checkCancellation(); return try operation(source) }
        }
        // An accessor that completed publication owns a real result. Do not
        // replace it with a late coordination error and lose the saved copy.
        if let result { return try result.get() }
        if let coordinationError { throw coordinationError }
        throw IridiumFilesImport.Failure.sourceChanged
    }
}
