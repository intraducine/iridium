"""Execute production callret initialization and the pinned, patched rpmalloc.

Only OS VM/syscall boundaries are modeled. This is not an iPhone execution test.
"""
from pathlib import Path
import shutil
import importlib.util
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FEX = ROOT / 'testrepos/Madeira/FEX'
FIXTURES = ROOT / 'ci/tests/fex_memory'

class FEXMemoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.tmp = Path(cls.temp.name)
        # Stub unrelated platform headers; include the actual production header.
        for header in ('Core/Context.h', 'Utils/Allocator.h', 'Utils/LogManager.h', 'Debug/InternalThreadState.h'):
            path = cls.tmp / 'FEXCore' / header
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('#pragma once\n')
        allocator = FEX / 'External/rpmalloc'
        if not (allocator/'rpmalloc/rpmalloc.c').exists():
            raise RuntimeError('Initialize pinned testrepos/Madeira/FEX/External/rpmalloc before running memory tests')
        common = ['-DFEX_IOS_HOST', '-DENABLE_OVERRIDE=0', '-DRPMALLOC_FIRST_CLASS_HEAPS=1', '-pthread', '-I'+str(FIXTURES)]
        obj = cls.tmp/'allocator.o'
        subprocess.run(['cc','-std=gnu11','-O1','-fsanitize=undefined','-fno-sanitize-recover=undefined',*common,'-I'+str(allocator),'-c',str(FIXTURES/'allocator_harness.c'),'-o',str(obj)],check=True,capture_output=True,text=True)
        cls.exe=cls.tmp/'replay'
        subprocess.run(['c++','-std=c++17','-O1','-fsanitize=undefined','-fno-sanitize-recover=undefined',*common,'-I'+str(cls.tmp),'-I'+str(FEX/'Source/Windows/Common'),str(FIXTURES/'replay.cpp'),str(obj),'-o',str(cls.exe)],check=True,capture_output=True,text=True)

        cls.common = common
        cls.obj = obj
        old = cls.tmp/'old'
        shutil.copytree(allocator/'rpmalloc',old/'rpmalloc')
        subprocess.run(['git','init','-q',str(old)],check=True)
        subprocess.run(['git','-C',str(old),'apply','--reverse',str(ROOT/'ci/patches/rpmalloc-compact-spans.patch')],check=True)
        old_obj=cls.tmp/'old.o'
        subprocess.run(['cc','-std=gnu11','-O1','-fsanitize=undefined','-fno-sanitize-recover=undefined',*common,'-I'+str(old),'-c',str(FIXTURES/'allocator_harness.c'),'-o',str(old_obj)],check=True,capture_output=True,text=True)
        cls.old_exe=cls.tmp/'old-replay'
        subprocess.run(['c++','-std=c++17','-O1','-fsanitize=undefined','-fno-sanitize-recover=undefined',*common,'-I'+str(cls.tmp),'-I'+str(FEX/'Source/Windows/Common'),str(FIXTURES/'replay.cpp'),str(old_obj),'-o',str(cls.old_exe)],check=True,capture_output=True,text=True)

    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()

    def check(self, mode):
        r=subprocess.run([str(self.exe),mode],capture_output=True,text=True,timeout=45)
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertNotIn('runtime error:',r.stderr)
        print(r.stdout.strip())

    def test_reserve_commit_failure_and_retry(self): self.check('failure')
    def test_allocator_size_and_alignment_boundaries(self): self.check('classes')
    def test_twenty_eight_live_translator_threads(self): self.check('replay')
    def test_diagnostic_buffer_is_bounded(self): self.check('diagnostic')

    def test_old_allocator_exhausts_same_workload(self):
        r=subprocess.run([str(self.old_exe),'replay'],capture_output=True,text=True,timeout=45)
        self.assertEqual(r.returncode,42,r.stdout+r.stderr)
        self.assertIn('bounded arena exhausted',r.stderr)

    def test_old_diagnostic_overflows_its_buffer(self):
        r=subprocess.run([str(self.old_exe),'diagnostic'],capture_output=True,text=True,timeout=45)
        self.assertNotEqual(r.returncode,0)
        self.assertIn('out of bounds',r.stderr)

    def test_actual_arm64ec_failure_path_returns_status_and_unlocks(self):
        source=(FEX/'Source/Windows/ARM64EC/Module.cpp').read_text()
        begin=source.index('NTSTATUS ThreadInit() {')
        end=source.index('  Thread->CurrentFrame->Pointers.ExitFunctionEC',begin)
        # Execute the real initialization prefix and its cleanup/return path.
        # The omitted success-only dispatcher patch is not part of this test.
        prefix=source[begin:end]+'  abort();\n}\n'
        test=self.tmp/'thread-init.cpp'
        test.write_text('#include "thread_init_stub.h"\n'+prefix+r'''
int main() {
  model_init(0);
  fail_emulator=true;
  assert(ThreadInit()==STATUS_NO_MEMORY);
  assert(initialized==1 && finalized==1 && created==0 && destroyed==0);
  assert(ThreadCreationMutex.try_lock());ThreadCreationMutex.unlock();
  fail_emulator=false;fail_reserve=true;
  assert(ThreadInit()==STATUS_NO_MEMORY);
  assert(initialized==2 && finalized==2 && created==1 && destroyed==1);
  assert(!TestArea::limit && !TestArea::base);
  assert(ThreadCreationMutex.try_lock());ThreadCreationMutex.unlock();
  fail_reserve=false;fail_commit=true;
  assert(ThreadInit()==STATUS_NO_MEMORY);
  assert(initialized==3 && finalized==3 && created==2 && destroyed==2);
  assert(!TestArea::limit && !TestArea::base);
  assert(!scrub_calls);
  assert(ThreadCreationMutex.try_lock());ThreadCreationMutex.unlock();
}
''')
        exe=self.tmp/'thread-init'
        built=subprocess.run(['c++','-std=c++17','-O1','-fsanitize=undefined','-fno-sanitize-recover=undefined',*self.common,'-I'+str(self.tmp),'-I'+str(FEX/'Source/Windows/Common'),str(test),str(self.obj),'-o',str(exe)],capture_output=True,text=True)
        self.assertEqual(built.returncode,0,built.stderr)
        result=subprocess.run([str(exe)],capture_output=True,text=True,timeout=45)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_patches_upgrade_and_repeat_without_discarding_edits(self):
        spec=importlib.util.spec_from_file_location('rpm_patches',ROOT/'ci/apply-rpmalloc-patches.py')
        mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            # This input still has the old host-arena patch applied.
            shutil.copytree(self.tmp/'old/rpmalloc',root/'rpmalloc')
            source=root/'rpmalloc/rpmalloc.c'
            source.write_text(source.read_text()+'\n/* preserved local note */\n')
            self.assertTrue(mod.apply(root))
            expected=source.read_bytes()
            self.assertFalse(mod.apply(root))
            self.assertEqual(expected,source.read_bytes())
            self.assertIn('preserved local note',source.read_text())

    def test_patch_conflict_is_transactional(self):
        spec=importlib.util.spec_from_file_location('rpm_patches',ROOT/'ci/apply-rpmalloc-patches.py')
        mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'rpmalloc').mkdir()
            source=root/'rpmalloc/rpmalloc.c';source.write_text('unrelated local source\n')
            with self.assertRaises(subprocess.CalledProcessError): mod.apply(root)
            self.assertEqual(source.read_text(),'unrelated local source\n')


if __name__=='__main__': unittest.main()
