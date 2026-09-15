import Foundation
@MainActor final class UIApplication { enum State { case active, inactive }; static let shared=UIApplication(); var applicationState:State = .active }
@MainActor var events:[(Int32,Int32)]=[]
@MainActor func winios_post_key(_ key:Int32,_ down:Int32) { events.append((key,down)) }
@main struct KeyboardRegression {
    @MainActor static func main() {
        for byte in 32...126 { precondition(MadeiraKeys.virtualKey(character:Character(UnicodeScalar(byte)!)) != nil) }
        for character:Character in ["ß", "ı", "é", "\u{FB03}", "中", "👨‍👩‍👦", "e\u{0301}"] {
            precondition(MadeiraKeys.virtualKey(character:character) == nil)
        }
        MadeiraHardwareInput.acceptingInput=true
        MadeiraHardwareInput.key(hid:26,pressed:true) // physical W
        precondition(events.count == 1)
        MadeiraHardwareInput.softwareKeyboardActive=true // release physical W before text mode
        precondition(events.count == 2 && events.last!.1 == 0)
        events=[]
        MadeiraHardwareInput.key(hid:4,pressed:true) // GCKeyboard must not double deliver a software insertion
        precondition(events.isEmpty)
        precondition(MadeiraHardwareInput.insertText("aA!"))
        precondition(events.count == 10)
        events=[]
        precondition(!MadeiraHardwareInput.insertText("abcßdef"))
        precondition(events.isEmpty, "partial unsupported insertion")
        MadeiraHardwareInput.deleteBackward()
        precondition(events.count == 2 && events[0].0 == 8)
        MadeiraHardwareInput.softwareKeyboardActive=false
        MadeiraHardwareInput.key(hid:57,pressed:true)
        MadeiraHardwareInput.key(hid:57,pressed:false)
        MadeiraHardwareInput.softwareKeyboardActive=true
        events=[]
        precondition(MadeiraHardwareInput.insertText("a"))
        precondition(events.first!.0 == 0x10 && events.first!.1 == 1, "Caps Lock not compensated")
        events=[]
        MadeiraHardwareInput.acceptingInput=false
        precondition(MadeiraHardwareInput.insertText("a"))
        precondition(events.isEmpty)
        print("PASS keyboard ASCII coverage, Unicode rejection, whole-insertion rejection, Backspace, hardware deduplication and tracked Caps Lock")
    }
}
