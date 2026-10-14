"""Execute production backdrop geometry for portrait hero composition."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumLibraryBackdrop.swift'


class BackdropLayoutTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for backdrop geometry checks')
    def test_portrait_hero_fills_region_and_landscape_preserves_crop(self):
        marker = 'struct IridiumBackdropLayout {'
        source = SOURCE.read_text()
        geometry = marker + source.split(marker, 1)[1]
        checks = r'''
for viewport in [CGSize(width: 375, height: 667), CGSize(width: 440, height: 956),
                 CGSize(width: 768, height: 1024), CGSize(width: 844, height: 390),
                 CGSize(width: 1024, height: 768), CGSize(width: 500, height: 500)] {
    for image in [CGSize(width: 1920, height: 620), CGSize(width: 600, height: 900),
                  CGSize(width: 1024, height: 1024), CGSize(width: 100, height: 2000)] {
        for position in [0.0, 0.2, 0.5, 0.8, 1.0] {
            let portrait = viewport.height > viewport.width
            let layout = IridiumBackdropLayout(imageSize: image, viewport: viewport, position: position, portrait: portrait)
            let frame = layout.artworkFrame
            let hero = layout.heroFrame
            precondition(abs(frame.width / frame.height - image.width / image.height) < 0.001)
            precondition(abs(frame.minY - (hero.height - frame.height) * position) < 0.001)
            precondition(frame.minX <= 0.001 && frame.maxX >= hero.width - 0.001)
            precondition(frame.minY <= 0.001 && frame.maxY >= hero.height - 0.001)
            if portrait {
                // The hero starts at the top and occupies a substantial region,
                // without the former thin fitted strip or empty blur above it.
                precondition(hero.minY == 0 && hero.width == viewport.width)
                precondition(hero.height == min(viewport.height * 0.78, viewport.width * 1.5))
                precondition(hero.height >= viewport.height * 0.6)
            } else {
                precondition(hero.size == viewport)
                let previousScale = max(viewport.width / image.width, viewport.height / image.height)
                let oldSize = CGSize(width: image.width * previousScale, height: image.height * previousScale)
                precondition(frame == CGRect(x: (viewport.width - oldSize.width) / 2,
                    y: (viewport.height - oldSize.height) * position, width: oldSize.width, height: oldSize.height))
            }
        }
    }
}
let empty = IridiumBackdropLayout(imageSize: .zero, viewport: .zero, position: 0.5, portrait: true)
precondition(empty.artworkFrame == .zero && empty.heroFrame == .zero)
print("Portrait hero geometry and unchanged landscape crop passed")
'''
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / 'main.swift'
            main.write_text('import Foundation\nimport CoreGraphics\n' + geometry + checks)
            executable = Path(folder) / 'check'
            subprocess.run(['swiftc', str(main), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
