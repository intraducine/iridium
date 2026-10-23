"""Execute shipping pointer handlers with fake UIKit contacts and a manual clock."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from host_tests import module_cache

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'iridium/apps/ios/App/Adapters/Madeira/ContentView.swift'

FIXTURE = r'''
import Foundation
import CoreGraphics
enum Clock { static var now = 100.0 }
struct Date { var timeIntervalSinceReferenceDate: Double { Clock.now } }
extension Double { static func now() -> Double { Clock.now } }
final class DispatchQueue {
    static let main = DispatchQueue()
    var pending: [(Double, () -> Void)] = []
    func asyncAfter(deadline: Double, execute: @escaping () -> Void) { pending.append((deadline, execute)) }
    func advance(_ delta: Double) {
        Clock.now += delta
        let ready = pending.filter { $0.0 <= Clock.now }
        pending.removeAll { $0.0 <= Clock.now }
        for (_, callback) in ready { callback() }
    }
}
class UIView {
    var window: UIView?
    func didMoveToWindow() {}
    func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
}
final class UITouch: Hashable {
    enum Phase { case began, moved, ended, cancelled }
    enum Kind { case direct, indirectPointer }
    weak var view: UIView?
    var point: CGPoint
    var phase = Phase.began
    var type = Kind.direct
    init(_ view: UIView, _ x: Double = 50, _ y: Double = 50) { self.view = view; point = CGPoint(x:x, y:y) }
    func location(in view: UIView) -> CGPoint { point }
    static func == (a: UITouch, b: UITouch) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}
final class UIEvent { var allTouches: Set<UITouch> = [] }
enum TouchMouseGate { enum Mode { case off, on }; static var mode = Mode.on }
enum IridiumTouchMouseMode { case off, direct, trackpad; static var mode = Self.direct; static func current() -> Self { mode } }
enum IridiumControlHaptics { static func press() {} }
final class LibraryModel { static let shared = LibraryModel(); var blocksGameplayTouch = false }
final class TouchControlsModel { static let shared = TouchControlsModel(); var editing = false }
final class InputSettings { static let shared = InputSettings(); var sensRel = 1.0, sensAbs = 1.0 }
final class UserDefaults { static let standard = UserDefaults(); func object(forKey: String) -> Any? { nil } }
final class HardwareInput {
    static let shared = HardwareInput()
    var intercepted = false, updates = 0
    func interceptTouches(_ t: Set<UITouch>, _ event: UIEvent?, _ phase: UITouch.Phase) -> Bool { intercepted }
    func iridiumUpdateTouchPointer() { updates += 1 }
}
struct Delivery { var kind: String; var x: Int32 = 0, y: Int32 = 0; var flags: UInt32 = 0, data: UInt32 = 0 }
var deliveries: [Delivery] = []
func winios_post_touch_down(_ x: Int32, _ y: Int32) { deliveries.append(.init(kind:"down", x:x, y:y)) }
func winios_post_touch_move(_ x: Int32, _ y: Int32) { deliveries.append(.init(kind:"move", x:x, y:y)) }
func winios_post_touch_up(_ x: Int32, _ y: Int32) { deliveries.append(.init(kind:"up", x:x, y:y)) }
func winios_cursor_move(_ x: Int32, _ y: Int32) { deliveries.append(.init(kind:"cursor", x:x, y:y)) }
func winios_pointer(_ x: Int32, _ y: Int32, _ flags: UInt32, _ data: UInt32) { deliveries.append(.init(kind:"pointer", x:x, y:y, flags:flags, data:data)) }
func winios_screen_size(_ w: inout Int32, _ h: inout Int32) { w = 960; h = 540 }
MOTION
final class MetalBackedView: UIView {
    static weak var keyboardTarget: MetalBackedView?
    func gameRect() -> CGRect { CGRect(x:20, y:20, width:200, height:200) }
    func mapPoint(_ p: CGPoint) -> (Int32, Int32) { (Int32(p.x), Int32(p.y)) }
    func mapTouch(_ t: UITouch) -> (Int32, Int32) { mapPoint(t.location(in:self)) }
HANDLERS
DETACH
}
let surface = MetalBackedView(), controls = UIView(), event = UIEvent()
MetalBackedView.keyboardTarget = surface
let landscape = true
func configureGamepad(landscape: Bool) {}
func editorChanged(_ editing: Bool) {
EDITOR
}
func menuChanged(_ blocked: Bool) {
MENU
}
func begin(_ contacts: Set<UITouch>) { surface.touchesBegan(contacts, with:event) }
func move(_ t: UITouch, _ x: Double, _ y: Double) {
    t.phase = .moved; t.point = CGPoint(x:x,y:y); surface.touchesMoved([t], with:event)
}
func end(_ contacts: Set<UITouch>) {
    for t in contacts { t.phase = .ended }; surface.touchesEnded(contacts, with:event)
}
func cancel(_ contacts: Set<UITouch>) {
    for t in contacts { t.phase = .cancelled }; surface.touchesCancelled(contacts, with:event)
}
func kinds() -> [String] { deliveries.map(\.kind) }
func flags() -> [UInt32] { deliveries.filter { $0.kind == "pointer" }.map(\.flags) }
switch CommandLine.arguments[1] {
case "boundaries":
    let owner = UITouch(surface), button = UITouch(controls), letterbox = UITouch(surface,5,5), mouse = UITouch(surface)
    mouse.type = .indirectPointer; event.allTouches = [owner,button,letterbox,mouse]
    begin([owner,button,letterbox,mouse]); end([owner])
    precondition(kinds() == ["cursor","down","up"], "foreign contacts changed the direct gesture")
    deliveries = []; move(button,70,70); end([button,letterbox,mouse])
    precondition(deliveries.isEmpty, "unowned contacts delivered pointer input")
case "admission":
    let touch = UITouch(surface)
    HardwareInput.shared.intercepted = true; begin([touch]); end([touch])
    HardwareInput.shared.intercepted = false
    TouchMouseGate.mode = .off; begin([touch]); TouchMouseGate.mode = .on
    move(touch,90,90); end([touch]); DispatchQueue.main.advance(1)
    precondition(deliveries.isEmpty, "a swallowed gesture was admitted after its gate changed")
    for blocked in 0..<3 {
        LibraryModel.shared.blocksGameplayTouch = blocked == 0
        TouchControlsModel.shared.editing = blocked == 1
        IridiumTouchMouseMode.mode = blocked == 2 ? .off : .direct
        let rejected = UITouch(surface); begin([rejected]); move(rejected,80,80); end([rejected])
    }
    precondition(deliveries.isEmpty, "disabled input admitted a contact")
    LibraryModel.shared.blocksGameplayTouch = false; TouchControlsModel.shared.editing = false
    IridiumTouchMouseMode.mode = .direct
    let accepted = UITouch(surface); begin([accepted]); end([accepted])
    precondition(kinds() == ["cursor","down","up"], "input did not recover after its gate opened")
case "direct":
    let owner = UITouch(surface); begin([owner]); move(owner,90,80); end([owner])
    precondition(kinds() == ["cursor","down","move","up"])
    precondition(deliveries[1].x == 50 && deliveries[2].x == 90, "drag moved its original down point")
    deliveries = []; let next = UITouch(surface); begin([next]); end([next]); DispatchQueue.main.advance(1)
    precondition(kinds() == ["cursor","down","up"], "a stale hold callback started another drag")
case "multitouch":
    let first = UITouch(surface,40,40), second = UITouch(surface,80,80), foreign = UITouch(controls)
    event.allTouches = [first,second,foreign]
    begin([first]); begin([second]); end([first]); end([second])
    precondition(flags() == [0x8008,0x8010] && deliveries.last!.x == 60 && deliveries.last!.y == 60)
    deliveries = []; let a = UITouch(surface,40,40), b = UITouch(surface,80,80)
    begin([a,b]); move(a,40,70); move(b,80,110); end([a,b])
    precondition(!flags().contains(0x8008) && flags().contains(0x800), "scroll became a right click")
case "revoke":
    for blockWithEditor in [false,true] {
        deliveries = []; let owner = UITouch(surface); begin([owner]); DispatchQueue.main.advance(0.3)
        precondition(kinds() == ["cursor","down"])
        TouchControlsModel.shared.editing = blockWithEditor; LibraryModel.shared.blocksGameplayTouch = !blockWithEditor
        if blockWithEditor { editorChanged(true) } else { menuChanged(true) }
        precondition(kinds() == ["cursor","down","up"] && HardwareInput.shared.updates > 0)
        TouchControlsModel.shared.editing = false; LibraryModel.shared.blocksGameplayTouch = false
        move(owner,100,100); end([owner]); DispatchQueue.main.advance(1)
        precondition(kinds() == ["cursor","down","up"], "revoked contact restarted before lifting")
    }
case "cancel":
    let owner = UITouch(surface); begin([owner]); DispatchQueue.main.advance(0.3)
    let other = UITouch(surface,80,80); begin([other]); cancel([other])
    precondition(kinds() == ["cursor","down","up"], "cancelling another owned finger left the drag held")
    move(owner,100,100); end([owner]); DispatchQueue.main.advance(1)
    precondition(kinds() == ["cursor","down","up"])
    deliveries = []; let next = UITouch(surface); begin([next]); end([next])
    precondition(kinds() == ["cursor","down","up"])
case "detach":
    let owner = UITouch(surface); begin([owner]); DispatchQueue.main.advance(0.3)
    surface.didMoveToWindow()
    precondition(kinds() == ["cursor","down","up"])
    move(owner,100,100); end([owner]); DispatchQueue.main.advance(1)
    precondition(kinds() == ["cursor","down","up"], "detached surface restarted a revoked drag")
case "trackpad":
    IridiumTouchMouseMode.mode = .trackpad
    let owner = UITouch(surface); begin([owner]); DispatchQueue.main.advance(0.6)
    precondition(flags() == [0x2], "long press did not start a trackpad drag")
    let other = UITouch(surface,80,80); begin([other]); end([owner]); end([other])
    precondition(flags() == [0x2,0x4], "drag owner release became a click or left the button held")
    deliveries = []; let next = UITouch(surface); begin([next]); move(next,70,80); end([next])
    precondition(flags() == [0x1] && deliveries[0].x == 20 && deliveries[0].y == 30)
    deliveries = []; let cancelled = UITouch(surface); begin([cancelled]); cancel([cancelled]); DispatchQueue.main.advance(1)
    precondition(deliveries.isEmpty, "cancelled hold started a late drag")
default: preconditionFailure("unknown scenario")
}
print("PASS shipping pointer: " + CommandLine.arguments[1])
'''


def program(source):
    handlers = source[source.index('    private var tmDownPoints:'):source.index('\n}\n\n/// Arrow-key button')]
    layout = (ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumPlayerLayout.swift').read_text()
    motion = layout[layout.index('struct IridiumTouchMouseMotion {'):layout.index('enum IridiumTouchHaptics:')]
    # Execute the detachment entry; the rest attaches real UIKit rendering.
    start = source.index('    override func didMoveToWindow() {')
    detach = source[start:source.index('        guard let w = window else { return }', start)] + '    }\n'
    def callback(marker):
        start = source.index(marker) + len(marker)
        return source[start:source.index('\n            }', start)]
    return (FIXTURE.replace('MOTION', motion).replace('HANDLERS', handlers).replace('DETACH', detach)
            .replace('EDITOR', callback('.onChange(of: m.editing) { _, editing in'))
            .replace('MENU', callback('.onChange(of: library.blocksGameplayTouch) { _, blocked in')))


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Apple Swift compiler required for pointer checks')
class TouchMouseOwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='iridium-pointer-check-')
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        source = root / 'main.swift'; source.write_text(program(SOURCE.read_text()))
        cls.binary = root / 'check'
        subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', module_cache(),
                        str(source), '-o', str(cls.binary)], check=True, timeout=90)

    def check(self, scenario):
        result = subprocess.run([str(self.binary), scenario], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_contacts_exclude_controls_letterbox_and_hardware_pointer(self): self.check('boundaries')
    def test_input_gates_and_revoked_contacts_require_fresh_admission(self): self.check('admission')
    def test_direct_drag_and_finished_hold_do_not_leave_a_button_down(self): self.check('direct')
    def test_only_owned_contacts_contribute_to_multifinger_click_and_scroll(self): self.check('multitouch')
    def test_menu_or_editor_revocation_releases_and_swallows_until_lift(self): self.check('revoke')
    def test_cancel_any_owned_finger_releases_the_entire_gesture(self): self.check('cancel')
    def test_window_detach_releases_without_waiting_for_another_input(self): self.check('detach')
    def test_trackpad_drag_owner_lifts_before_remaining_finger_without_click(self): self.check('trackpad')


if __name__ == '__main__': unittest.main()
