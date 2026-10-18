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
        [.folder] + ["exe"].compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
            + IridiumConsoleLibrary.importContentTypes + ["bin", "raw"].compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
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

enum IridiumFilesAccess {
    static func read<Value>(_ urls: [URL], operation: ([URL]) throws -> Value) throws -> Value {
        let scopes = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Value, Error>?
        let coordinator = NSFileCoordinator()
        func coordinate(_ index: Int, _ resolved: [URL]) throws -> Value {
            if index == urls.count { return try operation(resolved) }
            var error: NSError?, result: Result<Value, Error>?
            coordinator.coordinate(readingItemAt: urls[index], options: [], error: &error) { updated in
                result = Result { try Task.checkCancellation(); return try coordinate(index + 1, resolved + [updated]) }
            }
            if let result { return try result.get() }
            if let error { throw error }
            throw IridiumFilesImport.Failure.sourceChanged
        }
        coordinator.prepare(forReadingItemsAt: urls, options: [], writingItemsAt: [], options: [], error: &coordinationError) { completed in
            defer { completed() }
            result = Result { try Task.checkCancellation(); return try coordinate(0, []) }
        }
        if let result { return try result.get() }
        if let coordinationError { throw coordinationError }
        throw IridiumFilesImport.Failure.sourceChanged
    }
    static func readGame<Value>(_ source: URL, selectedFiles: [URL], operation: (URL, [URL]) throws -> Value) throws -> Value {
        let scopes = selectedFiles.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
        let names = try read([source]) { urls in
            ["gdi", "cue"].contains(source.pathExtension.lowercased())
                ? try IridiumDiscSet(urls[0], selectedFiles: selectedFiles, validateFiles: false).filenames : []
        }
        let inputs = [source] + names.map { source.deletingLastPathComponent().appendingPathComponent($0) }
        return try read(inputs) { urls in
            for (index, name) in names.enumerated() {
                guard urls[index + 1].standardizedFileURL == urls[0].deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
                else { throw IridiumFilesImport.Failure.sourceChanged }
            }
            return try operation(urls[0], urls)
        }
    }
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

/// The consumer flow begins with files. Only containers that cannot identify
/// their system ask a follow-up question; copying stays off the main thread.
struct IridiumGameImportView: View {
    struct Candidate: Identifiable, Sendable {
        let url: URL
        let platforms: [IridiumPlatform]
        var requiresConfirmation = false
        var id: URL { url }
    }
    let source: IridiumImportSource
    let importedConsole: (IridiumConsoleGame) -> Void
    let imported: (LibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [URL] = []
    @State private var candidates: [Candidate] = []
    @State private var warnings: [String] = []
    @State private var choosing: Candidate?
    @State private var windows: IridiumImportSource?
    @State private var busy = true
    @State private var failure: String?
    @State private var choosingFolder = false
    @State private var focus = 0
    @FocusState private var keyboardFocus: Bool
    var body: some View {
        Group {
            if let windows { IridiumFilesImportView(source: windows, imported: imported) }
            else {
                NavigationStack {
                  ScrollViewReader { proxy in
                    List {
                        if busy { ProgressView("Adding game…") }
                        if let failure {
                            Section {
                                Text(failure).foregroundStyle(.secondary)
                                Button("Choose Game Folder") { choosingFolder = true }
                            }
                        } else if let choosing {
                            Section {
                                Text(choosing.url.lastPathComponent).lineLimit(2)
                                ForEach(Array(choosing.platforms.enumerated()), id: \.element.rawValue) { index, platform in
                                    Button(platform.title) { begin(choosing, platform: platform) }
                                        .id(index)
                                        .listRowBackground(focus == index ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
                                }
                            } header: { Text("Which system is this game for?") }
                            if choosing.platforms == [.playStation2] {
                                Text("Only PlayStation 2 discs are supported. PlayStation discs cannot be played.").font(.footnote).foregroundStyle(.secondary)
                            }
                            if choosing.url.pathExtension.lowercased() == "zip" {
                                Section {
                                    Text("For an arcade game, keep the original ZIP name. For a Windows game, extract the archive and choose its folder.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                    Button("Choose Windows Game Folder") { choosingFolder = true }
                                        .id(choosing.platforms.count)
                                        .listRowBackground(focus == choosing.platforms.count ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
                                }
                            }
                        } else if !busy {
                            Section("Choose a game") {
                                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                                    Button(candidate.url.lastPathComponent) { choose(candidate) }
                                        .id(index)
                                        .listRowBackground(focus == index ? Color.white.opacity(0.2) : Color.white.opacity(0.07))
                                }
                            }
                            if !warnings.isEmpty {
                                Section("Other Files") { ForEach(warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) } }
                            }
                        }
                    }.iridiumPageSurface().navigationTitle("Add Game").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
                        .interactiveDismissDisabled(busy)
                        .focusable().focusEffectDisabled().focused($keyboardFocus)
                        .onAppear { keyboardFocus = true }
                        .onKeyPress(.upArrow) { command("up"); return .handled }
                        .onKeyPress(.downArrow) { command("down"); return .handled }
                        .onKeyPress(.return) { command("accept"); return .handled }
                        .onKeyPress(.escape) { command("back"); return .handled }
                        .onReceive(LibraryController.shared.commands, perform: command)
                        .onChange(of: focus) { _, index in proxy.scrollTo(index, anchor: .center) }
                  }
                }
            }
        }
        .task { selection = source.urls; await scan() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): selection = [url]; Task { await scan() }
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription }
            }
        }
    }
    private func scan() async {
        busy = true; failure = nil; choosing = nil; focus = 0
        let urls = selection
        do {
            let values = try await Task.detached(priority: .userInitiated) {
                try IridiumFilesAccess.read(urls) { urls in
                    guard !urls.isEmpty, urls.count <= 256 else { throw IridiumRuntimeError.invalidGame }
                    var files = urls
                    let folder: Bool
                    if urls.count == 1 { folder = try urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
                    else { folder = false }
                    if folder {
                        files = try FileManager.default.contentsOfDirectory(at: urls[0], includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        guard files.count <= 1000 else { throw IridiumRuntimeError.invalidGame }
                    }
                    let supported = IridiumConsoleLibrary.importExtensions
                    var values: [Candidate] = [], warnings: [String] = []
                    var firstFailure: Error?
                    for file in files where supported.contains(file.pathExtension.lowercased()) {
                        do {
                            let detected = try IridiumFilesAccess.readGame(file, selectedFiles: urls) { file, selected in
                                let platforms = try IridiumGameFileDetection.platforms(file, selectedFiles: selected)
                                return (platforms, try IridiumGameFileDetection.needsConfirmation(file, platforms: platforms))
                            }
                            values.append(Candidate(url: file, platforms: detected.0, requiresConfirmation: detected.1))
                        } catch {
                            if firstFailure == nil { firstFailure = error }
                            warnings.append(String(file.lastPathComponent.prefix(128)) + ": " + error.localizedDescription)
                        }
                    }
                    if folder {
                        if files.contains(where: { $0.pathExtension.lowercased() == "exe" }) || (values.isEmpty && firstFailure == nil) {
                            values.append(Candidate(url: urls[0], platforms: [.windows]))
                        }
                    } else if !folder {
                        values += files.filter { $0.pathExtension.lowercased() == "exe" }.map { Candidate(url: $0, platforms: [.windows]) }
                    }
                    guard !values.isEmpty else { throw firstFailure ?? IridiumRuntimeError.invalidGame }
                    return (values.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }, warnings)
                }
            }.value
            guard !Task.isCancelled else { return }
            candidates = values.0; warnings = values.1; busy = false
            if candidates.count == 1 && warnings.isEmpty { choose(candidates[0]) }
        } catch { if !Task.isCancelled { failure = error.localizedDescription; busy = false } }
    }
    private func choose(_ candidate: Candidate) {
        focus = 0
        if candidate.platforms.count == 1, !candidate.requiresConfirmation { begin(candidate, platform: candidate.platforms[0]) }
        else { choosing = candidate }
    }
    private func begin(_ candidate: Candidate, platform: IridiumPlatform) {
        if platform == .windows { windows = IridiumImportSource(url: candidate.url); return }
        guard !IridiumConsoleLibrary.shared.working else { failure = "Another game is being added. Try again when it finishes."; return }
        busy = true; choosing = nil; failure = nil
        IridiumConsoleLibrary.shared.importROM(candidate.url, preferredPlatform: platform, selectedFiles: selection,
            failed: { failure = $0; busy = false }, imported: importedConsole)
    }
    private func command(_ command: String) {
        guard !busy, windows == nil, !choosingFolder else { return }
        if failure != nil {
            if command == "accept" { choosingFolder = true }
            else if command == "back" { dismiss() }
            return
        }
        if command == "back" { if choosing != nil { choosing = nil; focus = 0 } else { dismiss() }; return }
        let archive = choosing?.url.pathExtension.lowercased() == "zip"
        let count = (choosing?.platforms.count ?? candidates.count) + (archive ? 1 : 0)
        if ["up", "left"].contains(command) { focus = max(0, focus - 1) }
        else if ["down", "right"].contains(command) { focus = min(max(0, count - 1), focus + 1) }
        else if command == "accept" {
            if archive, focus == choosing?.platforms.count { choosingFolder = true }
            else if let choosing, choosing.platforms.indices.contains(focus) { begin(choosing, platform: choosing.platforms[focus]) }
            else if candidates.indices.contains(focus) { choose(candidates[focus]) }
        }
    }
}
