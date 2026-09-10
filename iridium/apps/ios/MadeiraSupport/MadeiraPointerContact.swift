import Foundation

// UIKit can report several fingers. One contact owns the guest's single left button.
struct MadeiraPointerContact {
    private var owner: UInt64?

    static func position(x: Double, y: Double, width: Double, height: Double) -> (Int32, Int32)? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width >= 1, height >= 1, width <= Double(Int32.max), height <= Double(Int32.max) else { return nil }
        return (Int32(min(max(x, 0), 1) * (width - 1)), Int32(min(max(y, 0), 1) * (height - 1)))
    }

    mutating func flags(id: UInt64, phase: String) -> UInt32? {
        switch phase {
        case "began":
            guard owner == nil else { return nil }
            owner = id
            return 0x8003 // absolute move + left down
        case "moved":
            return owner == id ? 0x8001 : nil
        case "ended", "cancelled":
            guard owner == id else { return nil }
            owner = nil
            return 0x8004
        default: return nil
        }
    }

    mutating func release() -> Bool {
        let wasHeld = owner != nil
        owner = nil
        return wasHeld
    }
}
