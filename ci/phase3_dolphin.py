"""Dolphin-only source overlays for the shared builder."""


def generated(ROOT, directory):
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


def arguments():
    return ['-DENABLE_VULKAN=OFF', '-DENABLE_TESTS=OFF', '-DUSE_MGBA=OFF', '-DENABLE_LLVM=OFF',
            '-DENABLE_ANALYTICS=OFF', '-DUSE_RETRO_ACHIEVEMENTS=OFF', '-DUSE_SYSTEM_LIBS=OFF', '-DWITH_NEON=OFF',
            '-DCMAKE_CXX_FLAGS=-DFMT_CONSTEVAL=']


TARGET, OUTPUT = 'dolphin', 'Source/iOS/Library/libIridiumDolphin.dylib'
