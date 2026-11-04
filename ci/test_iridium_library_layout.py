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
        self.assertIn('let coverWidth = height / 1.5', source)
        self.assertNotIn('featuredWidth', source)
        self.assertIn('IridiumGameArtwork(game: entry, featured: false)', source)
        self.assertNotIn('settledCoverID', source)
        self.assertIn('x: proxy.frame(in: .scrollView(axis: .horizontal)).minX,', source)
        self.assertIn('content.scaleEffect(geometry.scale, anchor: .bottomLeading)', source)
        self.assertIn('HStack(spacing: 20) { actions(game); title(game) }', source)
        self.assertEqual(source.count('.accessibilityIdentifier("librarySelectionBorder")'), 1)
        self.assertIn('.animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selection.highlightedID)', source)
        self.assertNotIn('if selection.highlightedID == entry.id, !showFocus', source)
        self.assertIn('private struct IridiumLibrarySelectionOutline: Shape', source)
        self.assertIn('var animatableData: CGFloat', source)
        self.assertIn('.onPreferenceChange(IridiumLibraryChromeHeight.self)', source)
        self.assertIn('ScrollView(.vertical)', source)
        self.assertIn('.scrollBounceBehavior(.basedOnSize, axes: .vertical)', source)
        self.assertIn('.frame(height: layout.carouselHeight).id("games")', source)
        self.assertIn('.onChange(of: focus) { _, _ in revealFocusedSection(in: page) }', source)
        # Preserve single-line game titles and immediate, bidirectional selection.
        self.assertIn('IridiumLibraryText(text: name, title: true, multiline: false, animated: !reduceMotion)', source)
        self.assertIn('IridiumLibraryText(text: subtitle, title: false, multiline: dynamicTypeSize.isAccessibilitySize, animated: !reduceMotion)', source)
        self.assertIn('let expands = wideLayout && !reduceMotion', source)
        self.assertIn('.accessibilityLabel(artwork.title(entry))', source)
        self.assertIn('selection.observed(entries[index].id)', source)
        self.assertIn('previous: selection.highlightedID.flatMap { order.firstIndex(of: $0) }', source)
        self.assertIn('showsHints: showHints, frozenCoverHeight: touchCoverHeight', source)
        self.assertIn('if [.tracking, .interacting, .decelerating].contains(next), touchCoverHeight == nil', source)
        self.assertLess(source.index('touchCoverHeight = height'), source.index('showHints = false }', source.index('touchCoverHeight = height')))
        self.assertNotIn('if next == .idle { touchCoverHeight = nil }', source)
        self.assertIn('.onChange(of: height) { _, _ in keepSelection() }', source)
        self.assertIn('.onChange(of: geometry.size.height) { _, _ in touchCoverHeight = nil }', source)
        self.assertNotIn('showHints ? 240 : 212', source)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for actual selection path checks')
    def test_selection_path_stays_inside_current_row_during_resize_and_retarget(self):
        source = SOURCE.read_text()
        shape = source.split('private struct IridiumLibrarySelectionOutline: Shape {', 1)[1].split('// Kept independent', 1)[0]
        geometry = 'struct IridiumLibraryCoverGeometry {' + source.split('struct IridiumLibraryCoverGeometry {', 1)[1]
        checks = r"""
for height: CGFloat in [96, 109.333333, 144, 224] {
    let width = height / 1.5
    for step in 0...300 {
        var outline = IridiumLibrarySelectionOutline(x: 0, scrollX: -CGFloat(step) * 2,
            width: width, height: height, expands: true)
        // Retargeted travel must not interpolate a stale, larger viewport size.
        outline.animatableData = CGFloat(step) * 2.1
        let rect = outline.path(in: CGRect(x: 0, y: 0, width: 900, height: height)).boundingRect
        precondition(rect.minY >= -height * 0.5)
        precondition(rect.maxY <= height + 8)
        precondition(rect.width <= width * 1.5)
        precondition(rect.height <= height * 1.5)
    }
}
print("Actual selection path resize and retarget passed")
"""
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / 'main.swift'
            main.write_text('import SwiftUI\nstruct IridiumLibrarySelectionOutline: Shape {' + shape + geometry + checks)
            executable = Path(folder) / 'check'
            subprocess.run(['swiftc', str(main), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=30)

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
precondition(abs(normal.coverHeight - 109.333333) < 0.001)
precondition(normal.carouselHeight == 172) // Includes all of the expanded cover.
precondition(scaled.coverHeight == 96) // The full minimum remains scrollable.
precondition(scaled.freeSpace == 0)
let withHints = metrics(375, 260, hints: true)
precondition(withHints.coverHeight == 96)
let withSearch = metrics(375, 350)
precondition(withSearch.coverHeight == 96 && withSearch.freeSpace == 0)
let roomy = metrics(600, 155)
precondition(abs(roomy.coverHeight - 216) < 0.001 && abs(roomy.freeSpace - 65) < 0.001)
// A height-only resize must invalidate the frozen stride. An unchanged
// viewport (including release to idle) keeps its existing touch geometry.
let afterHeightResize = metrics(320, 155)
precondition(abs(afterHeightResize.coverHeight - 96) < 0.001)
let idleBeforeResize = IridiumLibraryLayoutMetrics(viewportHeight: 600, compact: true,
    chromeHeight: 155, hasSelection: true, showsHints: false, frozenCoverHeight: roomy.coverHeight)
precondition(idleBeforeResize.coverHeight == roomy.coverHeight)
let portrait = metrics(852, 155, compact: false)
precondition(portrait.coverHeight == 200 && portrait.freeSpace > 0)
let empty = metrics(375, 44, selected: false)
precondition(empty.coverHeight == 0 && empty.freeSpace == 299)
let dragging = IridiumLibraryLayoutMetrics(viewportHeight: 375, compact: true,
    chromeHeight: 155, hasSelection: true, showsHints: false, frozenCoverHeight: 100)
precondition(dragging.coverHeight == 100 && dragging.carouselHeight == 158 && dragging.freeSpace == 14)
let changedStatusDuringSnap = IridiumLibraryLayoutMetrics(viewportHeight: 375, compact: true,
    chromeHeight: 350, hasSelection: true, showsHints: false, frozenCoverHeight: 100)
precondition(changedStatusDuringSnap.coverHeight == 100 && changedStatusDuringSnap.freeSpace == 0)
precondition(abs(metrics(375, 155).coverHeight - 109.333333) < 0.001)

let width: CGFloat = 96, stride = width + 10
let left = IridiumLibraryCoverGeometry(x: 0, width: width, enabled: true)
precondition(left.scale == 1.5 && left.shift == 0 && left.drop == 8)
let approaching = IridiumLibraryCoverGeometry(x: stride / 2, width: width, enabled: true)
precondition(approaching.scale == 1.25 && approaching.drop == 4)
precondition(IridiumLibraryCoverGeometry(x: 0, width: width, enabled: false).scale == 1)
precondition(IridiumLibraryCoverGeometry(x: .nan, width: width, enabled: true).scale == 1)
// Simulate a continuous swipe in either direction. Growth never overlaps
// neighbors or escapes the row reserved for the full 1.5x art and lower edge.
for step in 0...1000 {
    let x = -stride * CGFloat(step) / 1000
    let a = IridiumLibraryCoverGeometry(x: x, width: width, enabled: true)
    let b = IridiumLibraryCoverGeometry(x: x + stride, width: width, enabled: true)
    let c = IridiumLibraryCoverGeometry(x: x + 2 * stride, width: width, enabled: true)
    precondition(abs((x + stride + b.shift) - (x + a.shift + width * a.scale) - 10) < 0.001)
    precondition(abs((x + 2 * stride + c.shift) - (x + stride + b.shift + width * b.scale) - 10) < 0.001)
    for effect in [a, b, c] {
        let height: CGFloat = 144
        let top = height * 1.5 + effect.drop - height * effect.scale
        let bottom = height * 1.5 + effect.drop
        precondition(top >= 0 && bottom <= height * 1.5 + 8)
        precondition(effect.scale >= 1 && effect.scale <= 1.5)
    }
}

for height: CGFloat in [0, 240, 320, 375, 390, 667, 852, 1024] {
    for chrome: CGFloat in [0, 100, 155, 235, 340, 600] {
        for compact in [true, false] {
            for hints in [true, false] {
                let layout = metrics(height, chrome, compact: compact, hints: hints)
                let minimum: CGFloat = 96
                let maximum: CGFloat = compact ? 224 : 200
                let spacing: CGFloat = compact ? 8 : 12
                let occupied = chrome + 24 + CGFloat(hints ? 4 : 3) * spacing
                let total = occupied + layout.carouselHeight + layout.freeSpace
                precondition(layout.coverHeight >= minimum && layout.coverHeight <= maximum)
                precondition(layout.freeSpace >= 0)
                let minimumRow = compact ? minimum * 1.5 + 8 : minimum
                if occupied + minimumRow <= height {
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
