.text
.balign 16

// iOS clobbers x18 on context switches. Read TEB from TPIDRRO_EL0 + the raw
// pthread TSD slot that wine's ntdll-unix publishes the TEB in, instead of
// trusting x18 directly. TPIDRRO_EL0 IS preserved by iOS across context
// switches, and AND #~7 + ldr is the canonical pthread TLS pattern.
//
// The #0x898 below is a PLACEHOLDER, not the slot. The real slot is whichever
// one backs ntdll-unix's TEB pthread key in this process, which is not knowable
// at assembly time and differs per device and per load order. Wine's x18
// binary patcher recognises this exact three-instruction triplet and rewrites
// the immediate through the .text RW alias, before this code is ever executed
// (see the "retarget hand-written TEB-from-TSD reads" pass in virtual_ios.c).
//
// Do NOT "correct" this constant, and do NOT break the triplet apart or
// reorder it -- the patcher matches all three instructions with matching
// registers, and an unmatched sequence silently keeps reading the wrong slot.
// The JIT emitters read the same offset at runtime via IosTebTsdOffset.
#ifdef FEX_IOS_HOST
.macro IOS_LOAD_TEB reg
  mrs \reg, TPIDRRO_EL0
  and \reg, \reg, #~7
  ldr \reg, [\reg, #0x898]
.endm
#endif

  // __os_arm64x_x64_jump in ARM64EC docs
  // Expects target code address in x9
.globl DispatchJump
DispatchJump:
  str lr, [sp, #-8]! // Push return address to stack, this will be popped by the x86 RET instr.
  b check_target_ec

  // __os_arm64x_dispatch_ret in ARM64EC docs
  // Expects target code address in lr
.globl RetToEntryThunk
RetToEntryThunk:
  mov x9, lr

check_target_ec:
  // Check if target is in fact x86 code
#ifdef FEX_IOS_HOST
  IOS_LOAD_TEB x16
  ldr x16, [x16, #0x60] // TEB->PEB
#else
  ldr x16, [x18, #0x60] // TEB->PEB
#endif
  ldr x16, [x16, #0x368] // PEB->EcCodeBitMap
  lsr x17, x9, #18
  ldr x16, [x16, x17, lsl #3]
  lsr x17, x9, #12
  lsr x16, x16, x17
  tbnz x16, #0, ExitFunctionEC
  b enter_jit

  // __os_arm64x_dispatch_call_no_redirect in ARM64EC docs
  // Expects target code address in x9, and to be called using a 'blr x16' instruction.
.globl ExitToX64
ExitToX64:
#ifdef FEX_IOS_HOST
  // iOS ml316 FFS BYPASS (root cause of the ml315 SCM-RPC ccontext=0x10 kill).
  //
  // When wine's __os_arm64x_check_call cannot classify a target (task #40: the x18 fix
  // that would let it is A/B-proven to break CEF), a native EC caller's call to an EC
  // function gets routed through clang's $iexit_thunk$cdecl$...$varargs with x9 = the
  // target's x64 fast-forward sequence. That thunk builds NO x64 frame -- it just does
  // `stp x4, x5, [sp, #0x20]` and calls here. After our `str lr, [sp,#-8]!` the guest
  // frame reads [RSP+0x28]=saved x4, [RSP+0x30]=saved x5 -- so when the FFS jmp lands
  // back in EC code and the varargs ENTRY thunk hands those to the callee as its stack
  // arguments, a variadic EC callee receives (x4, x5) VERBATIM instead of the real
  // args. ml315 measured exactly that: NdrClientCall2's param2 = the caller's
  // stack-args pointer, param3 = 0x10 = x5 the size -- which became the "context
  // handle" the SCM RPC then dereferenced.
  //
  // Real Windows never takes this round trip: check_call pattern-matches the FFS and
  // returns the underlying EC target for a direct native call. Do that here instead --
  // the one transition point we fully control. If x9 is the canonical 14-byte FFS
  //   48 8b c4  mov rax, rsp
  //   48 89 58 20  mov [rax+0x20], rbx
  //   55 5d     push rbp; pop rbp
  //   e9 rel32  jmp target
  // (byte-identical in every wine-built EC DLL: rpcrt4/sechost dumps verified) and the
  // jmp target is EC code per the bitmap, branch to it natively. x4/x5 flow through
  // untouched and the exit thunk becomes a transparent pass-through; the EC callee
  // rets to lr = the exit thunk's continuation. Non-FFS or non-EC targets fall
  // through to normal emulation with every register intact.
  //
  // Scratch: x16/x17 (IP0/IP1, dead at any call boundary) + x23 -- safe for the same
  // reason ExitFunctionEC already clobbers it: EnterEC rebuilds the RSP SRA register
  // from the native sp on every JIT entry. The `br` targets the PE VA; the Mach
  // exec-fault redirect translates it to the pool copy (proven ~33us path, and this
  // is RPC-call frequency, not per-frame).
  ldr x16, [x9]
  movz x17, #0x8b48
  movk x17, #0x48c4, lsl #16
  movk x17, #0x5889, lsl #32
  movk x17, #0x5520, lsl #48
  cmp x16, x17
  b.ne ios_ffs_no_bypass
  ldrh w16, [x9, #8]
  movz w17, #0xe95d
  cmp w16, w17
  b.ne ios_ffs_no_bypass
  ldursw x16, [x9, #10]  // jmp rel32 (signed)
  add x17, x9, x16
  add x17, x17, #14      // raw target = FFS base + 14 + rel32
  // ml316b: x9 (and thus the raw target) is usually the POOL-COPY alias -- wine
  // installs pool aliases into the dispatch slots and IATs so native code can
  // call them, and the copy is byte-identical so the pattern still matches.
  // The EC bitmap only covers PE-space VAs (the #52 lesson all over again), so
  // reverse-translate the target through IosAliasEntries BEFORE consulting it.
  // x4/x9 are spilled to free loop registers; restored on every exit path.
  // (Native EC callers keep sp 16-aligned at call boundaries per AAPCS.)
  stp x4, x9, [sp, #-16]!
  adrp x16, IosAliasEntries
  add x16, x16, #:lo12:IosAliasEntries
  adrp x9, IosAliasCount
  ldr w9, [x9, #:lo12:IosAliasCount]
ios_ffs_xlate_loop:
  cbz w9, ios_ffs_xlate_done
  ldr x4, [x16, #8]      // Entry.JitBase
  sub x4, x17, x4
  ldr x23, [x16, #16]    // Entry.Size
  cmp x4, x23
  b.lo ios_ffs_xlate_hit
  add x16, x16, #32
  sub w9, w9, #1
  b ios_ffs_xlate_loop
ios_ffs_xlate_hit:
  ldr x23, [x16]         // Entry.PeBase
  add x17, x23, x4       // target in PE space
ios_ffs_xlate_done:
  IOS_LOAD_TEB x16
  ldr x16, [x16, #0x60]  // TEB->PEB
  ldr x16, [x16, #0x368] // PEB->EcCodeBitMap
  cbz x16, ios_ffs_reject
  lsr x23, x17, #18
  ldr x16, [x16, x23, lsl #3]
  lsr x23, x17, #12
  lsr x16, x16, x23
  tbz x16, #0, ios_ffs_reject
  ldp x4, x9, [sp], #16
  adrp x16, IosFfsBypassLog
  add x16, x16, #:lo12:IosFfsBypassLog
  ldr x23, [x16]
  add x23, x23, #1
  str x23, [x16]         // [0] = bypass count (diagnostic, read by Core.cpp reporter)
  str x17, [x16, #8]     // [1] = last EC target taken natively
  br x17                 // PE VA; the Mach exec-fault redirect maps it to the pool copy
ios_ffs_reject:
  // Pattern matched but the (PE-space) target is not EC per the bitmap: fall
  // through to normal emulation -- correct for genuine x64 jmp targets -- but
  // COUNT it, so a run with zero bypasses is distinguishable from one where the
  // probe never fired at all (ml316's silent miss must not repeat).
  ldp x4, x9, [sp], #16
  adrp x16, IosFfsBypassLog
  add x16, x16, #:lo12:IosFfsBypassLog
  ldr x23, [x16, #16]
  add x23, x23, #1
  str x23, [x16, #16]    // [2] = matched-but-rejected count
  str x17, [x16, #24]    // [3] = last rejected (PE-space) target
ios_ffs_no_bypass:
#endif
  str lr, [sp, #-8]! // Push return address to stack, this will be popped by the x86 RET instr.

enter_jit:
#ifdef FEX_IOS_HOST
  IOS_LOAD_TEB x17
  ldr x17, [x17, #0x1788] // TEB->ChpeV2CpuAreaInfo
#else
  ldr x17, [x18, #0x1788] // TEB->ChpeV2CpuAreaInfo
#endif
  mov w16, #1
  strb w16, [x17, #0x0] // ChpeV2CpuAreaInfo->InSimulation
#ifdef FEX_IOS_HOST
  // ml460 (#75) Dekker handshake vs the pool-tail sweeper: InSimulation=1 is
  // published above; the full barrier orders it before the gate read, so
  // either the sweeper sees us in-simulation (and skips this thread) or we
  // see the gate (and wait out the sweep before touching L1/callret state).
  dmb ish
8:
  adrp x16, IosCodeBufferSweepGate
  add x16, x16, #:lo12:IosCodeBufferSweepGate
  ldar x16, [x16]
  cbz x16, 9f
  yield
  b 8b
9:
#endif
  ldr x16, [x17, #0x40] // ChpeV2CpuAreaInfo->EmulatorData[2] - DispatcherLoopTopEnterEC
  br x16 // DispatcherLoopTopEnterEC(RIP:x9, CPUArea:x17)

  // Invoked by KiUserEmulationDispatcher after e.g. an NtContinue to x86 code
.global BeginSimulation
BeginSimulation:
#ifdef FEX_IOS_HOST
  IOS_LOAD_TEB x17
  ldr x17, [x17, #0x1788] // TEB->ChpeV2CpuAreaInfo
  // ml460 (#75): this funnel re-enters the JIT after NtContinue (syscall
  // resumes, guest SEH returns, suspend resumes) and could otherwise run
  // emitted code with a stale InSimulation=0 — invisible to the sweeper.
  // Publish InSimulation BEFORE SyncThreadContext (the sweeper touches
  // State.callret_sp) and wait out any active sweep.
  mov w16, #1
  strb w16, [x17, #0x0] // ChpeV2CpuAreaInfo->InSimulation
  dmb ish
6:
  adrp x16, IosCodeBufferSweepGate
  add x16, x16, #:lo12:IosCodeBufferSweepGate
  ldar x16, [x16]
  cbz x16, 7f
  yield
  b 6b
7:
#else
  ldr x17, [x18, #0x1788] // TEB->ChpeV2CpuAreaInfo
#endif
  ldr x16, [x17, #0x8] // ChpeV2CpuAreaInfo->EmulatorStackBase
  mov sp, x16
  ldr x0, [x17, #0x18] // ChpeV2CpuAreaInfo->ContextAmd64
#ifdef FEX_IOS_HOST
  // llvm-mingw arm64ec emits extern "C" funcs as plain (unprefixed) symbols.
  bl SyncThreadContext
#else
  bl "#SyncThreadContext"
#endif
#ifdef FEX_IOS_HOST
  IOS_LOAD_TEB x17
  ldr x17, [x17, #0x1788] // TEB->ChpeV2CpuAreaInfo
#else
  ldr x17, [x18, #0x1788] // TEB->ChpeV2CpuAreaInfo
#endif
  ldr x16, [x17, #0x48] // ChpeV2CpuAreaInfo->EmulatorData[3] - DispatcherLoopTopEnterECFillSRA
  mov x11, #0 // Zero ENTRY_FILL_SRA_SINGLE_INST_REG to avoid single step
  br x16 // DispatcherLoopTopEnterECFillSRA(SingleInst:x10, CPUArea:x17)

  // Called into by FEXCore
  // Expects the target code address in x9
.global ExitFunctionEC
ExitFunctionEC:
  // Clear any the AFP NEP and AH bits in FPCR as native code won't expect their behaviour.
  mrs x17, fpcr
  and x17, x17, #~6 // NEP + AH
  msr fpcr, x17
#ifdef FEX_IOS_HOST
  IOS_LOAD_TEB x17
  ldr x17, [x17, #0x1788] // TEB->ChpeV2CpuAreaInfo
#else
  ldr x17, [x18, #0x1788] // TEB->ChpeV2CpuAreaInfo
#endif
  strb wzr, [x17, #0x0] // ChpeV2CpuAreaInfo->InSimulation
  ldr x17, [x17, #0x20] // ChpeV2CpuAreaInfo->SuspendDoorbell
  ldr w17, [x17]
  cbnz w17, ExitFunctionSuspendPoint

.global ExitFunctionSuspendResumePoint
ExitFunctionSuspendResumePoint:
#ifdef FEX_IOS_HOST
  // iOS: PE images can't execute at their mapped address (no mprotect(RX) on
  // file-backed mmaps); the only runnable copy lives in the dual-mapped JIT
  // pool. Translate the target through the alias table (IosJitAlias.cpp)
  // before branching — otherwise every x64→EC call lands on the PE VA and
  // costs a Mach exec-fault redirect (~33us each, measured ~40K/frame in
  // Thumper's menu = the entire frame budget).
  // x16/x17/x23 are already clobbered on all downstream paths; x4 maps to
  // x64 R10 (volatile at this call/ret boundary) and is clobbered by the
  // entry-thunk path below. NZCV is clobbered by the cmp at check_thunk
  // regardless.
  adrp x16, IosAliasEntries
  add x16, x16, #:lo12:IosAliasEntries
  adrp x17, IosAliasCount
  ldr w17, [x17, #:lo12:IosAliasCount]
ios_ec_xlate_loop:
  cbz w17, ios_ec_xlate_done
  ldr x23, [x16]        // Entry.PeBase
  sub x23, x9, x23      // offset into image (unsigned-wraps huge if below base)
  ldr x4, [x16, #16]    // Entry.Size
  cmp x23, x4
  b.lo ios_ec_xlate_hit
  add x16, x16, #32
  sub w17, w17, #1
  b ios_ec_xlate_loop
ios_ec_xlate_hit:
  ldr x4, [x16, #8]     // Entry.JitBase
  add x9, x4, x23
ios_ec_xlate_done:
#endif
  // Either return to an exit thunk (return to ARM64EC function) or call an entry thunk (call to ARM64EC function).
  // It is assumed that a 'blr x16' instruction is only ever used to call into x86 code from an exit thunk, and that all
  // exported ARM64EC functions have a 4-byte offset to their entry thunk immediately before their first instruction.
  mov x17, x9
  mov w16, #0x200
  movk w16, #0xd63f, lsl 16 // blr x16
  ldursw x23, [x17, #-0x4] // Load either the entry thunk offset or the calling instruction.
  cmp w23, w16
  beq ret_sp_aligned

  and x23, x23, #-0x4
  add x17, x17, x23 // Resolve entry thunk address.

  mov x4, sp
  tbz x4, #3, ret_sp_misaligned
  ldr lr, [x4], #0x8 // Pop the return address into lr.
  mov sp, x4

ret_sp_aligned:
  br x17

ret_sp_misaligned:
  // In the case of the x64 caller leaving sp only 8-byte aligned, leave the return address on the stack to keep 16-byte
  // alignment and have the callee return to an x86 ret instruction. FEX can then return to the actual caller keeping
  // the misaligned RSP.
  //
  // ml218: x4 must still point PAST the return address. On the path above the address is
  // popped (`ldr lr, [x4], #0x8`), leaving x4 = RSP+8 -- the base of the x64 home space,
  // which a variadic entry thunk then advances by 0x20 to reach the first stack argument:
  //   $ientry_thunk$cdecl$i8$varargs:  add x4, x4, #0x20
  // Here the address is deliberately LEFT on the stack, so x4 = RSP is one slot short and
  // every stack argument is read 8 bytes early. Measured directly in a Steam RPC call:
  //   [ndr-shift] param3 off=0x18 StackTop=0x703CD5EBF0 HERE=0x10 next=0x703CD5EC88
  //               => SHIFT: real pointer is ONE SLOT LATER (+8)
  // which is how ccontext arrived as 0x10 and faulted in #NdrContextHandleUnmarshall+0xcc.
  // Only variadic callees are affected -- non-variadic entry thunks never read x4 -- which
  // is why this stayed hidden outside RPC. sp is intentionally left untouched.
  add x4, x4, #0x8
  adrp lr, X64ReturnInstr
  ldr lr, [lr, #:lo12:X64ReturnInstr]
  br x17

.global ExitFunctionSuspendPoint
ExitFunctionSuspendPoint:
  brk #0xCAFE
  // Resume will jump back to `ExitFunctionSuspendResumePoint`

  // Makes a wrapper for calling a system call directly, skipping the usual ntdll thunks
#define HASH #
#define DIRECT_SYSCALL_WRAPPER(Name, WineIdName, WindowsId) \
  .global Name; \
  Name:; \
    adrp x16, WineSyscallDispatcher; \
    ldr x16, [x16, HASH:lo12:WineSyscallDispatcher]; \
    cbz x16, 1f; \
    mov x9, x30; \
    adrp x8, WineIdName; \
    ldr x8, [x8, HASH:lo12:WineIdName]; \
    blr x16; \
    ret; \
  1:; \
    svc HASH WindowsId; \
    ret

  // Allows for continuing from a full native context, as the NTDLL NtContinue export takes in an x64 context with EC and
  // the conversion to that loses the ARM64EC ABI-disallowed registers that FEX uses.
#ifdef FEX_IOS_HOST
// llvm-mingw arm64ec emits unprefixed references from C code (`NtContinueNative`)
// but the macro defines `#NtContinueNative` only. Add unprefixed aliases pointing
// to the same code so the link resolves cleanly without linker-synthesized thunks.
.global NtContinueNative
NtContinueNative:
#endif
DIRECT_SYSCALL_WRAPPER("#NtContinueNative", WineNtContinueSyscallId, 0x43)

  // Both of these are wrapped as FEX needs them to setup its call checker at startup time and their NTDLL thunks could
  // already be patched by then (and because the call checker isn't installed, their patched x86 versions would be invoked
  // when called by FEX).
#ifdef FEX_IOS_HOST
.global NtAllocateVirtualMemoryNative
NtAllocateVirtualMemoryNative:
#endif
DIRECT_SYSCALL_WRAPPER("#NtAllocateVirtualMemoryNative", WineNtAllocateVirtualMemorySyscallId, 0x18)
#ifdef FEX_IOS_HOST
.global NtProtectVirtualMemoryNative
NtProtectVirtualMemoryNative:
#endif
DIRECT_SYSCALL_WRAPPER("#NtProtectVirtualMemoryNative", WineNtProtectVirtualMemorySyscallId, 0x50)

  // A replacement for the standard ARM64EC call checker that ignores any FFS patches and always redirects to a function's
  // native implementation. As the only library FEX calls into is NTDLL, this is done using a LUT generated at init time.
  // Expects the FFS address in x11, exit thunk address in x10 (unused) and it's own address in x9. Return address is in x11.
.global "CheckCall"
"CheckCall":
  adrp x9, NtDllBase
  ldr x9, [x9, #:lo12:NtDllBase]
  subs x16, x11, x9
  b.lo end
  adrp x17, NtDllRedirectionLUTSize
  ldr x17, [x17, #:lo12:NtDllRedirectionLUTSize]
  cmp x16, x17
  b.hi end
  adrp x17, NtDllRedirectionLUT
  ldr x17, [x17, #:lo12:NtDllRedirectionLUT]
  ldr w11, [x17, x16, lsl #2]
  add x11, x11, x9
end:
  ret

  // Expects target address in x0, and the SP to set in x1
#ifdef FEX_IOS_HOST
.global JumpSetStack
JumpSetStack:
#endif
.global "#JumpSetStack"
"#JumpSetStack":
  mov sp, x1
  br x0
