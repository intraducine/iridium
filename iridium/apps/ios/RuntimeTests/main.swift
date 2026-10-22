// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
func check(_ value: Bool, line: UInt = #line) { precondition(value, "Check failed at line \(line)") }

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
check(try IridiumRuntimeRegistry.ppsspp.executionMode(jitAvailable: true) == .jit)
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
check(!game.pspJITEnabled && game.pspJIT == nil)
var gameWithPSPFlag = game; gameWithPSPFlag.pspJIT = true
check(!gameWithPSPFlag.pspJITEnabled) // Other platforms never acquire PSP JIT.
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
    check(!imported.pspJITEnabled && imported.pspJIT == nil)
    var enabled = imported; enabled.pspJIT = true
    var records = try pspStore.load()
    records[records.firstIndex { $0.id == enabled.id }!] = enabled
    try pspStore.save(records)
    check(try pspStore.load().first { $0.id == enabled.id }!.pspJITEnabled)
    let oldRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(imported)) as! [String: Any]
    check(oldRecord["pspJIT"] == nil)
    check(try !JSONDecoder().decode(IridiumConsoleGame.self, from: JSONSerialization.data(withJSONObject: oldRecord)).pspJITEnabled)
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

// Phase 3 headers exercise the shipping parser without executing guest code.
func inspectPhase3(_ bytes: Data, _ ext: String, _ expected: IridiumPlatform?, preferred: IridiumPlatform? = nil) throws {
    let path = temporary.appendingPathComponent("phase3-fixture." + ext)
    try bytes.write(to: path)
    if let expected { check(try IridiumROMInspection.inspect(path, fileExtension: ext, preferredPlatform: preferred).platform == expected) }
    else { rejects { _ = try IridiumROMInspection.inspect(path, fileExtension: ext, preferredPlatform: preferred) } }
}
var ps2ELF = elfFixture(); putLE(0x20924001, in: &ps2ELF, at: 36, bytes: 4)
try inspectPhase3(ps2ELF, "elf", .playStation2)
var dcELF = elfFixture(); putLE(42, in: &dcELF, at: 18, bytes: 2)
try inspectPhase3(dcELF, "elf", .dreamcast)
var ps2ISO = isoFixture(); put(Array(repeating: 32, count: 32), in: &ps2ISO, at: 16 * 2048 + 8)
put(Array("PLAYSTATION".utf8), in: &ps2ISO, at: 16 * 2048 + 8)
try inspectPhase3(ps2ISO, "iso", .playStation2)
var gc = Data(repeating: 0, count: 2048); putBE(0xc2339f3d, in: &gc, at: 28, bytes: 4)
try inspectPhase3(gc, "gcm", .gameCube); try inspectPhase3(gc, "iso", .gameCube)
var wii = Data(repeating: 0, count: 2048); putBE(0x5d1c9ea3, in: &wii, at: 24, bytes: 4)
try inspectPhase3(wii, "iso", .wii); try inspectPhase3(wii, "gcm", nil)
var wad = Data(repeating: 0, count: 64 + 0x2c0 + 0x200)
putBE(32, in: &wad, at: 0, bytes: 4); putBE(0x4973, in: &wad, at: 4, bytes: 2)
putBE(0x2a4, in: &wad, at: 16, bytes: 4); putBE(0x1e4, in: &wad, at: 20, bytes: 4)
try inspectPhase3(wad, "wad", .wii)
try inspectPhase3(Data(wad.prefix(64)), "wad", nil)
var badWad = wad; putBE(0xffffffff, in: &badWad, at: 24, bytes: 4)
try inspectPhase3(badWad, "wad", nil)
putBE(0x6962, in: &badWad, at: 4, bytes: 2)
try inspectPhase3(badWad, "wad", nil)

var dol = Data(repeating: 0, count: 260)
putBE(256, in: &dol, at: 0, bytes: 4); putBE(4, in: &dol, at: 0x90, bytes: 4)
putBE(0x80003100, in: &dol, at: 0xe0, bytes: 4)
try inspectPhase3(dol, "dol", .gameCube); try inspectPhase3(dol, "dol", .wii, preferred: .wii)
var badDOL = dol; putBE(5, in: &badDOL, at: 0x90, bytes: 4)
try inspectPhase3(badDOL, "dol", nil)
var rvz = Data(repeating: 0, count: 0x48 + 0xdc); put([0x52,0x56,0x5a,1], in: &rvz, at: 0)
putBE(0xdc, in: &rvz, at: 12, bytes: 4); putBE(2, in: &rvz, at: 0x48, bytes: 4)
putBE(0x5d1c9ea3, in: &rvz, at: 0x48 + 40, bytes: 4)
try inspectPhase3(rvz, "rvz", .wii, preferred: .wii)
var threeDSX = Data(repeating: 0, count: 40); put(Array("3DSX".utf8), in: &threeDSX, at: 0)
putLE(32, in: &threeDSX, at: 4, bytes: 2); putLE(8, in: &threeDSX, at: 6, bytes: 2)
try inspectPhase3(threeDSX, "3dsx", .nintendo3DS)
threeDSX[4] = 0xff; try inspectPhase3(threeDSX, "3dsx", nil)
for (ext, magic) in [("3ds", "NCSD"), ("cci", "NCSD"), ("cxi", "NCCH"), ("app", "NCCH")] {
    var cartridge = Data(repeating: 0, count: 512)
    put(Array(magic.utf8), in: &cartridge, at: 256); putLE(1, in: &cartridge, at: 260, bytes: 4)
    try inspectPhase3(cartridge, ext, .nintendo3DS)
    putLE(2, in: &cartridge, at: 260, bytes: 4); try inspectPhase3(cartridge, ext, nil)
}
var cdi = Data(repeating: 0, count: 512)
putLE(0x80000006, in: &cdi, at: 504, bytes: 4); putLE(256, in: &cdi, at: 508, bytes: 4)
try inspectPhase3(cdi, "cdi", .dreamcast)
var chd = Data(repeating: 0, count: 512)
put(Array("MComprHD".utf8), in: &chd, at: 0); putBE(124, in: &chd, at: 8, bytes: 4)
putBE(5, in: &chd, at: 12, bytes: 4); putBE(1024, in: &chd, at: 32, bytes: 8)
putBE(2448, in: &chd, at: 56, bytes: 4)
try inspectPhase3(chd, "chd", nil)
try inspectPhase3(chd, "chd", .dreamcast, preferred: .dreamcast)
try inspectPhase3(chd, "chd", .playStation2, preferred: .playStation2)
func arcadeZIP(_ filename: String = "test.bin") -> Data {
    let name = Array(filename.utf8)
    var local = Data(repeating: 0, count: 30 + name.count + 4)
    put([0x50,0x4b,3,4], in: &local, at: 0); putLE(20, in: &local, at: 4, bytes: 2)
    putLE(4, in: &local, at: 18, bytes: 4); putLE(4, in: &local, at: 22, bytes: 4)
    putLE(UInt64(name.count), in: &local, at: 26, bytes: 2); put(name, in: &local, at: 30)
    var central = Data(repeating: 0, count: 46 + name.count)
    put([0x50,0x4b,1,2], in: &central, at: 0); putLE(20, in: &central, at: 6, bytes: 2)
    putLE(4, in: &central, at: 20, bytes: 4); putLE(4, in: &central, at: 24, bytes: 4)
    putLE(UInt64(name.count), in: &central, at: 28, bytes: 2); put(name, in: &central, at: 46)
    var end = Data(repeating: 0, count: 22); put([0x50,0x4b,5,6], in: &end, at: 0)
    putLE(1, in: &end, at: 8, bytes: 2); putLE(1, in: &end, at: 10, bytes: 2)
    putLE(UInt64(central.count), in: &end, at: 12, bytes: 4); putLE(UInt64(local.count), in: &end, at: 16, bytes: 4)
    return local + central + end
}
try inspectPhase3(arcadeZIP(), "zip", .arcade)
for name in ["../test.bin", "folder/test.bin", "\\escape.bin", ".hidden", "bad\0.bin"] { try inspectPhase3(arcadeZIP(name), "zip", nil) }
var badZIP = arcadeZIP(); badZIP[30] = 0x66
try inspectPhase3(badZIP, "zip", nil) // Central/local identity mismatch.
badZIP = arcadeZIP(); putLE(0xa0000000, in: &badZIP, at: 42 + 38, bytes: 4)
try inspectPhase3(badZIP, "zip", nil) // Unix symbolic-link entry.

check(Set(IridiumConsoleSystem.all.map(\.id)) == Set(IridiumRuntimeRegistry.all.filter { $0.id != "madeira" }.map(\.id)))
#if IRIDIUM_PPSSPP
check(IridiumConsoleSystem.system(for: .psp)?.extensions == ["elf", "iso", "cso", "pbp"])
#else
check(IridiumConsoleSystem.system(for: .psp) == nil)
#endif
for system in IridiumConsoleSystem.all {
    check(IridiumConsoleSystem.system(titled: system.title)?.id == system.id)
    for platform in system.platforms {
        check(IridiumConsoleSystem.system(for: platform)?.id == system.id)
        check(try IridiumRuntimeRegistry.resolve(platform: platform, preferred: system.id).id == system.id)
        check(!system.formats(for: platform).isEmpty)
    }
}

#if IRIDIUM_PHASE3 && IRIDIUM_PPSSPP
for (platform, runtime) in [(IridiumPlatform.gameCube, "dolphin"), (.wii, "dolphin"), (.nintendo3DS, "azahar"), (.playStation2, "play"), (.dreamcast, "flycast"), (.arcade, "flycast")] {
    check(try IridiumRuntimeRegistry.resolve(platform: platform, preferred: nil).id == runtime)
}
rejects { _ = try IridiumRuntimeRegistry.play.executionMode(jitAvailable: false) }
rejects { _ = try IridiumRuntimeRegistry.dolphin.executionMode(jitAvailable: false) }
check(try IridiumRuntimeRegistry.dolphin.executionMode(jitAvailable: true) == .jit)
rejects { _ = try IridiumRuntimeRegistry.flycast.executionMode(jitAvailable: false) }
check(Set(IridiumConsoleSystem.all.map(\.id)).isSuperset(of: ["dolphin", "azahar", "play", "flycast"]))
check(IridiumConsoleSystem.system(for: .arcade)?.formats(for: .arcade) == ["zip"])
check(IridiumConsoleSystem.system(for: .dreamcast)?.formats(for: .dreamcast).contains("zip") == false)
check(IridiumConsoleSystem.system(for: .nintendo3DS)?.extensions.contains("3ds") == true)
check(IridiumConsoleSystem.system(for: .wii)?.formats(for: .wii).contains("gcm") == false)
let chosenStore = IridiumConsoleStore(root: temporary.appendingPathComponent("chosen-system"))
let chosenSource = temporary.appendingPathComponent("chosen.elf")
try ps2ELF.write(to: chosenSource)
rejects { _ = try chosenStore.importROM(chosenSource, into: [], preferredPlatform: .dreamcast) }
check(try chosenStore.load().isEmpty)
let chosenPS2 = try chosenStore.importROM(chosenSource, into: [], preferredPlatform: .playStation2)
check(chosenPS2.platform == .playStation2 && chosenPS2.runtimeID == "play")
check(try chosenStore.validateROM(chosenPS2) == chosenStore.rom(chosenPS2))
let advancedStore = IridiumConsoleStore(root: temporary.appendingPathComponent("advanced"))
let arcadeSource = temporary.appendingPathComponent("legal-fixture.zip")
try arcadeZIP().write(to: arcadeSource)
let arcade = try advancedStore.importROM(arcadeSource, into: [])
check(arcade.platform == .arcade && arcade.originalFilename == "legal-fixture.zip")
check(try advancedStore.rom(arcade).lastPathComponent == "legal-fixture.zip")
check(try advancedStore.validateROM(arcade) == advancedStore.rom(arcade))
let systemRoot = try advancedStore.systemDirectory(arcade)
check(systemRoot.path.hasSuffix("System/flycast"))
let anotherArcade = try advancedStore.importROM(arcadeSource, into: advancedStore.load())
check(try advancedStore.systemDirectory(anotherArcade).path == systemRoot.path)
check(try advancedStore.saveDirectory(arcade) != advancedStore.saveDirectory(anotherArcade))
try fm.createSymbolicLink(at: systemRoot.appendingPathComponent("escape"), withDestinationURL: escapes)
rejects { _ = try advancedStore.systemDirectory(arcade) }
#else
check(IridiumRuntimeRegistry.compatible(with: .playStation2).isEmpty)
#endif
print("Runtime registry, JIT policy, lifecycle intent, exclusive ownership, bounded headers, import, persistence and save isolation passed")

// The selected manifest's exact track names survive import and relaunch.
let discFolder = temporary.appendingPathComponent("Disc Set")
try fm.createDirectory(at: discFolder, withIntermediateDirectories: true)
for name in ["track 01.bin", "track02.raw", "track03.bin"] {
    try Data(repeating: 0, count: 2352).write(to: discFolder.appendingPathComponent(name))
}
let gdiSource = discFolder.appendingPathComponent("Homebrew.gdi")
try Data("3\n1 0 4 2352 \"track 01.bin\" 0\n2 450 0 2352 track02.raw 0\n3 45000 4 2352 track03.bin 0\n".utf8).write(to: gdiSource)
check(try IridiumGameFileDetection.platforms(gdiSource, selectedFiles: [discFolder]) == [.dreamcast])
rejects { _ = try IridiumDiscSet(gdiSource, selectedFiles: [gdiSource]) }
let selectedTracks = try fm.contentsOfDirectory(at: discFolder, includingPropertiesForKeys: nil)
check(try IridiumDiscSet(gdiSource, selectedFiles: selectedTracks).filenames.count == 3)
#if IRIDIUM_PHASE3 && IRIDIUM_PPSSPP
let discStore = IridiumConsoleStore(root: temporary.appendingPathComponent("disc-library"))
let importedDisc = try discStore.importROM(gdiSource, into: [], selectedFiles: [discFolder])
check(importedDisc.platform == .dreamcast && importedDisc.originalFilename == "Homebrew.gdi")
check(try discStore.validateROM(importedDisc) == discStore.rom(importedDisc))
for name in ["track 01.bin", "track02.raw", "track03.bin"] {
    let copied = try discStore.rom(importedDisc).deletingLastPathComponent().appendingPathComponent(name)
    check(try Data(contentsOf: copied) == Data(contentsOf: discFolder.appendingPathComponent(name)))
}
#endif
let cueSource = discFolder.appendingPathComponent("Homebrew.cue")
try Data("FILE \"track 01.bin\" BINARY\n TRACK 01 MODE1/2352\n INDEX 01 00:00:00\n".utf8).write(to: cueSource)
check(try IridiumGameFileDetection.platforms(cueSource, selectedFiles: [discFolder]) == [.dreamcast, .playStation2])
var dcBoot = Data(repeating: 0, count: 2352); put(Array("SEGA SEGAKATANA".utf8), in: &dcBoot, at: 16)
try dcBoot.write(to: discFolder.appendingPathComponent("track 01.bin"))
check(try IridiumGameFileDetection.platforms(cueSource, selectedFiles: [discFolder]) == [.dreamcast])
try Data("FILE \"../Test.gb\" BINARY\n TRACK 01 MODE1/2352\n".utf8).write(to: cueSource)
rejects { _ = try IridiumDiscSet(cueSource, selectedFiles: [discFolder]) }
try Data("FILE \"track 01.bin\" BINARY\n TRACK 01 MODE1/2352\n TRACK 02 AUDIO\n".utf8).write(to: cueSource)
check(try IridiumDiscSet(cueSource).hasSharedTracks)
let trackLink = discFolder.appendingPathComponent("track03.bin")
try fm.removeItem(at: trackLink); try fm.createSymbolicLink(at: trackLink, withDestinationURL: input)
rejects { _ = try IridiumDiscSet(gdiSource, selectedFiles: [discFolder]) }
let rvzSource = temporary.appendingPathComponent("Autodetect.rvz"); try rvz.write(to: rvzSource)
check(try IridiumGameFileDetection.platforms(rvzSource, selectedFiles: [rvzSource]) == [.wii])
print("Content detection and complete-disc import passed")

var identifiedPS2 = ps2ISO
identifiedPS2.append(Data(repeating: 0, count: 3 * 2048))
putLE(20, in: &identifiedPS2, at: 16 * 2048 + 80, bytes: 4)
putBE(20, in: &identifiedPS2, at: 16 * 2048 + 84, bytes: 4)
identifiedPS2[16 * 2048 + 156] = 34
putLE(18, in: &identifiedPS2, at: 16 * 2048 + 158, bytes: 4)
putLE(2048, in: &identifiedPS2, at: 16 * 2048 + 166, bytes: 4)
identifiedPS2[18 * 2048] = 45
putLE(19, in: &identifiedPS2, at: 18 * 2048 + 2, bytes: 4)
putLE(64, in: &identifiedPS2, at: 18 * 2048 + 10, bytes: 4)
identifiedPS2[18 * 2048 + 32] = 12
put(Array("SYSTEM.CNF;1".utf8), in: &identifiedPS2, at: 18 * 2048 + 33)
put(Array("BOOT2 = cdrom0:GAME.ELF;1\n".utf8), in: &identifiedPS2, at: 19 * 2048)
let psDisc = temporary.appendingPathComponent("Identify.iso")
try identifiedPS2.write(to: psDisc)
check(try IridiumGameFileDetection.platforms(psDisc, selectedFiles: [psDisc]) == [.playStation2])
check(try !IridiumGameFileDetection.needsConfirmation(psDisc, platforms: [.playStation2]))
put(Array("BOOT  = cdrom:GAME.EXE;1\n".utf8), in: &identifiedPS2, at: 19 * 2048)
try identifiedPS2.write(to: psDisc)
rejects { _ = try IridiumGameFileDetection.platforms(psDisc, selectedFiles: [psDisc]) }
try ps2ISO.write(to: psDisc)
check(try IridiumGameFileDetection.needsConfirmation(psDisc, platforms: [.playStation2]))
let ambiguousELF = temporary.appendingPathComponent("MIPS.elf");try elfFixture().write(to: ambiguousELF)
check(try IridiumGameFileDetection.platforms(ambiguousELF, selectedFiles: [ambiguousELF]) == [.psp, .playStation2])
var identifiedPSP = elfFixture();putLE(0x10a23001, in: &identifiedPSP, at: 36, bytes: 4);try identifiedPSP.write(to: ambiguousELF)
check(try IridiumGameFileDetection.platforms(ambiguousELF, selectedFiles: [ambiguousELF]) == [.psp])
check(try IridiumROMInspection.inspect(ambiguousELF, fileExtension: "elf", preferredPlatform: .playStation2).platform == .psp)
print("Ambiguous containers and PlayStation generation detection passed")
