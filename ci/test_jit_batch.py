"""Run the shipping batch bridge with checked 64-bit packets and real JavaScriptCore."""
from pathlib import Path
import json
import platform
import shutil
import subprocess
import tempfile
import unittest
from host_tests import module_cache
import stikjit_frontend as build

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'JavaScriptCore required')
class CheckedBatchTests(unittest.TestCase):
    def test_real_bridge_packets_bounds_replies_and_transport_failures(self):
        source = build.RUNNER.read_text().replace('@_implementationOnly import idevice', '')
        fixture = r'''
import Foundation
import JavaScriptCore
struct IdeviceFfiError {}
enum StikJITError: Error { case scriptUnavailable, scriptExecution(String) }
enum StikJIT { enum Script { case custom(String); var name: String { "fixture" } } }
enum BundledScript { static func source(for script: StikJIT.Script) throws -> String {
    switch script { case .custom(let source): return source }
} }
enum IdeviceFFI { static func consume(_ p: UnsafeMutablePointer<IdeviceFfiError>, fallback: String) -> StikJITError {
    .scriptExecution(fallback)
} }
var packets: [[UInt8]] = [], reads = 0, badAt = -1, badReply: String? = "E09", transportAt = -1
var error = IdeviceFfiError(), sendFails = false
func debugserver_command_new(_ p: UnsafePointer<CChar>, _ a: OpaquePointer?, _ n: Int) -> OpaquePointer? { OpaquePointer(bitPattern: 1) }
func debugserver_command_free(_ p: OpaquePointer) {}
func debug_proxy_send_command(_ p: OpaquePointer, _ h: OpaquePointer, _ r: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> UnsafeMutablePointer<IdeviceFfiError>? { nil }
func idevice_string_free(_ p: UnsafeMutablePointer<CChar>) { free(p) }
func debug_proxy_send_raw(_ p: OpaquePointer, _ bytes: UnsafePointer<UInt8>, _ n: UInt) -> UnsafeMutablePointer<IdeviceFfiError>? {
    packets.append(Array(UnsafeBufferPointer(start: bytes, count: Int(n))))
    return sendFails ? withUnsafeMutablePointer(to: &error) { $0 } : nil
}
func debug_proxy_read_response(_ p: OpaquePointer, _ out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> UnsafeMutablePointer<IdeviceFfiError>? {
    reads += 1
    if reads == transportAt { return withUnsafeMutablePointer(to: &error) { $0 } }
    out.pointee = reads == badAt ? badReply.flatMap { strdup($0) } : strdup("OK")
    return nil
}
func run(_ address: String, _ length: String) -> (String, Bool) {
    packets = []; reads = 0; var logs: [String] = []
    let script = "log(prepare_memory_region_checked('\(address)', '\(length)'));"
    let runner = ScriptRunner(targetPID: 42, debugProxy: OpaquePointer(bitPattern: 1)!, script: .custom(script), progress: { logs.append($0) })
    do { try runner.run(); return (logs[logs.count - 2], false) }
    catch { return (logs.last ?? "", true) }
}
func verifyPackets(_ start: UInt64, _ count: Int) {
    precondition(packets.count == 1 && packets[0].count == count * 26 && reads == count)
    for i in 0..<count {
        let packet = Array(packets[0][i*26..<(i+1)*26])
        let address = String(format: "%016llx", start + UInt64(i) * 16384)
        let body = "M\(address),1:69"
        let sum = body.utf8.reduce(UInt8(0)) { $0 &+ $1 }
        precondition(String(bytes: packet, encoding: .utf8) == "$\(body)#" + String(format: "%02x", sum))
    }
}
for address: UInt64 in [0x100000000, 0xfffffc000, 0x7000000000, 0x123456789abcc000, 0xffffffffff000000] {
    let result = run(String(address, radix: 16), "200000")
    precondition(result == ("OK", false)); verifyPackets(address, 128)
}
for (address, length) in [("0", "4000"), ("7000000001", "4000"), ("7000000000", "0"),
    ("7000000000", "1"), ("7000000000", "204000"), ("ffffffffffffc000", "4000"),
    ("10000000000000000", "4000"), ("-1", "4000"), ("NaN", "4000"), ("0x7000000000", "4000")] {
    precondition(run(address, length) == ("E01", false) && packets.isEmpty && reads == 0)
}
for response: String? in ["E09", "", nil, "T05", "OKjunk"] {
    badAt = 3; badReply = response
    precondition(run("7000000000", "200000") == ("E01", false))
    precondition(reads == 128) // Drain the whole batch before the script can set registers.
}
badAt = -1; transportAt = 3
precondition(run("7000000000", "200000").1 && reads == 3)
transportAt = -1; sendFails = true
precondition(run("7000000000", "200000").1 && reads == 0)
print("checked native batch: high addresses, checksums, bounds, all replies and transport failure passed")
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); main = root / 'main.swift'
            main.write_text(source + '\n' + fixture)
            binary = root / 'check'
            subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', module_cache(),
                            '-framework', 'JavaScriptCore', str(main), '-o', str(binary)], check=True, timeout=60)
            subprocess.run([str(binary)], check=True, timeout=15)

    def test_component_rejects_changed_sources_and_binary(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); framework = root / 'StikJIT.framework'; framework.mkdir()
            binary = framework / 'StikJIT'; binary.write_bytes(b'compiled')
            expected = {'runner': 'reviewed'}
            record = {'inputs': expected, 'files': {'StikJIT': build.digest(binary)}}
            (root / 'component.json').write_text(json.dumps(record))
            (framework / 'IridiumJITTransport.json').write_text(json.dumps(record))
            with patch.object(build, 'verify_source'), patch.object(build, 'OUTPUT', root), patch.object(build, 'identity', return_value=expected):
                self.assertEqual(build.verify(framework), record)
                binary.write_bytes(b'stale')
                with self.assertRaisesRegex(ValueError, 'differs'): build.verify(framework)
            with patch.object(build, 'verify_source'), patch.object(build, 'OUTPUT', root), patch.object(build, 'identity', return_value={'runner': 'new'}):
                with self.assertRaisesRegex(ValueError, 'inputs changed'): build.verify(framework)

    def test_release_source_graph_is_portable_and_offline(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); cached = root / 'cache'; cached.mkdir()
            (cached / 'component.json').write_text('{"receipt": "checked"}')
            stage = root / 'source'; stage.mkdir()
            vendor = stage / '.build/stikjit-frontend/vendor'
            config = '[source.vendored-sources]\ndirectory = "' + str(vendor) + '"\n'
            with patch.object(build, 'OUTPUT', cached), patch.object(build.subprocess, 'check_output', return_value=config) as cargo:
                build.collect_source(stage)
            self.assertEqual(cargo.call_count, 2)
            self.assertIn('--sync', cargo.call_args.args[0])
            output = stage / '.build/stikjit-frontend'
            self.assertNotIn(str(root), (output / '.cargo/config.toml').read_text())
            self.assertEqual((stage / 'STIKJIT-BUILD-RECEIPT.json').read_text(), '{"receipt": "checked"}')
            with patch.object(build, 'OUTPUT', output):
                self.assertIn('--offline', build.cargo_command())



@unittest.skipUnless(shutil.which('node'), 'Node required')
class SharedScriptBatchTests(unittest.TestCase):
    def test_checked_fast_path_and_safe_external_fallback(self):
        source = (ROOT / 'iridium/apps/ios/App/Resources/madeira-jit.js').read_text().split('let pid = get_pid();')[0]
        harness = r'''
const vm=require('vm'), assert=require('assert');
const source=JSON.parse(require('fs').readFileSync(0,'utf8'));
const calls=[]; let failure=-1;
const context=vm.createContext({prepare_memory_region:()=>{throw Error('unsafe helper called')},
 prepare_memory_region_checked:(address,length)=>{ calls.push([address,length]); return calls.length===failure?'E09':'OK'; },
 send_command:()=>{throw Error('slow path called with checked helper')}});
vm.runInContext(source,context);
assert(context.iridiumPrepareRegion(0x7000000000n,560n*1024n*1024n));
assert.equal(calls.length,280);
assert.deepEqual(calls[0],['7000000000','200000']);
assert.deepEqual(calls.at(-1),['7022e00000','200000']);
calls.length=0;
assert(context.iridiumPrepareRegion(0x123456789abcdef0n,0x4000n));
assert.deepEqual(calls,[['123456789abcc000','8000']]);
calls.length=0;failure=2;
assert(!context.iridiumPrepareRegion(0x7000000000n,0x600000n));assert.equal(calls.length,2);
calls.length=0;failure=-1;
assert(!context.iridiumPrepareRegion(0xffffffffffffffffn,1n));assert.equal(calls.length,0);
const external=vm.createContext({prepare_memory_region:()=>{throw Error('unsafe helper called')},send_command:c=>{calls.push(c);return 'OK'}});
vm.runInContext(source,external);assert(external.iridiumPrepareRegion(0x7000000000n,0x8000n));
assert.deepEqual(calls,['M7000000000,1:69','M7000004000,1:69']);
console.log('560 MiB Windows arena: 280 checked batches instead of 35840 serialized page requests');
'''
        subprocess.run(['node', '-e', harness], input=json.dumps(source), text=True, check=True, timeout=15)
