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
check(IridiumRuntimeRegistry.ppsspp.id == "ppsspp")
check(IridiumRuntimeRegistry.ppsspp.platforms == [.psp])
check(try IridiumRuntimeRegistry.ppsspp.executionMode(jitAvailable: false) == .interpreter)
check(try IridiumRuntimeRegistry.ppsspp.executionMode(jitAvailable: true) == .interpreter)
#if IRIDIUM_PPSSPP
check(try IridiumRuntimeRegistry.resolve(platform: .psp, preferred: nil) == IridiumRuntimeRegistry.ppsspp)
#else
check(IridiumRuntimeRegistry.compatible(with: .psp).isEmpty)
rejects { _ = try IridiumRuntimeRegistry.resolve(platform: .psp, preferred: "ppsspp") }
#endif
rejects { _ = try IridiumRuntimeRegistry.resolve(platform: .windows, preferred: "sameboy") }
rejects { _ = try IridiumRuntimeRegistry.resolve(platform: .gameBoy, preferred: "missing") }
var owner = IridiumRuntimeOwnership()
let first = try owner.acquire(sameBoy)
rejects { _ = try owner.acquire(sameBoy) }

var intent = IridiumConsoleIntent()
check(intent.request == .play)
intent.pause() // A pause requested during boot must survive until boot finishes.
check(intent.request == .pause)
intent.resume()
check(intent.request == .play)
intent.pause()
intent.stop()
intent.resume()
check(intent.request == .stop)
intent.pause()
check(intent.request == .stop)
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
check(try store.validateROM(game) == store.rom(game))
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
let sourceDirectoryLink = temporary.appendingPathComponent("linked-directory")
try fm.createSymbolicLink(at: sourceDirectoryLink, withDestinationURL: temporary)
rejects { _ = try store.importROM(sourceDirectoryLink.appendingPathComponent("Test.gb"), into: [other]) }
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

// Small synthetic structural fixtures are not copyrighted games and are never
// executed by a core. Header validation is independent of registry availability.
func putLE(_ value: UInt64, in data: inout Data, at offset: Int, bytes: Int) {
    for index in 0..<bytes { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
}
func putBE(_ value: UInt64, in data: inout Data, at offset: Int, bytes: Int) {
    for index in 0..<bytes { data[offset + index] = UInt8(truncatingIfNeeded: value >> ((bytes - index - 1) * 8)) }
}
func put(_ bytes: [UInt8], in data: inout Data, at offset: Int) {
    data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
}
func elfFixture() -> Data {
    var data = Data(repeating: 0, count: 88)
    put([0x7f, 0x45, 0x4c, 0x46, 1, 1, 1], in: &data, at: 0)
    putLE(2, in: &data, at: 16, bytes: 2) // ET_EXEC
    putLE(8, in: &data, at: 18, bytes: 2) // MIPS
    putLE(1, in: &data, at: 20, bytes: 4)
    putLE(52, in: &data, at: 28, bytes: 4)
    putLE(52, in: &data, at: 40, bytes: 2)
    putLE(32, in: &data, at: 42, bytes: 2)
    putLE(1, in: &data, at: 44, bytes: 2)
    putLE(1, in: &data, at: 52, bytes: 4) // PT_LOAD
    putLE(84, in: &data, at: 56, bytes: 4)
    putLE(4, in: &data, at: 68, bytes: 4)
    putLE(4, in: &data, at: 72, bytes: 4)
    return data
}
func isoFixture() -> Data {
    var data = Data(repeating: 0, count: 17 * 2048)
    let pvd = 16 * 2048
    put([1] + Array("CD001".utf8) + [1], in: &data, at: pvd)
    put(Array("PSP GAME".utf8), in: &data, at: pvd + 8)
    putLE(17, in: &data, at: pvd + 80, bytes: 4)
    putBE(17, in: &data, at: pvd + 84, bytes: 4)
    putLE(2048, in: &data, at: pvd + 128, bytes: 2)
    putBE(2048, in: &data, at: pvd + 130, bytes: 2)
    return data
}
func csoFixture() -> Data {
    var data = Data(repeating: 0, count: 130)
    put(Array("CISO".utf8), in: &data, at: 0)
    putLE(24, in: &data, at: 4, bytes: 4)
    putLE(17 * 2048, in: &data, at: 8, bytes: 8)
    putLE(2048, in: &data, at: 16, bytes: 4)
    data[20] = 1
    for index in 0...17 { putLE(UInt64(96 + index * 2), in: &data, at: 24 + index * 4, bytes: 4) }
    return data
}
func pbpFixture(_ executable: Data = elfFixture()) -> Data {
    var data = Data(repeating: 0, count: 40)
    put([0, 0x50, 0x42, 0x50], in: &data, at: 0)
    putLE(0x10000, in: &data, at: 4, bytes: 4)
    for index in 0..<7 { putLE(40, in: &data, at: 8 + index * 4, bytes: 4) }
    putLE(UInt64(40 + executable.count), in: &data, at: 36, bytes: 4)
    data.append(executable)
    return data
}

let pspStore = IridiumConsoleStore(root: temporary.appendingPathComponent("psp-library"))
func pspRecord(_ ext: String) -> IridiumConsoleGame {
    IridiumConsoleGame(id: UUID(), title: "PSP fixture", platform: .psp, runtimeID: "ppsspp", fileExtension: ext, importedAt: Date())
}
func checkPSPHeader(_ data: Data, _ ext: String, valid: Bool) throws {
    let record = pspRecord(ext)
    _ = try pspStore.checked(["Games", record.id.uuidString], createDirectory: true)
    let path = try pspStore.rom(record)
    try data.write(to: path)
    if valid { check(try pspStore.validateROM(record) == path) }
    else { rejects { _ = try pspStore.validateROM(record) } }
}
let fixtures = [("elf", elfFixture()), ("iso", isoFixture()), ("cso", csoFixture()), ("pbp", pbpFixture())]
for (ext, data) in fixtures {
    try checkPSPHeader(data, ext, valid: true)
    try checkPSPHeader(Data(data.prefix(12)), ext, valid: false)
    var invalidMagic = data
    invalidMagic[ext == "iso" ? 16 * 2048 + 1 : 0] = 0xff
    try checkPSPHeader(invalidMagic, ext, valid: false)
    let source = temporary.appendingPathComponent("Original.\(ext.uppercased())")
    try data.write(to: source)
    #if IRIDIUM_PPSSPP
    let imported = try pspStore.importROM(source, into: pspStore.load())
    check(imported.platform == .psp && imported.runtimeID == "ppsspp" && imported.fileExtension == ext)
    check(try Data(contentsOf: pspStore.validateROM(imported)) == data)
    // A same-size damaged private copy must be rejected at the next launch.
    try invalidMagic.write(to: pspStore.rom(imported))
    rejects { _ = try pspStore.validateROM(imported) }
    #else
    do { _ = try pspStore.importROM(source, into: []); fatalError("Unlinked PSP import succeeded") }
    catch IridiumRuntimeError.unavailable { }
    #endif
    check(try Data(contentsOf: source) == data)
}
for offset in [4, 5, 6, 16, 18, 20, 40, 42, 44, 52] {
    var data = elfFixture(); data[offset] = 0
    try checkPSPHeader(data, "elf", valid: false)
}
for offset in [28, 56, 68] {
    var data = elfFixture(); putLE(UInt64(UInt32.max), in: &data, at: offset, bytes: 4)
    try checkPSPHeader(data, "elf", valid: false)
}
var tooManySegments = elfFixture(); putLE(129, in: &tooManySegments, at: 44, bytes: 2)
try checkPSPHeader(tooManySegments, "elf", valid: false)
var badSections = elfFixture(); putLE(1, in: &badSections, at: 48, bytes: 2)
try checkPSPHeader(badSections, "elf", valid: false)
for offset in [16 * 2048 + 8, 16 * 2048 + 84, 16 * 2048 + 129] {
    var data = isoFixture(); data[offset] = 0xff
    try checkPSPHeader(data, "iso", valid: false)
}
for offset in [4, 8, 16, 20, 21, 24, 92] {
    var data = csoFixture(); data[offset] = 0xff
    try checkPSPHeader(data, "cso", valid: false)
}
var csoZeroHeader = csoFixture(); putLE(0, in: &csoZeroHeader, at: 4, bytes: 4)
try checkPSPHeader(csoZeroHeader, "cso", valid: true)
var hugeCSO = csoFixture(); putLE(UInt64.max, in: &hugeCSO, at: 8, bytes: 8)
try checkPSPHeader(hugeCSO, "cso", valid: false)
for offset in [4, 8, 32, 36] {
    var data = pbpFixture(); putLE(UInt64(UInt32.max), in: &data, at: offset, bytes: 4)
    try checkPSPHeader(data, "pbp", valid: false)
}
var descendingPBP = pbpFixture(); putLE(41, in: &descendingPBP, at: 12, bytes: 4)
try checkPSPHeader(descendingPBP, "pbp", valid: false)
var encryptedPSP = Data(repeating: 0, count: 0x150)
put(Array("~PSP".utf8), in: &encryptedPSP, at: 0)
try checkPSPHeader(pbpFixture(encryptedPSP), "pbp", valid: true)
try checkPSPHeader(pbpFixture(Data(encryptedPSP.prefix(4))), "pbp", valid: false)
rejects { try pspRecord("zip").validate() }

// Enforce file-size limits using sparse files, without allocating gigabytes.
let oversizedInputs: [(String, UInt64)] = [("elf", 134_217_729), ("iso", 2_147_483_649)]
for (ext, size) in oversizedInputs {
    let record = pspRecord(ext)
    _ = try pspStore.checked(["Games", record.id.uuidString], createDirectory: true)
    let path = try pspStore.rom(record)
    check(fm.createFile(atPath: path.path, contents: nil))
    let handle = try FileHandle(forWritingTo: path)
    try handle.truncate(atOffset: size)
    try handle.close()
    rejects { _ = try pspStore.validateROM(record) }
}

// Version 1 remains additive. PSP records can survive a build without PPSSPP,
// while old Game Boy records and save locations remain byte-for-byte intact.
let persistedPSP = pspRecord("elf")
try pspStore.save([game, persistedPSP])
check(try pspStore.load() == [game, persistedPSP])
let pspSave = try pspStore.saveDirectory(persistedPSP)
check(pspSave.path.hasSuffix("Saves/ppsspp/" + persistedPSP.id.uuidString))
check(try pspStore.saveDirectory(persistedPSP).path == pspSave.path)
let memoryStick = pspSave.appendingPathComponent("PSP/SAVEDATA", isDirectory: true)
try fm.createDirectory(at: memoryStick, withIntermediateDirectories: true)
let pspSaved = memoryStick.appendingPathComponent("fixture.bin")
try Data([4, 5, 6]).write(to: pspSaved)
try pspStore.save([game])
check(try Data(contentsOf: pspSaved) == Data([4, 5, 6]))
check(try pspStore.load() == [game])
check(try Data(contentsOf: saved) == Data([1, 2, 3]))
let nestedLink = memoryStick.appendingPathComponent("escape")
try fm.createSymbolicLink(at: nestedLink, withDestinationURL: escapes)
rejects { _ = try pspStore.saveDirectory(persistedPSP) }
check(try fm.contentsOfDirectory(atPath: escapes.path).isEmpty)
var wrongRuntime = persistedPSP; wrongRuntime.runtimeID = "sameboy"
rejects { try wrongRuntime.validate() }
rejects { try pspStore.save([game, game]) }
check(try pspStore.load() == [game])
print("Runtime registry, JIT policy, lifecycle intent, exclusive ownership, bounded headers, import, persistence and save isolation passed")
