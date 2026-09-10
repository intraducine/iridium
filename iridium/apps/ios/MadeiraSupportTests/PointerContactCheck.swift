import Foundation
@main struct PointerContactCheck {
    static func main() {
        var contact = MadeiraPointerContact()
        precondition(contact.flags(id: 1, phase: "began") == 0x8003)
        precondition(contact.flags(id: 2, phase: "began") == nil)
        precondition(contact.flags(id: 2, phase: "ended") == nil)
        precondition(contact.flags(id: 1, phase: "moved") == 0x8001)
        precondition(contact.flags(id: 1, phase: "cancelled") == 0x8004)
        precondition(!contact.release())
        precondition(contact.flags(id: 2, phase: "began") != nil)
        precondition(contact.release())
        let p = MadeiraPointerContact.position(x: -0.2, y: 1.2, width: 960, height: 540)!
        precondition(p.0 == 0 && p.1 == 539)
        precondition(MadeiraPointerContact.position(x: .nan, y: 0, width: 960, height: 540) == nil)
        precondition(MadeiraPointerContact.position(x: 0, y: 0, width: 0, height: 0) == nil)
        print("PASS: pointer down/move/cancel, competing touches, teardown, bounds")
    }
}
