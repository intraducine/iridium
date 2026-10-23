"""Execute the production PSP launch owner with explicit helper/OS boundaries."""
from host_tests import module_cache
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
BRIDGE=ROOT/'iridium/apps/ios/RuntimeBridge'


@unittest.skipUnless(platform.system()=='Darwin' and shutil.which('swiftc'), 'Darwin Swift required')
class PreparedLaunchTests(unittest.TestCase):
    def test_receipts_restoration_failure_cancel_foreign_owner_and_late_probe(self):
        native=r'''
#include "IRPSPNativeBridge.h"
#include <stdlib.h>
#include <assert.h>
#include <errno.h>
#include <pthread.h>
extern int fixture_mode(void);
extern void fixture_prepared(void *,unsigned long,unsigned);
extern void fixture_sdk_returned(void);
extern void fixture_record(int);
bool ir_psp_self_trace_clear(void) { return fixture_mode()!=1; }
IRPSPTeardownObservation *ir_psp_teardown_capture(void) { return malloc(1); }
bool ir_psp_self_trace_clear_diagnostic(IRPSPObservationDiagnostic *r) {
    if(fixture_mode()==1||fixture_mode()==14) {
        r->failure=IR_PSP_OBSERVATION_TRACE_QUERY;r->code=EACCES;r->count=0;return false;
    }
    return true;
}
static pthread_t captured_worker;
static unsigned observations;
void fixture_worker_check(void) { assert(pthread_equal(pthread_self(),captured_worker)); }
IRPSPTeardownObservation *ir_psp_teardown_capture_diagnostic(IRPSPObservationDiagnostic *r) {
    if(!ir_psp_self_trace_clear_diagnostic(r))return NULL;
    captured_worker=pthread_self();observations=0;
    if(fixture_mode()==16){r->failure=IR_PSP_OBSERVATION_UNKNOWN_ROUTE;r->count=1;return NULL;}
    if(fixture_mode()==13){r->failure=IR_PSP_OBSERVATION_HOST_ROUTES;r->code=4;r->count=14;return NULL;}
    return malloc(1);
}
void ir_psp_teardown_free(IRPSPTeardownObservation *p) { free(p); }
bool ir_psp_teardown_matches_diagnostic(IRPSPTeardownObservation *p,IRPSPObservationDiagnostic *r) {
    fixture_worker_check();observations++;
    bool ok=p&&fixture_mode()!=5&&!(fixture_mode()==15&&observations==2);
    if(!ok&&r){r->failure=IR_PSP_OBSERVATION_TASK_ROUTES;r->code=4;r->count=14;}
    return ok;
}
bool ir_psp_teardown_matches(IRPSPTeardownObservation *p) {return ir_psp_teardown_matches_diagnostic(p,NULL);}
static unsigned sequence;
void *ir_psp_owned_allocate_region(unsigned long bytes,unsigned ordinal) {
    fixture_worker_check();assert(ordinal==++sequence);
    void *address=(void *)(0x400000000ULL+ordinal*0x2000000ULL);
    fixture_prepared(address,bytes,ordinal);return (fixture_mode()==3||fixture_mode()==23||fixture_mode()==26||(fixture_mode()==32&&ordinal==2))?NULL:address;
}
int ir_psp_owned_detach(void) { fixture_worker_check();fixture_record(1);fixture_sdk_returned();return 0; }
int ir_psp_native_exec_prepare(const char *component,const IRPSPExecHost *h,IRPSPJITDiagnostic *j) {
    (void)component;(void)j;sequence=0;
    if(!h||h->version!=IR_PSP_EXEC_VERSION||!h->admission||!h->attempt||!h->prepare||!h->detach)return IR_PSP_EXEC_IDENTITY;
    for(unsigned i=1;i<=4;i++) {
        void *owned=NULL;int result=h->prepare(h->context,&owned,i==1?16777216:262144,i);
        if(result==IR_PSP_EXEC_UNCERTAIN)assert(!owned);
        if(!result)assert(owned==(void *)(0x400000000ULL+i*0x2000000ULL));
        if(result)return result;
    }
    return 0;
}
int ir_psp_native_exec_detach(uint64_t a) { (void)a;return ir_psp_owned_detach(); }
int ir_psp_native_exec_shutdown(const IRPSPExecShutdown *r) { fixture_record(2);return r&&r->flags==63?0:1; }
int ir_psp_native_exec_restored(uint64_t a,bool ok) { (void)a;fixture_record(3);return ok?0:1; }
int ir_psp_native_exec_restored_diagnostic(uint64_t a,bool ok,IRPSPJITDiagnostic *j) { (void)j;fixture_worker_check();return ir_psp_native_exec_restored(a,ok); }
void ir_psp_native_exec_cancel(uint64_t a) { (void)a;fixture_record(4); }
int ir_psp_native_exec_end(uint64_t a) { (void)a;fixture_worker_check();fixture_record(5);return 0; }
'''
        fixture=r'''
import Foundation
import CryptoKit
@_silgen_name("fixture_worker_check") func fixtureWorkerCheck()
final class Environment: @unchecked Sendable {
    static let shared=Environment()
    let lock=NSLock(), parked=DispatchSemaphore(value:0)
    var mode:Int32=0,receipt:IridiumPSPHelperReceipt?,events:[String]=[]
    var cancelLaunch:(@Sendable () -> Void)?
    func record(_ event:String) { lock.lock();events.append(event);lock.unlock() }
    func records()->[String] { lock.lock();defer{lock.unlock()};return events }
    func value()->IridiumPSPHelperReceipt? {lock.lock();defer{lock.unlock()};return receipt}
}
@_cdecl("fixture_mode") func fixtureMode()->Int32 {Environment.shared.mode}
@_cdecl("fixture_record") func fixtureRecord(_ code:Int32) {
    Environment.shared.record([1:"target.return",2:"shutdown.receipt",3:"restored.receipt",4:"cancel.admission",5:"end"] [code]!)
}
@_cdecl("fixture_prepared") func fixturePrepared(_ address:UnsafeMutableRawPointer?,_ bytes:UInt,_ sequence:UInt32) {
    let e=Environment.shared;e.record("prepare.\(sequence)");e.lock.lock();defer{e.lock.unlock()}
    let allocationFailed=e.mode==26 || (e.mode==32 && sequence==2)
    let failed=e.mode==3 || allocationFailed
    e.receipt!.stage=failed ? "prepare.failed":"prepared";e.receipt!.sequence=Int(sequence)
    e.receipt!.bytes=Int(bytes);e.receipt!.address=allocationFailed ? nil:String(format:"%016llx",UInt64(UInt(bitPattern:address)))
    if !allocationFailed {e.receipt!.arenas.append(IridiumPSPHelperArena(sequence:Int(sequence),bytes:Int(bytes),address:e.receipt!.address!))}
    if !failed {e.receipt!.preparedCount=Int(sequence)}
    if e.mode==20 {e.receipt!.address="0000000400000000"}
    if e.mode==21 && sequence==2 {e.receipt!.arenas[1].address=e.receipt!.arenas[0].address}
    if e.mode==22 {e.receipt!.arenas=[]}
    if e.mode==24 {e.receipt!.bytes+=1}
    if e.mode==25 {e.receipt!.version=1}
    if e.mode==27 {e.receipt!.sequence+=1}
    if e.mode==28 {e.receipt!.targetPID+=1}
    if e.mode==29 {e.receipt!.scriptSHA256=String(repeating:"b",count:64)}
    if e.mode==30 {e.receipt!.attempt="ffffffffffffffff"}
    if e.mode==35 && sequence==2 {e.receipt!.arenas[0].address="0000000400000000"}
    if e.mode==18 && sequence==2 {e.cancelLaunch?()}
}
@_cdecl("fixture_sdk_returned") func fixtureSDKReturned() {
    DispatchQueue.main.async {
        let e=Environment.shared;e.lock.lock();e.receipt!.detachAcknowledged=true;e.receipt!.sdkReturnedClean=e.mode != 4
        e.receipt!.terminal=e.mode==4;e.receipt!.stage=e.mode==4 ? "terminal":"sdk.return"
        if e.mode==33 {e.receipt!.arenas[0].address="0000000400000000"}
        if e.mode==34 {e.receipt!.preparedCount-=1}
        e.receipt!.address=nil;e.receipt!.bytes=0;e.receipt!.sequence=e.receipt!.preparedCount;let receipt=e.receipt!;e.lock.unlock()
        e.record("original.sdk.return");JITCoordinator.shared.final? (true,.success(.init(success:e.mode != 4,diagnosticAttemptID:receipt.attempt,pspReceipt:receipt)))
    }
}
enum MadeiraJITRequest { struct Response { let success:Bool;let diagnosticAttemptID:String?;let pspReceipt:IridiumPSPHelperReceipt? } }
enum StikJITHelper { static let pspScriptData=Data("IRIDIUM_PSP_PREPARED_V2 fixture".utf8) }
enum RuntimeDiagnosticLogFiles { static func writeConsoleLine(_ line:String) {} }
@MainActor final class IridiumJITWorkerReceipt { var returned=false }
final class IridiumJITDiagnostic: @unchecked Sendable {
    func mark(_ stage:IRJITDiagnosticStage,pass:UInt32=0,value:Int64=0,error:Int32=0,completed:@escaping (Bool)->Void={_ in}) {
        if stage==IR_JIT_ACTIVATION_ENTER {Environment.shared.record("durable.attempt")}
        if stage==IR_JIT_OBSERVATION_FAILED {Environment.shared.record("observation.\(pass).\(value).\(error)")}
        if stage==IR_JIT_FALLBACK {Environment.shared.record("fallback.\(value)")}
        DispatchQueue.main.async {completed(![10,14].contains(Environment.shared.mode))}
    }
    func prepare(component:String,host:UnsafePointer<IRPSPExecHost>)->Int32 {ir_psp_native_exec_prepare(component,host,nil)}
    func restored(admission:UInt64)->Int32 {ir_psp_native_exec_restored_diagnostic(admission,true,nil)}
    func check(component:String)->Int32 {
        fixtureWorkerCheck();Environment.shared.record("probe")
        if Environment.shared.mode==8 {Environment.shared.parked.wait()}
        return Environment.shared.mode==7 ? 0:1
    }
}
@MainActor final class JITCoordinator {
    static let shared=JITCoordinator()
    var owner:UUID?,final:((Bool,Result<MadeiraJITRequest.Response,Error>)->Void)?
    var pspRecoveryPending:Bool { Environment.shared.mode==12 }
    func beginPSP(attempt:String,hash:String,script:Data,shouldProceed:@escaping ()->Bool,started:@escaping ()->Void,final:@escaping (Bool,Result<MadeiraJITRequest.Response,Error>)->Void)->UUID? {
        let e=Environment.shared;e.record("begin.helper");precondition(e.records().first=="durable.attempt")
        guard owner==nil,shouldProceed() else{return nil}
        let token=UUID();owner=token;self.final=final
        e.lock.lock();e.receipt=IridiumPSPHelperReceipt(attempt:attempt,scriptSHA256:e.mode==11 ? String(repeating:"b",count:64):hash,targetPID:getpid(),stage:"ready",ready:true);if e.mode==19 {e.receipt!.version=1};e.lock.unlock()
        if e.mode==2 {final(true,.failure(CancellationError()))} else {started()}
        return token
    }
    func restorePSP(owner:UUID,completion:@escaping (Bool)->Void) {
        precondition(self.owner==owner);Environment.shared.record("network.restore")
        if Environment.shared.mode==17 {
            DispatchQueue.main.async {Environment.shared.cancelLaunch?();completion(true)}
        } else {completion(Environment.shared.mode != 6)}
    }
    func releasePSP(owner:UUID) {precondition(self.owner==owner);self.owner=nil;Environment.shared.record("release.helper")}
}
@MainActor enum MadeiraBuiltInJIT {
    static func pspSnapshot(attempt:String,completion:@escaping (IridiumPSPHelperReceipt?)->Void) {completion(Environment.shared.value())}
}
@main struct Check {
    @MainActor static func main() async {
        var retained:[IridiumPSPExecutableLaunch]=[]
        for mode:Int32 in [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,32,33,34,35] {
            let e=Environment.shared;e.mode=mode;e.events=[];e.receipt=nil;e.cancelLaunch=nil
            JITCoordinator.shared.owner=nil;JITCoordinator.shared.final=nil
            let diagnostic=IridiumJITDiagnostic()
            let launch=IridiumPSPExecutableLaunch(diagnostic:diagnostic,component:"fixture")
            e.cancelLaunch={ [weak launch] in launch?.cancel() }
            if mode==9 {launch.cancel()}
            let outcome:IridiumPSPExecutableLaunch.Outcome=await withCheckedContinuation { continuation in
                launch.completed={outcome in e.record("terminal.callback");continuation.resume(returning:outcome)};launch.start()
            }
            retained.append(launch)
            if mode==8 {e.parked.signal();try! await Task.sleep(nanoseconds:100000000)}
            let events=e.records()
            switch outcome {
            case .ready:
                precondition(mode==0 && JITCoordinator.shared.owner==nil)
                for (a,b) in [("durable.attempt","begin.helper"),("prepare.4","target.return"),("original.sdk.return","shutdown.receipt"),("shutdown.receipt","network.restore"),("network.restore","restored.receipt"),("restored.receipt","probe"),("probe","release.helper")] {
                    precondition(events.firstIndex(of:a)!<events.firstIndex(of:b)!,"ordering: \(events)")
                }
            case .fallback:
                precondition([1,3,7,9,10,13,14,16,17,18,26,32].contains(mode) && JITCoordinator.shared.owner==nil)
                if [1,9,10,13,14,16].contains(mode) {precondition(!events.contains("begin.helper") && !events.contains("probe"))}
                let reason:Int64=[1:1,3:6,7:7,9:2,10:3,13:1,14:1,16:1,17:2,18:2,26:6,32:6][mode]!
                precondition(events.firstIndex(of:"fallback.\(reason)")! < events.firstIndex(of:"terminal.callback")!)
                if [1,14].contains(mode) {precondition(events.first=="observation.1.0.13")}
                if mode==13 {precondition(events.first=="observation.5.14.4")}
                if mode==16 {precondition(events.first=="observation.15.1.0" && !events.contains("begin.helper"))}
                if [3,17,18,26,32].contains(mode) {precondition(events.contains("end") && !events.contains("probe"))}
                if mode==18 {precondition(events.contains("prepare.2") && !events.contains("prepare.3"))}
            case .restart:
                precondition([2,4,5,6,8,11,12,15,19,20,21,22,23,24,25,27,28,29,30,33,34,35].contains(mode))
                precondition(mode==12 ? JITCoordinator.shared.owner==nil:JITCoordinator.shared.owner != nil)
                precondition(!events.contains("release.helper") && !events.contains("end"))
                if mode==19 {precondition(!events.contains("prepare.1"))}
                if mode==12 {precondition(!events.contains("begin.helper") && !events.contains("durable.attempt"))}
                if mode != 8 {precondition(!events.contains("probe"))}
                if mode==15 {precondition(events.contains("restored.receipt") && events.contains("observation.6.14.4"))}
            }
        }
        print("PASS production PSP launch owner: durable admission, synchronous callback ordering, four receipts, distinct target/SDK/shutdown/restoration gates, foreign/stale decline, definite fallback, early helper failure, failed restoration and retained ownership after late probe return")
        withExtendedLifetime(retained){}
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'boundary.c').write_text(native);(root/'main.swift').write_text(fixture)
            subprocess.run(['clang','-I',str(BRIDGE),'-c',str(root/'boundary.c'),'-o',str(root/'boundary.o')],check=True)
            command=['swiftc','-swift-version','5','-parse-as-library','-module-cache-path',module_cache('macosx'),'-import-objc-header',str(BRIDGE/'IRPSPNativeBridge.h'),str(ROOT/'iridium/apps/ios/MadeiraSupport/IridiumJITHelperSnapshot.swift'),str(ROOT/'iridium/apps/ios/MadeiraSupport/IridiumPSPHelperProtocol.swift'),str(ROOT/'iridium/apps/ios/RuntimeSupport/IridiumPSPExecutableLaunch.swift'),str(root/'main.swift'),str(root/'boundary.o'),'-o',str(root/'check')]
            result=subprocess.run(command,capture_output=True,text=True,timeout=90);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            result=subprocess.run([str(root/'check')],capture_output=True,text=True,timeout=25);self.assertEqual(result.returncode,0,result.stdout+result.stderr);print(result.stdout.strip())


if __name__=='__main__':unittest.main()
