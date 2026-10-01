import Foundation

@main struct QueueChecks {
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw NSError(domain: "QueueChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            checks += 1
        }
        let game = SteamOwnedGame(appId: 42, name: "Fixture")
        let first = SteamDownloadJob(game: game, account: "  ACCOUNT_A ", options: SteamInstallOptions())
        let second = SteamDownloadJob(game: SteamOwnedGame(appId: 43, name: "Other"), account: "account_a", options: SteamInstallOptions())
        let otherAccount = SteamDownloadJob(game: game, account: "account_b", options: SteamInstallOptions())
        var queue = SteamDownloadQueue()
        try check(first.account == "account_a", "Account normalization")
        try check(queue.enqueue(first), "First enqueue")
        try check(!queue.enqueue(first), "Duplicate UUID rejected")
        try check(!queue.enqueue(SteamDownloadJob(game: game, account: "account_a", options: SteamInstallOptions())), "Duplicate pending app rejected")
        try check(queue.enqueue(second) && queue.enqueue(otherAccount), "Different app/account permitted")
        try check(queue.next(account: "account_b")?.id == otherAccount.id, "Account isolation")
        try check(queue.next(account: "missing") == nil, "No jobs for another account")
        queue.prioritize(second.id)
        try check(queue.next(account: "account_a")?.id == second.id, "Explicit priority")
        try check(queue.begin(second.id), "Start queued job")
        try check(!queue.begin(first.id) && queue.next(account: "account_b") == nil, "One active native operation across accounts")
        try check(!queue.remove(second.id), "Active entry cannot be removed")
        queue.recoverAfterRelaunch()
        try check(queue.jobs.first(where: { $0.id == second.id })?.status == .paused && queue.isPaused, "Crash recovers as paused")
        try check(queue.next(account: "account_a") == nil, "Relaunch never silently downloads")
        try check(!queue.resume(second.id, account: "account_b"), "Other account cannot resume")
        try check(queue.resume(second.id, account: "account_a"), "Owner may resume")
        queue.update(second.id) { $0.status = .cancelled }
        let replacement = SteamDownloadJob(game: SteamOwnedGame(appId: 43, name: "Other"), account: "account_a", options: SteamInstallOptions())
        try check(queue.enqueue(replacement), "Replacement for cancelled job")
        try check(!queue.resume(second.id, account: "account_a"), "Cannot revive conflicting cancelled job")
        queue.update(first.id) {
            $0.status = .completed
            $0.completedBytes = 50
            $0.totalBytes = 40
            $0.installed = SteamDownloadedGame(appId: 42, name: "Fixture", directory: "/fixture/42/99/content", executables: ["game.exe"], buildId: "18446744073709551615", options: SteamInstallOptions())
        }
        try check(queue.jobs.first(where: { $0.id == first.id })?.fractionCompleted == 1, "Progress is clamped")
        try check(!queue.resume(first.id, account: "account_a"), "Completed receipt is not requeued in place")
        let encoded = try JSONEncoder().encode(queue)
        var recovered = try JSONDecoder().decode(SteamDownloadQueue.self, from: encoded).validated()
        try check(recovered == queue, "Queue and install options round-trip")
        try check(recovered.jobs.first(where: { $0.id == first.id })?.installed?.buildId == "18446744073709551615", "64-bit Steam IDs remain strings")
        let movedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("steam-rebase-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: movedRoot) }
        let movedContent = movedRoot.appendingPathComponent("42/99/content")
        try FileManager.default.createDirectory(at: movedContent, withIntermediateDirectories: true)
        let oldContent = "/var/mobile/Containers/Data/Application/OLD/Library/Application Support/SteamGames/42/99/content"
        recovered.update(first.id) { $0.installed?.directory = oldContent; $0.reuseDirectory = oldContent }
        recovered.rebaseInstalledDirectories(steamGamesRoot: movedRoot)
        try check(recovered.jobs.first(where: { $0.id == first.id })?.installed?.directory == movedContent.path,
                  "Installed content follows an iOS container change")
        try check(recovered.jobs.first(where: { $0.id == first.id })?.reuseDirectory == movedContent.path,
                  "Repair source follows an iOS container change")
        let receipt = try JSONEncoder().encode(recovered.jobs.first(where: { $0.id == first.id })!.installed!)
        try receipt.write(to: movedContent.deletingLastPathComponent().appendingPathComponent("installed.json"))
        // Old repairs/variants remain nested; new repairs are siblings of builds.
        let retainedPaths = ["42/99/checks/legacy/content", "42/99/variants/german/content",
                             "42/installs/new-repair/content"]
        for path in retainedPaths {
            let directory = movedRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("repaired game and saves".utf8).write(to: directory.appendingPathComponent("game.exe"))
        }
        let registeredRepairPath = movedRoot.appendingPathComponent(retainedPaths[0]).path
        try check(!SteamManagedFiles.overlaps(movedContent.path, registeredRepairPath),
                  "Original payload deletion does not overlap a legacy repair library entry")
        try check(SteamManagedFiles.overlaps(movedContent.path, movedContent.appendingPathComponent("nested/content").path),
                  "Nested active or reuse paths are protected")
        try check(!SteamManagedFiles.overlaps(movedContent.path, movedContent.path + "-other"),
                  "Path overlap uses component boundaries")
        let alias = movedRoot.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: movedContent)
        try check(SteamManagedFiles.overlaps(movedContent.path, alias.path), "Aliased active paths are protected")
        try SteamManagedFiles.delete(recovered.jobs.first(where: { $0.id == first.id })!, from: movedRoot)
        for path in retainedPaths {
            try check(try Data(contentsOf: movedRoot.appendingPathComponent(path + "/game.exe")) == Data("repaired game and saves".utf8),
                      "Delete original preserves repair/variant payload and library target")
        }
        try check(!FileManager.default.fileExists(atPath: movedContent.deletingLastPathComponent().appendingPathComponent("installed.json").path),
                  "Original receipt is removed")
        try check(!FileManager.default.fileExists(atPath: movedContent.path), "Explicit deletion frees the managed install")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("steam-outside-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        recovered.update(first.id) { $0.installed?.directory = outside.appendingPathComponent("content").path }
        do { try SteamManagedFiles.delete(recovered.jobs.first(where: { $0.id == first.id })!, from: movedRoot)
            try check(false, "Outside install accepted")
        } catch { checks += 1 }
        try check(FileManager.default.fileExists(atPath: outside.path), "Outside files remain untouched")
        let legacyReceipt = Data("{\"appId\":42,\"name\":\"Old\",\"directory\":\"/fixture\",\"executables\":[\"game.exe\"]}".utf8)
        try check(try JSONDecoder().decode(SteamDownloadedGame.self, from: legacyReceipt).buildId == nil, "PR40 receipt compatibility")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iridium-queue-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("queue.json")
        let storage = SteamQueuePersistence(url: url)
        try check(try await storage.load() == SteamDownloadQueue(), "Missing journal starts empty")
        try await storage.save(queue, revision: 10)
        recovered.isPaused = true
        try await storage.save(recovered, revision: 9)
        try check(try await storage.load() == queue, "Stale async checkpoints cannot overwrite newer state")
        try await storage.save(recovered, revision: 11)
        try check(try await storage.load() == recovered, "Latest checkpoint persists")
        let retained = root.appendingPathComponent("save.dat")
        try Data("progress".utf8).write(to: retained)
        try check(recovered.remove(first.id), "History entry removal")
        try await storage.save(recovered, revision: 12)
        try check(try Data(contentsOf: retained) == Data("progress".utf8), "History removal never deletes payload or saves")
        var invalid = recovered
        invalid.version = 999
        do { try await storage.save(invalid, revision: 13); try check(false, "Unsupported queue version accepted") }
        catch SteamQueueError.invalidDocument { checks += 1 }
        try check(try await storage.load() == recovered, "Invalid checkpoint does not replace persisted queue")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: url)
        do { _ = try await storage.load(); try check(false, "Corrupt journal accepted") }
        catch is DecodingError { checks += 1 }
        try check(try Data(contentsOf: url) == corrupt, "Unreadable queue remains intact")
        let oversized = Data(repeating: 32, count: 4 * 1024 * 1024 + 1)
        try oversized.write(to: url)
        do { _ = try await storage.load(); try check(false, "Oversized journal accepted") }
        catch SteamQueueError.invalidDocument { checks += 1 }
        var rate = SteamTransferRate()
        rate.update(networkBytes: 100, at: 1, downloading: true)
        try check(rate.bytesPerSecond == 0, "One rate sample cannot imply a speed")
        rate.update(networkBytes: 300, at: 3, downloading: true)
        try check(rate.bytesPerSecond == 100, "Rate counts new payload bytes")
        rate.update(networkBytes: 900, at: 4, downloading: false)
        try check(rate.bytesPerSecond == 0, "Verification is not download speed")
        rate.update(networkBytes: 0, at: 5, downloading: true)
        try check(rate.bytesPerSecond == 0, "New operation resets transfer rate")
        print("PASS: \(checks) Steam queue checks.")
    }
}
