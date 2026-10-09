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
var selection = IridiumLibrarySelection()
precondition(selection.reconcile([a,b,c]) == a)
precondition(selection.select(b) == b)
precondition(selection.selectedID == b)
precondition(selection.transition(to: .tracking) == nil)
selection.observed(c)
precondition(selection.selectedID == b) // Commit backdrop at landing, not mid-drag.
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
print("Carousel arbitration passed")
''')
            exe = Path(folder) / 'check'
            subprocess.run(['swiftc', str(source), str(main), '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True, timeout=30)
