// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
func check(_ value: Bool) { precondition(value) }

func rejects(_ block: () throws -> Void) {
    do { try block(); fatalError("Expected rejection") } catch { }
}
let sameBoy = IridiumRuntimeRegistry.sameBoy
check(try sameBoy.executionMode(jitAvailable: false) == .interpreter)
check(try sameBoy.executionMode(jitAvailable: true) == .interpreter)
rejects { _ = try IridiumRuntimeRegistry.madeira.executionMode(jitAvailable: false) }
check(try IridiumRuntimeRegistry.madeira.executionMode(jitAvailable: true) == .jit)
let optional = IridiumRuntimeDescriptor(id: "test", name: "Test", platforms: [.gameBoy], jit: .optional,
    supportsPause: true, restartAfterStop: false)
check(try optional.executionMode(jitAvailable: false) == .interpreter)
check(try optional.executionMode(jitAvailable: true) == .jit)
check(try IridiumRuntimeRegistry.resolve(platform: .windows, preferred: nil).id == "madeira")
rejects { _ = try IridiumRuntimeRegistry.resolve(platform: .windows, preferred: "sameboy") }
rejects { _ = try IridiumRuntimeRegistry.resolve(platform: .gameBoy, preferred: "missing") }
var owner = IridiumRuntimeOwnership()
let first = try owner.acquire(sameBoy)
rejects { _ = try owner.acquire(sameBoy) }
owner.release(IridiumRuntimeLease(token: UUID(), runtimeID: first.runtimeID))
check(owner.lease == first)
owner.release(first)
let second = try owner.acquire(sameBoy)
owner.release(first)
check(owner.lease == second)
owner.release(second, restart: true)
rejects { _ = try owner.acquire(sameBoy) }

let fm = FileManager.default
let temporary = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temporary) }
let store = IridiumConsoleStore(root: temporary.appendingPathComponent("library"))
check(try store.load().isEmpty)
let input = temporary.appendingPathComponent("Test.gb")
try Data(repeating: 0, count: 32768).write(to: input)
let original = try Data(contentsOf: input)
let game = try store.importROM(input, into: [])
check(try store.load() == [game])
check(try Data(contentsOf: store.rom(game)) == original)
check(try Data(contentsOf: input) == original)
var colorData = original; colorData[0x143] = 0x80
let colorFile = temporary.appendingPathComponent("Color.gb")
try colorData.write(to: colorFile)
let color = try store.importROM(colorFile, into: store.load())
check(color.platform == .gameBoyColor)
let other = try store.importROM(input, into: store.load())
check(game.id != other.id)
check(try store.saveDirectory(game) != store.saveDirectory(other))
let saved = try store.saveDirectory(game).appendingPathComponent("battery.sav")
try Data([1, 2, 3]).write(to: saved)
try store.save([other])
check(fm.fileExists(atPath: try store.rom(game).path))
check(try Data(contentsOf: saved) == Data([1, 2, 3]))
let escapes = temporary.appendingPathComponent("outside")
try fm.createDirectory(at: escapes, withIntermediateDirectories: true)
let saveLink = try store.checked(["Saves", "sameboy", other.id.uuidString])
try fm.removeItem(at: saveLink)
try fm.createSymbolicLink(at: saveLink, withDestinationURL: escapes)
rejects { _ = try store.saveDirectory(other) }
check(try fm.contentsOfDirectory(atPath: escapes.path).isEmpty)

rejects { _ = try store.checked(["..", "outside"]) }
rejects { _ = try store.checked(["nested/path"]) }
let link = temporary.appendingPathComponent("linked.gb")
try fm.createSymbolicLink(at: link, withDestinationURL: input)
rejects { _ = try store.importROM(link, into: [other]) }
let rootLink = temporary.appendingPathComponent("root-link")
try fm.createSymbolicLink(at: rootLink, withDestinationURL: store.root)
rejects { _ = try IridiumConsoleStore(root: rootLink).load() }
let unknown = Data("{\"version\":999,\"games\":[]}".utf8)
let file = try store.checked(["library.json"])
try unknown.write(to: file)
rejects { _ = try store.load() }
rejects { try store.save([]) }
check(try Data(contentsOf: file) == unknown)
try Data("broken".utf8).write(to: file)
rejects { try store.save([]) }
check(try Data(contentsOf: file) == Data("broken".utf8))
print("Runtime registry, JIT policy, exclusive ownership, import, persistence and save isolation passed")
