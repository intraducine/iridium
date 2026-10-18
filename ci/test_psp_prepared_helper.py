"""Run the exact PSP script and typed receipt/export plumbing without a device."""
from pathlib import Path
import importlib.util
import json
import platform
import shutil
import subprocess
import tempfile
import unittest

import madeira_psp_jit as psp

ROOT = Path(__file__).resolve().parents[1]


class HelperDiagnosticTests(unittest.TestCase):
    def fixture(self):
        return (psp.script(), None,
                (ROOT / 'ci/input/check_psp_helper_diagnostics.js').read_text())

    @unittest.skipUnless(shutil.which('node'), 'Node required')
    def test_all_diagnostic_boundaries(self):
        source, baseline, harness = self.fixture()
        code = 'const [source,baseline]=JSON.parse(require("fs").readFileSync(0,"utf8"));\n' + harness
        result = subprocess.run(['node', '-e', code], input=json.dumps([source, baseline]), capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(result.stdout.strip())

    @unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'Darwin JavaScriptCore required')
    def test_sdk_javascriptcore_engine_runs_the_same_failure_and_parity_fixtures(self):
        source, baseline, harness = self.fixture()
        fixture = r'''
import Foundation
import JavaScriptCore
let inputs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [Any]
let context = JSContext()!
var failure: String?
context.exceptionHandler = { _, value in failure = value?.toString() ?? "JavaScript exception" }
let output: @convention(block) (String) -> Void = { print($0) }
context.setObject(inputs[0], forKeyedSubscript: "source" as NSString)
context.setObject(inputs[1], forKeyedSubscript: "baseline" as NSString)
context.setObject(output, forKeyedSubscript: "fixturePrint" as NSString)
context.evaluateScript("const console = { log: fixturePrint };\n" + (inputs[2] as! String))
if let failure { fputs(failure + "\n", stderr); exit(1) }
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); main = root / 'main.swift'; main.write_text(fixture)
            inputs = root / 'inputs.json'; inputs.write_text(json.dumps([source, baseline, harness]))
            binary = root / 'check'
            subprocess.run(['swiftc', '-module-cache-path', str(root/'cache'), '-framework', 'JavaScriptCore', str(main), '-o', str(binary)], check=True)
            result = subprocess.run([str(binary), str(inputs)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print('JavaScriptCore: ' + result.stdout.strip())


@unittest.skipUnless(shutil.which('node'), 'Node required')
class PreparedScriptTests(unittest.TestCase):
    def test_exact_script_acknowledgments_stops_bounds_and_owned_detach(self):
        harness = r'''
const vm = require('vm'), source = JSON.parse(require('fs').readFileSync(0, 'utf8'));
function le(x) { let out=''; for(let i=0;i<8;i++){out+=Number(x&255n).toString(16).padStart(2,'0');x>>=8n;}return out; }
function stop(command, address=0x400000000n, bytes=16777216n) {
  const seq=command===0n?0n:(address-0x400000000n)/0x2000000n+1n;
  return `T05metype:6;thread:p7b.1;20:${le(0x100000000n)};10:${le(command)};00:${le(0n)};01:${le(command===0n?0n:bytes)};02:${le(2n)};03:${le(seq)};`;
}
function run(stops, bad='', answer='E01') {
  const calls=[], logs=[]; let failed=false, allocations=0;
  const context=vm.createContext({get_pid:()=>123,log:s=>logs.push(s),prepare_memory_region:()=>{throw Error('unchecked SDK prepare');},send_command:command=>{
    calls.push(command);
    if (command.startsWith('vAttach')) return 'T05thread:1;';
    if(command===bad || (bad==='M'&&command.startsWith('M')) || (bad==='_M'&&command.startsWith('_M'))) return answer;
    if(command.startsWith('_M')) return (0x400000000n+BigInt(allocations++)*0x2000000n).toString(16);
    if(command==='c') {if(!stops.length)throw Error('unexpected continue');return stops.shift();}
    if(command.startsWith('m')) return 'a0013ed4';
    if(command.startsWith('Q')||command.startsWith('P')||command.startsWith('M')||command==='D') return 'OK';
    throw Error('unexpected command');
  }});
  try {vm.runInContext(source,context,{timeout:2000});} catch(error) {failed=true; if(!String(error).includes('PSP helper protocol failed'))throw error;}
  if(logs.some(s=>s.includes('SECRET')||s.includes('T05metype')))throw Error('remote data logged');
  return {calls,logs,failed};
}
function check(value,message){if(!value)throw Error(message);}
let r=run([stop(1n),stop(1n,0x402000000n,262144n),stop(1n,0x404000000n,262144n),stop(1n,0x406000000n,262144n),stop(0n)]);
check(!r.failed&&r.calls.filter(s=>s.startsWith('M')).length===1072,'four fixed arenas');
check(r.calls.at(-1)==='D'&&r.calls.filter(s=>s==='D').length===1,'one D, no c afterward');
check(r.logs.filter(s=>s.includes('event=prepared')).length===4&&r.logs.at(-1).includes('event=detach.ack'),'typed receipts');
check(r.calls.filter(s=>s.startsWith('_M')).join(',')==='_M1000000,rx,_M40000,rx,_M40000,rx,_M40000,rx','only four fixed RX allocations');
check(r.logs.filter(s=>s.includes('event=allocated')).length===4,'owned allocation receipts');
for(const answer of ['', 'OK', '0', '400000001', '1000000000', ((1n<<36n)-16384n).toString(16), 'f'.repeat(17), 'SECRET']) {
  r=run([stop(1n)],'_M',answer);check(r.failed&&!r.calls.some(s=>s.startsWith('M')||s.startsWith('P0=')),'invalid allocation adopted');
}
r=run([stop(1n),stop(0n)],'_M','E0e');
check(!r.failed&&r.calls.at(-1)==='D'&&r.logs.some(s=>s.includes('IRPSP3 code=39'))&&!r.logs.some(s=>s.includes('event=allocated')),'definitive allocation failure abort');
for(const packet of [stop(1n).replace('02:0200000000000000;','02:0100000000000000;'),
 stop(1n).replace('03:0100000000000000;','03:0200000000000000;'),stop(1n).replace('00:0000000000000000;','00:0000000004000000;')]) {
 r=run([packet]);check(r.failed&&!r.calls.some(s=>s.startsWith('P')||s.startsWith('_M')),'mixed version/sequence/caller VA mutated target');
}
r=run([stop(1n),stop(1n,0x402000000n,262144n)],'_M','400000000');
check(r.failed&&r.logs.filter(s=>s.includes('event=allocated')).length===1,'overlapping helper allocations accepted');

for(const answer of ['', 'OKSECRET', 'E0', 'E01SECRET']) {
  r=run([stop(1n)],'M',answer);check(r.failed&&r.calls.at(-1).startsWith('M')&&!r.calls.some(s=>s.startsWith('P0=')),'ambiguous M is terminal');
}
r=run([stop(1n),stop(0n)],'M','E01');
check(!r.failed&&r.logs.some(s=>s.includes('event=prepare.failed'))&&r.calls.at(-1)==='D','synchronized E return and owned abort');
for(const packet of [stop(1n).replace('thread:p7b.1;','thread:p7c.1;'),stop(1n).replace('20:', '20:00;20:'),stop(1n).slice(0,-1),stop(3n)]) {
  r=run([packet]);check(r.failed&&!r.calls.some(s=>s.startsWith('P20=')),'bad required stop must not advance');
}
r=run([stop(1n)],'P20=0400000001000000;thread:p7b.1;','E01');
check(r.failed&&!r.calls.some(s=>s.startsWith('M')),'P20 denial');
r=run([stop(1n)],'P0=0000000004000000;thread:p7b.1;','');
check(r.failed&&!r.logs.some(s=>s.includes('event=prepared')),'P0 denial');
r=run([stop(0n)],'D','E01');check(r.failed&&r.calls.at(-1)==='D'&&!r.logs.some(s=>s.includes('event=detach.ack')),'D denial');
for(const packet of [stop(1n).replace('00:0000000000000000;','00:0000000004000000;'),
 stop(1n).replace('03:0100000000000000;','03:0000000000000000;'),stop(1n,0x400000000n,262144n)]) {
  r=run([packet,stop(0n)]);check(r.failed&&!r.calls.some(s=>s.startsWith('P')||s.startsWith('_M')),'bad request rejected before allocation');
}
check(!source.includes('prepare_memory_region(')&&source.includes('pspSend(17, `_M'),'bounded allocation with explicit per-page ACKs');
console.log('PASS exact PSP script: 1072 sequential ACKs, first-field stops, foreign PID, malformed/truncated fields, all ACK denials, bounded extents, one owned D and no post-detach continue');
'''
        result = subprocess.run(['node', '-e', harness], input=json.dumps(psp.script()), capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(result.stdout.strip())


    def test_initial_attach_identity_and_only_owned_breakpoint_can_mutate(self):
        harness = r"""
const vm=require('vm'), source=JSON.parse(require('fs').readFileSync(0,'utf8'));
function le(x){let out='';for(let i=0;i<8;i++){out+=Number(x&255n).toString(16).padStart(2,'0');x>>=8n;}return out;}
function stop(type=6,signal='05'){return `T${signal}metype:${type};thread:p7b.1;20:${le(0x100000000n)};10:${le(1n)};00:${le(0x400000000n)};01:${le(16777216n)};`;}
function run(attach,packet='W00',instruction='a0013ed4'){
 const calls=[],logs=[];let failed=false;
 const context=vm.createContext({get_pid:()=>123,log:s=>logs.push(s),send_command:command=>{
  calls.push(command);if(command.startsWith('vAttach'))return attach;
  if(command==='c')return packet;
  if(command.startsWith('m'))return instruction;
  if(command.startsWith('vCont;C')||command.startsWith('C'))return 'W00';
  return 'OK';
 }});
 try{vm.runInContext(source,context,{timeout:500});}catch(e){failed=true;if(!String(e).includes('PSP helper protocol failed'))throw e;}
 return {calls,logs,failed};
}
function check(x,m){if(!x)throw Error(m);}
for(const attach of ['T05thread:1;','T05thread:p7b.1;','T05thread:P7B.1;','T05metype:6;thread:p7b.1;process:7b;']){
 const r=run(attach);check(!r.failed&&r.logs.some(s=>s.includes('event=ready')),'valid attach');
}
for(const attach of ['T05thread:p7c.1;','T05thread:P7C.1;','T05thread:p7b.;','T05thread:p7b.1;thread:p7b.1;',
 'T05garbage;','T05thread:1','T05thread:1;;','T05thread:;','T05thread:1;metype:6;metype:1;',
 'T05thread:1;metype:xyz;','T05thread:1;process:7c;','T05threads:p7b.1,p7c.2;', 'T05thread:1;fork:p7c.1;']){
 const r=run(attach);check(r.failed&&!r.logs.some(s=>s.includes('event=ready')),'invalid attach admitted: '+attach);
 check(!r.calls.some(s=>s==='c'||s==='D'||s.startsWith('P')||s.startsWith('M')),'attach failure mutated/continued');
}
// Same BRK bytes at a BAD_ACCESS stop must retain the original fault-forwarding route.
let r=run('T05thread:1;',stop(1,'0a'));
check(!r.failed&&r.calls.some(s=>s.startsWith('vCont;C0a:')),'BAD_ACCESS not forwarded as original SIGBUS');
check(!r.calls.some(s=>s.startsWith('P')||s.startsWith('M')||s==='D')&&!r.logs.some(s=>s.includes('event=prepared')),'BAD_ACCESS consumed as protocol');
r=run('T05thread:1;',stop(6,'0a'));
check(!r.calls.some(s=>s.startsWith('P')||s.startsWith('M')),'non-SIGTRAP consumed as protocol');
// A real breakpoint at a foreign immediate is not this owned protocol.
r=run('T05thread:1;',stop(),'c0013ed4');
check(r.failed&&!r.calls.some(s=>s.startsWith('P')||s.startsWith('M')||s==='D'),'foreign BRK mutated');
for(const packet of [stop().replace('metype:6;',''),stop().replace('metype:6;','metype:6;metype:1;'),stop().replace('metype:6;','metype:6x;')]){
 r=run('T05thread:1;',packet);check(!r.calls.some(s=>s.startsWith('P')||s.startsWith('M')),'missing/malformed type mutated');
}
console.log('PASS initial attach fields/target PID reject before ready; only SIGTRAP + EXC_BREAKPOINT + BRK f00d mutates; BAD_ACCESS at BRK bytes follows original signal forwarding; unrelated BRK declines');
"""
        result=subprocess.run(['node','-e',harness],input=json.dumps(psp.script()),capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr);print(result.stdout.strip())


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'Darwin Swift required')
class PreparedReceiptTests(unittest.TestCase):
    def test_journal_persistence_identity_transitions_and_public_projection(self):
        fixture = r'''
import Foundation
@main struct Check {
static func main() throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]), fm=FileManager.default
    let hash=String(repeating:"a",count:64), attempt="0123456789abcdef"
    let journal=IridiumPSPHelperJournal(attempt:attempt,hash:hash,pid:123,directory:root)
    precondition(journal.healthy)
    func event(_ event:String,_ seq:Int,_ bytes:Int,_ address:String="0000000000000000") {
        journal.receive("IRPSP1 event=\(event) seq=\(seq) bytes=\(bytes) addr=\(address) version=2")
    }
    event("ready",0,0)
    for seq in 1...4 {
        let address=String(format:"%016llx",0x400000000+UInt64(seq-1)*0x2000000)
        event("allocated",seq,seq==1 ? 16777216:262144,address)
        event("prepared",seq,seq==1 ? 16777216:262144,address)
    }
    precondition(!journal.receipt.sdkReturnedClean)
    event("detach.ack",4,0);journal.sdkReturned(clean:true)
    let value=IridiumPSPHelperJournal.read(directory:root)!
    precondition(value.matches(attempt:attempt,hash:hash,pid:123)&&value.sdkReturnedClean)
    precondition(!value.matches(attempt:"ffffffffffffffff",hash:hash,pid:123))
    precondition(!value.matches(attempt:attempt,hash:String(repeating:"b",count:64),pid:123))
    precondition(!value.matches(attempt:attempt,hash:hash,pid:124))
    precondition(!value.publicSummary.contains("0000000400000000") && !value.publicSummary.contains(hash))
    let file=root.appendingPathComponent("iridium-psp-helper.json")
    let mode=(try fm.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber).intValue
    precondition(mode==0o600 && (try! Data(contentsOf:file)).count<=4096)
    let telemetry=IridiumPSPHelperJournal(attempt:attempt,hash:hash,pid:123,directory:root)
    for malformed in ["IRPSP2 phase=1 code=8 length=10 fields=1 version=2 SECRET",
                      "IRPSP2 phase=7 code=8 length=10 fields=1 version=2",
                      "IRPSP2 phase=1 code=44 length=10 fields=1 version=2",
                      "IRPSP2 phase=1 code=8 length=65536 fields=1 version=2",
                      "IRPSP2 phase=1 code=8 length=10 fields=256 version=2"] {
        telemetry.receive(malformed)
        precondition(telemetry.receipt.phase==nil && !telemetry.receipt.terminal && !telemetry.receipt.ready)
    }
    telemetry.receive("IRPSP2 phase=2 code=24 length=0 fields=0 version=2")
    telemetry.receive("IRPSP2 phase=4 code=1 length=65535 fields=255 version=2")
    telemetry.sdkReturned(clean:false)
    let failure=IridiumPSPHelperJournal.read(directory:root)!
    precondition(failure.valid && failure.terminal && !failure.ready && !failure.sdkReturnedClean)
    precondition(failure.phase==4 && failure.code==30 && failure.replyLength==65535 && failure.replyFields==255)
    precondition(failure.firstIssuePhase==2 && failure.firstIssueCode==24)
    precondition(failure.publicSummary.contains("phase=4 code=30 length=65535 fields=255 issuePhase=2 issueCode=24"))
    let rejected=IridiumPSPHelperJournal(attempt:attempt,hash:hash,pid:123,directory:root)
    rejected.receive("IRPSP2 phase=1 code=8 length=23 fields=1 version=2")
    rejected.receive("IRPSP1 event=terminal seq=0 bytes=0 addr=0000000000000000 version=2")
    rejected.sdkReturned(clean:false)
    precondition(rejected.receipt.code==8 && rejected.receipt.firstIssueCode==8)
    let noDetach=IridiumPSPHelperJournal(attempt:attempt,hash:hash,pid:123,directory:root)
    noDetach.receive("IRPSP2 phase=4 code=1 length=3 fields=0 version=2")
    noDetach.sdkReturned(clean:true)
    precondition(noDetach.receipt.code==29 && noDetach.receipt.terminal && !noDetach.receipt.sdkReturnedClean)
    for code in 31...38 {
        let typed=IridiumPSPHelperJournal(attempt:attempt,hash:hash,pid:123,directory:root)
        typed.receive("IRPSP2 phase=1 code=\(code) length=879 fields=44 version=2")
        typed.sdkReturned(clean:false)
        let saved=IridiumPSPHelperJournal.read(directory:root)!
        precondition(saved.valid && saved.code==code && saved.firstIssueCode==code && saved.terminal)
    }
    var partial=value;partial.phase=1;precondition(!partial.valid)
    let preparation=IridiumPSPHelperJournal(attempt:attempt,hash:hash,pid:123,directory:root)
    preparation.receive("IRPSP1 event=ready seq=0 bytes=0 addr=0000000000000000 version=2")
    preparation.receive("IRPSP1 event=allocated seq=1 bytes=16777216 addr=0000000400000000 version=2")
    preparation.receive("IRPSP2 phase=2 code=25 length=5 fields=0 version=2")
    for malformed in ["IRPSP3 code=23 seq=2 error=14 version=2", "IRPSP3 code=23 seq=1 error=256 version=2",
                      "IRPSP3 code=22 seq=1 error=14 version=2", "IRPSP3 code=23 seq=1 error=14 version=2 SECRET"] {
        preparation.receive(malformed);precondition(preparation.receipt.preparationFailureCode==nil)
    }
    preparation.receive("IRPSP3 code=23 seq=1 error=14 version=2")
    preparation.receive("IRPSP3 code=22 seq=1 error=0 version=2") // First failure wins.
    preparation.receive("IRPSP1 event=prepare.failed seq=1 bytes=16777216 addr=0000000400000000 version=2")
    preparation.receive("IRPSP1 event=detach.ack seq=0 bytes=0 addr=0000000000000000 version=2")
    preparation.receive("IRPSP2 phase=14 code=1 length=2 fields=0 version=2")
    preparation.sdkReturned(clean:true)
    let savedPreparation=IridiumPSPHelperJournal.read(directory:root)!
    precondition(savedPreparation.sdkReturnedClean && savedPreparation.firstIssueCode==25)
    precondition(savedPreparation.preparationFailureCode==23 && savedPreparation.preparationFailureError==14)
    precondition(savedPreparation.publicSummary.contains("prepCode=23 prepSequence=1 prepError=14"))
    var invalidPreparation=savedPreparation;invalidPreparation.preparationFailureSequence=nil;precondition(!invalidPreparation.valid)
    var poisoned=failure;poisoned.firstIssuePhase=99;precondition(!poisoned.valid)
    // A receipt without optional telemetry still decodes after upgrading.
    let old=try JSONEncoder().encode(value)
    let decodedOld=try JSONDecoder().decode(IridiumPSPHelperReceipt.self,from:old)
    precondition(decodedOld.valid)
    var oldVersion=value;oldVersion.version=1;precondition(!oldVersion.valid)
    let mixed=IridiumPSPHelperJournal(attempt:attempt,hash:hash,pid:123,directory:root)
    mixed.receive("IRPSP1 event=ready seq=0 bytes=0 addr=0000000000000000 version=1")
    precondition(mixed.receipt.terminal && !mixed.receipt.ready)
    var wrongArena=value;wrongArena.arenas[1].address=wrongArena.arenas[0].address;precondition(!wrongArena.valid)
    var missing=value;missing.arenas.removeLast();precondition(!missing.valid)
    var wrongSize=value;wrongSize.arenas[0].bytes=262144;precondition(!wrongSize.valid)
    let duplicate=IridiumPSPHelperJournal(attempt:attempt,hash:hash,pid:123,directory:root)
    duplicate.receive("IRPSP1 event=ready seq=0 bytes=0 addr=0000000000000000 version=2")
    duplicate.receive("IRPSP1 event=ready seq=0 bytes=0 addr=0000000000000000 version=2")
    precondition(duplicate.receipt.terminal)
    for malformed in ["IRPSP1 event=ready seq=0", "IRPSP1 "+String(repeating:"x",count:200)] {
        let writer=IridiumPSPHelperJournal(attempt:attempt,hash:hash,pid:123,directory:root)
        writer.receive(malformed);precondition(writer.receipt.terminal)
        writer.sdkReturned(clean:true);precondition(!writer.receipt.sdkReturnedClean)
    }
    try fm.removeItem(at:file);try fm.createSymbolicLink(at:file,withDestinationURL:root.appendingPathComponent("outside"))
    precondition(IridiumPSPHelperJournal.read(directory:root)==nil)
    let linked=IridiumPSPHelperJournal(attempt:attempt,hash:hash,pid:123,directory:root);precondition(!linked.healthy)
    print("PASS real typed journal: private atomic bounded persistence, strict transitions, stale attempt/hash/PID, malformed input and link refusal; public summary omits private addresses")
}}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'main.swift'; source.write_text(fixture); binary = root / 'check'
            subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(root/'cache'),
                            str(ROOT/'iridium/apps/ios/MadeiraSupport/IridiumJITHelperSnapshot.swift'), str(psp.SUPPORT),str(source),'-o',str(binary)],check=True)
            result=subprocess.run([str(binary),str(root)],capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr);print(result.stdout.strip())


if __name__ == '__main__': unittest.main()
