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
    /// FEX's X87ReducedPrecision for this game. Off by default, as in FEX; only
    /// an explicit choice exports FEX_X87REDUCEDPRECISION=1.
    var reducedX87 = false
    var liveLogs = false
    var performance = false
    var touchControls = false
    var controls: [TouchControl]?
    /// The named layout (TouchControlPresets.swift) `controls` came from, so the
    /// Session menu shows it and an edit is written back to it; nil for controls
    /// no layout holds. Older files have none.
    var controlLayout: String?
    var lastPlayed: Date?
    var graphicsAPI: String?
    var folderBytes: Int64?
    var metadataChecked: Date?
    var metadataRevision: Int?
    var overlayFields: [String]?
    /// The Wine desktop (explorer and services in a virtual desktop).
    var desktop: Bool?
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

    /// What MadeiraConfig.applyGame writes for this game: the lines its pickers
    /// stand for, then its own config, which wins where both set a key.
    var gameConfigText: String? {
        var lines: [String] = []
        if let metalFXUpscale { lines.append("metalfx-upscale = \(metalFXUpscale)") }
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
    /// else the entry's Launch arguments.
    var programArguments: String { startsSteamGameDirectly ? (steamProgramArguments ?? "") : arguments }
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
    // Shared with the native launch-profile adapter; not persisted.
    var launchCommand: (exe: String, args: String) {
        func quoted(_ s: String) -> String { "\"\(s)\"" }
        var path = launchWindowsPath
        var extra = programArguments.trimmingCharacters(in: .whitespaces)
        var batch = isBatch
        if servicesScript != nil { path = servicesScriptPath; extra = ""; batch = true }
        func withExtra(_ s: String) -> String { extra.isEmpty ? s : s + " " + extra }
        if runsInDesktop {
            return ("explorer.exe", "/desktop=shell,\(resolution) " + withExtra(batch ? "cmd /c \(quoted(path))" : quoted(path)))
        }
        if batch { return ("C:\\windows\\system32\\cmd.exe", withExtra("/c \(quoted(path))")) }
        return (path, programArguments)   // upstream's direct launch, arguments verbatim
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
        var quoted = false, inToken = false, tokens = 0
        for character in launchArguments {
            if character == "\"" { quoted.toggle() }
            if !quoted && (character == " " || character == "\t") { inToken = false }
            else if !inToken { tokens += 1; inToken = true }
        }
        // WineProcessBridge takes at most 64 arguments in 4 KB.
        guard launchArguments.utf8.count < 4096 else { throw LibraryError.message("The complete launch command is too long.") }
        guard !quoted, tokens <= 64 else { throw LibraryError.message("Use balanced double quotes and at most 64 launch arguments in total.") }
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
