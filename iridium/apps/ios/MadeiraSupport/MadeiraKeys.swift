import Foundation

// Hardware keyboard state, separate from the XInput controller bridge.
struct MadeiraKeys {
    static func virtualKey(hid: Int) -> Int32? {
        if (4...29).contains(hid) { return Int32(0x41 + hid - 4) }
        if (30...38).contains(hid) { return Int32(0x31 + hid - 30) }
        if (58...69).contains(hid) { return Int32(0x70 + hid - 58) }
        let keys: [Int: Int32] = [39:0x30,40:0x0d,41:0x1b,42:0x08,43:0x09,44:0x20,
            45:0xbd,46:0xbb,47:0xdb,48:0xdd,49:0xdc,51:0xba,52:0xde,53:0xc0,
            54:0xbc,55:0xbe,56:0xbf,57:0x14,73:0x2d,74:0x24,75:0x21,76:0x2e,
            77:0x23,78:0x22,79:0x27,80:0x25,81:0x28,82:0x26,
            224:0xa2,225:0xa0,226:0xa4,227:0x5b,228:0xa3,229:0xa1,230:0xa5,231:0x5c]
        return keys[hid]
    }

    private var sources: [String: Set<Int32>] = [:]
    mutating func update(name: String, value: Double) -> [(Int32, Bool)] {
        let before = Set(sources.values.flatMap { $0 })
        let key = name.lowercased()
        var held = Set<Int32>()
        if value > 0 {
            let bindings: [String: Int32] = [
                "arrowup": 0x26, "arrowdown": 0x28, "arrowleft": 0x25, "arrowright": 0x27,
                "up": 0x26, "down": 0x28, "left": 0x25, "right": 0x27,
                "space": 0x20, "enter": 0x0d, "return": 0x0d, "escape": 0x1b]
            if let vk = bindings[key] { held.insert(vk) }
            else if key.count == 1, let ascii = key.uppercased().utf8.first, ascii < 128 {
                held.insert(Int32(ascii))
            }
        }
        sources[key] = held.isEmpty ? nil : held
        let after = Set(sources.values.flatMap { $0 })
        return before.subtracting(after).sorted().map { ($0, false) }
            + after.subtracting(before).sorted().map { ($0, true) }
    }
    mutating func releaseAll() -> [Int32] {
        let keys = Set(sources.values.flatMap { $0 }).sorted()
        sources.removeAll()
        return keys
    }
}
