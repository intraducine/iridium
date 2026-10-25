"""Execute the PS2 and Dreamcast allocators through separate RW/RX mappings."""
from pathlib import Path
import importlib.util
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'


@unittest.skipUnless(sys.platform == 'darwin' and platform.machine() == 'arm64' and shutil.which('clang++'), 'Apple arm64 Mach memory APIs required')
class SharedJITMemoryTests(unittest.TestCase):
    def test_native_probes_rewrite_executable_alias_and_release_both_mappings(self):
        fixture = r'''#include "IRSharedJITMemory.h"
#include <cassert>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <set>
#include <thread>
#include <vector>
#include <sys/mman.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>
#ifdef TEST_PLAY_MEMORY
#include "MemoryFunction.h"
#include "AppConfig.h"
extern "C" bool ir_phase3_core_prepare(const char *);
#endif
extern "C" bool ir_phase3_core_check_jit();
static std::atomic<unsigned> preparations{0};
static void *prepare(void *, size_t size) {
    ++preparations;
    return mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
}
static void *fail(void *, size_t) { return nullptr; }
namespace virtmem {
void flush_cache(void *start, void *end, void *write, void *write_end) {
    sys_icache_invalidate(write, (char *)write_end - (char *)write);
    sys_icache_invalidate(start, (char *)end - (char *)start);
}
}
int main() {
    void *write = (void *)1;
    assert(!ir_shared_jit_allocate(8, &write) && !write);
    assert(!ir_phase3_core_prepare_jit(nullptr));
    assert(ir_phase3_core_prepare_jit(fail));
    assert(!ir_shared_jit_allocate(8, &write) && !write);
    assert(ir_phase3_core_prepare_jit(prepare));
    assert(!ir_shared_jit_allocate(0, &write) && !write);
    assert(!ir_shared_jit_allocate(128 * 1024 * 1024 + 1, &write) && !write);
    assert(!ir_shared_jit_allocate(8, nullptr));
    for (int attempt = 0; attempt < 3; ++attempt) assert(ir_phase3_core_check_jit());
#ifdef TEST_PLAY_MEMORY
    assert(!ir_phase3_core_prepare(nullptr) && !ir_phase3_core_prepare(""));
    assert(ir_phase3_core_prepare("first-game"));
    assert(CAppConfig::GetInstance().root == "first-game" && CAppConfig::constructed == 1);
    assert(ir_phase3_core_prepare("second-game"));
    assert(CAppConfig::GetInstance().root == "second-game" && CAppConfig::constructed == 2);
    assert(!ir_phase3_core_prepare("") && CAppConfig::GetInstance().root == "second-game");
    assert(preparations == 1);
#else
    assert(preparations == 3);
#endif
    void *code = ir_shared_jit_allocate(8, &write);
    assert(code && write && code != write && ir_shared_jit_write(code) == write);
    const uint32_t instructions[] = {0xd2800540, 0xd65f03c0};
    memcpy(write, instructions, sizeof instructions);
    sys_icache_invalidate(code, sizeof instructions);
    assert(((int (*)())code)() == 42);
    ir_shared_jit_release(write);
    assert(!ir_shared_jit_write(code));
    ir_shared_jit_release(code);
#ifdef TEST_PLAY_MEMORY
    {
        CMemoryFunction original(instructions, sizeof instructions);
        auto copy = original.CreateInstance();
        assert(original.GetSize() == sizeof instructions && copy.GetSize() == sizeof instructions);
        assert(((int (*)())copy.GetCode())() == 42);
    }
#endif
    unsigned pooled_preparations = preparations.load();
    std::vector<void *> blocks, writes;
    std::set<void *> unique;
    for (unsigned i = 0; i < 1025; ++i) {
        void *write = nullptr;
        void *block = ir_shared_jit_allocate(8, &write);
        assert(block && write && unique.insert(block).second);
        assert(*(uint32_t *)write == 0);
        *(uint32_t *)write = i + 1;
        blocks.push_back(block); writes.push_back(write);
    }
    assert(preparations == pooled_preparations + 1);
    ir_shared_jit_release(blocks[7]); unique.erase(blocks[7]);
    blocks[7] = ir_shared_jit_allocate(8, &writes[7]);
    assert(blocks[7] && unique.insert(blocks[7]).second && *(uint32_t *)writes[7] == 0);
    *(uint32_t *)writes[7] = 8;
    assert(preparations == pooled_preparations + 1);
    for (unsigned i = 0; i < blocks.size(); ++i) {
        assert(*(uint32_t *)blocks[i] == i + 1);
        ir_shared_jit_release(i % 2 ? blocks[i] : writes[i]);
        assert(!ir_shared_jit_write(blocks[i]));
    }
    blocks.resize(16); writes.resize(16);
    std::vector<std::thread> workers;
    for (unsigned i = 0; i < blocks.size(); ++i) workers.emplace_back([&, i]() {
        blocks[i] = ir_shared_jit_allocate(8, &writes[i]);
        assert(blocks[i] && writes[i] && *(uint32_t *)writes[i] == 0);
        *(uint32_t *)writes[i] = i + 1;
    });
    for (auto &worker : workers) worker.join();
    unique = std::set<void *>(blocks.begin(), blocks.end());
    assert(unique.size() == blocks.size() && preparations == pooled_preparations + 1);
    for (unsigned i = 0; i < blocks.size(); ++i) {
        assert(*(uint32_t *)blocks[i] == i + 1);
        ir_shared_jit_release(blocks[i]);
    }
    code = ir_shared_jit_allocate(2 * getpagesize(), &write);
    assert(code && write && preparations == pooled_preparations + 2);
    ir_shared_jit_release(code);
    assert(ir_phase3_core_prepare_jit(fail));
    assert(!ir_shared_jit_allocate(8, &write) && !write);
}
'''
        for engine in ('flycast', 'play'):
            with self.subTest(engine=engine), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                recipe = ROOT / ('ci/phase3_' + engine + '.py')
                spec = importlib.util.spec_from_file_location('jit_recipe_' + engine, recipe)
                module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
                source = ROOT / ('vendor/Flycast' if engine == 'flycast' else 'vendor/Play/deps/CodeGen')
                if not source.joinpath('core/types.h' if engine == 'flycast' else 'src/MemoryFunction.cpp').is_file():
                    self.skipTest('Pinned engine source required: ' + engine)
                module.generated(ROOT, folder)
                main = folder / 'main.cpp'; main.write_text(fixture)
                command = ['clang++', '-std=c++17', '-I', str(BRIDGE), str(main),
                           str(BRIDGE / 'IRSharedJITMemory.cpp'), str(BRIDGE / 'IRJITExecutionProbe.c'),
                           str(BRIDGE / ('IRFlycastProbe.cpp' if engine == 'flycast' else 'IRPlayProbe.cpp'))]
                if engine == 'flycast':
                    command += ['-I', str(source / 'core'), '-I', str(source / 'core/deps/nowide/include')]
                else:
                    (folder / 'AppConfig.h').write_text('''#pragma once
#include <filesystem>
namespace fs = std::filesystem;
#include <string>
extern "C" const char *ir_play_save_root();
struct CAppConfig {
    inline static unsigned constructed = 0;
    std::string root;
    CAppConfig() : root(ir_play_save_root()) { ++constructed; }
    static CAppConfig& GetInstance();
    static void ResetInstance();
};
''')
                    command += ['-I', str(folder)]
                    command += ['-DTEST_PLAY_MEMORY', '-DMEMFUNC_USE_MACHVM', '-DMEMFUNC_MACHVM_STRICT_PROTECTION',
                                '-I', str(source / 'include'), '-I', str(ROOT / 'vendor/Play/deps/Framework/include'),
                                str(folder / 'MemoryFunction.cpp')]
                executable = folder / 'check'; command += ['-o', str(executable)]
                subprocess.run(command, check=True, timeout=60)
                subprocess.run([str(executable)], check=True, timeout=15)
