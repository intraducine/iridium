"""Only completed, validated module objects may leave the hosted build workspace."""
import json
import os
from pathlib import Path
import shutil
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
from test_manual_build import load

space = load('windows_module_space', 'free-build-space.py')
driver = load('windows_module_driver', 'build-madeira-windows.py')


class WindowsModuleSpaceTests(unittest.TestCase):
    def environment(self, root):
        return patch.dict(os.environ, GITHUB_ACTIONS='true', RUNNER_ENVIRONMENT='github-hosted',
                          GITHUB_WORKSPACE=str(root), IRIDIUM_CHROME_SIMULATOR='')

    def test_completed_objects_only_and_symlink_boundary_before_any_deletion(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); upstream=root/'vendor/Madeira'; key='a'*64
            tree=upstream/'wine/build-arm64ec'; tree.mkdir(parents=True)
            for name in ('compiler.o','part.obj','library.a','source.c','config.h'):(tree/name).write_text(name)
            keep=upstream/'source.o';keep.write_text('source');(tree/'link.o').symlink_to(keep)
            with self.environment(root):space.cleanup_madeira_module(root,upstream,'windows',key)
            self.assertFalse((tree/'compiler.o').exists());self.assertFalse((tree/'part.obj').exists())
            self.assertTrue(all((tree/name).exists() for name in ('library.a','source.c','config.h')))
            self.assertEqual(keep.read_text(),'source');self.assertTrue((tree/'link.o').is_symlink())
            (tree/'compiler.o').write_text('retain on rejected cleanup')
            second=upstream/'dxmt/build-arm64ec';second.parent.mkdir();second.symlink_to(tree)
            with self.environment(root),self.assertRaises(ValueError):space.cleanup_madeira_module(root,upstream,'windows',key)
            self.assertTrue((tree/'compiler.o').exists())
            for name,bad_key in [('unknown',key),('windows','../escape')]:
                with self.environment(root),self.assertRaises(ValueError):space.cleanup_madeira_module(root,upstream,name,bad_key)
            with patch.dict(os.environ,GITHUB_ACTIONS='false'),self.assertRaises(ValueError):space.cleanup_madeira_module(root,upstream,'windows',key)
            with self.environment(root),patch.dict(os.environ,RUNNER_ENVIRONMENT='self-hosted'),self.assertRaises(ValueError):space.cleanup_madeira_module(root,upstream,'windows',key)

    def test_keyed_object_paths_keep_other_builds_and_finished_outputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);upstream=root/'vendor/Madeira';key='a'*64
            for k in [key,'b'*64]:
                tree=upstream/f'toolchains/graphics/{k}/obj';tree.mkdir(parents=True)
                (tree/'shader.o').write_text('object');(tree/'module.dll').write_text('finished')
            with self.environment(root):space.cleanup_madeira_module(root,upstream,'zink',key)
            self.assertFalse((upstream/f'toolchains/graphics/{key}/obj/shader.o').exists())
            self.assertTrue((upstream/f'toolchains/graphics/{key}/obj/module.dll').exists())
            self.assertTrue((upstream/('toolchains/graphics/'+'b'*64+'/obj/shader.o')).exists())

    def test_each_validated_recipe_precedes_cleanup_and_i386_keeps_reserve(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'.build').mkdir();events=[]
            def build(upstream,sdk):
                name=driver.madeira_components.EXTRA[0];events.append(('validated',name))
                (root/f'.build/iridium-{name}.json').write_text(json.dumps({'key':'a'*64}))
            def windows():
                events.append(('i386','built'))
                (root/'.build/iridium-i386.json').write_text(json.dumps({'key':'b'*64}))
            frontend=SimpleNamespace(UPSTREAM=root,compiler_identity=lambda:'sdk',windows=windows)
            cleanup=SimpleNamespace(cleanup_madeira_module=lambda r,u,n,k:events.append(('cleanup',n)))
            names=driver.madeira_components.EXTRA
            with patch.object(driver.madeira_components,'build',side_effect=build),patch.object(driver.shutil,'disk_usage',return_value=shutil._ntuple_diskusage(100,0,60*1024**3)):
                driver.build(frontend,cleanup)
            self.assertEqual(driver.madeira_components.EXTRA,names)
            self.assertEqual(events,[(stage,name) for name in names for stage in ('validated','cleanup')]+[('i386','built'),('cleanup','i386')])
            events.clear()
            with patch.object(driver.madeira_components,'build',side_effect=ValueError('failed validation')),self.assertRaises(ValueError):driver.build(frontend,cleanup)
            self.assertFalse(events);self.assertEqual(driver.madeira_components.EXTRA,names)
            with patch.object(driver.madeira_components,'build',side_effect=build),patch.object(driver.shutil,'disk_usage',return_value=shutil._ntuple_diskusage(100,0,39*1024**3)),self.assertRaisesRegex(ValueError,'reserve'):
                driver.build(frontend,cleanup)
            self.assertNotIn(('i386','built'),events)
