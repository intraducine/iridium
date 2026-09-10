// SPDX-License-Identifier: MIT
/*
$info$
tags: ir|opts
$end_info$
*/

#include "Interface/IR/IR.h"
#include "Interface/IR/IREmitter.h"
#include "Interface/IR/IRTopologyCheck.h"
#include "Interface/IR/PassManager.h"
#include "Utils/AllocWatch.h"

#include <FEXCore/Core/X86Enums.h>
#include <FEXCore/IR/IR.h>
#include <FEXCore/Utils/CompilerDefs.h>
#include <FEXCore/Utils/MathUtils.h>
#include <FEXCore/Utils/Profiler.h>
#include <FEXCore/fextl/deque.h>
#include <FEXCore/fextl/vector.h>

// Flag bit flags
#define FLAG_V (1U << 0)
#define FLAG_C (1U << 1)
#define FLAG_Z (1U << 2)
#define FLAG_N (1U << 3)
#define FLAG_P (1U << 4)
#define FLAG_A (1U << 5)

#define FLAG_ZCV (FLAG_Z | FLAG_C | FLAG_V)
#define FLAG_NZCV (FLAG_N | FLAG_ZCV)
#define FLAG_ALL (FLAG_NZCV | FLAG_A | FLAG_P)

namespace FEXCore::IR {

struct FlagInfoUnpacked {
  // Set of flags read by the instruction.
  unsigned Read;

  // Set of flags written by the instruction. Happens AFTER the reads.
  unsigned Write;

  // If true, the instruction can be be eliminated if its flag writes can all be
  // eliminated.
  bool CanEliminate;

  // If set, the opcode can be replaced with Replacement if its flag writes can
  // all be eliminated, or ReplacementNoWrite if its register write can be
  // eliminated.
  IROps Replacement;
  IROps ReplacementNoWrite;

  // Needs speical handling
  bool Special;
};

struct FlagInfo {
  uint64_t Raw;

  static constexpr struct FlagInfo Pack(struct FlagInfoUnpacked F) {
    uint64_t R = F.Read | (F.Write << 8) | (F.CanEliminate << 16) | (((uint64_t)F.Replacement) << 32) |
                 ((uint64_t)F.ReplacementNoWrite << 48) | (F.Special ? (1ull << 63) : 0);
    return {.Raw = R};
  }

  bool Trivial() const {
    return Raw == 0;
  }

  unsigned Read() const {
    return Bits(0, 8);
  }

  unsigned Write() const {
    return Bits(8, 8);
  }

  bool CanEliminate() const {
    return Bits(16, 1);
  }

  bool Special() const {
    return Bits(63, 1);
  }

  IROps Replacement() const {
    return (IROps)Bits(32, 16);
  }

  IROps ReplacementNoWrite() const {
    return (IROps)Bits(48, 16);
  }

private:
  unsigned Bits(unsigned Start, unsigned Count) const {
    return (Raw >> Start) & ((1u << Count) - 1);
  }
};

struct BlockInfo {
  fextl::vector<uint32_t> Predecessors;
  Ref Node;
  uint8_t Flags;
  bool InWorklist;
};

struct ControlFlowGraph {
  fextl::vector<BlockInfo> BlockMap;
  IRListView& IR;

  void Init(fextl::deque<uint32_t>& Worklist, uint32_t BlockCount) {
    BlockMap.resize(BlockCount);

    for (unsigned ID = 0; ID < BlockCount; ++ID) {
      // Add the block with conservative flags and already in the worklist.
      auto Info = BlockInfo {{}, nullptr, FLAG_ALL, true};

      // Add some initial capacity
      Info.Predecessors.reserve(2);

      BlockMap[ID] = std::move(Info);
      /* ⛔ ml621: the ml611 AllocWatch registration was REMOVED here. See
       * AllocWatch.h — it produced 71.9M events / 17.2M slot collisions and its
       * 512-line drain corrupted the exception record, killing ml620. */
      Worklist.push_back(ID);
    }
  }

  // iOS-Madeira ml605: EVERY BlockMap lookup is bounds-checked, and an out-of-range
  // ID lands on this sentinel instead of past the end of the vector.
  //
  // ml604 (db 7276) died here: switching Steam to Library gave the in-process
  // renderer new libcef code to translate, and DFE::Run+0x378 —
  //     AddWorklist -> Get(Pred) -> ldrb w9,[x8,#0x21]   (Info->InWorklist)
  // computed x8 = BlockMap.data() + Pred*40 = 0x97d8c32280 and faulted. That
  // address is outside EVERY legal band (guest <=0x73ffff0000, PA pools
  // [0x74,0x7c)G, FEX [0x7c,0x80)G), i.e. it was never a pointer — it is a bogus
  // *block ID* scaled by sizeof(BlockInfo). So the defect is an invalid CFG index,
  // NOT a wild IR-node pointer, and pointer-band heuristics would not have caught it.
  //
  // Note the structural hazard this guards: Init() sizes BlockMap from
  // IR header BlockCount, while Get() indexes by each block's own Block->ID.
  // If those ever disagree the very first Get(Block->ID) is already out of range.
  //
  // Sentinel semantics are deliberately CONSERVATIVE, so degrading is always safe:
  //   Flags = FLAG_ALL  -> readers believe every flag is live => nothing eliminated
  //   InWorklist = true -> AddWorklist never re-queues it => no infinite requeue
  BlockInfo Sentinel {{}, nullptr, FLAG_ALL, true};
  uint32_t BadIDs {0};
  uint32_t FirstBadID {~0u};
  uint32_t BadIDReports {0};

  bool IDValid(uint32_t Block) const {
    return Block < BlockMap.size();
  }

  BlockInfo* Get(uint32_t Block) {
    if (Block >= BlockMap.size()) [[unlikely]] {
      ++BadIDs;
      if (FirstBadID == ~0u) {
        FirstBadID = Block;
      }
      if (BadIDReports++ < 4) {
        LogMan::Msg::EFmt("[dfe-cfg] ml605 OUT-OF-RANGE block id {} (BlockMap.size()={}) "
                          "rip=0x{:x} -- returning conservative sentinel instead of "
                          "dereferencing BlockMap.data()+{}",
                          Block, BlockMap.size(), IR.GetHeader()->OriginalRIP,
                          (uint64_t)Block * sizeof(BlockInfo));
      }
      return &Sentinel;
    }
    return &BlockMap[Block];
  }

  BlockInfo* Get(IROp_CodeBlock* Block) {
    return Get(Block->ID);
  }

  BlockInfo* Get(OrderedNodeWrapper Block) {
    return Get(IR.GetOp<IR::IROp_CodeBlock>(Block));
  }

  void RecordEdge(uint32_t From, OrderedNodeWrapper To) {
    auto Info = Get(To);
    if (Info == &Sentinel) {
      return; // invalid edge target: drop the edge rather than record into scratch
    }

    // ml607: validate the value we push AND re-read it immediately afterwards.
    //
    // This is the discriminator ml606 needed. Every From here is a Block->ID and
    // ml606 confirmed all block IDs were valid (bad_block_ids=0, max_id=257 <
    // blockmap=258) — yet a predecessor slot came out holding 0xa8953b50, which
    // has the shape of a truncated pointer into the vector's own allocator slab
    // (data=0x7ca8950020). If From is valid going in and the slot is wrong
    // coming out, the writer is FOREIGN (allocator/heap corruption), not CFG
    // construction. That distinction decides which subsystem to chase.
    const bool FromValid = IDValid(From);
    if (!FromValid && EdgeReports < 4) {
      ++EdgeReports;
      LogMan::Msg::EFmt("[dfe-edge] ml607 PUSHING INVALID From={} (blockmap={}) rip=0x{:x} "
                        "-- CFG construction itself supplied a bad id",
                        From, BlockMap.size(), IR.GetHeader()->OriginalRIP);
    }

    const size_t Idx = Info->Predecessors.size();
    Info->Predecessors.push_back(From);

    if (FromValid && Info->Predecessors[Idx] != From && EdgeReports < 4) {
      ++EdgeReports;
      LogMan::Msg::EFmt("[dfe-edge] ml607 SLOT CHANGED UNDER US: pushed {} read back {} at index {} "
                        "(size={} cap={} data={}) rip=0x{:x} -- the value was VALID going in, so a "
                        "FOREIGN WRITER corrupted the vector, not CFG construction",
                        From, Info->Predecessors[Idx], Idx, Info->Predecessors.size(), Info->Predecessors.capacity(),
                        (void*)Info->Predecessors.data(), IR.GetHeader()->OriginalRIP);
    }

  }

  uint32_t EdgeReports {0};

  void AddWorklist(fextl::deque<uint32_t>& Worklist, uint32_t Block) {
    if (!IDValid(Block)) [[unlikely]] {
      Get(Block); // accounts + reports; never dereferences out of range
      return;     // skip this edge; the block keeps its conservative flags
    }
    auto Info = Get(Block);
    if (!Info->InWorklist) {
      Info->InWorklist = true;
      Worklist.push_front(Block);
    }
  }

  // Cheap order-sensitive digest of every predecessor list. Taken right after CFG
  // construction and again at the end: if it changes, something MUTATED the
  // predecessor vectors during the pass. That distinguishes "the CFG was built
  // wrong" from "the CFG was fine and DFE (or another writer) corrupted it".
  uint64_t PredecessorDigest() const {
    uint64_t h = 1469598103934665603ull;
    for (size_t b = 0; b < BlockMap.size(); ++b) {
      h = (h ^ (b + 0x9e3779b9ull)) * 1099511628211ull;
      for (uint32_t p : BlockMap[b].Predecessors) {
        h = (h ^ p) * 1099511628211ull;
      }
    }
    return h;
  }
};

class DeadFlagCalculationEliminination final : public FEXCore::IR::Pass {
public:
  void Run(IREmitter* IREmit) override;

private:
  FlagInfo Classify(IROp_Header* Node);
  unsigned FlagsForCondClassType(CondClass Cond);
  bool EliminateDeadCode(IREmitter* IREmit, Ref CodeNode, IROp_Header* IROp);
  void FoldBranch(IREmitter* IREmit, IRListView& CurrentIR, IROp_CondJump* Op, Ref CodeNode);
  CondClass X86ToArmFloatCond(CondClass X86);
  bool ProcessBlock(IREmitter* IREmit, IRListView& CurrentIR, Ref Block, ControlFlowGraph& CFG);
  void OptimizeParity(IREmitter* IREmit, IRListView& CurrentIR, ControlFlowGraph& CFG);
};

unsigned DeadFlagCalculationEliminination::FlagsForCondClassType(CondClass Cond) {
  switch (Cond) {
  case CondClass::AL: return 0;

  case CondClass::MI:
  case CondClass::PL: return FLAG_N;

  case CondClass::EQ:
  case CondClass::NEQ: return FLAG_Z;

  case CondClass::UGE:
  case CondClass::ULT: return FLAG_C;

  case CondClass::VS:
  case CondClass::VC:
  case CondClass::FU:
  case CondClass::FNU: return FLAG_V;

  case CondClass::UGT:
  case CondClass::ULE: return FLAG_Z | FLAG_C;

  case CondClass::SGE:
  case CondClass::SLT:
  case CondClass::FLU:
  case CondClass::FGE: return FLAG_N | FLAG_V;

  case CondClass::SGT:
  case CondClass::SLE:
  case CondClass::FLEU:
  case CondClass::FGT: return FLAG_N | FLAG_Z | FLAG_V;

  default: LOGMAN_THROW_A_FMT(false, "unknown cond class type"); return FLAG_NZCV;
  }
}

constexpr FlagInfo ClassifyConst(IROps Op) {
  switch (Op) {
  case OP_ANDWITHFLAGS:
    return FlagInfo::Pack({
      .Write = FLAG_NZCV,
      .Replacement = OP_AND,
      .ReplacementNoWrite = OP_TESTNZ,
    });

  case OP_ADDWITHFLAGS:
    return FlagInfo::Pack({
      .Write = FLAG_NZCV,
      .Replacement = OP_ADD,
      .ReplacementNoWrite = OP_ADDNZCV,
    });

  case OP_SUBWITHFLAGS:
    return FlagInfo::Pack({
      .Write = FLAG_NZCV,
      .Replacement = OP_SUB,
      .ReplacementNoWrite = OP_SUBNZCV,
    });

  case OP_ADCWITHFLAGS:
    return FlagInfo::Pack({
      .Read = FLAG_C,
      .Write = FLAG_NZCV,
      .Replacement = OP_ADC,
      .ReplacementNoWrite = OP_ADCNZCV,
    });

  case OP_ADCZEROWITHFLAGS:
    return FlagInfo::Pack({
      .Read = FLAG_C,
      .Write = FLAG_NZCV,
      .Replacement = OP_ADCZERO,
    });

  case OP_SBBWITHFLAGS:
    return FlagInfo::Pack({
      .Read = FLAG_C,
      .Write = FLAG_NZCV,
      .Replacement = OP_SBB,
      .ReplacementNoWrite = OP_SBBNZCV,
    });

  case OP_SHIFTFLAGS:
    // _ShiftFlags conditionally sets NZCV+PF, which we model here as a
    // read-modify-write. Logically, it also conditionally makes AF undefined,
    // which we model by omitting AF from both Read and Write sets (since
    // "cond ? AF : undef" may be optimized to "AF").
    return FlagInfo::Pack({
      .Read = FLAG_NZCV | FLAG_P,
      .Write = FLAG_NZCV | FLAG_P,
      .CanEliminate = true,
    });

  case OP_ROTATEFLAGS:
    // _RotateFlags conditionally sets CV, again modeled as RMW.
    return FlagInfo::Pack({
      .Read = FLAG_C | FLAG_V,
      .Write = FLAG_C | FLAG_V,
      .CanEliminate = true,
    });

  case OP_RDRAND: return FlagInfo::Pack({.Write = FLAG_NZCV});

  case OP_ADDNZCV:
  case OP_SUBNZCV:
  case OP_TESTNZ:
  case OP_FCMP:
  case OP_STORENZCV:
    return FlagInfo::Pack({
      .Write = FLAG_NZCV,
      .CanEliminate = true,
    });

  case OP_AXFLAG:
    // Per the Arm spec, axflag reads Z/V/C but not N. It writes all flags.
    return FlagInfo::Pack({
      .Read = FLAG_ZCV,
      .Write = FLAG_NZCV,
      .CanEliminate = true,
    });

  case OP_CMPPAIRZ:
    return FlagInfo::Pack({
      .Write = FLAG_Z,
      .CanEliminate = true,
    });

  case OP_CARRYINVERT:
    return FlagInfo::Pack({
      .Read = FLAG_C,
      .Write = FLAG_C,
      .CanEliminate = true,
    });

  case OP_SETSMALLNZV:
    return FlagInfo::Pack({
      .Write = FLAG_N | FLAG_Z | FLAG_V,
      .CanEliminate = true,
    });

  case OP_LOADNZCV: return FlagInfo::Pack({.Read = FLAG_NZCV});

  case OP_ADC:
  case OP_ADCZERO:
  case OP_SBB: return FlagInfo::Pack({.Read = FLAG_C});

  case OP_ADCNZCV:
  case OP_SBBNZCV:
    return FlagInfo::Pack({
      .Read = FLAG_C,
      .Write = FLAG_NZCV,
      .CanEliminate = true,
    });

  case OP_LOADPF: return FlagInfo::Pack({.Read = FLAG_P});
  case OP_LOADAF: return FlagInfo::Pack({.Read = FLAG_A});
  case OP_STOREPF: return FlagInfo::Pack({.Write = FLAG_P, .CanEliminate = true});
  case OP_STOREAF: return FlagInfo::Pack({.Write = FLAG_A, .CanEliminate = true});

  case OP_NZCVSELECT:
  case OP_NZCVSELECTV:
  case OP_NZCVSELECTINCREMENT:
  case OP_NEG:
  case OP_CONDJUMP:
  case OP_CONDSUBNZCV:
  case OP_CONDADDNZCV:
  case OP_RMIFNZCV:
  case OP_INVALIDATEFLAGS: return FlagInfo::Pack({.Special = true});
  default: return FlagInfo::Pack({});
  }
}

constexpr auto FlagInfos = std::invoke([] {
  std::array<FlagInfo, OP_LAST> ret = {};

  for (unsigned i = 0; i < OP_LAST; ++i) {
    ret[i] = ClassifyConst((IROps)i);
  }

  return ret;
});

FlagInfo DeadFlagCalculationEliminination::Classify(IROp_Header* IROp) {
  FlagInfo Info = FlagInfos[IROp->Op];
  if (!Info.Special()) {
    return Info;
  }

  switch (IROp->Op) {
  case OP_NZCVSELECT:
  case OP_NZCVSELECTINCREMENT: {
    auto Op = IROp->CW<IR::IROp_NZCVSelect>();
    return FlagInfo::Pack({.Read = FlagsForCondClassType(Op->Cond)});
  }

  case OP_NZCVSELECTV: {
    auto Op = IROp->CW<IR::IROp_NZCVSelectV>();
    return FlagInfo::Pack({.Read = FlagsForCondClassType(Op->Cond)});
  }

  case OP_NEG: {
    auto Op = IROp->CW<IR::IROp_Neg>();
    return FlagInfo::Pack({.Read = FlagsForCondClassType(Op->Cond)});
  }

  case OP_CONDJUMP: {
    auto Op = IROp->CW<IR::IROp_CondJump>();
    if (!Op->FromNZCV) {
      return FlagInfo::Pack({});
    }

    return FlagInfo::Pack({.Read = FlagsForCondClassType(Op->Cond)});
  }

  case OP_CONDSUBNZCV:
  case OP_CONDADDNZCV: {
    auto Op = IROp->CW<IR::IROp_CondAddNZCV>();
    return FlagInfo::Pack({
      .Read = FlagsForCondClassType(Op->Cond),
      .Write = FLAG_NZCV,
      .CanEliminate = true,
    });
  }

  case OP_RMIFNZCV: {
    auto Op = IROp->CW<IR::IROp_RmifNZCV>();

    static_assert(FLAG_N == (1 << 3), "rmif mask lines up with our bits");
    static_assert(FLAG_Z == (1 << 2), "rmif mask lines up with our bits");
    static_assert(FLAG_C == (1 << 1), "rmif mask lines up with our bits");
    static_assert(FLAG_V == (1 << 0), "rmif mask lines up with our bits");

    return FlagInfo::Pack({
      .Write = Op->Mask,
      .CanEliminate = true,
    });
  }

  case OP_INVALIDATEFLAGS: {
    auto Op = IROp->CW<IR::IROp_InvalidateFlags>();
    unsigned Flags = 0;

    // TODO: Make this translation less silly
    if (Op->Flags & (1u << X86State::RFLAG_SF_RAW_LOC)) {
      Flags |= FLAG_N;
    }

    if (Op->Flags & (1u << X86State::RFLAG_ZF_RAW_LOC)) {
      Flags |= FLAG_Z;
    }

    if (Op->Flags & (1u << X86State::RFLAG_CF_RAW_LOC)) {
      Flags |= FLAG_C;
    }

    if (Op->Flags & (1u << X86State::RFLAG_OF_RAW_LOC)) {
      Flags |= FLAG_V;
    }

    if (Op->Flags & (1u << X86State::RFLAG_PF_RAW_LOC)) {
      Flags |= FLAG_P;
    }

    if (Op->Flags & (1u << X86State::RFLAG_AF_RAW_LOC)) {
      Flags |= FLAG_A;
    }

    // The mental model of InvalidateFlags is writing undefined values to all
    // of the selected flags, allowing the write-after-write optimizations to
    // optimize invalidate-after-write for free.
    return FlagInfo::Pack({
      .Write = Flags,
      .CanEliminate = true,
    });
  }

  default: LOGMAN_THROW_A_FMT(false, "invalid special op"); FEX_UNREACHABLE;
  }

  FEX_UNREACHABLE;
}

// General purpose dead code elimination. Returns whether flag handling should
// be skipped (because it was removed or could not possibly affect flags).
bool DeadFlagCalculationEliminination::EliminateDeadCode(IREmitter* IREmit, Ref CodeNode, IROp_Header* IROp) {
  // Can't remove anything used or with side effects.
  if (CodeNode->GetUses() > 0 || IR::HasSideEffects(IROp->Op)) {
    return false;
  }

  IREmit->Remove(CodeNode);
  return true;
}

CondClass DeadFlagCalculationEliminination::X86ToArmFloatCond(CondClass X86) {
  // Table of x86 condition codes that map to arm64 condition codes, in the
  // sense that fcmp+axflag+branch(x86) is equivalent to fcmp+branch(arm).
  //
  // E would be "equal or unordered", no condition code.
  // G would be "greater than or less than", no condition code.
  //
  // SF/OF conditions are trivial and therefore shouldn't actually be generated
  switch (X86) {
  case CondClass::UGE /* A  */: return CondClass::FGE /* GE */;
  case CondClass::UGT /* AE */: return CondClass::FGT /* GT */;
  case CondClass::ULT /* B  */: return CondClass::SLT /* LT */;
  case CondClass::ULE /* BE */: return CondClass::SLE /* LE */;
  case CondClass::SLE /* LE */: return CondClass::SLE /* LE */;
  default: return CondClass::AL;
  }
}

void DeadFlagCalculationEliminination::FoldBranch(IREmitter* IREmit, IRListView& CurrentIR, IROp_CondJump* Op, Ref CodeNode) {
  // Skip past StoreRegisters at the end -- they don't touch flags.
  auto PrevWrap = CodeNode->Header.Previous;
  while (CurrentIR.GetOp<IR::IROp_Header>(PrevWrap)->Op == OP_STOREREGISTER ||
         CurrentIR.GetOp<IR::IROp_Header>(PrevWrap)->Op == OP_STOREPF || CurrentIR.GetOp<IR::IROp_Header>(PrevWrap)->Op == OP_STOREAF) {
    PrevWrap = CurrentIR.GetNode(PrevWrap)->Header.Previous;
  }

  auto Prev = CurrentIR.GetOp<IR::IROp_Header>(PrevWrap);
  if (Prev->Op == OP_AXFLAG) {
    // Pattern match a branch fed by AXFLAG.
    CondClass ArmCond = X86ToArmFloatCond(Op->Cond);
    if (ArmCond == CondClass::AL) {
      return;
    }

    Op->Cond = ArmCond;
  } else if (Prev->Op == OP_SUBNZCV) {
    // Pattern match a branch fed by a compare. We could also handle bit tests
    // here, but tbz/tbnz has a limited offset range which we don't have a way to
    // deal with yet. Let's hope that's not a big deal.
    if (!(Op->Cond == CondClass::NEQ || Op->Cond == CondClass::EQ) || (Prev->Size < OpSize::i32Bit)) {
      return;
    }

    auto SecondArg = CurrentIR.GetOp<IR::IROp_Header>(Prev->Args[1]);
    if (SecondArg->Op != OP_INLINECONSTANT || SecondArg->C<IR::IROp_InlineConstant>()->Constant != 0) {
      return;
    }

    // We've matched. Fold the compare into branch.
    IREmit->ReplaceNodeArgument(CodeNode, 0, CurrentIR.GetNode(Prev->Args[0]));
    IREmit->ReplaceNodeArgument(CodeNode, 1, CurrentIR.GetNode(Prev->Args[1]));
    Op->FromNZCV = false;
    Op->CompareSize = Prev->Size;
  } else {
    return;
  }

  // The compare/test/axflag sets flags but does not write registers. Flags are
  // dead after the jump. The jump does not read flags anymore.  There is no
  // intervening instruction. Therefore the compare is dead.
  IREmit->Remove(CurrentIR.GetNode(PrevWrap));
}

/**
 * @brief This pass removes dead code locally.
 */
bool DeadFlagCalculationEliminination::ProcessBlock(IREmitter* IREmit, IRListView& CurrentIR, Ref Block, ControlFlowGraph& CFG) {
  uint32_t FlagsRead = FLAG_ALL;

  // Reverse iteration is not yet working with the iterators
  auto BlockIROp = CurrentIR.GetOp<IR::IROp_CodeBlock>(Block);

  // iOS-Madeira ml599: VALIDATE BEFORE MUTATING.
  //
  // ml597 bounded the reverse walk below and ml598 saw it fire (block 405,
  // 13,183 steps). But that bound trips only AFTER the walk has already called
  // IREmit->Remove() thousands of times, so "skip the rest" left half-optimized
  // IR behind and the register allocator then hung on the same block. Checking
  // the structure up front means we either fix it or never touch it.
  // ml599b: the CHEAP check on the healthy path. The full diagnostic (forward
  // walk + Floyd + reciprocity) runs only when this one trips, because ml599
  // proved the full version on every block is ruinously expensive.
  IRTopoNoteChecked();
  if (!QuickBackwardOK(CurrentIR, Block)) {
    if (HandleSuspectBlock("dfe-entry", CurrentIR, Block) == IRTopoAction::Skip) {
      return false;
    }
  }

  // We grab these nodes this way so we can iterate easily
  auto CodeBegin = CurrentIR.at(BlockIROp->Begin);
  auto CodeLast = CurrentIR.at(BlockIROp->Last);

  // Advance past EndBlock to get at the exit.
  --CodeLast;

  // Initialize the FlagsRead mask according to the exit instruction.
  auto [ExitNode, ExitOp] = CodeLast();
  if (ExitOp->Op == IR::OP_CONDJUMP) {
    auto Op = ExitOp->CW<IR::IROp_CondJump>();
    FlagsRead = CFG.Get(Op->TrueBlock)->Flags | CFG.Get(Op->FalseBlock)->Flags;
  } else if (ExitOp->Op == IR::OP_JUMP) {
    FlagsRead = CFG.Get(ExitOp->Args[0])->Flags;
  }

  // iOS-Madeira ml597/ml599: BOUND THE REVERSE WALK (backstop).
  //
  // This walk terminates only by reaching CodeBegin, so a cyclic or truncated
  // Previous chain spins forever holding a fexlock read reference and stalls
  // every other FEX thread. That was the ml594/ml598 hang.
  //
  // As of ml599 the entry check above has already PROVEN this chain reaches
  // CodeBegin, so this bound should now be unreachable. That makes it a
  // discriminator rather than a duplicate: entry validated clean but the walk
  // still ran away means DFE's own IREmit->Remove() calls are what corrupt the
  // list -- which would make this pass the corrupter, not a victim of it.
  const uint32_t IRNodeBudget = CurrentIR.GetSSACount() + 16;
  uint32_t StepsTaken = 0;

  // Iterate the block in reverse
  while (true) {
    if (++StepsTaken > IRNodeBudget) {
      LogMan::Msg::EFmt("[dfe-guard] ml599: reverse walk exceeded {} steps in block {} AFTER a "
                        "clean entry validation -- DFE ITSELF corrupted the Previous/Next chain "
                        "while removing nodes; skipping the rest of this block",
                        IRNodeBudget, BlockIROp->ID);
      return false;
    }
    auto [CodeNode, IROp] = CodeLast();

    // Optimizing flags can cause earlier flag reads to become dead but dead
    // flag reads should not impede optimiation of earlier dead flag writes.
    // We must DCE as we go to ensure we converge in a single iteration.
    if (!EliminateDeadCode(IREmit, CodeNode, IROp)) {
      // Optimiation algorithm: For each flag written...
      //
      //  If the flag has a later read (per FlagsRead), remove the flag from
      //  FlagsRead, since the reader is covered by this write.
      //
      //  Else, there is no later read, so remove the flag write (if we can).
      //  This is the active part of the optimization.
      //
      // Then, add each flag read to FlagsRead.
      //
      // This order is important: instructions that read-modify-write flags
      // (like adcs) first read flags, then write flags. Since we're iterating
      // the block backwards, that means we handle the write first.
      struct FlagInfo Info = Classify(IROp);

      if (!Info.Trivial()) {
        bool Eliminated = false;

        if ((FlagsRead & Info.Write()) == 0) {
          if ((Info.CanEliminate() || Info.Replacement()) && CodeNode->GetUses() == 0) {
            IREmit->Remove(CodeNode);
            Eliminated = true;
          } else if (Info.Replacement()) {
            IROp->Op = Info.Replacement();
          }
        } else if (Info.ReplacementNoWrite() && CodeNode->GetUses() == 0) {
          IROp->Op = Info.ReplacementNoWrite();
        }

        // If we don't care about the sign or carry, we can optimize testnz.
        // Carry is inverted between testz and testnz so we check that too. Note
        // this flag is outside of the if, since the TestNZ might result from
        // optimizing AndWithFlags, and we need to converge locally in a single
        // iteration.
        if (IROp->Op == OP_TESTNZ && IROp->Size < OpSize::i32Bit && !(FlagsRead & (FLAG_N | FLAG_C))) {
          IROp->Op = OP_TESTZ;
        }

        FlagsRead &= ~Info.Write();

        // If we eliminated the instruction, we eliminate its read too. This
        // check is required to ensure the pass converges locally in a single
        // iteration.
        if (!Eliminated) {
          FlagsRead |= Info.Read();
        }
      }
    }

    // Iterate in reverse
    if (CodeLast == CodeBegin) {
      break;
    }
    --CodeLast;
  }

  // For the purposes of global propagation, the content of our progress doesn't
  // matter -- only the difference in our final FlagsRead contributes to changes
  // in the predecessors.
  uint32_t OldFlagsRead = CFG.Get(BlockIROp->ID)->Flags;
  CFG.Get(BlockIROp->ID)->Flags = FlagsRead;
  return (OldFlagsRead != FlagsRead);
}

void DeadFlagCalculationEliminination::OptimizeParity(IREmitter* IREmit, IRListView& CurrentIR, ControlFlowGraph& CFG) {
  // Mapping for flags inside this pass.
  const uint8_t PARTIAL = 0;
  const uint8_t FULL = 1;

  // Initialize conservatively: all blocks need full parity. This initialization
  // matters for proper handling of backedges.
  for (auto [Block, BlockHeader] : CurrentIR.GetBlocks()) {
    auto ID = BlockHeader->C<IROp_CodeBlock>()->ID;
    CFG.Get(ID)->Flags = FULL;
  }

  for (auto [Block, BlockHeader] : CurrentIR.GetBlocks()) {
    const auto ID = BlockHeader->C<IROp_CodeBlock>()->ID;
    const auto& Predecessors = CFG.Get(ID)->Predecessors;
    bool Full = false;

    if (Predecessors.empty()) {
      // Conservatively assume there was full parity before the start block
      Full = true;
    } else {
      // If any predecessor needs full parity at the end, we need full parity.
      for (auto Pred : Predecessors) {
        Full |= (CFG.Get(Pred)->Flags == FULL);
      }
    }

    for (auto [CodeNode, IROp] : CurrentIR.GetCode(Block)) {
      if (IROp->Op == OP_STOREPF) {
        auto Op = IROp->CW<IR::IROp_StorePF>();
        auto Generator = CurrentIR.GetOp<IR::IROp_Header>(Op->Value);

        // Determine if we only write 0/1 to the parity flag.
        Full = true;
        if (Generator->Op == OP_NZCVSELECT) {
          auto C0 = CurrentIR.GetOp<IR::IROp_Header>(Generator->Args[0]);
          auto C1 = CurrentIR.GetOp<IR::IROp_Header>(Generator->Args[1]);
          if (C0->Op == C1->Op && C0->Op == OP_INLINECONSTANT) {
            auto IC0 = CurrentIR.GetOp<IR::IROp_InlineConstant>(Generator->Args[0]);
            auto IC1 = CurrentIR.GetOp<IR::IROp_InlineConstant>(Generator->Args[1]);

            // We need the full 8 if the constant has upper bits set.
            Full = (IC0->Constant | IC1->Constant) & ~1;
          }
        }
      } else if (IROp->Op == OP_PARITY && !Full) {
        // Eliminate parity calculations if it's only 1-bit.
        auto Parity = IROp->C<IROp_Parity>();
        Ref Value = CurrentIR.GetNode(Parity->Raw);

        if (Parity->Invert) {
          IREmit->SetWriteCursor(CodeNode);
          Value = IREmit->_Xor(OpSize::i32Bit, Value, IREmit->_InlineConstant(1));
        }

        IREmit->ReplaceUsesWithAfter(CodeNode, Value, CurrentIR.at(CodeNode));
        IREmit->Remove(CodeNode);
      }
    }

    // Record our final state for our successors to read.
    CFG.Get(ID)->Flags = Full ? FULL : PARTIAL;
  }
}

void DeadFlagCalculationEliminination::Run(IREmitter* IREmit) {
  FEXCORE_PROFILE_SCOPED("PassManager::DFE");

  auto CurrentIR = IREmit->ViewIR();
  fextl::deque<uint32_t> Worklist;

  // Initialize CFG
  ControlFlowGraph CFG {.IR = CurrentIR};
  CFG.Init(Worklist, CurrentIR.GetHeader()->BlockCount);

  // Gather CFG
  for (auto [BlockNode, BlockHeader] : CurrentIR.GetBlocks()) {
    auto Block = BlockHeader->C<IROp_CodeBlock>();
    auto CodeLast = CurrentIR.at(Block->Last);
    --CodeLast;
    auto [ExitNode, ExitOp] = CodeLast();
    if (ExitOp->Op == IR::OP_CONDJUMP) {
      auto Op = ExitOp->CW<IR::IROp_CondJump>();

      CFG.RecordEdge(Block->ID, Op->TrueBlock);
      CFG.RecordEdge(Block->ID, Op->FalseBlock);
    } else if (ExitOp->Op == IR::OP_JUMP) {
      CFG.RecordEdge(Block->ID, ExitOp->Args[0]);
    }

    CFG.Get(Block->ID)->Node = BlockNode;
  }

  // iOS-Madeira ml605: SEMANTIC CFG VALIDATION, once, right after construction.
  //
  // Answers the question the ml604 crash could not: was the CFG born invalid
  // (emitter / block-ID gather supplied bad IDs) or did it become invalid while
  // the pass ran? Everything below is O(blocks + edges) and only logs on failure.
  const uint64_t PredDigestAtBuild = CFG.PredecessorDigest();
  {
    const uint32_t HeaderBlockCount = CurrentIR.GetHeader()->BlockCount;
    uint32_t MaxSeenID = 0, Enumerated = 0, BadPreds = 0, BadBlockIDs = 0;

    for (auto [BlockNode, BlockHeader] : CurrentIR.GetBlocks()) {
      auto Block = BlockHeader->C<IROp_CodeBlock>();
      ++Enumerated;
      if (Block->ID > MaxSeenID) {
        MaxSeenID = Block->ID;
      }
      if (!CFG.IDValid(Block->ID)) {
        ++BadBlockIDs;
      }
    }
    for (size_t b = 0; b < CFG.BlockMap.size(); ++b) {
      for (uint32_t p : CFG.BlockMap[b].Predecessors) {
        if (!CFG.IDValid(p)) {
          if (!BadPreds) {
            const auto& V = CFG.BlockMap[b].Predecessors;
            LogMan::Msg::EFmt("[dfe-cfg] ml605 BAD PREDECESSOR pred={} in block={} "
                              "blockmap={} header_blockcount={} enumerated={} max_id={} "
                              "rip=0x{:x} predvec(size={} cap={} data={})",
                              p, b, CFG.BlockMap.size(), HeaderBlockCount, Enumerated, MaxSeenID,
                              CurrentIR.GetHeader()->OriginalRIP, V.size(), V.capacity(), (void*)V.data());
          }
          ++BadPreds;
        }
      }
    }

    // ml611 (3): the old test (Enumerated == HeaderBlockCount && MaxSeenID <
    // size) does NOT prove the IDs are a unique 0..N-1 permutation — a set with
    // one duplicate and one gap passes it. Check uniqueness, gaps, and the Node
    // pointer that ProcessBlock will actually dereference.
    uint32_t DupIDs = 0, MissingIDs = 0, NullNodes = 0, BadWorklistIDs = 0;
    {
      fextl::vector<uint8_t> Seen(CFG.BlockMap.size(), 0);
      for (auto [BlockNode, BlockHeader] : CurrentIR.GetBlocks()) {
        auto Block = BlockHeader->C<IROp_CodeBlock>();
        if (CFG.IDValid(Block->ID)) {
          if (Seen[Block->ID]) {
            ++DupIDs;
          }
          Seen[Block->ID] = 1;
        }
      }
      for (size_t b = 0; b < CFG.BlockMap.size(); ++b) {
        if (!Seen[b]) {
          ++MissingIDs;
        }
        // THE field that killed ml610: Get() hands a caller Info->Node, and the
        // out-of-range sentinel's Node is nullptr.
        if (CFG.BlockMap[b].Node == nullptr) {
          ++NullNodes;
        }
      }
      // ml611: the worklist is a separate container (deque) from BlockMap, so it
      // can be corrupted independently. Validate every entry now, so a later
      // failure can be attributed to propagation rather than to gather.
      for (uint32_t W : Worklist) {
        if (!CFG.IDValid(W)) {
          ++BadWorklistIDs;
        }
      }
    }

    if (BadBlockIDs || BadPreds || Enumerated != HeaderBlockCount || MaxSeenID >= CFG.BlockMap.size() || DupIDs || MissingIDs ||
        NullNodes || BadWorklistIDs) {
      // ml607: DO NOT say "born bad" here. This check runs immediately after
      // gather, so all it establishes is "already bad by then" — it cannot tell
      // an invalid EDGE from memory corrupted DURING gathering. ml606 showed the
      // difference matters: every pushed From was a valid block ID, yet a
      // predecessor slot held pointer debris, and the digest ALSO changed during
      // propagation. That is a foreign writer, not bad CFG construction.
      LogMan::Msg::EFmt("[dfe-cfg] ml611 CFG INVALID BY END OF GATHER: bad_block_ids={} bad_preds={} "
                        "dup_ids={} missing_ids={} null_nodes={} bad_worklist_ids={} "
                        "enumerated={} header_blockcount={} max_id={} blockmap={} rip=0x{:x} "
                        "-- ABANDONING this DFE invocation before touching IR (true no-op: gather "
                        "is read-only, so the block simply keeps every flag calculation)",
                        BadBlockIDs, BadPreds, DupIDs, MissingIDs, NullNodes, BadWorklistIDs, Enumerated, HeaderBlockCount,
                        MaxSeenID, CFG.BlockMap.size(), CurrentIR.GetHeader()->OriginalRIP);
      FEXCore::Utils::AllocWatch::Clear();  // ml621: no drain — see AllocWatch.h
      return;
    }
  }

  // After processing a block, if we made progress, we must process its
  // predecessors to propagate globally. A block will be reprocessed only if
  // there is a loop backedge.
  // iOS-Madeira ml597: BOUND THE WORKLIST TOO — the second way this pass can fail
  // to terminate. Blocks are re-queued whenever their flag set changes, so if the
  // dataflow never reaches a fixed point the queue refills forever even though the
  // per-block walk above is healthy. Bounding both separates the two causes: a
  // [dfe-guard] "reverse walk" message means a corrupt intrusive list, a "worklist"
  // message means non-converging dataflow. Same fail-open rule.
  const uint64_t WorklistBudget = (uint64_t)CurrentIR.GetSSACount() * 64 + 4096;
  uint64_t WorklistSteps = 0;

  for (; !Worklist.empty(); Worklist.pop_back()) {
    auto Block = Worklist.back();

    // ml611 (2): RE-VALIDATE AT EVERY POP, and ABORT THE WHOLE INVOCATION on any
    // failure — do not merely skip the bad entry.
    //
    // This is the ml610 crash. CFG.Get() returns &Sentinel for an out-of-range id,
    // Sentinel.Node is nullptr, and the old code passed Info->Node straight into
    // ProcessBlock(), which dereferences it at its 7th instruction
    // (libarm64ecfex.dll+0xfe608, `ldr w10,[x3]`, x3=0). The ml605 sentinel did not
    // contain that failure, it CONVERTED an out-of-bounds read into a null deref.
    //
    // Skipping the entry is not good enough: once any id or Node is invalid the
    // whole CFG is untrustworthy, and continuing could eliminate flags on the
    // strength of propagation that never completed.
    //
    // ⚠️ HONEST SCOPE: unlike the end-of-gather bail this is NOT a true no-op.
    // Earlier ProcessBlock() calls in this same invocation may already have removed
    // instructions, and returning cannot undo them. It prevents the crash and stops
    // further damage; it does not restore the block. A proper recovery would
    // re-compile this guest block from fresh IR with DFE disabled, which the
    // compiler cannot currently be asked to do from here.
    if (!CFG.IDValid(Block) || CFG.Get(Block)->Node == nullptr) {
      LogMan::Msg::EFmt("[dfe-cfg] ml611 INVALID WORKLIST ENTRY at pop: block={} (blockmap={}) "
                        "node={} slot_addr={} steps={} rip=0x{:x} -- the CFG passed end-of-gather "
                        "validation, so this was corrupted DURING propagation; ABANDONING "
                        "(⚠️ not a no-op: {} blocks were already processed and any flag "
                        "calculations they removed stay removed)",
                        Block, CFG.BlockMap.size(), (void*)(CFG.IDValid(Block) ? CFG.Get(Block)->Node : nullptr),
                        (void*)&Worklist.back(), WorklistSteps, CurrentIR.GetHeader()->OriginalRIP, WorklistSteps);
      FEXCore::Utils::AllocWatch::Clear();  // ml621: no drain — see AllocWatch.h
      return;
    }

    auto Info = CFG.Get(Block);
    Info->InWorklist = false;

    if (++WorklistSteps > WorklistBudget) {
      LogMan::Msg::EFmt("[dfe-guard] ml597: CFG worklist exceeded {} iterations "
                        "(last block {}) -- flag dataflow is not converging; abandoning "
                        "global propagation (fail-open)",
                        WorklistBudget, Block);
      break;
    }

    if (ProcessBlock(IREmit, CurrentIR, Info->Node, CFG)) {
      for (auto Pred : Info->Predecessors) {
        CFG.AddWorklist(Worklist, Pred);
      }
    }
  }

  // ml605: did the predecessor lists change under us? Built-valid + changed-here
  // means DFE (or something running concurrently) corrupted them; built-invalid
  // was already reported above. Either way the sentinel kept us alive.
  if (CFG.PredecessorDigest() != PredDigestAtBuild) {
    LogMan::Msg::EFmt("[dfe-cfg] ml605 PREDECESSOR LISTS MUTATED during propagation "
                      "(rip=0x{:x} blocks={}) -- the CFG was valid at build and something "
                      "wrote to it while the pass ran",
                      CurrentIR.GetHeader()->OriginalRIP, CFG.BlockMap.size());
    // ml611: this is the case the allocation trace exists for — the CFG was born
    // clean and changed underneath us. Dump who touched those buffers.
    FEXCore::Utils::AllocWatch::Clear();  // ml621: no drain — see AllocWatch.h
  } else {
    // Uneventful run: drop the watches silently so the table does not accumulate
    // stale entries across compilations.
    FEXCore::Utils::AllocWatch::Clear();
  }
  if (CFG.BadIDs) {
    LogMan::Msg::EFmt("[dfe-cfg] ml605 summary: {} out-of-range block id(s), first={}, "
                      "blockmap={} rip=0x{:x} -- all served the conservative sentinel, "
                      "so flags stayed FLAG_ALL and nothing was eliminated for them",
                      CFG.BadIDs, CFG.FirstBadID, CFG.BlockMap.size(),
                      CurrentIR.GetHeader()->OriginalRIP);
  }

  // Fold compares into branches now that we're otherwise optimized. This needs
  // to run after eliminating carries etc and it needs the global flag metadata.
  // But it only needs to run once, we don't do it in the loop.
  for (auto [Block, _] : CurrentIR.GetBlocks()) {
    // Grab the jump
    auto BlockIROp = CurrentIR.GetOp<IR::IROp_CodeBlock>(Block);
    auto CodeLast = CurrentIR.at(BlockIROp->Last);
    --CodeLast;

    auto [ExitNode, ExitOp] = CodeLast();
    if (ExitOp->Op == IR::OP_CONDJUMP) {
      auto Op = ExitOp->CW<IR::IROp_CondJump>();
      uint32_t FlagsOut = CFG.Get(Op->TrueBlock)->Flags | CFG.Get(Op->FalseBlock)->Flags;

      if ((FlagsOut & FLAG_NZCV) == 0 && Op->FromNZCV) {
        FoldBranch(IREmit, CurrentIR, Op, ExitNode);
      }
    }
  }

  if (CurrentIR.GetHeader()->ReadsParity) {
    OptimizeParity(IREmit, CurrentIR, CFG);
  }
}

fextl::unique_ptr<Pass> CreateDeadFlagCalculationEliminination() {
  return fextl::make_unique<DeadFlagCalculationEliminination>();
}

} // namespace FEXCore::IR
