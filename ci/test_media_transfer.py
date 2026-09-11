import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import subprocess
import unittest
from unittest.mock import patch
from test_manual_build import load, ROOT

media = load('media_restore', 'restore-media-sdk.py')


class MediaTransferTests(unittest.TestCase):
    def test_transfer_checks_revision_hashes_and_restores_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            transfer = root / '.build/media-transfer'
            transfer.mkdir(parents=True)
            (transfer / 'source-revision.txt').write_text('a' * 40)
            archive = transfer / 'media-sdk.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                member = tarfile.TarInfo('media-sdk/GStreamer.xcframework/ios-arm64/libGStreamer.a')
                member.size = 2
                tar.addfile(member, io.BytesIO(b'ok'))
            source = transfer / 'cerbero-1.28.6.tar.xz'
            source.write_bytes(b'source fixture')
            (transfer / 'SHA256SUMS').write_text(''.join(
                hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n'
                for p in (archive, source)))
            with patch.object(media.subprocess, 'check_output', return_value='b' * 40):
                with self.assertRaises(ValueError):
                    media.restore(root)
            with patch.object(media.subprocess, 'check_output', return_value='a' * 40):
                original = source.read_bytes()
                source.write_bytes(b'changed')
                with self.assertRaises(media.subprocess.CalledProcessError):
                    media.restore(root)
                source.write_bytes(original)
                media.restore(root)
            self.assertEqual((root / '.build/corresponding-source' / source.name).read_bytes(), original)
            self.assertTrue((root / 'iridium/apps/ios/.build/media-sdk/GStreamer.xcframework/ios-arm64/libGStreamer.a').is_file())

    def test_recipe_patch_changes_nested_source_inside_checkout(self):
        patch_file = ROOT / 'ci/patches/cerbero-gperf-cxx14.patch'
        # Recover the exact preimage hunk without a network test dependency.
        lines = patch_file.read_text().splitlines()
        hunk = lines[lines.index(next(line for line in lines if line.startswith('@@')))+1:]
        original = ''.join(line[1:] + '\n' for line in hunk if line.startswith((' ', '-')))
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            recipe = root / '.build/runtime-sources/cerbero/recipes/build-tools/gperf.recipe'
            recipe.parent.mkdir(parents=True)
            recipe.write_text(original)
            script = (ROOT / 'ci/prepare-media-sdk.sh').read_text()
            command = next(line for line in script.splitlines()
                           if line.startswith('git ') and '--check' not in line)
            command = command.replace('$ROOT', str(root)).replace(
                str(root / 'ci/patches/cerbero-gperf-cxx14.patch'), str(patch_file))
            subprocess.run(['bash', '-c', command], cwd=recipe.parents[2], check=True)
            self.assertIn("meson_options = {'cpp_std': 'c++14'}", recipe.read_text())

    def test_media_can_run_without_runtime_and_is_retained(self):
        workflow = (ROOT / '.github/workflows/build-unsigned-ipa.yml').read_text()
        self.assertIn('needs: [linux-userland, media]', workflow)
        self.assertIn("!inputs.media_only && needs.media.result == 'success'", workflow)
        self.assertIn('--only cerbero-source', workflow)
        self.assertIn('name: media-sdk-with-source', workflow)
        self.assertNotIn('prepare-media-sdk.sh', (ROOT / 'ci/prepare-native-runtime.sh').read_text())
