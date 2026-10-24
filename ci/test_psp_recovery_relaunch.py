"""Crash two processes during production recovery; use the real PSP broker gate."""
from host_tests import module_cache
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest
import madeira_jit_observability as diagnostics
import madeira_presentation as presentation
import madeira_psp_jit as psp

ROOT=Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system()=='Darwin' and shutil.which('swiftc'),'Darwin Swift required')
class RecoveryRelaunchTests(unittest.TestCase):
    def test_two_relaunches_retain_debt_until_correlated_success_and_block_psp(self):
        def generated(name):
            original=(ROOT/'ci/fixtures/madeira-build43/app/Madeira'/name).read_text()
            return psp.apply(name,diagnostics.apply(name,presentation.apply(name,original)))
        network=generated('JITNetwork.swift')
        network=network[network.index('@MainActor final class JITNetworkShortcut:'):]
        # Keep the exact production pending property and all recovery/run/callback methods.
        # The on-disk preferences endpoint is a private atomic file in this fixture.
        network=network.replace('UserDefaults.standard','FixtureDefaults.standard')
        setup=generated('JITSetup.swift')
        broker=setup[setup.index('    var pspRecoveryPending:'):setup.index('    func restorePSP(owner:')]
        fixture=r'''
import Foundation
import Darwin
protocol ObservableObject {}
@propertyWrapper struct Published<Value> { var wrappedValue:Value }
@MainActor enum MadeiraConfig {
 static func flag(_ name:String,fallback:Bool)->Bool {false}
 static func set(_ name:String,_ value:String?) {}
}
final class LogStore {
 static let shared=LogStore();enum Level {case error}
 func log(_ text:String,level:Level?=nil) {}
}
struct NWPath {
 enum Status {case satisfied};enum InterfaceType {case cellular,wifi}
 var status:Status {.satisfied};func usesInterfaceType(_ type:InterfaceType)->Bool {type == .cellular}
}
final class NWPathMonitor {var currentPath=NWPath();func start(queue:DispatchQueue) {}}
@MainActor enum LoopbackProbe {static var vpnInterfaceUp:Bool {false}}
@MainActor final class UIApplication {
 static let shared=UIApplication();var urls:[URL]=[];var opens=true
 func open(_ url:URL,completion:(Bool)->Void){urls.append(url);completion(opens)}
}
@MainActor final class FixtureDefaults {
 static let standard=FixtureDefaults()
 let url=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("defaults.json")
 func string(forKey key:String)->String? {
  guard let data=try? Data(contentsOf:url),let values=try? JSONDecoder().decode([String:String].self,from:data) else{return nil}
  return values[key]
 }
 func set(_ value:String?,forKey key:String) {
  var values:[String:String]=[:]
  if let data=try? Data(contentsOf:url),let saved=try? JSONDecoder().decode([String:String].self,from:data){values=saved}
  values[key]=value;try! JSONEncoder().encode(values).write(to:url,options:.atomic)
 }
}
NETWORK
extension JITNetworkShortcut {func fixtureTimeout(){timeout?.fire()}}
@MainActor enum SigningStatus {struct State{var debuggable=true};static let current=State()}
func ir_psp_self_trace_clear()->Bool {true}
enum IridiumJITHelperSnapshot {static func validAttemptID(_ value:String)->Bool {true}}
enum JITPairingFileStore {static func data() throws -> Data {Data([1])}}
struct MadeiraJITRequest {
 struct Response {}
 var diagnosticAttemptID:String?;var pspProtocolVersion:Int?;var pspAttemptID:String?;var pspScriptSHA256:String?
 static func enable(targetPID:Int32,pairingData:Data,scriptBase64:String)->MadeiraJITRequest {MadeiraJITRequest()}
}
@MainActor enum MadeiraBuiltInJIT {
 static func send(_ request:MadeiraJITRequest,started:@escaping ()->Void,completion:@escaping (Result<MadeiraJITRequest.Response,Error>)->Void){fatalError("fixture never starts a helper")}
}
@MainActor final class JITCoordinator {
 private var enableRequest:UUID?;var busy=false
 enum Method {case builtIn};var resolvedMethod:Method {.builtIn};var admitted=0
 func ensureLoopback(then:@escaping (Bool)->Void,stopped:@escaping (String)->Void){admitted+=1}
BROKER
}
@MainActor func callback(_ original:URL,_ key:String)->URL {
 let values=URLComponents(url:original,resolvingAgainstBaseURL:false)!.queryItems!
 return URL(string:values.first{$0.name==key}!.value!)!
}
@MainActor func checks() {
 let folder=URL(fileURLWithPath:CommandLine.arguments[1]),phase=CommandLine.arguments[2]
 let shortcut=JITNetworkShortcut.shared,app=UIApplication.shared,broker=JITCoordinator()
 let key="madeiraJITShortcutPendingDone",owed="done cellular vpn-off"
 func blocked(){precondition(broker.beginPSP(attempt:"0123456789abcdef",hash:String(repeating:"a",count:64),script:Data([1]),shouldProceed:{true},started:{},final:{_,_ in})==nil);precondition(broker.admitted==0)}
 if phase=="start" {
  shortcut.start{_ in};precondition(app.urls.count==1)
  shortcut.handle(callback(app.urls[0],"x-success"))
  precondition(FixtureDefaults.standard.string(forKey:key)==owed);blocked()
  _exit(0) // End without restoration; the production pending property is already durable.
 }
 precondition(FixtureDefaults.standard.string(forKey:key)==owed && shortcut.pspRecoveryPending)
 blocked() // Relaunch has no in-memory waiting; durable debt alone must stop admission.
 shortcut.restoreLeftover();precondition(app.urls.count==1)
 precondition(FixtureDefaults.standard.string(forKey:key)==owed);blocked()
 if phase=="relaunch1" {
  try! app.urls[0].absoluteString.write(to:folder.appendingPathComponent("stale-url"),atomically:true,encoding:.utf8)
  _exit(0) // Second termination while the actual recovery request is unresolved.
 }
 let stale=URL(string:try! String(contentsOf:folder.appendingPathComponent("stale-url"),encoding:.utf8))!
 shortcut.handle(callback(stale,"x-success"));precondition(shortcut.pspRecoveryPending);blocked()
 shortcut.handle(callback(app.urls[0],"x-cancel"));precondition(FixtureDefaults.standard.string(forKey:key)==owed);blocked()
 shortcut.restoreLeftover();shortcut.fixtureTimeout();precondition(FixtureDefaults.standard.string(forKey:key)==owed);blocked()
 app.opens=false;shortcut.restoreLeftover();precondition(FixtureDefaults.standard.string(forKey:key)==owed);blocked();app.opens=true
 shortcut.restoreLeftover();let current=app.urls.last!
 // A correlated old restoration cannot erase a different newly owed input.
 FixtureDefaults.standard.set("done replacement",forKey:key)
 shortcut.handle(callback(current,"x-success"));precondition(FixtureDefaults.standard.string(forKey:key)=="done replacement");blocked()
 shortcut.restoreLeftover();let final=app.urls.last!
 shortcut.handle(callback(current,"x-success"));precondition(shortcut.pspRecoveryPending);blocked()
 shortcut.handle(callback(final,"x-success"))
 precondition(FixtureDefaults.standard.string(forKey:key)==nil && !shortcut.pspRecoveryPending)
 let owner=broker.beginPSP(attempt:"0123456789abcdef",hash:String(repeating:"a",count:64),script:Data([1]),shouldProceed:{true},started:{},final:{_,_ in})
 precondition(owner != nil && broker.admitted==1)
 print("PASS two unclean process relaunches through production recovery and PSP admission: debt persists before callbacks; stale/cancel/timeout/open failure cannot clear it; correlated matching success alone admits PSP")
}
MainActor.assumeIsolated {checks()}
'''.replace('NETWORK',network).replace('BROKER',broker)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'main.swift';source.write_text(fixture);binary=root/'check'
            result=subprocess.run(['swiftc','-swift-version','5','-module-cache-path',module_cache('macosx'),str(source),'-o',str(binary)],capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            for phase in ['start','relaunch1','relaunch2']:
                result=subprocess.run([str(binary),str(root),phase],capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode,0,phase+'\n'+result.stdout+result.stderr)
                if result.stdout:print(result.stdout.strip())


if __name__=='__main__':unittest.main()
