// SPDX-License-Identifier: MIT
/*
$info$
tags: backend|arm64
$end_info$
*/

#include "Interface/Context/Context.h"
#include "FEXCore/IR/IR.h"
#include "Interface/Core/LookupCache.h"

#include "Interface/Core/JIT/JITClass.h"

#include <FEXCore/Core/Thunks.h>
#include <FEXCore/Core/X86Enums.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/HLE/SyscallHandler.h>
#include <FEXCore/Utils/MathUtils.h>

namespace FEXCore::CPU {

DEF_OP(CallbackReturn) {
  // spill back to CTX
  SpillStaticRegs(TMP1);

  // First we must reset the stack
  ResetStack();

  // We can now lower the ref counter again

  ldr(ARMEmitter::WReg::w2, STATE, offsetof(FEXCore::Core::CpuStateFrame, SignalHandlerRefCounter));
  sub(ARMEmitter::Size::i32Bit, ARMEmitter::Reg::r2, ARMEmitter::Reg::r2, 1);
  str(ARMEmitter::WReg::w2, STATE, offsetof(FEXCore::Core::CpuStateFrame, SignalHandlerRefCounter));

  // We need to adjust an additional 8 bytes to get back to the original "misaligned" RSP state
  ldr(ARMEmitter::XReg::x2, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.gregs[X86State::REG_RSP]));
  add(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r2, ARMEmitter::Reg::r2, 8);
  str(ARMEmitter::XReg::x2, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.gregs[X86State::REG_RSP]));

  PopCalleeSavedRegisters();

  // Return to the thunk
  ret();
}

DEF_OP(ExitFunction) {
  auto Op = IROp->C<IR::IROp_ExitFunction>();

  ResetStack();

  if (CTX->HostFeatures.IsInstCountCI) [[unlikely]] {
    // Emit function end marker
    udf(0x420F);
  }

  uint64_t NewRIP;

  if constexpr (Context::BLOCK_DEBUGGING) {
    // Skip block linking when BLOCK_DEBUGGING as it adds overhead and is unncessary.
    // This is a debug only feature and doesn't need caching help.
    bool IsInlineRIP = IsInlineConstant(Op->NewRIP, &NewRIP) || IsInlineEntrypointOffset(Op->NewRIP, &NewRIP);
    ARMEmitter::ForwardLabel l_ExitLink;
    if (IsInlineRIP) {
      ldr(TMP1, &l_ExitLink);
      str(TMP1, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.rip));
    } else {
      auto RipReg = GetReg(Op->NewRIP);
      str(RipReg.X(), STATE, offsetof(FEXCore::Core::CpuStateFrame, State.rip));
    }
    ldr(TMP2, STATE, offsetof(FEXCore::Core::CpuStateFrame, Pointers.DispatcherLoopTop));
    br(TMP2);

    if (IsInlineRIP) {
      BindOrRestart(&l_ExitLink);
      dc64(NewRIP);
    }

    return;
  }

  if (IsInlineConstant(Op->NewRIP, &NewRIP) || IsInlineEntrypointOffset(Op->NewRIP, &NewRIP)) {
#ifdef ARCHITECTURE_arm64ec
    if (NewRIP < EC_CODE_BITMAP_MAX_ADDRESS && RtlIsEcCode(NewRIP)) {
      str(REG_CALLRET_SP, STATE_PTR(CpuStateFrame, State.callret_sp));
      add(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::rsp, StaticRegisters[X86State::REG_RSP], 0);
      InsertGuestRIPMove(EC_CALL_CHECKER_PC_REG, NewRIP);
      ldr(TMP2, STATE_PTR(CpuStateFrame, Pointers.ExitFunctionEC));
      br(TMP2);
    } else {
#endif
      // In order to support direct branches without constantly hitting the L1 cache, we emit a call to a block linker,
      // this will compile the branch target block when it is hit and replace the branch to the linker at the callsite
      // with a direct branch to the destination block. Upon invalidation of the target block the backpatch is undone.
      //
      // In addition, to avoid needing to lookup in the cache for returns and any indirect branch prediction penalty,
      // a shadow stack of <GuestReturnRIP, HostReturnPC> pairs is maintained, acting as a first level cache for any
      // return operations. As the guest may not balance calls and returns exactly, an exception handler is expected to
      // be installed by the frontend, to reset the shadow stack to the middle of its valid bounds on overflow/underflow.
      // This shadow stack is also cleared on block invalidation operations or codebuffer switches, to ensure all pointed-to
      // host code is always valid.

      // This code will be backpatched by Arm64JITCore_ExitFunctionLink, below is an enumeration of all the possible cases.
      // Jump thunks are emitted in JIT.cpp after compilation of the entire multiblock.
      //
      // Call with known return block - unlinked
      //    00: adr TMP1, 0xC
      //    04: stp RetReg, TMP1, [SpReg, -0x10]!
      //    08: bl JmpThunk00
      //    JmpThunk00:
      //    00: b 0x8
      //    04: br TMP1
      //    08: ldr TMP1, <Shared exit linker>
      //    0c: blr TMP1
      //    10: HostCode
      //    18: GuestRIP
      //    20: CallerOffset
      //
      // Call with known return block after backpatching - linked in branch immediate range
      //    00: adr TMP1, 0xC
      //    04: stp RetReg, TMP1, [SpReg, -0x10]!
      //    08: bl HostCode                                        - MODIFIED
      //
      // Call with known return block after backpatching - linked out of range
      //    00: adr TMP1, 0xC
      //    04: stp RetReg, TMP1, [SpReg, -0x10]!
      //    08: bl JmpThunk00
      //    JmpThunk00:
      //    00: ldr TMP1, 0x10                                     - MODIFIED 2nd
      //    04: br TMP1
      //    08: ldr TMP1, <Shared exit linker>
      //    0c: blr TMP1
      //    10: HostCode                                           - MODIFIED 1st
      //    18: GuestRIP
      //    20: CallerOffset
      //
      // Jump - unlinked
      //    00: b JmpThunk00
      //    JmpThunk00:
      //    00: b 0x8
      //    04: br TMP1
      //    08: ldr TMP1, <Shared exit linker>
      //    0c: blr TMP1
      //    10: HostCode
      //    18: GuestRIP
      //    20: CallerOffset
      //
      // Jump after backpatching - linked in branch immediate range
      //    00: b HostCode                                         - MODIFIED
      //
      // Jump after backpatching - linked out of range
      //    00: b JmpThunk00
      //    JmpThunk00:
      //    00: ldr TMP1, 0x10                                     - MODIFIED 2nd
      //    04: br TMP1
      //    08: ldr TMP1, <Shared exit linker>
      //    0c: blr TMP1
      //    10: HostCode                                           - MODIFIED 1st
      //    18: GuestRIP
      //    20: CallerOffset

      ARMEmitter::ForwardLabel l_BranchHost;
      ARMEmitter::ForwardLabel l_CallReturn;
      if (Op->Hint == IR::BranchHint::Call) {
#ifdef ARCHITECTURE_arm64ec
        // iOS-Madeira 2026-05-13: REG_CALLRET_SP (x17) gets clobbered when a
        // previous BLR returns from native ARM64EC code (DXMT vtable methods,
        // ARM64EC entry thunks). Reload from State.callret_sp before pushing
        // the call-return frame so we don't stp to wherever x17 was left.
        ldr(REG_CALLRET_SP, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp));
        // iOS-Madeira 2026-05-18: inline bounds-guard (Tier-2). iOS doesn't
        // honor PAGE_NOACCESS on the callret stack's guard pages, so the
        // SEH-driven HandleAccessViolation never resets the stack on
        // underflow. Detect-and-reset inline before the `stp` to keep stack
        // pointer in-range. Uses TMP1 as scratch; adr below re-initializes it.
        {
          ARMEmitter::ForwardLabel l_callret_ok;
          /* iOS-Madeira ml263: the >>24 test only fires when the pointer leaves the
           * ENTIRE 16MB region, so a large-but-in-range leak sails straight through.
           * Measured on the CEF webhelper thread:
           *   tid 0098 sp-base=0x2c8c40 -> 1.1MB pushed  (~36,000 nested calls)
           *   tid 0078 sp-base=0x132900 -> 2.75MB pushed (~90,000 nested calls)
           * while those threads' GUEST stacks had used only 2,264 and 10,008 bytes. 36,000
           * nested calls cannot exist in 2.2KB of stack (every x86 CALL pushes >=8 bytes),
           * so entries are pushed and never popped -- non-local exits (SEH unwind, C++
           * throw) skip the guest RETs, and CEF init throws constantly.
           *
           * Bound it to a 4MB window CENTRED on DefaultLocation (base + 4MB): test
           * (sp - (base + 2MB)) >> 22, so sp-base must stay in [2MB, 6MB). Caps pushes at
           * ~131,072 entries (~65,536 nested calls), far beyond any real program.
           *
           * Resetting is SAFE, not a papering-over: this stack is purely a return-address
           * PREDICTOR. A stale or missing entry fails the `sub TMP1, TMP1, RipReg` compare
           * and falls through to the L1 lookup, which is always correct. A reset costs
           * mispredictions, nothing else. */
          ldr(TMP1, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp_base));
          add(ARMEmitter::Size::i64Bit, TMP1, TMP1, 0x200000);
          sub(ARMEmitter::Size::i64Bit, TMP1, REG_CALLRET_SP, TMP1);
          lsr(ARMEmitter::Size::i64Bit, TMP1, TMP1, 22);
          (void)cbz(ARMEmitter::Size::i64Bit, TMP1, &l_callret_ok);
          ldr(REG_CALLRET_SP, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp_base));
          add(ARMEmitter::Size::i64Bit, REG_CALLRET_SP, REG_CALLRET_SP, 0x400000);
          (void)Bind(&l_callret_ok);
        }
#endif
        if (!Op->CallReturnBlock.IsInvalid()) {
          auto CallReturnAddressReg = GetReg(Op->CallReturnAddress).X();
          PendingCallReturnTargetLabel = &CallReturnTargets.try_emplace(Op->CallReturnBlock.ID()).first->second;
          (void)adr(TMP1, &l_CallReturn);
          stp<ARMEmitter::IndexType::PRE>(CallReturnAddressReg, TMP1, REG_CALLRET_SP, -0x10);
        } else {
          stp<ARMEmitter::IndexType::PRE>(ARMEmitter::XReg::zr, ARMEmitter::XReg::zr, REG_CALLRET_SP, -0x10);
        }
#ifdef ARCHITECTURE_arm64ec
        /* Write back post-push x17 so dispatcher LoopTop's reload picks
         * up the new top. Without this, in-register PUSH changes get
         * lost on next dispatcher iteration and the entry leaks. */
        str(REG_CALLRET_SP, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp));
#endif
      } else if (Op->Hint == IR::BranchHint::CheckTF) {
        ARMEmitter::ForwardLabel TFUnset;
        ldrb(TMP1, STATE_PTR(CpuStateFrame, State.flags[X86State::RFLAG_TF_RAW_LOC]));
        (void)cbz(ARMEmitter::Size::i32Bit, TMP1, &TFUnset);
        InsertGuestRIPMove(TMP1, NewRIP);
        str(TMP1, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.rip));
        ldr(TMP2, STATE, offsetof(FEXCore::Core::CpuStateFrame, Pointers.DispatcherLoopTop));
        blr(TMP2);
        (void)Bind(&TFUnset);
      }

      EmitLinkedBranch(NewRIP, Op->Hint == IR::BranchHint::Call);
      (void)Bind(&l_CallReturn);
#ifdef ARCHITECTURE_arm64ec
    }
#endif
  } else {
    ARMEmitter::ForwardLabel SkipFullLookup;
    auto RipReg = GetReg(Op->NewRIP);

    if (Op->Hint == IR::BranchHint::Return) {
      // First try to pop from the call-ret stack, otherwise follow the normal path (but ending in a ret)
#ifdef ARCHITECTURE_arm64ec
      // iOS-Madeira 2026-05-15: POP-side x17 reload + state sync. ARM64EC
      // native returns clobber x17, so we reload from State.callret_sp
      // before popping. AND we write back the post-pop value to State so
      // the dispatcher LoopTop's reload (line 134 of Dispatcher.cpp) sees
      // the updated stack pointer. Without this writeback, in-register
      // pop changes are lost on next dispatcher iteration — quantified
      // as ~1 leaked callret entry per block dispatch on Thumper FMOD.
      ldr(REG_CALLRET_SP, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp));
      // iOS-Madeira 2026-05-18: inline bounds-guard (Tier-2) — see CALL push
      // site for rationale. Reset to DefaultLocation if OOB before ldp.
      {
        ARMEmitter::ForwardLabel l_callret_ok;
        /* iOS-Madeira ml263: tightened to a 4MB window -- see the first CALL push site. */
        ldr(TMP1, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp_base));
        add(ARMEmitter::Size::i64Bit, TMP1, TMP1, 0x200000);
        sub(ARMEmitter::Size::i64Bit, TMP1, REG_CALLRET_SP, TMP1);
        lsr(ARMEmitter::Size::i64Bit, TMP1, TMP1, 22);
        (void)cbz(ARMEmitter::Size::i64Bit, TMP1, &l_callret_ok);
        ldr(REG_CALLRET_SP, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp_base));
        add(ARMEmitter::Size::i64Bit, REG_CALLRET_SP, REG_CALLRET_SP, 0x400000);
        (void)Bind(&l_callret_ok);
      }
#endif
      ldp<ARMEmitter::IndexType::POST>(TMP1, TMP2, REG_CALLRET_SP, 0x10);
#ifdef ARCHITECTURE_arm64ec
      str(REG_CALLRET_SP, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp));
#endif
      sub(TMP1, TMP1, RipReg.X());
#ifdef FEX_IOS_HOST
      /* iOS-Madeira ml305 (tasks #42 / #51 / #52): DO NOT TRUST THE CALL-RET PREDICTION ON iOS.
       *
       * Taking this shortcut means `br TMP2`, where TMP2 is the HOST half of the popped entry -- an
       * intra-block `adr(&l_CallReturn)` label recorded by the CALL push above. That is only safe if
       * the popped entry actually belongs to this return. Upstream can assume it does because an
       * unbalanced stack eventually walks into a guard page and CallRetStack::HandleAccessViolation
       * resets it. On iOS that SEGV NEVER FIRES -- Wine's VirtualAlloc(MEM_RESERVE, PAGE_NOACCESS)
       * does not enforce NOACCESS here, which is the whole reason the inline bounds-guard above
       * exists -- so stale entries accumulate without bound inside the guard window and a RET can
       * pop an entry belonging to an unrelated, long-abandoned call.
       *
       * When such a stale entry's guest_ret COINCIDENTALLY equals the real return address, the cbz
       * fires and we branch into the middle of a DIFFERENT block at its l_CallReturn label, with
       * this block's register state. Measured evidence for exactly that:
       *   ml304  GuestRIP 0x1561b540c, InlineJITBlockHeader 0x1561b53e0  -> host PC +0x2c into block
       *   ml298  GuestRIP 0x15621c354, InlineJITBlockHeader 0x15621b0a0  -> host PC +0x12b4 into block
       * both in FEX's own EC_CODE tail, both absent from every guest GPR ([bogus-regs]), and with
       * 79,880 leaked entries live (sp-base 2.78MB, inside [2MB,6MB) so the guard stayed silent).
       *
       * Dropping the shortcut is SEMANTICALLY SAFE by this file's own reasoning: the call-ret stack
       * is "purely a return-address PREDICTOR", and "a stale or missing entry fails the compare and
       * falls through to the L1 lookup, which is always correct". We keep the ldp POP and the
       * State.callret_sp writeback so stack balance is completely unchanged -- only the act of
       * trusting TMP2 goes away. Cost is a mispredict per guest RET (an L1 lookup instead of a
       * direct branch), so this is a real throughput hit worth measuring on Thumper.
       *
       * A/B either way: if the [iOS-bogusrip] hits disappear, the predictor was the source and this
       * becomes the fix; if they persist unchanged, the predictor is exonerated and a large suspect
       * is eliminated for one run. */
      (void)SkipFullLookup;
#else
      (void)cbz(ARMEmitter::Size::i64Bit, TMP1, &SkipFullLookup);
#endif
    }

    // L1 Cache
    ldp<ARMEmitter::IndexType::OFFSET>(TMP1, TMP2, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.L1Pointer));

    // Calculate (tmp1 + ((ripreg & L1_ENTRIES_MASK) << 4)) for the address
    // L1Mask is pre-shifted.
    and_(ARMEmitter::Size::i64Bit, TMP2, TMP2, RipReg, ARMEmitter::ShiftType::LSL, FEXCore::ilog2(sizeof(LookupCache::LookupCacheEntry)));
    add(TMP1, TMP1, TMP2);

    ldp<ARMEmitter::IndexType::OFFSET>(TMP2, TMP1, TMP1, 0);

    // Note: sub+cbnz used over cmp+br to preserve flags.
    sub(TMP1, TMP1, RipReg.X());
    (void)cbz(ARMEmitter::Size::i64Bit, TMP1, &SkipFullLookup);
    ldr(TMP2, STATE, offsetof(FEXCore::Core::CpuStateFrame, Pointers.DispatcherLoopTop));
    str(RipReg.X(), STATE, offsetof(FEXCore::Core::CpuStateFrame, State.rip));

    (void)Bind(&SkipFullLookup);
    if (Op->Hint == IR::BranchHint::Call) {
      ARMEmitter::ForwardLabel l_CallReturn;
#ifdef ARCHITECTURE_arm64ec
      // iOS-Madeira 2026-05-13: see note above — reload REG_CALLRET_SP (x17)
      // from State.callret_sp before pushing the call-return frame, since
      // native ARM64EC returns leave x17 pointing at an arbitrary RX page.
      ldr(REG_CALLRET_SP, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp));
      // iOS-Madeira 2026-05-18: inline bounds-guard (Tier-2). Same as
      // linked-path CALL push.
      {
        ARMEmitter::ForwardLabel l_callret_ok;
        /* iOS-Madeira ml263: tightened to a 4MB window -- see the first CALL push site. */
        ldr(TMP1, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp_base));
        add(ARMEmitter::Size::i64Bit, TMP1, TMP1, 0x200000);
        sub(ARMEmitter::Size::i64Bit, TMP1, REG_CALLRET_SP, TMP1);
        lsr(ARMEmitter::Size::i64Bit, TMP1, TMP1, 22);
        (void)cbz(ARMEmitter::Size::i64Bit, TMP1, &l_callret_ok);
        ldr(REG_CALLRET_SP, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp_base));
        add(ARMEmitter::Size::i64Bit, REG_CALLRET_SP, REG_CALLRET_SP, 0x400000);
        (void)Bind(&l_callret_ok);
      }
#endif
      if (!Op->CallReturnBlock.IsInvalid()) {
        auto CallReturnAddressReg = GetReg(Op->CallReturnAddress).X();
        PendingCallReturnTargetLabel = &CallReturnTargets.try_emplace(Op->CallReturnBlock.ID()).first->second;
        (void)adr(TMP1, &l_CallReturn);
        stp<ARMEmitter::IndexType::PRE>(CallReturnAddressReg, TMP1, REG_CALLRET_SP, -0x10);
      } else {
        stp<ARMEmitter::IndexType::PRE>(ARMEmitter::XReg::zr, ARMEmitter::XReg::zr, REG_CALLRET_SP, -0x10);
      }
#ifdef ARCHITECTURE_arm64ec
      /* Write back post-push x17 so dispatcher LoopTop reload sees it. */
      str(REG_CALLRET_SP, STATE, offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp));
#endif
      blr(TMP2);
      (void)Bind(&l_CallReturn);
    } else if (Op->Hint == IR::BranchHint::Return) {
      ret(TMP2);
    } else {
      br(TMP2);
    }
  }
}

DEF_OP(Jump) {
  const auto Op = IROp->C<IR::IROp_Jump>();

  PendingTargetLabel = JumpTarget(Op->TargetBlock);
}

DEF_OP(CondJump) {
  auto Op = IROp->C<IR::IROp_CondJump>();

  auto TrueTargetLabel = JumpTarget(Op->TrueBlock);

  if (Op->FromNZCV) {
    b_OrRestart(MapCC(Op->Cond), TrueTargetLabel);
  } else {
    uint64_t Const;
    const bool isConst = IsInlineConstant(Op->Cmp2, &Const);

    auto Reg = GetReg(Op->Cmp1);
    const auto Size = Op->CompareSize == IR::OpSize::i32Bit ? ARMEmitter::Size::i32Bit : ARMEmitter::Size::i64Bit;

    LOGMAN_THROW_A_FMT(IsGPR(Op->Cmp1), "CondJump: Expected GPR");
    LOGMAN_THROW_A_FMT(isConst, "CondJump: Expected constant source");

    if (Op->Cond == IR::CondClass::EQ) {
      LOGMAN_THROW_A_FMT(Const == 0, "CondJump: Expected 0 source");
      cbz_OrRestart(Size, Reg, TrueTargetLabel);
    } else if (Op->Cond == IR::CondClass::NEQ) {
      LOGMAN_THROW_A_FMT(Const == 0, "CondJump: Expected 0 source");
      cbnz_OrRestart(Size, Reg, TrueTargetLabel);
    } else if (Op->Cond == IR::CondClass::TSTZ) {
      LOGMAN_THROW_A_FMT(Const < 64, "CondJump: Expected valid bit source");
      tbz_OrRestart(Reg, Const, TrueTargetLabel);
    } else if (Op->Cond == IR::CondClass::TSTNZ) {
      LOGMAN_THROW_A_FMT(Const < 64, "CondJump: Expected valid bit source");
      tbnz_OrRestart(Reg, Const, TrueTargetLabel);
    } else {
      LOGMAN_THROW_A_FMT(false, "CondJump expected simple condition");
    }
  }

  PendingTargetLabel = JumpTarget(Op->FalseBlock);
}

DEF_OP(Syscall) {
  auto Op = IROp->C<IR::IROp_Syscall>();
  // Arguments are passed as follows:
  // X0: SyscallHandler
  // X1: ThreadState
  // X2: Pointer to SyscallArguments

  PushDynamicRegs(TMP1);

  uint32_t GPRSpillMask = ~0U;
  uint32_t FPRSpillMask = ~0U;

  SpillStaticRegs(TMP1, {
                          .GPRSpillMask = GPRSpillMask,
                          .FPRSpillMask = FPRSpillMask,
                        });

  // Now that we are spilled, store in the state that we are in a syscall
  // Still without overwriting registers that matter
  // 16bit LoadConstant to be a single instruction
  // This gives the signal handler a value to check to see if we are in a syscall at all
  LoadConstant(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r0, GPRSpillMask & 0xFFFF);
  str(ARMEmitter::XReg::x0, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));

  uint64_t SPOffset = AlignUp(FEXCore::HLE::SyscallArguments::MAX_ARGS * 8, 16);
  sub(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::rsp, ARMEmitter::Reg::rsp, SPOffset);
  for (uint32_t i = 0; i < FEXCore::HLE::SyscallArguments::MAX_ARGS; ++i) {
    if (Op->Header.Args[i].IsInvalid()) {
      continue;
    }
    str(GetReg(Op->Header.Args[i]).X(), ARMEmitter::Reg::rsp, i * 8);
  }

  ldr(ARMEmitter::XReg::x0, STATE, offsetof(FEXCore::Core::CpuStateFrame, Pointers.SyscallHandlerObj));
  ldr(ARMEmitter::XReg::x3, STATE, offsetof(FEXCore::Core::CpuStateFrame, Pointers.SyscallHandlerFunc));
  mov(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r1, STATE.R());

  // SP supporting move
  add(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r2, ARMEmitter::Reg::rsp, 0);
  if (!CTX->Config.DisableVixlIndirectCalls) [[unlikely]] {
    GenerateIndirectRuntimeCall<uint64_t, void*, void*, void*>(ARMEmitter::Reg::r3);
  } else {
    blr(ARMEmitter::Reg::r3);
  }

  add(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::rsp, ARMEmitter::Reg::rsp, SPOffset);

  // Result is now in x0
  // Fix the stack and any values that were stepped on
  FillStaticRegs({
    .OptionalReg = ARMEmitter::Reg::r1,
    .OptionalReg2 = ARMEmitter::Reg::r2,
    .GPRFillMask = GPRSpillMask,
    .FPRFillMask = FPRSpillMask,
  });

  // Now the registers we've spilled are back in their original host registers
  // We can safely claim we are no longer in a syscall
  str(ARMEmitter::XReg::zr, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));

  PopDynamicRegs();

  const auto OSABI = CTX->SyscallHandler->GetOSABI();

  if (OSABI != FEXCore::HLE::SyscallOSABI::OS_GENERIC) {
    // Move result to its destination register.
    // Only if `NORETURNEDRESULT` wasn't set, otherwise we might overwrite the CPUState refilled with `FillStaticRegs`
    mov(ARMEmitter::Size::i64Bit, GetReg(Node), ARMEmitter::Reg::r0);
  }
}

DEF_OP(Thunk) {
  auto Op = IROp->C<IR::IROp_Thunk>();
  // Arguments are passed as follows:
  // X0: CTX
  // X1: Args (from guest stack)

  // spill to ctx before ra64 spill
  SpillStaticRegs(TMP1, {
                          .NZCV = false,
                        });

  PushDynamicRegs(TMP1);

  mov(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r0, GetReg(Op->ArgPtr));

  InsertNamedThunkRelocation(ARMEmitter::Reg::r2, Op->ThunkNameHash);
  if (!CTX->Config.DisableVixlIndirectCalls) [[unlikely]] {
    GenerateIndirectRuntimeCall<void, void*, void*>(ARMEmitter::Reg::r2);
  } else {
    blr(ARMEmitter::Reg::r2);
  }

  PopDynamicRegs();

  // load from ctx after ra64 refill
  FillStaticRegs({
    .NZCV = false,
  });
}

DEF_OP(ValidateCode) {
  auto Op = IROp->C<IR::IROp_ValidateCode>();
  auto OldCode = Op->CodeOriginal.data();
  auto Base = GetReg(Op->Header.Args[0]).X();
  int len = Op->CodeLength;
  int Offset = 0;
  ARMEmitter::ForwardLabel Fail;

  const auto Dst = GetReg(Node);

  auto EmitCheck = [&](size_t Size, auto&& LoadData) {
    while (len >= Size) {
      LoadData();
      sub(ARMEmitter::Size::i64Bit, TMP1, TMP1, TMP2);
      cbnz_OrRestart(ARMEmitter::Size::i64Bit, TMP1, &Fail);
      len -= Size;
      Offset += Size;
    }
  };

  EmitCheck(8, [&]() {
    ldr(TMP1, Base, Offset);
    LoadConstant(ARMEmitter::Size::i64Bit, TMP2, *(const uint64_t*)(OldCode + Offset));
  });

  EmitCheck(4, [&]() {
    ldr(TMP1.W(), Base, Offset);
    LoadConstant(ARMEmitter::Size::i32Bit, TMP2, *(const uint32_t*)(OldCode + Offset));
  });

  EmitCheck(2, [&]() {
    ldrh(TMP1.W(), Base, Offset);
    LoadConstant(ARMEmitter::Size::i32Bit, TMP2, *(const uint16_t*)(OldCode + Offset));
  });

  EmitCheck(1, [&]() {
    ldrb(TMP1.W(), Base, Offset);
    LoadConstant(ARMEmitter::Size::i32Bit, TMP2, *(const uint8_t*)(OldCode + Offset));
  });

  ARMEmitter::ForwardLabel End;
  LoadConstant(ARMEmitter::Size::i32Bit, Dst, 0);
  b_OrRestart(&End);
  BindOrRestart(&Fail);
  LoadConstant(ARMEmitter::Size::i32Bit, Dst, 1);
  BindOrRestart(&End);
}

DEF_OP(ThreadRemoveCodeEntry) {
  PushDynamicRegs(TMP4);
  SpillStaticRegs(TMP4);

  // Arguments are passed as follows:
  // X0: Thread
  // X1: RIP
  mov(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r0, STATE.R());

  // TODO: Relocations don't seem to be wired up to this...?
  LoadConstant(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r1, Entry, CPU::Arm64Emitter::PadType::AUTOPAD);

  ldr(ARMEmitter::XReg::x2, STATE, offsetof(FEXCore::Core::CpuStateFrame, Pointers.ThreadRemoveCodeEntryFromJIT));
  if (!CTX->Config.DisableVixlIndirectCalls) [[unlikely]] {
    GenerateIndirectRuntimeCall<void, void*, void*>(ARMEmitter::Reg::r2);
  } else {
    blr(ARMEmitter::Reg::r2);
  }
  FillStaticRegs();

  // Fix the stack and any values that were stepped on
  PopDynamicRegs();
}

DEF_OP(CPUID) {
  auto Op = IROp->C<IR::IROp_CPUID>();

  isb();
  mov(ARMEmitter::Size::i64Bit, TMP2, GetReg(Op->Function));
  mov(ARMEmitter::Size::i64Bit, TMP3, GetReg(Op->Leaf));

  PushDynamicRegs(TMP4);
  SpillStaticRegs(TMP4);

  // x0 = CPUID Handler
  // x1 = CPUID Function
  // x2 = CPUID Leaf
  ldr(ARMEmitter::XReg::x0, STATE, offsetof(FEXCore::Core::CpuStateFrame, Pointers.CPUIDObj));
  ldr(ARMEmitter::XReg::x3, STATE, offsetof(FEXCore::Core::CpuStateFrame, Pointers.CPUIDFunction));

  if (!TMP_ABIARGS) {
    mov(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r1, TMP2);
    mov(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r2, TMP3);
  }

  if (!CTX->Config.DisableVixlIndirectCalls) [[unlikely]] {
    GenerateIndirectRuntimeCall<__uint128_t, void*, uint64_t, uint64_t>(ARMEmitter::Reg::r3);
  } else {
    blr(ARMEmitter::Reg::r3);
  }

  if (!TMP_ABIARGS) {
    mov(ARMEmitter::Size::i64Bit, TMP1, ARMEmitter::Reg::r0);
    mov(ARMEmitter::Size::i64Bit, TMP2, ARMEmitter::Reg::r1);
  }

  FillStaticRegs();

  PopDynamicRegs();

  // Results are in x0, x1
  // Results want to be 4xi32 scalars
  mov(ARMEmitter::Size::i32Bit, GetReg(Op->OutEAX), TMP1);
  mov(ARMEmitter::Size::i32Bit, GetReg(Op->OutECX), TMP2);
  ubfx(ARMEmitter::Size::i64Bit, GetReg(Op->OutEBX), TMP1, 32, 32);
  ubfx(ARMEmitter::Size::i64Bit, GetReg(Op->OutEDX), TMP2, 32, 32);
}

DEF_OP(XGetBV) {
  auto Op = IROp->C<IR::IROp_XGetBV>();

  PushDynamicRegs(TMP4);
  SpillStaticRegs(TMP4);

  mov(ARMEmitter::Size::i32Bit, ARMEmitter::Reg::r1, GetReg(Op->Function));

  // x0 = CPUID Handler
  // x1 = XCR Function
  ldr(ARMEmitter::XReg::x0, STATE, offsetof(FEXCore::Core::CpuStateFrame, Pointers.CPUIDObj));
  ldr(ARMEmitter::XReg::x2, STATE, offsetof(FEXCore::Core::CpuStateFrame, Pointers.XCRFunction));
  if (!CTX->Config.DisableVixlIndirectCalls) [[unlikely]] {
    GenerateIndirectRuntimeCall<uint64_t, void*, uint32_t>(ARMEmitter::Reg::r2);
  } else {
    blr(ARMEmitter::Reg::r2);
  }

  if (!TMP_ABIARGS) {
    mov(ARMEmitter::Size::i64Bit, TMP1, ARMEmitter::Reg::r0);
  }

  FillStaticRegs();

  PopDynamicRegs();

  // Results are in x0, need to split into i32 parts
  mov(ARMEmitter::Size::i32Bit, GetReg(Op->OutEAX), TMP1);
  ubfx(ARMEmitter::Size::i64Bit, GetReg(Op->OutEDX), TMP1, 32, 32);
}

} // namespace FEXCore::CPU
