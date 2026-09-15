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
    def test_offline_cargo_restore_preserves_lock_and_source_selectors(self):
        import asyncio
        import json
        import os
        import shutil
        import textwrap
        import tomllib
        import urllib.parse
        from types import SimpleNamespace
        from unittest.mock import AsyncMock
        patch_text = (ROOT / 'ci/patches/cerbero-cargo-source-cache.patch').read_text()
        added = textwrap.dedent('\n'.join(line[1:] for line in patch_text.splitlines()
                                       if line.startswith('+') and not line.startswith('+++')
                                       and line != '+import json'))
        scope = dict(os=os, json=json, shutil=shutil, urllib=urllib, FatalError=ValueError)
        exec('async def restore(self, offline, logfile):\n' + textwrap.indent(added, '    '), scope)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cached = root / 'supplied/plugin/cargo-vendor/crate'
            cached.mkdir(parents=True)
            (cached / 'Cargo.toml').write_text('name = "crate"')
            src = root / 'build'
            src.mkdir()
            lock = src / 'Cargo.lock'
            lock.write_text('\n'.join('[[package]]\nsource = ' + json.dumps(source) for source in [
                'registry+https://github.com/rust-lang/crates.io-index',
                'git+https://example.invalid/repo?branch=stable#abcdef',
                'git+https://example.invalid/other?rev=123456#123456']))
            original = lock.read_bytes()
            call = AsyncMock(return_value='{}')
            scope['shell'] = SimpleNamespace(async_call_output=call)
            obj = SimpleNamespace(config=SimpleNamespace(cached_sources=str(root / 'supplied'),
                                  find_toml_module=lambda: tomllib), name='plugin',
                                  cargo_vendor_cache_dir=str(root / 'local/vendor'), src_dir=str(src),
                                  cargo='cargo', env={})
            asyncio.run(scope['restore'](obj, True, None))
            settings = tomllib.loads((src / '.cargo/config.toml').read_text())['source']
            self.assertEqual(settings['https://example.invalid/repo?branch=stable']['branch'], 'stable')
            self.assertEqual(settings['https://example.invalid/other?rev=123456']['rev'], '123456')
            self.assertEqual(settings['crates-io']['replace-with'], 'iridium-vendor')
            self.assertEqual(lock.read_bytes(), original)
            self.assertTrue((root / 'local/vendor/crate/Cargo.toml').is_file())
            self.assertEqual(call.call_args.args[0][-2:], ['--frozen', '--offline'])

    def test_nested_meson_cache_restores_only_verified_bytes(self):
        import os
        import shutil
        import textwrap
        from types import SimpleNamespace
        patch_text = (ROOT / 'ci/patches/cerbero-meson-source-cache.patch').read_text()
        added = textwrap.dedent('\n'.join(line[1:] for line in patch_text.splitlines()
                                       if line.startswith('+') and not line.startswith('+++')))
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cached = root / 'supplied/recipe/source.tar'
            cached.parent.mkdir(parents=True)
            cached.write_bytes(b'verified source')
            target = root / 'working/recipe/source.tar'
            digest = hashlib.sha256(cached.read_bytes()).hexdigest()
            def verify(path, expected):
                if hashlib.sha256(Path(path).read_bytes()).hexdigest() != expected:
                    raise ValueError('Checksum mismatch')
            scope = dict(os=os, shutil=shutil,
                         self=SimpleNamespace(config=SimpleNamespace(cached_sources=str(root / 'supplied')),
                                              package_name='recipe', verify=verify),
                         downloads=[('nested', (('https://unused.invalid', None), str(target), digest))])
            exec(added, scope)
            self.assertEqual(target.read_bytes(), cached.read_bytes())
            target.unlink()
            cached.write_bytes(b'damaged')
            with self.assertRaises(ValueError):
                exec(added, scope)
            self.assertFalse(target.exists())

    def test_media_build_root_is_physical_through_a_symlink(self):
        assignment = next(line for line in (ROOT / 'ci/prepare-media-sdk.sh').read_text().splitlines()
                          if line.startswith('ROOT='))
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            checkout = root / 'real checkout'
            (checkout / 'ci').mkdir(parents=True)
            script = checkout / 'ci/root.sh'
            script.write_text(assignment + '\nprintf "%s" "$ROOT"\n')
            alias = root / 'alias'
            alias.symlink_to(checkout, target_is_directory=True)
            actual = subprocess.check_output(['bash', str(alias / 'ci/root.sh')], text=True)
            self.assertEqual(actual, str(checkout))

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
            helper = 'apply_source_patch() {' + script.split('apply_source_patch() {', 1)[1].split('\n}', 1)[0] + '\n}'
            patches = root / 'ci/patches'
            patches.mkdir(parents=True)
            (patches / patch_file.name).write_bytes(patch_file.read_bytes())
            command = helper + '\napply_source_patch cerbero-gperf-cxx14.patch\n'
            import os
            env = dict(os.environ, ROOT=str(root))
            for _ in range(2):
                subprocess.run(['bash', '-ec', command], env=env, cwd=recipe.parents[2], check=True)
            self.assertIn("meson_options = {'cpp_std': 'c++14'}", recipe.read_text())
            recipe.write_text(recipe.read_text().replace("'c++14'", "'c++20'"))
            result = subprocess.run(['bash', '-ec', command], env=env, cwd=recipe.parents[2], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("'c++20'", recipe.read_text())

    def test_media_can_run_without_runtime_and_is_retained(self):
        workflow = (ROOT / '.github/workflows/build-unsigned-ipa.yml').read_text()
        self.assertIn('needs: [asset-plan, linux-userland, media, prefix, steam]', workflow)
        self.assertIn("needs.steam.result == 'success'", workflow)
        self.assertIn("needs.media.result == 'success'", workflow)
        self.assertIn('--only cerbero-source', workflow)
        self.assertIn('name: media-sdk-with-source', workflow)
        self.assertNotIn('prepare-media-sdk.sh', (ROOT / 'ci/prepare-native-runtime.sh').read_text())

    def test_media_config_tracks_app_target_and_preserves_user_config(self):
        script = (ROOT / 'ci/prepare-media-sdk.sh').read_text()
        setup = script.split("<<'PY'\n", 1)[1].split("\nPY", 1)[0]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = root / 'app.yml'
            app.write_text('    IPHONEOS_DEPLOYMENT_TARGET: "26.0"\n')
            config = root / 'ci.cbc'
            argv = ['-', str(config), str(root / 'build'), '2', str(app)]
            with patch('sys.argv', argv), patch('pathlib.Path.home', return_value=root):
                exec(compile(setup, 'media-config', 'exec'), {})
                values = {}
                exec(config.read_text(), values)
                self.assertEqual(values['ios_min_version'], '26.0')
                exec(compile(setup, 'media-config', 'exec'), {})
                host = root / '.cerbero/cerbero.cbc'
                host.write_text('# existing user configuration\n')
                with self.assertRaises(SystemExit):
                    exec(compile(setup, 'media-config', 'exec'), {})
                self.assertEqual(host.read_text(), '# existing user configuration\n')

    def test_checksum_list_cannot_omit_source_or_reference_other_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            transfer = root / '.build/media-transfer'
            transfer.mkdir(parents=True)
            (transfer / 'source-revision.txt').write_text('a' * 40)
            for manifest in ('', '0' * 64 + '  media-sdk.tar.gz\n',
                             '0' * 64 + '  ../outside\n',
                             ('0' * 64 + '  media-sdk.tar.gz\n') * 2):
                (transfer / 'SHA256SUMS').write_text(manifest)
                with patch.object(media.subprocess, 'check_output', return_value='a' * 40):
                    with self.assertRaises(ValueError):
                        media.restore(root)
