"""Execute the production carousel arbitration, not a second model of it."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class LibrarySelectionTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for executable carousel checks')
    def test_touch_momentum_focus_and_identity(self):
        source = ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumLibrarySelection.swift'
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / 'main.swift'
            main.write_text('''import Foundation
let a = UUID(), b = UUID(), c = UUID()
let stale = UUID()
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
precondition(currentDrag.token != cancelledDrag.token)
precondition(!drag.accepts(context: cancelledDrag, item: cancelledDrag, local: true, privateType: true))
precondition(!drag.accepts(context: currentDrag, item: cancelledDrag, local: true, privateType: true))
precondition(!drag.accepts(context: currentDrag, item: currentDrag, local: false, privateType: true))
precondition(!drag.accepts(context: currentDrag, item: currentDrag, local: true, privateType: false))
drag.end(cancelledDrag) // A late old callback cannot cancel the new drag.
precondition(drag.active == currentDrag)
precondition(drag.accepts(context: currentDrag, item: currentDrag, local: true, privateType: true))
drag.end(currentDrag)
precondition(drag.active == nil)

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
