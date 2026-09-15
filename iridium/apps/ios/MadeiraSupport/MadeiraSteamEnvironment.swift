import Foundation

enum MadeiraSteamEnvironment {
    private static let lockKey = "IRIDIUM_LOCK_STEAM_ENV"
    private static let explicitIDKey = "IRIDIUM_STEAM_APP_ID"

    static func publish(
        sourceExecutable: URL,
        sourceRoot: URL,
        windowsExecutable: String
    ) {
        unsetenv("SteamAppPath")
        unsetenv("SteamGameId")
        unsetenv("SteamAppId")
        setenv(lockKey, "1", 1)

        guard let appID = resolveAppID(sourceExecutable: sourceExecutable, sourceRoot: sourceRoot) else {
            RuntimeLogCapture.writeLine("[Launch] Steam metadata unset for selected game; no steam_appid.txt or IRIDIUM_STEAM_APP_ID was found.")
            return
        }

        let appPath = windowsDirectory(for: windowsExecutable)
        setenv("SteamAppPath", appPath, 1)
        setenv("SteamGameId", appID, 1)
        setenv("SteamAppId", appID, 1)
        RuntimeLogCapture.writeLine("[Launch] Steam metadata set for selected game: appID \(appID), path \(appPath)")
    }

    private static func resolveAppID(sourceExecutable: URL, sourceRoot: URL) -> String? {
        if let explicit = sanitizedAppID(ProcessInfo.processInfo.environment[explicitIDKey]) {
            return explicit
        }

        let root = sourceRoot.resolvingSymlinksInPath().standardizedFileURL
        let executable = sourceExecutable.resolvingSymlinksInPath().standardizedFileURL
        guard executable.path.hasPrefix(root.path + "/") || executable.deletingLastPathComponent() == root else {
            return nil
        }

        let executableDirectory = executable.deletingLastPathComponent()
        let candidates = [
            executableDirectory.appendingPathComponent("steam_appid.txt", isDirectory: false),
            root.appendingPathComponent("steam_appid.txt", isDirectory: false)
        ]

        for candidate in candidates {
            if let appID = readSteamAppID(candidate) {
                return appID
            }
        }
        return nil
    }

    private static func readSteamAppID(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 65) <= 64,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return sanitizedAppID(text)
    }

    private static func sanitizedAppID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= 20,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            return nil
        }
        return trimmed
    }

    private static func windowsDirectory(for windowsExecutable: String) -> String {
        guard let slash = windowsExecutable.lastIndex(of: "\\") else {
            return "C:\\IridiumGame"
        }
        let directory = String(windowsExecutable[..<slash])
        return directory.isEmpty ? "C:\\" : directory
    }
}
