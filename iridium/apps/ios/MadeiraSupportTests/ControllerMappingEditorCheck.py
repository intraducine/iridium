#!/usr/bin/env python3
"""Exercise production editor load/edit closures without a SwiftUI simulator."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Iridium/Input/PhysicalControllerMappingView.swift").read_text()
assert ".onChange(of: configuration)" not in source, "loading state must not persist it"
appear = re.findall(r"\.onAppear \{ (configuration = PhysicalControllerMappingStore\.configuration\(for: gameID\)) \}", source)
assert len(appear) == 1, "editor appearance load boundary changed"
initial = re.findall(r"        (_configuration = State\(initialValue: PhysicalControllerMappingStore\.configuration\(for: gameID\)\))", source)
assert len(initial) == 1, "editor initial load boundary changed"
start = source.index("    private func editing<Value>")
end = source.index("\n}\n\nprivate struct ControllerMappingChoiceView")
methods = source[start:end].replace("private func", "func")
reset = re.findall(r'Button\("Reset Bindings", role: \.destructive\) \{\n(.*?)\n            \}', source, flags=re.DOTALL)
assert len(reset) == 1, "editor reset boundary changed"
for member in ["mode", "leftStick", "rightStick", "deadZone", "mouseSpeed"]:
    assert f"editing(\\.{member})" in source
assert "value.bindings[button.rawValue] = action\n                                                  persistEdit(value)" in source

code = """
import Foundation
@propertyWrapper final class State<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    init(initialValue: Value) { wrappedValue = initialValue }
}
struct Binding<Value> {
    let get: () -> Value
    let set: (Value) -> Void
    var wrappedValue: Value { get { get() } nonmutating set { set(newValue) } }
}
struct EditorUnderTest {
    let gameID: UUID
    @State var configuration: PhysicalControllerConfiguration
    init(gameID: UUID) {
        self.gameID = gameID
""" + initial[0] + """
    }
    func appear() {
""" + appear[0] + """
    }
    func resetBindings() {
""" + reset[0] + """
    }
""" + methods + """
}
@main struct Check {
    static func main() throws {
        let game = UUID(), key = PhysicalControllerMappingStore.key(for: game)
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: key) }
        var selected = PhysicalControllerConfiguration(); selected.mode = .keyboardMouse
        PhysicalControllerMappingStore.save(selected, for: game)
        let editor = EditorUnderTest(gameID: game)
        precondition(editor.configuration == selected)
        let corrupt = Data("corrupt-settings".utf8)
        defaults.set(corrupt, forKey: key)
        editor.appear(); editor.appear()
        precondition(editor.configuration.mode == .native && defaults.data(forKey: key) == corrupt)
        var future = selected; future.version = 99
        let futureData = try JSONEncoder().encode(future)
        defaults.set(futureData, forKey: key)
        editor.appear(); editor.appear()
        precondition(editor.configuration.mode == .native && defaults.data(forKey: key) == futureData)
        defaults.removeObject(forKey: key)
        editor.appear()
        precondition(defaults.object(forKey: key) == nil, "appearing must not create absent preferences")
        selected.mouseSpeed = 1200
        PhysicalControllerMappingStore.save(selected, for: game)
        let external = defaults.data(forKey: key)
        editor.appear()
        precondition(editor.configuration == selected && defaults.data(forKey: key) == external)
        editor.editing(\\.mode).wrappedValue = .native
        precondition(PhysicalControllerMappingStore.configuration(for: game).mode == .native)
        editor.editing(\\.leftStick).wrappedValue = .arrows
        editor.editing(\\.rightStick).wrappedValue = .none
        editor.adjustDeadZone(1); editor.adjustMouseSpeed(-1)
        precondition(PhysicalControllerMappingStore.configuration(for: game) == editor.configuration)
        precondition(editor.configuration.leftStick == .arrows && editor.configuration.rightStick == .none)
        precondition(editor.configuration.mouseSpeed == 1100)
        editor.resetBindings()
        precondition(editor.configuration == PhysicalControllerConfiguration())
        precondition(PhysicalControllerMappingStore.configuration(for: game) == editor.configuration)
        defaults.set(futureData, forKey: key); editor.appear()
        editor.editing(\\.mode).wrappedValue = .keyboardMouse
        precondition(defaults.data(forKey: key) != futureData, "an explicit edit may replace retained bytes")
        precondition(PhysicalControllerMappingStore.configuration(for: game).mode == .keyboardMouse)
        print("PASS production editor load/reappearance preserves absent, corrupt, future and external settings; explicit edits/reset persist")
    }
}
"""
with tempfile.TemporaryDirectory(prefix="iridium-controller-editor-") as directory:
    harness = Path(directory) / "EditorUnderTest.swift"
    harness.write_text(code)
    binary = Path(directory) / "check"
    subprocess.run(["xcrun", "swiftc", str(root / "Iridium/Input/PhysicalControllerMapping.swift"),
                    str(harness), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
