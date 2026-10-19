// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from Madeira; see App/Origin and docs/runtime-integration.md.
import SwiftUI
import Darwin

extension LibraryEntry {
    /// Runs on the launch worker, before the JIT pool is taken.
    func applyEnvironment() {
        configureLaunch()
        // Unset unless chosen: FEX's own default then applies, as for any other launch.
        if reducedX87 { setenv("FEX_X87REDUCEDPRECISION", "1", 1) } else { unsetenv("FEX_X87REDUCEDPRECISION") }
        // Exported only when chosen: unset keeps the engine's own default (and any
        // madeira.cfg setting), as before these choices existed.
        // Unset otherwise, so a previous game's choice (a launch that died before the
        // session-end unset) never beats madeira.cfg for this one.
        if let cpuCount, (1..<64).contains(cpuCount) { setenv("MADEIRA_CPU_COUNT", String(cpuCount), 1) }
        else { unsetenv("MADEIRA_CPU_COUNT") }
        // "dinput": the host pad also as a DirectInput joystick (wine/dlls/dinput/joystick_ios.c,
        // off by default because a game reading both APIs would see two controllers).
        // Exported only for that choice, and it wins over madeira.cfg's MADEIRA_DINPUT_PAD
        // (ml1240: in ml1184's per-launch list, unset when the session ends); the cfg's
        // own value still applies to the other choices.
        if GamepadInput.keyboardMouseAvailable, controllerMode == "dinput" { setenv("MADEIRA_DINPUT_PAD", "1", 1) }
        else if MadeiraConfig.get("env.MADEIRA_DINPUT_PAD") == nil { unsetenv("MADEIRA_DINPUT_PAD") }
        if let anisotropyLimit, [1, 2, 4, 8].contains(anisotropyLimit) { setenv("DXMT_D9_ANISO_LIMIT", String(anisotropyLimit), 1) }
        else { unsetenv("DXMT_D9_ANISO_LIMIT") }
        // Set or unset, so a previous session's choice never stays.
        if avx == true { setenv("MADEIRA_FEX_AVX", "1", 1) } else { unsetenv("MADEIRA_FEX_AVX") }
        if frameGeneration == true { setenv("MADEIRA_FRAMEGEN", "1", 1) } else { unsetenv("MADEIRA_FRAMEGEN") }
        // "Report an NVIDIA GPU": DXMT's vendor extension (DXGI vendor 10DE,
        // NVAPI), with DXGI's output carrying user32's monitor and mode list so
        // the game finds its monitor on the adapter. The device id goes into
        // DXMT_CONFIG (ContentView); win32u reads DXMT_ENABLE_NVEXT for the
        // registry adapter. Set or unset, so one game's choice never leaks into
        // the next session; when set, it wins over madeira.cfg's lines for the
        // same keys (ml1184's per-launch list in WineProcessBridge.m).
        if reportNVIDIA == true {
            setenv("DXMT_ENABLE_NVEXT", "1", 1)
            setenv("DXMT_WSI_MONITOR_IDENTITY", "1", 1)
            setenv("DXMT_WSI_MODE_TABLE", "1", 1)
        } else {
            unsetenv("DXMT_ENABLE_NVEXT")
            unsetenv("DXMT_WSI_MONITOR_IDENTITY")
            unsetenv("DXMT_WSI_MODE_TABLE")
        }
        // Fastsync's per-game switches, only when Settings chose Fastsync; with Madsync
        // (the default) or Wine's standard sync nothing is exported here.
        if SyncEngine.current == .fastsync {
            let mode = MadeiraConfig.get("env.MADEIRA_FASTSYNC") ?? "auto"
            setenv("MADEIRA_FASTSYNC", fastSync == false ? "0" : mode, 1)
            // Only a game's own choice; otherwise madeira.cfg's env.MADEIRA_FASTSYNC_SEM applies.
            if let sem = semaphoreFastPath { setenv("MADEIRA_FASTSYNC_SEM", sem ? "1" : "0", 1) }
            else { unsetenv("MADEIRA_FASTSYNC_SEM") }
        }
        madeira_set_vsync_locked(effectiveFPSMode)
        // This game's own lines; a launch without any unsets the previous game's.
        do {
            let pairs = try MadeiraConfig.applyGame(gameConfigText)
            if !pairs.isEmpty {
                LogStore.shared.log("[game-cfg] " + pairs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            }
        } catch {
            LogStore.shared.log("[game-cfg] this game's config could not be written: \(error.localizedDescription)")
        }
        fputs("[frontend] launch profile applied\n", stderr)
        if usesLaunchOptions {
            fputs("[library] ml1163 start=\(runsInDesktop ? "desktop" : "direct") batch=\(isBatch ? 1 : 0) services=\(servicesScript != nil ? 1 : 0) cwd=\(launchDirectory)\n", stderr)
        }
        LogStore.shared.log("[display-shape] resolution=\(resolution) mode=\(displayMode.rawValue)")
    }

    /// What the bridge starts. Set on the main thread before the session begins.
    func configureLaunch() {
        // "The game"'s identity and the launch's working folder, for this launch only
        // (the bridge reads and clears them); every other launch starts without them.
        unsetenv("MADEIRA_STEAM_APPID"); unsetenv("MADEIRA_STEAM_APPPATH"); unsetenv("MADEIRA_WORKDIR")
        if steamAppID != nil {
            // A Steam game through Madeira Dock: Dock has set what starts (ContentView.startDock);
            // the virtual monitor follows this entry's Resolution, as below. "The game" starts
            // its own program below, like any library game.
            if !startsSteamGameDirectly {
                GuestDisplay.configureSessionDefault(view: CGSize(width: 1280, height: 720), knob: resolution)
                return
            }
        }
        let command = desktop == true ? (exe: "explorer.exe", args: launchArguments) : launchCommand
        setenv("MADEIRA_EXE", command.exe, 1)
        setenv("MADEIRA_ARGS", command.args, 1)
        if desktop == true || runsInDesktop { setenv("MADEIRA_DESKTOP", "1", 1) } else { unsetenv("MADEIRA_DESKTOP") }
        if startsSteamGameDirectly, let steamAppID {
            // The game's own Steam identity (SteamAppId, SteamGameId, SteamAppPath = its install
            // folder) instead of the bridge's fixed one.
            setenv("MADEIRA_STEAM_APPID", String(steamAppID), 1)
            setenv("MADEIRA_STEAM_APPPATH", windowsPath, 1)
        }
        // ml1163: a game starts in launchDirectory (a chosen folder, Steam's for "The game",
        // else the program's own). It is exported when the bridge's default, the folder of
        // what it starts, differs: explorer.exe (desktop mode) and cmd.exe (a .bat, the
        // services batch) live elsewhere. The Desktop entry keeps explorer's default.
        if desktop != true, launchDirectory != Self.folder(of: command.exe) {
            setenv("MADEIRA_WORKDIR", launchDirectory, 1)
        }
        // Every session's virtual monitor takes this entry's Resolution
        // (MADEIRA_SCREEN_W/H, source "knob"); for the Desktop entry it is the
        // same size as its /desktop= argument.
        GuestDisplay.configureSessionDefault(view: CGSize(width: 1280, height: 720), knob: resolution)
    }
}
