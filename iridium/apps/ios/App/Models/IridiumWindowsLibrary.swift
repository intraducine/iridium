import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Darwin
import ImageIO
import Combine

// IRIDIUM-OWNED-UNIT
/// One game in the library and its launch profile, stored in
/// Documents/madeira-library.json (version 1). New fields must be optional so
/// older files keep decoding; unknown keys are ignored.
struct LibraryEntry: Codable, Identifiable {
    var id = UUID()
    var title: String
    /// The executable, relative to drive_c ("Games/Foo/foo.exe").
    var relativePath: String
    /// 32 or 64 from the PE header, 0 when unknown.
    var bits: Int
    /// A user-chosen cover in Documents/madeira-art/.
    var coverFile: String?
    /// The Steam store app this game was matched to (Game details › Find on
    /// Steam). Only its public artwork is used: the library cover and the
    /// starting screen's background, when no cover file is chosen.
    var steamID: Int?
    var arguments = ""
    /// The virtual monitor's size ("WxH"): the session default a game renders
    /// for (GuestDisplay.configureSessionDefault), and the Desktop entry's
    /// desktop size. ml1172: new entries default to this screen's shape at
    /// 1280x720's pixel count (ResolutionChoices: 1408x648 on a 19.5:9 iPhone,
    /// as before, and 1152x800 on an 11-inch iPad, where a fixed 1408x648 left bars).
    var resolution = ResolutionChoices.defaultValue
    /// How the monitor is scaled to the screen (DisplayMode raw value; nil = Fit).
    var display: String?
    /// FPS limit: 1 = 60, 3 = 30, 4 = 40, 0 = display maximum, 2 = uncapped (madeira_set_vsync_locked).
    var fpsMode = 1
    /// FEX's X87ReducedPrecision for this game: true exports 1 (reduced, fast).
    /// false leaves the engine's default unless `fullX87` asks for full precision:
    /// the 32-bit (WOW64) module runs reduced by default (ml950: full precision
    /// cost Fallout: New Vegas 20-50 % of its CPU and about half its frame rate),
    /// the 64-bit one full. Saved entries all carry false, so "false" has to mean
    /// the engine's default, not "full": exporting 0 for it (upstream #461) put
    /// every 32-bit game on the slow path.
    var reducedX87 = false
    /// Full 80-bit x87 for this game (exports 0), chosen on the Compatibility page;
    /// nil = the engine's default. Ignored when reducedX87 is on.
    var fullX87: Bool?

    /// The Compatibility page's x87 choice over reducedX87 and fullX87.
    enum X87Precision: String, CaseIterable { case automatic, reduced, full }
    var x87Precision: X87Precision {
        get { reducedX87 ? .reduced : (fullX87 == true ? .full : .automatic) }
        set {
            reducedX87 = newValue == .reduced
            fullX87 = newValue == .full ? true : nil
        }
    }
    var liveLogs = false
    var performance = false
    var touchControls = false
    var controls: [TouchControl]?
    /// The named layout (TouchControlPresets.swift) `controls` came from, so the
    /// Session menu shows it and an edit is written back to it; nil for controls
    /// no layout holds. Older files have none.
    var controlLayout: String?
    /// The game's gesture zones (GestureZones.swift), kept with its controls. Older files have none.
    var zones: [GestureZone]?
    var lastPlayed: Date?
    var graphicsAPI: String?
    var folderBytes: Int64?
    var metadataChecked: Date?
    var metadataRevision: Int?
    var overlayFields: [String]?
    /// The Wine desktop (explorer and services in a virtual desktop).
    var desktop: Bool?
    /// ml2021: Valve's client in Big Picture, inside the Wine desktop (the library's
    /// Big Picture button; C:\big-picture.bat, written at every launch).
    var bigPicture: Bool?
    /// Touch controls' opacity (0.15...1, nil = 0.7) and overall size (0.5...2,
    /// nil = 1) in this game's sessions.
    var controlOpacity: Double?
    var controlSize: Double?
    // ml1163: how a game starts. All optional, so older library files decode and
    // entries that never set them start as before.
    /// "desktop": the program runs inside the Wine desktop, as explorer.exe's
    /// first child (explorer.exe /desktop=shell,<resolution> "<exe>" args), so
    /// every window shows. nil or "direct": the program is Wine's first process,
    /// with no desktop; only its small windows (launchers, message boxes) are
    /// drawn over the game.
    var launchMode: String?
    /// The working directory, a C:\ path (exported as MADEIRA_WORKDIR); nil or
    /// empty = the program's own folder (Steam's for "The game").
    var workingDirectory: String?
    /// Start services.exe (the SCM, and through it rpcss: out-of-process COM,
    /// which Steam-style launchers need) before the program, from a generated
    /// C:\madeira-games\<id>.bat (servicesScript).
    var startServices: Bool?
    /// How a physical controller reaches this game: nil, the game's own support
    /// (XInput, as before); "dinput", XInput and a DirectInput joystick of the same
    /// pad (for games older than XInput; a game reading both APIs sees two
    /// controllers); "keys", keyboard and mouse (PadKeyboardMouse: the pad
    /// presses keys and moves the mouse, the game sees no controller). For games
    /// without controller support. Optional, so older files decode.
    var controllerMode: String?
    /// Keyboard-and-mouse mode: what each controller input does in this game
    /// (PadBindings.buttonNames plus "LS"/"RS" → key, mouse button, key stick or
    /// .none), on top of the layout's bindings and the built-in template. Only
    /// inputs the player changed are stored. Optional, so older files decode.
    var controllerBinds: [String: ControlAction]?
    /// Keyboard-and-mouse mode: vertical speed of the right-stick mouse relative
    /// to horizontal (PadBindings.mouseVertical); nil = 1.
    var padMouseVertical: Double?
    /// Gyro aim and turbo for player 1 (PadAssist.swift); nil = both off.
    /// Optional, so older files decode.
    var padAssist: PadAssistSettings?
    /// Processors reported to Windows code in this game's sessions
    /// (MADEIRA_CPU_COUNT, ntdll); nil = automatic.
    var cpuCount: Int?
    /// D3D9 anisotropic filtering limit (DXMT_D9_ANISO_LIMIT: 1, 2, 4 or 8);
    /// nil = the application's own choice.
    var anisotropyLimit: Int?
    /// "Report an NVIDIA GPU": DXGI names NVIDIA as the vendor (GeForce RTX
    /// 3060, 10DE:2544), DXMT's NVAPI answers, and win32u registers the same
    /// display adapter, for games that refuse a GPU without a known vendor's
    /// driver. nil = off.
    var reportNVIDIA: Bool?
    /// A Steam game (SteamGames.swift): Madeira Dock starts it by this App ID
    /// through Valve's client, with Steam's default launch option.
    /// `relativePath` is then its install folder, relative to drive_c.
    var steamAppID: Int?
    /// How a Steam game starts (Game details › Steam › Start with): nil is Madeira
    /// Dock, the default; "game" is the game's own program in Wine, without Steam
    /// (SteamDirectStart).
    var steamStart: String?
    /// "The game": the program, relative to the install folder ("bin/game.exe"), its
    /// arguments, and its working folder (relative to the install folder; nil: the
    /// program's own folder, "": the install folder), from Steam's launch configuration
    /// for the app ("steam"), the Program picker ("choice") or the folder's only
    /// program ("only").
    var steamProgram: String?
    var steamProgramArguments: String?
    var steamProgramFolder: String?
    var steamProgramSource: String?
    /// The install folder, build and picked program a Steam game's `bits` and
    /// `graphicsAPI` were read for, and whether Steam's launch configuration was
    /// cached (LibraryModel.refreshSteamMetadata); any change reads them again.
    var steamMetadataInstall: String?
    /// An itch.io game (ItchLibrary.swift): its game id. `relativePath` is then its
    /// program inside C:\itch.
    var itchGameID: Int?
    /// An Epic Games game (EpicLibrary.swift): its app name. `relativePath` is then
    /// its program inside C:\Program Files\Epic Games, and each start adds Epic's
    /// sign-in arguments (EpicLibrary.launchArguments) for that launch only.
    var epicAppName: String?
    /// An EA app game (EALibrary.swift): its offer id. `relativePath` is then its
    /// program inside C:\Program Files\EA Games, and each start first gets the game's
    /// licence, the EA app's environment and Madeira's stand-in for the EA app's
    /// local service (EALibrary.prepareLaunch).
    var eaOfferID: String?
    /// An Epic game with an official way to start without anti-cheat
    /// (epicAntiCheatOffProgram): nil or true starts that program.
    /// The anti-cheat cannot run in Wine on iOS, so on is the default.
    var epicAntiCheatOff: Bool?
    /// Games with an official way to start without Easy Anti-Cheat (offline modes
    /// only), as the program to start instead of the one Epic names. Rocket League:
    /// its Launcher.exe with -noeac ("No Easy Anti Cheat") starts RocketLeague.exe
    /// with Epic's arguments and nothing else. Madeira starts that program itself,
    /// which leaves out the launcher's .NET runtime: it crashed in Wine Mono once
    /// the game had quit, so the session never ended cleanly.
    static let epicAntiCheatOffProgram: [String: String] = ["Sugar": "RocketLeague.exe"]
    /// Fastsync's per-game switches, used only while Settings › Sync engine is
    /// Fastsync: "Fast synchronization" (nil = on; off gives this game Wine's
    /// standard sync) and "Fast semaphore waits" (nil = off). Optional, so older
    /// library files decode; the fork's files carry the same keys.
    var fastSync: Bool?
    var semaphoreFastPath: Bool?
    /// This game's own lines in madeira.cfg's syntax (Game details › This game's
    /// config). At launch a key set here wins over madeira.cfg, env.NAME lines are
    /// exported after madeira.cfg's and dxmt options are added to its own
    /// (MadeiraConfig.applyGame). nil: none.
    var config: String?
    /// AVX and AVX2 for this game (FEX's 128-bit AVX emulation, MADEIRA_FEX_AVX);
    /// nil = off, FEX's iOS default.
    var avx: Bool?
    /// Experimental MetalFX frame interpolation between the game's frames
    /// (DXMT's present path, MADEIRA_FRAMEGEN); nil = off.
    var frameGeneration: Bool?
    /// MetalFX spatial upscaling factor (Display › MetalFX upscaling: 1.5 or 2;
    /// nil = off), passed on as this game's `metalfx-upscale` line.
    var metalFXUpscale: Double?
    /// ml1298: a reservation of 64 GB or more that the address space cannot hold
    /// is served with a real 16 GB part (ntdll's ios_oversize_reserve), passed on
    /// as this game's `oversize-reserve` line; nil = off, such a reservation fails.
    var largeReservations: Bool?

    /// What MadeiraConfig.applyGame writes for this game: the lines its pickers
    /// stand for, then its own config, which wins where both set a key.
    var gameConfigText: String? {
        var lines: [String] = []
        if let metalFXUpscale { lines.append("metalfx-upscale = \(metalFXUpscale)") }
        if largeReservations == true { lines.append("oversize-reserve = 1") }
        if let config, !config.isEmpty { lines.append(config) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var displayMode: DisplayMode { display.flatMap(DisplayMode.init(rawValue:)) ?? .fit }

    var launchArguments: String {
        if desktop == true { return "/desktop=shell,\(resolution) C:\\windows\\system32\\services.exe" }
        return launchCommand.args
    }

    /// ml1163: a .bat or .cmd target runs through cmd.exe. For "The game" (a Steam
    /// game started as its own program) the target is that program.
    var isBatch: Bool {
        let path = launchRelativePath.lowercased()
        return path.hasSuffix(".bat") || path.hasSuffix(".cmd")
    }
    /// ml1163's launch options apply to what the library starts itself: a game you
    /// added, or a Steam game's "The game". A Steam game started through Madeira
    /// Dock has Dock's own desktop and command (ContentView.startDock).
    var usesLaunchOptions: Bool { desktop != true && (steamAppID == nil || startsSteamGameDirectly) }
    /// ml1163: a game (not the Desktop entry) started inside the Wine desktop.
    var runsInDesktop: Bool { usesLaunchOptions && launchMode == "desktop" }
    /// The program's own arguments: Steam's launch configuration for "The game",
    /// else the entry's Launch arguments; an Epic game's sign-in arguments come first
    /// while its launch is being prepared.
    var programArguments: String {
        let own = startsSteamGameDirectly ? (steamProgramArguments ?? "") : arguments
        guard epicAppName != nil, let transient = Self.transientArguments(for: id), !transient.isEmpty else { return own }
        return own.isEmpty ? transient : transient + " " + own
    }
    /// Arguments for the launch being prepared only (an Epic game's one-use sign-in
    /// code): never part of the saved entry. ContentView sets them before the launch;
    /// applyEnvironment clears them once the bridge's command is exported.
    private static let transientLock = NSLock()
    private static var transient: [UUID: String] = [:]
    static func setTransientArguments(_ arguments: String?, for id: UUID) {
        transientLock.lock(); defer { transientLock.unlock() }
        transient[id] = arguments
    }
    static func transientArguments(for id: UUID) -> String? {
        transientLock.lock(); defer { transientLock.unlock() }
        return transient[id]
    }
    /// ml1163: the directory the program starts in (MADEIRA_WORKDIR): the chosen
    /// working folder, else Steam's for "The game", else the program's own folder.
    /// A desktop-mode game inherits explorer's directory and a .bat runs as
    /// cmd.exe, whose own folder is system32, so configureLaunch exports it
    /// whenever what starts lives elsewhere.
    var launchDirectory: String {
        let chosen = (workingDirectory ?? "").trimmingCharacters(in: .whitespaces)
        if !chosen.isEmpty { return chosen }
        return steamWorkingWindowsPath ?? Self.folder(of: launchWindowsPath)
    }
    /// C:\a\b\x.exe -> C:\a\b (C:\ for a file in the root).
    static func folder(of windowsPath: String) -> String {
        guard let i = windowsPath.lastIndex(of: "\\") else { return "C:\\" }
        let dir = String(windowsPath[..<i])
        return dir.count <= 2 ? dir + "\\" : dir
    }
    /// drive_c on the host. LibraryModel.drive is the same folder; this struct
    /// stands alone so the host tests can compile it.
    static var hostDrive: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wine/drive_c", isDirectory: true)
    }
    /// C:\a\b -> <prefix>/drive_c/a/b; nil for another drive or a ".." element.
    static func hostURL(ofWindowsPath path: String) -> URL? {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard p.count >= 3, p.prefix(3).uppercased() == "C:\\" else { return nil }
        let parts = p.dropFirst(3).split(separator: "\\").map(String.init)
        guard !parts.contains("..") else { return nil }
        return parts.reduce(hostDrive) { $0.appendingPathComponent($1) }
    }
    /// ml1163: where startServices writes its batch file, one per entry.
    var servicesScriptPath: String { "C:\\madeira-games\\\(id.uuidString).bat" }
    /// ml1163: the services batch, CRLF. services.exe is STARTed; then a .bat is
    /// CALLed so it runs in this console, and an exe is STARTed so cmd exits and
    /// its console closes straight away (the pattern of Steam's batch). nil
    /// unless startServices.
    var servicesScript: String? {
        guard usesLaunchOptions, startServices == true else { return nil }
        func quoted(_ s: String) -> String { "\"\(s)\"" }
        // Text put into the batch keeps one line each (a line break in the arguments
        // or the title would start another command), and its '%' is doubled once per
        // expansion: cmd expands '%' in a batch file, so C:\Games\100% Juice became
        // C:\Games\100 Juice and "%~" in a title was a syntax error that stopped the
        // whole batch; CALL expands its line a second time.
        func batchText(_ s: String, expansions: Int = 1) -> String {
            var text = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            for _ in 0..<expansions { text = text.replacingOccurrences(of: "%", with: "%%") }
            return text
        }
        let expansions = isBatch ? 2 : 1   // the program's line: CALL for a .bat
        let extra = batchText(programArguments.trimmingCharacters(in: .whitespaces), expansions: expansions)
        let target = quoted(batchText(launchWindowsPath, expansions: expansions))
        let run = isBatch ? "call \(target)" : "start \"\" \(target)"
        return [
            "@echo off",
            "rem Generated by Madeira (ml1163) for \(batchText(title)); rewritten at every launch.",
            "start \"\" \"C:\\windows\\system32\\services.exe\"",
            "cd /d \(quoted(batchText(launchDirectory)))",
            extra.isEmpty ? run : run + " " + extra,
        ].joined(separator: "\r\n") + "\r\n"
    }

    /// ml1163: what a game starts (the Desktop entry keeps its own command
    /// above). MADEIRA_ARGS goes through
    /// WineProcessBridge's quote-aware tokenizer; Wine re-quotes an argument
    /// with spaces.
    ///   Wine desktop: explorer.exe /desktop=shell,WxH "<exe>" args, or cmd /c "x.bat" args
    ///   direct:       the exe with its arguments, or cmd.exe /c "x.bat" args
    /// With startServices the target is the services batch, which carries the
    /// arguments itself. The exe is launchWindowsPath: "The game"'s program for
    /// a Steam game started as its own program.
    var launchCommand: (exe: String, args: String) { launchCommand(parent: nil) }
    func launchCommand(parent: String?) -> (exe: String, args: String) {
        func quoted(_ s: String) -> String { "\"\(s)\"" }
        var path = launchWindowsPath
        var extra = programArguments.trimmingCharacters(in: .whitespaces)
        var batch = isBatch
        if servicesScript != nil { path = servicesScriptPath; extra = ""; batch = true }
        func withExtra(_ s: String) -> String { extra.isEmpty ? s : s + " " + extra }
        let parent = batch ? nil : parent
        if runsInDesktop {
            let program = parent.map { quoted($0) + " " + quoted(path) } ?? quoted(path)
            return ("explorer.exe", "/desktop=shell,\(resolution) " + withExtra(batch ? "cmd /c \(quoted(path))" : program))
        }
        if batch { return ("C:\\windows\\system32\\cmd.exe", withExtra("/c \(quoted(path))")) }
        if let parent { return (parent, withExtra(quoted(path))) }
        return (path, programArguments)   // upstream's direct launch, arguments verbatim
    }
    /// ml2320: an Epic game's x64 program starts as the child of a process with the Epic client's
    /// name (build/epic-parent), as it does under the Epic client on Windows. A publisher's launcher
    /// that did not find that process treated the Epic copy as not owned and offered it for sale.
    /// nil for any other entry, a batch, a 32-bit program, a build without the program, or with
    /// env.MADEIRA_EPIC_LAUNCHER_PARENT=0.
    var epicParent: String? {
        guard epicAppName != nil, !isBatch, servicesScript == nil,
              MadeiraConfig.get("env.MADEIRA_EPIC_LAUNCHER_PARENT") != "0",
              Bundle.main.url(forResource: "EpicGamesLauncher", withExtension: "exe", subdirectory: "arm64ec-windows") != nil,
              let url = Self.hostURL(ofWindowsPath: launchWindowsPath), Self.peMachine(url) == 0x8664 else { return nil }
        return "C:\\windows\\system32\\EpicGamesLauncher.exe"
    }
    /// The PE machine of an executable (0x14c: 32-bit x86, 0x8664: x64), nil when unreadable.
    static func peMachine(_ url: URL) -> Int? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let dos = try? h.read(upToCount: 64), dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { return nil }
        let offset = (0..<4).reduce(UInt64(0)) { $0 | (UInt64(dos[60 + $1]) << ($1 * 8)) }
        guard offset >= 64, offset < 16 * 1024 * 1024, (try? h.seek(toOffset: offset)) != nil,
              let pe = try? h.read(upToCount: 6), pe.count == 6, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { return nil }
        return Int(pe[4]) | Int(pe[5]) << 8
    }
    /// The details page's "command that runs" line: the program's file name and
    /// its arguments, as upstream shows a direct start; ml1163: what starts it
    /// otherwise (explorer.exe or cmd.exe with its whole command), and with the
    /// services batch also what that batch starts.
    var commandPreview: String {
        func name(_ path: String) -> String { path.split(separator: "\\").last.map(String.init) ?? path }
        let command = launchCommand
        let program = ([name(launchWindowsPath)] + (programArguments.isEmpty ? [] : [programArguments])).joined(separator: " ")
        if command.exe == launchWindowsPath { return program }
        let line = name(command.exe) + " " + command.args
        return servicesScript == nil ? line : line + "\n(the batch starts services.exe, then " + program + ")"
    }

    /// A Steam game that starts as its own program ("Start with: The game").
    var startsSteamGameDirectly: Bool { steamAppID != nil && steamStart == "game" }
    /// What a launch starts, relative to drive_c: "The game"'s program inside the
    /// install folder, else `relativePath`.
    var launchRelativePath: String {
        if let app = epicAppName, epicAntiCheatOff != false, let program = Self.epicAntiCheatOffProgram[app] {
            // The program next to the one Epic names (Rocket League: Launcher.exe -> RocketLeague.exe).
            let folder = relativePath.split(separator: "/").dropLast().joined(separator: "/")
            return folder.isEmpty ? program : folder + "/" + program
        }
        guard startsSteamGameDirectly, let program = steamProgram, !program.isEmpty else { return relativePath }
        return relativePath + "/" + program
    }
    var launchWindowsPath: String { "C:\\" + launchRelativePath.replacingOccurrences(of: "/", with: "\\") }
    /// "The game"'s working folder as a Windows path, or nil for the program's own folder.
    var steamWorkingWindowsPath: String? {
        guard startsSteamGameDirectly, let folder = steamProgramFolder else { return nil }
        return "C:\\" + (folder.isEmpty ? relativePath : relativePath + "/" + folder).replacingOccurrences(of: "/", with: "\\")
    }

    static let desktopID = UUID(uuidString: "AF046C35-C32A-497B-92BC-0BBD14F8CB61")!
    static var desktopEntry: LibraryEntry {
        var entry = LibraryEntry(title: "Desktop", relativePath: "windows/system32/explorer.exe", bits: 64)
        entry.id = desktopID; entry.desktop = true; entry.graphicsAPI = "Wine desktop"
        return entry
    }

    // MARK: ml2021 Big Picture

    static let bigPictureID = UUID(uuidString: "5A0B2C44-9C1E-4D0F-8F2A-7B3E6D1C9A10")!
    /// Valve's client in Big Picture (its gamepad UI) inside the Wine desktop, as a
    /// desktop-mode batch: C:\big-picture.bat starts services.exe and then steam.exe
    /// -bigpicture with the Chromium switches the Steam test launch proved
    /// (ContentView.prepareSteamLaunch). Its recommended list (GameRecommendations
    /// .steamBigPicture) carries the launcher-chain memory lines a 64-bit Chromium
    /// host needs and the swap tier with the donor pool.
    static var bigPictureEntry: LibraryEntry {
        var entry = LibraryEntry(title: "Big Picture", relativePath: "big-picture.bat", bits: 64)
        entry.id = bigPictureID; entry.bigPicture = true; entry.graphicsAPI = "Steam"; entry.launchMode = "desktop"
        return entry
    }
    /// Madeira Dock's Steam folder inside the prefix (Windows path, Unix path), when its
    /// steam.exe is there. Its component set is PINNED (SteamRuntime: steamclient64.dll must be
    /// the build the Dock host supports), so the client UI must never run from it: steam.exe
    /// would complete the install from Valve's CDN and replace the pinned build.
    static var dockSteamFolder: (windows: String, unix: String)? {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let prefix = documents.appendingPathComponent("wine").path
        let candidates = [
            ("C:\\Program Files (x86)\\Steam", "\(prefix)/drive_c/Program Files (x86)/Steam"),
            ("C:\\Program Files\\Steam", "\(prefix)/drive_c/Program Files/Steam"),
        ]
        return candidates.first { fm.fileExists(atPath: "\($0.1)/steam.exe") }
    }
    /// Big Picture's own Steam folder: Valve's client completes itself there on the first
    /// run (steam.exe is Valve's bootstrapper: it fetches the client's packages, the web
    /// helper included, from Valve's CDN into its own folder), leaving the Dock's pinned
    /// install alone.
    static var bigPictureFolder: (windows: String, unix: String)? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let prefix = documents.appendingPathComponent("wine").path
        return ("C:\\Program Files\\Steam Big Picture", "\(prefix)/drive_c/Program Files/Steam Big Picture")
    }
    /// Big Picture is unfinished: the button beside Desktop and a Big Picture card in the library
    /// exist only in a build compiled with the Swift condition MADEIRA_BIG_PICTURE_UI (for example
    /// xcodebuild SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) MADEIRA_BIG_PICTURE_UI').
    /// No IPA build sets it, so release IPAs have neither; the launch code is compiled either way.
#if MADEIRA_BIG_PICTURE_UI
    static let bigPictureShown = true
#else
    static let bigPictureShown = false
#endif
    /// Whether the library lists this entry: a Big Picture entry only while Big Picture is shown.
    var listedInLibrary: Bool { bigPicture != true || Self.bigPictureShown }
    /// The button is offered when Big Picture's folder has a client, or the Dock's steam.exe
    /// can seed one.
    static var steamClientInstalled: Bool {
        let fm = FileManager.default
        if let bp = bigPictureFolder, fm.fileExists(atPath: "\(bp.unix)/steam.exe") { return true }
        return dockSteamFolder != nil
    }
    /// Writes C:\big-picture.bat for this launch, seeding Big Picture's folder with the
    /// Dock's steam.exe when it has none yet. False, having logged why, when there is no client.
    @discardableResult
    static func writeBigPictureBatch() -> Bool {
        let fm = FileManager.default
        guard let folder = bigPictureFolder,
              let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        if !fm.fileExists(atPath: "\(folder.unix)/steam.exe") {
            guard let dock = dockSteamFolder else {
                LogStore.shared.log("[big-picture] no Steam client to start from: prepare Madeira Dock's Steam components first", level: .error)
                return false
            }
            do {
                try fm.createDirectory(atPath: folder.unix, withIntermediateDirectories: true)
                try fm.copyItem(atPath: "\(dock.unix)/steam.exe", toPath: "\(folder.unix)/steam.exe")
                LogStore.shared.log("[big-picture] seeded \(folder.windows) with the Dock's steam.exe; Valve's client completes itself there on this first run (a download from Valve's CDN)")
            } catch {
                LogStore.shared.log("[big-picture] could not seed \(folder.windows): \(error.localizedDescription)", level: .error)
                return false
            }
        }
        // ml2210: once the 32-bit client and its web helper (bin/cef/cef.win7) are in place,
        // the bootstrapper neither updates itself nor the client, so a later run cannot move
        // it to the 64-bit client, whose CEF pools do not fit the address space.
        // env.MADEIRA_BIG_PICTURE_PIN = 0 lets it update as before.
        let pinned = MadeiraConfig.flag("MADEIRA_BIG_PICTURE_PIN", fallback: true)
            && fm.fileExists(atPath: "\(folder.unix)/bin/cef/cef.win7/steamwebhelper.exe")
        if pinned { LogStore.shared.log("[big-picture] ml2210 the installed 32-bit client is kept: no bootstrap update this run") }
        // ml2230: env.MADEIRA_BIG_PICTURE_GPU = 1 lets the web helper draw with the GPU (Chromium's
        // ANGLE on the 32-bit D3D11); off by default, software drawing as before.
        let gpu = MadeiraConfig.flag("MADEIRA_BIG_PICTURE_GPU", fallback: false)
        if gpu { LogStore.shared.log("[big-picture] ml2230 the web helper may use the GPU (env.MADEIRA_BIG_PICTURE_GPU = 1)") }
        listMadeiraLibraries(in: folder)
        let bat = [
            "@echo off",
            "rem Generated by Madeira (ml2021) for Big Picture; rewritten at every launch.",
            "start \"\" \"C:\\windows\\system32\\services.exe\"",
            "cd /d \"\(folder.windows)\"",
            "\"\(folder.windows)\\steam.exe\" -bigpicture -no-cef-sandbox" + (gpu ? "" : " -cef-disable-gpu") + " -console -nocrashmonitor"
                + (pinned ? " -nobootstrapperupdate -skipinitialbootstrap" : "")
                + " -cef-disable-features=SegmentationPlatform,OptimizationTargetPrediction,OptimizationHints",
        ].joined(separator: "\r\n") + "\r\n"
        let path = documents.appendingPathComponent("wine/drive_c/big-picture.bat").path
        do {
            try bat.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            LogStore.shared.log("[big-picture] could not write big-picture.bat: \(error.localizedDescription)", level: .error)
            return false
        }
        LogStore.shared.log("[big-picture] steam.exe -bigpicture from \(folder.windows) in the Wine desktop")
        return true
    }

    /// ml2230: Big Picture's client lists the games Madeira installed. Its libraryfolders.vdf
    /// (config/, the one Valve's client reads, and its steamapps/ copy) gets Madeira's Steam
    /// library (the Dock client's folder, where downloads go) and the libraries on connected
    /// drives, added beside the client's own entries, never replacing one. The records there
    /// are the client's own format (AppManifestWriter). env.MADEIRA_BIG_PICTURE_LIBRARIES = 0
    /// leaves the files alone.
    private static func listMadeiraLibraries(in folder: (windows: String, unix: String)) {
        guard MadeiraConfig.flag("MADEIRA_BIG_PICTURE_LIBRARIES", fallback: true) else { return }   // 0: Big Picture's client lists only its own library
        let fm = FileManager.default
        let own = "Program Files/Steam Big Picture"
        // ml2240: every library Madeira's Steam list reads (MadeiraDock.steamLibraries), not
        // only the client's own folder and the external drives: the other C: libraries its
        // libraryfolders.vdf names were left out. MADEIRA_BIG_PICTURE_DOCK_LIBRARIES=0 restores.
        let found = MadeiraConfig.flag("MADEIRA_BIG_PICTURE_DOCK_LIBRARIES", fallback: true)
            ? MadeiraDock.steamLibraries(drive: MadeiraDock.drive)
            : [SteamRuntimeFiles.relativeRoot + "/steamapps"] + ExternalDrives.steamLibraries
        var libraries = [own]
        for library in found.prefix(32) where library.hasSuffix("/steamapps") {
            let root = String(library.dropLast("/steamapps".count))
            guard !libraries.contains(where: { $0.caseInsensitiveCompare(root) == .orderedSame }) else { continue }
            libraries.append(root)
            let manifests = ((try? fm.contentsOfDirectory(atPath: MadeiraDock.drive.appendingPathComponent(library).path)) ?? [])
                .filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }
            LogStore.shared.log("[big-picture] ml2240 library C:\\\(root.replacingOccurrences(of: "/", with: "\\")): \(manifests.count) install record(s)")
        }
        var added = 0
        for sub in ["config", "steamapps"] {
            let vdf = URL(fileURLWithPath: "\(folder.unix)/\(sub)/libraryfolders.vdf")
            do {
                let existing: Data?
                do { existing = try Data(contentsOf: vdf) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { existing = nil }
                let data = try ExternalSteamLibraries.add(paths: libraries, to: existing)
                guard data != existing else { continue }
                try fm.createDirectory(at: vdf.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: vdf, options: .atomic)
                added += 1
            } catch {
                LogStore.shared.log("[big-picture] \(sub)/libraryfolders.vdf was kept: \(error.localizedDescription)")
            }
        }
        LogStore.shared.log("[big-picture] ml2230 Madeira's Steam libraries listed for Big Picture: \(libraries.count - 1) (\(added) file(s) updated)")
    }

    var windowsPath: String { "C:\\" + relativePath.replacingOccurrences(of: "/", with: "\\") }

    /// The vsync mode to apply: a saved 30 or 40 FPS limit runs as 60 when it is
    /// not offered (DXMT without that cap would present uncapped).
    var effectiveFPSMode: Int32 { ProMotionIntent.supportedMode(fpsMode) }

    func validate() throws {
        let size = resolution.split(separator: "x").compactMap { Int($0) }
        guard size.count == 2, (320...4096).contains(size[0]), (240...4096).contains(size[1]),
              (0...4).contains(fpsMode), !arguments.contains("\0"), !windowsPath.contains("\0"),
              !launchArguments.contains("\0"), !launchWindowsPath.contains("\0"),
              launchWindowsPath.utf8.count < 1024, (steamWorkingWindowsPath?.utf8.count ?? 0) < 512 else {
            throw LibraryError.message("The saved launch profile contains invalid display or argument values.")
        }
        guard LaunchArgumentText.valid(launchArguments) else {
            throw LibraryError.message("Use balanced double quotes, no control characters, and at most 64 launch arguments in 4 KB.")
        }
        // build/madeira_cfg.h reads at most 64 KB of a file.
        guard (config?.utf8.count ?? 0) < 60_000, config?.contains("\0") != true else {
            throw LibraryError.message("This game's config is too long.")
        }
        // ml1163: the launch options.
        guard launchMode == nil || launchMode == "desktop" || launchMode == "direct" else {
            throw LibraryError.message("The saved launch profile contains an invalid launch mode.")
        }
        if usesLaunchOptions, let chosen = workingDirectory?.trimmingCharacters(in: .whitespaces), !chosen.isEmpty {
            // WineProcessBridge maps MADEIRA_WORKDIR onto drive_c (C:\ only), and the
            // services batch quotes it, so only an existing C:\ folder without
            // quotes is accepted.
            var isFolder: ObjCBool = false
            guard !chosen.contains("\""), !chosen.contains("\0"), chosen.utf8.count < 500,
                  let url = Self.hostURL(ofWindowsPath: chosen),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
                throw LibraryError.message("The working folder must be an existing folder on drive C:, such as C:\\Games\\Some Game.")
            }
        }
        // validate() is the last step of a launch that can refuse it
        // (ContentView.launchLibraryEntry), so the services batch is written
        // here: a batch that cannot be written stops the launch with a message.
        if let script = servicesScript {
            guard let url = Self.hostURL(ofWindowsPath: servicesScriptPath) else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try script.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw LibraryError.message("Could not write \(servicesScriptPath): \(error.localizedDescription)")
            }
        }
    }

}
