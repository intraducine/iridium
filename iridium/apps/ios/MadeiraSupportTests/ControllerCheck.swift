@main
struct ControllerCheck {
 static func main() {
assert(MadeiraKeys.virtualKey(hid: 26) == 0x57) // W
assert(MadeiraKeys.virtualKey(hid: 225) == 0xa0) // left Shift
assert(MadeiraKeys.virtualKey(hid: 224) == 0xa2) // left Control
assert(MadeiraKeys.virtualKey(hid: 43) == 0x09) // Tab
assert(MadeiraKeys.virtualKey(hid: 89) == 0x61) // keypad 1
assert(MadeiraKeys.virtualKey(hid: 98) == 0x60) // keypad 0
assert(MadeiraKeys.virtualKey(hid: 88) == 0x0d) // keypad Enter
assert(MadeiraKeys.virtualKey(hid: 104) == 0x7c) // F13
assert(MadeiraKeys.virtualKey(hid: 115) == 0x87) // F24
assert(MadeiraKeys.virtualKey(hid: 999) == nil)
assert(MadeiraKeys.virtualKey(character: "a")?.key == 0x41 && MadeiraKeys.virtualKey(character: "a")?.shift == false)
assert(MadeiraKeys.virtualKey(character: "A")?.key == 0x41 && MadeiraKeys.virtualKey(character: "A")?.shift == true)
assert(MadeiraKeys.virtualKey(character: "0")?.key == 0x30 && MadeiraKeys.virtualKey(character: "0")?.shift == false)
assert(MadeiraKeys.virtualKey(character: "!")?.key == 0x31 && MadeiraKeys.virtualKey(character: "!")?.shift == true)
assert(MadeiraKeys.virtualKey(character: "_")?.key == 0xbd && MadeiraKeys.virtualKey(character: "_")?.shift == true)
assert(MadeiraKeys.virtualKey(character: "\n")?.key == 0x0d && MadeiraKeys.virtualKey(character: "\n")?.shift == false)
assert(MadeiraKeys.virtualKey(character: "é") == nil)
var keys = MadeiraKeys()
assert(keys.update(name: "ArrowLeft", value: 1).first?.0 == 0x25)
assert(keys.update(name: "left", value: 1).isEmpty)
assert(keys.update(name: "ArrowLeft", value: 0).isEmpty)
assert(keys.update(name: "left", value: 0).first?.1 == false)
assert(keys.update(name: "z", value: 1).first?.0 == 0x5a)
assert(keys.releaseAll() == [0x5a])
print("PASS keyboard aliases, software text mapping, shared keys and release")

 }
}
