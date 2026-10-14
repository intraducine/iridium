"""Execute production backdrop geometry for whole-art portrait composition."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumLibraryBackdrop.swift'


class BackdropLayoutTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for backdrop geometry checks')
    def test_portrait_preserves_subjects_and_landscape_preserves_crop(self):
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
            let layout = IridiumBackdropLayout(imageSize: image, viewport: viewport, position: position)
            let frame = layout.artworkFrame
            precondition(abs(frame.width / frame.height - image.width / image.height) < 0.001)
            precondition(abs(frame.minY - (viewport.height - frame.height) * position) < 0.001)
            if viewport.height > viewport.width {
                precondition(layout.showsAmbient)
                // Every point in the selected artwork, including far-left and
                // far-right subjects, remains inside the portrait viewport.
                precondition(frame.minX >= -0.001 && frame.maxX <= viewport.width + 0.001)
                precondition(frame.minY >= -0.001 && frame.maxY <= viewport.height + 0.001)
                precondition(abs(frame.width - viewport.width) < 0.001 || abs(frame.height - viewport.height) < 0.001)
                precondition(layout.fillFrame.width >= viewport.width - 0.001)
                precondition(layout.fillFrame.height >= viewport.height - 0.001)
            } else {
                precondition(!layout.showsAmbient)
                let previousScale = max(viewport.width / image.width, viewport.height / image.height)
                let oldSize = CGSize(width: image.width * previousScale, height: image.height * previousScale)
                precondition(frame == CGRect(x: (viewport.width - oldSize.width) / 2,
                    y: (viewport.height - oldSize.height) * position, width: oldSize.width, height: oldSize.height))
            }
        }
    }
}
let empty = IridiumBackdropLayout(imageSize: .zero, viewport: .zero, position: 0.5)
precondition(empty.artworkFrame == .zero && empty.fillFrame == .zero)
print("Whole-art portrait geometry and unchanged landscape crop passed")
'''
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / 'main.swift'
            main.write_text('import Foundation\nimport CoreGraphics\n' + geometry + checks)
            executable = Path(folder) / 'check'
            subprocess.run(['swiftc', str(main), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
