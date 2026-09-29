// SPDX-License-Identifier: MIT
/*
$info$
meta: ir|opts ~ IR to IR Optimization
tags: ir|opts
desc: Defines which passes are run, and runs them
$end_info$
*/

#include "Interface/Context/Context.h"
#include <cstdio>    // ml599: snprintf for the [ir-topo] sweep labels
#include <cstdlib>   // ml597: getenv for the MADEIRA_NO_DFE gate
#include "Interface/IR/IREmitter.h"
#include "Interface/IR/IRTopologyCheck.h"
#include "Interface/IR/PassManager.h"
#include "Interface/IR/Passes.h"
#include "Interface/IR/Passes/RegisterAllocationPass.h"

#include <FEXCore/Config/Config.h>
#include <FEXCore/Utils/LogManager.h>
#include <FEXCore/Utils/Profiler.h>
#include <FEXCore/fextl/sstream.h>  // ml623: targeted IR capture
#include <FEXCore/fextl/string.h>
#include <FEXCore/fextl/vector.h>

#include <algorithm>
#include <atomic>
#include <string_view>

namespace FEXCore::IR {

void PassManager::Finalize() {
  if (!PassManagerDumpIR()) {
    // Not configured to dump any IR, just return.
    return;
  }

  auto it = Passes.begin();
  // Walk the passes and add them where asked.
  if (PassManagerDumpIR() & FEXCore::Config::PassManagerDumpIR::BEFOREOPT) {
    // Insert at the start.
    it = InsertAt(it, Debug::CreateIRDumper());
    ++it; // Skip what we inserted.
  }

  if ((PassManagerDumpIR() & FEXCore::Config::PassManagerDumpIR::BEFOREPASS) ||
      (PassManagerDumpIR() & FEXCore::Config::PassManagerDumpIR::AFTERPASS)) {

    bool SkipFirstBefore = PassManagerDumpIR() & FEXCore::Config::PassManagerDumpIR::BEFOREOPT;
    for (; it != Passes.end();) {
      if (PassManagerDumpIR() & FEXCore::Config::PassManagerDumpIR::BEFOREPASS) {
        if (SkipFirstBefore) {
          // If we need to skip the first one, then continue.
          SkipFirstBefore = false;
          ++it;
          continue;
        }

        // Insert before
        it = InsertAt(it, Debug::CreateIRDumper());
        ++it; // Skip what we inserted.
      }

      ++it; // Skip current pass.
      if (PassManagerDumpIR() & FEXCore::Config::PassManagerDumpIR::AFTERPASS) {
        // Insert after
        it = InsertAt(it, Debug::CreateIRDumper());
        ++it; // Skip what we inserted.
      }
    }
  }
  if (PassManagerDumpIR() & FEXCore::Config::PassManagerDumpIR::AFTEROPT) {
    if (!(PassManagerDumpIR() & FEXCore::Config::PassManagerDumpIR::AFTERPASS)) {
      // Insert final IRDumper.
      InsertAt(Passes.end(), Debug::CreateIRDumper());
    }
  }
}

void PassManager::AddDefaultPasses(FEXCore::Context::ContextImpl* ctx) {
  FEX_CONFIG_OPT(DisablePasses, O0);

  if (!DisablePasses()) {
    InsertPass(CreateX87StackOptimizationPass(ctx->HostFeatures, ctx->Config.Is64BitMode ? IR::OpSize::i64Bit : IR::OpSize::i32Bit));

    // iOS-Madeira ml597: TARGETED A/B for the ml594 post-login hang. The renderer
    // thread was sampled 9x at 97-100% CPU inside DeadFlagCalculationEliminination
    // while everything else idled and Steam presented no further frames.
    //
    // FEX_O0 is the wrong instrument for convicting it: it drops the x87 pass too,
    // so a pass implicates one of two things and a failure exonerates neither.
    // MADEIRA_NO_DFE removes ONLY this pass, leaving the rest of the pipeline —
    // including x87 — exactly as it is in a known-good run. Env-gated rather than
    // compiled out so both arms come from one FEX build.
    //   set  -> hang disappears  => this pass is the cause
    //   set  -> hang persists    => exonerated, look elsewhere in the compile path
    // The [dfe-guard] bounds in the pass itself remain active either way and will
    // name the failure mode (cyclic list vs non-converging dataflow) if it recurs.
    const char* NoDFE = getenv("MADEIRA_NO_DFE");
    if (NoDFE && *NoDFE && *NoDFE != '0') {
      LogMan::Msg::EFmt("[dfe-guard] ml597: MADEIRA_NO_DFE set — DeadFlagCalculationEliminination DISABLED");
    } else {
      InsertPass(CreateDeadFlagCalculationEliminination());
    }
  }
}

void PassManager::AddDefaultValidationPasses() {
#if defined(ASSERTIONS_ENABLED) && ASSERTIONS_ENABLED
  InsertValidationPass(Validation::CreateIRValidation(), "IRValidation");
#endif
}

void PassManager::InsertRegisterAllocationPass(FEXCore::Context::ContextImpl* ctx) {
  InsertPass(IR::CreateRegisterAllocationPass(&ctx->CPUID), "RA");
}

namespace {
// iOS-Madeira ml599: name the pass that breaks the intrusive node list.
//
// DFE and RA both detect corruption at their own entry, but by then the damage
// is upstream and anonymous. This sweeps every block after every pass and
// reports the FIRST pass at which a block stops validating, which converts
// "the IR is corrupt" into "pass N corrupts it".
//
// Off by default: it walks every block twice per pass, which is real cost on a
// 13,000-node function. Set MADEIRA_IR_TOPO=1 for a diagnostic run.
bool IRTopoSweepEnabled() {
  static const bool Enabled = [] {
    const char* E = getenv("MADEIRA_IR_TOPO");
    return E && *E && *E != '0';
  }();
  return Enabled;
}

// ml599b: only sweep BIG functions.
//
// ml599 swept every block after every pass on every compile and that alone
// stalled the renderer -- it spent as much time in ValidateBlockTopology as in
// the whole x86 decoder, and Steam never reached the UI it had reached the run
// before. The corruption we are hunting lives in a ~13,167-node multiblock
// region, so almost every compile in the program is irrelevant to it. Gating on
// SSA count keeps the attribution while dropping essentially all of the cost.
uint32_t IRTopoSweepMinSSA() {
  static const uint32_t Min = [] {
    const char* E = getenv("MADEIRA_IR_TOPO_MIN");
    const long V = (E && *E) ? strtol(E, nullptr, 0) : 0;
    return static_cast<uint32_t>(V > 0 ? V : 2048);
  }();
  return Min;
}

// Returns true when corruption was found (caller stops sweeping this compile:
// every later pass would report the same damage and flood the log).
bool SweepBlockTopology(IREmitter* IREmit, int PassIndex) {
  auto IR = IREmit->ViewIR();

  for (auto [BlockNode, BlockHeader] : IR.GetBlocks()) {
    (void)BlockHeader;
    if (!QuickBackwardOK(IR, BlockNode)) {
      char Where[48];
      if (PassIndex < 0) {
        snprintf(Where, sizeof(Where), "sweep/post-emit");
      } else {
        snprintf(Where, sizeof(Where), "sweep/after-pass-%d", PassIndex);
      }
      // Report only -- do NOT repair here. The point of the sweep is to name the
      // pass that broke the chain; repairing mid-pipeline would erase the very
      // evidence the next sweep needs.
      IRBlockTopology Topo;
      (void)ValidateBlockTopology(IR, BlockNode, Topo);
      ReportBlockTopology(Where, IR, BlockNode, Topo);
      return true;
    }
  }
  return false;
}
} // namespace

/* iOS-Madeira ml623 — TARGETED IR CAPTURE FOR ONE GUEST INSTRUCTION.
 *
 * The ULTRAKILL wall is a miscompile of exactly one x86 instruction inside
 * Mono's x86-64 code emitter:
 *
 *     mono-2.0-bdwgc.dll+0x4db259   or  al, 0x44
 *     mono-2.0-bdwgc.dll+0x4db25b   mov byte ptr [rcx+2], al
 *
 * Guest state was CORRECT (RCX=0x7040140010 into a fresh RWX buffer, AL=0x4c),
 * yet FEX emitted
 *
 *     movz w6, #0x44 ; orr x8, x8, x6 ; dmb ish ; strb w8, [x6, xzr]
 *
 * so the ADDRESS register x6 still held the IMMEDIATE: the `add x6, x0, #2`
 * that both sibling branches emit was never generated, and the store landed on
 * 0x44. This capture prints the IR for that one instruction after the frontend
 * and after every pass; the last stage at which the address computation is
 * still present names the culprit outright.
 *
 * ⛔ COMPILE TIME ONLY — never reachable from a fault path. ml620 died
 * formatting inside DFE's fault path and came back with its own format string
 * as the exception code (0x3d736469 == "ids="). Everything here runs while
 * CompileBlock is building IR, which already allocates and formats freely.
 *
 * Bounded by construction: IRCapMaxCaptures sessions total, and each stage
 * prints only the window between the target's GuestOpcode marker and the next
 * one, plus the defining lines of the SSA values the store consumes. */
extern "C" {
/* Absolute guest address to capture; 0 = disarmed. Published by the Windows
 * InvalidationTracker at module load, so nothing here needs to know about PE
 * layout or load order. */
uint64_t FEX_MadeiraIRCapTarget = 0;
}

namespace {

/* Set by Core.cpp's decode loop when the block being compiled CONTAINS the
 * target instruction. Containment, NOT entry RIP: with multiblock the block
 * routinely starts hundreds of bytes earlier, so an entry-range gate (which is
 * what I first proposed) would have missed this block entirely. */
thread_local uint64_t IRCapRIP = 0;
std::atomic<uint32_t> IRCapTaken {0};

constexpr uint32_t IRCapMaxCaptures = 4; // a LATER generation may be the faulty one
constexpr int IRCapLinesBefore = 12;
constexpr int IRCapLinesAfter = 96;
constexpr int IRCapMaxDefs = 24;

/* Read the last integer on a line ("#0x1a2b" or "#42") without depending on the
 * dumper's exact arg formatting, which is generated code and may change. */
bool IRCapTrailingInt(std::string_view Line, uint64_t& Out) {
  size_t End = Line.size();
  while (End > 0 && (Line[End - 1] == ' ' || Line[End - 1] == '\t' || Line[End - 1] == '\r')) {
    --End;
  }
  size_t Begin = End;
  while (Begin > 0) {
    const char C = Line[Begin - 1];
    const bool IsHexDigit = (C >= '0' && C <= '9') || (C >= 'a' && C <= 'f') || (C >= 'A' && C <= 'F');
    if (!IsHexDigit && C != 'x' && C != 'X') {
      break;
    }
    --Begin;
  }
  if (Begin >= End) {
    return false;
  }
  std::string_view Tok = Line.substr(Begin, End - Begin);
  int Base = 10;
  if (Tok.size() > 2 && Tok[0] == '0' && (Tok[1] == 'x' || Tok[1] == 'X')) {
    Base = 16;
    Tok = Tok.substr(2);
  }
  uint64_t Val = 0;
  for (const char C : Tok) {
    int D;
    if (C >= '0' && C <= '9') {
      D = C - '0';
    } else if (C >= 'a' && C <= 'f') {
      D = C - 'a' + 10;
    } else if (C >= 'A' && C <= 'F') {
      D = C - 'A' + 10;
    } else {
      return false;
    }
    if (D >= Base) {
      return false;
    }
    Val = Val * Base + static_cast<uint64_t>(D);
  }
  Out = Val;
  return true;
}

/* The SSA id a line DEFINES: the dumper writes "%12 i32 = Op ..." for ops with a
 * destination and "(%12 i32) Op ..." for ops without one. */
bool IRCapDefinedID(std::string_view Line, uint32_t& Out) {
  size_t i = 0;
  while (i < Line.size() && (Line[i] == '\t' || Line[i] == ' ')) {
    ++i;
  }
  if (i < Line.size() && Line[i] == '(') {
    ++i;
  }
  if (i >= Line.size() || Line[i] != '%') {
    return false;
  }
  ++i;
  if (i >= Line.size() || Line[i] < '0' || Line[i] > '9') {
    return false;
  }
  uint32_t Val = 0;
  while (i < Line.size() && Line[i] >= '0' && Line[i] <= '9') {
    Val = Val * 10 + static_cast<uint32_t>(Line[i] - '0');
    ++i;
  }
  Out = Val;
  return true;
}

void IRCapEmit(IREmitter* IREmit, const char* Stage, uint64_t GuestRIP, uint32_t Session) {
  const uint64_t Target = FEX_MadeiraIRCapTarget;
  if (!Target || Target < GuestRIP) {
    return;
  }
  const uint64_t WantOffset = Target - GuestRIP;

  auto IR = IREmit->ViewIR();
  fextl::stringstream Stream;
  FEXCore::IR::Dump(&Stream, &IR);
  const fextl::string Text = Stream.str();
  const std::string_view All {Text.data(), Text.size()};

  // Split once; the dump is one block's worth of IR, not the whole program.
  fextl::vector<std::string_view> Lines;
  for (size_t Pos = 0; Pos <= All.size();) {
    const size_t NL = All.find('\n', Pos);
    if (NL == std::string_view::npos) {
      if (Pos < All.size()) {
        Lines.push_back(All.substr(Pos));
      }
      break;
    }
    Lines.push_back(All.substr(Pos, NL - Pos));
    Pos = NL + 1;
  }

  int Start = -1;
  int Stop = static_cast<int>(Lines.size());
  for (int i = 0; i < static_cast<int>(Lines.size()); ++i) {
    if (Lines[i].find("GuestOpcode") == std::string_view::npos) {
      continue;
    }
    uint64_t Off = 0;
    if (!IRCapTrailingInt(Lines[i], Off)) {
      continue;
    }
    if (Start < 0 && Off == WantOffset) {
      Start = i;
    } else if (Start >= 0 && i > Start) {
      Stop = i;
      break;
    }
  }

  // Silence must be interpretable: say so rather than printing nothing.
  if (Start < 0) {
    LogMan::Msg::EFmt("[ircap] ml623 s{} stage={} postra={} NO GuestOpcode marker for offset {:#x} "
                      "(rip={:#x} target={:#x} ssa={} lines={}) -- instruction has no side-effect marker "
                      "in this stage's IR",
                      Session, Stage, IR.PostRA() ? 1 : 0, WantOffset, GuestRIP, Target, IR.GetSSACount(), Lines.size());
    return;
  }

  const int From = std::max(0, Start - IRCapLinesBefore);
  const int To = std::min(Stop, Start + IRCapLinesAfter);

  LogMan::Msg::EFmt("[ircap] ml623 s{} stage={} postra={} rip={:#x} target={:#x} off={:#x} "
                    "ssa={} window=[{},{}) marker@{}",
                    Session, Stage, IR.PostRA() ? 1 : 0, GuestRIP, Target, WantOffset, IR.GetSSACount(), From, To, Start);

  // Collect the SSA ids the store consumes so their definitions can be shown
  // even when they were produced far earlier in the block.
  uint32_t Wanted[IRCapMaxDefs];
  int NumWanted = 0;
  for (int i = From; i < To; ++i) {
    const std::string_view L = Lines[i];
    LogMan::Msg::EFmt("[ircap]   {}{}", i == Start ? "* " : "  ", L);
    if (L.find("StoreMem") == std::string_view::npos) {
      continue;
    }
    // Everything after '=' or the op name; grab every %N referenced.
    for (size_t p = 0; p + 1 < L.size(); ++p) {
      if (L[p] != '%' || L[p + 1] < '0' || L[p + 1] > '9') {
        continue;
      }
      uint32_t Val = 0;
      size_t q = p + 1;
      while (q < L.size() && L[q] >= '0' && L[q] <= '9') {
        Val = Val * 10 + static_cast<uint32_t>(L[q] - '0');
        ++q;
      }
      bool Dup = false;
      for (int k = 0; k < NumWanted; ++k) {
        Dup |= (Wanted[k] == Val);
      }
      if (!Dup && NumWanted < IRCapMaxDefs) {
        Wanted[NumWanted++] = Val;
      }
      p = q - 1;
    }
  }

  // Print the defining line of each consumed value, wherever it lives. This is
  // what answers "was the address computation ever emitted, and by which op".
  for (int i = 0; i < static_cast<int>(Lines.size()); ++i) {
    uint32_t Def = 0;
    if (!IRCapDefinedID(Lines[i], Def)) {
      continue;
    }
    for (int k = 0; k < NumWanted; ++k) {
      if (Wanted[k] != Def) {
        continue;
      }
      const bool InWindow = (i >= From && i < To);
      if (!InWindow) {
        LogMan::Msg::EFmt("[ircap]   DEF %{} @{}  {}", Def, i, Lines[i]);
      }
      break;
    }
  }
}

} // namespace

extern "C" void FEX_MadeiraIRCapMark(uint64_t GuestRIP) {
  IRCapRIP = GuestRIP;
}
extern "C" void FEX_MadeiraIRCapClear() {
  IRCapRIP = 0;
}
extern "C" uint64_t FEX_MadeiraIRCapCurrentRIP() {
  return IRCapRIP;
}

void PassManager::Run(IREmitter* IREmit) {
  FEXCORE_PROFILE_SCOPED("PassManager::Run");

  // One-time armed line so that ZERO [ir-topo] output is INTERPRETABLE. In ml599
  // the log had no [ir-topo] lines at all and that could equally have meant
  // "nothing was corrupt" or "the checks never ran" -- an unfalsifiable probe.
  [[maybe_unused]] static const bool Armed = [] {
    LogMan::Msg::EFmt("[ir-topo] ml599b ARMED: entry checks ON (dfe+ra, cheap backward walk), "
                      "sweep={} min-ssa={}",
                      IRTopoSweepEnabled() ? "ON" : "off", IRTopoSweepMinSSA());
    return true;
  }();

  const bool Sweep = IRTopoSweepEnabled() && IREmit->ViewIR().GetSSACount() >= IRTopoSweepMinSSA();
  // -1 means "as emitted, before any pass ran". If this fires, the IR is born
  // corrupt and no optimization pass is responsible.
  bool Corrupt = Sweep && SweepBlockTopology(IREmit, -1);

  /* ml623: claim ONE capture session for this whole compilation if the decode
   * loop saw the target instruction in this block. Claimed per compile rather
   * than per stage, so a session always yields a complete before/after set
   * rather than a truncated one. */
  const uint64_t CapRIP = FEX_MadeiraIRCapCurrentRIP();
  uint32_t CapSession = 0;
  bool Cap = false;
  if (CapRIP) {
    uint32_t Prev = IRCapTaken.load(std::memory_order_relaxed);
    while (Prev < IRCapMaxCaptures && !IRCapTaken.compare_exchange_weak(Prev, Prev + 1, std::memory_order_relaxed)) {
    }
    if (Prev < IRCapMaxCaptures) {
      Cap = true;
      CapSession = Prev + 1;
      LogMan::Msg::EFmt("[ircap] ml623 ===== CAPTURE {}/{} — block rip={:#x} CONTAINS target {:#x} =====", CapSession,
                        IRCapMaxCaptures, CapRIP, FEX_MadeiraIRCapTarget);
      IRCapEmit(IREmit, "frontend", CapRIP, CapSession);
    }
  }

  int PassIndex = 0;
  for (const auto& Pass : Passes) {
    Pass->Run(IREmit);

    if (Cap) {
      char NameBuf[32];
      const char* PassName = nullptr;
      for (const auto& NP : NameToPassMaping) {
        if (NP.second == Pass.get()) {
          PassName = NP.first.c_str();
          break;
        }
      }
      if (!PassName) {
        snprintf(NameBuf, sizeof(NameBuf), "pass%d", PassIndex);
        PassName = NameBuf;
      }
      IRCapEmit(IREmit, PassName, CapRIP, CapSession);
    }

    if (Sweep && !Corrupt) {
      Corrupt = SweepBlockTopology(IREmit, PassIndex);
    }
    ++PassIndex;
  }

#if defined(ASSERTIONS_ENABLED) && ASSERTIONS_ENABLED
  for (const auto& Pass : ValidationPasses) {
    Pass->Run(IREmit);
  }
#endif
}
} // namespace FEXCore::IR
