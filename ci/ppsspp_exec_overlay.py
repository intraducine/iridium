"""PSP-owned prepared executable arenas over the exact release-pinned engine."""

GUARD = 'defined(IRIDIUM_PSP_PREPARED_JIT) && PPSSPP_ARCH(ARM64)'
PATCHED = (
    'Common/CodeBlock.h', 'Common/Arm64Emitter.h', 'Common/Arm64Emitter.cpp', 'Common/MemoryUtil.cpp',
    'Core/MIPS/ARM64/Arm64Jit.cpp', 'Core/MIPS/ARM64/Arm64IRJit.cpp', 'Core/MIPS/ARM64/Arm64IRAsm.cpp',
    'Core/MIPS/JitCommon/JitCommon.cpp', 'Core/MIPS/IR/IRJit.cpp', 'Core/MIPS/MIPS.cpp', 'Core/System.cpp',
    'Core/MIPS/ARM64/Arm64Asm.cpp', 'Core/MIPS/IR/IRNativeCommon.cpp', 'Core/MIPS/IR/IRNativeCommon.h',
    'GPU/Common/VertexDecoderCommon.cpp', 'GPU/Common/VertexDecoderArm64.cpp',
    'GPU/Common/DrawEngineCommon.cpp', 'GPU/Software/RasterizerRegCache.cpp',
    'GPU/Software/RasterizerRegCache.h', 'GPU/Software/DrawPixel.cpp', 'GPU/Software/Sampler.cpp', 'GPU/GPU.cpp',
)


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('PSP prepared-memory hook changed: ' + old[:100])
    return text.replace(old, new)


def guarded(code):
    return '\n#if ' + GUARD + '\n' + code + '\n#endif\n'


def typed_guarded(code):
    # Common also compiles unused x64 emitters in an ARM64 build. Only the
    # concrete ARM64 template consumes the prepared PSP memory boundary.
    return guarded('if constexpr (std::is_same<T, Arm64Gen::ARM64XEmitter>::value) {\n' + code + '\n}')


def apply(name, text):
    if name not in PATCHED:
        return text
    text = '#include "ppsspp_config.h"\n#include "IRPSPExecutableMemory.h"\n' + text
    if name == 'Common/CodeBlock.h':
        text = '#include <type_traits>\nnamespace Arm64Gen { class ARM64XEmitter; }\n' + text
        text = replace(text, 'void AllocCodeSpace(int size) {', '''void AllocCodeSpace(int size, unsigned iridiumRole = 0) {'''+typed_guarded('''
        void *rx = nullptr, *rw = nullptr;
        iridiumClaim_ = ir_psp_exec_claim(iridiumRole, size, &rx, &rw);
        region = (u8 *)rx; writableRegion = (u8 *)rw;
        region_size = iridiumClaim_ ? size : 0;
        T::SetCodePointer(region, writableRegion);
        return;'''))
        text = replace(text, 'void ClearCodeSpace(int offset) {', 'void ClearCodeSpace(int offset) {' + typed_guarded('''
        if (!region || offset < 0 || (size_t)offset > region_size || !ir_psp_exec_begin_write(iridiumClaim_, region + offset, region_size - offset)) { T::FailEmission(); return; }
        T::ResetEmissionError();
        if (!ir_psp_exec_validate(writableRegion + offset, region_size - offset, true)) T::FailEmission();
        if (!T::EmissionFailed()) PoisonMemory(offset);
        if (!ir_psp_exec_end_write(iridiumClaim_, region + offset, region_size - offset)) T::FailEmission();
        ResetCodePtr(offset);
        return;'''))
        text = replace(text, 'bool BeginWrite(size_t sizeEstimate = 1) {', 'bool BeginWrite(size_t sizeEstimate = 1) {' + typed_guarded('''
        T::ResetEmissionError();
        if (!region || writeStart_ || !ir_psp_exec_begin_write(iridiumClaim_, GetCodePtr(), GetSpaceLeft())) { T::FailEmission(); return false; }
        writeStart_ = GetCodePtr();
        writeEstimated_ = sizeEstimate;
        return true;'''))
        text = replace(text, 'void ContinueWrite(size_t sizeEstimate = 1) {', 'void ContinueWrite(size_t sizeEstimate = 1) {' + typed_guarded('''
        if (!writeStart_ || !ir_psp_exec_validate(GetCodePtr(), 0, false)) T::FailEmission();
        return;'''))
        text = replace(text, 'bool EndWrite() {', 'bool EndWrite() {' + typed_guarded('''
        if (!writeStart_) return !T::EmissionFailed();
        const u8 *start = writeStart_; writeStart_ = nullptr;
        uintptr_t end = (uintptr_t)GetCodePtr(), begin = (uintptr_t)start;
        bool span = end >= begin && end - begin <= region_size;
        bool published = ir_psp_exec_end_write(iridiumClaim_, start, span && !T::EmissionFailed() ? end - begin : 0);
        return span && published && !T::EmissionFailed();'''))
        text = replace(text, 'void FreeCodeSpace() {', 'void FreeCodeSpace() {' + typed_guarded('''
        if (!iridiumClaim_) return;
        if (writeStart_ || !ir_psp_exec_release(iridiumClaim_)) { ir_psp_exec_fail(); return; }
        iridiumClaim_ = 0; region = nullptr; writableRegion = nullptr; region_size = 0;
        T::SetCodePointer(nullptr, nullptr);
        return;'''))
        text = replace(text, 'void ResetCodePtr(size_t offset) {', 'void ResetCodePtr(size_t offset) {' + typed_guarded('''
        if (!region || offset > region_size) { T::FailEmission(); return; }'''))
        a=text.index('\tconst u8 *GetCodePtrFromWritablePtr(u8 *ptr) override {')
        b=text.index('\nprotected:', a)
        text=text[:a]+'''\tconst u8 *GetCodePtrFromWritablePtr(u8 *ptr) override {
#if '''+GUARD+'''
        if constexpr (std::is_same<T, Arm64Gen::ARM64XEmitter>::value) {
            void *result = nullptr;
            if (!ir_psp_exec_translate(ptr, 0, false, &result)) { T::FailEmission(); return nullptr; }
            return (const u8 *)result;
        }
#endif
        return region + ((uintptr_t)ptr - (uintptr_t)writableRegion);
    }
    u8 *GetWritablePtrFromCodePtr(const u8 *ptr) override {
#if '''+GUARD+'''
        if constexpr (std::is_same<T, Arm64Gen::ARM64XEmitter>::value) {
            void *result = nullptr;
            if (!ir_psp_exec_translate(ptr, 0, true, &result)) { T::FailEmission(); return nullptr; }
            return (u8 *)result;
        }
#endif
        return writableRegion + ((uintptr_t)ptr - (uintptr_t)region);
    }
'''+text[b:]
        text = replace(text, '\t\tT::SetCodePointer(ptr, GetWritablePtrFromCodePtr(ptr));', '''        u8 *writable = GetWritablePtrFromCodePtr(ptr);''' + typed_guarded('    if (!writable) { T::FailEmission(); return; }') + '\t\tT::SetCodePointer(ptr, writable);')
        text = replace(text, '\tconst uint8_t *writeStart_ = nullptr;', guarded('    IRPSPExecClaim iridiumClaim_ = 0;')+'\tconst uint8_t *writeStart_ = nullptr;')
        text = replace(text, 'return region_size - (T::GetCodePointer() - region);', '''uintptr_t pointer = (uintptr_t)T::GetCodePointer(), base = (uintptr_t)region;
        return region && pointer >= base && pointer - base <= region_size ? region_size - (pointer - base) : 0;''')
        text = replace(text, 'return (ptr >= region) && (ptr < (region + region_size));', 'return region && (uintptr_t)ptr >= (uintptr_t)region && (uintptr_t)ptr - (uintptr_t)region < region_size;')
    elif name == 'Common/Arm64Emitter.h':
        text = replace(text, '\tconst u8 *m_code = nullptr;', guarded('    bool iridiumFailed_ = false;')+'\tconst u8 *m_code = nullptr;')
        text = replace(text, '\t\t*(u32 *)m_writable = value;', '''#if '''+GUARD+'''
        if (iridiumFailed_ || !ir_psp_exec_write32(m_code, m_writable, value)) { iridiumFailed_ = true; return; }
#else
        *(u32 *)m_writable = value;
#endif''')
        text = replace(text, '\tvoid SetCodePointer(const u8 *ptr, u8 *writePtr);', '''
    bool EmissionFailed() const {
#if '''+GUARD+'''
        return iridiumFailed_;
#else
        return false;
#endif
    }
    void FailEmission() {
#if '''+GUARD+'''
        iridiumFailed_ = true;
#endif
    }
    void ResetEmissionError() {
#if '''+GUARD+'''
        iridiumFailed_ = false;
#endif
    }
\tvoid SetCodePointer(const u8 *ptr, u8 *writePtr);''')
    elif name == 'Common/Arm64Emitter.cpp':
        # The separate MOV initialization correction is applied before this overlay.
        for signature, bits in [
            ('void ARM64XEmitter::EncodeCompareBranchInst(u32 op, ARM64Reg Rt, const void* ptr)\n{', 19),
            ('void ARM64XEmitter::EncodeTestBranchInst(u32 op, ARM64Reg Rt, u8 bits, const void* ptr)\n{', 14),
            ('void ARM64XEmitter::EncodeUnconditionalBranchInst(u32 op, const void* ptr)\n{', 26),
            ('void ARM64XEmitter::B(CCFlags cond, const void* ptr)\n{', 19),
        ]:
            text = replace(text, signature, signature + guarded(f'''
    uintptr_t target = (uintptr_t)ptr, current = (uintptr_t)m_code;
    uint64_t distanceBytes = target >= current ? target - current : current - target;
    if (EmissionFailed() || ((target | current) & 3) ||
        (target >= current ? distanceBytes >= (1ULL << {bits + 1}) : distanceBytes > (1ULL << {bits + 1}))) {{ FailEmission(); return; }}'''))
        text = replace(text, '\tptrdiff_t writable = m_writable - m_code;\n\t*(u32 *)(branch.ptr + writable) = inst;', '''#if '''+GUARD+'''
    void *rw = nullptr;
    if (EmissionFailed() || !ir_psp_exec_translate(branch.ptr, 4, true, &rw) ||
        !ir_psp_exec_write32(branch.ptr, rw, inst)) FailEmission();
#else
    uintptr_t offset = (uintptr_t)m_code - (uintptr_t)branch.ptr;
    *(u32 *)(m_writable - offset) = inst;
#endif''')
        text = replace(text, 'void ARM64XEmitter::SetJumpTarget(FixupBranch const& branch)\n{', '''void ARM64XEmitter::SetJumpTarget(FixupBranch const& branch)
{'''+guarded('''
    if (EmissionFailed() || branch.type > 6 || !ir_psp_exec_validate(branch.ptr, 4, false) ||
        !ir_psp_exec_validate(m_code, 0, false)) { FailEmission(); return; }
    int64_t displacement = (int64_t)(uintptr_t)m_code - (int64_t)(uintptr_t)branch.ptr;
    int bits = branch.type <= 2 ? 19 : branch.type <= 4 ? 14 : 26;
    if ((displacement & 3) || displacement / 4 < -(1LL << (bits - 1)) ||
        displacement / 4 >= (1LL << (bits - 1))) { FailEmission(); return; }'''))
        a=text.index('void ARM64CodeBlock::PoisonMemory(int offset) {')
        text=text[:a]+text[a:].replace('void ARM64CodeBlock::PoisonMemory(int offset) {', '''void ARM64CodeBlock::PoisonMemory(int offset) {'''+guarded('''
    if (offset < 0 || (size_t)offset > region_size) { FailEmission(); return; }
    void *rw = nullptr;
    if (!ir_psp_exec_translate(region + offset, region_size - offset, true, &rw)) { FailEmission(); return; }
    auto *words = (u32 *)rw;
    for (size_t n = 0; n < (region_size - offset) / 4; ++n) words[n] = 0xd4200000;
    return;'''),1)
        text = replace(text, 'void ARM64XEmitter::FlushIcacheSection(const u8 *start, const u8 *end)\n{', '''void ARM64XEmitter::FlushIcacheSection(const u8 *start, const u8 *end)
{'''+guarded('''
    if ((uintptr_t)end < (uintptr_t)start || EmissionFailed() ||
        !ir_psp_exec_publish(start, (uintptr_t)end - (uintptr_t)start)) FailEmission();
    return;'''))
        # Every alignment/reservation loop must terminate after a denied store.
        text = text.replace('while ((u64)m_code & 15)', 'while (!EmissionFailed() && ((u64)m_code & 15))')
        text = text.replace('while ((u64)m_code & (GetMemoryProtectPageSize() - 1))', 'while (!EmissionFailed() && ((u64)m_code & (GetMemoryProtectPageSize() - 1)))')
    elif name == 'Core/MIPS/ARM64/Arm64Jit.cpp':
        text = replace(text, 'AllocCodeSpace(1024 * 1024 * 16);', 'AllocCodeSpace(1024 * 1024 * 16, IR_PSP_EXEC_CPU);')
        text = replace(text, '\tGenerateFixedCode(jo);', guarded('    if (!GetBasePtr()) { ir_psp_exec_fail(); return; }')+'\tGenerateFixedCode(jo);', )
        text = replace(text, '\tBeginWrite(JitBlockCache::MAX_BLOCK_INSTRUCTIONS * 16);', '\tif (!BeginWrite(JitBlockCache::MAX_BLOCK_INSTRUCTIONS * 16)) { ir_psp_exec_fail(); Core_UpdateState(CORE_RUNTIME_ERROR); return; }')
        text = replace(text, '\tDoJit(em_address, b);', '\tDoJit(em_address, b);' + guarded('''
    if (!EndWrite() || EmissionFailed()) { ir_psp_exec_fail(); Core_UpdateState(CORE_RUNTIME_ERROR); return; }
    FlushIcache();
    if (EmissionFailed()) { ir_psp_exec_fail(); Core_UpdateState(CORE_RUNTIME_ERROR); return; }'''))
        text = replace(text, '\tEndWrite();\n\t_dbg_assert_(js.nextExit <= 2);', '#if !('+GUARD+')\n\tEndWrite();\n#endif\n\t_dbg_assert_(js.nextExit <= 2);')
        for signature, pointer, size in [('void Arm64Jit::LinkBlock(u8 *exitPoint, const u8 *checkedEntry) {','exitPoint',32), ('void Arm64Jit::UnlinkBlock(u8 *checkedEntry, u32 originalAddress) {','checkedEntry',16)]:
            text = replace(text, signature, signature + guarded(f'    IRPSPExecPatchScope patch({pointer}, {size});\n    if (!patch) {{ ir_psp_exec_fail(); Core_UpdateState(CORE_RUNTIME_ERROR); return; }}'))
        text = replace(text, '\tARM64XEmitter emit(GetCodePtrFromWritablePtr(exitPoint), exitPoint);', guarded('    if (!ir_psp_exec_validate(checkedEntry, 4, false)) { ir_psp_exec_fail(); return; }') + '\tconst u8 *translated = GetCodePtrFromWritablePtr(exitPoint);' + guarded('    if (!translated) { ir_psp_exec_fail(); Core_UpdateState(CORE_RUNTIME_ERROR); return; }') + '\tARM64XEmitter emit(translated, exitPoint);')
        text = replace(text, '\tARM64XEmitter emit(GetCodePtrFromWritablePtr(checkedEntry), checkedEntry);', guarded('    if (!ir_psp_exec_validate(MIPSComp::jit->GetDispatcher(), 4, false)) { ir_psp_exec_fail(); return; }') + '\tconst u8 *translated = GetCodePtrFromWritablePtr(checkedEntry);' + guarded('    if (!translated) { ir_psp_exec_fail(); Core_UpdateState(CORE_RUNTIME_ERROR); return; }') + '\tARM64XEmitter emit(translated, checkedEntry);')
        text = text.replace('\temit.FlushIcache();', '\temit.FlushIcache();' + guarded('    if (emit.EmissionFailed()) { ir_psp_exec_fail(); Core_UpdateState(CORE_RUNTIME_ERROR); }'))
    elif name == 'Core/MIPS/ARM64/Arm64Asm.cpp':
        text = replace(text, '\t\t\tB(dispatcherNoCheck); // no point in special casing this', '''#if '''+GUARD+'''
            MOVP2R(SCRATCH1_64, &coreState);
            LDR(INDEX_UNSIGNED, SCRATCH1, SCRATCH1_64, 0);
            CBZ(SCRATCH1, dispatcherNoCheck);
            FixupBranch postCompileFailure = B();
#else
            B(dispatcherNoCheck);
#endif''')
        text = replace(text, '\tconst uint8_t *quitLoop = GetCodePtr();', '\tconst uint8_t *quitLoop = GetCodePtr();' + guarded('    SetJumpTarget(postCompileFailure);'))
        text = replace(text, '\tBeginWrite(GetMemoryProtectPageSize());', '\tif (!BeginWrite(GetMemoryProtectPageSize())) { ir_psp_exec_fail(); return; }')
        text = replace(text, '\tEndWrite();', '\tif (!EndWrite() || EmissionFailed()) ir_psp_exec_fail();')
    elif name == 'Core/MIPS/ARM64/Arm64IRJit.cpp':
        text = '#include "Core/Core.h"\n' + text
        text = replace(text, 'AllocCodeSpace(1024 * 1024 * 16);', 'AllocCodeSpace(1024 * 1024 * 16, IR_PSP_EXEC_CPU);')
        for pointer in ('profilerPC', 'profilerStatus'):
            old = f'int offset = (int)((const u8 *)hooks_.{pointer} - GetBasePtr());\n\t\tMOVI2R(SCRATCH2, MIPS_EMUHACK_OPCODE + offset);'
            new = f'''if (!ir_psp_exec_validate(hooks_.{pointer}, 4, true)) {{ FailEmission(); return; }}
        MOVP2R(SCRATCH2_64, hooks_.{pointer});'''
            expected = 2 if pointer == 'profilerPC' else 1
            if text.count(old) != expected: raise ValueError('Profiler address hook changed')
            text = text.replace(old, new)
        text = text.replace('STR(SCRATCH1, JITBASEREG, SCRATCH2);', 'STR(INDEX_UNSIGNED, SCRATCH1, SCRATCH2_64, 0);')
        text = replace(text, 'STR(r, JITBASEREG, SCRATCH2);', 'STR(INDEX_UNSIGNED, r, SCRATCH2_64, 0);')
        text = replace(text, 'void Arm64JitBackend::WriteDebugPC(ARM64Reg r) {', 'void Arm64JitBackend::WriteDebugPC(ARM64Reg r) {\n    if (hooks_.profilerPC && (r == SCRATCH2 || r == SCRATCH2_64)) { FailEmission(); return; }')
        text = replace(text, 'Arm64JitBackend::~Arm64JitBackend() {}', 'Arm64JitBackend::~Arm64JitBackend() { QuiesceProfiler(); }')
        text = replace(text, '\tBeginWrite(std::min(GetSpaceLeft(), (size_t)block->GetNumIRInstructions() * 32));', '\tif (!BeginWrite(std::min(GetSpaceLeft(), (size_t)block->GetNumIRInstructions() * 32))) { ir_psp_exec_fail(); return false; }')
        text = replace(text, 'void Arm64JitBackend::OverwriteExit(int srcOffset, int len, int block_num) {', '''void Arm64JitBackend::OverwriteExit(int srcOffset, int len, int block_num) {''' + guarded('''
    if (srcOffset < 0 || len < MIN_BLOCK_EXIT_LEN || (size_t)srcOffset > region_size || (size_t)len > region_size - srcOffset) { ir_psp_exec_fail(); return; }
    IRPSPExecPatchScope patch(GetBasePtr() + srcOffset, len);
    if (!patch) { ir_psp_exec_fail(); return; }'''))
        text = replace(text, '\tint offset = block->GetNativeOffset();', '\tint offset = block->GetNativeOffset();' + guarded('''
    if (offset < 0 || (size_t)offset > region_size || MIN_BLOCK_NORMAL_LEN > region_size - offset) { ir_psp_exec_fail(); return; }
    IRPSPExecPatchScope patch(GetBasePtr() + offset, MIN_BLOCK_NORMAL_LEN);
    if (!patch) { ir_psp_exec_fail(); return; }'''))
        text = text.replace('\t\temitter.FlushIcache();', '\t\temitter.FlushIcache();' + guarded('    if (emitter.EmissionFailed()) { ir_psp_exec_fail(); return; }'))
        text = replace(text, 'region + region_size - jitStartOffset_', 'region + region_size')
        for signature in ('void Arm64JitBackend::WriteDebugPC(uint32_t pc) {', 'void Arm64JitBackend::WriteDebugPC(ARM64Reg r) {', 'void Arm64JitBackend::WriteDebugProfilerStatus(IRProfilerStatus status) {'):
            text = replace(text, signature, signature + guarded('''
    if (DebugProfilerEnabled() && (!hooks_.profilerPC || !hooks_.profilerStatus ||
        ((uintptr_t)hooks_.profilerPC & 3) || ((uintptr_t)hooks_.profilerStatus & 3))) { FailEmission(); return; }'''))
        text = replace(text, '\tEndWrite();\n\tFlushIcache();\n\tcompilingBlockNum_ = -1;', '''    bool published = EndWrite();
    FlushIcache();
    compilingBlockNum_ = -1;
    if (!published || EmissionFailed()) { ir_psp_exec_fail(); Core_UpdateState(CORE_RUNTIME_ERROR); return false; }''')
        text = replace(text, '\t\t\tcompilingBlockNum_ = -1;\n\t\t\treturn false;', '\t\t\tcompilingBlockNum_ = -1;\n            if (!EndWrite() || EmissionFailed()) ir_psp_exec_fail();\n\t\t\treturn false;')
        for indent, offset in [('\t\t', 'srcOffset'), ('\t', 'offset')]:
            old = indent + 'u8 *writable = GetWritablePtrFromCodePtr(GetBasePtr()) + ' + offset + ';'
            new = indent + 'u8 *writable = GetWritablePtrFromCodePtr(GetBasePtr());' + guarded('    if (!writable) { ir_psp_exec_fail(); return; }') + indent + 'writable += ' + offset + ';'
            text = replace(text, old, new)
        text = replace(text, '\t\tu8 *writable = GetWritablePtrFromCodePtr(GetBasePtr());', guarded('    if (nativeBlock->checkedOffset < 0 || (size_t)nativeBlock->checkedOffset >= region_size) { ir_psp_exec_fail(); return; }') + '\t\tu8 *writable = GetWritablePtrFromCodePtr(GetBasePtr());')
        text = replace(text, '\tu32 pc = block->GetOriginalStart();', guarded('    if (!ir_psp_exec_validate(dispatcherPCInSCRATCH1_, 4, false)) { ir_psp_exec_fail(); return; }') + '\tu32 pc = block->GetOriginalStart();')
    elif name == 'Core/MIPS/ARM64/Arm64IRAsm.cpp':
        text = replace(text, '\t\t\tB(dispatcherNoCheck_);', '''#if '''+GUARD+'''
            MOVP2R(SCRATCH1_64, &coreState);
            LDR(INDEX_UNSIGNED, SCRATCH1, SCRATCH1_64, 0);
            CBZ(SCRATCH1, dispatcherNoCheck_);
            FixupBranch postCompileFailure = B();
#else
            B(dispatcherNoCheck_);
#endif''')
        text = replace(text, '\tconst uint8_t *quitLoop = GetCodePtr();', '\tconst uint8_t *quitLoop = GetCodePtr();' + guarded('    SetJumpTarget(postCompileFailure);'))
        text = replace(text, 'void Arm64JitBackend::GenerateFixedCode(MIPSState *mipsState) {', '''void Arm64JitBackend::GenerateFixedCode(MIPSState *mipsState) {'''+guarded('''
    hooks_.profilerPC = nullptr; hooks_.profilerStatus = nullptr;
    if (!GetBasePtr()) { ir_psp_exec_fail(); return; }'''))
        text = replace(text, '\tconst u8 *start = AlignCodePage();', '\tif (!BeginWrite(GetMemoryProtectPageSize())) { ir_psp_exec_fail(); return; }\n\tconst u8 *start = AlignCodePage();')
        text = replace(text, '\t\tProtectMemoryPages(start, GetMemoryProtectPageSize(), MEM_PROT_READ | MEM_PROT_WRITE);', '\t\t(void)start; // Scratch is initialized in the checked append scope.')
        text = replace(text, '\t\thooks_.profilerStatus = (IRProfilerStatus *)GetWritableCodePtr();\n\t\tWrite32(0);', '''\t\thooks_.profilerStatus = (IRProfilerStatus *)GetWritableCodePtr();
        Write32(0);
''')
        text = replace(text, '\tconst u8 *disasmStart = AlignCodePage();\n\tBeginWrite(GetMemoryProtectPageSize());', '''    if (!EndWrite() || EmissionFailed()) { hooks_.profilerPC = nullptr; hooks_.profilerStatus = nullptr; ir_psp_exec_fail(); return; }
    if (!BeginWrite(GetMemoryProtectPageSize())) { ir_psp_exec_fail(); return; }
    const u8 *disasmStart = AlignCodePage();''')
        text = replace(text, '\tEndWrite();\n\n\t// Update our current', '\tif (!EndWrite() || EmissionFailed()) { ir_psp_exec_fail(); return; }\n\n\t// Update our current')
    elif name == 'Core/MIPS/IR/IRJit.cpp':
        text = replace(text, 'void IRJit::Compile(u32 em_address) {', 'void IRJit::Compile(u32 em_address) {' + guarded('    if (ir_psp_exec_failed()) { Core_UpdateState(CORE_RUNTIME_ERROR); return; }'))
        text = replace(text, '\tif (!CompileBlock(em_address, instructions, mipsBytes)) {', '\tif (!CompileBlock(em_address, instructions, mipsBytes)) {' + guarded('    if (ir_psp_exec_failed()) { Core_UpdateState(CORE_RUNTIME_ERROR); return; }'))
        text = replace(text, '\tif (frontend_.CheckRounding(em_address)) {', guarded('    if (ir_psp_exec_failed()) { Core_UpdateState(CORE_RUNTIME_ERROR); return; }') + '\tif (frontend_.CheckRounding(em_address)) {')
    elif name == 'Core/MIPS/IR/IRNativeCommon.cpp':
        text = replace(text, 'IRNativeBackend::~IRNativeBackend() {', 'IRNativeBackend::~IRNativeBackend() { QuiesceProfiler(); }\n\nvoid IRNativeBackend::QuiesceProfiler() {')
        text = replace(text, '\tbackend_->GenerateFixedCode(mips_);', '\tbackend_->GenerateFixedCode(mips_);' + guarded('    if (ir_psp_exec_failed()) return;'))
        text = replace(text, '\t\tdebugProfilerThread = std::thread([&] {', '\t\tdebugProfilerThread = std::thread([&] {' + guarded('    IRPSPExecReadScope reader((const void *)hooks_.profilerPC);\n    if (!reader) { ir_psp_exec_fail(); return; }'))
    elif name == 'Core/MIPS/IR/IRNativeCommon.h':
        text = replace(text, '\tvirtual ~IRNativeBackend();', '\tvirtual ~IRNativeBackend();\n    void QuiesceProfiler();')
    elif name == 'GPU/Common/VertexDecoderCommon.cpp':
        text = replace(text, 'AllocCodeSpace(1024 * 64 * 4);', 'AllocCodeSpace(1024 * 64 * 4, IR_PSP_EXEC_VERTEX);')
        text = replace(text, '\tif (jitted_ && !validateJit) {', guarded('''
    bool nativeDecoder = jitted_ == &VtxDec_Tu8_C5551_Ps16 || jitted_ == &VtxDec_Tu16_C8888_Pfloat;
    IRPSPExecReadScope reader(nativeDecoder ? nullptr : (const void *)jitted_);''') + '''\tif (jitted_ && !validateJit
#if '''+GUARD+'''
        && (nativeDecoder || reader)
#endif
    ) {''')
        text = replace(text, '\tjitted_(startPtr, &jittedBuffer[0], count, uvScaleOffset);', guarded('    IRPSPExecReadScope reader((const void *)jitted_);\n    if (!reader) return;') + '\tjitted_(startPtr, &jittedBuffer[0], count, uvScaleOffset);')
    elif name == 'GPU/Common/VertexDecoderArm64.cpp':
        text = replace(text, '\tBeginWrite(4096);\n\tconst u8 *start = AlignCode16();', '''    *jittedSize = 0;
    size_t checkpoint = GetCodePtr() && GetBasePtr() ? GetOffset(GetCodePtr()) : 0;
    if (!BeginWrite(4096)) { dec_ = nullptr; return nullptr; }
    const u8 *start = AlignCode16();''')
        text = replace(text, '\t*jittedSize = (int)(GetCodePtr() - start);\n\tEndWrite();', '''    if (!EndWrite() || EmissionFailed()) {
        ResetCodePtr(checkpoint); dec_ = nullptr; return nullptr;
    }
    *jittedSize = (int)(GetCodePtr() - start);''')
        text = replace(text, '\t\t\tResetCodePtr(GetOffset(start));', '\t\t\tResetCodePtr(checkpoint);\n            dec_ = nullptr;')
    elif name == 'GPU/Common/DrawEngineCommon.cpp':
        text = replace(text, '''void DrawEngineCommon::NotifyConfigChanged() {
\tif (decJitCache_)
\t\tdecJitCache_->Clear();''', 'void DrawEngineCommon::NotifyConfigChanged() {')
        text = replace(text, '\tdecoderMap_.Clear();', '\tdecoderMap_.Clear();\n    if (decJitCache_) decJitCache_->Clear(); // Drop old callable owners before clearing their bytes.')
    elif name == 'GPU/Software/RasterizerRegCache.cpp':
        text = replace(text, 'CodeBlock::CodeBlock(int size)', 'CodeBlock::CodeBlock(int size, unsigned role)')
        text = replace(text, '\tAllocCodeSpace(size);', '\tAllocCodeSpace(size, role);')
    elif name == 'GPU/Software/RasterizerRegCache.h':
        text = replace(text, 'CodeBlock(int size);', 'CodeBlock(int size, unsigned role = 0);')
    elif name == 'GPU/Software/DrawPixel.cpp':
        text = replace(text, 'CodeBlock(1024 * 64 * 4)', 'CodeBlock(1024 * 64 * 4, IR_PSP_EXEC_PIXEL)')
        text = replace(text, 'void Init() {', 'void Init() {' + guarded('    if (jitCache) { ir_psp_exec_fail(); return; }'))
    elif name == 'GPU/Software/Sampler.cpp':
        text = replace(text, 'Rasterizer::CodeBlock(1024 * 64 * 4)', 'Rasterizer::CodeBlock(1024 * 64 * 4, IR_PSP_EXEC_SAMPLER)')
        text = replace(text, 'void Init() {', 'void Init() {' + guarded('    if (jitCache) { ir_psp_exec_fail(); return; }'))
    elif name == 'GPU/GPU.cpp':
        text = replace(text, 'bool GPU_Init(GPUCore gpuCore, GraphicsContext *ctx, Draw::DrawContext *draw) {',
                       'bool GPU_Init(GPUCore gpuCore, GraphicsContext *ctx, Draw::DrawContext *draw) {' + guarded('    if (gpu) { ir_psp_exec_fail(); return false; }'))
    elif name == 'Core/MIPS/JitCommon/JitCommon.cpp':
        text = '#include \"Core/Core.h\"\n' + text
        text = replace(text, '\t\tjit->Compile(currentMIPS->pc);', guarded('    if (ir_psp_exec_failed()) { Core_UpdateState(CORE_RUNTIME_ERROR); return; }') + '\t\tjit->Compile(currentMIPS->pc);' + guarded('    if (ir_psp_exec_failed()) Core_UpdateState(CORE_RUNTIME_ERROR);'))
        old = '\t\tif (useIR)\n\t\t\treturn new MIPSComp::Arm64IRJit(mipsState);\n\t\telse\n\t\t\treturn new MIPSComp::Arm64Jit(mipsState);'
        new = '\t\tJitInterface *candidate = useIR ? (JitInterface *)new MIPSComp::Arm64IRJit(mipsState) : new MIPSComp::Arm64Jit(mipsState);' + guarded('    if (ir_psp_exec_failed()) { delete candidate; return nullptr; }') + '        return candidate;'
        text = replace(text, old, new)
    elif name == 'Core/System.cpp':
        text = replace(text, '\tmipsr4k.Reset();', '\tmipsr4k.Reset();' + guarded('    if (ir_psp_exec_failed()) { *errorString = "PSP executable memory initialization failed."; return false; }'))
    elif name == 'Core/MIPS/MIPS.cpp':
        text = replace(text, 'int MIPSState::RunLoopUntil(u64 globalTicks) {', 'int MIPSState::RunLoopUntil(u64 globalTicks) {' + guarded('''
    bool nativeJit = PSP_CoreParameter().cpuCore == CPUCore::JIT || PSP_CoreParameter().cpuCore == CPUCore::JIT_IR;
    IRPSPExecReadScope reader(nativeJit ? IR_PSP_EXEC_CPU : 0u);
    if (nativeJit && (!reader || !MIPSComp::jit || ir_psp_exec_failed())) { Core_UpdateState(CORE_RUNTIME_ERROR); return 1; }'''))
    elif name == 'Common/MemoryUtil.cpp':
        signature = 'void *AllocateExecutableMemory(size_t size) {'
        if text.count(signature) != 2: raise ValueError('Executable allocation hooks changed')
        text = text.replace(signature, signature + guarded('    (void)size; return nullptr; // Prepared CodeBlock claims are the only PSP executable allocator.'))
        text = replace(text, 'void FreeExecutableMemory(void *ptr, size_t size) {',
                       'void FreeExecutableMemory(void *ptr, size_t size) {' + guarded('    (void)ptr; (void)size; ir_psp_exec_fail(); return; // Only the opaque claim may release owned views.'))
        text = replace(text, 'bool ProtectMemoryPages(const void* ptr, size_t size, uint32_t memProtFlags) {',
                       'bool ProtectMemoryPages(const void* ptr, size_t size, uint32_t memProtFlags) {' + guarded('''
    void *rx = nullptr;
    if (ir_psp_exec_translate(ptr, size, false, &rx)) {
        return !(memProtFlags & MEM_PROT_EXEC) || ir_psp_exec_publish(rx, size);
    }
    if (ir_psp_exec_validate(ptr, size, false)) {
        return !(memProtFlags & MEM_PROT_EXEC) || ir_psp_exec_publish(ptr, size);
    }
    if (memProtFlags & MEM_PROT_EXEC) return false;'''))
    return text
