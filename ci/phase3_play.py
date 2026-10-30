"""Play-only source overlays for the shared builder."""


def generated(ROOT, directory):
    source = ROOT / 'vendor/Play'
    pad_header = (source / 'Source/ui_libretro/PH_Libretro_Input.h').read_text()
    pad = (source / 'Source/ui_libretro/PH_Libretro_Input.cpp').read_text()
    replacements = [
        ('int16 m_btns_state = 0;', 'int16 m_btns_state[2] = {};'),
        ('uint8 m_axis_btn_state[4] = {0x7F};', 'uint8 m_axis_btn_state[2][4] = {{0x7F,0x7F,0x7F,0x7F},{0x7F,0x7F,0x7F,0x7F}};'),
    ]
    for old, new in replacements:
        if pad_header.count(old) != 1: raise ValueError('Play controller state layout changed')
        pad_header = pad_header.replace(old, new)
    pad = pad.replace('g_input_state_cb(0,', 'g_input_state_cb(port,')
    pad = pad.replace('m_btns_state', 'm_btns_state[port]').replace('m_axis_btn_state[', 'm_axis_btn_state[port][')
    begin = pad.index('\n\tif(libretro_supports_bitmasks)')
    end = pad.index('\n}\n\nvoid CPH_Libretro_Input::Update(', begin)
    pad = pad[:begin] + '\n\tfor(unsigned port=0;port<2;++port)\n\t{' + pad[begin:end] + '\n\t}' + pad[end:]
    old = '\t\tfor(unsigned int i = 0; i < PS2::CControllerInfo::MAX_BUTTONS; i++)'
    if pad.count(old) != 1: raise ValueError('Play controller dispatch loop changed')
    pad = pad.replace(old, '\t\tfor(unsigned port=0;port<2;++port)\n' + old)
    pad = pad.replace('SetAxisState(0,', 'SetAxisState(port,').replace('SetButtonState(0,', 'SetButtonState(port,')
    old = 'uint8 val = static_cast<int8>((value / 0xFF) + 0.5) + 0x7F;'
    if pad.count(old) != 1: raise ValueError('Play analog conversion changed')
    pad = pad.replace(old, 'uint8 val = static_cast<uint8>((static_cast<int32>(value) + 32768) * 255 / 65535);')
    (directory / 'PH_Libretro_Input.h').write_text(pad_header)
    (directory / 'PH_Libretro_Input.cpp').write_text(pad)
    main = (source / 'Source/ui_libretro/main_libretro.cpp').read_text()
    start = main.index('size_t retro_serialize_size(void)')
    end = main.index('void* retro_get_memory_data(', start)
    main = main[:start] + '''#include "IRPlayState.h"
size_t retro_serialize_size(void) { return irPlayStateSize; }
bool retro_serialize(void* data, size_t size) { return irPlaySaveState(m_virtualMachine, data, size); }
bool retro_unserialize(const void* data, size_t size) { return irPlayLoadState(m_virtualMachine, data, size); }

''' + main[end:]
    hook = 'static CPS2VM* m_virtualMachine = nullptr;'
    if main.count(hook) != 1: raise ValueError('Play VM ownership hook changed')
    main = main.replace(hook, '''class IRPlayVM final : public CPS2VM {
public:
    template<typename F> void OnVM(F&& work) { m_mailBox.SendCall(std::forward<F>(work), true); }
};
''' + hook)
    hook = 'm_virtualMachine = new CPS2VM();'
    if main.count(hook) != 1: raise ValueError('Play VM allocation hook changed')
    main = main.replace(hook, 'm_virtualMachine = new IRPlayVM();')
    header = (source / 'Source/app_shared/AppConfig.h').read_text()
    hook = '\tCAppConfig();'
    if header.count(hook) != 1: raise ValueError('Play app configuration interface changed')
    header = header.replace(hook, hook + '\n\tstatic CAppConfig& GetInstance();\n\tstatic void ResetInstance();')
    (directory / 'include').mkdir(exist_ok=True)
    (directory / 'include/AppConfig.h').write_text(header)
    for name in ('AppConfig.cpp', 'Log.cpp'):
        (directory / name).write_text((source / 'Source/app_shared' / name).read_text())
    hook = '\tstatic bool updates = true;'
    if main.count(hook) != 1: raise ValueError('Play variable update lifecycle changed')
    main = main.replace(hook, '')
    main = 'static bool updates = true;\n' + main
    hook = 'void retro_init()\n{'
    if main.count(hook) != 1: raise ValueError('Play initialization hook changed')
    main = main.replace(hook, hook + '\n\tupdates = true;')
    start = main.index('\t\tm_virtualMachine->PauseAsync();', main.index('void retro_deinit()'))
    end = main.index('\t\tm_virtualMachine->DestroyPadHandler();', start)
    main = main[:start] + '''\t\tif(!ir_phase3_core_pause(true))
\t\t\tthrow std::runtime_error("Play VM did not pause for shutdown");
\t\tauto gsHandler = static_cast<CGSH_OpenGL_Libretro*>(m_virtualMachine->GetGSHandler());
\t\tif(gsHandler) gsHandler->Release();
''' + main[end:]
    hook = '#include "DefaultAppConfig.h"'
    if main.count(hook) != 1:
        raise ValueError('Play configuration hook changed')
    replacement = '''extern "C" const char *ir_play_save_root();
fs::path CAppConfig::GetBasePath() const { return fs::path(ir_play_save_root()); }'''
    # Pause the independently running VM while pumping its owner-thread GS
    # mailbox. Release() is teardown and must not be used for a pause.
    pause = '''
extern "C" bool ir_phase3_core_pause(bool paused) {
    if (!m_virtualMachine) return true;
    if (!paused) {
        if (!first_run) return true;
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
    if (gs) gs->FlushMailBox();
    return true;
}
'''
    disc = '''
#include "DiskUtils.h"
#include "IRDiscControl.h"
extern "C" IRDiscResult ir_phase3_core_change_disc_result(const char* path) {
    if (!path || !m_virtualMachine || m_virtualMachine->GetStatus() != CVirtualMachine::PAUSED) return IRDiscResult::Failed;
    bool restored = true, inserted = false;
    try {
        auto media = DiskUtils::CreateOpticalMediaFromPath(fs::path(path));
        if (!media) return IRDiscResult::Failed;
        auto previous = CAppConfig::GetInstance().GetPreferencePath(PREF_PS2_CDROM0_PATH);
        static_cast<IRPlayVM*>(m_virtualMachine)->OnVM([&] {
            try {
                restored = false;
                CAppConfig::GetInstance().SetPreferencePath(PREF_PS2_CDROM0_PATH, fs::path(path));
                m_virtualMachine->CDROM0_SyncPath();
                inserted = m_virtualMachine->m_cdrom0 != nullptr;
            } catch (...) {}
            if (!inserted) {
                try {
                    CAppConfig::GetInstance().SetPreferencePath(PREF_PS2_CDROM0_PATH, previous);
                    m_virtualMachine->CDROM0_SyncPath();
                    restored = m_virtualMachine->m_cdrom0 != nullptr;
                } catch (...) {}
            }
        });
        return inserted ? IRDiscResult::Changed : restored ? IRDiscResult::Failed : IRDiscResult::RestoreFailed;
    } catch (...) { return restored ? IRDiscResult::Failed : IRDiscResult::RestoreFailed; }
}
'''
    (directory / 'main_libretro.cpp').write_text('#include <chrono>\n#include <stdexcept>\nextern "C" bool ir_phase3_core_pause(bool);\n' + main.replace(hook, replacement) + pause + disc)
    graphics = (source / 'Source/ui_libretro/GSH_OpenGL_Libretro.cpp').read_text()
    geometry = '''\tretro_game_geometry geometry{};
\tgeometry.base_width = GetCrtWidth() * g_res_factor;
\tgeometry.base_height = GetCrtHeight() * g_res_factor;
\tgeometry.max_width = geometry.max_height = 4096;
\tgeometry.aspect_ratio = 4.0f / 3.0f;
\tif(!g_environ_cb(RETRO_ENVIRONMENT_SET_GEOMETRY, &geometry))
\t\tthrow std::runtime_error("Play render target resize failed");
'''
    for hook in ('\tCGSH_OpenGL::InitializeImpl();', '\tCGSH_OpenGL::FlipImpl(dispInfo);'):
        if graphics.count(hook) != 1: raise ValueError('Play presentation hook changed')
        graphics = graphics.replace(hook, geometry + hook)
    (directory / 'GSH_OpenGL_Libretro.cpp').write_text('#include <stdexcept>\n#include "ext/libretro.h"\nextern retro_environment_t g_environ_cb;\n' + graphics)
    gs = (source / 'Source/gs/GSHandler.cpp').read_text()
    hook = '\tSendGSCall([&]() { SyncMemoryCache(); }, true);'
    if gs.count(hook) != 1: raise ValueError('Play snapshot graphics sync changed')
    gs = gs.replace(hook, '\tSendGSCall([&]() { SyncMemoryCache(); }, true, true);')
    (directory / 'GSHandler.cpp').write_text(gs.replace('#include "../', '#include "'))
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
