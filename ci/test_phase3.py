"""Phase 3 build reuse and corresponding-source boundaries."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'ci' / file)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


builder = load('phase3_test_builder', 'build-phase3.py')
collector = load('phase3_test_collector', 'collect-madeira-source.py')


class Phase3Tests(unittest.TestCase):
    def test_reuse_rejects_changed_abi_generated_and_compiled_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            # Source CI deliberately leaves optional engine submodules absent.
            # Discover the production input paths without reading those files,
            # then exercise real hashing against a complete temporary fixture.
            with patch.object(builder, 'digest', return_value='fixture'):
                inputs = builder.fixed_inputs('host')
            for name in inputs:
                target = root / name; target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('fixture input: ' + name + '\n')
            generated = root / '.build/phase3/host/iphoneos/embedding/native.exports'
            generated.parent.mkdir(parents=True); generated.write_text('_export\n')
            compiled = root / 'generated.c'; compiled.write_text('int value;\n')
            with patch.object(builder, 'ROOT', root):
                record = dict(engine='host', sdk='iphoneos', buildInputs=builder.fixed_inputs('host'),
                    compiledInputs={'generated.c': builder.digest(compiled)},
                    embedding={'native.exports': builder.digest(generated)})
                builder.verify_inputs(record)
                for target in (root / 'iridium/apps/ios/RuntimeBridge/IRPhase3.h',
                               root / 'vendor/Flycast/core/deps/libretro-common/include/libretro.h',
                               generated, compiled):
                    original = target.read_bytes(); target.write_bytes(original + b'changed')
                    with self.assertRaises(ValueError): builder.verify_inputs(record)
                    target.write_bytes(original)

    def test_source_state_rejects_dirty_source_and_changed_nested_pin(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'vendor/Engine'; source.mkdir(parents=True)
            env = dict(os.environ, GIT_AUTHOR_NAME='intraducine', GIT_COMMITTER_NAME='intraducine',
                GIT_AUTHOR_EMAIL='265588704+intraducine@users.noreply.github.com',
                GIT_COMMITTER_EMAIL='265588704+intraducine@users.noreply.github.com')
            def git(path, *args):
                return subprocess.check_output(['git', '-C', str(path), *args], env=env, stderr=subprocess.DEVNULL)
            git(source, 'init', '-q')
            child = source / 'dependency'; child.mkdir(); git(child, 'init', '-q')
            (child / 'source.c').write_text('int first;\n'); git(child, 'add', '.'); git(child, 'commit', '-qm', 'Fixture')
            (source / 'source.c').write_text('int root;\n'); git(source, 'add', '.'); git(source, 'commit', '-qm', 'Fixture')
            with patch.object(builder, 'ROOT', root):
                self.assertEqual(len(builder.source_state(source)), 2)
                (source / 'source.c').write_text('modified\n')
                with self.assertRaises(ValueError): builder.source_state(source)
                git(source, 'checkout', '--', 'source.c')
                (child / 'source.c').write_text('int second;\n'); git(child, 'add', '.'); git(child, 'commit', '-qm', 'Fixture changed')
                with self.assertRaises(ValueError): builder.source_state(source)

    def test_only_byte_identical_cmake_zconf_rename_is_allowed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'vendor/libchdr'; source.mkdir(parents=True)
            env = dict(os.environ, GIT_AUTHOR_NAME='intraducine', GIT_COMMITTER_NAME='intraducine',
                GIT_AUTHOR_EMAIL='265588704+intraducine@users.noreply.github.com',
                GIT_COMMITTER_EMAIL='265588704+intraducine@users.noreply.github.com')
            def git(*args): subprocess.run(['git', '-C', str(source), *args], env=env, check=True, stdout=subprocess.DEVNULL)
            git('init', '-q')
            header = source / 'deps/zlib-1.3.1/zconf.h'; header.parent.mkdir(parents=True); header.write_text('original\n')
            git('add', '.'); git('commit', '-qm', 'Fixture')
            included = header.with_name('zconf.h.included'); header.rename(included)
            with patch.object(builder, 'ROOT', root):
                builder.source_state(source)
                included.write_text('modified\n')
                with self.assertRaises(ValueError): builder.source_state(source)

    def test_every_new_binary_has_a_source_component(self):
        for name in ('libIridiumRetroPlayer.dylib', 'libIridiumDolphin.dylib', 'azahar_libretro.dylib',
                     'play_libretro_ios.dylib', 'flycast_libretro.dylib'):
            self.assertTrue(collector.binary_component('Frameworks/' + name))
        with self.assertRaises(ValueError): collector.binary_component('Frameworks/unknown.dylib')

    def test_flycast_context_overlay_is_checked_against_upstream(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'vendor/Flycast/core/deps/libretro-common/glsm/glsm.c'
            source.parent.mkdir(parents=True)
            source.write_text('#ifdef HAVE_OPENGLES\n   hw_render.context_type       = RETRO_HW_CONTEXT_OPENGLES2;\n#endif\n')
            with patch.object(builder, 'ROOT', root):
                generated = builder.generated('flycast', root / 'output')
                self.assertIn('#ifdef HAVE_OPENGLES3', (generated / 'glsm.c').read_text())
                source.write_text('upstream changed\n')
                with self.assertRaises(ValueError): builder.generated('flycast', root / 'output')
