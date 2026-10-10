"""Check measured library sizing without maintaining a second layout model."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumLibraryView.swift'


class LibraryLayoutTests(unittest.TestCase):
    def test_measured_chrome_and_reachable_overflow_are_wired(self):
        source = SOURCE.read_text()
        # Measurement must exclude the flexible inset and fixed-height carousel.
        self.assertIn('.modifier(IridiumLibraryMeasureHeight())\n                                    .padding(.top, layout.freeSpace)', source)
        self.assertIn('chromeHeight: chromeHeight, hasSelection: selected != nil', source)
        self.assertIn('.onPreferenceChange(IridiumLibraryChromeHeight.self)', source)
        self.assertIn('ScrollView(.vertical)', source)
        self.assertIn('.scrollBounceBehavior(.basedOnSize, axes: .vertical)', source)
        self.assertIn('.frame(height: layout.coverHeight).id("games")', source)
        self.assertIn('.onChange(of: focus) { _, _ in revealFocusedSection(in: page) }', source)
        # Preserve single-line game titles and immediate, bidirectional selection.
        self.assertIn('Text(artwork.title(entry)).font(.title2.weight(.semibold)).lineLimit(1)', source)
        self.assertIn('.accessibilityLabel(artwork.title(entry))', source)
        self.assertIn('selection.observed(games[index].id)', source)
        self.assertIn('previous: games.firstIndex(where: { $0.id == selection.highlightedID })', source)
        self.assertIn('showsHints: showHints, frozenCoverHeight: touchCoverHeight', source)
        self.assertIn('if [.tracking, .interacting, .decelerating].contains(next), touchCoverHeight == nil', source)
        self.assertLess(source.index('touchCoverHeight = height'), source.index('showHints = false }', source.index('touchCoverHeight = height')))
        self.assertLess(source.index('let target = selection.transition(to: next)'), source.index('if next == .idle { touchCoverHeight = nil }'))
        self.assertIn('.onChange(of: height) { _, _ in keepSelection() }', source)
        self.assertNotIn('showHints ? 240 : 212', source)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for executable library geometry checks')
    def test_actual_geometry_handles_scaled_text_search_and_hints(self):
        source = SOURCE.read_text()
        marker = 'struct IridiumLibraryLayoutMetrics {'
        geometry = marker + source.split(marker, 1)[1]
        checks = r'''
func metrics(_ height: CGFloat, _ chrome: CGFloat, compact: Bool = true,
             hints: Bool = false, selected: Bool = true) -> IridiumLibraryLayoutMetrics {
    IridiumLibraryLayoutMetrics(viewportHeight: height, compact: compact,
        chromeHeight: chrome, hasSelection: selected, showsHints: hints)
}
let normal = metrics(375, 155)
let scaled = metrics(375, 235)
precondition(normal.coverHeight == 180)
precondition(scaled.coverHeight == 100) // Actual text growth reduces the cover.
precondition(scaled.freeSpace == 0)
let withHints = metrics(375, 260, hints: true)
precondition(withHints.coverHeight == 72) // The full minimum cover remains scrollable.
let withSearch = metrics(375, 350)
precondition(withSearch.coverHeight == 72 && withSearch.freeSpace == 0)
let roomy = metrics(600, 155)
precondition(roomy.coverHeight == 192 && roomy.freeSpace == 213)
let portrait = metrics(852, 155, compact: false)
precondition(portrait.coverHeight == 264 && portrait.freeSpace > 0)
let empty = metrics(375, 44, selected: false)
precondition(empty.coverHeight == 0 && empty.freeSpace == 299)
let dragging = IridiumLibraryLayoutMetrics(viewportHeight: 375, compact: true,
    chromeHeight: 155, hasSelection: true, showsHints: false, frozenCoverHeight: 100)
precondition(dragging.coverHeight == 100 && dragging.freeSpace == 80)
let changedStatusDuringSnap = IridiumLibraryLayoutMetrics(viewportHeight: 375, compact: true,
    chromeHeight: 350, hasSelection: true, showsHints: false, frozenCoverHeight: 100)
precondition(changedStatusDuringSnap.coverHeight == 100 && changedStatusDuringSnap.freeSpace == 0)
precondition(metrics(375, 155).coverHeight == 180) // Adapt again only after idle.

for height: CGFloat in [0, 240, 320, 375, 390, 667, 852, 1024] {
    for chrome: CGFloat in [0, 100, 155, 235, 340, 600] {
        for compact in [true, false] {
            for hints in [true, false] {
                let layout = metrics(height, chrome, compact: compact, hints: hints)
                let minimum: CGFloat = compact ? 72 : 156
                let maximum: CGFloat = compact ? 192 : 264
                let spacing: CGFloat = compact ? 8 : 12
                let occupied = chrome + 24 + CGFloat(hints ? 3 : 2) * spacing
                let total = occupied + layout.coverHeight + layout.freeSpace
                precondition(layout.coverHeight >= minimum && layout.coverHeight <= maximum)
                precondition(layout.freeSpace >= 0)
                if occupied + minimum <= height {
                    precondition(abs(total - height) < 0.001) // Fits without clipping.
                } else {
                    precondition(layout.coverHeight == minimum && layout.freeSpace == 0)
                    precondition(total > height) // Overflow is content, not a cropped frame.
                }
            }
        }
    }
}
print("Measured library geometry passed")
'''
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / 'main.swift'
            main.write_text('import Foundation\n' + geometry + checks)
            executable = Path(folder) / 'check'
            subprocess.run(['swiftc', str(main), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
