"""Flycast-only source overlays for the shared builder."""
import re


def generated(ROOT, directory):
    main = (ROOT / 'vendor/Flycast/shell/libretro/libretro.cpp').read_text()
    if main.count('static bool first_run = true;') != 1:
        raise ValueError('Flycast session hook changed')
    begin = main.index('size_t retro_serialize_size()')
    end = main.index('// Cheats', begin)
    states = main[begin:end]
    if states.count('std::lock_guard<std::mutex> lock(mtx_serialization);') != 3 or states.count('emu.start();') != 3:
        raise ValueError('Flycast state lifecycle changed')
    states = states.replace('std::lock_guard<std::mutex> lock(mtx_serialization);',
        'std::lock_guard<std::mutex> lock(mtx_serialization);\n\tconst bool irWasRunning = emu.running();')
    states = states.replace('emu.start();', 'if (irWasRunning) emu.start();')
    main = main[:begin] + states + main[end:]
    (directory / 'libretro.cpp').write_text(main + '''
extern "C" bool ir_phase3_core_pause(bool paused) {
    if (first_run) return true;
    if (paused) emu.stop();
    else emu.start();
    return emu.running() != paused;
}
''')
    glsm = (ROOT / 'vendor/Flycast/core/deps/libretro-common/glsm/glsm.c').read_text()
    hook = '#ifdef HAVE_OPENGLES\n   hw_render.context_type       = RETRO_HW_CONTEXT_OPENGLES2;'
    if glsm.count(hook) != 1: raise ValueError('Flycast GLES context hook changed')
    # This target compiles the ES3 renderer/symbol loader. Its pinned GLSM
    # otherwise advertises ES2 regardless of HAVE_OPENGLES3.
    replacement = '#ifdef HAVE_OPENGLES3\n   hw_render.context_type       = RETRO_HW_CONTEXT_OPENGLES3;\n#elif defined(HAVE_OPENGLES)\n   hw_render.context_type       = RETRO_HW_CONTEXT_OPENGLES2;'
    (directory / 'glsm.c').write_text(glsm.replace(hook, replacement))
    memory = (ROOT / 'vendor/Flycast/core/linux/posix_vmem.cpp').read_text()
    start = memory.index('// Prepares the code region for JIT operations')
    end = memory.index('\n} // namespace virtmem', start)
    (directory / 'posix_vmem.cpp').write_text(memory[:start] + memory[end:])
    # Upstream's dual-address code generators already translate RW to RX.
    # Keep their write aliases writable instead of toggling them executable.
    for path, function in [('core/rec-ARM64/rec_arm64.cpp', 'jitWriteProtect'),
                           ('core/hw/arm7/arm7_rec_arm64.cpp', 'JITWriteProtect'),
                           ('core/hw/aica/dsp_arm64.cpp', 'JITWriteProtect')]:
        text = (ROOT / 'vendor/Flycast' / path).read_text()
        pattern = r'(static void ' + function + r'\([^\n]*\)\n)\{.*?\n\}'
        text, count = re.subn(pattern, r'\1{\n}', text, count=1, flags=re.S)
        if count != 1: raise ValueError('Flycast code write hook changed: ' + path)
        if path.endswith('dsp_arm64.cpp'):
            if text.count('DynCode = pCodeBuffer;') != 1: raise ValueError('Flycast DSP entry changed')
            text = text.replace('DynCode = pCodeBuffer;', 'DynCode = pCodeBuffer + rx_offset;')
        (directory / path.split('/')[-1]).write_text(text)


def arguments():
    return ['-DLIBRETRO=ON', '-DUSE_VULKAN=OFF', '-DUSE_HOST_LIBZIP=OFF', '-DUSE_OPENMP=OFF',
            '-DENABLE_CTEST=OFF', '-DUSE_BREAKPAD=OFF', '-DUSE_UPNP=ON', '-DCMAKE_C_FLAGS=-DIOS', '-DCMAKE_CXX_FLAGS=-DIOS']


TARGET, OUTPUT = 'flycast_libretro', 'flycast_libretro.dylib'
