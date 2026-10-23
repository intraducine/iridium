"""Pinned-emitter UB regression and secret-free helper observations; no device."""
from host_tests import module_cache
from pathlib import Path
import importlib.util
import json
import platform
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import madeira_jit_observability as helper
import ppsspp_native_overlay as psp

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / 'vendor/PPSSPP'
MADEIRA = ROOT / 'ci/fixtures/madeira-build43/app'


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('clang++'), 'Darwin C++ compiler required')
class EmitterRegressionTests(unittest.TestCase):
    def test_exact_production_emitter_ubsan_and_constant_bytes(self):
        # Compile the complete production emitter, not a reimplementation.
        # Pattern initialization makes its unset bool entries reproducibly invalid.
        fixture = r'''
#include "Common/Arm64Emitter.h"
#include "Common/Log.h"
#include <cassert>
#include <cstdarg>
#include <cstring>
bool HandleAssert(bool, const char *, const char *, int, const char *, const char *, ...) { return true; }
void GenericLog(Log, LogLevel, const char *, int, const char *, ...) {}
static void check(Arm64Gen::ARM64Reg reg, uint64_t expected, bool optimize) {
    alignas(16) uint8_t bytes[64] = {};
    Arm64Gen::ARM64XEmitter emitter(bytes, bytes);
    emitter.MOVI2R(reg, expected, optimize); emitter.RET();
    uint64_t value = 0xfeedbeefdeadbeefULL;
    bool wide = reg == Arm64Gen::X0;
    uint64_t mask = wide ? UINT64_MAX : UINT32_MAX;
    for (auto p = bytes; p < emitter.GetCodePointer(); p += 4) {
        uint32_t word; memcpy(&word, p, 4);
        if (word == 0xd65f03c0) { assert(p + 4 == emitter.GetCodePointer()); break; }
        uint64_t imm = (word >> 5) & 0xffff;
        unsigned shift = ((word >> 21) & 3) * 16;
        if ((word & 0x9f000000) == 0x10000000 || (word & 0x9f000000) == 0x90000000) {
            int64_t offset = ((word >> 5) & 0x7ffff) * 4 | ((word >> 29) & 3);
            if (offset & (1 << 20)) offset -= 1 << 21;
            value = word & 0x80000000 ? (uintptr_t(p) & ~uintptr_t(4095)) + offset * 4096 : uintptr_t(p) + offset;
            value &= mask; continue; // ADR/ADRP: permitted by upstream even when optimize=false.
        }
        if ((word & 0x7f000000) == 0x11000000) {
            value = (value + uint64_t((word >> 10) & 0xfff) * ((word & (1 << 22)) ? 4096 : 1)) & mask;
            continue;
        }
        switch (word & 0x7f800000) {
        case 0x52800000: value = imm << shift; break; // MOVZ
        case 0x12800000: value = ~(imm << shift); break; // MOVN
        case 0x72800000: value = (value & ~(uint64_t(0xffff) << shift)) | (imm << shift); break; // MOVK
        default: assert(word == (wide ? 0xaa3f03e0 : 0x2a3f03e0)); value = mask; break; // MVN ZR
        }
        value &= mask;
    }
    assert(value == expected && emitter.GetCodePointer() <= bytes + 32);
}
int main() {
    for (bool optimize : {true, false}) {
        for (uint64_t value : {0ULL, 7ULL, 42ULL, 0x12345678ULL, 0x12340000ULL, 0xffffabcdULL, 0xffffffffULL})
            check(Arm64Gen::W0, value, optimize);
        for (uint64_t value : {0ULL, 7ULL, 42ULL, 0x100000000ULL, 0x123456789abcdef0ULL, UINT64_MAX})
            check(Arm64Gen::X0, value, optimize);
    }
}
'''
        original = (UPSTREAM / 'Common/Arm64Emitter.cpp').read_text()
        patched = psp.apply('Common/Arm64Emitter.cpp', original)
        self.assertIn('bool upload_part[4] = {!optimize, !optimize, !optimize, !optimize};', patched)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); main = root / 'main.cpp'; main.write_text(fixture)
            for label, source in [('original', original), ('patched', patched)]:
                unit = root / (label + '.cpp'); unit.write_text(source); binary = root / label
                subprocess.run(['clang++', '-std=c++17', '-O1', '-ftrivial-auto-var-init=pattern',
                                '-fsanitize=undefined,bool', '-fno-sanitize-recover=all',
                                '-ffunction-sections', '-fdata-sections', '-Wl,-dead_strip',
                                '-I', str(UPSTREAM), '-I', str(ROOT / 'iridium/apps/ios/RuntimeBridge'), str(unit), str(main), '-o', str(binary)], check=True)
                result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
                if label == 'original':
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('not a valid value for type', result.stderr)
                else: self.assertEqual(result.returncode, 0, result.stderr)


@unittest.skipUnless(shutil.which('node'), 'Node required for isolated script fixture')
class HelperScriptTests(unittest.TestCase):
    def test_shared_region_keeps_high_address_bits_and_checks_every_reply(self):
        source = (ROOT / 'iridium/apps/ios/App/Resources/madeira-jit.js').read_text()
        harness = r'''
const vm = require('vm'), assert = require('assert');
const source = JSON.parse(require('fs').readFileSync(0, 'utf8'));
let commands = [], failAt = -1;
const context = vm.createContext({send_command: command => {
  commands.push(command); return commands.length === failAt ? 'E09' : 'OK';
}});
vm.runInContext(source.split('let pid = get_pid();')[0], context);
assert(context.iridiumPrepareRegion(0x7000000000n, 0x20000000n));
assert.equal(commands.length, 32768);
assert.equal(commands[0], 'M7000000000,1:69');
assert.equal(commands.at(-1), 'M701fffc000,1:69');
commands = [];
assert(context.iridiumPrepareRegion(0x123456789abcdef0n, 0x4000n));
assert.deepEqual(commands, ['M123456789abcc000,1:69', 'M123456789abd0000,1:69']);
commands = []; failAt = 2;
assert(!context.iridiumPrepareRegion(0x7000000000n, 0xc000n));
assert.equal(commands.length, 2);
for (const [address, size] of [[0n, 1n], [-1n, 1n], [1n, 0n], [1n, 0x100000001n],
                              [0xffffffffffffffffn, 2n], [1n << 64n, 1n]]) {
  commands = []; assert(!context.iridiumPrepareRegion(address, size)); assert.equal(commands.length, 0);
}
function le(value) {
  return Array.from({length: 8}, (_, i) => Number(value >> BigInt(i * 8) & 255n).toString(16).padStart(2, '0')).join('');
}
function run(allocated, writeReply, bytes = 0x8000n, detachReply = 'OK') {
  const trace = []; let stops = 0;
  vm.runInNewContext(source, {get_pid: () => 42, log: () => {}, send_command: command => {
    trace.push(command);
    if (command.startsWith('vAttach')) return 'T05';
    if (command === 'c') return 'T05thread:abc;20:' + le(0x100000000n) + ';00:' + le(0n) +
      ';01:' + le(bytes) + ';10:' + le(stops++ === 0 ? 1n : 0n) + ';metype:6;medata:1;';
    if (command.startsWith('m')) return 'a0013ed4';
    if (command.startsWith('_M')) return allocated;
    if (command.startsWith('M')) return writeReply;
    if (command === 'D') return detachReply;
    return 'OK';
  }}, {timeout: 1000});
  return trace;
}
const success = run('7000000000', 'OK');
assert.throws(() => run('7000000000', 'OK', 0x8000n, 'E09'), /detach was not acknowledged/);
assert.deepEqual(success.filter(x => x.startsWith('M')), ['M7000000000,1:69', 'M7000004000,1:69']);
assert(success.includes('P0=0000000070000000;thread:abc;'));
for (const result of [run('7000000000', 'E09'), run('E09', 'OK'), run('not-hex', 'OK'),
                      run('7000000001', 'OK'), run('7000000000', 'OK', 0x100000001n)]) {
  assert(result.includes('P0=0000000000000000;thread:abc;'));
  assert(result.includes('D'));
}
'''
        subprocess.run(['node', '-e', harness], input=json.dumps(source), text=True, check=True, timeout=10)

    def test_first_fault_tuple_exact_64bit_fields_bounds_and_one_record(self):
        harness = r'''
const vm = require('vm');
const source = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const base = 'IRJIT2 stage=first.fault kind=stop signal=10 exception=1 code=2';
function check(packet, pc, ok, word, suffix, classification = base) {
  const logs = [];
  const context = vm.createContext({log: s => logs.push(s)});
  vm.runInContext(source, context);
  context.iridiumJITStop(packet, 'first.fault', pc, ok, word);
  context.iridiumJITStop(packet, 'first.fault', pc, ok, word);
  const expected = classification + suffix;
  if (logs.length !== 1 || logs[0] !== expected || logs[0].length > 190) throw Error(JSON.stringify(logs));
}
check('T0ametype:1;medata:2;medata:fedcba9876543210;', 'efcdab8967452301', true, 0x52800540,
      ' pc=0123456789abcdef addr=fedcba9876543210 md=2 insn=mov42');
check('T0amedata:2;medata:0XFFFFFFFFFFFFFFFF;metype:1;', 'ffffffffffffffff', true, 0x528000e0,
      ' pc=ffffffffffffffff addr=ffffffffffffffff md=2 insn=mov7');
check('T0ametype:1;medata:2;medata:0;', '0000000000000000', true, 0xd65f03c0,
      ' pc=0000000000000000 addr=0000000000000000 md=2 insn=ret');
check('T0ametype:1;medata:2;', undefined, false, 0,
      ' pc=missing addr=missing md=1 insn=unreadable');
check('T0ametype:1;', undefined, false, 0,
      ' pc=missing addr=missing md=0 insn=unreadable',
      'IRJIT2 stage=first.fault kind=stop signal=10 exception=1 code=0');
for (const address of ['SECRET', '', '10000000000000000', '1\nSECRET']) {
  check('T0ametype:1;medata:2;medata:' + address + ';', 'bad-pc', true, 0xdeadbeef,
        ' pc=invalid addr=invalid md=2 insn=other');
}
check('T0ametype:1;medata:2;medata:1234', 'bad', false, 0,
      ' pc=invalid addr=invalid md=2 insn=unreadable');
check('T0ametype:1;medata:2;medata:0123456789abcdef;medata:SECRET;medata:SECRET;', 'efcdab8967452301', true, 0,
      ' pc=0123456789abcdef addr=0123456789abcdef md=more insn=other');
const logs = [], context = vm.createContext({log: s => logs.push(s)});
vm.runInContext(source, context);
context.iridiumJITStop('T0a' + 'x'.repeat(2048), 'first.fault', 'ffffffffffffffff', true, 0);
if (logs.length) throw Error('oversized input retained');
'''
        subprocess.run(['node', '-e', harness], input=json.dumps(helper.SCRIPT_DIAGNOSTICS),
                       capture_output=True, text=True, check=True, timeout=10)

    def test_stop_prefix_first_middle_malformed_and_truncated_fields(self):
        harness = r'''
const vm = require('vm');
const source = JSON.parse(require('fs').readFileSync(0, 'utf8'));
function check(packet, expected) {
  const logs = [];
  const context = vm.createContext({log: s => logs.push(s)});
  vm.runInContext(source, context);
  context.iridiumJITStop(packet, 'first.stop');
  if (JSON.stringify(logs) !== JSON.stringify(expected ? ['IRJIT2 stage=first.stop kind=stop signal=10 ' + expected] : []))
    throw Error('classification mismatch: ' + JSON.stringify(logs));
}
check('T0ametype:1;medata:2;thread:abc;20:0000000001000000;', 'exception=1 code=2');
check('T0amedata:2;metype:1;', 'exception=1 code=2');
check('T0athread:abc;metype:1;medata:2;', 'exception=1 code=2');
check('T0ametype:0000000D;medata:000000FF;', 'exception=13 code=255');
check('T0ametype:e;medata:100;', 'exception=0 code=0');
check('T0ametype:1;medata:2', 'exception=1 code=0');
check('T0ametype:1', 'exception=0 code=0');
check('T0ametype:1z;medata:2z;', 'exception=0 code=0');
check('T0ametype:bad;metype:1;medata:invalid;medata:2;', 'exception=0 code=0');
check('T0axmetype:1;xmedata:2;', 'exception=0 code=0');
check('T0ametype:111111111;medata:111111111;', 'exception=0 code=0');
check('T0ametype:1;medata:2;' + 'x'.repeat(2048), null);
check('T0', null); check('Tgg', null); check(null, null);
'''
        subprocess.run(['node', '-e', harness], input=json.dumps(helper.SCRIPT_DIAGNOSTICS),
                       capture_output=True, text=True, check=True, timeout=10)

    def test_generated_verifier_detects_script_and_helper_drift(self):
        spec = importlib.util.spec_from_file_location('observability_frontend', ROOT / 'ci/madeira-frontend.py')
        frontend = importlib.util.module_from_spec(spec); spec.loader.exec_module(frontend)
        with tempfile.TemporaryDirectory() as directory:
            upstream = Path(directory) / 'upstream'; output = Path(directory) / 'output'
            (upstream / 'app/Madeira').mkdir(parents=True)
            (output / 'app/Madeira/Winios').mkdir(parents=True)
            (output / 'app/MadeiraJITHelper').mkdir(parents=True)
            import iridium_app_sources
            iridium_app_sources.stage(output / 'app')
            with patch.object(frontend, 'UPSTREAM', upstream), patch.object(frontend, 'OUTPUT', output), \
                 patch.object(frontend, 'check_sameboy_component'), patch.object(frontend, 'verify_pin'):
                frontend.verify()
                for name in (helper.SCRIPT, helper.HELPER, helper.MESSAGES, helper.HOST):
                    generated = output / 'app' / name; original = generated.read_text()
                    generated.write_text(original + '\n// undeclared drift\n')
                    with self.assertRaises(ValueError): frontend.verify()
                    generated.write_text(original)

    def test_overlay_keeps_debugger_command_trace_and_redacts_observations(self):
        original = (MADEIRA / helper.SCRIPT).read_text()
        patched = helper.apply('madeira-jit.js', original)
        harness = r'''
const vm = require('vm');
const input = JSON.parse(require('fs').readFileSync(0, 'utf8'));
function run(source) {
  const commands = [], logs = [];
  const stop = 'T0athread:abc;20:0000000001000000;metype:1;medata:2;secret:PAIRING_SECRET;path:/private/user;';
  vm.runInNewContext(source, { get_pid: () => 42, log: s => logs.push(s), send_command: command => {
    commands.push(command);
    if (command.startsWith('vAttach')) return 'T05secret:PAIRING_SECRET;';
    if (command.startsWith('QSetIgnored')) return 'OK';
    if (command.startsWith('QPass')) return 'E22';
    if (command === 'c') return stop;
    if (command.startsWith('m')) return '00000000';
    if (command.startsWith('vCont;C')) return 'W09';
    throw Error('unexpected command');
  }}, {timeout: 1000});
  return {commands, logs};
}
const old = run(input.original), candidate = run(input.patched);
if (JSON.stringify(old.commands) !== JSON.stringify(candidate.commands)) throw Error('debugger policy changed');
const diagnostics = candidate.logs.filter(s => s.startsWith('IRJIT2 '));
if (diagnostics.length !== 6 || diagnostics.some(s => /PAIRING_SECRET|private|thread/.test(s))) throw Error('unbounded/private diagnostics');
console.log(JSON.stringify(diagnostics));
'''
        result = subprocess.run(['node', '-e', harness], input=json.dumps(dict(original=original, patched=patched)),
                                capture_output=True, text=True, check=True, timeout=10)
        records = json.loads(result.stdout)
        self.assertIn('IRJIT2 stage=setup.pass status=error', records)
        self.assertIn('IRJIT2 stage=first.fault kind=stop signal=10 exception=1 code=2 pc=0000000100000000 addr=missing md=1 insn=other', records)
        self.assertIn('IRJIT2 stage=first.exit kind=exit signal=0 exception=0 code=9', records)

    def test_hook_drift_declines_and_helper_progress_is_filtered(self):
        for name in ['madeira-jit.js', 'MadeiraJITHelper.swift', 'JITBuiltInMessages.swift', 'JITBuiltInHost.swift']:
            with self.assertRaises(ValueError): helper.apply(name, 'changed upstream hook')
        text = helper.apply('MadeiraJITHelper.swift', (MADEIRA / helper.HELPER).read_text())
        self.assertIn('progress: { diagnostic.receive($0) }', text)
        self.assertNotIn('progress: { NSLog("[MadeiraJIT] %@", $0)', text)


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'Darwin Swift compiler required')
class HelperJournalTests(unittest.TestCase):
    def test_private_fault_survives_but_system_log_mirror_and_export_omit_locations(self):
        fixture = r'''
import Foundation
import Darwin
let fm = FileManager.default
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let app = directory.appendingPathComponent("app")
try! fm.createDirectory(at: app, withIntermediateDirectories: true)
let fault = "IRJIT2 stage=first.fault kind=stop signal=10 exception=1 code=2 pc=0123456789abcdef addr=fedcba9876543210 md=2 insn=mov42"
let publicFault = "IRJIT2 stage=first.fault kind=stop signal=10 exception=1 code=2 md=2 insn=mov42"
let file = directory.appendingPathComponent("iridium-jit-helper.log")
do {
    let writer = IridiumJITHelperDiagnostic(directory: directory, attemptID: "aabbccddeeff0011")
    for invalid in [fault + " SECRET", fault.replacingOccurrences(of: "pc=0123456789abcdef", with: "pc=SECRET"),
        fault.replacingOccurrences(of: "stage=first.fault", with: "stage=first.stop"),
        fault.replacingOccurrences(of: "insn=mov42", with: "insn=52800540"),
        fault.replacingOccurrences(of: "md=2", with: "md=999")] { writer.receive(invalid) }
    DispatchQueue.concurrentPerform(iterations: 100) { _ in writer.receive(fault) }
}
let original = try! Data(contentsOf: file)
let raw = String(decoding: original, as: UTF8.self)
let records = IridiumJITHelperSnapshot.read(in: directory)
precondition(records.count == 2 && records.last!.hasSuffix(fault))
precondition(raw.components(separatedBy: "stage=first.fault").count == 2)
precondition(original.count <= 4096 && raw.split(separator: "\n").allSatisfy { $0.utf8.count < 240 })
var status = stat(); precondition(lstat(file.path, &status) == 0 && status.st_mode & 0o777 == 0o600)
precondition(IridiumJITHelperSnapshot.publicPayload(fault) == publicFault)
for flags in ["pc=missing addr=missing md=0 insn=unreadable", "pc=invalid addr=invalid md=more insn=other"] {
    let payload = "IRJIT2 stage=first.fault kind=stop signal=0 exception=0 code=0 " + flags
    precondition(IridiumJITHelperSnapshot.validPayload(payload))
    precondition(!IridiumJITHelperSnapshot.publicPayload(payload)!.contains("pc="))
}
precondition(IridiumJITHelperSnapshot.validPayload("IRJIT2 stage=first.fault kind=stop signal=10 exception=1 code=2"))
// Scrub a previous private-form mirror as well as newly received records.
let mirror = app.appendingPathComponent("iridium-jit-helper-mirror.log")
try! original.write(to: mirror)
try! IridiumJITHelperSnapshot.mirror(records, in: app)
let mirrored = try! String(contentsOf: mirror, encoding: .utf8)
precondition(mirrored.contains(publicFault) && !mirrored.contains("pc=") && !mirrored.contains("addr="))
// Defense in depth: ordinary export/recent lines redact a raw tuple or local base
// accidentally copied into any selected app log, preserving private originals.
try! Data((fault + "\n").utf8).write(to: app.appendingPathComponent("iridium-console.log"))
let anchors = ["probe.base", "image.base", "app.image.base"].map {
    "seq=1 mono=1.0 stage=\($0) pass=0 value=81985529216486895 error=0"
}.joined(separator: "\n") + "\n"
try! Data(anchors.utf8).write(to: app.appendingPathComponent("iridium-psp-jit-stages.log"))
let exported = try! RuntimeDiagnosticLogFiles.export(in: app, destination: app)
let text = try! String(contentsOf: exported, encoding: .utf8)
precondition(text.contains(publicFault) && text.contains("Private JIT address entry redacted"))
let recent = RuntimeDiagnosticLogFiles.recentLines(in: app).joined(separator: "\n")
for value in ["pc=", "addr=", "0123456789abcdef", "fedcba9876543210", "81985529216486895"] {
    precondition(!text.contains(value) && !recent.contains(value))
}
precondition(try! Data(contentsOf: file) == original)
print("PASS private first fault exact/bounded/0600/once, read-only snapshot, legacy schema, sanitized system log/mirror/export/recent lines")
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); logs = root / 'logs'; logs.mkdir()
            main = root / 'main.swift'; main.write_text(fixture); binary = root / 'check'
            support = ROOT / 'iridium/apps/ios/MadeiraSupport'
            subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', module_cache('macosx'),
                            str(support / 'IridiumJITHelperDiagnostic.swift'),
                            str(support / 'IridiumJITHelperSnapshot.swift'),
                            str(ROOT / 'iridium/apps/ios/Iridium/RuntimeDiagnosticLogFiles.swift'),
                            str(main), '-o', str(binary)], check=True)
            result = subprocess.run([str(binary), str(logs)], capture_output=True, text=True, check=True, timeout=15)
            for value in ['0123456789abcdef', 'fedcba9876543210', 'pc=', 'addr=', 'SECRET']:
                self.assertNotIn(value, result.stderr)
            print(result.stdout.strip())

    def test_allowlist_bounds_rotation_concurrency_and_no_symlink_follow(self):
        fixture = r'''
import Foundation
func session(_ directory: URL) {
    let writer = IridiumJITHelperDiagnostic(directory: directory)
    writer.receive("framework prefix SECRET IRJIT2 stage=setup.ignore status=ok")
    writer.receive("IRJIT2 stage=first.fault kind=stop signal=10 exception=1 code=2")
    let forbidden = ["raw remote packet TOKEN", "IRJIT2 stage=setup.pass status=TOKEN",
        "IRJIT2 stage=setup.pass status=ok\nTOKEN", "IRJIT2 stage=first.stop kind=stop signal=32 exception=1 code=2",
        "IRJIT2 stage=first.stop kind=stop signal=1 exception=14 code=2",
        "IRJIT2 stage=first.stop kind=stop signal=1 exception=1 code=256",
        "IRJIT2 stage=setup.ignore status=ok " + String(repeating: "PRIVATE", count: 1000)]
    for line in forbidden { writer.receive(line) }
    let file = directory.appendingPathComponent("iridium-jit-helper.log")
    let text = try! String(contentsOf: file, encoding: .utf8)
    precondition(text.split(separator: "\n").count == 3 && !text.contains("SECRET") && !text.contains("TOKEN"))
    DispatchQueue.concurrentPerform(iterations: 1000) { _ in writer.receive("IRJIT2 stage=setup.pass status=empty") }
    let bounded = try! Data(contentsOf: file)
    precondition(bounded.count <= 4096 && String(decoding: bounded, as: UTF8.self).split(separator: "\n").count == 16)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    let rejected = IridiumJITHelperDiagnostic(directory: directory, attemptID: "TOKEN=SECRET")
    rejected.receive("IRJIT2 stage=setup.attach status=ok")
    precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("iridium-jit-helper.log").path))
}
session(directory)
let previous = try! Data(contentsOf: directory.appendingPathComponent("iridium-jit-helper.log"))
do { let writer = IridiumJITHelperDiagnostic(directory: directory); writer.receive("IRJIT2 stage=setup.attach status=stop") }
precondition(try! Data(contentsOf: directory.appendingPathComponent("iridium-jit-helper.previous.log")) == previous)
let current = directory.appendingPathComponent("iridium-jit-helper.log")
try! FileManager.default.removeItem(at: current)
let victim = directory.appendingPathComponent("victim")
try! Data("unchanged".utf8).write(to: victim)
try! FileManager.default.createSymbolicLink(at: current, withDestinationURL: victim)
do { let writer = IridiumJITHelperDiagnostic(directory: directory); writer.receive("IRJIT2 stage=setup.attach status=ok") }
precondition(try! String(contentsOf: victim, encoding: .utf8) == "unchanged")
print("PASS strict fields, secret redaction, concurrent cap, rotation and symlink refusal")
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); logs = root / 'logs'; logs.mkdir()
            main = root / 'main.swift'; main.write_text(fixture); binary = root / 'check'
            subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', module_cache('macosx'),
                            str(ROOT / 'iridium/apps/ios/MadeiraSupport/IridiumJITHelperDiagnostic.swift'),
                            str(ROOT / 'iridium/apps/ios/MadeiraSupport/IridiumJITHelperSnapshot.swift'),
                            str(main), '-o', str(binary)], check=True)
            result = subprocess.run([str(binary), str(logs)], capture_output=True, text=True, check=True, timeout=15)
            self.assertNotIn('TOKEN', result.stderr)
            self.assertNotIn('SECRET', result.stderr)


if __name__ == '__main__': unittest.main()
