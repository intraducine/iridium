"""Play-only source overlays for the shared builder."""


def generated(ROOT, directory):
    source = ROOT / 'vendor/Play'
    main = (source / 'Source/ui_libretro/main_libretro.cpp').read_text()
    hook = '#include "DefaultAppConfig.h"'
    if main.count(hook) != 1:
        raise ValueError('Play configuration hook changed')
    replacement = '''extern "C" const char *ir_play_save_root();
fs::path CAppConfig::GetBasePath() const { return fs::path(ir_play_save_root()); }'''
    # Pause the independently running VM while pumping its owner-thread GS
    # mailbox. Release() is teardown and must not be used for a pause.
    pause = '''
extern "C" bool ir_phase3_core_pause(bool paused) {
    if (!m_virtualMachine || !first_run) return true;
    if (!paused) {
        m_virtualMachine->Resume();
        return m_virtualMachine->GetStatus() == CVirtualMachine::RUNNING;
    }
    m_virtualMachine->PauseAsync();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    auto gs = static_cast<CGSH_OpenGL_Libretro*>(m_virtualMachine->GetGSHandler());
    while (m_virtualMachine->GetStatus() != CVirtualMachine::PAUSED) {
        if (std::chrono::steady_clock::now() >= deadline) return false;
        if (gs) gs->FlushMailBox();
        std::this_thread::yield();
    }
    return true;
}
'''
    (directory / 'main_libretro.cpp').write_text('#include <chrono>\n' + main.replace(hook, replacement) + pause)
    memory = (source / 'deps/CodeGen/src/MemoryFunction.cpp').read_text()
    start = memory.index('\tvm_size_t page_size = 0;')
    end = memory.index('#elif defined(MEMFUNC_USE_MMAP)', start)
    memory = memory[:start] + '''\tvoid *write = nullptr;
\tm_code = ir_shared_jit_allocate(size, &write);
\tif(!m_code) throw std::runtime_error("Shared JIT allocation failed");
\tm_size = size;
\tmemcpy(write, code, size);
''' + memory[end:]
    release = 'vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), m_size);'
    if memory.count(release) != 1: raise ValueError('Play release hook changed')
    memory = memory.replace(release, 'ir_shared_jit_release(m_code);')
    for protection in ('VM_PROT_READ | VM_PROT_WRITE', 'VM_PROT_READ | VM_PROT_EXECUTE'):
        hook = '\tkern_return_t result = vm_protect(mach_task_self(), reinterpret_cast<vm_address_t>(m_code), m_size, 0, ' + protection + ');\n\tassert(result == 0);'
        if memory.count(hook) != 1: raise ValueError('Play modification hook changed')
        memory = memory.replace(hook, '\t// Shared JIT keeps separate writable and executable addresses.')
    memory = '#include <stdexcept>\n#include <unistd.h>\n#include "IRSharedJITMemory.h"\n' + memory
    (directory / 'MemoryFunction.cpp').write_text(memory)
    block = (source / 'Source/BasicBlock.cpp').read_text()
    hook = 'auto code = reinterpret_cast<uint8*>(m_function.GetCode());'
    if block.count(hook) != 2: raise ValueError('Play block modification hooks changed')
    block = block.replace(hook, '''auto code = reinterpret_cast<uint8*>(ir_shared_jit_write(m_function.GetCode()));
\tif(!code) throw std::runtime_error("Shared JIT write address missing");''')
    (directory / 'BasicBlock.cpp').write_text('#include <stdexcept>\n#include "IRSharedJITMemory.h"\n' + block)


def arguments():
    return ['-DTARGET_IOS=ON', '-DBUILD_PLAY=OFF', '-DBUILD_TESTS=OFF', '-DBUILD_LIBRETRO_CORE=ON']


TARGET, OUTPUT = 'play_libretro', 'Source/ui_libretro/play_libretro_ios.dylib'
