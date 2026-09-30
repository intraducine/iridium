import Foundation

@main struct GamePrerequisitesCheck {
    static func main() throws {
        let script = Data(#"""
        // Repeated Run Process sections must not replace each other.
        "InstallScript" {
          "Run Process" { "Runtime" {
            "HasRunKey" "HKLM\\Software\\Example"
            "MinimumHasRunValue" "3"
            "Process 2" "%INSTALLDIR%/redist/Second.msi"
            "Command 2" "/quiet"
            "Process 1" "%INSTALLDIR%\\redist\\First.exe"
            "Command 1" "/path \"%INSTALLDIR%\""
          } }
          "Run Process" { "Runtime" {
            "HasRunKey" "HKLM\\Software\\Example"
            "MinimumHasRunValue" "3"
            "Process 10" "%INSTALLDIR%\\redist\\Third.exe"
          } }
          "Run Process" { "User" {
            "HasRunKey" "HKEY_CURRENT_USER\\Software\\Example"
            "Process 1" "%INSTALLDIR%\\redist\\First.exe"
          } }
        }
        """#.utf8)
        let processes = try IridiumSteamInstallScript.processes(script: script, installDir: "C:\\IridiumGame", appID: 42)
        precondition(processes.count == 4)
        precondition(processes[0].executable.hasSuffix("First.exe"))
        precondition(processes[1].executable.hasSuffix("Second.msi"))
        precondition(processes[2].executable.hasSuffix("Third.exe"))
        precondition(processes[0].arguments == "/path \"C:\\IridiumGame\"")
        precondition(processes[0].run.value == 3)
        precondition(IridiumSteamInstallScript.keys(processes[0].run) == ["Software\\Example", "Software\\Wow6432Node\\Example"])
        precondition(processes[3].run.hive == .user && IridiumSteamInstallScript.keys(processes[3].run).count == 1)
        var explicit = processes[0].run
        explicit.key = "Software\\Wow6432Node\\Example"
        precondition(IridiumSteamInstallScript.keys(explicit).count == 1)
        let old = "[Software\\\\Wow6432Node\\\\Example] 1\n\"runtime\"=dword:00000002\n"
        let done = old.replacingOccurrences(of: "00000002", with: "00000003")
        precondition(!IridiumSteamInstallScript.marked(processes[0].run, in: old))
        precondition(IridiumSteamInstallScript.marked(processes[0].run, in: done))
        let noKey = Data(#"""
        "InstallScript" { "Run Process" { "Custom" { "Process 1" "%INSTALLDIR%\\Setup.exe" } } }
        """#.utf8)
        let manual = try IridiumSteamInstallScript.processes(script: noKey, installDir: "C:\\IridiumGame")
        precondition(manual.count == 1 && manual[0].run.key == "Software\\Iridium\\Prerequisites")
        let native = try IridiumSteamInstallScript.processes(script: noKey, installDir: "C:\\IridiumGame", appID: 42)
        precondition(native[0].run.key == "Software\\Valve\\Steam\\Apps\\42")
        for bad in [
            String(decoding: noKey, as: UTF8.self).dropLast(),
            Substring(String(decoding: noKey, as: UTF8.self).replacingOccurrences(of: "Setup.exe", with: "Setup.bat")),
            Substring(String(decoding: script, as: UTF8.self).replacingOccurrences(of: "Second.msi", with: "Second.cmd")),
            Substring(String(decoding: script, as: UTF8.self).replacingOccurrences(of: "MinimumHasRunValue\" \"3", with: "MinimumHasRunValue\" \"invalid")),
        ] {
            do {
                _ = try IridiumSteamInstallScript.processes(script: Data(bad.utf8), installDir: "C:\\IridiumGame")
                preconditionFailure("An incomplete or invalid installer group was accepted")
            } catch { }
        }
        let completedUnsupported = try IridiumSteamInstallScript.processes(
            script: Data(String(decoding: noKey, as: UTF8.self).replacingOccurrences(of: "Setup.exe", with: "Setup.bat").utf8),
            installDir: "C:\\IridiumGame", completed: { _ in true })
        precondition(completedUnsupported.isEmpty)
        let text = try IridiumGamePrerequisites.configuration(processes, executable: "C:\\IridiumGame\\Game.exe",
            arguments: ["", "two words", "quote\"here", "C:\\end\\", "&not-a-shell", "雪"])
        precondition(text.contains("runs=2\r\n") && text.contains("processes=3\r\n"))
        precondition(text.contains("executable=xC:\\windows\\system32\\msiexec.exex\r\n"))
        precondition(text.contains(" /i \"C:\\IridiumGame\\redist\\Second.msi\" /quiet"))
        precondition(MadeiraLaunchArguments.quoteWindowsArgument("C:\\end\\") == "\"C:\\end\\\\\"")
        var invalid = processes[0]
        invalid.run.name = "bad\n[game]"
        do { _ = try IridiumGamePrerequisites.configuration([invalid], executable: "C:\\Game.exe", arguments: []); preconditionFailure("INI injection accepted") }
        catch { }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix")
        let game = prefix.appendingPathComponent("drive_c/IridiumGame")
        let resourcesURL = root.appendingPathComponent("Resources.bundle")
        for path in ["ControllerRuntime/arm64ec/iridium-prerequisites.exe", "i386-windows/ntdll.dll", "i386-windows/fusion.dll"] {
            let file = resourcesURL.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("MZfixture".utf8).write(to: file)
        }
        let resources = Bundle(path: resourcesURL.path)!
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
        try Data("MZfixture".utf8).write(to: prefix.appendingPathComponent("drive_c/windows/system32/msiexec.exe"))
        try fm.createDirectory(at: game.appendingPathComponent("redist"), withIntermediateDirectories: true)
        for name in ["system.reg", "user.reg"] { try Data("WINE REGISTRY Version 2\n".utf8).write(to: prefix.appendingPathComponent(name)) }
        let save = game.appendingPathComponent("save.dat")
        try Data("keep my save".utf8).write(to: save)
        let ordinary = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: nil, resources: resources)
        precondition(ordinary == nil)
        try script.write(to: game.appendingPathComponent("installscript.vdf"))
        for name in ["First.exe", "Second.msi", "Third.exe"] { try Data("MZfixture".utf8).write(to: game.appendingPathComponent("redist/" + name)) }
        let launch = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: ["two words"], appID: 42, resources: resources)!
        precondition(launch.installerCount == 2)
        let encoded = try Data(contentsOf: prefix.appendingPathComponent("drive_c/IridiumPrerequisites/installers.ini"))
        precondition(encoded.starts(with: [0xff, 0xfe]))
        let savedData = try Data(contentsOf: save)
        precondition(savedData == Data("keep my save".utf8))
        let fusion = prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/Framework/v2.0.50727/fusion.dll")
        try Data("custom fusion".utf8).write(to: fusion)
        _ = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: 42, resources: resources)
        let customFusion = try Data(contentsOf: fusion)
        precondition(customFusion == Data("custom fusion".utf8))
        try IridiumGamePrerequisites.cancel(prefix: prefix)
        precondition(fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/IridiumPrerequisites/cancel.flag").path))
        try Data(done.utf8).write(to: prefix.appendingPathComponent("system.reg"))
        try Data("[Software\\\\Example] 1\n\"user\"=dword:00000001\n".utf8).write(to: prefix.appendingPathComponent("user.reg"))
        let recorded = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: 42, resources: resources)
        precondition(recorded == nil)
        let shared = root.appendingPathComponent("SteamGames/228980/default/content")
        try fm.createDirectory(at: shared.appendingPathComponent("_CommonRedist"), withIntermediateDirectories: true)
        try noKey.write(to: shared.appendingPathComponent("_CommonRedist/installscript.vdf"))
        try Data("MZfixture".utf8).write(to: shared.appendingPathComponent("Setup.exe"))
        precondition(IridiumGamePrerequisites.sharedRoots(gameRoot: game, nativeSteamInstall: false,
            steamGamesRoot: root.appendingPathComponent("SteamGames")).isEmpty)
        let sharedRoots = IridiumGamePrerequisites.sharedRoots(gameRoot: game, nativeSteamInstall: true,
            steamGamesRoot: root.appendingPathComponent("SteamGames"))
        precondition(sharedRoots.map { $0.resolvingSymlinksInPath().path } == [shared.resolvingSymlinksInPath().path])
        let sharedLaunch = try IridiumGamePrerequisites.prepare(prefix: prefix, executable: "C:\\IridiumGame\\Game.exe",
            arguments: [], appID: 42, sharedRoots: sharedRoots, resources: resources)
        precondition(sharedLaunch?.installerCount == 1)
        precondition(IridiumGamePrerequisites.resolve("C:\\IridiumPrerequisites\\shared1\\setup.EXE", drive: prefix.appendingPathComponent("drive_c")) != nil)
        precondition(IridiumGamePrerequisites.resolve("C:\\..\\save.dat", drive: prefix.appendingPathComponent("drive_c")) == nil)
        print("PASS: repeated scripts, process ordering, registry thresholds/views, custom imports, shared redist, MSI, argv, fusion, cancellation and save preservation")
    }
}
