"""Execute the pinned GL queue protocol with controlled producer/consumer races."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import hashlib
import ppsspp_gl_sync_overlay as overlay

ROOT = Path(__file__).resolve().parents[1]


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2]


def harness(patched):
    source = (ROOT / 'vendor/PPSSPP' / overlay.PATCHED[1]).read_text()
    header = (ROOT / 'vendor/PPSSPP' / overlay.PATCHED[0]).read_text()
    if patched:
        source = overlay.apply(overlay.PATCHED[1], source)
        header = overlay.apply(overlay.PATCHED[0], header)
    flush = function(source, ('bool' if patched else 'void') + ' GLRenderManager::FlushSync()')
    flush = flush.replace('steps_.clear();\n\t}', 'steps_.clear();\n\t}\n\tAfterPublish();')
    methods = '\n'.join(function(source, signature) for signature in (
        'bool GLRenderManager::ThreadFrame(', 'void GLRenderManager::ThreadEnd()',
        'void GLRenderManager::StartThread()'))
    sync = header[header.index('\tstd::mutex syncMutex_;'):header.index('\n\tGLDeleter deleter_;')]
    sync = sync.replace('std::condition_variable syncCondVar_;', 'TrackedCV syncCondVar_{&probe};')
    ack = source.split('\tcase GLRRunType::SYNC:\n', 1)[1].split('\n\t\tbreak;', 1)[0]
    return r'''
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <mutex>
#include <queue>
#include <thread>
#include <vector>
#define INFO_LOG(...)
#define VLOG(...)
#define _assert_(x) assert(x)
constexpr int MAX_INFLIGHT_FRAMES = 1;
struct Probe {
    std::mutex mutex; std::condition_variable cv;
    unsigned waits=0, evaluations=0; bool returned=false, work=false;
    template<class F> void until(F f) {
        std::unique_lock<std::mutex> lock(mutex);
        assert(cv.wait_for(lock,std::chrono::seconds(3),f));
    }
    template<class F> void change(F f) {std::lock_guard<std::mutex> lock(mutex);f();cv.notify_all();}
};
struct TrackedCV {
    Probe *p; std::condition_variable cv;
    void notify_one(){cv.notify_one();} void notify_all(){cv.notify_all();}
    void wait(std::unique_lock<std::mutex>& lock) {
        p->change([&]{p->waits++;}); cv.wait(lock);
    }
    template<class F> void wait(std::unique_lock<std::mutex>& lock,F predicate) {
        p->change([&]{p->waits++;});
        cv.wait(lock,[&]{p->change([&]{p->evaluations++;});return predicate();});
    }
};
enum class GLRRunType {SUBMIT,PRESENT,SYNC};
struct GLRStep {};
template<class T> using FastVec=std::vector<T>;
struct GLRRenderThreadTask {
    explicit GLRRenderThreadTask(GLRRunType type):runType(type){}
    std::vector<GLRStep*> steps; FastVec<int> initSteps;
    int frame=0; GLRRunType runType; uint64_t syncId=0;
};
struct Deleter {void Perform(void*,bool){}};
struct Frame {bool hasBegun=false; Deleter deleter,deleter_prev;};
class GLRenderManager {
public:
    Probe probe;
    SYNCMEMBERS
    std::mutex pushMutex_; std::condition_variable pushCondVar_;
    std::queue<GLRRenderThreadTask*> renderThreadQueue_;
    bool runCompileThread_=true,skipGLCalls_=false; int curFrame_=0;
    std::vector<GLRStep*> steps_; FastVec<int> initSteps_;
    Frame frameData_[1]; Deleter deleter_;
    struct {void DestroyDeviceObjects(){}} queueRunner_;
    std::atomic<uint64_t> bufferRequest{0};
    std::atomic<bool> copiedBeforeCompletion{false};
    bool afterPublish=false;
    bool ThreadFrame(bool); void ThreadEnd(); void StartThread();
    FLUSHDECL
    bool Readback() {
        bool ok=FLUSHRESULT;
        if(ok && bufferRequest.load()==0)copiedBeforeCompletion=true;
        probe.change([&]{probe.returned=true;}); return ok;
    }
    void AfterPublish() {
        if(afterPublish)probe.until([&]{return probe.work;});
    }
    bool Run(GLRRenderThreadTask& task) {
        if(task.runType==GLRRunType::PRESENT)return true;
        auto& frameData=frameData_[task.frame];
        // Stand-in GPU work: completion must follow init and readback, as the
        // real Run does. No GPU rendering result is claimed by this harness.
        if(!skipGLCalls_)bufferRequest=task.syncId ? task.syncId : 1;
        probe.change([&]{probe.work=true;});
        ACK
        return false;
    }
    GLRRenderThreadTask *Take() {
        std::unique_lock<std::mutex> lock(pushMutex_);
        assert(pushCondVar_.wait_for(lock,std::chrono::seconds(3),[&]{return !renderThreadQueue_.empty();}));
        auto *task=renderThreadQueue_.front();renderThreadQueue_.pop();return task;
    }
};
METHODS
FLUSH
int main() {
    {
        GLRenderManager m;
        assert(!m.ThreadFrame(false));
        std::thread producer([&]{m.Readback();});
        m.probe.until([&]{return m.probe.waits || m.probe.returned;});
        if(LEGACY) {
            assert(m.probe.returned && m.copiedBeforeCompletion);
            auto *task=m.Take();m.Run(*task);delete task;producer.join();
            puts("REPRO: empty drain releases readback before its SYNC runs");return 0;
        }
        assert(!m.probe.returned && !m.copiedBeforeCompletion);
        assert(!m.ThreadFrame(false));producer.join();
        assert(!m.copiedBeforeCompletion && m.bufferRequest==1);
    }
    PATCHEDCHECKS
    puts("PASS: own-SYNC completion, empty drains, publish/ack race, stale ack and shutdown");
}
'''.replace('SYNCMEMBERS', sync).replace('FLUSHDECL', ('bool' if patched else 'void') + ' FlushSync();').replace(
        'FLUSHRESULT', 'FlushSync()' if patched else '(FlushSync(), true)').replace('METHODS', methods).replace(
        'FLUSH\n', flush + '\n').replace('ACK', ack).replace('LEGACY', 'false' if patched else 'true').replace(
        'PATCHEDCHECKS', r'''
    {
        GLRenderManager m;m.afterPublish=true;
        std::thread consumer([&]{auto *task=m.Take();m.Run(*task);delete task;});
        assert(m.Readback());consumer.join();assert(!m.copiedBeforeCompletion);
    }
    {
        GLRenderManager m;m.skipGLCalls_=true;bool completed=true;
        std::thread producer([&]{completed=m.Readback();});
        m.probe.until([&]{return m.probe.waits>0;});
        assert(!m.ThreadFrame(false));producer.join();
        assert(!completed && !m.copiedBeforeCompletion && m.bufferRequest==0);
    }
    {
        GLRenderManager m;bool first=true;
        std::thread producer([&]{first=m.Readback();});
        m.probe.until([&]{return m.probe.waits>0;});
        m.ThreadEnd();producer.join();assert(!first && !m.copiedBeforeCompletion);
        auto *old=m.Take();
        assert(!m.FlushSync());assert(m.renderThreadQueue_.empty());
        m.StartThread();assert(!m.ThreadFrame(false));
        m.probe.change([&]{m.probe.returned=false;});
        unsigned before;
        {std::lock_guard<std::mutex> lock(m.probe.mutex);before=m.probe.evaluations;}
        std::thread next([&]{assert(m.Readback());});
        m.probe.until([&]{return m.probe.evaluations>before;});
        {std::lock_guard<std::mutex> lock(m.probe.mutex);before=m.probe.evaluations;}
        m.Run(*old);delete old;
        m.probe.until([&]{return m.probe.evaluations>before || m.probe.returned;});
        assert(!m.probe.returned); // A completed prior-generation request is not this readback.
        assert(!m.ThreadFrame(false));next.join();
        assert(m.bufferRequest==2 && !m.copiedBeforeCompletion);
    }
''' if patched else '')


class GLSyncTests(unittest.TestCase):
    def test_old_or_incomplete_component_cannot_be_reused(self):
        source=ROOT/'vendor/PPSSPP'
        with self.assertRaisesRegex(ValueError,'Rebuild'):
            overlay.validate_component({'revision':'fa50bb1976065c4f8b1b47af227d367fe9771555'},source)
        hashes={n:hashlib.sha256(overlay.apply(n,(source/n).read_text()).encode()).hexdigest() for n in overlay.PATCHED}
        record={'embeddingHooks':hashes,'compiledInputSHA256':{}}
        with self.assertRaisesRegex(ValueError,'not compiled'):overlay.validate_component(record,source)
        record['compiledInputSHA256']['embedding/'+overlay.PATCHED[1]]=hashes[overlay.PATCHED[1]]
        with self.assertRaisesRegex(ValueError,'header'):overlay.validate_component(record,source)
        record['glSyncHeaderAudit']={'headerSHA256':hashes[overlay.PATCHED[0]],'references':14}
        overlay.validate_component(record,source)

    @unittest.skipUnless(shutil.which('clang++'), 'C++ compiler required')
    def test_actual_queue_protocol_and_old_counterexample(self):
        for patched in (False, True):
            with self.subTest(patched=patched), tempfile.TemporaryDirectory() as folder:
                root=Path(folder);source=root/'check.cpp';binary=root/'check';source.write_text(harness(patched))
                built=subprocess.run(['clang++','-std=c++17','-pthread',str(source),'-o',str(binary)],capture_output=True,text=True)
                self.assertEqual(built.returncode,0,built.stderr)
                run=subprocess.run([str(binary)],capture_output=True,text=True,timeout=15)
                self.assertEqual(run.returncode,0,run.stderr)
                self.assertIn('PASS:' if patched else 'REPRO:',run.stdout)

    def test_cancelled_readbacks_never_copy_gpu_memory(self):
        name=overlay.PATCHED[1];source=overlay.apply(name,(ROOT/'vendor/PPSSPP'/name).read_text())
        framebuffer=function(source,'bool GLRenderManager::CopyFramebufferToMemory(')
        texture=function(source,'void GLRenderManager::CopyImageToMemorySync(')
        self.assertLess(framebuffer.index('if (!FlushSync()) return false;'),framebuffer.index('CopyFromReadbackBuffer'))
        self.assertLess(texture.index('if (!FlushSync()) return;'),texture.index('CopyFromReadbackBuffer'))
        run=function(source,'bool GLRenderManager::Run(')
        self.assertLess(run.index('RunInitSteps'),run.index('iter->Flush()'))
        self.assertLess(run.index('iter->MapDevice'),run.index('syncCompleted_ = task.syncId'))


if __name__=='__main__':unittest.main()
