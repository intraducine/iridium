// SPDX-License-Identifier: GPL-3.0-or-later
// Registry/path rules adapted from Madeira DockInstallers.swift (40d5e748).
// Copyright 2026 125hz. Madeira Converter Exception: see testrepos/Madeira/LICENSE-EXCEPTION.md.
import Foundation

enum IridiumGamePrerequisites {
    struct Launch {
        let executable: String
        let arguments: [String]
        let installerCount: Int
    }

    // Called by the existing boot worker, before wineserver owns the registry.
    static func prepare(prefix: URL, executable: String, arguments: [String], appID: Int?,
                        sharedRoots: [URL] = [], resources: Bundle = .main) throws -> Launch? {
        let fm = FileManager.default
        let drive = prefix.appendingPathComponent("drive_c", isDirectory: true)
        let game = drive.appendingPathComponent("IridiumGame", isDirectory: true)
        func registry(_ name: String) throws -> String {
            let file = prefix.appendingPathComponent(name)
            guard fm.fileExists(atPath: file.path) else { return "" } // Wine creates a fresh registry at startup.
            return try String(contentsOf: file, encoding: .utf8)
        }
        let machine = try registry("system.reg"), user = try registry("user.reg")
        var found: [IridiumInstallProcess] = []
        var sharedToCopy: [(URL, URL)] = []
        for (index, root) in ([game] + sharedRoots).enumerated() {
            let installDir = index == 0 ? "C:\\IridiumGame" : "C:\\IridiumPrerequisites\\shared\(index)"
            var pending: [IridiumInstallProcess] = []
            for file in try IridiumSteamInstallScript.scripts(folder: root) {
                let bytes = try Data(contentsOf: file)
                let processes = try IridiumSteamInstallScript.processes(script: bytes, installDir: installDir, appID: appID) {
                    IridiumSteamInstallScript.marked($0, in: $0.hive == .machine ? machine : user)
                }
                for process in processes {
                    if !pending.contains(process) { pending.append(process) }
                }
            }
            guard !pending.isEmpty else { continue }
            found += pending.filter { !found.contains($0) }
            if index > 0 { sharedToCopy.append((root, drive.appendingPathComponent("IridiumPrerequisites/shared\(index)"))) }
        }
        guard !found.isEmpty else { return nil } // Preserve the ordinary launch path.
        guard found.count <= 64 else { throw failure("This game has too many prerequisite installer steps.") }
        guard let helper = resources.url(forResource: "iridium-prerequisites", withExtension: "exe",
                                         subdirectory: "ControllerRuntime/arm64ec"),
              resources.url(forResource: "ntdll", withExtension: "dll", subdirectory: "i386-windows") != nil else {
            throw failure("This build is missing its prerequisite installer runtime.")
        }
        let folder = drive.appendingPathComponent("IridiumPrerequisites", isDirectory: true)
        try requireUnlinkedPath(folder, under: prefix)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let cancelFile = folder.appendingPathComponent("cancel.flag")
        try requireUnlinkedPath(cancelFile, under: prefix)
        if fm.fileExists(atPath: cancelFile.path) { try fm.removeItem(at: cancelFile) }
        for (source, destination) in sharedToCopy {
            try MadeiraGamePreparation.validateCompleteTree(source)
            try requireUnlinkedPath(destination, under: prefix)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
        }
        for process in found {
            guard resolve(process.executable, drive: drive) != nil else {
                throw failure("A prerequisite installer file is missing: \(URL(fileURLWithPath: process.executable.replacingOccurrences(of: "\\", with: "/")).lastPathComponent).")
            }
        }
        if found.contains(where: { $0.executable.lowercased().hasSuffix(".msi") }),
           resolve("C:\\windows\\system32\\msiexec.exe", drive: drive) == nil {
            throw failure("This build is missing the Windows Installer service program.")
        }
        try placeFusion(drive: drive, resources: resources)
        let helperTarget = folder.appendingPathComponent("iridium-prerequisites.exe")
        try requireUnlinkedPath(helperTarget, under: prefix)
        try Data(contentsOf: helper).write(to: helperTarget, options: .atomic)
        let plan = folder.appendingPathComponent("installers.ini")
        try requireUnlinkedPath(plan, under: prefix)
        let text = try configuration(found, executable: executable, arguments: arguments)
        guard let encoded = text.data(using: .utf16LittleEndian) else { throw CocoaError(.fileReadCorruptFile) }
        try (Data([0xff, 0xfe]) + encoded).write(to: plan, options: .atomic)
        return Launch(executable: "C:\\IridiumPrerequisites\\iridium-prerequisites.exe",
                      arguments: ["C:\\IridiumPrerequisites\\installers.ini"], installerCount: Set(found.map(\.run)).count)
    }

    // Native downloads use SteamGames/<appid>/<variant>/content. Also accept the
    // usual Steamworks Shared sibling folder, when the selected library has it.
    static func sharedRoots(gameRoot: URL, nativeSteamInstall: Bool,
                            steamGamesRoot: URL? = nil) -> [URL] {
        guard nativeSteamInstall else { return [] }
        let fm = FileManager.default
        var result = [gameRoot.deletingLastPathComponent().appendingPathComponent("Steamworks Shared")]
        let managed = steamGamesRoot ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SteamGames")
        let shared = managed.appendingPathComponent("228980")
        if let variants = try? fm.contentsOfDirectory(at: shared, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            result += variants.sorted(by: { $0.path < $1.path }).map { $0.appendingPathComponent("content") }
        }
        return result.filter {
            let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    static func configuration(_ processes: [IridiumInstallProcess], executable: String, arguments: [String]) throws -> String {
        var runs: [IridiumInstallRun] = []
        for process in processes where !runs.contains(process.run) { runs.append(process.run) }
        func value(_ text: String) throws -> String {
            guard !text.contains("\0"), !text.contains("\r"), !text.contains("\n"), text.utf16.count < 32_766 else {
                throw failure("A prerequisite install script contains an invalid value.")
            }
            return "x" + text + "x"
        }
        func directory(_ path: String) -> String { String(path[..<(path.lastIndex(of: "\\") ?? path.endIndex)]) }
        var lines = ["[plan]", "runs=\(runs.count)", "[game]", "executable=\(try value(executable))",
                     "command=\(try value(MadeiraLaunchArguments.windowsCommandLine(executable: executable, arguments: arguments)))",
                     "directory=\(try value(directory(executable)))"]
        for (index, run) in runs.enumerated() {
            let selected = processes.filter { $0.run == run }
            let keys = IridiumSteamInstallScript.keys(run)
            lines += ["[run\(index)]", "hive=\(run.hive == .machine ? 1 : 2)", "name=\(try value(run.name))",
                      "value=\(run.value)", "keys=\(keys.count)", "processes=\(selected.count)"]
            for (offset, key) in keys.enumerated() { lines.append("key\(offset)=\(try value(key))") }
            for (offset, process) in selected.enumerated() {
                let msi = process.executable.lowercased().hasSuffix(".msi")
                let program = msi ? "C:\\windows\\system32\\msiexec.exe" : process.executable
                let command = MadeiraLaunchArguments.quoteWindowsArgument(program)
                    + (msi ? " /i " + MadeiraLaunchArguments.quoteWindowsArgument(process.executable) : "")
                    + (process.arguments.isEmpty ? "" : " " + process.arguments)
                lines += ["[process\(index)_\(offset)]", "executable=\(try value(program))",
                          "command=\(try value(command))", "directory=\(try value(directory(process.executable)))"]
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // Resolve Windows paths without following a link outside this prefix.
    static func resolve(_ windowsPath: String, drive: URL) -> URL? {
        guard windowsPath.hasPrefix("C:\\") else { return nil }
        let parts = windowsPath.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { return nil }
        let root = drive.resolvingSymlinksInPath().standardizedFileURL
        var current = root
        for part in parts {
            let names = try? FileManager.default.contentsOfDirectory(atPath: current.path)
            guard let match = names?.first(where: { $0.caseInsensitiveCompare(String(part)) == .orderedSame }) else { return nil }
            current.appendPathComponent(match)
            guard current.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                  (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        }
        return (try? current.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true ? current : nil
    }

    private static func placeFusion(drive: URL, resources: Bundle) throws {
        let target = drive.appendingPathComponent("windows/Microsoft.NET/Framework/v2.0.50727/fusion.dll")
        if (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil { return }
        guard let source = resources.url(forResource: "fusion", withExtension: "dll", subdirectory: "i386-windows") else {
            throw failure("This build is missing the prerequisite fusion.dll helper.")
        }
        try requireUnlinkedPath(target, under: drive)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
    }

    static func cancel(prefix: URL) throws {
        let flag = prefix.appendingPathComponent("drive_c/IridiumPrerequisites/cancel.flag")
        try requireUnlinkedPath(flag, under: prefix)
        try Data().write(to: flag, options: .atomic)
    }

    private static func requireUnlinkedPath(_ url: URL, under root: URL) throws {
        let root = root.standardizedFileURL
        var current = url.standardizedFileURL
        guard current.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
        while current != root {
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            current.deleteLastPathComponent()
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "IridiumPrerequisites", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
