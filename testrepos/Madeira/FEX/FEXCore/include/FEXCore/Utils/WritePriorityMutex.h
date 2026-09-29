// SPDX-License-Identifier: MIT
#pragma once
#include <atomic>
#include <cstdint>

#if defined(__linux__)
#include <linux/futex.h> /* Definition of FUTEX_* constants */
#include <sys/syscall.h> /* Definition of SYS_* constants */
#include <unistd.h>
#elif defined(__APPLE__)
#include <unistd.h>
#include <os/lock.h>
#else
#include <synchapi.h>
// Don't pull in all WIN32 headers for INFINITE. Causes too many problems.
#ifndef INFINITE
#define INFINITE 0xffffffff
#endif
#endif

#include <FEXCore/Utils/LogManager.h>

#include <FEXCore/Utils/SpinWaitLock.h>

namespace FEXCore::Utils::WritePriorityMutex {

// A custom mutex that prioritizes exclusive locks.
// In highly contested scenarios, this can help minimize overall contention time.
//
// Features:
//  - Up to 32767 pending exclusive locks ("writers")
//  - Up to 32767 pending shared_locks ("readers")
//  - Low-overhead waiting via WFE with a fallback to futex on timeout
//  - Direct writer->reader hand-off and vice-versa to further reduce overhead
//
// Trade-offs:
//  - No guaranteed order of wake-ups besides prioritizing writers
//  - No support for recursive locking
//  - We can't use FUTEX_LOCK_PI to enable priority inheritance
class Mutex final {
public:
  Mutex() = default;

  // Move-only type
  Mutex(const Mutex&) = delete;
  Mutex& operator=(const Mutex&) = delete;
  Mutex(Mutex&& rhs) = delete;
  Mutex& operator=(Mutex&&) = delete;

  void lock() {
    /* ml451: the ml450 write→write self-grant REVERTED — its nest accounting
     * leaked on steam's boot path (SELF-WRITE nest climbed 1→3+ from paired
     * try_lock/lock call sites; a leaked count makes the outermost unlock
     * consume a nested decrement instead of releasing the futex ⇒ permanent
     * hold ⇒ the ml450-era early-boot loader wedge).  The write→write case
     * needs a reland with call-site-exact pairing; see task #69. */

    // Try a non-blocking lock first.  (ml442: try_lock stamps the owner
    // itself now, so direct try_lock callers are attributed too.)
    if (try_lock()) {
      return;
    }

    // Try a quick WFE write-lock.
    if (Attempt_WFE_WriteLock()) {
      NoteWriteAcquired();
      return;
    }

    // Still couldn't get it. Start waiting.
    auto AtomicFutex = std::atomic_ref<uint32_t>(Futex);

    uint32_t Expected {};
    uint32_t Desired {};
#if defined(ASSERTIONS_ENABLED) && ASSERTIONS_ENABLED
    Expected = AtomicFutex.load(std::memory_order_relaxed);
    do {
      // Increment the number of write waiters.
      Desired = Expected + WRITE_WAITER_INCREMENT;

      LOGMAN_THROW_A_FMT((Desired & WRITE_WAITER_COUNT_MASK) != 0, "Overflow in write-waiters!");
    } while (AtomicFutex.compare_exchange_strong(Expected, Desired, std::memory_order_acq_rel, std::memory_order_acquire) == false);
#else
    // Increment the number of writers waiting. The following loop will attempt to acquire the write-lock while decrementing the waiter count.
    Expected = AtomicFutex.fetch_add(WRITE_WAITER_INCREMENT);
    Desired = Expected + WRITE_WAITER_INCREMENT;
#endif

    // Thread added to waiter list.
    Expected = Desired;

    while (true) {
      bool Sleep = false;

      do {
        if ((Expected & WRITE_OWNED_BIT) == 0 && (Expected & READ_OWNER_COUNT_MASK) == 0) {
          // If not write-owned, and no read-owners, try to acquire.
          LOGMAN_THROW_A_FMT((Expected & WRITE_WAITER_COUNT_MASK) != 0, "Underflow in write-waiters!");

          // Add write-owned bit.
          Desired = Expected | WRITE_OWNED_BIT;

          // Remove ourselves from the wait list.
          Desired -= WRITE_WAITER_INCREMENT;

          Sleep = false;
        } else {
          // Already write-owned or read-locked. Go to sleep.
          Desired = Expected;
          Sleep = true;
          break;
        }

      } while (AtomicFutex.compare_exchange_strong(Expected, Desired, std::memory_order_acq_rel, std::memory_order_acquire) == false);

      if (!Sleep) {
        // Acquired early.
        LOGMAN_THROW_A_FMT((Desired & WRITE_OWNED_BIT) == WRITE_OWNED_BIT, "Somehow acquired a write-lock without it being set!");
        NoteWriteAcquired();
        return;
      }

      // Two paths to get here.
      // Desired[31] = 1 (WRITE_OWNED_BIT)
      // OR
      // Desired[15:0] != 0 (READ_OWNER_COUNT_MASK)
      // Meaning that there was already a writer that owned the lock, or reads were owning it.
      // This thread already incremented `WRITE_WAITER_INCREMENT` before this loop.
      // - Linux waits for the full 32-bits to change (With bitset wakeup).
      // - Win32 also waits for the full 32-bits to change (with offset addr on the reader side to reduce stampeding).
      FutexWaitForWriteAvailable(Desired);

      Expected = AtomicFutex.load(std::memory_order_relaxed);
    }
  }

  void lock_shared() {
    /* iOS-Madeira ml442 (#74 ROOT FIX): the class forbids recursive locking,
     * but the invalidation paths hold this WRITE-locked while a fault taken
     * on the same thread re-enters the compiler, which asks for SHARED — the
     * thread then parks forever behind itself (ml441 run: tid 00e4 write-owned
     * 0x7ca7173500 and read-waited on it; the whole webhelper cascaded behind
     * that one park).  A write owner already has exclusive access, which is a
     * strict superset of shared — grant it with a nest counter instead. */
    if (IosWriterSelfShared()) {
      return;
    }

    // Try an uncontended lock first.
    if (try_lock_shared()) {
      return;
    }

    // Try a quick WFE read-lock.
    if (Attempt_WFE_ReadLock()) {
      return;
    }

    auto AtomicFutex = std::atomic_ref<uint32_t>(Futex);

    uint32_t Expected = AtomicFutex.load(std::memory_order_relaxed);
    uint32_t Desired {};

    while (true) {
      bool Sleep = false;
      do {
        if ((Expected & WRITE_OWNED_BIT) == 0 && (Expected & WRITE_WAITER_COUNT_MASK) == 0) {
          // If no write-owner and no write-waiting, try and acquire.

          Desired = Expected + READ_OWNER_INCREMENT;
          LOGMAN_THROW_A_FMT((Desired & READ_OWNER_COUNT_MASK) != 0, "Overflow in read-owners!");
          Sleep = false;
        } else {
          // Waiting for lock to become available. Add to waiters.
          Desired = Expected | READ_WAITER_BIT;
          Sleep = true;
        }
      } while (AtomicFutex.compare_exchange_strong(Expected, Desired, std::memory_order_acq_rel, std::memory_order_acquire) == false);

      if (!Sleep) {
        // Acquired early.
        LOGMAN_THROW_A_FMT((Desired & WRITE_OWNED_BIT) != WRITE_OWNED_BIT, "Somehow read-locked and got a write lock!");
        NoteReadAcquired();
        return;
      }

      // Only one path to get here.
      // Desired[31][29:16] != 0 (Either writer-owned, or writer-waiting)
      // Desired[30][15:0]  == READ_WAIT_BIT and number of read-owners (draining to zero as write-side is set)
      // - Linux waits for full 32-bit futex.
      // - Win32 waits for upper 16-bits to not match (Either zero writer owned, writer-wait is draining, and `READ_WAITER_BIT` changed).
      // Can get some spurious wake-ups which will `or` the `READ_WAITER_BIT` again, which does nothing.
      FutexWaitForReadAvailable(Desired);

      Expected = AtomicFutex.load(std::memory_order_relaxed);
    }
  }

  void unlock() {
    auto AtomicFutex = std::atomic_ref<uint32_t>(Futex);

    NoteWriteReleased();

    uint32_t Expected = AtomicFutex.load(std::memory_order_relaxed);
    uint32_t Desired {};
    do {
      LOGMAN_THROW_A_FMT((Expected & WRITE_OWNED_BIT) == WRITE_OWNED_BIT, "Trying to write-unlock something not write-locked!");
      // Remove the exclusive lock bit.
      Desired = Expected & ~WRITE_OWNED_BIT;

      // If no more writers, then make sure to clear the read-waiters bit as well.
      if ((Desired & WRITE_WAITER_COUNT_MASK) == 0) {
        Desired &= ~READ_WAITER_BIT;
      }
    } while (AtomicFutex.compare_exchange_strong(Expected, Desired, std::memory_order_acq_rel, std::memory_order_acquire) == false);

    // `Expected` has old value. Containing `READ_WAITER_BIT` which was just masked off, and also `WRITE_WAITER_COUNT_MASK`.
    //
    // Two paths here to be careful about dead-locking other waiters:
    // - If there are any writers waiting, those get priority to wake.
    // - If there are zero writers waiting, and there are read waiters then make sure to wake them all.
    // Failure to send wake events can cause readers to "infinitely" hang! (ignoring spurious wake-up).
    if ((Expected & WRITE_WAITER_COUNT_MASK)) {
      // Handle write-write handoff.
      FutexWakeWriter();
    } else if ((Expected & READ_WAITER_BIT)) {
      // Handle write-reader handoff.
      FutexWakeReaders();
    }
  }

  void unlock_shared() {
    /* ml442: matching release for a write-owner's nested shared grant */
    if (IosWriterSelfSharedRelease()) {
      return;
    }

    auto AtomicFutex = std::atomic_ref<uint32_t>(Futex);

    NoteReadReleased();

    uint32_t Desired {};
#if defined(ASSERTIONS_ENABLED) && ASSERTIONS_ENABLED
    uint32_t Expected = AtomicFutex.load(std::memory_order_relaxed);
    do {
      LOGMAN_THROW_A_FMT((Expected & WRITE_OWNED_BIT) != WRITE_OWNED_BIT, "Trying to read-unlock something write-locked!");
      LOGMAN_THROW_A_FMT((Expected & READ_OWNER_COUNT_MASK) != 0, "Trying to read-unlock something not read-locked!");

      // Decrement the shared counter.
      Desired = Expected - READ_OWNER_INCREMENT;
    } while (AtomicFutex.compare_exchange_strong(Expected, Desired, std::memory_order_acq_rel, std::memory_order_acquire) == false);
#else
    Desired = AtomicFutex.fetch_sub(READ_OWNER_INCREMENT) - READ_OWNER_INCREMENT;
#endif

    // Handle read->write handoff if there are any waiting writers, and no readers left.
    // Only one path here but still need to be careful to not dead-lock waiting writers.
    // - If there are waiters /but/ this is not the final unlock_shared, then don't wake writer.
    //   - Writer would wake and immediately sleep again if we woke on every unlock_shared.
    // - If there are waiters and this is the final unlock_shared, then wake a /single/ writer.
    // - We ignore any reader-waiters here as they must wait their turn for writers that are waiting.
    if ((Desired & WRITE_WAITER_COUNT_MASK) && (Desired & READ_OWNER_COUNT_MASK) == 0) {
      FutexWakeWriter();
    }
  }

  /* ml452 (#74): token-scoped nested-aware write acquire.  The ml450 in-mutex
   * nest counter leaked (try/lock double-entry); doing it HERE with the RAII
   * token as the unit makes pairing structural: returns whether this call
   * actually locked — the token unlocks only if it did.  Self-test is the
   * OwnerTeb stamp (only the true owner can see its own teb there).  Stale
   * stamp from a dead owner + recycled TEB yields a false no-lock, which is
   * strictly better than the guaranteed self-park (and the reapers clear the
   * corpse's hold). */
  bool ios_lock_write_nested_aware() {
#if defined(_WIN32)
    const uint64_t Teb = IosSelfTeb();
    if (Teb && OwnerTeb == Teb) {
      static std::atomic<int> NestedTokenLog {0};
      if (NestedTokenLog.fetch_add(1, std::memory_order_relaxed) < 20) {
        LogMan::Msg::EFmt("[fexlock] NESTED-TOKEN write grant mutex={} ra={} rev=ml452", static_cast<void*>(&Futex),
                          __builtin_return_address(0));
      }
      return false;
    }
#endif
    lock();
    return true;
  }

  bool try_lock() {
    auto AtomicFutex = std::atomic_ref<uint32_t>(Futex);

    uint32_t Expected = 0;

    // Try and grab the owned bit.
    uint32_t Desired = WRITE_OWNED_BIT;

    // try to CAS immediately.
    const bool Acquired = AtomicFutex.compare_exchange_strong(Expected, Desired, std::memory_order_acq_rel, std::memory_order_acquire);
    if (Acquired) {
      NoteWriteAcquired();
    }
    return Acquired;
  }

  // Can race with other threads trying to lock shared!
  bool try_lock_shared() {
    /* ml442: write owner asking for shared always succeeds (see lock_shared) */
    if (IosWriterSelfShared()) {
      return true;
    }

    auto AtomicFutex = std::atomic_ref<uint32_t>(Futex);
    uint32_t Expected = AtomicFutex.load(std::memory_order_relaxed);

    // Exclusively owned or has a list of waiting owners. Can't pass.
    if ((Expected & WRITE_OWNED_BIT) || (Expected & WRITE_WAITER_COUNT_MASK)) {
      return false;
    }

    // Try to add reader.
    uint32_t Desired = Expected + READ_OWNER_INCREMENT;
    LOGMAN_THROW_A_FMT((Desired & READ_OWNER_COUNT_MASK) != 0, "Overflow in read-owners!");

    // Uncontended mutex check
    const bool Acquired = AtomicFutex.compare_exchange_strong(Expected, Desired, std::memory_order_acq_rel, std::memory_order_acquire);
    if (Acquired) {
      NoteReadAcquired();
    }
    return Acquired;
  }

#if !defined(_WIN32)
  void StealAndDropActiveLocks() {
    Futex = 0;
  }
#endif

  /* iOS-Madeira ml612: identity of the address NoteReadAcquired() stamps into
   * TEB Instrumentation[8]. The thread-exit cleanup MUST verify a stamped
   * address against this before releasing anything — the stamp is a diagnostic
   * value written by whichever mutex was held, and acting on it blindly (or
   * poking its futex word directly) would corrupt an unrelated lock. */
  uint64_t IosStampAddress() const {
    return reinterpret_cast<uint64_t>(&Futex);
  }

private:

#if defined(__linux__)
  void FutexWaitForWriteAvailable(uint32_t Expected) {
    ::syscall(SYS_futex, &Futex, FUTEX_PRIVATE_FLAG | FUTEX_WAIT_BITSET, Expected, nullptr, nullptr, FUTEX_BITSET_WAIT_WRITERS);
  }

  void FutexWaitForReadAvailable(uint32_t Expected) {
    ::syscall(SYS_futex, &Futex, FUTEX_PRIVATE_FLAG | FUTEX_WAIT_BITSET, Expected, nullptr, nullptr, FUTEX_BITSET_WAIT_READERS);
  }

  void FutexWakeWriter() {
    ::syscall(SYS_futex, &Futex, FUTEX_PRIVATE_FLAG | FUTEX_WAKE_BITSET, 1, nullptr, nullptr, FUTEX_BITSET_WAIT_WRITERS);
  }

  void FutexWakeReaders() {
    ::syscall(SYS_futex, &Futex, FUTEX_PRIVATE_FLAG | FUTEX_WAKE_BITSET, INT_MAX, nullptr, nullptr, FUTEX_BITSET_WAIT_READERS);
  }
#elif defined(__APPLE__)
  // Apple: spin-wait fallback (WFE handles the fast path on arm64)
  void FutexWaitForWriteAvailable(uint32_t Expected) {
    auto AtomicFutex = std::atomic_ref<uint32_t>(Futex);
    while (AtomicFutex.load(std::memory_order_relaxed) == Expected) {
      usleep(10);
    }
  }

  void FutexWaitForReadAvailable(uint32_t Expected) {
    auto AtomicFutex = std::atomic_ref<uint32_t>(Futex);
    while (AtomicFutex.load(std::memory_order_relaxed) == Expected) {
      usleep(10);
    }
  }

  void FutexWakeWriter() {
    // No-op: spin-waiters will see the change
  }

  void FutexWakeReaders() {
    // No-op: spin-waiters will see the change
  }
#else
  /* iOS-Madeira ml411: an INFINITE wait here is unobservable — a thread parked
   * on a never-released lock looks identical to an idle one, and this mutex is
   * anonymous (no owner is recorded). Wait in 1s slices instead and, past a few
   * seconds, name the write-owner from the ring below. Semantics are unchanged:
   * both callers already loop and re-check state, and spurious wake-ups are
   * explicitly tolerated. */
  void IosStuckReport(const char* Which, uint32_t Expected) {
    LogMan::Msg::EFmt("[fexlock] STUCK {} on mutex {} word={:08x} (write-owned={} read-waiter={} "
                      "write-waiters={} read-owners={}) expected={:08x} | owner teb={:x} tid={:04x} depth={}",
                      Which, static_cast<void*>(&Futex), Futex, !!(Futex & WRITE_OWNED_BIT), !!(Futex & READ_WAITER_BIT),
                      (Futex & WRITE_WAITER_COUNT_MASK) >> WRITE_WAITER_OFFSET, Futex & READ_OWNER_COUNT_MASK, Expected,
                      OwnerTeb, OwnerTid, OwnerDepth);
    /* ml413: a parked writer means live read holds are the blockers — name them.
     * ml414: dump from READ-wait reports too — ml414 died before any write
     * waiter reached its report and the ring never printed. Global cap keeps
     * the spam bounded instead. */
    static std::atomic<int> HolderDumps {0};
    if (HolderDumps.fetch_add(1, std::memory_order_relaxed) < 12) {
      for (size_t i = 0; i < 16; i++) {
        if (ReadHolderTeb[i]) {
          LogMan::Msg::EFmt("[fexlock]   read-holder[{}] teb={:x} tid={:04x}", i, ReadHolderTeb[i], ReadHolderTid[i]);
        }
      }
    }
  }

  // Writers wait for the full 32-bit futex.
  void FutexWaitForWriteAvailable(uint32_t Expected) {
    for (uint32_t i = 0;; i++) {
      if (WaitOnAddress(&Futex, &Expected, sizeof(Futex), 1000)) {
        return;
      }
      if (i == 4 || i == 60) {
        IosStuckReport("write-wait", Expected);
      }
    }
  }

  // Readers wait for Futex bits [31:16] to be zero.
  void FutexWaitForReadAvailable(uint32_t Expected) {
    auto ReadWaiterAddress = reinterpret_cast<uint8_t*>(&Futex) + 2;
    uint16_t smol_Expected = Expected >> 16;
    for (uint32_t i = 0;; i++) {
      if (WaitOnAddress(ReadWaiterAddress, &smol_Expected, sizeof(smol_Expected), 1000)) {
        return;
      }
      if (i == 4 || i == 60) {
        IosStuckReport("read-wait", Expected);
      }
    }
  }

  void FutexWakeWriter() {
    WakeByAddressSingle(&Futex);
  }

  void FutexWakeReaders() {
    auto ReadWaiterAddress = reinterpret_cast<uint8_t*>(&Futex) + 2;
    WakeByAddressAll(ReadWaiterAddress);
  }
#endif

  // Reuse the SpinWaitLock WFE implementations for read/write lock acquiring with WFE.
  // Can't reuse the spin-lock directly as some bit-representations are different.
  // WFE-write-lock is less likely to occur the more read-lock threads are participating. Can still occur so good to try.
  // WFE-read-lock is actually quite likely to succeed.
  // Return: true if the lock was acquired.
  bool Attempt_WFE_WriteLock() {
#ifdef ARCHITECTURE_arm64
    const auto Begin = FEXCore::Utils::SpinWaitLock::GetCycleCounter();
    auto Now = Begin;
    const auto Duration = FEXCore::Utils::SpinWaitLock::CycleCounterFrequency / CYCLECOUNT_DIVISOR;

    auto AtomicFutex = std::atomic_ref<uint32_t>(Futex);
    uint32_t Expected = AtomicFutex.load(std::memory_order_relaxed);

    while ((Now - Begin) < Duration) {
      if (Expected == 0) {
        // Try and grab the owned bit.
        uint32_t Desired = WRITE_OWNED_BIT;

        if (AtomicFutex.compare_exchange_strong(Expected, Desired, std::memory_order_acq_rel, std::memory_order_acquire)) {
          return true;
        }
      }

      // One-shot attempt to wait for mask to be zero.
      Expected = FEXCore::Utils::SpinWaitLock::OneShotWFEBitComparison(&Futex, ~0U, 0U);
      Now = FEXCore::Utils::SpinWaitLock::GetCycleCounter();
    }
#endif

    return false;
  }

  // Return: true if the lock was acquired.
  bool Attempt_WFE_ReadLock() {
#ifdef ARCHITECTURE_arm64
    // Spin on a WFE for a short-amount of time, waiting for write-owned and writer-count to be zero.
    //  - Attempt to acquire read-lock at that point.
    //  - Don't add read-waiters bit on failure, return false.
    const auto Begin = FEXCore::Utils::SpinWaitLock::GetCycleCounter();
    auto Now = Begin;
    const auto Duration = FEXCore::Utils::SpinWaitLock::CycleCounterFrequency / CYCLECOUNT_DIVISOR;

    auto AtomicFutex = std::atomic_ref<uint32_t>(Futex);
    uint32_t Expected = AtomicFutex.load(std::memory_order_relaxed);
    uint32_t Desired {};

    while ((Now - Begin) < Duration) {
      if ((Expected & WRITE_OWNED_BIT) == 0 && (Expected & WRITE_WAITER_COUNT_MASK) == 0) {
        // If no write-owner and no write-waiting, try and acquire.

        Desired = Expected + READ_OWNER_INCREMENT;
        LOGMAN_THROW_A_FMT((Desired & READ_OWNER_COUNT_MASK) != 0, "Overflow in read-owners!");
        if (AtomicFutex.compare_exchange_strong(Expected, Desired, std::memory_order_acq_rel, std::memory_order_acquire)) {
          NoteReadAcquired();
          return true;
        }
      }

      // One-shot attempt to wait for mask to be zero.
      Expected = FEXCore::Utils::SpinWaitLock::OneShotWFEBitComparison(&Futex, WRITE_OWNED_BIT | WRITE_WAITER_COUNT_MASK, 0U);
      Now = FEXCore::Utils::SpinWaitLock::GetCycleCounter();
    }
#endif

    return false;
  }

  constexpr static uint32_t WRITE_OWNED_BIT = 1U << 31;
  constexpr static uint32_t READ_WAITER_BIT = 1U << 30;
  constexpr static uint32_t WRITE_WAITER_OFFSET = 16;
  constexpr static uint32_t WRITE_WAITER_INCREMENT = 1U << WRITE_WAITER_OFFSET;
  constexpr static uint32_t READ_OWNER_INCREMENT = 1;

  // Count masks
  constexpr static uint32_t WRITE_WAITER_COUNT_MASK = 0x3FFFU << WRITE_WAITER_OFFSET;
  constexpr static uint32_t READ_OWNER_COUNT_MASK = 0xFFFFU;

  // Independent futex bit-set masks.
  // Wait for readers to drain.
  constexpr static uint32_t FUTEX_BITSET_WAIT_READERS = 1U << 0;
  // Wait for writers to drain.
  constexpr static uint32_t FUTEX_BITSET_WAIT_WRITERS = 1U << 1;

  // Only spin on WFE for 0.01ms (10k ns).
  constexpr static uint64_t CYCLECOUNT_DIVISOR = 1'000'000'000ULL / 10'000U;

  // Layout:
  //    Bits[31]: Write-lock bit.
  //    Bits[30]: Read-waiter bit.
  // Bits[29:16]: Write-waiter count.
  //  Bits[15:0]: Read-owner count.
  uint32_t Futex {};

#if defined(_WIN32)
  /* iOS-Madeira ml411: who holds it exclusive. Written after every successful
   * write-acquire and cleared on release, so a stuck waiter can name the
   * thread instead of guessing. TEB comes from x18 (the ARM64 platform
   * register) and the tid from TEB.ClientId.UniqueThread at +0x48; both are
   * logged so they cross-check against the [cpu-area] lines, which print the
   * same pair. Plain stores — the lock word itself is the synchronisation. */
  uint64_t OwnerTeb {};
  uint32_t OwnerTid {};
  uint32_t OwnerDepth {};
  /* ml442: count of shared grants the write owner holds nested inside its
   * write hold.  Touched only by the owning thread — plain stores suffice. */
  uint32_t OwnerSharedNest {};

  void NoteWriteAcquired() {
    uint64_t Teb = 0;
#ifdef ARCHITECTURE_arm64
    __asm volatile("mov %0, x18" : "=r"(Teb));
#endif
    OwnerTeb = Teb;
    OwnerTid = Teb ? *reinterpret_cast<uint32_t*>(Teb + 0x48) : 0;
    OwnerDepth++;
  }

  void NoteWriteReleased() {
    if (OwnerSharedNest) {
      /* Badly-nested release order (write-unlock before nested shared-unlock).
       * Scoped RAII guards can't produce this; log loudly if something does. */
      static std::atomic<int> WarnCount {0};
      if (WarnCount.fetch_add(1, std::memory_order_relaxed) < 8) {
        LogMan::Msg::EFmt("[fexlock] WARN write-unlock with nested-shared={} mutex={} rev=ml442", OwnerSharedNest,
                          static_cast<void*>(&Futex));
      }
      OwnerSharedNest = 0;
    }
    if (OwnerWriteNest) {
      static std::atomic<int> WarnCount2 {0};
      if (WarnCount2.fetch_add(1, std::memory_order_relaxed) < 8) {
        LogMan::Msg::EFmt("[fexlock] WARN write-unlock with nested-write={} mutex={} rev=ml450", OwnerWriteNest,
                          static_cast<void*>(&Futex));
      }
      OwnerWriteNest = 0;
    }
    OwnerTeb = 0;
    OwnerTid = 0;
  }

  /* ml442 (#74 ROOT FIX): if the calling thread already write-owns this mutex,
   * grant shared access by nesting instead of parking behind ourselves.  Safe
   * against races: OwnerTeb can only equal OUR teb if we are the owner (no
   * other thread can store our teb), and while we own it nobody else clears
   * the stamp. */
  bool IosWriterSelfShared() {
    const uint64_t Teb = IosSelfTeb();
    if (!Teb || OwnerTeb != Teb) {
      return false;
    }
    OwnerSharedNest++;
    static std::atomic<int> LogCount {0};
    if (LogCount.fetch_add(1, std::memory_order_relaxed) < 20) {
      LogMan::Msg::EFmt("[fexlock] SELF-SHARED write-owner re-entry mutex={} nest={} ra={} rev=ml442",
                        static_cast<void*>(&Futex), OwnerSharedNest, __builtin_return_address(0));
    }
    return true;
  }

  bool IosWriterSelfSharedRelease() {
    const uint64_t Teb = IosSelfTeb();
    if (!Teb || OwnerTeb != Teb || !OwnerSharedNest) {
      return false;
    }
    OwnerSharedNest--;
    return true;
  }

  /* ml450: write→write recursion (nested compile's buffer-swap re-locks the
   * L' it already write-owns).  Same OwnerTeb==self race-freedom argument as
   * the shared grant; nest counter pairs lock()/unlock() LIFO. */
  uint32_t OwnerWriteNest {};

  bool IosWriterSelfWrite() {
    const uint64_t Teb = IosSelfTeb();
    if (!Teb || OwnerTeb != Teb) {
      return false;
    }
    OwnerWriteNest++;
    static std::atomic<int> WriteNestLog {0};
    if (WriteNestLog.fetch_add(1, std::memory_order_relaxed) < 20) {
      LogMan::Msg::EFmt("[fexlock] SELF-WRITE write-owner re-entry mutex={} nest={} ra={} rev=ml450",
                        static_cast<void*>(&Futex), OwnerWriteNest, __builtin_return_address(0));
    }
    return true;
  }

  bool IosWriterSelfWriteRelease() {
    const uint64_t Teb = IosSelfTeb();
    if (!Teb || OwnerTeb != Teb || !OwnerWriteNest) {
      return false;
    }
    OwnerWriteNest--;
    return true;
  }

  /* iOS-Madeira ml413: the ml413 wedge was read-owners=1 with the writer parked
   * behind it — the WRITE stamp above can't name a leaked READ hold. Ring of
   * live shared holds: acquire claims a zero slot, release clears one of the
   * caller's slots. Additionally each holder stamps TEB Instrumentation[8]
   * (0x16f8) with the mutex address while it holds the lock, so the unix-side
   * exception-delivery and thread-exit paths can spot "this thread holds a FEX
   * shared lock" and log the leak-in-progress ([deliver-hold]/[exit-hold]).
   * Slot 9 (0x1700) is the NotifyReadFile flag, slot 10 the wine PUMP beacon. */
  uint64_t ReadHolderTeb[16] {};
  uint32_t ReadHolderTid[16] {};

  static uint64_t IosSelfTeb() {
    uint64_t Teb = 0;
#ifdef ARCHITECTURE_arm64
    __asm volatile("mov %0, x18" : "=r"(Teb));
#endif
    return Teb;
  }

  void NoteReadAcquired() {
    const uint64_t Teb = IosSelfTeb();
    if (!Teb) {
      return;
    }
    /* ml415: slot 7 (0x16f0) = per-thread shared-hold depth. Without it, a
     * nested acquire+release pair wiped slot 8 while the outer hold remained,
     * blinding [census-hold]/[deliver-hold] (the ml414 false-negatives). */
    auto* Depth = reinterpret_cast<uint32_t*>(Teb + 0x16f0);
    if (++*Depth == 1) {
      *reinterpret_cast<uint64_t*>(Teb + 0x16f8) = reinterpret_cast<uint64_t>(&Futex);
    }
    for (size_t i = 0; i < 16; i++) {
      uint64_t ExpectedSlot = 0;
      if (std::atomic_ref<uint64_t>(ReadHolderTeb[i]).compare_exchange_strong(ExpectedSlot, Teb, std::memory_order_acq_rel)) {
        ReadHolderTid[i] = *reinterpret_cast<uint32_t*>(Teb + 0x48);
        return;
      }
    }
  }

  void NoteReadReleased() {
    const uint64_t Teb = IosSelfTeb();
    if (!Teb) {
      return;
    }
    auto* Depth = reinterpret_cast<uint32_t*>(Teb + 0x16f0);
    if (*Depth && --*Depth == 0) {
      *reinterpret_cast<uint64_t*>(Teb + 0x16f8) = 0;
    }
    for (size_t i = 0; i < 16; i++) {
      if (std::atomic_ref<uint64_t>(ReadHolderTeb[i]).load(std::memory_order_relaxed) == Teb) {
        ReadHolderTid[i] = 0;
        std::atomic_ref<uint64_t>(ReadHolderTeb[i]).store(0, std::memory_order_release);
        return;
      }
    }
  }
#else
  void NoteWriteAcquired() {}
  void NoteWriteReleased() {}
  void NoteReadAcquired() {}
  void NoteReadReleased() {}
  bool IosWriterSelfShared() {
    return false;
  }
  bool IosWriterSelfSharedRelease() {
    return false;
  }
  bool IosWriterSelfWrite() {
    return false;
  }
  bool IosWriterSelfWriteRelease() {
    return false;
  }
#endif
};

/* iOS-Madeira ml455 (#74 delivery-under-locks): every stall flavor left after
 * ml454 is one shape — a fault delivered while THIS thread's interrupted frame
 * holds emission locks (WPM shared / CodeBufferWriteMutex / lookup write), and
 * the guest SEH machinery then re-enters the compiler, which parks on those
 * same locks.  Detection is unambiguous at compiler ENTRY points: slot 7
 * (0x16f0, WPM shared-hold depth) and slot 6 (0x16e8, CodeBufferWriteMutex
 * stamp) are always zero there on synchronous paths (ExitFunctionLink releases
 * its brief shared scope before calling CompileBlock), so nonzero means an
 * interrupted frame below us.  Slot 3 (0x16d0, previously unused — slots 4-10
 * are taken, 0x1710 is past the Instrumentation array) carries the
 * "unpublished compile" mode as a DEPTH from CompileBlock down into the
 * backend, so the emission section can refuse buffer swaps (the ml452
 * TAIL-REFUSED lesson) without misreading its OWN normal-path holds. */
#if defined(_WIN32) && defined(ARCHITECTURE_arm64)
static inline uint64_t IosDeliveryProbeTeb() {
  uint64_t Teb = 0;
  __asm volatile("mov %0, x18" : "=r"(Teb));
  return Teb;
}
static inline bool IosEmissionLocksHeldBySelf() {
  const uint64_t Teb = IosDeliveryProbeTeb();
  if (!Teb) {
    return false;
  }
  return *reinterpret_cast<const uint32_t*>(Teb + 0x16f0) != 0 || *reinterpret_cast<const uint64_t*>(Teb + 0x16e8) != 0;
}
static inline void IosAdjustUnpublishedCompileDepth(int64_t Delta) {
  const uint64_t Teb = IosDeliveryProbeTeb();
  if (Teb) {
    *reinterpret_cast<uint64_t*>(Teb + 0x16d0) += static_cast<uint64_t>(Delta);
  }
}
static inline bool IosUnpublishedCompileActive() {
  const uint64_t Teb = IosDeliveryProbeTeb();
  return Teb && *reinterpret_cast<const uint64_t*>(Teb + 0x16d0) != 0;
}
#else
static inline bool IosEmissionLocksHeldBySelf() {
  return false;
}
static inline void IosAdjustUnpublishedCompileDepth(int64_t) {}
static inline bool IosUnpublishedCompileActive() {
  return false;
}
#endif
} // namespace FEXCore::Utils::WritePriorityMutex
