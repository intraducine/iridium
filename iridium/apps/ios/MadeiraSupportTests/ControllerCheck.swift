@main
struct ControllerCheck {
 static func main() {
assert(MadeiraKeys.virtualKey(hid: 26) == 0x57) // W
assert(MadeiraKeys.virtualKey(hid: 225) == 0xa0) // left Shift
assert(MadeiraKeys.virtualKey(hid: 224) == 0xa2) // left Control
assert(MadeiraKeys.virtualKey(hid: 43) == 0x09) // Tab
assert(MadeiraKeys.virtualKey(hid: 999) == nil)
var keys = MadeiraKeys()
assert(keys.update(name: "ArrowLeft", value: 1).first?.0 == 0x25)
assert(keys.update(name: "left", value: 1).isEmpty)
assert(keys.update(name: "ArrowLeft", value: 0).isEmpty)
assert(keys.update(name: "left", value: 0).first?.1 == false)
assert(keys.update(name: "z", value: 1).first?.0 == 0x5a)
assert(keys.releaseAll() == [0x5a])
print("PASS keyboard aliases, shared keys and release")

 }
}
