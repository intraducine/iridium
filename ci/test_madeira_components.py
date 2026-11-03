# SPDX-License-Identifier: AGPL-3.0-only
"""Runtime module checks bind recipes, source inventories and signed code bytes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import madeira_components as components

ROOT = Path(__file__).resolve().parents[1]


class RuntimeComponentTests(unittest.TestCase):
    def test_recipe_installer_cannot_consume_remaining_commands(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            recipes = root / 'tools/build'; recipes.mkdir(parents=True)
            shutil.copy2(ROOT / 'vendor/Madeira/tools/build/build-runtime-component.sh', recipes)
            (recipes / 'prepare-graphics.sh').write_text('printf "%s" "$1" > completed\nexit "${RECIPE_RESULT:-0}"\n')
            tools = root / 'bin'; tools.mkdir()
            brew = tools / 'brew'
            brew.write_text('#!/bin/sh\ncase "$1" in\nlist) exit 1;;\ninstall) cat >/dev/null;;\n--prefix) printf /fixture;;\nesac\n')
            brew.chmod(0o755)
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'])
            components.build_recipe(root, 'kosmickrisp', env)
            self.assertEqual((root / 'completed').read_text(), 'kosmickrisp')
            with self.assertRaises(subprocess.CalledProcessError):
                components.build_recipe(root, 'kosmickrisp', dict(env, RECIPE_RESULT='7'))

    def fixture(self, root):
        contract = root / 'tools/build'; contract.mkdir(parents=True)
        shutil.copy2(ROOT / 'vendor/Madeira/tools/build/runtime-components.py', contract / 'runtime-components.py')
        spec = {'moltenvk': {'pins': [], 'inputs': ['recipe.sh'], 'outputs': ['gl/*', 'licenses/*'],
                            'required': ['gl/libMoltenVK.dylib', 'licenses/license.txt']}}
        (contract / 'runtime-components.json').write_text(json.dumps(spec))
        (root / 'recipe.sh').write_text('pinned recipe\n')
        (root / 'iridium-runtime-sources.json').write_text(json.dumps({'schema': 1, 'files': ['recipe.sh'], 'pins': {}}))
        return components.contract(root)

    def test_archive_inventory_binds_replacement_source_and_rejects_escaping_names(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch); module = self.fixture(root)
            before = module.input_key('moltenvk', 'sdk')
            (root / 'recipe.sh').write_text('replacement source\n')
            self.assertNotEqual(before, module.input_key('moltenvk', 'sdk'))
            self.assertNotEqual(module.input_key('moltenvk', 'sdk'), module.input_key('moltenvk', 'different-sdk'))
            (root / 'iridium-runtime-sources.json').write_text(json.dumps({'schema': 1, 'files': ['../escape'], 'pins': {}}))
            with self.assertRaisesRegex(ValueError, 'unsafe runtime path'): components.contract(root)

    @unittest.skipUnless(shutil.which('xcrun') and Path('/usr/bin/codesign').exists(), 'Apple tools required')
    def test_package_allows_signing_changes_but_rejects_changed_code_or_receipts(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch); module = self.fixture(root)
            app = root / 'app/Madeira'; bundle = root / 'staged'
            for base in (app, bundle):
                (base / 'gl').mkdir(parents=True); (base / 'licenses').mkdir()
                (base / 'licenses/license.txt').write_text('fixture licence')
            library = app / 'gl/libMoltenVK.dylib'
            def compile(value, destination):
                subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios18.0',
                    '-dynamiclib', '-x', 'c', '-', '-o', str(destination), '-Wl,-install_name,@rpath/libMoltenVK.dylib'],
                    input='int fixture(void){return ' + str(value) + ';}', text=True, check=True, capture_output=True, timeout=45)
            compile(1, library)
            shutil.copy2(library, bundle / 'gl/libMoltenVK.dylib')
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'iridium.module.fixture',
                            str(bundle / 'gl/libMoltenVK.dylib')], check=True, capture_output=True)
            record = {'schema': 1, 'key': module.input_key('moltenvk', 'sdk'), 'files': {
                name: hashlib.sha256((app / name).read_bytes()).hexdigest()
                for name in ('gl/libMoltenVK.dylib', 'licenses/license.txt')}}
            receipt = root / '.build/iridium-moltenvk.json'; receipt.parent.mkdir(); receipt.write_text(json.dumps(record))
            with patch.object(components, 'EXTRA', ('moltenvk',)):
                self.assertIn('moltenvk', components.verify(root, bundle, 'sdk'))
                compile(2, bundle / 'gl/libMoltenVK.dylib')
                with self.assertRaisesRegex(ValueError, 'Staged Madeira module differs'): components.verify(root, bundle, 'sdk')
                (app / 'licenses/license.txt').write_text('changed licence')
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'): components.verify(root, bundle, 'sdk')
                with self.assertRaisesRegex(ValueError, 'source or SDK'): components.verify(root, bundle, 'different-sdk')

    def test_archive_recipe_metadata_keeps_replacement_source_bytes(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch); original = root / 'original'; original.mkdir()
            def git(*args): return subprocess.check_output(['git', '-C', str(original), *args], text=True).strip()
            git('init', '-q'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid')
            (original / 'unit.c').write_text('upstream source\n'); git('add', '.'); git('commit', '-qm', 'fixture')
            revision = git('rev-parse', 'HEAD')
            upstream = root / 'vendor/Madeira'; upstream.mkdir(parents=True)
            file = upstream / 'unit.c'; file.write_text('replacement source\n')
            (upstream / 'iridium-runtime-sources.json').write_text(json.dumps({'gitSources': []}))
            (root / 'SOURCE-REVISIONS.json').write_text(json.dumps({'vendor/Madeira': revision}))
            (root / 'UPSTREAM-SOURCES.json').write_text(json.dumps({'frontend_runtime': {
                'upstream': 'https://fixture.invalid/source.git', 'revision': revision}}))
            run = subprocess.run
            def local_fetch(args, **kwargs):
                if 'fetch' in args:
                    args = [str(original) if p == 'https://fixture.invalid/source.git' else p for p in args]
                return run(args, **kwargs)
            with patch.object(components.subprocess, 'run', side_effect=local_fetch):
                components.prepare_source_metadata(upstream)
            self.assertEqual(file.read_text(), 'replacement source\n')
            self.assertEqual(subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip(), revision)
