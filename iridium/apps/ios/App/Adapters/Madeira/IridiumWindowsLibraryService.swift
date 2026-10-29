import SwiftUI
import Combine
import UniformTypeIdentifiers
import ImageIO

final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var drive: URL { documents.appendingPathComponent("wine/drive_c", isDirectory: true).resolvingSymlinksInPath() }
    @Published var enabled = false
    @Published var entries: [LibraryEntry] = []
    @Published var current: UUID?
    @Published var activeEntry: LibraryEntry?
    @Published var menu = false
    @Published var performance = false
    @Published var liveLogs = false
    @Published var fpsMode = 1
    /// The session's controller mode (LibraryEntry.controllerMode): "keys" or nil.
    @Published var controllerMode: String? {
        didSet { if oldValue != controllerMode { applyControllerMode() } }
    }
    /// The session's binds table (LibraryEntry.controllerBinds); a change rebuilds
    /// the driver's bindings at once, so the binds page is live.
    @Published var controllerBinds: [String: ControlAction] = [:] {
        didSet { if oldValue != controllerBinds { applyControllerMode() } }
    }
    /// The session's right-stick mouse vertical speed (LibraryEntry.padMouseVertical).
    @Published var padMouseVertical: Double = 1 {
        didSet { if oldValue != padMouseVertical { applyControllerMode() } }
    }
    /// The session's touch-control opacity (the entry's Control opacity).
    @Published var opacity = 0.7
    /// The session's Aspect & scaling; MetalBackedView lays the game out with it.
    @Published var displayMode = DisplayMode.fit {
        didSet { if displayMode != oldValue { MetalBackedView.refreshDisplayMode(reason: "mode-toggle") } }
    }
    @Published var error: String? { didSet { if error != nil { preparing = nil } } }
    @Published var sessionMessage = ""
    @Published var launching = false
    @Published var overlayFields = ["FPS", "Frame time", "RAM", "Battery"]
    private var launchPresent: UInt64 = 0
    private var launchSurface: UInt64 = 0
    private var launchStarted = Date()
    /// Read by the starting screen for its elapsed-time line.
    var launchStartedAt: Date { launchStarted }
    @Published var launchSlow = false
    @Published var launchLogs = false
    private var launchDismissLogged = false
    var menuButtonRect = CGRect.zero
    var performanceRect = CGRect.zero
    /// The in-game menu and the starting screen take every touch.
    var blocksGameplayTouch: Bool { preparing != nil || (current != nil && (menu || launching)) }
    private var timer: Timer?
    private var sawProcess = false
    // Why a session ended by itself (not Quit): the program the app launched
    // exited with a Windows error (wine_crash_exit_status, WineProcessBridge.m).
    // MADEIRA_EXIT_REPORT=0 returns to the library without a message.
    private(set) var quitRequested = false
    private func exitReport() -> String? {
        guard !quitRequested, MadeiraConfig.flag("MADEIRA_EXIT_REPORT") else { return nil }
        var status: UInt32 = 0
        guard wine_crash_exit_status(&status) != 0 else { return nil }
        LogStore.shared.log("[exit-report] status=0x\(String(status, radix: 16))")
        let kind = status == 0xC0000005 ? " (memory access violation)" : status == 0xC0000017 ? " (out of memory)" : ""
        return "The game stopped with Windows error 0x\(String(status, radix: 16, uppercase: true))\(kind). Export the diagnostic log to report it."
    }
    private var readOnly = false
    private var metadataInFlight = Set<UUID>()
    private var steamMetadataInFlight = Set<Int>()
    private var iridiumWindowsControlsBaseline: IridiumControlLayoutState?
    private var savedControls: [TouchControl] = []
    private var savedLayout: String?
    private var savedZones: [GestureZone] = []
    private var savedVisible = true
    private var savedSize = 1.0
    /// The session's first frame makes the drawable's shape known (Aspect).
    private var laidOutAfterFirstPresent = false
    private struct Document: Codable { var version: Int; var entries: [LibraryEntry]; var hiddenSteamApps: [Int]? = nil }
    @Published private(set) var hiddenSteamApps: Set<Int> = []
    private var file: URL { Self.documents.appendingPathComponent("madeira-library.json") }

    private init() {
        refreshFlag()
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let doc = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
                guard doc.version == 1 else { throw LibraryError.message("This library uses a newer format.") }
                hiddenSteamApps = Set(doc.hiddenSteamApps ?? [])
                entries = doc.entries
            } catch {
                readOnly = true
                self.error = "Library could not be opened. The original file was preserved. " + error.localizedDescription
            }
        }
        resetPhoneResolution()
        applyRecommendations()
    }

    /// madeira-bcd: games already in the library get Madeira's recommended settings
    /// when they are due (GameRecommendationsApply.swift); the entries' own fields
    /// are saved here.
    private func applyRecommendations() {
        guard !readOnly else { return }
        var next = entries
        var changed = false
        for i in next.indices {
            if GameRecommendations.prepare(&next[i]) { changed = true }
        }
        if changed { persist(next) }
    }

    /// ml1172: every new entry used to get 1408x648, a 19.5:9 phone's shape.
    /// On a screen of another shape (an iPad: a third of it black in Fit)
    /// those entries are reset once to this device's default. Nothing tells a
    /// deliberate 1408x648 from the old default, so a game set to it on purpose
    /// is reset too; on a 19.5:9 iPhone nothing changes.
    private func resetPhoneResolution() {
        let key = "madeira.ml1172.resolution-reset"
        guard !readOnly, !UserDefaults.standard.bool(forKey: key) else { return }
        let phone = "1408x648"
        let reset = ResolutionChoices.fills(1408, 648) ? 0 : entries.filter { $0.resolution == phone }.count
        if reset > 0 {
            var next = entries
            for i in next.indices where next[i].resolution == phone { next[i].resolution = ResolutionChoices.defaultValue }
            guard persist(next) else { return }   // try again at the next start
        }
        UserDefaults.standard.set(true, forKey: key)
        LogStore.shared.log("[library] ml1172 resolution default \(ResolutionChoices.defaultValue); \(reset) entries reset from \(phone)")
    }

    func refreshFlag() {
        guard current == nil, !IridiumMadeiraRuntime.shared.isBusy else { return }
        // Fixed for the whole run (FrontendChoice); a change applies at the next start.
        let allowed = FrontendChoice.startup.useNew
        if enabled != allowed { fputs("[frontend] library enabled=\(allowed ? 1 : 0)\n", stderr) }
        enabled = allowed
        LibraryController.shared.configure(enabled: allowed, ownsInput: allowed)
    }

    func save(_ entry: LibraryEntry) {
        guard !readOnly else { error = "The library file could not be read. Preserve or repair it before making changes."; return }
        guard entry.steamAppID.map({ !hiddenSteamApps.contains($0) }) ?? true else { return }
        var next = entries
        var entry = entry
        // madeira-bcd: a game seen for the first time gets Madeira's recommended settings
        // (GameRecommendationsApply.swift): a finished Steam download, a new or saved entry.
        let isNew = !next.contains { $0.id == entry.id || (entry.steamAppID != nil && $0.steamAppID == entry.steamAppID) }
        GameRecommendations.prepare(&entry, new: isNew)
        // A Steam game has one entry: a details page opened before its card first saved
        // one (refreshSteamMetadata) updates that entry.
        if let i = next.firstIndex(where: { $0.id == entry.id }) ??
            next.firstIndex(where: { entry.steamAppID != nil && $0.steamAppID == entry.steamAppID }) {
            // A details sheet may predate an asynchronous metadata refresh.
            if (next[i].metadataChecked ?? .distantPast) > (entry.metadataChecked ?? .distantPast) {
                entry.folderBytes = next[i].folderBytes; entry.graphicsAPI = next[i].graphicsAPI
                entry.bits = next[i].bits; entry.steamMetadataInstall = next[i].steamMetadataInstall
                entry.metadataChecked = next[i].metadataChecked
                entry.metadataRevision = next[i].metadataRevision
            }
            next[i] = entry
        } else { next.append(entry) }
        persist(next)
    }
    func remove(_ id: UUID) {
        if let appID = entries.first(where: { $0.id == id })?.steamAppID {
            persist(entries, hiddenSteamApps: hiddenSteamApps.union([appID]))
        } else { persist(entries.filter { $0.id != id }) }
    }
    /// A Steam game's library entry, which holds its per-game settings
    /// (SteamGames.swift). A game without one gets a new entry made from what
    /// Steam installed; it is saved when its details page closes or it is
    /// played. An existing entry follows the install folder Steam records.
    func steamEntry(_ game: DockGame, title: String? = nil) -> LibraryEntry {
        let folder = game.library + "/common/" + game.installDir
        if var entry = entries.first(where: { $0.steamAppID == game.id }) {
            entry.relativePath = folder
            return entry
        }
        var entry = LibraryEntry(title: title ?? game.name, relativePath: folder, bits: 0)
        entry.steamAppID = game.id
        entry.folderBytes = SteamInstallFiles.sizeOnDisk(appID: game.id, steamApps: Self.drive.appendingPathComponent(game.library, isDirectory: true))
        return entry
    }
    /// A Steam download finished (SteamOwnedLibrary): the game gets its library
    /// entry, or an existing one keeps its title, artwork and settings.
    func upsertSteam(_ game: DockGame, title: String) {
        guard !readOnly else { return }
        if hiddenSteamApps.contains(game.id), !persist(entries, hiddenSteamApps: hiddenSteamApps.subtracting([game.id])) { return }
        var entry = steamEntry(game, title: title)
        entry.folderBytes = SteamInstallFiles.sizeOnDisk(appID: game.id, steamApps: Self.drive.appendingPathComponent(game.library, isDirectory: true)) ?? entry.folderBytes
        save(entry)
    }
    /// Keep settings and identity for a reinstall, while hiding the removed install.
    @discardableResult func removeSteam(appID: Int) -> Bool {
        hideSteam([appID])
    }
    @discardableResult func hideSteam(_ appIDs: Set<Int>) -> Bool {
        guard !appIDs.isSubset(of: hiddenSteamApps) else { return true }
        return persist(entries, hiddenSteamApps: hiddenSteamApps.union(appIDs))
    }

    @MainActor func steamInstall(_ entry: LibraryEntry) -> DockGame? {
        guard let appID = entry.steamAppID, MadeiraDock.validAppID(appID) else { return nil }
        guard !SteamGamesModel.shared.sharedOnlyApps.contains(appID) else { return nil }
        if let game = SteamGamesModel.shared.games.first(where: { $0.id == appID }) { return game }
        let prefix = SteamInstallPaths.libraryRelative + "/common/"
        guard entry.relativePath.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let folder = String(entry.relativePath.dropFirst(prefix.count))
        guard MadeiraDock.validFolderName(folder) else { return nil }
        return DockGame(id: appID, name: entry.title, installDir: folder, library: SteamInstallPaths.libraryRelative,
                        installed: false, customExecutables: false, filesMissing: true)
    }
    @discardableResult
    private func persist(_ next: [LibraryEntry], hiddenSteamApps: Set<Int>? = nil) -> Bool {
        guard !readOnly else { return false }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let hidden = hiddenSteamApps ?? self.hiddenSteamApps
            try encoder.encode(Document(version: 1, entries: next, hiddenSteamApps: hidden.isEmpty ? nil : hidden.sorted())).write(to: file, options: .atomic)
            self.hiddenSteamApps = hidden
            entries = next
            return true
        } catch { self.error = "Could not save the library: " + error.localizedDescription; return false }
    }

    /// Install size and graphics API, at most once a day per entry.
    @MainActor
    func refreshMetadata(_ id: UUID) async {
        let revision = 12
        guard !metadataInFlight.contains(id), let entry = entries.first(where: { $0.id == id }), entry.desktop != true,
              entry.metadataRevision != revision || Date().timeIntervalSince(entry.metadataChecked ?? .distantPast) > 86400,
              let url = try? Self.executable(entry.relativePath) else { return }
        metadataInFlight.insert(id)
        defer { metadataInFlight.remove(id) }
        let result = await LibraryMetadataScanner.shared.scan(url, drive: Self.drive)
        guard !Task.isCancelled, var updated = entries.first(where: { $0.id == id }) else { return }
        updated.folderBytes = result.bytes
        if let api = result.api { updated.graphicsAPI = api }
        updated.metadataChecked = Date(); updated.metadataRevision = revision; save(updated)
        fputs("[library-metadata] install scan api=\(updated.graphicsAPI ?? "unknown") bytes=\(result.bytes ?? -1)\n", stderr)
    }

    /// An installed Steam game's library pills (SteamGames.swift): 32-bit or 64-bit and
    /// the graphics API of the program "Start with: The game" would start
    /// (SteamDirectStart.program), and the install size from Steam's install record.
    /// Read off the main thread once per install folder, build and picked program
    /// (again when Steam's launch configuration arrives, or after a day while no
    /// program is known) and kept on the game's entry.
    @MainActor
    func refreshSteamMetadata(_ game: DockGame, title: String) async {
        let revision = 1
        guard !hiddenSteamApps.contains(game.id), game.sharedOnly != true else { return }
        guard !readOnly, game.installed, !steamMetadataInFlight.contains(game.id) else { return }
        steamMetadataInFlight.insert(game.id)
        defer { steamMetadataInFlight.remove(game.id) }
        let drive = Self.drive
        let folder = game.library + "/common/" + game.installDir
        let root = drive.appendingPathComponent(folder, isDirectory: true)
        let steamApps = drive.appendingPathComponent(game.library, isDirectory: true)
        let record = await Task.detached(priority: .utility) {
            (build: SteamInstallFiles.buildID(appID: game.id, steamApps: steamApps),
             size: SteamInstallFiles.sizeOnDisk(appID: game.id, steamApps: steamApps))
        }.value
        let stored = entries.first { $0.steamAppID == game.id }
        let picked = stored?.steamProgramSource == "choice" ? stored?.steamProgram : nil
        let known = SteamOwnedLibrary.shared.game(game.id)?.launches != nil
        let install = "\(folder)#\(record.build ?? 0)#\(picked ?? "")#\(known ? 1 : 0)"
        if let stored, stored.steamMetadataInstall == install, stored.metadataRevision == revision,
           stored.bits != 0 || Date().timeIntervalSince(stored.metadataChecked ?? .distantPast) < 86400 { return }
        // Steam's launch configuration is asked for only when no picked program is installed.
        let kept = await Task.detached(priority: .utility) { picked.flatMap { SteamDirectStart.onDisk($0, in: root, directory: false) } }.value
        let options = kept == nil ? await SteamOwnedLibrary.shared.launchOptions(appID: game.id) : nil
        let program = await Task.detached(priority: .utility) { () -> (url: URL, bits: Int, api: String?)? in
            guard let path = SteamDirectStart.program(picked: kept, options: options, installFolder: root),
                  let inspected = try? LibraryModel.inspect(root.appendingPathComponent(path)) else { return nil }
            return (root.appendingPathComponent(path), inspected.bits, inspected.graphicsAPI)
        }.value
        var api = program?.api
        if let program, let scanned = await LibraryMetadataScanner.shared.scan(program.url, drive: drive, countBytes: false).api { api = scanned }
        guard !Task.isCancelled, !hiddenSteamApps.contains(game.id) else { return }
        var updated = entries.first { $0.steamAppID == game.id } ?? LibraryEntry(title: title, relativePath: folder, bits: 0)
        updated.steamAppID = game.id
        updated.relativePath = folder
        updated.bits = program?.bits ?? 0
        updated.graphicsAPI = api
        updated.folderBytes = record.size ?? updated.folderBytes
        updated.steamMetadataInstall = install
        updated.metadataChecked = Date(); updated.metadataRevision = revision
        save(updated)
        LogStore.shared.log("[steam-games] metadata app=\(game.id) bits=\(updated.bits) api=\(api ?? "unknown")")
    }

    /// What an entry can start: an executable, or (ml1163) a batch file run through cmd.exe.
    static let programExtensions: Set<String> = ["exe", "bat", "cmd"]
    static func executable(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") }) else {
            throw LibraryError.message("The executable path is not valid.")
        }
        let url = drive.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard IridiumGameStorage.windowsRelative(url, drive: drive) != nil, programExtensions.contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.message("Choose an executable (.exe, .bat or .cmd) in Iridium’s game storage.")
        }
        return url
    }
    static func inspect(_ url: URL) throws -> LibraryEntry {
        guard let relative = IridiumGameStorage.windowsRelative(url, drive: drive) else {
            throw LibraryError.message("The executable must be in Iridium’s game storage.")
        }
        if ["bat", "cmd"].contains(url.pathExtension.lowercased()) {
            // ml1163: a batch file has no PE header. Like every entry it starts
            // directly by default, as upstream starts every game; the details page
            // warns that Wine then stops when cmd.exe, its first process, exits.
            return LibraryEntry(title: url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " "),
                                relativePath: relative, bits: 0)
        }
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        let dos = try h.read(upToCount: 64) ?? Data()
        guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { throw LibraryError.message("This is not a Windows executable.") }
        let offset = (0..<4).reduce(UInt64(0)) { $0 | (UInt64(dos[60 + $1]) << ($1 * 8)) }
        guard offset >= 64, offset < 16 * 1024 * 1024 else { throw LibraryError.message("Invalid executable header.") }
        try h.seek(toOffset: offset)
        let pe = try h.read(upToCount: 6) ?? Data()
        guard pe.count == 6, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { throw LibraryError.message("Missing PE header.") }
        let machine = Int(pe[4]) | Int(pe[5]) << 8
        guard machine == 0x14c || machine == 0x8664 else { throw LibraryError.message("Only x86 and x64 executables are supported.") }
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        var entry = LibraryEntry(title: name, relativePath: relative, bits: machine == 0x14c ? 32 : 64)
        entry.graphicsAPI = graphicsImports(url)
        return entry
    }

    // Read the PE import directory, rather than guessing from the executable's name.
    static func apiNames(_ imports: [String]) -> Set<String> {
        var levels = Set<String>()
        for name in imports {
            switch name {
            case "ddraw.dll": levels.insert("DirectDraw")
            case "d3d8.dll": levels.insert("D3D8")
            case "d3d9.dll": levels.insert("D3D9")
            case "d3d10.dll", "d3d10_1.dll": levels.insert("D3D10")
            case "d3d11.dll": levels.insert("D3D11")
            case "d3d12.dll": levels.insert("D3D12")
            case "opengl32.dll": levels.insert("OpenGL")
            case "vulkan-1.dll": levels.insert("Vulkan")
            default: break
            }
        }
        return levels
    }
    static func graphicsImports(_ url: URL) -> String? {
        let levels = apiNames(importNames(url))
        return levels.isEmpty ? nil : levels.sorted().joined(separator: " / ")
    }
    static func importNames(_ url: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data {
            do { try h.seek(toOffset: offset); return try h.read(upToCount: count) ?? Data() } catch { return Data() }
        }
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { return 0 }
            return (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        let dos = read(0, 64); guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { return [] }
        let base = UInt64(u32(dos, 60)); guard base < 16 * 1024 * 1024 else { return [] }
        let header = read(base, 264); guard header.count == 264, u32(header, 0) == 0x4550 else { return [] }
        let sections = Int(header[6]) | Int(header[7]) << 8
        let optSize = Int(header[20]) | Int(header[21]) << 8
        guard sections <= 96, optSize >= 120 else { return [] }
        let pe64 = header[24] == 0x0b && header[25] == 2
        guard header[24] == 0x0b, header[25] == 1 || pe64 else { return [] }
        let imports = u32(header, pe64 ? 144 : 128)
        let delayed = optSize >= (pe64 ? 224 : 208) ? u32(header, pe64 ? 240 : 224) : 0
        let table = read(base + 24 + UInt64(optSize), sections * 40)
        func fileOffset(_ rva: UInt32) -> UInt64? {
            guard table.count == sections * 40 else { return nil }
            for index in 0..<sections {
                let i = index * 40, va = u32(table, index * 40 + 12), size = u32(table, index * 40 + 16)
                if rva >= va, rva - va < size { return UInt64(u32(table, i + 20)) + UInt64(rva - va) }
            }
            return nil
        }
        var names: [String] = []
        for (rva, stride, nameField) in [(imports, 20, 12), (delayed, 32, 4)] {
            guard rva != 0, let start = fileOffset(rva) else { continue }
            for i in 0..<256 {
                let descriptor = read(start + UInt64(i * stride), stride)
                guard descriptor.count == stride else { break }
                var nameRVA = u32(descriptor, nameField); if nameRVA == 0 { break }
                if stride == 32 && u32(descriptor, 0) & 1 == 0 {
                    let imageBase = u32(header, 52)
                    guard !pe64, nameRVA >= imageBase else { continue }
                    nameRVA -= imageBase
                }
                guard let offset = fileOffset(nameRVA) else { continue }
                let data = read(offset, 128)
                let name = String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self).lowercased()
                names.append(name)
            }
        }
        return names
    }

    // MARK: session

    /// Initialize the embedded Windows host once. Game jobs reuse that host;
    /// a failed native initialization still retains admission.
    static var sessionsThisRun = 0
    private static var nativeInitializationStarted = false
    private(set) var nativeLaunchID = UUID()
    static let restartMessage = "Windows could not finish the session safely. Close and reopen Iridium."
    @MainActor static func reserveNativeSession() -> Bool {
        guard !nativeInitializationStarted else { return false }
        nativeInitializationStarted = true
        sessionsThisRun = 1
        return true
    }
    @MainActor func launchFailedBeforeNative(_ owner: UUID, reason: String? = nil, offerJIT: Bool = false) {
        guard nativeLaunchID == owner else { return }
        guard !Self.nativeInitializationStarted else { launchFailed(Self.restartMessage); return }
        JITCoordinator.shared.releaseAttachedDebugger { clean in
            guard self.nativeLaunchID == owner, !Self.nativeInitializationStarted else { return }
            guard clean else { self.launchFailed(Self.restartMessage); return }
            Self.sessionsThisRun = 0
            self.launchFailed(reason, offerJIT: offerJIT)
        }
    }
    @Published var restartNotice: String? { didSet { if restartNotice != nil { preparing = nil } } }
    /// CS_DEBUGGED is set but no debugger is attached (JIT was enabled outside
    /// Madeira): the text of the alert that offers Madeira's own Enable JIT.
    @Published var jitNotice: String? { didSet { if jitNotice != nil { preparing = nil } } }
    /// Play is enabling JIT before starting this entry (ContentView.jitReadyForLaunch):
    /// its Play button reads Starting JIT, with a spinner, until JIT is on or fails.
    @Published var startingJIT: UUID?
    /// A Play still enabling JIT or getting its start ready: the starting screen is up
    /// for it before the session begins (LibraryHUD), so the press goes straight to it.
    @Published var preparing: LibraryEntry?
    private var preparingSince = Date()
    /// The starting screen is up: a session starting, or a Play getting ready.
    var startingScreen: Bool { launching || preparing != nil }
    var startingEntry: LibraryEntry? { launching ? activeEntry : preparing }
    /// When the starting screen went up, for its elapsed-time line.
    var startingSince: Date { launching ? launchStarted : preparingSince }
    func prepare(_ entry: LibraryEntry) {
        guard current == nil else { return }
        preparingSince = Date(); preparing = entry
        // The starting screen draws in the controls window (LibraryHUD), which otherwise
        // only comes up with the session's game view.
        TouchControlsHost.attach()
    }
    /// A Steam game's saves may not be the latest (SteamOwnedLibrary.cloudHold):
    /// the alert Play shows before starting it.
    struct CloudNotice: Equatable {
        enum Kind { case syncing, unchecked, conflict }
        var appID: Int
        var kind: Kind
        var title: String
        var message: String
    }
    @Published var cloudNotice: CloudNotice? { didSet { if cloudNotice != nil { preparing = nil } } }
    /// Starts the game the notice is about again.
    var cloudRetry: (() -> Void)?
    /// The game (App ID) allowed to start once without the check ("Launch anyway").
    var cloudBypass: Int?
    /// The entry whose details page the library should open (the notice's "Choose").
    @Published var showDetail: UUID?

    /// `remember: false` runs a session that is not a library entry (a Madeira
    /// Dock start): it is neither added to the library nor stamped as played.
    /// `dock`: the game a Madeira Dock start launches (DockStartScreen).
    func begin(_ entry: LibraryEntry, remember: Bool = true, dock: DockGame? = nil) {
        GestureZonesModel.shared.flush()
        wine_exit_status_reset()
        quitRequested = false
        LibraryController.shared.configure(enabled: enabled, ownsInput: false)
        nativeLaunchID = UUID()
        Self.sessionsThisRun += 1
        launchPresent = madeira_get_present_count(); launchStarted = Date(); launchSlow = false; launchLogs = entry.liveLogs
        launchSurface = winios_surface_present_count()
        MetalBackedView.presentCountAtLaunch = launchPresent; laidOutAfterFirstPresent = false
        preparing = nil; launching = true; overlayFields = entry.overlayFields ?? ["FPS", "Frame time", "RAM", "Battery"]
        displayMode = entry.displayMode
        MainActor.assumeIsolated { IridiumGameAudio.shared.begin(entry.id) }
        activeEntry = entry; current = entry.id; menu = false; performance = entry.performance; liveLogs = entry.liveLogs
        LogStore.shared.setDisplayActive(entry.liveLogs)
        fpsMode = entry.fpsMode; sessionMessage = "Starting…"
        opacity = min(max(entry.controlOpacity ?? 0.7, 0.15), 1)
        let controls = TouchControlsModel.shared
        savedControls = controls.controls; savedVisible = controls.visible; savedSize = controls.sizeScale
        savedLayout = controls.layoutID
        let zones = GestureZonesModel.shared
        savedZones = zones.zones
        if let profile = entry.controls {
            controls.controls = profile
            // A game saved before zones existed takes its layout's zones, if any.
            zones.selected = nil
            zones.zones = entry.zones
                ?? ControlPresetsModel.shared.store.preset(entry.controlLayout ?? "").map(ControlPresetStore.zones(of:))
                ?? []
            // The game's controls come with the layout they were loaded from (if that
            // layout still exists), so a later edit is not written to another game's.
            if ControlPresetsModel.enabled {
                controls.layoutID = ControlPresetsModel.shared.store.resolvedID(entry.controlLayout)
            }
        }
        controls.visible = entry.touchControls
        controls.sizeScale = min(max(entry.controlSize ?? 1, 0.5), 2)
        iridiumWindowsControlsBaseline = nil
        let profileStore = IridiumControlProfileStore.shared
        let selected = profileStore.document.games[entry.id.uuidString] != nil ||
            (entry.controls == nil && entry.controlLayout == nil && profileStore.hasSelection(platform: .windows, gameID: nil))
        if selected {
            let fallback = IridiumControlLayoutState(controls: savedControls, visible: savedVisible, size: savedSize,
                opacity: entry.controlOpacity ?? 0.7, zones: savedZones)
            do {
                let value = try profileStore.resolve(platform: .windows, gameID: entry.id, builtIn: fallback)
                controls.controls = value.controls; controls.visible = value.visible; controls.sizeScale = value.size
                zones.zones = value.zones ?? []
                controls.layoutID = nil; opacity = value.opacity ?? 0.7
                iridiumWindowsControlsBaseline = IridiumControlLayoutState(controls: controls.controls, visible: controls.visible,
                    size: controls.sizeScale, opacity: opacity, zones: zones.zones)
            } catch { self.error = error.localizedDescription }
        }
        controllerBinds = GamepadInput.keyboardMouseAvailable ? (entry.controllerBinds ?? [:]) : [:]
        padMouseVertical = GamepadInput.keyboardMouseAvailable ? (entry.padMouseVertical ?? 1) : 1
        controllerMode = GamepadInput.keyboardMouseAvailable ? entry.controllerMode : nil
        applyControllerMode()
        MetalHostView.shared.isHidden = false
        ProMotionIntent.apply(mode: entry.effectiveFPSMode)
        ThermalPacing.shared.begin()
        if remember { var played = entry; played.lastPlayed = Date(); save(played) }
        launchDismissLogged = false
        DockStartScreen.shared.begin(dock, at: launchStarted)
        sawProcess = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }
    @MainActor private func poll() {
        if IridiumMadeiraRuntime.shared.isResident {
            let owner = nativeLaunchID
            IridiumMadeiraRuntime.shared.poll(owner) { event in
                guard self.nativeLaunchID == owner, self.current != nil else { return }
                switch event {
                case .starting: break
                case .running:
                    self.sawProcess = true
                    if self.sessionMessage == "Starting…" { self.sessionMessage = "" }
                case .ended(let status):
                    self.finish()
                    if status != 0 && !self.quitRequested { self.error = "The Windows game ended with code \(status)." }
                case .blocked(let message):
                    self.timer?.invalidate(); self.timer = nil
                    self.launching = false; self.error = message
                }
            }
        }
        let dockStart = DockStartScreen.shared
        if dockStart.active {
            // A Dock start: the desktop's own frames (explorer, the host's console window)
            // do not end this starting screen; the game's window does (DockStartScreen).
            dockStart.poll(self, rendered: madeira_get_present_count() >= launchPresent + 3)
        }
        if dockStart.holding {
            if launching && !launchSlow && Date().timeIntervalSince(launchStarted) > 30 { launchSlow = true }
        } else if launching {
            if madeira_get_present_count() >= launchPresent + 3 {
                showGameView(reason: "present")
            } else if winios_surface_present_count() > launchSurface {
                showGameView(reason: "surface")
            } else if Date().timeIntervalSince(launchStarted) > 30 { launchSlow = true }
        }
        if !IridiumMadeiraRuntime.shared.isResident, wine_process_is_running() != 0 {
            sawProcess = true
            if sessionMessage == "Starting…" { sessionMessage = "" }
        } else if !IridiumMadeiraRuntime.shared.isResident, sawProcess && wineserver_is_running() == 0 { finish() }
        // The first frame gives Aspect and Fill height the drawable's shape.
        if current != nil, !laidOutAfterFirstPresent, madeira_get_present_count() != MetalBackedView.presentCountAtLaunch {
            laidOutAfterFirstPresent = true
            MetalBackedView.refreshDisplayMode(reason: "first-present")
        }
    }
    /// `reason`: what stopped the launch, when the caller knows (the JIT pool's failure).
    /// `offerJIT`: the launch failed because no debugger is attached, so the alert
    /// offers Enable JIT instead of only reporting.
    func launchFailed(_ reason: String? = nil, offerJIT: Bool = false) {
        guard current != nil && !sawProcess else { return }
        finish()
        if offerJIT, let reason { jitNotice = reason }
        else { error = reason ?? "The session could not start. Check the diagnostic log and JIT status." }
    }
    /// Both flags change in one transaction without animation: the animated
    /// removal of a scrolling view with live content could leave the starting
    /// screen up (and unresponsive) while the game was already presenting.
    func showGameView(reason: String = "button") {
        if launching && !launchDismissLogged {
            launchDismissLogged = true
            fputs("[launch-view] dismissed reason=\(reason) logs=\(launchLogs ? 1 : 0)\n", stderr)
        }
        LogStore.shared.setDisplayActive(liveLogs)
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { launchLogs = false; launching = false }
    }
    func toggleLaunchLogs() {
        launchLogs.toggle()
        LogStore.shared.setDisplayActive(launching ? launchLogs : liveLogs)
        fputs("[startup-log] visible=\(launchLogs ? 1 : 0)\n", stderr)
    }

    /// Hand the session's mode to the pad sampler. In keyboard-and-mouse mode the
    /// bindings follow the touch layout on screen, so they are rebuilt when the
    /// controls change (TouchControlsModel.controls, observed below).
    func applyControllerMode() {
        guard GamepadInput.keyboardMouseAvailable else { return }
        if current != nil, controllerMode == "keys" {
            GamepadInput.shared.setKeyboardMouse(PadBindings.build(controls: TouchControlsModel.shared.controls, binds: controllerBinds, mouseVertical: padMouseVertical))
            if controlsSink == nil {
                controlsSink = TouchControlsModel.shared.$controls.sink { [weak self] controls in
                    guard let self, self.controllerMode == "keys", self.current != nil else { return }
                    GamepadInput.shared.setKeyboardMouse(PadBindings.build(controls: controls, binds: self.controllerBinds, mouseVertical: self.padMouseVertical))
                }
            }
        } else {
            controlsSink = nil
            GamepadInput.shared.setKeyboardMouse(nil)
        }
    }
    private var controlsSink: AnyCancellable?

    func setFPS(_ mode: Int) {
        fpsMode = mode
        ThermalPacing.shared.userChose()
        let applied = ProMotionIntent.supportedMode(mode)
        madeira_set_vsync_locked(applied)
        ProMotionIntent.apply(mode: applied)
        saveCurrentProfile()
    }
    func showMenu() {
        LibraryKeyboard.hide()
        LibraryController.shared.configure(enabled: enabled, ownsInput: true)
        menu = true
    }
    func requestQuit() {
        LibraryKeyboard.hide()
        if quitRequested, IridiumMadeiraRuntime.shared.isResident {
            IridiumMadeiraRuntime.shared.requestStop(nativeLaunchID)
            sessionMessage = "Ending the remaining game processes…"
            menu = false
            return
        }
        quitRequested = true
        if !sawProcess { IridiumMadeiraRuntime.shared.requestStop(nativeLaunchID) }
        let closingOwner = nativeLaunchID
        // Ask the application to close (Alt+F4) through the normal input queue,
        // so it can save; the surface stays up until the native session ends.
        winios_post_key(0x12, 1); winios_post_key(0x73, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard self.nativeLaunchID == closingOwner, self.current != nil else { return }
            winios_post_key(0x73, 0); winios_post_key(0x12, 0)
        }
        sessionMessage = "Confirm the exit in the game. Close again to end remaining processes."
        menu = false
        fputs("[frontend] graceful close requested\n", stderr)
    }
    func saveCurrentProfile() {
        let controls = TouchControlsModel.shared
        if let id = current, var entry = entries.first(where: { $0.id == id }) {
            entry.zones = GestureZonesModel.shared.zones
            if let baseline = iridiumWindowsControlsBaseline {
                let value = IridiumControlLayoutState(controls: controls.controls, visible: controls.visible,
                    size: controls.sizeScale, opacity: opacity, zones: GestureZonesModel.shared.zones)
                if value != baseline {
                    do { try IridiumControlProfileStore.shared.set(.init(layout: value), platform: .windows, gameID: id) }
                    catch { self.error = error.localizedDescription; return }
                }
            } else {
                entry.controls = controls.controls
                if ControlPresetsModel.enabled { entry.controlLayout = controls.layoutID }
                entry.touchControls = controls.visible
                entry.controlOpacity = opacity; entry.controlSize = controls.sizeScale
            }
            entry.fpsMode = fpsMode; entry.performance = performance
            entry.overlayFields = overlayFields
            if GamepadInput.keyboardMouseAvailable { entry.controllerMode = controllerMode }
            if GamepadInput.keyboardMouseAvailable { entry.controllerBinds = controllerBinds.isEmpty ? nil : controllerBinds }
            if GamepadInput.keyboardMouseAvailable { entry.padMouseVertical = padMouseVertical == 1 ? nil : padMouseVertical }
            // The in-game Aspect & scaling choice sticks to the game. MADEIRA_SESSION_TOOLS=0
            // hides that picker and leaves the stored choice alone.
            if MadeiraConfig.flag("MADEIRA_SESSION_TOOLS") { entry.display = displayMode.rawValue }
            save(entry)
        }
    }
    private func finish() {
        if sawProcess, let report = exitReport() { error = report }
        timer?.invalidate(); timer = nil
        saveCurrentProfile()
        controllerMode = nil
        controllerBinds = [:]
        padMouseVertical = 1
        let controls = TouchControlsModel.shared
        controls.editing = false; controls.selected = nil
        controls.controls = savedControls; controls.visible = savedVisible; controls.sizeScale = savedSize
        GestureZonesModel.shared.selected = nil; GestureZonesModel.shared.zones = savedZones
        if ControlPresetsModel.enabled { controls.layoutID = savedLayout }
        iridiumWindowsControlsBaseline = nil
        current = nil; activeEntry = nil; menu = false; sessionMessage = ""
        displayMode = .fit
        LogStore.shared.setDisplayActive(true)
        launching = false; launchLogs = false; LibraryKeyboard.hide()
        DockStartScreen.shared.finish()
        LibraryController.shared.configure(enabled: enabled, ownsInput: enabled)
        MetalHostView.shared.isHidden = true
        ProMotionIntent.shared.setActive(false)
        ThermalPacing.shared.end()
        fputs("[frontend] returned to library\n", stderr)
    }
}

enum LibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

// Serialized off the main actor. Cancellation follows the card's SwiftUI task,
// so entering a session stops directory work instead of competing with it.
private actor LibraryMetadataScanner {
    static let shared = LibraryMetadataScanner()
    // Dynamic imports do not appear in the PE import table. Look only for
    // terminated DLL names in bounded reads; these indicate supported APIs,
    // not which backend an application selects at runtime.
    private func dynamicAPIs(_ file: URL, budget: inout Int) -> Set<String> {
        guard budget > 0, let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let signature = try? handle.read(upToCount: 2), signature == Data([0x4d, 0x5a]) else { return [] }
        let length = (try? handle.seekToEnd()) ?? 0
        let window = min(budget, 4 * 1024 * 1024)
        var result = Set<String>()
        let names = ["ddraw.dll", "d3d8.dll", "d3d9.dll", "d3d10.dll", "d3d10_1.dll", "d3d11.dll", "d3d12.dll", "opengl32.dll", "vulkan-1.dll"]
        for offset in [UInt64(0), length > UInt64(window) ? length - UInt64(window) : 0] {
            guard budget > 0, !Task.isCancelled else { break }
            try? handle.seek(toOffset: offset)
            guard let bytes = try? handle.read(upToCount: min(window, budget)) else { break }
            budget -= bytes.count
            let folded = Data(bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 })
            for name in names {
                let ascii = Data((name + "\0").utf8)
                let wide = Data((name + "\0").utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
                if folded.range(of: ascii) != nil || folded.range(of: wide) != nil {
                    result.formUnion(LibraryModel.apiNames([name]))
                }
            }
            if length <= UInt64(window) { break }
        }
        return result
    }
    /// `countBytes: false` skips the size walk (a Steam game's size is its install record's).
    func scan(_ executable: URL, drive: URL, countBytes: Bool = true) -> (bytes: Int64?, api: String?) {
        let folder = executable.deletingLastPathComponent()
        guard IridiumGameStorage.windowsRelative(folder, drive: drive) != nil, !Task.isCancelled else { return (nil, nil) }
        let manager = FileManager.default
        // Executables commonly live below the installation root. Only ascend
        // conventional binary directories, never an arbitrary library parent.
        var installation = folder
        let binaryFolders: Set<String> = ["bin", "binaries", "win32", "win64", "x86", "x64", "release"]
        for _ in 0..<4 {
            guard binaryFolders.contains(installation.lastPathComponent.lowercased()) else { break }
            let parent = installation.deletingLastPathComponent()
            guard IridiumGameStorage.windowsRelative(parent, drive: drive) != nil,
                  !["program files", "program files (x86)", "games", "common", "steamapps"].contains(parent.lastPathComponent.lowercased()) else { break }
            installation = parent
        }
        var complete = true
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let walker = countBytes ? manager.enumerator(at: installation, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in complete = false; return true }) : nil
        var bytes: Int64 = 0
        var files = 0
        while let file = walker?.nextObject() as? URL {
            if Task.isCancelled { return (nil, nil) }
            files += 1
            if files > 200_000 { complete = false; break }
            guard let values = try? file.resourceValues(forKeys: keys) else { complete = false; continue }
            if values.isSymbolicLink == true { walker?.skipDescendants(); continue }
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        // Engines often import graphics through a local DLL. Follow only their
        // actual import graph, case-insensitively, never every DLL in drive_c.
        let siblings = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var local: [String: URL] = [:]
        for file in siblings where file.pathExtension.lowercased() == "dll" {
            if IridiumGameStorage.windowsRelative(file, drive: drive) != nil { local[file.lastPathComponent.lowercased()] = file }
        }
        var budget = 32 * 1024 * 1024
        var pending = [executable], visited = Set<String>(), apis = Set<String>()
        // A launcher may start a sibling executable rather than import its engine.
        // Restrict fallback to the same installation directory and a small count.
        if LibraryModel.graphicsImports(executable) == nil {
            pending.insert(contentsOf: siblings.filter {
                $0.pathExtension.lowercased() == "exe" && $0 != executable &&
                IridiumGameStorage.windowsRelative($0, drive: drive) != nil
            }.sorted { $0.path < $1.path }.prefix(8), at: 0)
        }
        while let file = pending.popLast(), visited.count < 64, !Task.isCancelled {
            if !visited.insert(file.path).inserted { continue }
            let imports = LibraryModel.importNames(file)
            apis.formUnion(LibraryModel.apiNames(imports))
            apis.formUnion(dynamicAPIs(file, budget: &budget))
            for name in imports { if let dependency = local[name], !visited.contains(dependency.path) { pending.append(dependency) } }
        }
        return (complete && walker != nil ? bytes : nil, apis.isEmpty ? nil : apis.sorted().joined(separator: "/"))
    }
}

enum LibraryRendererBadge {
    static let apis = ["D3D12", "D3D11", "D3D10", "D3D9", "D3D8", "Vulkan", "OpenGL", "DirectDraw"]

    /// The badge names an API only when the game's files name exactly one. The
    /// scan finds every renderer a game ships, not the one it runs: an engine
    /// with D3D9 and D3D10 renderers would otherwise be labelled D3D10.
    static func compact(_ detected: String?) -> String? {
        guard let detected else { return nil }
        // "D3D10/D3D9" from the metadata scan, "D3D10 / D3D9" from inspect.
        let values = Set(detected.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) })
        let known = apis.filter(values.contains)
        if known.count == 1 { return known[0] }
        return known.isEmpty && !detected.contains("/") ? detected : nil   // e.g. "Wine desktop"
    }
}

/// "Madeira" as a large title at the leading edge of the navigation bar, on the
/// row of the toolbar buttons (the system large title would sit on a row of its
/// own below them), in the large title font, with no Liquid Glass capsule
/// behind it on iOS 26. LibraryHeaderAlignment lines its first letter up with
/// the search field below.
