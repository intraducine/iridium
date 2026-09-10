import Foundation

enum MadeiraControllerInstall {
    static func install(prefix: URL, windowsExecutable: String) throws {
        let relative = String(windowsExecutable.dropFirst(3)).replacingOccurrences(of: "\\", with: "/")
        let exe = prefix.appendingPathComponent("drive_c").appendingPathComponent(relative)
        let handle = try FileHandle(forReadingFrom: exe)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 64) ?? Data()
        guard header.count == 64, header[0] == 0x4d, header[1] == 0x5a else { throw CocoaError(.fileReadCorruptFile) }
        let offset = (0..<4).reduce(UInt64(0)) { $0 | UInt64(header[60 + $1]) << (8 * $1) }
        try handle.seek(toOffset: offset)
        let pe = try handle.read(upToCount: 6) ?? Data()
        guard pe.count == 6, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { throw CocoaError(.fileReadCorruptFile) }
        let machine = UInt16(pe[4]) | UInt16(pe[5]) << 8
        guard machine == 0x8664 || machine == 0x14c else { throw CocoaError(.featureUnsupported) }
        let arch = machine == 0x8664 ? "x64" : "x86"
        guard let source = Bundle.main.url(forResource: "xinput", withExtension: "dll", subdirectory: "ControllerRuntime/\(arch)") else { throw CocoaError(.fileNoSuchFile) }
        let payload = try Data(contentsOf: source)
        for name in ["xinput1_1", "xinput1_2", "xinput1_3", "xinput1_4", "xinput9_1_0"] {
            let target = exe.deletingLastPathComponent().appendingPathComponent(name + ".dll")
            // Preserve any game-supplied DLL in the isolated copy before installing the bridge.
            let backup = target.appendingPathExtension("before-iridium")
            if FileManager.default.fileExists(atPath: target.path),
               !FileManager.default.fileExists(atPath: backup.path),
               try Data(contentsOf: target) != payload {
                try FileManager.default.copyItem(at: target, to: backup)
            }
            try payload.write(to: target, options: .atomic)
        }
    }
}
