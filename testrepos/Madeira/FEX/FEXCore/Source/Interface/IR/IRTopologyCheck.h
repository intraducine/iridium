// SPDX-License-Identifier: MIT
#pragma once
/*
 * iOS-Madeira ml599: bounded structural validation of the intrusive IR node list.
 *
 * WHY THIS EXISTS
 * ---------------
 * Two passes walk a code block BACKWARDS and terminate only by reaching
 * CodeBegin, with no bound on the number of steps:
 *
 *   DeadFlagCalculationEliminination::ProcessBlock   (RedundantFlagCalculationElimination.cpp)
 *   ConstrainedRAPass::Run                           (RegisterAllocationPass.cpp)
 *
 * Both assume the Previous chain from BlockIROp->Last always reaches
 * BlockIROp->Begin. ml598 proved that assumption can fail on real workloads:
 * the ml597 DFE bound fired on block 405 after 13,183 steps (budget =
 * SSACount + 16), and the SAME run then hung Chrome_InProcRendererThread at
 * 97-100% CPU for minutes inside ConstrainedRAPass::Run -- PC sampled at
 * libarm64ecfex.dll RVA 0x100b0c / 0x100cb4 / 0x100cc4 / 0x100cdc, all inside
 * [Run, Run+0xcd8), on the `ldr w27,[x26,#8]` (Previous) back edge. Steam had
 * logged in and reached its main UI; the store page never rendered because the
 * renderer's compile never returned.
 *
 * Skipping a pass after the damage is done ("fail open") is NOT a fix: DFE
 * calls IREmit->Remove() as it walks, so by the time a step counter trips it
 * has already mutated the list thousands of times, and the register allocator
 * is then handed that IR anyway.
 *
 * WHAT THIS DOES
 * --------------
 * Validate BEFORE anything mutates, then either repair or decline:
 *
 *   ValidateBlockTopology()  bounded forward walk Begin->Last, bounded backward
 *                            walk Last->Begin, Next/Previous reciprocity check,
 *                            and Floyd cycle detection on the Previous chain.
 *                            Says WHICH field is wrong, not merely "something is".
 *
 *   RepairBlockPrevious()    rebuild the Previous chain from the forward chain.
 *                            Sound only when the forward walk reached Last, so
 *                            callers must check that first.
 *
 * A caller that cannot repair must skip its backward walk entirely rather than
 * bound it mid-flight: a partial backward pass in RA sets kill bits on only
 * some nodes, which is conservative and safe, whereas walking a cyclic chain
 * sets kill bits on nodes belonging to other blocks, which is a miscompile.
 */

#include "Interface/IR/IntrusiveIRList.h"

#include <FEXCore/IR/IR.h>
#include <FEXCore/Utils/LogManager.h>

#include <atomic>
#include <cstdint>

namespace FEXCore::IR {

struct IRBlockTopology {
  static constexpr uint32_t NoNode = 0xffffffffu;

  uint32_t BeginID {};
  uint32_t LastID {};

  // Steps actually taken. Both are capped at SSACount + 16; hitting the cap is
  // itself proof of corruption, since a single block cannot hold more nodes
  // than the entire listing.
  uint32_t ForwardSteps {};
  uint32_t BackwardSteps {};

  bool ForwardReachedLast {};
  bool BackwardReachedBegin {};

  // Previous chain revisits a node (Floyd tortoise/hare). Distinguishes "loops
  // forever" from "walks off into another block's nodes and stops".
  bool BackwardCyclic {};

  // First node N on the forward walk where Next(N)->Previous != N.
  uint32_t ReciprocityBreakID {NoNode};
  uint16_t ReciprocityBreakOp {};

  [[nodiscard]]
  bool OK() const {
    return ForwardReachedLast && BackwardReachedBegin && !BackwardCyclic && ReciprocityBreakID == NoNode;
  }

  // Repair is only sound when the forward chain is intact end to end.
  [[nodiscard]]
  bool Repairable() const {
    return ForwardReachedLast;
  }
};

/**
 * @brief CHEAP detection: bounded backward walk only.
 *
 * ml599 shipped the full diagnostic on every block at DFE entry, RA entry, AND
 * after every pass. That was far too expensive -- the renderer thread spent as
 * much time inside ValidateBlockTopology as inside the entire x86 decoder, and
 * Steam never reached the UI it had reached the run before. A probe must not
 * break what it measures.
 *
 * So detection is now just the walk that actually hangs: follow Previous from
 * Last, bounded, and see whether it reaches Begin. No Floyd, no forward walk, no
 * reciprocity -- those cost 3-4x more and are only needed to DESCRIBE a fault we
 * have already found. One extra pointer-chase loop per block is small against
 * the many loads and stores per node the passes themselves do.
 *
 * @return true when the backward chain reaches Begin within budget.
 */
[[nodiscard]]
inline bool QuickBackwardOK(const IRListView& IR, Ref BlockNode) {
  auto BlockIROp = IR.GetOp<IROp_CodeBlock>(BlockNode);
  const uint32_t Budget = IR.GetSSACount() + 16;

  Ref const Begin = IR.GetNode(BlockIROp->Begin);
  Ref Cur = IR.GetNode(BlockIROp->Last);

  for (uint32_t Steps = 0; Steps <= Budget; ++Steps) {
    if (Cur == Begin) {
      return true;
    }
    const OrderedNodeWrapper PrevW = Cur->Header.Previous;
    if (PrevW.NodeOffset == 0) {
      return false; // truncated: hit the sentinel without seeing Begin
    }
    Cur = IR.GetNode(PrevW);
  }
  return false; // exceeded budget: cyclic, or chained into foreign nodes
}

/**
 * @brief FULL diagnostic. Only worth running once QuickBackwardOK has failed.
 * @return true when the block is well formed. Never dereferences past the
 *         budget, so it is safe to call on already-corrupt IR.
 */
[[nodiscard]]
inline bool ValidateBlockTopology(const IRListView& IR, Ref BlockNode, IRBlockTopology& Out) {
  Out = IRBlockTopology {};

  auto BlockIROp = IR.GetOp<IROp_CodeBlock>(BlockNode);
  const uint32_t Budget = IR.GetSSACount() + 16;

  Ref const Begin = IR.GetNode(BlockIROp->Begin);
  Ref const Last = IR.GetNode(BlockIROp->Last);

  Out.BeginID = IR.GetID(Begin).Value;
  Out.LastID = IR.GetID(Last).Value;

  // Forward: Begin -> ... -> Last, checking reciprocity as we go.
  {
    Ref Cur = Begin;
    OrderedNodeWrapper CurW = BlockIROp->Begin;

    while (true) {
      ++Out.ForwardSteps;

      if (Cur == Last) {
        Out.ForwardReachedLast = true;
        break;
      }

      if (Out.ForwardSteps > Budget) {
        break;
      }

      const OrderedNodeWrapper NextW = Cur->Header.Next;
      if (NextW.NodeOffset == 0) {
        // Ran into the sentinel without ever seeing Last: the chain is
        // truncated, or Last does not belong to this block.
        break;
      }

      Ref Next = IR.GetNode(NextW);
      if (Out.ReciprocityBreakID == IRBlockTopology::NoNode && IR.GetNode(Next->Header.Previous) != Cur) {
        Out.ReciprocityBreakID = IR.GetID(Cur).Value;
        Out.ReciprocityBreakOp = static_cast<uint16_t>(IR.GetOp<IROp_Header>(Cur)->Op);
      }

      CurW = NextW;
      Cur = Next;
    }
  }

  // Backward: Last -> ... -> Begin, with Floyd cycle detection running on the
  // same chain. Slow advances one link per iteration, Fast two; they can only
  // meet if the chain closes on itself.
  {
    Ref Cur = Last;
    Ref Slow = Last;
    Ref Fast = Last;

    auto StepPrev = [&IR](Ref N) -> Ref {
      const OrderedNodeWrapper PrevW = N->Header.Previous;
      return PrevW.NodeOffset == 0 ? nullptr : IR.GetNode(PrevW);
    };

    while (true) {
      ++Out.BackwardSteps;

      if (Cur == Begin) {
        Out.BackwardReachedBegin = true;
        break;
      }

      if (Out.BackwardSteps > Budget) {
        break;
      }

      Cur = StepPrev(Cur);
      if (!Cur) {
        break;
      }

      // Floyd, one tortoise step and two hare steps per iteration.
      if (Fast) {
        Fast = StepPrev(Fast);
      }
      if (Fast) {
        Fast = StepPrev(Fast);
      }
      Slow = StepPrev(Slow);

      if (Fast && Fast == Slow) {
        Out.BackwardCyclic = true;
        break;
      }
    }
  }

  return Out.OK();
}

/**
 * @brief Rebuild the Previous chain from the forward chain.
 *
 * Caller MUST have validated that the forward walk reaches Last
 * (IRBlockTopology::Repairable), otherwise this walks the same broken chain.
 *
 * @return number of Previous links rewritten.
 */
inline uint32_t RepairBlockPrevious(const IRListView& IR, Ref BlockNode) {
  auto BlockIROp = IR.GetOp<IROp_CodeBlock>(BlockNode);
  const uint32_t Budget = IR.GetSSACount() + 16;

  Ref const Last = IR.GetNode(BlockIROp->Last);

  OrderedNodeWrapper CurW = BlockIROp->Begin;
  Ref Cur = IR.GetNode(CurW);

  uint32_t Relinked = 0;
  uint32_t Steps = 0;

  while (Cur != Last && ++Steps <= Budget) {
    const OrderedNodeWrapper NextW = Cur->Header.Next;
    if (NextW.NodeOffset == 0) {
      break;
    }

    Ref Next = IR.GetNode(NextW);
    if (IR.GetNode(Next->Header.Previous) != Cur) {
      Next->Header.Previous = CurW;
      ++Relinked;
    }

    CurW = NextW;
    Cur = Next;
  }

  return Relinked;
}

/**
 * @brief One line naming exactly which structural invariant broke.
 * @param Where short tag for the call site, e.g. "dfe-entry" or "ra-entry".
 */
inline void ReportBlockTopology(const char* Where, const IRListView& IR, Ref BlockNode, const IRBlockTopology& Topo) {
  auto BlockIROp = IR.GetOp<IROp_CodeBlock>(BlockNode);
  auto Header = IR.GetHeader();

  LogMan::Msg::EFmt("[ir-topo] ml599 {} CORRUPT block={} rip=0x{:x}+0x{:x} ssa={} "
                    "begin={} last={} fwd={}{} bwd={}{}{} recip-break={} op={}",
                    Where, BlockIROp->ID, Header->OriginalRIP, BlockIROp->GuestEntryOffset, IR.GetSSACount(), Topo.BeginID, Topo.LastID,
                    Topo.ForwardSteps, Topo.ForwardReachedLast ? "(reached-last)" : "(NEVER-REACHED-LAST)", Topo.BackwardSteps,
                    Topo.BackwardReachedBegin ? "(reached-begin)" : "(NEVER-REACHED-BEGIN)", Topo.BackwardCyclic ? "(CYCLIC)" : "",
                    Topo.ReciprocityBreakID == IRBlockTopology::NoNode ? 0xffffffffu : Topo.ReciprocityBreakID, Topo.ReciprocityBreakOp);
}

// Census. ml599's ZERO [ir-topo] lines were ambiguous -- no corruption, or the
// checks never ran? A probe whose silence cannot be interpreted is not a probe.
// These make "nothing fired" mean something.
inline std::atomic<uint64_t> IRTopoChecked {0};
inline std::atomic<uint64_t> IRTopoTripped {0};
inline std::atomic<uint64_t> IRTopoRepaired {0};
inline std::atomic<uint64_t> IRTopoDeclined {0};

enum class IRTopoAction {
  Proceed, // chain is (now) sound: the caller's backward walk will terminate
  Skip,    // unrepairable: the caller MUST NOT walk this block backwards
};

inline void IRTopoNoteChecked() {
  const uint64_t N = IRTopoChecked.fetch_add(1, std::memory_order_relaxed) + 1;
  if ((N & 0xfffff) == 0) { // every ~1M blocks
    LogMan::Msg::EFmt("[ir-topo] ml599b census: checked={} tripped={} repaired={} declined={}", N,
                      IRTopoTripped.load(std::memory_order_relaxed), IRTopoRepaired.load(std::memory_order_relaxed),
                      IRTopoDeclined.load(std::memory_order_relaxed));
  }
}

/**
 * @brief Full diagnosis + repair for a block the cheap check flagged.
 *
 * Only reached when QuickBackwardOK() failed, so the expensive walks here cost
 * nothing on the healthy path.
 */
inline IRTopoAction HandleSuspectBlock(const char* Where, const IRListView& IR, Ref BlockNode) {
  IRTopoTripped.fetch_add(1, std::memory_order_relaxed);

  IRBlockTopology Topo;
  if (ValidateBlockTopology(IR, BlockNode, Topo)) {
    // Cheap check said bad, full check says good. Report it rather than hide it:
    // it would mean the two disagree, which is a bug in one of them.
    LogMan::Msg::EFmt("[ir-topo] ml599b {} DISAGREEMENT: quick check tripped but full "
                      "validation passed (fwd={} bwd={}) -- proceeding",
                      Where, Topo.ForwardSteps, Topo.BackwardSteps);
    return IRTopoAction::Proceed;
  }

  ReportBlockTopology(Where, IR, BlockNode, Topo);

  if (Topo.Repairable()) {
    const uint32_t Relinked = RepairBlockPrevious(IR, BlockNode);
    const bool NowOK = ValidateBlockTopology(IR, BlockNode, Topo);
    LogMan::Msg::EFmt("[ir-topo] ml599b {} repair: relinked {} Previous link(s) from the "
                      "forward chain -> {}",
                      Where, Relinked, NowOK ? "VALID" : "STILL CORRUPT");
    if (NowOK) {
      IRTopoRepaired.fetch_add(1, std::memory_order_relaxed);
      return IRTopoAction::Proceed;
    }
  }

  IRTopoDeclined.fetch_add(1, std::memory_order_relaxed);
  return IRTopoAction::Skip;
}

} // namespace FEXCore::IR
