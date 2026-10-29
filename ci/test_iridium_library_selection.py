"""Execute the production carousel arbitration, not a second model of it."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class LibrarySelectionTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for menu haptic lifecycle checks')
    def test_menu_haptics_renew_after_game_and_cover_touch_is_not_duplicated(self):
        view = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumLibraryView.swift').read_text()
        select = view[view.index('    private func select(_ id:'):view.index('    var body: some View')]
        start = view.index('.fullScreenCover(isPresented: Binding(get: { consoleSession.presented }')
        start = view.index('onDismiss: {', start) + len('onDismiss: {')
        dismiss = view[start:view.index('\n            }) {', start)]
        start = view.index('.onChange(of: selection.highlightedID) { old, value in') + len('.onChange(of: selection.highlightedID) { old, value in')
        change = view[start:view.index('\n            }', start)]
        fixture = r'''import Foundation
enum IridiumTouchHaptics { case off, medium; static var mode = Self.medium; static func current() -> Self { mode } }
enum IridiumMenuSounds {
    enum Cue { case move, select, back }
    static var moves = 0
    static func play(_ cue: Cue) { if cue == .move { moves += 1 } }
}
final class UISelectionFeedbackGenerator {
    var valid = true, pulses = 0, preparations = 0
    func selectionChanged() { if valid { pulses += 1 } }
    func prepare() { preparations += 1 }
}
struct Animation { static func smooth(duration: Double) -> Self { Self() } }
func withAnimation(_ animation: Animation?, _ body: () -> Void) { body() }
enum Anchor { case leading }
struct Position { mutating func scrollTo(id: UUID, anchor: Anchor) {} }
struct Game { let id: UUID }
final class Host {
    var selectionFeedback = UISelectionFeedbackGenerator()
    var selection = IridiumLibrarySelection(), carouselPosition = Position()
    var selectedID: UUID?, selected: Game?, pageArtwork = ""
    var showFocus = false, showHints = false, reduceMotion = false
    let reorderSession = IridiumLibraryDragSession()
    let games: [Game]
    var focusRestores = 0
    init(_ ids: [UUID]) { games = ids.map(Game.init); _ = selection.reconcile(ids) }
    func restoreKeyboardFocus() { focusRestores += 1 }
SELECT
    func touch(_ id: UUID) {
        let old = selection.highlightedID
        select(id, touched: true)
        changed(old, selection.highlightedID)
    }
    func focus(_ id: UUID) {
        let old = selection.highlightedID
        select(id); changed(old, selection.highlightedID)
    }
    func changed(_ old: UUID?, _ value: UUID?) {
CHANGE
    }
    func dismissed() {
DISMISS
    }
    func swipe(_ id: UUID) {
        let old = selection.highlightedID
        _ = selection.transition(to: .tracking); selection.observed(id)
        changed(old, selection.highlightedID)
        _ = selection.transition(to: .idle)
    }
}
let a = UUID(), b = UUID(), c = UUID()
let host = Host([a,b,c])
host.showFocus = true; host.showHints = true
host.touch(b)
precondition(host.selectionFeedback.pulses == 1 && !host.showFocus && !host.showHints)
host.touch(b); precondition(host.selectionFeedback.pulses == 1 && IridiumMenuSounds.moves == 1)
host.swipe(c); precondition(host.selectionFeedback.pulses == 2)
// Model a feedback resource made unusable during a native session.
let oldFeedback = host.selectionFeedback; oldFeedback.valid = false
host.dismissed()
precondition(host.selectionFeedback !== oldFeedback && host.selectionFeedback.preparations == 1 && host.focusRestores == 1)
host.swipe(b); host.touch(a)
precondition(host.selectionFeedback.pulses == 2 && oldFeedback.pulses == 2)
IridiumTouchHaptics.mode = .off
let moves = IridiumMenuSounds.moves
host.touch(b); host.swipe(c)
precondition(host.selectionFeedback.pulses == 2 && IridiumMenuSounds.moves == moves + 2)
IridiumTouchHaptics.mode = .medium
host.showFocus = true
host.focus(b)
precondition(host.selectionFeedback.pulses == 3)
print("PASS shipping menu haptics: fresh feedback after game dismissal, touch/swipe/controller, no duplicate tap and Off retained")
'''.replace('SELECT', select).replace('CHANGE', change).replace('DISMISS', dismiss)
        with tempfile.TemporaryDirectory() as folder:
            unit = Path(folder) / 'main.swift'; unit.write_text(fixture)
            binary = Path(folder) / 'check'
            subprocess.run(['swiftc', str(ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumLibrarySelection.swift'),
                            str(unit), '-o', str(binary)], check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=10)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for executable carousel checks')
    def test_touch_momentum_focus_and_identity(self):
        source = ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumLibrarySelection.swift'
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / 'main.swift'
            main.write_text('''import Foundation
let a = UUID(), b = UUID(), c = UUID()
let stale = UUID()
precondition(IridiumLibrarySelection.boundaries(from: a, to: a, in: [a,b,c]) == 0)
precondition(IridiumLibrarySelection.boundaries(from: a, to: c, in: [a,b,c]) == 2)
precondition(IridiumLibrarySelection.boundaries(from: c, to: b, in: [a,b,c]) == 1)
precondition(IridiumLibrarySelection.boundaries(from: a, to: stale, in: [a,b,c]) == 0)
precondition(IridiumLibrarySelection.boundaries(from: a, to: b, in: []) == 0)
let stored = IridiumLibraryOrder.encoded([c,c,stale,a])
precondition(IridiumLibraryOrder.ordered([a,b,c], saved: stored) == [c,a,b])
let reordered = IridiumLibraryOrder.moving(c, relativeTo: a, after: false, in: [a,b,c])
precondition(reordered == [c,a,b])
precondition(IridiumLibraryOrder.ordered([a,b,c], saved: IridiumLibraryOrder.encoded(reordered)) == reordered)
precondition(IridiumLibraryOrder.moving(a, relativeTo: c, after: true, in: reordered) == [c,a,b])
precondition(IridiumLibraryOrder.moving(stale, relativeTo: b, after: false, in: reordered) == reordered)
// Filtered reorder retains identities outside the visible filter.
precondition(IridiumLibraryOrder.moving(c, relativeTo: a, after: true, in: [a,b,c]) == [a,c,b])
precondition(IridiumLibrarySelection.restingOffset(190, widths: [210,66,66], spacing: 10, focusWidth: 66) == 220)
precondition(IridiumLibrarySelection.restingOffset(-20, widths: [210,66,66], spacing: 10, focusWidth: 66) == 0)
precondition(IridiumLibrarySelection.restingOffset(9999, widths: [210,66,66], spacing: 10, focusWidth: 66) == 296)
precondition(IridiumLibrarySelection.restingOffset(.nan, widths: [210,66], spacing: 10, focusWidth: 66) == nil)

// A cancelled session cannot admit text or its old local payload.
let drag = IridiumLibraryDragSession()
let cancelledDrag = drag.begin(a)
precondition(drag.accepts(context: cancelledDrag, item: cancelledDrag, local: true, privateType: true))
drag.end(cancelledDrag)
precondition(drag.active == nil)
precondition(!drag.accepts(context: nil, item: nil, local: false, privateType: false))
precondition(!drag.accepts(context: cancelledDrag, item: cancelledDrag, local: true, privateType: true))
let currentDrag = drag.begin(a)
precondition(drag.preview(target: b, after: false, in: [a,b,c]))
precondition(drag.insertion?.beforeID == b)
precondition(!drag.preview(target: a, after: true, in: [a,b,c]), "same gap has no repeated feedback")
precondition(drag.preview(target: b, after: true, in: [a,b,c]))
precondition(drag.insertion?.beforeID == c)
precondition(!drag.preview(target: c, after: false, in: [a,b,c]), "neighboring edges normalize to one slot")
precondition(drag.preview(target: c, after: true, in: [a,b,c]))
precondition(drag.insertion != nil && drag.insertion?.beforeID == nil)
precondition(!drag.preview(target: stale, after: true, in: [a,b,c]))
precondition(currentDrag.token != cancelledDrag.token)
precondition(!drag.accepts(context: cancelledDrag, item: cancelledDrag, local: true, privateType: true))
precondition(!drag.accepts(context: currentDrag, item: cancelledDrag, local: true, privateType: true))
precondition(!drag.accepts(context: currentDrag, item: currentDrag, local: false, privateType: true))
precondition(!drag.accepts(context: currentDrag, item: currentDrag, local: true, privateType: false))
drag.end(cancelledDrag) // A late old callback cannot cancel the new drag.
precondition(drag.active == currentDrag)
precondition(drag.insertion != nil, "late cancellation cannot clear the new preview")
precondition(drag.accepts(context: currentDrag, item: currentDrag, local: true, privateType: true))
drag.end(currentDrag)
precondition(drag.active == nil)
precondition(drag.insertion == nil, "ending/cancelling clears the line without persisting an order")
let firstSlot = drag.begin(c)
precondition(drag.preview(target: a, after: false, in: [a,b,c]))
precondition(drag.insertion?.beforeID == a, "first-slot preview")
drag.end(firstSlot)

var selection = IridiumLibrarySelection()
precondition(selection.reconcile([a,b,c]) == a)
precondition(selection.select(b) == b)
precondition(selection.selectedID == b)
precondition(selection.transition(to: .tracking) == nil)
selection.observed(c)
precondition(selection.selectedID == b) // Committed focus does not fight native scrolling.
precondition(selection.highlightedID == c) // Border/title preview moves immediately.
selection.observed(a)
precondition(selection.highlightedID == a)
selection.observed(c)
precondition(selection.transition(to: .decelerating) == nil)
precondition(selection.select(a) == nil) // Focus cannot fight momentum.
selection.observed(c)
precondition(selection.transition(to: .idle) == a)
precondition(selection.selectedID == a)
precondition(selection.transition(to: .animating) == nil)
selection.observed(b) // Programmatic intermediate geometry cannot change selection.
precondition(selection.transition(to: .idle) == nil)
precondition(selection.selectedID == a)
_ = selection.transition(to: .interacting)
selection.observed(c)
precondition(selection.transition(to: .idle) == nil)
precondition(selection.selectedID == c)
_ = selection.transition(to: .interacting)
selection.observed(b)
_ = selection.transition(to: .animating) // Native snap still belongs to touch.
precondition(selection.userIsScrolling)
selection.observed(a)
precondition(selection.transition(to: .idle) == nil)
precondition(selection.selectedID == a)
_ = selection.select(c)
precondition(selection.reconcile([b,c]) == c) // Identity survives reordering/filter.
precondition(selection.reconcile([b]) == b)
precondition(selection.reconcile([]) == nil)
precondition(selection.selectedID == nil)
var names = [a: "Puzzle One", b: "Puzzle Two"]
func filteredIDs() -> [UUID] { [a,b].filter { names[$0]!.contains("Puzzle") } }
_ = selection.reconcile(filteredIDs())
_ = selection.select(a)
names[a] = "Renamed Game"
precondition(selection.reconcile(filteredIDs()) == b) // Rename removes selected search result.
precondition(selection.selectedID == b)
precondition(selection.select(b) == b) // Controller selection still has a valid identity.
names[b] = "Another Name"
precondition(selection.reconcile(filteredIDs()) == nil)
precondition(selection.selectedID == nil)
precondition(IridiumLibrarySelection.visibleIndex(offset: 0, stride: 120, count: 3, previous: nil) == 0)
precondition(IridiumLibrarySelection.visibleIndex(offset: 61, stride: 120, count: 3, previous: 0) == 1)
precondition(IridiumLibrarySelection.visibleIndex(offset: 59, stride: 120, count: 3, previous: 1) == 0)
precondition(IridiumLibrarySelection.visibleIndex(offset: 60, stride: 120, count: 3, previous: 1) == 1)
precondition(IridiumLibrarySelection.visibleIndex(offset: -30, stride: 120, count: 3, previous: nil) == 0)
precondition(IridiumLibrarySelection.visibleIndex(offset: 900, stride: 120, count: 3, previous: nil) == 2)
precondition(IridiumLibrarySelection.visibleIndex(offset: 900, stride: 120, count: 1, previous: nil) == 0)
precondition(IridiumLibrarySelection.visibleIndex(offset: 0, stride: 120, count: 0, previous: nil) == nil)
precondition(IridiumLibrarySelection.visibleIndex(offset: .nan, stride: 120, count: 3, previous: nil) == nil)
// Featured first card is wide; every later card remains portrait.
let widths = [210.0, 66.0, 66.0]
precondition(IridiumLibrarySelection.visibleIndex(offset: 0, widths: widths, spacing: 10, focusWidth: 66, previous: nil) == 0)
precondition(IridiumLibrarySelection.visibleIndex(offset: 170, widths: widths, spacing: 10, focusWidth: 66, previous: 0) == 0)
precondition(IridiumLibrarySelection.visibleIndex(offset: 190, widths: widths, spacing: 10, focusWidth: 66, previous: 0) == 1)
precondition(IridiumLibrarySelection.visibleIndex(offset: 220, widths: widths, spacing: 10, focusWidth: 66, previous: 0) == 1)
precondition(IridiumLibrarySelection.visibleIndex(offset: 296, widths: widths, spacing: 10, focusWidth: 66, previous: 1) == 2)
precondition(IridiumLibrarySelection.visibleIndex(offset: 170, widths: widths, spacing: 10, focusWidth: 66, previous: 2) == 0)
precondition(IridiumLibrarySelection.visibleIndex(offset: 182, widths: widths, spacing: 10, focusWidth: 66, previous: 1) == 1)
precondition(IridiumLibrarySelection.visibleIndex(offset: -100, widths: widths, spacing: 10, focusWidth: 66, previous: 2) == 0)
precondition(IridiumLibrarySelection.visibleIndex(offset: .nan, widths: widths, spacing: 10, focusWidth: 66, previous: nil) == nil)
precondition(IridiumLibrarySelection.verticalFocus("games", down: true, wide: true) == "play")
precondition(IridiumLibrarySelection.verticalFocus("play", down: false, wide: true) == "games")
precondition(IridiumLibrarySelection.verticalFocus("games", down: false, wide: true) == "search")
precondition(IridiumLibrarySelection.verticalFocus("games", down: false, wide: false) == "play")
precondition(IridiumLibrarySelection.verticalFocus("play", down: true, wide: false) == "games")
precondition(IridiumLibrarySelection.verticalFocus("options", down: true, wide: true) == "options")
precondition(IridiumLibrarySelection.visibleIndex(offset: 10000, widths: widths, spacing: 10, focusWidth: 66, previous: 0) == 2)
print("Carousel arbitration passed")
''')
            exe = Path(folder) / 'check'
            subprocess.run(['swiftc', str(source), str(main), '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True, timeout=30)
