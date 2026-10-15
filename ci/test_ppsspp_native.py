"""Native PSP preparation contracts; runtime acceptance requires an Apple build."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'ci'))
import ppsspp_native_overlay as overlay
spec = importlib.util.spec_from_file_location('native_psp', ROOT / 'ci/build-ppsspp-native.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class NativePSPPreparationTests(unittest.TestCase):
    def test_every_gl_compiler_dependency_uses_the_adapted_header(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);header=root/'source/Common/GPU/OpenGL/GLRenderManager.h'
            header.parent.mkdir(parents=True);header.write_text('adapted class layout')
            old=root/'upstream/GLRenderManager.h';old.parent.mkdir();old.write_text('old class layout')
            with patch.object(native,'output',return_value='    '+str(header)+'\n'):
                self.assertEqual(native.gl_sync_headers(root)['references'],1)
            with patch.object(native,'output',return_value='    '+str(header)+'\n    '+str(old)+'\n'):
                with self.assertRaisesRegex(ValueError,'unadapted upstream'):native.gl_sync_headers(root)

    def test_native_target_requires_media_and_keeps_native_frontend(self):
        with patch.object(native, 'output', return_value='/SDK'):
            command = native.configure(Path('/source'), Path('/output'), 'iphoneos')
        self.assertIn('-DLIBRETRO=OFF', command)
        self.assertIn('-DUSE_FFMPEG=ON', command)
        self.assertIn('-DFFMPEG_DIR=/output/ffmpeg', command)
        self.assertNotIn('-DUSE_MINIUPNPC=OFF', command)
        self.assertNotIn('-DUSE_FFMPEG=OFF', command)

    def test_full_assets_are_copied_and_unsafe_destination_is_rejected_before_writes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve(); source = root / 'source'; target = root / 'assets'
            for name in ('compat.ini', 'shaders/example.glsl', 'lang/en_US.ini', 'themes/default.ini', 'font.ttf'):
                f = source / 'assets' / name; f.parent.mkdir(parents=True, exist_ok=True); f.write_bytes(name.encode())
            hashes = native.assets(source, target)
            self.assertIn('font.ttf', hashes); self.assertIn('themes/default.ini', hashes)
            original = root / 'retained'; (target / 'shaders').rename(original)
            (target / 'shaders').symlink_to(original, target_is_directory=True)
            (source / 'assets/compat.ini').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'symbolic'):
                native.assets(source, target)
            self.assertEqual((target / 'compat.ini').read_bytes(), b'compat.ini')

    def test_release_source_hooks_preserve_engine_and_remove_app_ownership(self):
        source = ROOT / 'vendor/PPSSPP'
        if not (source / 'ios/main.mm').exists(): self.skipTest('Release source checkout required')
        platform = overlay.apply('ios/main.mm', (source / 'ios/main.mm').read_text())
        self.assertNotIn('int main(', platform)
        self.assertNotIn('exit(0)', platform)
        self.assertIn('ir_native_psp_restart()', platform)
        self.assertIn('ir_native_psp_jit_available()', platform)
        engine = (source / 'UI/NativeApp.cpp').read_text()
        adapted = overlay.apply('UI/NativeApp.cpp', engine)
        self.assertEqual(adapted.count('g_Config.memStickDirectory = Path(savegame_dir);'), 1)
        for name in ('ios/ViewController.mm', 'ios/ViewControllerMetal.mm'):
            adapted = overlay.apply(name, (source / name).read_text())
            self.assertIn('iridiumAwaitRenderLoop:', adapted)
            self.assertIn('ir_native_psp_renderer_ready()', adapted)
            self.assertNotIn('[UIApplication sharedApplication].delegate screen', adapted)

    def test_overlay_fails_when_upstream_ownership_hook_drifts(self):
        with self.assertRaisesRegex(ValueError, 'embedding hook changed'):
            overlay.apply('UI/NativeApp.cpp', 'Unreviewed source')


if __name__ == '__main__': unittest.main()
