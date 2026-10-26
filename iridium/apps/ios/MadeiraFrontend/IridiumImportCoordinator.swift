// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

@MainActor final class IridiumImportCoordinator: ObservableObject {
    static let shared = IridiumImportCoordinator()
    struct Choice: Identifiable {
        let receipt: IridiumImportFiles.Receipt
        let title: String
        let options: [(value: String, title: String)]
        var id: UUID { receipt.id }
    }
    @Published private(set) var isWorking = false
    @Published private(set) var migrationError: String?
    @Published private(set) var choices: [String: Choice] = [:]
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var imported = 0
    @Published private(set) var lastImportedGameID: UUID?
    @Published private(set) var transferringLibrary = false
    private var active = true
    private var incoming: [URL] = []
    private var incomingScopes: [URL] = []
    @Published private(set) var ready = false
    @Published private(set) var remaining: [String] = []
    var blocksLaunch: Bool { !ready || isWorking || transferringLibrary || migrationError != nil }
    var launchMessage: String { migrationError ?? "Wait for the file import to finish, then try again." }
    private let files = IridiumImportFiles(documents: LibraryModel.documents.resolvingSymlinksInPath())
    private var task: Task<Void, Never>?
    private var preparedKey: String?
    private var attempted = Set<String>()
    private var automaticPairingNeedsChoice = false
    private var mayWork: Bool {
        active && !transferringLibrary && LibraryModel.shared.current == nil && !LibraryModel.shared.launching &&
            !IridiumConsoleSession.shared.isActive && !IridiumConsoleSession.shared.dolphinMaintenance &&
            !IridiumConsoleLibrary.shared.working && !JITCoordinator.shared.busy && !OnDevicePairing.shared.active &&
            !SteamOwnedLibrary.shared.downloads.values.contains { $0.state == .active }
    }

    func scan(retry: Bool = false) {
        guard task == nil, mayWork else { return }
        if !incoming.isEmpty { receivePending(); return }
        if retry { attempted.removeAll(); failures.removeAll(); migrationError = nil; preparedKey = nil }
        isWorking = true
        task = Task {
            defer {
                isWorking = false; task = nil
                if !incoming.isEmpty { receivePending() } else { SteamOwnedLibrary.shared.resumeDownloadsAfterImport() }
            }
            do {
                let library = LibraryModel.shared
                let store = IridiumConsoleLibrary.shared.store
                let games = try await files.consoleGames(store)
                let windows = library.entries.filter { $0.desktop != true }
                    .map { ($0.id, $0.relativePath, $0.steamAppID != nil) }
                var titles = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0.title) })
                for entry in library.entries { titles[entry.id] = entry.title }
                let key = windows.map { "\($0.0):\($0.1):\(titles[$0.0] ?? "")" }.joined(separator: "\n") + games.map { "\($0.id):\($0.title)" }.joined()
                if preparedKey != key {
                    isWorking = true
                    do {
                        try await files.prepare(windows: windows, consoles: games.map(\.id), oldConsoleRoot: store.root, titles: titles)
                        preparedKey = key; migrationError = nil; ready = true
                        SteamGamesModel.shared.refresh()
                    } catch is CancellationError { return }
                    catch {
                        migrationError = error.localizedDescription
                        return
                    }
                }
                guard migrationError == nil else { return }
                let roots = try await files.roots(registered: Set(games.map(\.id) + windows.map { $0.0 }))
                let allFiles = try await files.files(LibraryModel.documents.resolvingSymlinksInPath().appendingPathComponent("Import"), validate: false)
                let pairing = allFiles.filter { ["plist", "mobiledevicepairing"].contains($0.pathExtension.lowercased()) }
                automaticPairingNeedsChoice = try await files.pairingNeedsChoice(count: pairing.count)
                for source in roots {
                    guard mayWork, !Task.isCancelled else { break }
                    await process(source, depth: 0, batch: source.lastPathComponent.hasPrefix("From Files-"))
                }
                try await files.removeEmptyStagingFolders()
                remaining = try await files.files(LibraryModel.documents.resolvingSymlinksInPath().appendingPathComponent("Import"), validate: false)
                    .map { String($0.path.dropFirst(LibraryModel.documents.resolvingSymlinksInPath().appendingPathComponent("Import").path.count + 1)) }
                let kept = await files.existing(Array(Set(choices.keys).union(failures.keys)))
                choices = choices.filter { kept.contains($0.key) }
                failures = failures.filter { $0.key == "Import" || kept.contains($0.key) }
                IridiumConsoleLibrary.shared.reload()
                JITCoordinator.shared.refreshPairingStatus()
            } catch is CancellationError { }
            catch { failures["Import"] = error.localizedDescription }
        }
    }

    func beginLibraryTransfer() throws {
        guard !blocksLaunch, task == nil, mayWork else { throw LibraryError.message(launchMessage) }
        transferringLibrary = true
    }
    func endLibraryTransfer() { transferringLibrary = false; storageDidChange() }
    func storageDidChange() { preparedKey = nil; scan() }

    func resume() { active = true; preparedKey = nil; scan() }

    func suspend() {
        active = false
        task?.cancel()
        if !incoming.isEmpty { failures["Import"] = "File selection paused. Choose those files again when Iridium is open." }
        incoming.removeAll()
        incomingScopes.forEach { $0.stopAccessingSecurityScopedResource() }; incomingScopes.removeAll()
    }

    func choose(_ choice: Choice, value: String) {
        guard task == nil, mayWork else { return }
        isWorking = true
        task = Task {
            do { try await files.choose(value, receipt: choice.receipt) }
            catch { failures[choice.receipt.path] = error.localizedDescription }
            isWorking = false; task = nil; scan()
        }
    }

    func receive(_ urls: [URL]) {
        guard !urls.isEmpty, incoming.count + urls.count <= 256 else {
            failures["Import"] = "Choose up to 256 items at a time. Larger batches can go in a folder."; return
        }
        incoming += urls
        incomingScopes += urls.filter { $0.startAccessingSecurityScopedResource() }
        receivePending()
    }

    private func receivePending() {
        guard task == nil, mayWork, !incoming.isEmpty else { return }
        let urls = incoming, scopes = incomingScopes
        incoming.removeAll(); incomingScopes.removeAll()
        isWorking = true
        task = Task {
            defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                try await files.receive(urls)
                failures["Import"] = nil
                isWorking = false; task = nil; scan()
            } catch {
                failures["Import"] = error.localizedDescription
                isWorking = false; task = nil
            }
        }
    }

    private func process(_ source: URL, depth: Int, batch: Bool = false) async {
        guard depth <= 8 else {
            let path = String(source.path.dropFirst(files.storage.inbox.path.count + 1))
            failures[path] = "This folder is nested too deeply."
            return
        }
        var record: IridiumImportFiles.Receipt?
        do {
            let directory = try await files.isDirectory(source)
            let extensions = Set(IridiumConsoleLibrary.importExtensions + ["exe", "plist", "mobiledevicepairing", "zip", "7z"])
            guard directory || extensions.contains(source.pathExtension.lowercased()) else { return }
            let receipt = try await files.receipt(source); record = receipt
            let key = receipt.path + "#" + receipt.fingerprint
            guard !attempted.contains(key) else { return }
            if directory {
                let executables = try await files.executables(source)
                let consoleBatch = try await files.hasConsoleGame(source)
                if !executables.isEmpty && !consoleBatch && (!batch || executables.count == 1 || executables.contains(where: { !$0.contains("/") })) {
                    let selected: String
                    if let choice = receipt.choice, executables.contains(choice) { selected = choice }
                    else if executables.count == 1 { selected = executables[0] }
                    else {
                        var options = executables.map { (value: $0, title: $0) }
                        if !executables.contains(where: { !$0.contains("/") }) { options.insert((value: ":folders", title: "Import each subfolder"), at: 0) }
                        if receipt.choice != ":folders" {
                            choices[receipt.path] = Choice(receipt: receipt, title: "Choose the program to start", options: options)
                            return
                        }
                        for child in try await files.children(source) { await process(child, depth: depth + 1) }
                        return
                    }
                    try await windows(source.appendingPathComponent(selected), folder: source, receipt: receipt)
                } else {
                    for child in try await files.children(source) { await process(child, depth: depth + 1) }
                    return
                }
            } else if ["plist", "mobiledevicepairing"].contains(source.pathExtension.lowercased()) {
                let all = try await files.files(files.storage.inbox, validate: false)
                let count = all.filter { ["plist", "mobiledevicepairing"].contains($0.pathExtension.lowercased()) }.count
                automaticPairingNeedsChoice = try await files.pairingNeedsChoice(count: count)
                if automaticPairingNeedsChoice && receipt.choice != ":pairing" {
                    choices[receipt.path] = Choice(receipt: receipt, title: "More than one pairing file is present",
                        options: [(value: ":pairing", title: "Use this pairing file")])
                    return
                }
                isWorking = true
                let data = try await files.pairing(source)
                guard !JITCoordinator.shared.busy, !OnDevicePairing.shared.active else { return }
                try JITPairingFileStore.store(data, source: .imported)
                try await files.consume(source, receipt: receipt)
                imported += 1
            } else if ["zip", "7z"].contains(source.pathExtension.lowercased()), receipt.choice != IridiumPlatform.arcade.rawValue {
                isWorking = true
                let folder = try await files.expand(source, receipt: receipt)
                let before = imported
                await process(folder, depth: depth + 1, batch: true)
                let refreshed = try await files.receipt(source)
                let paths = await files.existing(Array(Set(choices.keys).union(failures.keys)))
                let pending = paths.contains { $0 == folder.lastPathComponent || $0.hasPrefix(folder.lastPathComponent + "/") }
                if (imported > before || refreshed.importedPayload == true) && !pending { try await files.consume(source, receipt: receipt) }
                else if imported == before && refreshed.importedPayload != true && !pending && source.pathExtension.lowercased() == "zip" {
                    choices[receipt.path] = Choice(receipt: receipt, title: "No loose game files found. Is this an arcade ROM set?",
                        options: [(value: IridiumPlatform.arcade.rawValue, title: "Import as arcade set")])
                }
                else if imported == before && refreshed.importedPayload != true && !pending {
                    failures[receipt.path] = "No supported game or pairing files were found. The archive stays in Import."
                    attempted.insert(key)
                }
                return
            } else if source.pathExtension.lowercased() == "exe" {
                try await windows(source, folder: nil, receipt: receipt)
            } else if IridiumConsoleLibrary.importExtensions.contains(source.pathExtension.lowercased()) {
                let siblings = try await files.children(source.deletingLastPathComponent())
                let detected = try await files.detection(source, siblings: siblings)
                let platform: IridiumPlatform
                if let choice = receipt.choice.flatMap(IridiumPlatform.init(rawValue:)), detected.0.contains(choice) { platform = choice }
                else if detected.0.count == 1 && !detected.1 { platform = detected.0[0] }
                else {
                    choices[receipt.path] = Choice(receipt: receipt, title: "Choose the game system",
                        options: detected.0.map { (value: $0.rawValue, title: $0.title) })
                    return
                }
                isWorking = true
                let tracks = try await files.discFiles(source, siblings: siblings)
                var trackReceipts: [(URL, IridiumImportFiles.Receipt)] = []
                for track in tracks { trackReceipts.append((track, try await files.receipt(track))) }
                _ = try await files.importConsole(source, receipt: receipt, platform: platform, siblings: siblings, store: IridiumConsoleLibrary.shared.store)
                if platform == .arcade { try await files.discardUnchangedExpansion(receipt) }
                try await files.consume(source, receipt: receipt)
                for (track, ticket) in trackReceipts { try await files.consumeTrack(track, receipt: ticket) }
                imported += 1; lastImportedGameID = receipt.id
            } else { return } // Sidecars and unknown files remain in the inbox.
            attempted.insert(key); choices[receipt.path] = nil; failures[receipt.path] = nil
        } catch is CancellationError { }
        catch {
            let path = record?.path ?? source.lastPathComponent
            failures[path] = error.localizedDescription
            if let record { attempted.insert(record.path + "#" + record.fingerprint) }
        }
    }

    private func windows(_ executable: URL, folder: URL?, receipt: IridiumImportFiles.Receipt) async throws {
        isWorking = true
        let model = LibraryModel.shared
        let result = try await files.importWindows(executable, folder: folder, receipt: receipt)
        if let existing = model.entries.first(where: { $0.id == receipt.id }) {
            guard existing.relativePath == result.relativePath else { throw IridiumGameStorage.Failure.unsafePath }
        } else {
            let entry = LibraryEntry(id: receipt.id, title: folder?.lastPathComponent ?? result.title,
                relativePath: result.relativePath, bits: result.bits)
            model.save(entry)
            guard model.entries.contains(where: { $0.id == receipt.id }) else {
                throw IridiumImportFailure.message("The library could not be saved. The original files stay in Import.")
            }
        }
        try await files.consume(folder ?? executable, receipt: receipt)
        imported += 1; lastImportedGameID = receipt.id
    }
}
