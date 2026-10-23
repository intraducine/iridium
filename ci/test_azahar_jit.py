"""Execute the shared allocator boundary without a device or optional sources."""
from pathlib import Path
import importlib.util
import io
import json
import shutil
import subprocess
import tempfile
import tarfile
import textwrap
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class AzaharJITTests(unittest.TestCase):
    def test_moltenvk_reuse_rejects_changed_archive_source_and_manifest(self):
        spec = importlib.util.spec_from_file_location('azahar_receipt_builder', ROOT / 'ci/build-phase3.py')
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'ci').mkdir()
            shutil.copy2(ROOT / 'ci/build-ppsspp-moltenvk.py', root / 'ci/build-ppsspp-moltenvk.py')
            source = root / '.build/azahar/moltenvk-source/MoltenVK'
            source.mkdir(parents=True); (source / 'source.cpp').write_bytes(b'original')
            download = root / '.build/runtime-downloads'; download.mkdir()
            archive = download / 'source.tar'
            with tarfile.open(archive, 'w') as tar:
                member = tarfile.TarInfo('MoltenVK-pinned/source.cpp'); member.size = 8
                tar.addfile(member, io.BytesIO(b'original'))
            checksum = builder.digest(archive); archive = archive.rename(download / (checksum + '.tar'))
            manifest = root / 'ci/azahar-moltenvk-source-inputs.json'
            manifest.write_text(json.dumps([{'name': 'MoltenVK', 'sha256': checksum}]))
            folder = root / '.build/azahar/moltenvk-derived/package-iphoneos'
            library = folder / 'Build/Products/Release-iphoneos/libMoltenVK.a'
            library.parent.mkdir(parents=True); library.write_bytes(b'binary')
            tree = builder.hashlib.sha256(json.dumps({'source.cpp': builder.digest(source / 'source.cpp')}, sort_keys=True).encode()).hexdigest()
            record = {'version': '1.4.1', 'sourceInputs': json.loads(manifest.read_text()),
                      'sourceArchiveSHA256': builder.digest(manifest), 'archiveSHA256': builder.digest(library),
                      'sourceTreeSHA256': {'MoltenVK': tree}}
            (folder / 'component.json').write_text(json.dumps(record))
            with patch.object(builder, 'ROOT', root):
                self.assertEqual(builder.azahar_moltenvk('iphoneos'), (library, record))
                for file in (archive, source / 'source.cpp', manifest, library):
                    original = file.read_bytes(); file.write_bytes(original + b' ')
                    with self.subTest(file=file.name), self.assertRaises(ValueError):
                        builder.azahar_moltenvk('iphoneos')
                    file.write_bytes(original)

    @unittest.skipUnless(shutil.which('c++') and (ROOT / '.build/phase3-downloads/azahar-unified-source-2126.2').is_dir(), 'Azahar source and C++ compiler required')
    def test_native_vulkan_frame_releases_the_libretro_run_loop(self):
        spec = importlib.util.spec_from_file_location('azahar_frame_builder', ROOT / 'ci/build-phase3.py')
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            overlay = builder.generated('azahar', root)
            source = (overlay / 'libretro_window.cpp').read_text()
            body = source[source.index('void EmuWindow_LibRetro::PollEvents() {'):source.index('    LibRetro::PollInput();')]
            fixture = r'''#include <cassert>
namespace Settings {
enum class GraphicsAPI {Software,Vulkan,OpenGL};
struct Option {GraphicsAPI value;GraphicsAPI GetValue(){return value;}};
struct {Option graphics_api;} values;
}
struct EmuWindow_LibRetro {
    bool submitted=false;
    void SwapBuffers(){submitted=true;}
    void PollEvents();
};
BODY
}
int main(){
    for(auto api:{Settings::GraphicsAPI::Software,Settings::GraphicsAPI::Vulkan,Settings::GraphicsAPI::OpenGL}){
        Settings::values.graphics_api.value=api;
        EmuWindow_LibRetro window;window.PollEvents();
        assert(window.submitted==(api!=Settings::GraphicsAPI::OpenGL));
    }
}
'''.replace('BODY', body).replace('#include <cassert>', '#include <cassert>\n#include <initializer_list>')
            unit = root / 'main.cpp'; unit.write_text(fixture)
            subprocess.run(['c++', '-std=c++17', str(unit), '-o', str(root / 'check')], check=True, timeout=30)
            subprocess.run([str(root / 'check')], check=True, timeout=5)

    @unittest.skipUnless(shutil.which('cmake'), 'CMake required')
    def test_build_replaces_architecture_wrappers_and_rejects_duplicate_sources(self):
        hook = (ROOT / 'ci/phase3-targets.cmake').read_text()
        selection = next(line.strip() for line in hook.splitlines() if 'list(FILTER sources EXCLUDE REGEX' in line)
        recipe = (ROOT / 'ci/build-phase3.py').read_text()
        start = recipe.index("    if engine == 'azahar':\n        commands = json.loads", recipe.index('    run(*arguments)'))
        validation = textwrap.dedent(recipe[start:recipe.index("    run('cmake', '--build'", start)])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / 'check.cmake'
            script.write_text('set(sources backend/arm64/address_space.cpp arch_gen/absolute/common/spin_lock_arm64.cpp backend/exception_handler_macos.cpp backend/exception_handler_macos_mig.c backend/exception_handler_generic.cpp backend/arm64/emit_arm64.cpp)\n' + selection + '\nif(NOT sources STREQUAL "backend/arm64/emit_arm64.cpp")\nmessage(FATAL_ERROR "Original JIT implementation remains")\nendif()\n')
            subprocess.run(['cmake', '-P', str(script)], check=True, timeout=10)
            names = ('address_space.cpp', 'spin_lock_arm64.cpp', 'arm_dynarmic.cpp', 'shader_jit.cpp', 'shader_jit_a64_compiler.cpp', 'vk_platform.cpp', 'libretro_window.cpp', 'mouse_tracker.cpp', 'citra_libretro.cpp')
            overlay = root / 'embedding'
            valid = [{'file': str(overlay / name)} for name in names]
            import json
            def check(commands):
                (root / 'compile_commands.json').write_text(json.dumps(commands))
                exec(validation, {'engine': 'azahar', 'build_dir': root, 'embedding': overlay, 'Path': Path, 'json': json})
            check(valid)
            for commands in (valid + [{'file': str(root / 'arch_gen/common/spin_lock_arm64.cpp')}],
                             valid[1:],
                             valid + [{'file': str(root / 'libretro_vk.cpp')}],
                             valid + [{'file': '/source/src/video_core/renderer_vulkan/renderer_vulkan.cpp', 'command': 'c++ -DHAVE_LIBRETRO'}],
                             valid + [{'file': str(root / 'backend/exception_handler_macos.cpp')}]):
                with self.assertRaises(ValueError): check(commands)

    @unittest.skipUnless(shutil.which('c++') and (ROOT / '.build/phase3-downloads/azahar-unified-source-2126.2').is_dir(), 'Azahar unified source and C++ compiler required')
    def test_dynarmic_lock_allocates_after_shared_jit_setup(self):
        spec = importlib.util.spec_from_file_location('azahar_lock_builder', ROOT / 'ci/build-phase3.py')
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            overlay = builder.generated('azahar', root)
            source = (overlay / 'spin_lock_arm64.cpp').read_text()
            body = source[source.index('namespace {'):source.rindex('}  // namespace Dynarmic')]
            fixture = r'''#include <atomic>
#include <cassert>
#include <mutex>
#include <thread>
#include <vector>
static bool ready=false;
static int allocations=0;
static unsigned reads[16],writes[16];
static void lockWord(volatile int* p){while(__atomic_exchange_n(p,1,__ATOMIC_ACQUIRE))std::this_thread::yield();}
static void unlockWord(volatile int* p){__atomic_store_n(p,0,__ATOMIC_RELEASE);}
namespace oaknut {
struct CodeBlock {
    CodeBlock(int){assert(ready);++allocations;}
    unsigned* ptr(){return reads;}
    unsigned* wptr(){return writes;}
    void protect(){} void unprotect(){} void invalidate_all(){}
};
struct CodeGenerator {
    int cursor=0;
    CodeGenerator(unsigned* rw,unsigned* rx){assert(rw==writes&&rx==reads);}
    template<class T>T xptr(){return cursor++?unlockWord:lockWord;}
    void RET(){}
};
}
namespace Dynarmic {
struct SpinLock {void Lock();void Unlock();volatile int storage=0;};
constexpr int X0=0;
void EmitSpinLockLock(oaknut::CodeGenerator&,int){}
void EmitSpinLockUnlock(oaknut::CodeGenerator&,int){}
BODY
}
int main(){
    assert(allocations==0);ready=true;
    Dynarmic::SpinLock lock;int count=0;
    std::vector<std::thread> workers;
    for(int i=0;i<4;++i)workers.emplace_back([&]{for(int j=0;j<5000;++j){lock.Lock();++count;lock.Unlock();}});
    for(auto& thread:workers)thread.join();
    assert(allocations==1&&count==20000&&lock.storage==0);
}
'''.replace('BODY', body)
            unit = root / 'main.cpp'; unit.write_text(fixture)
            binary = root / 'check'
            subprocess.run(['c++', '-std=c++17', '-pthread', str(unit), '-o', str(binary)], check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=5)

    @unittest.skipUnless(shutil.which('c++'), 'C++ compiler required')
    def test_shared_allocator_bounds_failures_and_alias_cleanup(self):
        source = (ROOT / 'iridium/apps/ios/RuntimeBridge/IRAzaharJIT.cpp').read_text()
        body = source[source.index('static std::atomic<IRPhase3JITPrepare>'):source.index('extern "C" bool ir_phase3_core_check_jit')]
        body += source[source.index('extern "C" void ir_azahar_jit_executed'):]
        fixture = r'''#include <atomic>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
using IRPhase3JITPrepare=void*(*)(void*,size_t);
using vm_address_t=uintptr_t;using vm_prot_t=int;using kern_return_t=int;
constexpr int VM_FLAGS_ANYWHERE=1,VM_INHERIT_NONE=0,KERN_SUCCESS=0,VM_PROT_READ=1,VM_PROT_WRITE=2;
static void* const MAP_FAILED=(void*)-1;
static int remapFailure=0,protectFailure=0,prepares=0,remaps=0,unmaps=0,deallocations=0;
static size_t requested=0;
static uintptr_t prepared=0x1000000000ull;
static int getpagesize(){return 16384;}
static int mach_task_self(){return 1;}
static int vm_remap(int,vm_address_t* out,size_t size,int,int,int,vm_address_t rx,bool copy,vm_prot_t*,vm_prot_t*,int){
    ++remaps;assert(rx==prepared && !copy && size==requested);*out=0x2000000000ull;return remapFailure;
}
static int vm_protect(int,vm_address_t address,size_t size,bool maximum,int protection){
    assert(address==0x2000000000ull && size==requested && !maximum && protection==3);return protectFailure;
}
static int vm_deallocate(int,vm_address_t address,size_t size){
    assert(address==0x2000000000ull && size==requested);++deallocations;return 0;
}
static int munmap(void* address,size_t size){assert((uintptr_t)address==prepared && size==requested);++unmaps;return 0;}
static void* prepare(void* address,size_t size){assert(!address);++prepares;requested=size;return (void*)prepared;}
BODY
int main(){
    void* rw=nullptr;
    assert(!ir_azahar_jit_allocate(1,&rw));
    assert(!ir_phase3_core_prepare_jit(nullptr));
    assert(ir_phase3_core_prepare_jit(prepare));
    assert(!ir_azahar_jit_allocate(0,&rw));
    assert(!ir_azahar_jit_allocate(128ull*1024*1024+1,&rw));
    assert(!ir_azahar_jit_allocate(SIZE_MAX,&rw));
    assert(!ir_azahar_jit_allocate(1,nullptr));
    assert(prepares==0);
    assert(ir_azahar_jit_allocate(1,&rw)==(void*)prepared);
    assert(requested==16384 && rw==(void*)0x2000000000ull && unmaps==0 && deallocations==0);
    assert(ir_azahar_jit_allocate(16385,&rw)==(void*)prepared && requested==32768);
    remapFailure=1;rw=(void*)1;
    assert(!ir_azahar_jit_allocate(1,&rw) && !rw && unmaps==1 && deallocations==0);
    remapFailure=0;protectFailure=1;rw=(void*)1;
    assert(!ir_azahar_jit_allocate(1,&rw) && !rw && unmaps==2 && deallocations==1);
    protectFailure=0;
    int oldRemaps=remaps;
    for(uintptr_t invalid : {uintptr_t(0),UINTPTR_MAX,uintptr_t(1)}){
        prepared=invalid;rw=(void*)1;
        assert(!ir_azahar_jit_allocate(1,&rw) && !rw);
    }
    assert(remaps==oldRemaps && unmaps==2);
    assert(ir_phase3_core_jit_status()==0);
    ir_azahar_jit_executed(0);assert(ir_phase3_core_jit_status()==1);
    ir_azahar_jit_executed(1);assert(ir_phase3_core_jit_status()==3);
    assert(ir_phase3_core_prepare_jit(prepare) && ir_phase3_core_jit_status()==0);
}
'''.replace('BODY', body)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unit = root / 'main.cpp'; unit.write_text(fixture)
            binary = root / 'check'
            subprocess.run(['c++', '-std=c++17', str(unit), '-o', str(binary)], check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=5)


if __name__ == '__main__':
    unittest.main()
