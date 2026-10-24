"""Flycast-only source overlays for the shared builder."""


def generated(ROOT, directory):
    main = (ROOT / 'vendor/Flycast/shell/libretro/libretro.cpp').read_text()
    if main.count('static bool first_run = true;') != 1:
        raise ValueError('Flycast session hook changed')
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


def arguments():
    return ['-DLIBRETRO=ON', '-DUSE_VULKAN=OFF', '-DUSE_HOST_LIBZIP=OFF', '-DUSE_OPENMP=OFF',
            '-DENABLE_CTEST=OFF', '-DUSE_BREAKPAD=OFF', '-DUSE_UPNP=OFF', '-DCMAKE_C_FLAGS=-DIOS', '-DCMAKE_CXX_FLAGS=-DIOS']


TARGET, OUTPUT = 'flycast_libretro', 'flycast_libretro.dylib'
