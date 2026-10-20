// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct IridiumSoftwareCredit: Identifiable {
    let name: String
    let purpose: String
    let source: String
    var id: String { name }
    static let engines: [Self] = [
        .init(name: "Iridium", purpose: "Game library, shared player and controls", source: "https://github.com/intraducine/iridium"),
        .init(name: "Madeira", purpose: "Windows games", source: "https://github.com/willfaust/Madeira"),
        .init(name: "SameBoy", purpose: "Game Boy and Game Boy Color", source: "https://github.com/LIJI32/SameBoy"),
        .init(name: "PPSSPP", purpose: "PSP", source: "https://github.com/hrydgard/ppsspp"),
        .init(name: "Dolphin", purpose: "GameCube and Wii", source: "https://github.com/dolphin-emu/dolphin"),
        .init(name: "DolphiniOS", purpose: "Dolphin's iOS port", source: "https://github.com/OatmealDome/dolphin-ios"),
        .init(name: "Azahar", purpose: "Nintendo 3DS", source: "https://github.com/azahar-emu/azahar"),
        .init(name: "Play!", purpose: "PlayStation 2", source: "https://github.com/jpd002/Play-"),
        .init(name: "Flycast", purpose: "Dreamcast and arcade", source: "https://github.com/flyinghead/flycast")
    ]
    static let supporting: [Self] = [
        .init(name: "Wine", purpose: "Windows compatibility", source: "https://github.com/willfaust/wine"),
        .init(name: "FEX-Emu", purpose: "PC instruction translation", source: "https://github.com/willfaust/FEX"),
        .init(name: "DXMT", purpose: "Direct3D graphics on Metal", source: "https://github.com/willfaust/dxmt"),
        .init(name: "Madeira Dock", purpose: "Steam client integration", source: "https://github.com/willfaust/madeira-dock"),
        .init(name: "StikJIT", purpose: "On-device JIT helper", source: "https://github.com/StikDebug/StikJIT"),
        .init(name: "StikDebug", purpose: "External JIT connection", source: "https://github.com/StikDebug/StikDebug"),
        .init(name: "idevice", purpose: "Device pairing and communication", source: "https://github.com/jkcoxson/idevice"),
        .init(name: "MoltenVK", purpose: "Vulkan graphics on Metal", source: "https://github.com/KhronosGroup/MoltenVK"),
        .init(name: "FFmpeg", purpose: "Game audio and video codecs", source: "https://ffmpeg.org"),
        .init(name: "FreeType", purpose: "Font rendering", source: "https://freetype.org"),
        .init(name: "LLVM", purpose: "Compiler and runtime libraries", source: "https://github.com/llvm/llvm-project"),
        .init(name: "rpmalloc", purpose: "Memory allocation", source: "https://github.com/mjansson/rpmalloc"),
        .init(name: "GnuTLS", purpose: "Secure network connections", source: "https://www.gnutls.org"),
        .init(name: "GMP", purpose: "Multiple-precision arithmetic", source: "https://gmplib.org"),
        .init(name: "Nettle", purpose: "Cryptographic primitives", source: "https://www.lysator.liu.se/~nisse/nettle/"),
        .init(name: "Libretro", purpose: "Core interfaces and artwork catalog", source: "https://github.com/libretro"),
        .init(name: "Zstandard", purpose: "Compressed game downloads", source: "https://github.com/facebook/zstd"),
        .init(name: "Apple Metal Shader Converter", purpose: "Shader translation", source: "https://developer.apple.com/metal/shader-converter/")
    ]
}

struct IridiumSoftwareNotice: Identifiable {
    let url: URL
    let path: String
    let software: String
    let title: String
    var id: String { path }

    static func catalog(roots: [(name: String, url: URL)]) -> [Self] {
        var result: [Self] = []
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                      ["txt", "md", "html", "json", "xml", "mit", "bsd", "lib", ""].contains(url.pathExtension.lowercased()) else { continue }
                let relative = String(url.path.dropFirst(root.url.path.count + 1))
                let parts = relative.split(separator: "/").map(String.init)
                let group = software(parts, root: root.name)
                let basename = url.deletingPathExtension().lastPathComponent
                let kind: String
                switch basename.lowercased() {
                case "license", "licence", "copying": kind = "License"
                case "authors": kind = "Authors"
                case "copyright": kind = "Copyright"
                case "sources": kind = "Source Information"
                case "notice", "notices": kind = "Notices"
                default: kind = basename.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
                }
                let generic = ["dist", "src", "build", "licenses", "license", "docs", "legal"]
                let parent = parts.dropLast().last(where: { !generic.contains($0.lowercased()) })
                let title = parent.map { $0.lowercased() != group.lowercased() && !parts.dropLast().isEmpty ? "\($0) · \(kind)" : kind } ?? kind
                result.append(.init(url: url, path: root.name + "/" + relative, software: group, title: title))
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    private static func software(_ parts: [String], root: String) -> String {
        let name = parts.joined(separator: "/").lowercased()
        if name.hasPrefix("phase3/"), parts.count > 1 {
            return ["dolphin": "Dolphin", "azahar": "Azahar", "play": "Play!", "flycast": "Flycast"][parts[1]] ?? parts[1]
        }
        if name.hasPrefix("ppsspp/") { return "PPSSPP" }
        for (key, group) in [("sameboy", "SameBoy"), ("iridium", "Iridium"), ("madeira", "Madeira"), ("dxmt", "DXMT"), ("fex", "FEX-Emu"), ("llvm", "LLVM"), ("rpmalloc", "rpmalloc"), ("zstd", "Zstandard"), ("stik", "StikJIT & Pairing"), ("rppairing", "StikJIT & Pairing"), ("gnutls", "GnuTLS"), ("nettle", "Nettle"), ("gmp", "GMP"), ("ffmpeg", "FFmpeg"), ("freetype", "FreeType"), ("dock", "Madeira Dock")] {
            if name.contains(key) { return group }
        }
        if root == "legal" { return "Windows Runtime Libraries" }
        if name.contains("ofl") { return "Fonts" }
        return "Shared License Texts & Notices"
    }
}
