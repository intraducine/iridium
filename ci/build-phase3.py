#!/usr/bin/env python3
"""Build pinned Phase 3 upstream iOS components and retain complete receipts."""
import argparse
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'
PINS = {
    'dolphin': ('Dolphin', '7cac54161659421ed95c2cd1c0b0746539a4cd38', 'v5.0.0b6'),
    'azahar': ('Azahar', '219d743a1e698101fe1ab8bef43e6563126c3c27', '2126.2'),
    'play': ('Play', 'fa75cea31a33f5ab7a2008ed0d90dc74353e9cef', '0.77'),
    'flycast': ('Flycast', '5aa091fde632fb332c8d8c34e280d62dc951954c', 'v2.7'),
}
NATIVE_EXPORTS = {'_ir_native_engine_' + name for name in ('abi', 'create', 'pause', 'stop', 'frames')}
DOLPHIN_EXPORTS = NATIVE_EXPORTS | {'_ir_dolphin_api'}
AZAHAR_DOWNLOADS = {
    'azahar-libretro-ios-arm64-2126.2.zip': '18e78a721884438b11a3588f96d19e09895f0dbb5c716448343ab185972bc451',
    'azahar-unified-source-2126.2.tar.xz': '85c8b56fac703df04720125044b8ff887997911858a6cde545dfb1107ba4cd26',
}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(*command):
    print(' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, cwd=ROOT)


def output(*command):
    return subprocess.check_output(list(map(str, command)), text=True, cwd=ROOT).strip()


def source_state(source):
    """Verify initialized dependency pins; tolerate only zlib's exact CMake rename."""
    revisions = {}
    def visit(repo):
        revision = output('git', '-C', repo, 'rev-parse', 'HEAD')
        changed = output('git', '-C', repo, 'diff', '--name-status', '--ignore-submodules=all', 'HEAD')
        if changed:
            renamed = 'deps/zlib-1.3.1/zconf.h'
            included = repo / (renamed + '.included')
            original = subprocess.check_output(['git', '-C', str(repo), 'show', 'HEAD:' + renamed]) if changed == 'D\t' + renamed else None
            if original is None or not included.is_file() or included.is_symlink() or included.read_bytes() != original:
                raise ValueError('Modified upstream source: ' + repo.relative_to(ROOT).as_posix())
        untracked = output('git', '-C', repo, 'ls-files', '--others', '--exclude-standard', '-z').split('\0')
        if any(name and (name != 'deps/zlib-1.3.1/zconf.h.included' or not changed) for name in untracked):
            raise ValueError('Untracked upstream source: ' + repo.relative_to(ROOT).as_posix())
        revisions[repo.relative_to(ROOT).as_posix()] = revision
        records = output('git', '-C', repo, 'ls-files', '--stage', '-z').split('\0')
        for record in records:
            if not record.startswith('160000 '): continue
            meta, name = record.split('\t', 1)
            child = repo / name
            if not (child / '.git').exists(): continue
            if output('git', '-C', child, 'rev-parse', 'HEAD') != meta.split()[1]:
                raise ValueError('Dependency differs from its pin: ' + child.relative_to(ROOT).as_posix())
            visit(child)
    visit(source)
    return revisions


def input_paths(engine):
    names = ['ci/build-phase3.py', 'ci/phase3-cmake-hook.cmake', 'ci/phase3-targets.cmake',
             'iridium/apps/ios/RuntimeBridge/IRPhase3.h']
    bridge = {'host': ['IRRetroPlayer.mm'], 'dolphin': ['IRDolphin.mm', 'IRDolphinAPI.h', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h'], 'azahar': ['IRAzaharJIT.cpp', 'IRAzaharGraphics.mm', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h'],
              'play': ['IRPlayProbe.cpp', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h'],
              'flycast': ['IRFlycastProbe.cpp', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h']}
    names += ['iridium/apps/ios/RuntimeBridge/' + name for name in bridge[engine]]
    if engine == 'host': names += ['vendor/Flycast/core/deps/libretro-common/include/libretro.h']
    if engine == 'azahar': names += ['ci/azahar-moltenvk-source-inputs.json', 'ci/build-ppsspp-moltenvk.py']
    return names


def fixed_inputs(engine):
    return {name: digest(ROOT / name) for name in input_paths(engine)}


def verify_inputs(record):
    if record.get('buildInputs') != fixed_inputs(record['engine']):
        raise ValueError('Phase 3 build recipe or ABI changed: ' + record['engine'])
    if record['engine'] != 'host':
        source = ROOT / 'vendor' / PINS[record['engine']][0]
        if record.get('sourceRevisions') != source_state(source):
            raise ValueError('Phase 3 dependency revisions changed: ' + record['engine'])
    for name, expected in record.get('compiledInputs', {}).items():
        if digest(ROOT / name) != expected:
            raise ValueError('Phase 3 compiled input changed: ' + name)
    for name, expected in record.get('embedding', {}).items():
        directory = ROOT / '.build/phase3' / record['engine'] / record['sdk'] / 'embedding'
        if digest(directory / name) != expected:
            raise ValueError('Phase 3 generated adapter changed: ' + name)
    if record['engine'] == 'azahar':
        library, moltenvk = azahar_moltenvk(record['sdk'])
        if record.get('moltenVK') != moltenvk or digest(library) != moltenvk['archiveSHA256']:
            raise ValueError('Azahar linked MoltenVK source closure changed')


def azahar_moltenvk(sdk, jobs=None):
    manifest = ROOT / 'ci/azahar-moltenvk-source-inputs.json'
    spec = importlib.util.spec_from_file_location('azahar_moltenvk', ROOT / 'ci/build-ppsspp-moltenvk.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    directory = ROOT / '.build/azahar/moltenvk-derived' / ('package-' + sdk)
    library = directory / 'Build/Products' / ('Release-' + sdk) / 'libMoltenVK.a'
    receipt = directory / 'component.json'
    if jobs is not None and not receipt.is_file():
        return module.build(sdk, jobs, inputs=manifest, version='1.4.1', build_root=ROOT / '.build/azahar')
    record = json.loads(receipt.read_text())
    if record.get('version') != '1.4.1' or record.get('sourceInputs') != json.loads(manifest.read_text()) or record.get('sourceArchiveSHA256') != digest(manifest) or record.get('archiveSHA256') != digest(library):
        raise ValueError('Azahar MoltenVK receipt differs from its pinned inputs')
    for item in record['sourceInputs']:
        archive = ROOT / '.build/runtime-downloads' / (item['sha256'] + '.tar')
        if digest(archive) != item['sha256'] or module.verify_tree(archive, ROOT / '.build/azahar/moltenvk-source' / item['name']) != record['sourceTreeSHA256'][item['name']]:
            raise ValueError('Azahar MoltenVK source changed: ' + item['name'])
    return library, record


def public_arguments(arguments):
    return [str(value).replace(str(ROOT), '${IRIDIUM_ROOT}') for value in arguments]


def generated(engine, destination):
    directory = destination / 'embedding'
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'native.exports').write_text('\n'.join(sorted(DOLPHIN_EXPORTS if engine == 'dolphin' else NATIVE_EXPORTS)) + '\n')
    (directory / 'retro.exports').write_text('_retro_*\n' + ('_ir_phase3_core_check_jit\n' if engine in ('azahar', 'play', 'flycast') else '') + ('_ir_phase3_core_pause\n' if engine in ('play', 'flycast') else '') + ('_ir_phase3_core_prepare\n' if engine == 'play' else '') + ('_ir_phase3_core_prepare_jit\n_ir_phase3_core_jit_status\n_ir_phase3_core_set_metal_surface\n' if engine == 'azahar' else ''))
    (directory / 'toolchain.cmake').write_text('set(CMAKE_SYSTEM_NAME iOS)\nset(CMAKE_SYSTEM_PROCESSOR aarch64)\nset(IOS ON)\n')
    if engine == 'azahar':
        source = ROOT / '.build/phase3-downloads/azahar-unified-source-2126.2'
        def replace(text, old, new, count=1):
            if text.count(old) != count:
                raise ValueError('Azahar shared JIT source hook changed: ' + old)
            return text.replace(old, new)
        oaknut = source / 'externals/dynarmic/externals/oaknut/include/oaknut/code_block.hpp'
        code = oaknut.read_text()
        code = replace(code, 'namespace oaknut {', 'extern "C" void* ir_azahar_jit_allocate(std::size_t, void**);\n\nnamespace oaknut {')
        code = replace(code, '#    if TARGET_OS_IPHONE\n        m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);',
            '#    if TARGET_OS_IPHONE\n        void* writable = nullptr;\n        m_memory = static_cast<std::uint32_t*>(ir_azahar_jit_allocate(size, &writable));\n        m_wmemory = static_cast<std::uint32_t*>(writable);')
        code = replace(code, '        munmap(m_memory, m_size);', '#if defined(__APPLE__) && TARGET_OS_IPHONE\n        munmap(m_wmemory, m_size);\n#endif\n        munmap(m_memory, m_size);')
        code = replace(code, '    void protect()', '    std::uint32_t* wptr() const\n    {\n#if defined(__APPLE__) && TARGET_OS_IPHONE\n        return m_wmemory;\n#else\n        return m_memory;\n#endif\n    }\n\n    void protect()')
        # iOS keeps separate RW and RX aliases, so generated code stays executable.
        code = replace(code, '#elif defined(__APPLE__) || defined(__NetBSD__) || defined(__OpenBSD__)', '#elif (defined(__APPLE__) && !TARGET_OS_IPHONE) || defined(__NetBSD__) || defined(__OpenBSD__)', 2)
        code = replace(code, '        sys_icache_invalidate(mem, size);', '#if TARGET_OS_IPHONE\n        sys_dcache_flush(m_wmemory + (mem - m_memory), size);\n#endif\n        sys_icache_invalidate(mem, size);')
        code = replace(code, '    std::uint32_t* m_memory;', '    std::uint32_t* m_memory;\n    std::uint32_t* m_wmemory = nullptr;')
        header = directory / 'include/oaknut/code_block.hpp'
        header.parent.mkdir(parents=True, exist_ok=True); header.write_text(code)
        arm = source / 'externals/dynarmic/src/dynarmic/backend/arm64/address_space.cpp'
        code = replace(arm.read_text(), 'code(mem.ptr(), mem.ptr())', 'code(mem.wptr(), mem.ptr())')
        code = replace(code, 'CodeGenerator c{mem.ptr(), mem.ptr()};', 'CodeGenerator c{mem.wptr(), mem.ptr()};', 2)
        (directory / 'address_space.cpp').write_text(code)
        spin = source / 'externals/dynarmic/src/dynarmic/common/spin_lock_arm64.cpp'
        code = replace(spin.read_text(), 'SpinLockImpl impl;', 'SpinLockImpl& GetImpl() {\n    static SpinLockImpl impl;\n    return impl;\n}')
        code = replace(code, 'code{mem.ptr(), mem.ptr()}', 'code{mem.wptr(), mem.ptr()}')
        code = replace(code, '    std::call_once(flag, &SpinLockImpl::Initialize, impl);', '    auto& impl = GetImpl();\n    std::call_once(flag, &SpinLockImpl::Initialize, impl);', 2)
        (directory / spin.name).write_text(code)
        shader = source / 'src/video_core/shader/shader_jit_a64_compiler.cpp'
        code = replace(shader.read_text(), 'std::memcpy(code_mem->ptr(), code_vec.data(), code_vec.size() * sizeof(u32));', 'std::memcpy(code_mem->wptr(), code_vec.data(), code_vec.size() * sizeof(u32));')
        (directory / shader.name).write_text(code)
        for relative, namespace, call, kind in (
            ('src/core/arm/dynarmic/arm_dynarmic.cpp', 'namespace Core {', '    jit->Run();', 0),
            ('src/video_core/shader/shader_jit.cpp', 'namespace Pica::Shader {', '    shader->Run(setup, state, setup.entry_point);', 1)):
            original = source / relative
            code = replace(original.read_text(), namespace, 'extern "C" void ir_azahar_jit_executed(unsigned);\n\n' + namespace)
            code = replace(code, call, call + '\n    ir_azahar_jit_executed(' + str(kind) + ');')
            (directory / original.name).write_text(code)
        original = source / 'src/citra_libretro/citra_libretro.cpp'
        code = replace(original.read_text(), '#include "citra_libretro/libretro_vk.h"', '')
        code = replace(code, '        LibRetro::VulkanResetContext();', '        // The native renderer owns its Metal surface and Vulkan device.')
        start = code.index('    case Settings::GraphicsAPI::Vulkan: {', code.index('bool retro_load_game'))
        end = code.index('    case Settings::GraphicsAPI::Software: {', start)
        code = code[:start] + '    case Settings::GraphicsAPI::Vulkan:\n' + code[end:]
        (directory / original.name).write_text(code)
        original = source / 'src/citra_libretro/emu_window/libretro_window.cpp'
        code = replace(original.read_text(), 'EmuWindow_LibRetro::EmuWindow_LibRetro() {', 'extern "C" void* ir_azahar_metal_layer();\n\nEmuWindow_LibRetro::EmuWindow_LibRetro() {')
        code = replace(code, '    window_info.type = Frontend::WindowSystemType::LibRetro;', '    window_info.type = Frontend::WindowSystemType::MacOS;\n    window_info.render_surface = ir_azahar_metal_layer();')
        code = replace(code, '    if (Settings::values.graphics_api.GetValue() == Settings::GraphicsAPI::Software) {', '    if (Settings::values.graphics_api.GetValue() == Settings::GraphicsAPI::Software ||\n        Settings::values.graphics_api.GetValue() == Settings::GraphicsAPI::Vulkan) {')
        (directory / original.name).write_text(code)
        original = source / 'src/citra_libretro/input/mouse_tracker.cpp'
        code = replace(original.read_text(), '#include "video_core/renderer_vulkan/renderer_vulkan.h"', '')
        (directory / original.name).write_text(code)
        original = source / 'src/video_core/renderer_vulkan/vk_platform.cpp'
        code = replace(original.read_text(), 'namespace Vulkan {', 'extern "C" VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance, const char*);\n\nnamespace Vulkan {')
        start = code.index('    [[maybe_unused]] Frontend::GraphicsContext* context) {')
        end = code.index('\nvk::SurfaceKHR CreateSurface', start)
        code = code[:start] + '    [[maybe_unused]] Frontend::GraphicsContext* context) {\n    return std::make_shared<Common::DynamicLibrary>(nullptr);\n}\n' + code[end:]
        start = code.index('    if (!library.IsLoaded()) {')
        end = code.index('    VULKAN_HPP_DEFAULT_DISPATCHER.init(vkGetInstanceProcAddr);', start)
        code = code[:start] + '    const auto vkGetInstanceProcAddr = ::vkGetInstanceProcAddr;\n' + code[end:]
        (directory / original.name).write_text(code)
    if engine == 'dolphin':
        code_block = (ROOT / 'vendor/Dolphin/Source/Core/Common/CodeBlock.h').read_text()
        alias = '    writable_region_diff = Common::AllocateWritableRegionAndGetDiff(region, size);'
        release = ('    Common::FreeWritableRegion(region, total_region_size, writable_region_diff);\n'
                   '    Common::FreeExecutableMemory(region, total_region_size);')
        if code_block.count(alias) != 1 or code_block.count(release) != 1:
            raise ValueError('Dolphin iOS code-block allocation hooks changed')
        # CachedInterpreter owns ordinary RW pages, not an executable region.
        code_block = code_block.replace(alias, '    if constexpr (executable)\n  ' + alias)
        code_block = code_block.replace(release,
            '    if constexpr (executable)\n    {\n' +
            '\n'.join('  ' + line for line in release.splitlines()) +
            '\n    }\n    else\n      Common::FreeMemoryPages(region, total_region_size);')
        overlay = directory / 'include/Common/CodeBlock.h'
        overlay.parent.mkdir(parents=True, exist_ok=True)
        overlay.write_text(code_block)
        memory = (ROOT / 'vendor/Dolphin/Source/Core/Common/MemoryUtil_iOS_LuckTXM.cpp').read_text()
        mapping = 'static_cast<u8*>(mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0))'
        if memory.count('if (!rx_ptr)') != 1 or memory.count(mapping) != 1:
            raise ValueError('Dolphin TXM mapping failure hook changed')
        request_start = memory.index('  asm (')
        request_end = memory.index('\n\n  vm_address_t rw_region', request_start)
        # Use the shared debugger allocation path, as Madeira does. Preparing
        # an app-created RX mapping was rejected by TXM on the physical phone.
        memory = memory[:request_start] + memory[request_end:]
        memory = memory.replace(mapping, 'static_cast<u8*>(ir_dolphin_jit_prepare(nullptr, size))')
        memory = memory.replace('namespace Common',
            'extern "C" void* ir_dolphin_jit_prepare(void*, size_t);\n\nnamespace Common', 1)
        (directory / 'MemoryUtil_iOS_LuckTXM.cpp').write_text(memory.replace('if (!rx_ptr)', 'if (!rx_ptr || rx_ptr == MAP_FAILED)'))
        state = (ROOT / 'vendor/Dolphin/Source/Core/Core/State.cpp').read_text()
        callback = 'if (s_on_after_load_callback)'
        if state.count(callback) != 1:
            raise ValueError('Dolphin state completion hook changed')
        # The upstream completion callback also fires for failed loads.
        (directory / 'State.cpp').write_text(state.replace(callback,
            'if (loadedSuccessfully && s_on_after_load_callback)'))
        audio_root = ROOT / 'vendor/Dolphin/Source/Core/AudioCommon'
        audio_header = (audio_root / 'CoreAudioSoundStream.h').read_text()
        audio = (audio_root / 'CoreAudioSoundStream.cpp').read_text()
        mix = '    sound->m_mixer->Mix(static_cast<short*>(buffer.mData), buffer.mDataByteSize / 4);'
        initial_volume = ('  err = AudioUnitSetParameter(audio_unit, kHALOutputParam_Volume, kAudioUnitScope_Output, 0,\n'
                          '                              m_volume / 100., 0);\n'
                          '  if (err != noErr)\n    ERROR_LOG_FMT(AUDIO, "error setting volume");\n')
        if (audio_header.count('  int m_volume;') != 1 or audio.count(mix) != 1 or
                audio.count(initial_volume) != 1 or audio.count('void CoreAudioSound::SetVolume(int volume)') != 1):
            raise ValueError('Dolphin iOS audio hooks changed')
        audio_header = audio_header.replace('#pragma once', '#pragma once\n#include <atomic>')
        audio_header = audio_header.replace('  bool Init() override;', '  ~CoreAudioSound() override;\n  bool Init() override;')
        audio_header = audio_header.replace('  AudioUnit audio_unit;', '  AudioUnit audio_unit = nullptr;')
        audio_header = audio_header.replace('  int m_volume;', '  std::atomic<int> m_volume{100};')
        audio_overlay = directory / 'include/AudioCommon/CoreAudioSoundStream.h'
        audio_overlay.parent.mkdir(parents=True, exist_ok=True)
        audio_overlay.write_text(audio_header)
        # RemoteIO has no HAL output-volume control. Apply gain to its PCM output.
        audio = audio.replace('#include <AudioUnit/AudioUnit.h>', '#include <AudioUnit/AudioUnit.h>\n#include <algorithm>\n#include <cstring>')
        audio = audio.replace(mix, mix + '''
    const int volume = sound->m_volume.load(std::memory_order_relaxed);
    auto* samples = static_cast<short*>(buffer.mData);
    if (volume == 0)
      std::memset(samples, 0, buffer.mDataByteSize);
    else if (volume != 100)
      for (UInt32 sample = 0; sample < buffer.mDataByteSize / sizeof(short); ++sample)
        samples[sample] = static_cast<short>(static_cast<int>(samples[sample]) * volume / 100);
''')
        audio = audio.replace(initial_volume, '')
        audio = audio[:audio.index('void CoreAudioSound::SetVolume(int volume)')] + '''void CoreAudioSound::SetVolume(int volume)
{
  m_volume.store(std::clamp(volume, 0, 100), std::memory_order_relaxed);
}

CoreAudioSound::~CoreAudioSound()
{
  if (audio_unit)
  {
    AudioOutputUnitStop(audio_unit);
    AudioUnitUninitialize(audio_unit);
    AudioComponentInstanceDispose(audio_unit);
  }
}
'''
        (directory / 'CoreAudioSoundStream.cpp').write_text(audio)
        # Supported mbedTLS user configuration: its public self-test keys are
        # unnecessary in a player. Preserve TLS/PEM support and all source.
        (directory / 'mbedtls-user-config.h').write_text(
            '#undef MBEDTLS_SELF_TEST\n#undef MBEDTLS_CERTS_C\n')
        metal = (ROOT / 'vendor/Dolphin/Source/Core/VideoBackends/Metal/MTLUtil.mm').read_text()
        capability = 'backend_info->bSupportsFramebufferFetch = [device supportsFamily:MTLGPUFamilyApple1];'
        if metal.count(capability) != 1:
            raise ValueError('Dolphin Metal framebuffer-fetch capability hook changed')
        # Simulator advertises an Apple GPU family but rejects render-target
        # reads. Select the upstream non-fetch shader path on that platform.
        (directory / 'MTLUtil.mm').write_text(metal.replace(capability,
            capability[:-1] + ' && !TARGET_OS_SIMULATOR;'))
    if engine == 'play':
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
    if engine == 'flycast':
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
    return directory


def audit(binary, sdk, native=False):
    symbols = set(output('xcrun', 'nm', '-gUj', binary).splitlines())
    if native:
        expected = DOLPHIN_EXPORTS if binary.name == 'libIridiumDolphin.dylib' else NATIVE_EXPORTS
        if symbols != expected:
            raise ValueError('Native player exports differ: ' + str(symbols ^ expected))
    elif not all(s.startswith('_retro_') or s in {'_ir_phase3_core_check_jit', '_ir_phase3_core_prepare', '_ir_phase3_core_pause', '_ir_phase3_core_prepare_jit', '_ir_phase3_core_jit_status', '_ir_phase3_core_set_metal_surface'} for s in symbols):
        raise ValueError('Upstream C++ symbols escape the core boundary')
    if not native and '_retro_run' not in symbols:
        raise ValueError('Missing upstream core interface')
    platform = 'IOSSIMULATOR' if sdk == 'iphonesimulator' else 'IOS'
    build = output('xcrun', 'vtool', '-show-build', binary)
    if re.findall(r'platform\s+(\w+)', build) != [platform]:
        raise ValueError('Wrong native platform')
    if output('xcrun', 'lipo', '-archs', binary) != 'arm64':
        raise ValueError('Wrong native architecture')
    libraries = [s.strip().split(' (', 1)[0] for s in output('xcrun', 'otool', '-L', binary).splitlines()[1:]]
    identity = '@rpath/' + binary.name
    if not libraries or libraries[0] != identity or any(not lib.startswith(('/usr/lib/', '/System/Library/Frameworks/')) for lib in libraries[1:]):
        raise ValueError('Unreviewed dynamic dependency or install name: ' + str(libraries))
    return dict(sha256=digest(binary), exports=sorted(symbols), platform=platform, dynamicLibraries=libraries)


def notices(source, destination, allowed=None):
    target = destination / 'licenses'
    if target.exists(): shutil.rmtree(target)
    target.mkdir(exist_ok=True)
    for path in (source.rglob('*') if allowed is None else (source / name for name in allowed)):
        if not path.is_file() or '.git' in path.parts:
            continue
        name = path.name.lower()
        if name.startswith(('license', 'copying', 'notice', 'copyright')) or name == 'authors':
            relative = path.relative_to(source)
            output_path = target / relative
            output_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, output_path)


def build(engine, sdk, jobs):
    inputs = fixed_inputs(engine)
    name, revision, release = PINS[engine]
    source = ROOT / 'vendor' / name
    if output('git', '-C', source, 'rev-parse', 'HEAD') != revision:
        raise ValueError('Unexpected upstream pin for ' + name)
    source_state(source)
    destination = ROOT / '.build/phase3' / engine / sdk
    destination.mkdir(parents=True, exist_ok=True)
    binary_name = {'dolphin': 'libIridiumDolphin.dylib', 'azahar': 'azahar_libretro.dylib',
                   'play': 'play_libretro_ios.dylib', 'flycast': 'flycast_libretro.dylib'}[engine]
    binary = destination / binary_name
    arguments = []
    if engine == 'azahar':
        downloads = ROOT / '.build/phase3-downloads'
        for filename, expected in AZAHAR_DOWNLOADS.items():
            if digest(downloads / filename) != expected:
                raise ValueError('Official release artifact digest differs: ' + filename)
        expanded = downloads / 'azahar-unified-source-2126.2'
        if not expanded.exists():
            with tarfile.open(downloads / 'azahar-unified-source-2126.2.tar.xz') as archive:
                archive.extractall(downloads, filter='data')
        if (expanded / 'GIT-COMMIT').read_text().strip() != revision:
            raise ValueError('Azahar unified source pin differs')
        archive_files = []
        with tarfile.open(downloads / 'azahar-unified-source-2126.2.tar.xz') as archive:
            for member in archive:
                relative = Path(member.name).relative_to(expanded.name)
                target = expanded / relative
                if member.isfile():
                    if target.is_symlink() or digest(target) != hashlib.file_digest(archive.extractfile(member), 'sha256').hexdigest():
                        raise ValueError('Azahar expanded source changed: ' + relative.as_posix())
                    archive_files.append(relative)
                elif member.issym() and (not target.is_symlink() or Path(target.readlink()) != Path(member.linkname)):
                    raise ValueError('Azahar expanded source link changed')
    embedding = generated(engine, destination)
    build_dir = destination / 'build'
    arguments = ['cmake', '-S', str(expanded if engine == 'azahar' else source), '-B', str(build_dir), '-G', 'Ninja',
        '-DCMAKE_TOOLCHAIN_FILE=' + str(embedding / 'toolchain.cmake'), '-DCMAKE_OSX_SYSROOT=' + sdk,
        '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON',
        '-DCMAKE_PROJECT_INCLUDE=' + str(ROOT / 'ci/phase3-cmake-hook.cmake'),
        '-DIRIDIUM_ROOT=' + str(ROOT), '-DIRIDIUM_PHASE3_GENERATED=' + str(embedding),
        '-DIRIDIUM_PHASE3_TARGET_HOOK=' + str(ROOT / 'ci/phase3-targets.cmake')]
    if engine == 'dolphin':
        arguments += ['-DENABLE_VULKAN=OFF', '-DENABLE_TESTS=OFF', '-DUSE_MGBA=OFF', '-DENABLE_LLVM=OFF',
            '-DENABLE_ANALYTICS=OFF', '-DUSE_RETRO_ACHIEVEMENTS=OFF', '-DUSE_SYSTEM_LIBS=OFF', '-DWITH_NEON=OFF',
            '-DCMAKE_CXX_FLAGS=-DFMT_CONSTEVAL=']
        target, relative = 'dolphin', 'Source/iOS/Library/libIridiumDolphin.dylib'
    elif engine == 'azahar':
        moltenvk_library, moltenvk_receipt = azahar_moltenvk(sdk, jobs)
        arguments += ['-DENABLE_LIBRETRO=ON', '-DENABLE_VULKAN=ON', '-DENABLE_OPT=OFF',
            '-DENABLE_LTO=OFF', '-DCITRA_USE_PRECOMPILED_HEADERS=OFF', '-DCITRA_WARNINGS_AS_ERRORS=OFF',
            '-DCMAKE_C_FLAGS=-DIOS', '-DCMAKE_CXX_FLAGS=-DIOS', '-DIRIDIUM_AZAHAR_MOLTENVK=' + str(moltenvk_library)]
        target, relative = 'citra_libretro', 'bin/Release/azahar_libretro.dylib'
    elif engine == 'play':
        arguments += ['-DTARGET_IOS=ON', '-DBUILD_PLAY=OFF', '-DBUILD_TESTS=OFF', '-DBUILD_LIBRETRO_CORE=ON']
        target, relative = 'play_libretro', 'Source/ui_libretro/play_libretro_ios.dylib'
    else:
        arguments += ['-DLIBRETRO=ON', '-DUSE_VULKAN=OFF', '-DUSE_HOST_LIBZIP=OFF', '-DUSE_OPENMP=OFF',
            '-DENABLE_CTEST=OFF', '-DUSE_BREAKPAD=OFF', '-DUSE_UPNP=OFF', '-DCMAKE_C_FLAGS=-DIOS', '-DCMAKE_CXX_FLAGS=-DIOS']
        target, relative = 'flycast_libretro', binary_name
    run(*arguments)
    if engine == 'azahar':
        commands = json.loads((build_dir / 'compile_commands.json').read_text())
        for name in ('address_space.cpp', 'spin_lock_arm64.cpp', 'arm_dynarmic.cpp', 'shader_jit.cpp', 'shader_jit_a64_compiler.cpp', 'vk_platform.cpp', 'libretro_window.cpp', 'mouse_tracker.cpp', 'citra_libretro.cpp'):
            compiled = [Path(item['file']).resolve() for item in commands if Path(item['file']).name == name]
            if compiled != [(embedding / name).resolve()]:
                raise ValueError('Azahar must compile only its checked overlay: ' + name)
        if any(Path(item['file']).name in ('exception_handler_macos.cpp', 'exception_handler_macos_mig.c') for item in commands):
            raise ValueError('Azahar must not replace the shared debugger exception handlers')
        if any(Path(item['file']).name == 'libretro_vk.cpp' for item in commands):
            raise ValueError('Azahar must use its main Vulkan renderer')
        for item in commands:
            if '/src/video_core/' in item['file'] and '-DHAVE_LIBRETRO' in item['command']:
                raise ValueError('Azahar video must own its Vulkan device and presentation queue')
    run('cmake', '--build', build_dir, '--target', target, '-j', jobs)
    shutil.copy2(build_dir / relative, binary)
    record = audit(binary, sdk, native=engine == 'dolphin')
    if fixed_inputs(engine) != inputs:
        raise ValueError('Phase 3 build inputs changed during compilation: ' + engine)
    record.update(engine=engine, sdk=sdk, revision=revision, release=release, arguments=public_arguments(arguments),
                  buildInputs=fixed_inputs(engine), sourceRevisions=source_state(source),
                  recipeSHA256=digest(Path(__file__)),
                  embedding={p.relative_to(embedding).as_posix(): digest(p) for p in embedding.rglob('*') if p.is_file()})
    bridge_sources = {'dolphin': ['IRDolphin.mm', 'IRPhase3.h', 'IRDolphinAPI.h', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h'], 'azahar': ['IRAzaharJIT.cpp', 'IRAzaharGraphics.mm', 'IRPhase3.h', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h'],
        'play': ['IRPlayProbe.cpp', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h'],
        'flycast': ['IRFlycastProbe.cpp', 'IRJITExecutionProbe.c', 'IRJITExecutionProbe.h', 'IRJITDiagnostic.h']}[engine]
    record['adapterSources'] = {name: digest(BRIDGE / name) for name in bridge_sources}
    if engine == 'azahar':
        # The binary's official source archive includes its dependency closure;
        # the shallow root checkout alone does not contain their notices.
        expanded = ROOT / '.build/phase3-downloads/azahar-unified-source-2126.2'
        if not expanded.exists():
            with tarfile.open(downloads / 'azahar-unified-source-2126.2.tar.xz') as archive:
                archive.extractall(downloads, filter='data')
        notices(expanded, destination, allowed=archive_files)
        record['moltenVK'] = moltenvk_receipt
        for item in moltenvk_receipt['sourceInputs']:
            source_root = ROOT / '.build/azahar/moltenvk-source' / item['name']
            with tarfile.open(ROOT / '.build/runtime-downloads' / (item['sha256'] + '.tar')) as archive:
                for member in archive:
                    relative = Path(*Path(member.name).parts[1:])
                    if not member.isfile(): continue
                    if not relative.name.lower().startswith(('license', 'copying', 'notice', 'copyright', 'authors')) and not any(part.lower() == 'licenses' for part in relative.parts): continue
                    target = destination / 'licenses/MoltenVK' / item['name'] / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source_root / relative, target)
    else:
        notices(source, destination)
    assets = destination / 'assets'
    if assets.exists(): shutil.rmtree(assets)
    assets.mkdir(exist_ok=True)
    if engine == 'dolphin':
        shutil.copytree(source / 'Data/Sys', assets / 'Sys', dirs_exist_ok=True)
    if engine == 'play':
        shutil.copy2(source / 'GameConfig.xml', assets / 'GameConfig.xml')
    if engine == 'azahar':
        record['officialArtifacts'] = AZAHAR_DOWNLOADS
    if engine != 'host':
        commands = json.loads((build_dir / 'compile_commands.json').read_text())
        record['compiledInputs'] = {Path(item['file']).resolve().relative_to(ROOT).as_posix(): digest(Path(item['file'])) for item in commands}
    record['files'] = {p.relative_to(destination).as_posix(): digest(p)
        for folder in (assets, destination / 'licenses') for p in folder.rglob('*') if p.is_file()}
    (destination / 'component.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    print(json.dumps(dict(engine=engine, sdk=sdk, binary=str(binary), sha256=record['sha256'])), flush=True)


def host(sdk):
    inputs = fixed_inputs('host')
    destination = ROOT / '.build/phase3/host' / sdk
    destination.mkdir(parents=True, exist_ok=True)
    exports = destination / 'native.exports'; exports.write_text('\n'.join(sorted(NATIVE_EXPORTS)) + '\n')
    binary = destination / 'libIridiumRetroPlayer.dylib'
    target = 'arm64-apple-ios18.0' + ('-simulator' if sdk == 'iphonesimulator' else '')
    arguments = ['xcrun', '--sdk', sdk, 'clang++', '-std=c++17', '-fobjc-arc', '-dynamiclib', '-O2',
        '-target', target, '-isysroot', output('xcrun', '--sdk', sdk, '--show-sdk-path'),
        '-I', ROOT / 'vendor/Flycast/core/deps/libretro-common/include', '-I', BRIDGE,
        BRIDGE / 'IRRetroPlayer.mm', '-Wl,-exported_symbols_list,' + str(exports),
        '-framework', 'UIKit', '-framework', 'AVFAudio', '-framework', 'CoreGraphics',
        '-framework', 'OpenGLES', '-framework', 'QuartzCore', '-install_name', '@rpath/' + binary.name, '-o', binary]
    run(*arguments)
    if fixed_inputs('host') != inputs:
        raise ValueError('Phase 3 host inputs changed during compilation')
    record = audit(binary, sdk, native=True)
    record.update(engine='host', sdk=sdk, buildInputs=fixed_inputs('host'), arguments=public_arguments(arguments))
    (destination / 'component.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', choices=(*PINS, 'host', 'all'), default='all')
    parser.add_argument('--sdk', choices=('iphoneos', 'iphonesimulator'), default='iphoneos')
    parser.add_argument('--jobs', type=int, default=3)
    args = parser.parse_args()
    if args.jobs < 1 or args.jobs > 16:
        parser.error('Choose between 1 and 16 build jobs')
    if args.engine in ('all', 'host'):
        host(args.sdk)
    for engine in PINS if args.engine == 'all' else [args.engine] if args.engine != 'host' else []:
        build(engine, args.sdk, args.jobs)
