import Foundation

// swiftc MadeiraMediaInstall.swift RuntimeDependenciesCheck.swift -o /tmp/dependency-check
// /tmp/dependency-check apps/ios/MediaRuntime
@main struct RuntimeDependenciesCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Resources.bundle")
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]),
                        to: bundleURL.appendingPathComponent("MediaRuntime"))
        let resources = Bundle(path: bundleURL.path)!
        let prefix = root.appendingPathComponent("prefix")
        let system = prefix.appendingPathComponent("drive_c/windows/system32")
        try fm.createDirectory(at: system, withIntermediateDirectories: true)
        let registry = prefix.appendingPathComponent("user.reg")
        try "WINE REGISTRY Version 2\n".write(to: registry, atomically: true, encoding: .utf8)
        let save = prefix.appendingPathComponent("saved-game.dat")
        try Data("keep my save".utf8).write(to: save)
        try MadeiraMediaInstall.install(prefix: prefix, resources: resources)
        let firstRegistry = try Data(contentsOf: registry)
        try MadeiraMediaInstall.install(prefix: prefix, resources: resources)
        let secondRegistry = try Data(contentsOf: registry)
        let savedData = try Data(contentsOf: save)
        precondition(secondRegistry == firstRegistry)
        precondition(savedData == Data("keep my save".utf8))
        for name in ["d3dx9_42", "d3dcompiler_42", "xaudio2_7"] {
            let actual = try Data(contentsOf: system.appendingPathComponent(name + ".dll"))
            let expected = try Data(contentsOf: bundleURL.appendingPathComponent("MediaRuntime/" + name + ".dll"))
            precondition(actual == expected && actual.starts(with: [0x4d, 0x5a]))
        }
        let custom = Data("game-specific DirectX replacement".utf8)
        let helper = system.appendingPathComponent("d3dx9_42.dll")
        try custom.write(to: helper)
        let compiler = system.appendingPathComponent("d3dcompiler_42.dll")
        try fm.removeItem(at: compiler)
        try fm.createSymbolicLink(atPath: compiler.path, withDestinationPath: "custom-compiler.dll")
        try MadeiraMediaInstall.install(prefix: prefix, resources: resources)
        let preserved = try Data(contentsOf: helper)
        let link = try fm.destinationOfSymbolicLink(atPath: compiler.path)
        precondition(preserved == custom)
        precondition(link == "custom-compiler.dll")
        print("PASS: missing helpers installed, existing DLL and link preserved, repeat install stable, saves preserved")
    }
}
