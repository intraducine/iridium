"""Exercise generated helper/host JSON retrieval and real diagnostic export locally."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

import madeira_jit_observability as overlay
import madeira_psp_jit as prepared

ROOT = Path(__file__).resolve().parents[1]
MADEIRA = ROOT / 'ci/fixtures/madeira-build43/app'


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'Darwin Swift compiler required')
class HelperRetrievalTests(unittest.TestCase):
    def test_generated_request_response_later_launch_mirror_export_and_timeout(self):
        def apply(name, text): return prepared.apply(name, overlay.apply(name, text))
        messages = apply('JITBuiltInMessages.swift', (MADEIRA / overlay.MESSAGES).read_text())
        helper = apply('MadeiraJITHelper.swift', (MADEIRA / overlay.HELPER).read_text())
        host = apply('JITBuiltInHost.swift', (MADEIRA / overlay.HOST).read_text())
        # Redirect only OS/container boundaries: fake extension API and simulator
        # StikJIT stand-in. All request/response, validation and export code is real.
        helper = helper.replace('#if !targetEnvironment(simulator)', '#if false').replace('#if targetEnvironment(simulator)', '#if true')
        messages = messages.replace('FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first', 'Optional(fixtureHelperDirectory)')
        helper = helper.replace('FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first', 'Optional(fixtureHelperDirectory)')
        helper = helper.replace('IridiumJITHelperDiagnostic(attemptID:', 'IridiumJITHelperDiagnostic(directory: fixtureHelperDirectory, attemptID:')
        start = host.index('        if NSClassFromString("NSExtension") == nil {')
        end = host.index('        guard let data = try? JSONEncoder().encode(request)', start)
        host = host[:start] + '        let found: AnyObject = FixtureExtension()\n' + host[end:]
        start = host.index('        guard let url = Bundle.main.builtInPlugInsURL?')
        end = host.index('\n    }', start)
        host = host[:start] + '        return "fixture.helper"' + host[end:]
        fixture = r'''
import Foundation
let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtureHelperDirectory = fixtureRoot.appendingPathComponent("helper")
let fixtureAppDirectory = fixtureRoot.appendingPathComponent("app")

@MainActor final class LogStore {
    enum Level { case error }
    static let shared = LogStore()
    func log(_ text: String, level: Level = .error) { fatalError("Diagnostic retrieval initialized LogStore") }
}

// Replace the OS extension endpoint with a loopback invoking the generated
// NSExtensionRequestHandling implementation, through actual JSON/item payloads.
final class FixtureExtension: NSObject, NSExtensionShim {
    static var mode = "normal"
    private var completion: ((NSUUID?, [Any]?) -> Void)?
    func beginExtensionRequest(withInputItems items: [Any], completion started: @escaping (NSUUID?) -> Void) {
        let uuid = NSUUID()
        started(uuid)
        if Self.mode == "timeout" { return }
        let callback = completion!
        let mode = Self.mode
        let context = FixtureContext(items: items) { returned in
            var items = returned
            if mode == "stale", let item = items.first as? NSExtensionItem,
               let data = item.userInfo?[MadeiraJITRequest.Response.itemKey] as? Data,
               var response = try? JSONDecoder().decode(MadeiraJITRequest.Response.self, from: data) {
                response.diagnosticAttemptID = "ffffffffffffffff"
                item.userInfo = [MadeiraJITRequest.Response.itemKey: try! JSONEncoder().encode(response)]
            }
            if mode == "malformed" {
                let item = NSExtensionItem()
                item.userInfo = [MadeiraJITRequest.Response.itemKey: Data("{".utf8)]
                items = [item]
            }
            if mode == "poison", let item = items.first as? NSExtensionItem,
               let data = item.userInfo?[MadeiraJITRequest.Response.itemKey] as? Data,
               var response = try? JSONDecoder().decode(MadeiraJITRequest.Response.self, from: data) {
                response.diagnosticRecords = ["raw remote packet TOKEN"]
                item.userInfo = [MadeiraJITRequest.Response.itemKey: try! JSONEncoder().encode(response)]
            }
            if mode == "oversized" {
                let item = NSExtensionItem()
                item.userInfo = [MadeiraJITRequest.Response.itemKey: Data(repeating: 32, count: 16385)]
                items = [item]
            }
            callback(uuid, items)
            callback(uuid, items) // A repeated completion must have no effect.
        }
        MadeiraJITHelperHandler().beginRequest(with: context)
    }
    func pid(forRequestIdentifier identifier: NSUUID) -> Int32 { fatalError("Diagnostics requested a PID") }
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void) { completion = block }
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void) {}
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void) {}
}

final class FixtureContext: NSExtensionContext {
    private let items: [Any]
    private let callback: ([Any]) -> Void
    init(items: [Any], callback: @escaping ([Any]) -> Void) { self.items = items; self.callback = callback; super.init() }
    required init?(coder: NSCoder) { fatalError() }
    override var inputItems: [Any] { items }
    override func completeRequest(returningItems items: [Any]?, completionHandler: ((Bool) -> Void)? = nil) {
        callback(items ?? [])
    }
}

@main struct Check {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fixtureHelperDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: fixtureAppDirectory, withIntermediateDirectories: true)
        let fault = "IRJIT2 stage=first.fault kind=stop signal=10 exception=1 code=2 pc=0123456789abcdef addr=fedcba9876543210 md=2 insn=mov42"
        let publicFault = "IRJIT2 stage=first.fault kind=stop signal=10 exception=1 code=2 md=2 insn=mov42"
        let seed = fixtureRoot.appendingPathComponent("fixture-request.json")
        if CommandLine.arguments.count > 2 {
            let first = MadeiraJITRequest.enable(targetPID: 1, pairingData: Data([1]), scriptBase64: "synthetic")
            try JSONEncoder().encode(first).write(to: seed)
            let writer = IridiumJITHelperDiagnostic(directory: fixtureHelperDirectory, attemptID: first.diagnosticAttemptID!)
            writer.receive(fault)
            writer.receive("IRJIT2 stage=setup.attach status=SECRET")
            let receipt = IridiumPSPHelperJournal(attempt: first.diagnosticAttemptID!, hash: String(repeating: "a", count: 64), pid: 123, directory: fixtureHelperDirectory)
            receipt.receive("IRPSP2 phase=2 code=24 length=0 fields=0 version=2")
            receipt.receive("IRPSP2 phase=15 code=0 length=0 fields=0 version=2")
            receipt.receive("IRPSP1 event=ready seq=0 bytes=0 addr=0000000000000000 version=2")
            receipt.receive("IRPSP1 event=allocated seq=1 bytes=16777216 addr=0000000400000000 version=2")
            receipt.receive("IRPSP1 event=prepared seq=1 bytes=16777216 addr=0000000400000000 version=2")
            receipt.receive("IRPSP1 event=allocated seq=2 bytes=262144 addr=0000000402000000 version=2")
            receipt.receive("IRPSP1 event=prepared seq=2 bytes=262144 addr=0000000402000000 version=2")
            receipt.receive("IRPSP2 phase=15 code=23 length=3 fields=0 version=2")
            receipt.receive("IRPSP3 code=23 seq=3 error=14 version=2")
            receipt.receive("IRPSP1 event=allocated seq=3 bytes=262144 addr=0000000404000000 version=2")
            receipt.receive("IRPSP1 event=prepare.failed seq=3 bytes=262144 addr=0000000404000000 version=2")
            receipt.receive("IRPSP1 event=detach.ack seq=2 bytes=0 addr=0000000000000000 version=2")
            receipt.receive("IRPSP2 phase=14 code=1 length=2 fields=0 version=2")
            receipt.sdkReturned(clean: true)
            _exit(0) // Persisted journal must survive without deinit or a response.
        }
        let first = try JSONDecoder().decode(MadeiraJITRequest.self, from: Data(contentsOf: seed))
        let second = MadeiraJITRequest.enable(targetPID: 1, pairingData: Data([1]), scriptBase64: "synthetic")
        precondition(first.diagnosticAttemptID != second.diagnosticAttemptID)
        do {
            let writer = IridiumJITHelperDiagnostic(directory: fixtureHelperDirectory, attemptID: second.diagnosticAttemptID!)
            writer.receive("IRJIT2 stage=setup.ignore status=ok")
        }
        let helperFile = fixtureHelperDirectory.appendingPathComponent("iridium-jit-helper.log")
        let writer = try FileHandle(forWritingTo: helperFile)
        try writer.seekToEnd(); try writer.write(contentsOf: Data("utc=1.000000 attempt=1234567890abcdef IRJIT2 stage=setup.pass status=ok".utf8)); try writer.close()
        let original = try Data(contentsOf: helperFile)
        // Simulate a busy enable operation. Diagnostic retrieval must bypass it.
        let gate = DispatchSemaphore(value: 0)
        MadeiraJITWork.queue.async { gate.wait() }
        let started = Date()
        let response = await MadeiraBuiltInJIT.diagnosticSnapshot()
        gate.signal()
        precondition(Date().timeIntervalSince(started) < 1.5)
        let records = response!
        let current: IridiumPSPHelperReceipt? = await withCheckedContinuation { continuation in
            MadeiraBuiltInJIT.pspSnapshot(attempt: first.diagnosticAttemptID!) { continuation.resume(returning: $0) }
        }
        precondition(current?.attempt == first.diagnosticAttemptID && current?.preparedCount == 2)
        precondition(current?.phase == 14 && current?.firstIssuePhase == 2 && current?.firstIssueCode == 24)
        precondition(current?.preparationFailureCode == 23 && current?.preparationFailureSequence == 3 && current?.preparationFailureError == 14)
        let stale: IridiumPSPHelperReceipt? = await withCheckedContinuation { continuation in
            MadeiraBuiltInJIT.pspSnapshot(attempt: second.diagnosticAttemptID!) { continuation.resume(returning: $0) }
        }
        precondition(stale == nil)
        precondition(records.count == 4 && records.contains { $0.contains(fault) })
        precondition(records.contains { $0.contains("attempt=" + first.diagnosticAttemptID!) })
        precondition(records.contains { $0.contains("attempt=" + second.diagnosticAttemptID!) })
        precondition(!records.contains { $0.contains("SECRET") || $0.contains("1234567890abcdef") })
        precondition(try! Data(contentsOf: helperFile) == original) // retrieval is read-only
        try IridiumJITHelperSnapshot.mirror(records, in: fixtureAppDirectory)
        let mirror = fixtureAppDirectory.appendingPathComponent("iridium-jit-helper-mirror.log")
        let saved = try Data(contentsOf: mirror)
        // Same normal export function used by Settings/player diagnostics.
        let output = try RuntimeDiagnosticLogFiles.export(in: fixtureAppDirectory, destination: fixtureRoot)
        let text = try String(contentsOf: output, encoding: .utf8)
        precondition(text.contains("iridium-jit-helper-mirror.log") && text.contains(publicFault))
        precondition(text.contains(first.diagnosticAttemptID!) && text.contains(second.diagnosticAttemptID!))
        precondition(text.contains("stage=sdk.return sequence=2 allocated=3 prepared=2"))
        precondition(text.contains("prepCode=23 prepSequence=3 prepError=14"))
        precondition(text.contains("phase=14 code=1 length=2 fields=0 issuePhase=2 issueCode=24"))
        precondition(!text.contains(String(repeating: "a", count: 64)) && !text.contains("0000000402000000"))
        precondition(!text.contains("SECRET"))
        precondition(!text.contains("0123456789abcdef") && !text.contains("fedcba9876543210"))
        precondition(!text.contains(" pc=") && !text.contains(" addr="))
        try IridiumJITHelperSnapshot.mirror([], in: fixtureAppDirectory)
        precondition(try! Data(contentsOf: mirror) == saved)
        for mode in ["stale", "malformed", "poison", "oversized", "timeout"] {
            FixtureExtension.mode = mode
            let start = Date()
            let result = await MadeiraBuiltInJIT.diagnosticSnapshot()
            precondition(result == nil && Date().timeIntervalSince(start) < 3)
            precondition(try! Data(contentsOf: mirror) == saved)
        }
        // Unavailable on another launch: persisted app mirror still exports.
        try fm.removeItem(at: helperFile)
        FixtureExtension.mode = "normal"
        let later = await MadeiraBuiltInJIT.diagnosticSnapshot()
        try IridiumJITHelperSnapshot.mirror(later!, in: fixtureAppDirectory)
        precondition(try! Data(contentsOf: mirror) == saved)
        let exportedAgain = try RuntimeDiagnosticLogFiles.export(in: fixtureAppDirectory, destination: fixtureRoot)
        precondition(try! String(contentsOf: exportedAgain, encoding: .utf8).contains(publicFault))
        // Reject poison, excess records, links and incomplete input at both ends.
        for invalid in [records + ["TOKEN=secret"], Array(repeating: records[0], count: 33)] {
            do { try IridiumJITHelperSnapshot.mirror(invalid, in: fixtureAppDirectory); fatalError("accepted invalid snapshot") }
            catch {}
            precondition(try! Data(contentsOf: mirror) == saved)
        }
        let previous = fixtureHelperDirectory.appendingPathComponent("iridium-jit-helper.previous.log")
        try fm.removeItem(at: previous)
        try fm.createSymbolicLink(at: previous, withDestinationURL: mirror)
        precondition(IridiumJITHelperSnapshot.read(in: fixtureHelperDirectory).isEmpty)
        try fm.removeItem(at: mirror)
        try fm.createSymbolicLink(at: mirror, withDestinationURL: previous)
        do { try IridiumJITHelperSnapshot.mirror(records, in: fixtureAppDirectory); fatalError("followed mirror link") }
        catch {}
        print("PASS generated JSON/item request-response, crash/relaunch persistence, busy queue bypass, attempt isolation, normal export, duplicate/stale/malformed/poison/oversized/timeout, partial tail, mirror preservation and symlink refusal")
    }
}
'''
        # Private helper/host types remain in the same compilation unit as their
        # fixture; their implementations are not copied or reimplemented.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'Check.swift'
            source.write_text(messages + '\n' + helper + '\n' + host + '\n' + fixture)
            binary = root / 'check'
            runtime = root / 'RuntimeDiagnosticLogFiles.swift'
            runtime.write_text((ROOT / 'iridium/apps/ios/Iridium/RuntimeDiagnosticLogFiles.swift').read_text().replace('consoleSink = RuntimeConsoleLogSink()', 'consoleSink = RuntimeConsoleLogSink(directory: fixtureAppDirectory)'))
            build = subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                                    '-module-cache-path', str(root / 'cache'), str(source),
                                    str(runtime),
                                    '-o', str(binary)], capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            subprocess.run([str(binary), str(root), 'seed'], capture_output=True, text=True, check=True, timeout=15)
            result = subprocess.run([str(binary), str(root)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS generated JSON/item request-response', result.stdout)
            print(result.stdout.strip())


if __name__ == '__main__': unittest.main()
