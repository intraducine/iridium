// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * On-device exercise of the arena carver against the REAL placeholder
 * implementation.
 *
 * The host-side suite runs the same carver against a mock. That proves the
 * interval arithmetic and the rollback logic, but it cannot prove that this
 * kernel splits, replaces, preserves and coalesces the way the mock assumes --
 * and that assumption is the whole design. So this runs on the device, against
 * the actual implementation, before any allocator is made to depend on it.
 *
 * Deliberately gated by its OWN flag, separate from the feature switch: a test
 * that only runs when the feature is enabled cannot be used to decide whether
 * to enable the feature.
 *
 *   MADEIRA_ARENA_TEST=churn:N   N sequential create/destroy cycles; free space
 *                                and largest hole must return EXACTLY
 *   MADEIRA_ARENA_TEST=ramp:N    up to N concurrent threads; hitting capacity
 *                                is a RESULT, not a failure
 *   MADEIRA_ARENA_TEST=random:N  N randomized size/alignment/free-order rounds
 */

#include "ArenaManager.h"

#include <FEXCore/Utils/LogManager.h>

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>
#include <windows.h>

namespace FEX {
namespace Windows {
namespace Arena {

namespace {

constexpr size_t TEST_ARENA = 256ull << 20; /* 256MB: enough to be meaningful, small enough to be quick */
constexpr size_t GRAN = 0x10000;
/* Carves per round. Each one costs a split, a replace, a preserve and up to two
 * coalesces against the real kernel, so this multiplies quickly. */
constexpr unsigned PER_ROUND = 8;

/* A cheap deterministic generator -- the run must be reproducible, and this
 * must not pull in anything that allocates. */
uint32_t Rand(uint32_t& S) {
  S ^= S << 13;
  S ^= S >> 17;
  S ^= S << 5;
  return S;
}

uintptr_t ReserveTestArena(size_t Size) {
  using VA2 = PVOID(WINAPI*)(HANDLE, PVOID, SIZE_T, ULONG, ULONG, MEM_EXTENDED_PARAMETER*, ULONG);
  HMODULE KB = GetModuleHandleA("kernelbase.dll");
  auto pVA2 = KB ? reinterpret_cast<VA2>(reinterpret_cast<void*>(GetProcAddress(KB, "VirtualAlloc2"))) : nullptr;
  if (!pVA2) {
    LogMan::Msg::EFmt("[arena-test] VirtualAlloc2 unavailable -- cannot reserve a test arena");
    return 0;
  }
  MEM_ADDRESS_REQUIREMENTS Req {};
  MEM_EXTENDED_PARAMETER Param {};
  Req.LowestStartingAddress = reinterpret_cast<PVOID>(0x0200000000ull);
  Req.HighestEndingAddress = reinterpret_cast<PVOID>(0x0fbfffffffull);
  Req.Alignment = GRAN;
  Param.Type = MemExtendedParameterAddressRequirements;
  Param.Pointer = &Req;
  void* Base = pVA2(GetCurrentProcess(), nullptr, Size, MEM_RESERVE | MEM_RESERVE_PLACEHOLDER, PAGE_NOACCESS, &Param, 1);
  return reinterpret_cast<uintptr_t>(Base);
}

struct Rec {
  void* P;
  size_t S;
};

int Failures = 0;
void Expect(bool Cond, const char* What) {
  if (Cond) {
    LogMan::Msg::EFmt("[arena-test]   ok   {}", What);
  } else {
    ++Failures;
    LogMan::Msg::EFmt("[arena-test]   FAIL {}", What);
  }
}

void RunChurn(unsigned N) {
  size_t Free0 = 0, Largest0 = 0;
  Stats(&Largest0, &Free0, nullptr, nullptr);
  LogMan::Msg::EFmt("[arena-test] churn x{}: start free={:#x} largest={:#x}", N, Free0, Largest0);

  /* Every carve is several VM operations against the real kernel, so the total
   * is announced up front: a long silent run is indistinguishable from a hang,
   * which is exactly how the first attempt looked. */
  LogMan::Msg::EFmt("[arena-test] {} rounds x {} carves = ~{} VM operations; progress every 20 rounds", N, PER_ROUND,
                    (unsigned)(N * PER_ROUND * 5));
  for (unsigned round = 0; round < N; ++round) {
    if (round && (round % 20) == 0) {
      size_t F = 0;
      Stats(nullptr, &F, nullptr, nullptr);
      LogMan::Msg::EFmt("[arena-test]   round {}/{} free={:#x}", round, N, F);
    }
    Rec Held[PER_ROUND];
    unsigned Got = 0;
    for (unsigned i = 0; i < PER_ROUND; ++i) {
      const size_t S = GRAN * (1 + (i % 4));
      void* P = Alloc(S, GRAN, Policy::CommittedRW);
      if (!P) {
        break;
      }
      Held[Got++] = {P, S};
    }
    for (unsigned i = 0; i < Got; ++i) {
      Free(Held[i].P, Held[i].S);
    }
  }

  size_t Free1 = 0, Largest1 = 0;
  unsigned Slices = 0, Live = 0;
  Stats(&Largest1, &Free1, &Slices, &Live);
  LogMan::Msg::EFmt("[arena-test] churn done: free={:#x} largest={:#x} slices={} live={}", Free1, Largest1, Slices, Live);
  Expect(Free1 == Free0, "total free returns EXACTLY after churn");
  Expect(Largest1 == Largest0, "largest hole returns EXACTLY (capacity did not shrink)");
  Expect(Live == 0, "no carve leaked");
  Expect(Slices == 1, "arena is a single hole again");
}

void RunRamp(unsigned MaxThreads) {
  size_t Free0 = 0, Largest0 = 0;
  Stats(&Largest0, &Free0, nullptr, nullptr);
  std::atomic<unsigned> Succeeded {0}, Refused {0};

  std::vector<std::thread> T;
  for (unsigned t = 0; t < MaxThreads; ++t) {
    T.emplace_back([&, t] {
      uint32_t S = t * 2654435761u + 1;
      for (unsigned i = 0; i < 64; ++i) {
        const size_t Sz = GRAN * (1 + (Rand(S) % 4));
        void* P = Alloc(Sz, GRAN, Policy::CommittedRW);
        if (P) {
          ++Succeeded;
          Free(P, Sz);
        } else {
          ++Refused;
        }
      }
    });
  }
  for (auto& th : T) {
    th.join();
  }

  size_t Free1 = 0, Largest1 = 0;
  unsigned Slices = 0, Live = 0;
  Stats(&Largest1, &Free1, &Slices, &Live);
  /* A refusal under a concurrency ramp means the arena was momentarily full.
   * That is CAPACITY, not fragmentation, and must not be read as a failure --
   * the failure would be capacity that does not come back. */
  LogMan::Msg::EFmt("[arena-test] ramp x{}: {} carves, {} refused (refusals mean capacity, not breakage)", MaxThreads,
                    Succeeded.load(), Refused.load());
  Expect(Free1 == Free0, "total free returns EXACTLY after the ramp");
  Expect(Largest1 == Largest0, "largest hole returns EXACTLY after the ramp");
  Expect(Live == 0, "no carve leaked under concurrency");
  Expect(Slices == 1, "no fragmentation left after concurrent churn");
}

void RunRandom(unsigned N) {
  size_t Free0 = 0, Largest0 = 0;
  Stats(&Largest0, &Free0, nullptr, nullptr);
  uint32_t S = 20260829u;
  std::vector<Rec> Held;
  for (unsigned i = 0; i < N; ++i) {
    if (Held.empty() || (Rand(S) % 100) < 60) {
      const size_t Sz = GRAN * (1 + (Rand(S) % 8));
      const size_t A = GRAN << (Rand(S) % 3);
      void* P = Alloc(Sz, A, Policy::CommittedRW);
      if (P) {
        Held.push_back({P, Sz});
      }
    } else {
      const size_t k = Rand(S) % Held.size();
      Free(Held[k].P, Held[k].S);
      Held.erase(Held.begin() + k);
    }
  }
  for (auto& H : Held) {
    Free(H.P, H.S);
  }
  size_t Free1 = 0, Largest1 = 0;
  unsigned Slices = 0, Live = 0;
  Stats(&Largest1, &Free1, &Slices, &Live);
  LogMan::Msg::EFmt("[arena-test] random x{}: free={:#x} largest={:#x} slices={} live={}", N, Free1, Largest1, Slices, Live);
  Expect(Free1 == Free0, "total free returns EXACTLY after random churn");
  Expect(Largest1 == Largest0, "largest hole returns EXACTLY after random churn");
  Expect(Live == 0, "no carve leaked");
}

void RunInjection() {
  /* The rollback path never executes in an ordinary run, so it is exercised
   * here or it is untested. The proof is not that the call failed -- it is
   * that a later carve SPANNING the rolled-back boundary still succeeds. */
  size_t Free0 = 0;
  Stats(nullptr, &Free0, nullptr, nullptr);

  SetInject(Inject::ReplaceFails, 1);
  void* p = Alloc(GRAN * 4, GRAN, Policy::CommittedRW);
  SetInject(Inject::None, 0);
  Expect(p == nullptr, "injected replacement failure refuses the carve");

  size_t Free1 = 0;
  Stats(nullptr, &Free1, nullptr, nullptr);
  Expect(Free1 == Free0, "a failed replacement leaks no address space");

  void* big = Alloc(GRAN * 8, GRAN, Policy::CommittedRW);
  Expect(big != nullptr, "a carve spanning the rolled-back split still succeeds");
  if (big) {
    Free(big, GRAN * 8);
  }
}

} // namespace

void SelfTest() {
  const char* Env = getenv("MADEIRA_ARENA_TEST");
  if (!Env || !*Env) {
    return;
  }

  const char* Colon = strchr(Env, ':');
  const unsigned N = Colon ? (unsigned)atoi(Colon + 1) : 0;
  if (!N) {
    LogMan::Msg::EFmt("[arena-test] MADEIRA_ARENA_TEST={} has no count -- expected churn:N, ramp:N or random:N", Env);
    return;
  }

  const uintptr_t Base = ReserveTestArena(TEST_ARENA);
  if (!Base) {
    LogMan::Msg::EFmt("[arena-test] could not reserve a {}MB test arena -- REAL placeholder support is "
                      "unproven on this device; do NOT enable the feature",
                      TEST_ARENA >> 20);
    return;
  }
  LogMan::Msg::EFmt("[arena-test] reserved test arena [{:#x},{:#x}) -- exercising the REAL placeholder "
                    "implementation, not a mock",
                    Base, Base + TEST_ARENA);

  if (!Adopt(Base, Base + TEST_ARENA)) {
    LogMan::Msg::EFmt("[arena-test] Adopt refused the test arena");
    return;
  }

  Failures = 0;
  if (!strncmp(Env, "churn:", 6)) {
    RunChurn(N);
  } else if (!strncmp(Env, "ramp:", 5)) {
    RunRamp(N);
  } else if (!strncmp(Env, "random:", 7)) {
    RunRandom(N);
  } else {
    LogMan::Msg::EFmt("[arena-test] unknown mode {}", Env);
    return;
  }
  RunInjection();

  LogMan::Msg::EFmt("[arena-test] ===== {} FAILURE(S) against the real placeholder implementation =====", Failures);
}

} // namespace Arena
} // namespace Windows
} // namespace FEX
