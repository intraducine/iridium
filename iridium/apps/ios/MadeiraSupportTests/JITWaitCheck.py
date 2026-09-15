#!/usr/bin/env python3
"""Run the production external-JIT routing and waiting code with an app stub."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[4]
s=(root/'testrepos/Madeira/app/Madeira/StikJITHelper.swift').read_text()
lc3=(root/'iridium/apps/ios/MadeiraSupport/MadeiraLiveContainer3JIT.swift').read_text()
assert 'URLQueryItem(name: "pid", value: String(getpid()))' in lc3
body=s[s.index('    enum Route:'):s.index('    private static var pinned')]
stubs=r'''
import Foundation
struct Date: Comparable {
 static var offset: Double = 0
 var timeIntervalSince1970: Double
 init() { timeIntervalSince1970 = Foundation.Date().timeIntervalSince1970 + Self.offset }
 init(_ value: Double) { timeIntervalSince1970 = value }
 func addingTimeInterval(_ value: Double) -> Date { Date(timeIntervalSince1970 + value) }
 static func <(a: Date,b: Date) -> Bool { a.timeIntervalSince1970 < b.timeIntervalSince1970 }
}
func getpid() -> Int32 { 4242 }
var poolAttempts: [Int] = []
var available: UInt = 2048 * 1024 * 1024
func os_proc_available_memory() -> UInt { available }
var debugged = false
func jit_check_debugged() -> Bool { debugged }
final class LogStore {
 enum Level { case error }
 static let shared = LogStore()
 func log(_ text: String, level: Level? = nil) {}
}
final class UIApplication {
 static let shared = UIApplication()
 static let didBecomeActiveNotification = Notification.Name("active")
 var opened: [URL] = []
 var accepted = "stikjit"
 func canOpenURL(_ url: URL) -> Bool { url.scheme == accepted }
 func open(_ url: URL, options: [String: String], completionHandler: (Bool) -> Void) {
  opened.append(url); completionHandler(url.scheme == accepted)
 }
}
enum StikJITHelper {
 static func allocatePool(poolSize: Int) -> (rx: UnsafeMutableRawPointer, rw: UnsafeMutableRawPointer, size: Int)? {
  poolAttempts.append(poolSize / 1024 / 1024)
  guard poolSize == 128 * 1024 * 1024 else { return nil }
  let p=UnsafeMutableRawPointer(bitPattern: 4096)!
  return (p,p,poolSize)
 }
 static let persistentScriptRequestKey = "IridiumTestJITRequested"
 static let resolvedScriptBase64: String? = "YWJjKys/"
 static func consumePersistentScriptRequest() { UserDefaults.standard.removeObject(forKey: persistentScriptRequestKey) }
'''
checks=r'''
}
func tick() { RunLoop.current.run(until: Foundation.Date().addingTimeInterval(0.6)) }
func decodedGuest(_ destination: URL) -> URL {
 if destination.scheme == "stikjit" { return destination }
 let value=URLComponents(url:destination,resolvingAgainstBaseURL:false)!.queryItems!.first{$0.name=="url"}!.value!
 return URL(string:String(data:Data(base64Encoded:value)!,encoding:.utf8)!)!
}
func assertPIDRequest(_ destination: URL) {
 let guest=decodedGuest(destination)
 let items=URLComponents(url:guest,resolvingAgainstBaseURL:false)!.queryItems!
 assert(items.first{$0.name=="pid"}!.value=="4242")
 assert(items.first{$0.name=="bundle-id"} != nil)
 assert(items.first{$0.name=="script-data"}!.value=="YWJjKys/")
}
let defaults = UserDefaults.standard
let oldPool=defaults.object(forKey:"IridiumJITPoolMB")
let oldRoute=defaults.object(forKey: StikJITHelper.routeKey)
let oldDeadline=defaults.object(forKey: "IridiumJITDeadline")
defer {
 defaults.set(oldPool,forKey:"IridiumJITPoolMB")
 defaults.set(oldRoute,forKey: StikJITHelper.routeKey)
 defaults.set(oldDeadline,forKey: "IridiumJITDeadline")
 defaults.removeObject(forKey: StikJITHelper.persistentScriptRequestKey)
}
defaults.set("automatic",forKey: StikJITHelper.routeKey)
let guest=URL(string:"stikjit://enable-jit?script-data=a%2Bb%2Fc%3D")!
for scheme in ["livecontainer", "livecontainer2"] {
 let wrapped=StikJITHelper.liveContainerURL(for: guest,scheme:scheme)!
 let value=URLComponents(url:wrapped,resolvingAgainstBaseURL:false)!.queryItems![0].value!
 assert(wrapped.scheme==scheme && String(data:Data(base64Encoded:value)!,encoding:.utf8)==guest.absoluteString)
}
assert(StikJITHelper.liveContainerURL(for:guest,scheme:"https")==nil)
var results: [Bool] = []
StikJITHelper.enableJIT { results.append($0) }
assert(UIApplication.shared.opened.map{$0.scheme!} == ["livecontainer2","stikjit"])
for destination in UIApplication.shared.opened { assertPIDRequest(destination) }
debugged=true; tick(); assert(results == [true])
StikJITHelper.cancel(); tick(); assert(results == [true])
debugged=false; results=[]
StikJITHelper.enableJIT { results.append($0) }
StikJITHelper.cancel(); StikJITHelper.cancel(); tick(); assert(results == [false])
results=[]
StikJITHelper.enableJIT { results.append($0) }
Date.offset=181; tick(); assert(results == [false])
assert(StikJITHelper.lastFailure.contains("timed out"))
Date.offset=0
results=[]; defaults.set("livecontainer",forKey:StikJITHelper.routeKey)
StikJITHelper.enableJIT { results.append($0) }; assert(results == [false])
defaults.set(0,forKey:"IridiumJITPoolMB")
assert(StikJITHelper.allocateAdaptivePool()?.size == 128 * 1024 * 1024)
assert(poolAttempts == [512,256,128])
poolAttempts=[]; available=200 * 1024 * 1024
assert(StikJITHelper.allocateAdaptivePool()==nil && poolAttempts.isEmpty)
available=2048 * 1024 * 1024; defaults.set(128,forKey:"IridiumJITPoolMB")
assert(StikJITHelper.allocateAdaptivePool() != nil && poolAttempts == [128])
print("JIT PID request, pool fallback, routing, completion, cancellation, and timeout passed")
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'main.swift';exe=Path(tmp)/'check';p.write_text(stubs+body+checks)
 subprocess.run(['swiftc','-swift-version','5',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
