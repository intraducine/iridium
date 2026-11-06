"""Execute the shared frontend's production clock, audio prefill and Play sink."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import phase3_play

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'


@unittest.skipUnless(shutil.which('c++'), 'C++ compiler required')
class ConsoleTimingTests(unittest.TestCase):
    def compile_run(self, code, includes=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'main.cpp'; binary = root / 'check'
            source.write_text(code)
            subprocess.run(['c++', '-std=c++17', '-I', str(BRIDGE), *includes, str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=10)

    def test_clock_jitter_pal_ntsc_pause_and_bounded_stalls(self):
        self.compile_run(r'''
#include "IRRuntimeTiming.h"
#include <cassert>
#include <cstdio>
int main() {
 for(double fps : {50.0, 59.72750056960583, 60.0}) {
  IRFramePacer clock;
  unsigned old=0, current=0;
  double last=-1;
  for(unsigned ms=0;ms<2000;++ms) {
   double now=ms/1000.0;
   if(ms>=200&&ms<225)continue;
   if(ms>=1200&&ms<1225)continue;
   if(std::floor(now*fps)==last)continue;
   last=std::floor(now*fps);++old;
   current+=clock.steps(now,fps);
  }
  assert(std::abs(current-2*fps)<=1 && current>old);
  assert(clock.steps(2-1/fps/2,fps)==0); // early wakeup never speeds the guest up
  assert(clock.steps(30,fps)==3 && clock.discarded>1000);
  clock.reset();assert(clock.steps(120,fps)==1); // no pause debt
  printf("fps=%.5f old=%u recovered=%u\n",fps,old,current);
 }
 IRFramePacer clock;assert(clock.steps(NAN,60)==0 && clock.steps(0,0)==0);
}
''')

    def test_audio_prefill_underrun_recovery_mute_and_stereo_sample_counts(self):
        self.compile_run(r'''
#include "IRRuntimeTiming.h"
#include <cassert>
int main() {
 for(double rate : {22050.0,44100.0,48000.0,96000.0}) {
  IRAudioPrefill audio;uint32_t threshold=(uint32_t)std::ceil(rate*.05);
  assert(audio.frames(threshold-1,128,rate,false)==0);
  assert(audio.frames(threshold,128,rate,false)==128);
  assert(audio.frames(31,128,rate,false)==31 && audio.underruns==1);
  assert(audio.frames(threshold-1,128,rate,false)==0);
  assert(audio.frames(threshold,128,rate,false)==128);
  assert(audio.frames(threshold,128,rate,true)==0 && !audio.primed);
  assert(audio.frames(0,128,rate,false)==0);
 }
}
''')

    @unittest.skipUnless((ROOT / 'vendor/Play/Source/ui_libretro/SH_LibreAudio.cpp').is_file(), 'Pinned Play source required')
    def test_play_delivers_vm_audio_without_waiting_for_a_video_frame(self):
        text = phase3_play.audio_source((ROOT / 'vendor/Play/Source/ui_libretro/SH_LibreAudio.cpp').read_text())
        text = '\n'.join(line for line in text.splitlines() if not line.startswith('#include'))
        self.compile_run(r'''
#include <vector>
#include <mutex>
#include <cstdint>
#include <cassert>
using int16=int16_t;
struct CSoundHandler {};
using retro_audio_sample_batch_t=size_t(*)(const int16_t*,size_t);
static std::vector<int16_t> heard;
static size_t batch(const int16_t* data,size_t frames) {
 heard.insert(heard.end(),data,data+frames*2);return frames;
}
retro_audio_sample_batch_t g_set_audio_sample_batch_cb=batch;
struct CSH_LibreAudio:CSoundHandler {
 std::vector<int16> m_buffer;std::mutex m_buffer_lock;
 static CSoundHandler* HandlerFactory();
 void Write(int16*,unsigned,unsigned);void ProcessBuffer();
 bool HasFreeBuffers();void Reset();void RecycleBuffers();
};
SOURCE
int main() {
 CSH_LibreAudio audio;int16_t a[]={100,-100,200,-200},b[]={300,-300};
 audio.Write(a,4,44100);
 assert(heard.size()==4); // no video callback or ProcessBuffer is needed
 audio.Write(b,2,44100);
 assert((heard==std::vector<int16_t>{100,-100,200,-200,300,-300}));
 audio.ProcessBuffer();assert(heard.size()==6);
 audio.Write(a,3,44100);audio.Write(nullptr,2,44100);audio.ProcessBuffer();assert(heard.size()==6);
}
'''.replace('SOURCE', text))

    def test_native_audio_producer_is_clocked_without_drops_and_pause_releases_wait(self):
        text = (BRIDGE / 'IRRetroPlayer.mm').read_text()
        begin = text.index('static size_t audioBatch(')
        end = text.index('static void audioSample', begin)
        producer = text[begin:end]
        self.compile_run(r'''
#include <atomic>
#include <algorithm>
#include <cmath>
#include <chrono>
#include <thread>
#include <future>
#include <string>
#include <vector>
#include <cassert>
static constexpr uint32_t audioCapacity=16384;
struct IRRetroPlayer {
 std::string engine;
 std::atomic<bool> muted{false};
 std::atomic<uint32_t> readAudio{UINT32_MAX-1000},writeAudio{UINT32_MAX-1000};
 std::atomic<uint64_t> producedAudio{0},droppedAudio{0};
 double initialAudioRate=44100;
 std::vector<int16_t> samples=std::vector<int16_t>(audioCapacity*2);
};
static IRRetroPlayer *active;
PRODUCER
int main() {
 for(const char *engine : {"play","flycast"}) {
  IRRetroPlayer player;player.engine=engine;active=&player;
  // 30-fps content produces 1,470 stereo frames per run. Calling it at 60 Hz
  // must wait for audio consumption, rather than double speed and drop samples.
  auto input=std::async(std::launch::async, [&] {
   std::vector<int16_t> block(1470*2);
   for(unsigned call=0;call<12;++call) {
    for(unsigned i=0;i<1470;++i){block[i*2]=(call*1470+i)%30000;block[i*2+1]=-block[i*2];}
    assert(audioBatch(block.data(),1470)==1470);
   }
  });
  unsigned heard=0;
  while(heard<12*1470) {
   auto read=player.readAudio.load(),write=player.writeAudio.load();
   auto queued=write-read;assert(queued<=3528);
   auto frames=std::min(queued,441u);
   for(unsigned i=0;i<frames;++i){
    assert(player.samples[((read+i)%audioCapacity)*2]==(heard+i)%30000);
    assert(player.samples[((read+i)%audioCapacity)*2+1]==-(int)((heard+i)%30000));
   }
   player.readAudio.store(read+frames);heard+=frames;
   std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  input.get();assert(player.producedAudio==heard&&player.droppedAudio==0);
  // A paused or lost output cannot trap a native worker or overwrite unread PCM.
  player.readAudio=0;player.writeAudio=3528;
  int16_t block[2]={1,-1};
  auto blocked=std::async(std::launch::async,[&]{audioBatch(block,1);});
  player.muted=true;
  assert(blocked.wait_for(std::chrono::milliseconds(200))==std::future_status::ready);
  blocked.get();assert(player.writeAudio==3528);
  player.muted=false;
  audioBatch(block,1);assert(player.writeAudio==3528&&player.droppedAudio==1);
 }
}
'''.replace('PRODUCER', producer))

    def test_production_audio_render_preserves_stereo_pitch_and_wraps_without_padding(self):
        text = (BRIDGE / 'IRRetroPlayer.mm').read_text()
        begin = text.index('        uint32_t read = p->readAudio.load', text.index('audioSource = [[AVAudioSourceNode'))
        end = text.index('return noErr;', begin) + len('return noErr;')
        render = text[begin:end]
        self.compile_run(r'''
#include "IRRuntimeTiming.h"
#include <vector>
#include <cassert>
using UInt32=uint32_t;
static constexpr uint32_t audioCapacity=16384;
struct Buffer {void *mData;};
struct Buffers {unsigned mNumberBuffers;Buffer mBuffers[2];};
struct Player {
 std::atomic<uint32_t> readAudio{16380},writeAudio{16380};std::atomic<bool> muted{false};
 IRAudioPrefill audioPrefill;double initialAudioRate=48000;
 std::vector<int16_t> samples=std::vector<int16_t>(audioCapacity*2);
};
static float gain=1;
void ir_audio_volume_apply_float(float *out,unsigned count){for(unsigned i=0;i<count;++i)out[i]*=gain;}
int render(Player *p,unsigned count,Buffers *buffers,bool *silent) {
 const int noErr=0;
RENDER
}
int main() {
 Player p;
 for(unsigned i=0;i<3000;++i){auto index=(16380+i)%audioCapacity;p.samples[index*2]=i%2?16000:-16000;p.samples[index*2+1]=-p.samples[index*2];}
 p.writeAudio=16380+3000;
 float left[513]={},right[513]={};left[512]=right[512]=42;
 Buffers out{2,{{left},{right}}};bool silent=true;
 render(&p,512,&out,&silent);assert(!silent && p.readAudio==16380+512);
 for(unsigned i=0;i<512;++i){assert(left[i]==(i%2?16000:-16000)/32768.f);assert(right[i]==-left[i]);}
 assert(left[512]==42&&right[512]==42);
 gain=0;render(&p,512,&out,&silent);for(unsigned i=0;i<512;++i)assert(left[i]==0&&right[i]==0);
 p.muted=true;render(&p,512,&out,&silent);assert(silent && p.readAudio==p.writeAudio && !p.audioPrefill.primed);
}
'''.replace('RENDER', render))

    def test_production_host_uses_monotonic_clock_and_prefill(self):
        text = (BRIDGE / 'IRRetroPlayer.mm').read_text()
        self.assertIn('framePacer.steps(CACurrentMediaTime(),self->currentFPS)', text)
        self.assertIn('audioPrefill.frames(write - read, count', text)
        session = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumConsoleSession.swift').read_text()
        self.assertIn('completionCallbackType: .dataRendered', session)
        self.assertNotIn('completionCallbackType: .dataPlayedBack', session)
        self.assertLess(session.index('try startAudioSession()'), session.index('switch backend {'))
