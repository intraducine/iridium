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
    allocation = 'vm_allocate(mach_task_self(), reinterpret_cast<vm_address_t*>(&m_code), allocSize, TRUE);'
    if memory.count(allocation) != 1:
        raise ValueError('Play allocation hook changed')
    memory = '#include <stdexcept>\n' + memory.replace(allocation,
        'if (' + allocation[:-1] + ' != KERN_SUCCESS) throw std::runtime_error("Executable allocation failed");')
    # Upstream assertions disappear in Release. Fail before executing or
    # rewriting a page when any of the three W^X transitions was rejected.
    if memory.count('assert(result == 0);') != 3:
        raise ValueError('Play protection hooks changed')
    memory = memory.replace('assert(result == 0);', 'if (result != KERN_SUCCESS) throw std::runtime_error("Executable protection failed");')
    (directory / 'MemoryFunction.cpp').write_text(memory)


def arguments():
    return ['-DTARGET_IOS=ON', '-DBUILD_PLAY=OFF', '-DBUILD_TESTS=OFF', '-DBUILD_LIBRETRO_CORE=ON']


TARGET, OUTPUT = 'play_libretro', 'Source/ui_libretro/play_libretro_ios.dylib'
