# SPDX-License-Identifier: AGPL-3.0-only
"""Run the shipping Cloud check and quit-upload bodies with isolated transfers."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from host_tests import module_cache

ROOT = Path(__file__).resolve().parents[1]
STEAM = ROOT / 'iridium/apps/ios/App/Steam'


def function(source, name):
    start = source.index('    func ' + name + '(') if name != 'download' else source.index('    private func download(')
    return source[start:source.index('\n    }\n', start) + len('\n    }\n')].replace('private func download', 'func download')


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class SteamCloudQuitTests(unittest.TestCase):
    def test_running_game_takeover_checks_uploads_and_keeps_live_cache_untouched(self):
        source = (STEAM / 'SteamOwnedLibrary.swift').read_text()
        cloud = (STEAM / 'SteamCloud.swift').read_text()
        models = cloud[cloud.index('struct SteamCloudEntry:'):cloud.index('/// How one app\'s cloud')]
        models += cloud[cloud.index('struct SteamCloudPlan:'):cloud.index('// MARK: - Upload')]
        models += cloud[cloud.index('struct SteamCloudState:'):]
        methods = '\n'.join(function(source, name) for name in ('checkCloud', 'download', 'uploadForQuit'))
        fixture = r'''import Foundation
MODELS
struct SteamCloudPaths: Sendable {
    func location(cloudPath: String) -> (base: URL, parts: [String])? { (URL(fileURLWithPath: "/fixture"), [cloudPath]) }
    static func resolve(base: URL, parts: [String]) -> URL { base.appendingPathComponent(parts.joined(separator: "/")) }
    static func split(_ path: String) -> (root: String?, rest: String) { (nil, path) }
}
struct SaveFile: Sendable { var root = "remote" }
struct Info: Sendable { var saveFiles: [SaveFile] = []; var rootOverrides: [String] = [] }
struct Listing: Sendable { var audit: SteamCloudAudit }
struct SteamCloudAudit: Equatable, Sendable {
    var changeNumber: UInt64 = 1, cloudFiles = 1
    var entries: [SteamCloudEntry] = []
    var summary: String { "fixture" }
    func count(_ kind: SteamCloudEntry.Kind) -> Int { entries.filter { $0.kind == kind }.count }
    static func run(listing: Listing, saveFiles: [SaveFile], paths: SteamCloudPaths) -> Self { listing.audit }
    static func findElsewhere(cloudPath: String, drive: URL) -> String? { nil }
}
enum FixtureError: Error { case network }
enum SteamFileError: Error { case invalid(String) }
enum SteamSignIn { static func message(_ error: Error) -> String { "Synthetic connection failure" } }
@MainActor enum SteamLog { static func event(_ message: String) {} }
@MainActor enum SteamRemoteCache {
    static var writes = 0
    static func write(appID: Int, audit: SteamCloudAudit, paths: SteamCloudPaths) throws -> (synced: Int, local: Int, dropped: Int)? {
        writes += 1; return (0, 0, 0)
    }
}
@MainActor enum SteamCloudTransfer {
    static var writes = 0
    static func place(_ file: Data, at url: URL, backupTo backup: URL, relative: [String], time: UInt64) throws { writes += 1 }
}
@MainActor final class Gate { var takeovers = 0; func takeOver() async { takeovers += 1 } }
@MainActor final class Fixture {
    static var cloudEnabled = true, cloudQuitEnabled = true, cloudRemoteCache = true
    static let cloudNoFolders = "No save folders", drive = URL(fileURLWithPath: "/fixture")
    static func reason(_ error: Error) -> String { "fixture" }
    static func cloudBackup(_ appID: Int) -> URL { drive }
    let gate = Gate()
    var signedIn = true, inSession = true, cloudTakeover = false, remoteCacheOffLogged = false
    var cloudBlocked: Bool { inSession && !cloudTakeover }
    var cloud: [Int: SteamCloudState] = [:], cloudBusy: Set<Int> = []
    var networkCalls = 0, uploads = 0, failNetwork = false, disableDuringListing = false
    var localSHA: UInt8 = 2, serverSHA: UInt8 = 1
    var changeDuringUpload = false, keepSaving = false, serverChangesAfterUpload = false
    var createDuringUpload = false, extraSave = false
    var known = ["save.dat": "01"]
    enum CloudQuit { case working(String), conflict(Int), failed(String), done(Int) }
    var cloudQuit: CloudQuit?
    func baseline(_ appID: Int) -> [String: String] { known }
    func recordBaseline(_ appID: Int, settled: [String: String]) { known.merge(settled) { _, new in new } }
    func cloudContext(_ appID: Int) async throws -> (info: Info, paths: SteamCloudPaths)? {
        networkCalls += 1
        if failNetwork { throw FixtureError.network }
        return (Info(), SteamCloudPaths())
    }
    func cloudListing(_ appID: Int) async throws -> Listing {
        if disableDuringListing { Self.cloudEnabled = false }
        if keepSaving { localSHA += 1 }
        let entry = SteamCloudEntry(path: "save.dat", kind: serverSHA == localSHA ? .same : .differ,
            cloudSHA: Data([serverSHA]), localSHA: Data([localSHA]))
        let extra = SteamCloudEntry(path: "new-save.dat", kind: .localOnly, localSHA: Data([4]))
        return Listing(audit: SteamCloudAudit(entries: extraSave ? [entry, extra] : [entry]))
    }
    func cloudFile(_ appID: Int, _ entry: SteamCloudEntry) async throws -> Data { Data([1]) }
    func upload(_ appID: Int, _ wanted: [SteamCloudEntry]) async -> Bool {
        precondition(!cloudBlocked)
        uploads += 1; serverSHA = localSHA; cloud[appID]?.lastUpload = wanted.count
        cloud[appID]?.lastUploadHashes = Dictionary(uniqueKeysWithValues: wanted.map { ($0.key, SteamCloudPlan.hex(Data([serverSHA]))) })
        if changeDuringUpload { localSHA += 1; changeDuringUpload = false }
        if serverChangesAfterUpload { serverSHA += 1 }
        if createDuringUpload { extraSave = true }
        return true
    }
METHODS
}
@main @MainActor struct Check {
    static func main() async {
        let app = 42
        let blocked = Fixture()
        let denied = await blocked.checkCloud(app)
        precondition(denied == nil)
        precondition(blocked.networkCalls == 0)
        let takeover = Fixture(); takeover.cloudTakeover = true
        let checked = await takeover.checkCloud(app)
        precondition(checked?.upload.count == 1, "The running game's takeover must retain its completed check")
        precondition(SteamRemoteCache.writes == 0, "Never rewrite the running client's cache")
        let downloaded = await takeover.download(app, checked!.upload)
        precondition(!downloaded && SteamCloudTransfer.writes == 0)
        let library = Fixture(); library.inSession = false
        let normal = await library.checkCloud(app)
        precondition(normal != nil && SteamRemoteCache.writes == 1)
        let arrived = await library.download(app, normal!.upload)
        precondition(arrived && SteamCloudTransfer.writes == 1)
        let before = SteamRemoteCache.writes
        let quitting = Fixture()
        await quitting.uploadForQuit(app)
        guard case .done(1) = quitting.cloudQuit else { preconditionFailure("Quit upload did not complete") }
        precondition(quitting.gate.takeovers == 1 && quitting.uploads == 1 && SteamRemoteCache.writes == before)
        let failed = Fixture(); failed.failNetwork = true
        await failed.uploadForQuit(app)
        guard case .failed("Synthetic connection failure") = failed.cloudQuit else { preconditionFailure("Lost connection error") }
        precondition(failed.uploads == 0)
        failed.failNetwork = false
        await failed.uploadForQuit(app)
        guard case .done(1) = failed.cloudQuit else { preconditionFailure("Retry did not complete") }
        precondition(failed.gate.takeovers == 1 && failed.uploads == 1)
        let conflict = Fixture(); conflict.known = [:]
        await conflict.uploadForQuit(app)
        guard case .conflict(1) = conflict.cloudQuit else { preconditionFailure("Conflict must need a choice") }
        precondition(conflict.uploads == 0)
        let racing = Fixture(); racing.changeDuringUpload = true
        await racing.uploadForQuit(app)
        guard case .failed(let changed) = racing.cloudQuit else { preconditionFailure("A changed save must keep the app open") }
        precondition(changed.contains("changed during upload") && racing.known["save.dat"] == "02")
        await racing.uploadForQuit(app)
        guard case .done(1) = racing.cloudQuit else { preconditionFailure("A retry must upload the newer save without a false conflict") }
        precondition(racing.uploads == 2 && racing.gate.takeovers == 1)
        let replaced = Fixture(); replaced.serverChangesAfterUpload = true
        await replaced.uploadForQuit(app)
        guard case .failed(let unconfirmed) = replaced.cloudQuit else { preconditionFailure("Unconfirmed bytes must not close the app") }
        precondition(unconfirmed.contains("not confirmed") && replaced.known["save.dat"] == "01")
        let created = Fixture(); created.createDuringUpload = true
        await created.uploadForQuit(app)
        guard case .failed(let added) = created.cloudQuit else { preconditionFailure("A new save must not be left behind on quit") }
        precondition(added.contains("changed during upload") && created.extraSave)
        let saving = Fixture(); saving.keepSaving = true
        await saving.uploadForQuit(app)
        guard case .failed(let busy) = saving.cloudQuit else { preconditionFailure("Unstable saves must not upload or close") }
        precondition(busy.contains("still saving") && saving.uploads == 0)
        let disabled = Fixture(); disabled.cloudTakeover = true; disabled.disableDuringListing = true
        let discarded = await disabled.checkCloud(app)
        precondition(discarded == nil && disabled.uploads == 0 && SteamRemoteCache.writes == before)
        print("PASS: production quit upload, account takeover, active-game download/cache guards, real errors, retry and conflict hold")
    }
}
'''.replace('MODELS', models).replace('METHODS', methods)
        with tempfile.TemporaryDirectory(prefix='iridium-cloud-quit-') as directory:
            root = Path(directory)
            (root / 'Check.swift').write_text(fixture)
            built = subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors',
                '-parse-as-library', '-module-cache-path', module_cache('macosx'),
                str(root / 'Check.swift'), '-o', str(root / 'check')],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            ran = subprocess.run([str(root / 'check')], capture_output=True, text=True, timeout=45)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
