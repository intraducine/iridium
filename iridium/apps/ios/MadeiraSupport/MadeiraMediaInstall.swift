import Foundation

enum MadeiraMediaInstall {
    // Wine rewrites registry whitespace. Compare section keys for repeat launches.
    static func addingMissingSections(_ entries: String, to registry: String) -> String {
        var result = registry
        for block in entries.components(separatedBy: "\n\n") where !block.isEmpty {
            guard let header = block.components(separatedBy: "\n").first,
                  header.hasPrefix("["), header.hasSuffix("]") else { continue }
            if !result.localizedCaseInsensitiveContains(header) { result += "\n" + block + "\n" }
        }
        return result
    }

    static func install(prefix: URL, resources: Bundle = .main) throws {
        for name in ["winegstreamer", "msvproc", "xaudio2_7", "d3dx9_42", "d3dcompiler_42"] {
            guard let source = resources.url(forResource: name, withExtension: "dll", subdirectory: "MediaRuntime") else { throw CocoaError(.fileNoSuchFile) }
            let target = prefix.appendingPathComponent("drive_c/windows/system32/\(name).dll")
            if name == "d3dx9_42" || name == "d3dcompiler_42" {
                // Supply missing helpers without replacing a game's chosen version or link.
                do { try Data(contentsOf: source).write(to: target, options: .withoutOverwriting) }
                catch let error as CocoaError where error.code == .fileWriteFileExists { }
                continue
            }
            try Data(contentsOf: source).write(to: target, options: .atomic)
        }
        // The process has not started its Wine server yet. Only alter our test prefix.
        let registry = prefix.appendingPathComponent("user.reg")
        var text = try String(contentsOf: registry, encoding: .utf8)
        let key = "Software\\\\Classes\\\\CLSID\\\\{317df618-5e5a-468a-9f15-d827a9a08162}\\\\InprocServer32"
        if !text.localizedCaseInsensitiveContains("[" + key + "]") {
            text += "\n[\(key)]\n@=\"winegstreamer.dll\"\n\"ThreadingModel\"=\"Both\"\n"
        }
        guard let registration = resources.url(forResource: "video-processor", withExtension: "reg", subdirectory: "MediaRuntime") else { throw CocoaError(.fileNoSuchFile) }
        let entries = try String(contentsOf: registration, encoding: .utf8)
        text = addingMissingSections(entries, to: text)
        guard let audioRegistration = resources.url(forResource: "xaudio2", withExtension: "reg", subdirectory: "MediaRuntime") else { throw CocoaError(.fileNoSuchFile) }
        text = addingMissingSections(try String(contentsOf: audioRegistration, encoding: .utf8), to: text)
        try text.write(to: registry, atomically: true, encoding: .utf8)
    }
}
