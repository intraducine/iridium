"""Exercise saved game gain, final PCM scaling, and native-engine handoff."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'
sys.path.insert(0, str(ROOT / 'ci'))
import madeira_audio_volume
import ppsspp_native_overlay


class GameVolumeTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('cc') and shutil.which('c++'), 'C and C++ compilers required')
    def test_pcm_and_native_binding_in_c_and_cpp(self):
        fixture = r'''#include "IRAudioVolume.h"
#include <assert.h>
#include <dlfcn.h>
#include <math.h>
int main(int argc, char **argv) {
    assert(argc == 2 && ir_audio_volume_get() == 1);
    int16_t source[] = {-32768, -16384, 0, 16384, 32767};
    ir_audio_volume_apply_i16(source, 5);
    assert(source[0] == -32768 && source[4] == 32767);
    ir_audio_volume_set(0.5f); ir_audio_volume_apply_i16(source, 5);
    assert(source[0] == -16384 && source[1] == -8192 && source[3] == 8192 && source[4] == 16383);
    float samples[] = {-1, -0.5f, 0, 0.5f, 1};
    ir_audio_volume_apply_float(samples, 5);
    assert(samples[0] == -0.5f && samples[4] == 0.5f);
    ir_audio_volume_set(0); ir_audio_volume_apply_float(samples, 5); ir_audio_volume_apply_i16(source, 5);
    for (int i = 0; i < 5; ++i) assert(samples[i] == 0 && source[i] == 0);
    ir_audio_volume_apply_float(NULL, 1); ir_audio_volume_apply_i16(NULL, 1);
    ir_audio_volume_set(INFINITY); assert(ir_audio_volume_get() == 0);
    ir_audio_volume_set(NAN); assert(ir_audio_volume_get() == 0);
    ir_audio_volume_set(-1); assert(ir_audio_volume_get() == 0);
    ir_audio_volume_set(2); assert(ir_audio_volume_get() == 1);
    void *image = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL); assert(image);
    float (*last)(void) = (float(*)(void))dlsym(image, "last_volume"); assert(last);
    assert(!ir_audio_volume_bind(image, NULL));
    assert(!ir_audio_volume_bind(image, "missing"));
    ir_audio_volume_set(0.25f);
    assert(last() == 1);
    assert(ir_audio_volume_bind(image, "set_volume") && last() == 0.25f);
    ir_audio_volume_set(0.75f); assert(last() == 0.75f);
    assert(ir_audio_volume_bind(NULL, NULL));
    ir_audio_volume_set(0); assert(last() == 0.75f);
    assert(!ir_audio_volume_bind(image, "missing"));
    ir_audio_volume_set(1); assert(last() == 0.75f);
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = root / 'engine.dylib'
            unit = root / 'engine.c'
            unit.write_text('#include "IRAudioVolume.h"\nvoid set_volume(float v) {ir_audio_volume_set(v);} float last_volume(void) {return ir_audio_volume_get();}')
            subprocess.run(['cc', '-dynamiclib' if sys.platform == 'darwin' else '-shared', '-fPIC', '-I', str(BRIDGE), str(unit),
                            str(BRIDGE / 'IRAudioVolume.c'), '-o', str(library)], check=True)
            main = root / 'main.c'; main.write_text(fixture)
            for compiler, standard in [('cc', 'c11'), ('c++', 'c++17')]:
                executable = root / compiler.replace('+', 'p')
                subprocess.run([compiler, '-std=' + standard, '-I', str(BRIDGE), str(main),
                                str(BRIDGE / 'IRAudioVolume.c'), '-o', str(executable)], check=True)
                subprocess.run([str(executable), str(library)], check=True, timeout=10)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_saved_levels_and_legacy_mute_stay_per_game(self):
        fixture = r'''import Foundation
let defaults = UserDefaults(suiteName: UUID().uuidString)!
let a = UUID(), b = UUID(), c = UUID()
precondition(IridiumGameVolume.load(a, defaults: defaults) == 1)
precondition(IridiumGameVolume.load(a, legacyMuted: true, defaults: defaults) == 0)
IridiumGameVolume.save(0.37, game: a, defaults: defaults)
IridiumGameVolume.save(0, game: b, defaults: defaults)
precondition(IridiumGameVolume.load(a, legacyMuted: true, defaults: defaults) == 0.37)
precondition(IridiumGameVolume.load(b, defaults: defaults) == 0)
precondition(IridiumGameVolume.load(c, defaults: defaults) == 1)
IridiumGameVolume.save(2, game: a, defaults: defaults)
precondition(IridiumGameVolume.load(a, defaults: defaults) == 1)
IridiumGameVolume.save(-1, game: a, defaults: defaults)
precondition(IridiumGameVolume.load(a, defaults: defaults) == 0)
precondition(IridiumGameVolume.clamp(.nan) == 0 && IridiumGameVolume.clamp(.infinity) == 0)
for game in [a,b,c] { defaults.removeObject(forKey: "GameVolume.\(game)") }
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); main = root / 'main.swift'; main.write_text(fixture)
            executable = root / 'volume'
            subprocess.run(['swiftc', str(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumGameVolume.swift'),
                            str(main), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=10)

    def test_windows_overlay_scales_the_final_mix_and_rejects_changed_hooks(self):
        source = 'static OSStatus ios_audio_render_cb(void) {\n    atomic_fetch_add_explicit(&g_dev.cb_epoch, 1, memory_order_release);\n}'
        result = madeira_audio_volume.apply(source)
        self.assertLess(result.index('ir_audio_volume_apply_float(out, total);'), result.index('atomic_fetch_add'))
        for changed in ('', source + source, source.replace('cb_epoch', 'changed')):
            with self.assertRaises(ValueError): madeira_audio_volume.apply(changed)

    @unittest.skipUnless(shutil.which('cc') and (ROOT / 'vendor/Madeira/build/ntdll-unix/audio_null_ios.c').is_file(), 'Madeira source and C compiler required')
    def test_production_windows_final_mix_scales_without_changing_streams(self):
        text = madeira_audio_volume.apply((ROOT / 'vendor/Madeira/build/ntdll-unix/audio_null_ios.c').read_text())
        callback = text[text.index('static OSStatus ios_audio_render_cb('):text.index('/* Parse the WASAPI format')]
        fixture = r'''#include "IRAudioVolume.h"
#include <assert.h>
#include <stdatomic.h>
#include <string.h>
typedef int OSStatus; typedef unsigned UInt32; typedef unsigned UINT32; typedef unsigned AudioUnitRenderActionFlags;
typedef struct {} AudioTimeStamp;
typedef struct { void *mData; unsigned mDataByteSize; } AudioBuffer;
typedef struct { unsigned mNumberBuffers; AudioBuffer mBuffers[1]; } AudioBufferList;
enum { noErr=0, IOS_MAX_STREAMS=2 };
struct ios_stream { float level; };
static _Atomic(struct ios_stream *) g_mix[IOS_MAX_STREAMS];
static struct { unsigned rate, channels; _Atomic(unsigned) cb_epoch, clamped; } g_dev;
static void ios_mix_stream(struct ios_stream *s, float *out, UInt32 frames, UInt32 channels, UInt32 rate) {
    assert(rate==48000); for (unsigned i=0; i<frames*channels; ++i) out[i]+=s->level;
}
CALLBACK
int main(void) {
    struct ios_stream a={0.25f}, b={0.5f};
    g_mix[0]=&a; g_mix[1]=&b; g_dev.rate=48000; g_dev.channels=2;
    float samples[5]={0,0,0,0,42}; AudioBufferList output={1,{{samples,4*sizeof(float)}}};
    ir_audio_volume_set(1); ios_audio_render_cb(NULL,NULL,NULL,0,2,&output);
    assert(samples[0]==0.75f && samples[3]==0.75f && samples[4]==42);
    ir_audio_volume_set(0.5f); ios_audio_render_cb(NULL,NULL,NULL,0,200,&output);
    assert(samples[0]==0.375f && samples[3]==0.375f && samples[4]==42);
    ir_audio_volume_set(0); ios_audio_render_cb(NULL,NULL,NULL,0,2,&output);
    for (int i=0;i<4;++i) assert(samples[i]==0);
    assert(a.level==0.25f && b.level==0.5f && samples[4]==42 && g_dev.cb_epoch==3);
}
'''.replace('CALLBACK', callback)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); main = root / 'main.c'; main.write_text(fixture)
            executable = root / 'check'
            subprocess.run(['cc', '-std=c11', '-I', str(BRIDGE), str(main), str(BRIDGE / 'IRAudioVolume.c'), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=10)

    def test_psp_overlay_scales_output_after_the_upstream_mixer(self):
        source = '\tNativeMix(output, inNumberFrames, SAMPLE_RATE, nullptr);'
        result = ppsspp_native_overlay.apply('ios/iOSCoreAudio.mm', source)
        self.assertIn('ir_audio_volume_apply_i16(output, static_cast<size_t>(inNumberFrames) * 2);', result)
        self.assertLess(result.index('NativeMix'), result.index('ir_audio_volume_apply_i16'))
        with self.assertRaises(ValueError): ppsspp_native_overlay.apply('ios/iOSCoreAudio.mm', '')


if __name__ == '__main__':
    unittest.main()
