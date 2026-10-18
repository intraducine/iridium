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
        self.assertIn('.modifier(IridiumLibraryMeasureHeight()).id("details")', source)
        self.assertIn('chromeHeight: chromeHeight, hasSelection: selected != nil', source)
        self.assertNotIn('.scrollTargetBehavior(.viewAligned)', source)
        self.assertLess(source.index('Color.clear.frame(height: layout.freeSpace)'), source.index('carousel(height: layout.coverHeight'))
        self.assertIn('entry.id == games.first?.id ? featuredWidth : height / 1.5', source)
        self.assertIn('HStack(spacing: 20) { title(game); actions(game) }', source)
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
        self.assertNotIn('if next == .idle { touchCoverHeight = nil }', source)
        self.assertIn('.onChange(of: height) { _, _ in keepSelection() }', source)
        self.assertIn('.onChange(of: geometry.size.height) { _, _ in touchCoverHeight = nil }', source)
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
precondition(abs(normal.coverHeight - 105) < 0.001)
precondition(scaled.coverHeight == 92) // Actual text growth reduces the cover.
precondition(scaled.freeSpace == 0)
let withHints = metrics(375, 260, hints: true)
precondition(withHints.coverHeight == 72) // The full minimum cover remains scrollable.
let withSearch = metrics(375, 350)
precondition(withSearch.coverHeight == 72 && withSearch.freeSpace == 0)
let roomy = metrics(600, 155)
precondition(abs(roomy.coverHeight - 168) < 0.001 && abs(roomy.freeSpace - 229) < 0.001)
// A height-only resize must invalidate the frozen stride. An unchanged
// viewport (including release to idle) keeps its existing touch geometry.
let afterHeightResize = metrics(320, 155)
precondition(abs(afterHeightResize.coverHeight - 96) < 0.001)
let idleBeforeResize = IridiumLibraryLayoutMetrics(viewportHeight: 600, compact: true,
    chromeHeight: 155, hasSelection: true, showsHints: false, frozenCoverHeight: roomy.coverHeight)
precondition(idleBeforeResize.coverHeight == roomy.coverHeight)
let portrait = metrics(852, 155, compact: false)
precondition(portrait.coverHeight == 180 && portrait.freeSpace > 0)
let empty = metrics(375, 44, selected: false)
precondition(empty.coverHeight == 0 && empty.freeSpace == 299)
let dragging = IridiumLibraryLayoutMetrics(viewportHeight: 375, compact: true,
    chromeHeight: 155, hasSelection: true, showsHints: false, frozenCoverHeight: 100)
precondition(dragging.coverHeight == 100 && dragging.freeSpace == 72)
let changedStatusDuringSnap = IridiumLibraryLayoutMetrics(viewportHeight: 375, compact: true,
    chromeHeight: 350, hasSelection: true, showsHints: false, frozenCoverHeight: 100)
precondition(changedStatusDuringSnap.coverHeight == 100 && changedStatusDuringSnap.freeSpace == 0)
precondition(abs(metrics(375, 155).coverHeight - 105) < 0.001) // A new layout without frozen touch geometry adapts.

for height: CGFloat in [0, 240, 320, 375, 390, 667, 852, 1024] {
    for chrome: CGFloat in [0, 100, 155, 235, 340, 600] {
        for compact in [true, false] {
            for hints in [true, false] {
                let layout = metrics(height, chrome, compact: compact, hints: hints)
                let minimum: CGFloat = 72
                let maximum: CGFloat = compact ? 220 : 180
                let spacing: CGFloat = compact ? 8 : 12
                let occupied = chrome + 24 + CGFloat(hints ? 4 : 3) * spacing
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
