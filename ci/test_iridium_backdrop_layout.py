"""Execute production backdrop geometry for portrait hero composition."""
from pathlib import Path
import json
import os
import plistlib
import time
import shutil
from host_tests import module_cache
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumLibraryBackdrop.swift'


class BackdropLayoutTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('IRIDIUM_CHROME_SIMULATOR'), 'Opt in to a booted simulator for UIKit transition checks')
    def test_actual_canvas_retains_opaque_art_during_rapid_changes(self):
        device = os.environ['IRIDIUM_CHROME_SIMULATOR']
        canvas = SOURCE.read_text().split('struct IridiumBackdropCanvas:', 1)[1]
        fixture = r'''import UIKit
import SwiftUI
struct IridiumBackdropCanvas:''' + canvas + r'''
@main final class FixtureApp: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Check", sessionRole: session.role)
        config.delegateClass = FixtureScene.self; return config
    }
}
final class FixtureScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    let canvas = IridiumBackdropCanvas.Canvas()
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        let window = UIWindow(windowScene: scene as! UIWindowScene), root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible(); self.window = window
        canvas.frame = CGRect(x: 0, y: 0, width: 320, height: 200); root.view.addSubview(canvas)
        let images = (0..<3).map { _ in UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        } }
        canvas.show(images[0], position: 0.5, animated: false)
        canvas.show(images[1], position: 0.5, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let outgoing = self.canvas.subviews.first!.layer.presentation()!
            precondition(outgoing.opacity == 1, "Outgoing artwork must not fade to black")
            for i in 0..<100 {
                self.canvas.show(images[i % 3], position: 0.5, animated: true)
                precondition(self.canvas.subviews.count <= 2, "Interrupted transitions must stay bounded")
                precondition(self.canvas.subviews.first!.alpha == 1)
            }
            self.canvas.frame.size = CGSize(width: 200, height: 320); self.canvas.layoutIfNeeded()
            precondition(self.canvas.subviews.allSatisfy { $0.frame == self.canvas.bounds })
            self.canvas.show(images[0], position: 0.2, animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                precondition(self.canvas.subviews.count == 1 && self.canvas.subviews[0].alpha == 1)
                self.canvas.show(nil, position: 0.5, animated: false)
                precondition(self.canvas.subviews.isEmpty)
                let result = ["opaqueOutgoing": true, "boundedRapidChanges": true, "resize": true, "reducedMotionAndClear": true]
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try! JSONSerialization.data(withJSONObject: result).write(to: folder.appendingPathComponent("RESULT.json"))
            }
        }
    }
}
'''
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
        identifier = 'dev.iridium.backdrop-check'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); app = root / 'Check.app'; app.mkdir()
            unit = root / 'Check.swift'; unit.write_text(fixture)
            info = {'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Check', 'CFBundleName': 'Check',
                    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
                    'MinimumOSVersion': '18.0', 'UILaunchScreen': {},
                    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False, 'UISceneConfigurations': {}}}
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                '-target', 'arm64-apple-ios18.0-simulator', '-sdk', sdk,
                '-module-cache-path', module_cache('iphonesimulator'), str(unit), '-o', str(app / 'Check')], check=True, timeout=90)
            try:
                subprocess.run(['xcrun', 'simctl', 'install', device, str(app)], check=True, timeout=30)
                subprocess.run(['xcrun', 'simctl', 'launch', device, identifier], check=True, timeout=30)
                container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', device, identifier, 'data'], text=True).strip())
                result = container / 'Documents/RESULT.json'; deadline = time.monotonic() + 20
                while not result.exists() and time.monotonic() < deadline: time.sleep(0.2)
                self.assertTrue(result.exists(), 'UIKit checks did not finish')
                self.assertTrue(all(json.loads(result.read_text()).values()))
                print(result.read_text())
            finally:
                subprocess.run(['xcrun', 'simctl', 'terminate', device, identifier], capture_output=True)
                subprocess.run(['xcrun', 'simctl', 'uninstall', device, identifier], capture_output=True)

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
