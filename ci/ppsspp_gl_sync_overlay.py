"""Request-specific GL readback completion for the release-pinned PSP engine."""
import hashlib

PATCHED = ('Common/GPU/OpenGL/GLRenderManager.h', 'Common/GPU/OpenGL/GLRenderManager.cpp')


def validate_component(record, source):
    expected = {name: hashlib.sha256(apply(name, (source / name).read_text()).encode()).hexdigest() for name in PATCHED}
    if any(record.get('embeddingHooks', {}).get(name) != value for name, value in expected.items()):
        raise ValueError('Rebuild the PSP component with the declared GL synchronization fix')
    if record.get('compiledInputSHA256', {}).get('embedding/' + PATCHED[1]) != expected[PATCHED[1]]:
        raise ValueError('The patched GL render manager was not compiled')
    audited = record.get('glSyncHeaderAudit', {})
    if audited.get('headerSHA256') != expected[PATCHED[0]] or audited.get('references', 0) < 1:
        raise ValueError('The PSP GL header dependency audit is missing')


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('PPSSPP GL synchronization hook changed: ' + old[:90])
    return text.replace(old, new)


def apply(name, text):
    if name.endswith('.h'):
        text = replace(text, '\tGLRRunType runType;', '\tGLRRunType runType;\n\tuint64_t syncId = 0;')
        text = replace(text, '\tvoid FlushSync();', '\tbool FlushSync();')
        return replace(text, '\tbool syncDone_ = false;', '''	// Protected by syncMutex_. Only the completed request can release a readback.
	uint64_t syncSubmitted_ = 0;
	uint64_t syncCompleted_ = 0;
	bool syncCancelled_ = false;''')
    text = replace(text, '''				lock.unlock();
				// Oh, host wanted out. Let's leave, and also let's notify the host.
				// This is unlike Vulkan too which can just block on the thread existing.
				std::unique_lock<std::mutex> lock(syncMutex_);
				syncCondVar_.notify_one();
				syncDone_ = true;
				return false;''', '''				// An empty host drain completes no submitted work.
				return false;''')
    text = replace(text, '\trunCompileThread_ = false;', '''	{
		std::lock_guard<std::mutex> lock(syncMutex_);
		syncCancelled_ = true;
		syncCondVar_.notify_all();
	}
	runCompileThread_ = false;''')
    text = replace(text, '\t\trunCompileThread_ = true;', '''		{
			std::lock_guard<std::mutex> lock(syncMutex_);
			syncCancelled_ = false;
		}
		runCompileThread_ = true;''')
    text = replace(text, '''			syncDone_ = true;
			syncCondVar_.notify_one();''', '''			if (skipGLCalls_) syncCancelled_ = true;
			else if (task.syncId > syncCompleted_) syncCompleted_ = task.syncId;
			syncCondVar_.notify_all();''')
    start = text.index('void GLRenderManager::FlushSync() {')
    # FlushSync is the final function in the pinned translation unit.
    if text[start:].count('\n}') != 1:
        raise ValueError('PPSSPP GL FlushSync boundary changed')
    text = text[:start] + '''bool GLRenderManager::FlushSync() {
	// Publish and wait under the same completion lock: a render thread that
	// finishes immediately cannot lose its acknowledgement before we wait.
	std::unique_lock<std::mutex> syncLock(syncMutex_);
	if (syncCancelled_) return false;
	const uint64_t request = ++syncSubmitted_;
	{
		GLRRenderThreadTask *task = new GLRRenderThreadTask(GLRRunType::SYNC);
		task->frame = curFrame_;
		task->syncId = request;
		std::lock_guard<std::mutex> lock(pushMutex_);
		task->initSteps = std::move(initSteps_);
		task->steps = std::move(steps_);
		renderThreadQueue_.push(task);
		pushCondVar_.notify_one();
		steps_.clear();
	}
	syncCondVar_.wait(syncLock, [this, request] {
		return syncCompleted_ >= request || syncCancelled_;
	});
	return !syncCancelled_ && syncCompleted_ >= request;
}
'''
    text = replace(text, '\tFlushSync();\n\n\tDraw::DataFormat srcFormat;',
                   '\tif (!FlushSync()) return false;\n\n\tDraw::DataFormat srcFormat;')
    return replace(text, '\tFlushSync();\n\n\tqueueRunner_.CopyFromReadbackBuffer(nullptr,',
                   '\tif (!FlushSync()) return;\n\n\tqueueRunner_.CopyFromReadbackBuffer(nullptr,')
