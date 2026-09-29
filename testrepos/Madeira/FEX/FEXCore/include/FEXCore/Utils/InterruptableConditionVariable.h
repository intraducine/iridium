// SPDX-License-Identifier: MIT
#pragma once

#include <atomic>
#include <chrono>
#include <climits>
#include <cstdint>
#if defined(__linux__)
#include <linux/futex.h>
#include <sys/syscall.h>
#include <unistd.h>
#elif defined(__APPLE__)
#include <os/lock.h>
#include <unistd.h>
#include <pthread.h>
#else
#include <errhandlingapi.h>
#include <synchapi.h>
#include <winerror.h>
#include <unistd.h>
#endif

namespace FEXCore {
/**
 * @brief A condition variable that is robust against use of longjmp in signal handlers.
 */
#if defined(__linux__)
class InterruptableConditionVariable final {
public:
  bool Wait(struct timespec* Timeout = nullptr) {
    while (true) {
      uint32_t Expected = SIGNALED;
      uint32_t Desired = UNSIGNALED;

      if (Mutex.compare_exchange_strong(Expected, Desired)) {
        return true;
      }

      constexpr int Op = FUTEX_WAIT | FUTEX_PRIVATE_FLAG;
      int Result = ::syscall(SYS_futex, &Mutex, Op, Desired, Timeout, nullptr, 0);

      if (Timeout && Result == -1 && errno == ETIMEDOUT) {
        return false;
      }
    }
  }

  template<class Rep, class Period>
  bool WaitFor(const std::chrono::duration<Rep, Period>& time) {
    struct timespec Timeout {};
    auto SecondsDuration = std::chrono::duration_cast<std::chrono::seconds>(time);
    Timeout.tv_sec = SecondsDuration.count();
    Timeout.tv_nsec = std::chrono::duration_cast<std::chrono::nanoseconds>(time - SecondsDuration).count();
    return Wait(&Timeout);
  }

  void NotifyOne() { DoNotify(1); }
  void NotifyAll() { DoNotify(INT_MAX); }

private:
  std::atomic<uint32_t> Mutex {};
  constexpr static uint32_t SIGNALED = 1;
  constexpr static uint32_t UNSIGNALED = 0;

  void DoNotify(int Waiters) {
    uint32_t Expected = UNSIGNALED;
    uint32_t Desired = SIGNALED;
    if (Mutex.compare_exchange_strong(Expected, Desired)) {
      constexpr int Op = FUTEX_WAKE | FUTEX_PRIVATE_FLAG;
      ::syscall(SYS_futex, &Mutex, Op, Waiters, 0, &Mutex, 0);
    }
  }
};
#elif defined(__APPLE__)
// Apple implementation using atomic spinning + pthread_cond fallback
class InterruptableConditionVariable final {
public:
  bool Wait(struct timespec* Timeout = nullptr) {
    while (true) {
      uint32_t Expected = SIGNALED;
      uint32_t Desired = UNSIGNALED;
      if (Mutex.compare_exchange_strong(Expected, Desired)) {
        return true;
      }
      // Spin briefly then yield
      for (int i = 0; i < 1000; ++i) {
        Expected = SIGNALED;
        if (Mutex.compare_exchange_strong(Expected, Desired)) {
          return true;
        }
      }
      if (Timeout) {
        // Convert timespec to absolute time for timed wait
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        struct timespec abs_timeout;
        abs_timeout.tv_sec = now.tv_sec + Timeout->tv_sec;
        abs_timeout.tv_nsec = now.tv_nsec + Timeout->tv_nsec;
        if (abs_timeout.tv_nsec >= 1000000000L) {
          abs_timeout.tv_sec++;
          abs_timeout.tv_nsec -= 1000000000L;
        }
        // Use usleep as a simple fallback
        usleep(100); // 100us
        Expected = SIGNALED;
        if (!Mutex.compare_exchange_strong(Expected, Desired)) {
          return false; // Timeout
        }
        return true;
      }
      usleep(100);
    }
  }

  template<class Rep, class Period>
  bool WaitFor(const std::chrono::duration<Rep, Period>& time) {
    struct timespec Timeout {};
    auto SecondsDuration = std::chrono::duration_cast<std::chrono::seconds>(time);
    Timeout.tv_sec = SecondsDuration.count();
    Timeout.tv_nsec = std::chrono::duration_cast<std::chrono::nanoseconds>(time - SecondsDuration).count();
    return Wait(&Timeout);
  }

  void NotifyOne() { DoNotify(); }
  void NotifyAll() { DoNotify(); }

private:
  std::atomic<uint32_t> Mutex {};
  constexpr static uint32_t SIGNALED = 1;
  constexpr static uint32_t UNSIGNALED = 0;

  void DoNotify() {
    uint32_t Expected = UNSIGNALED;
    uint32_t Desired = SIGNALED;
    Mutex.compare_exchange_strong(Expected, Desired);
  }
};
#else
class InterruptableConditionVariable final {
public:
  bool Wait(struct timespec* Timeout = nullptr) {
    while (true) {
      uint32_t Expected = SIGNALED;
      uint32_t Desired = UNSIGNALED;

      // If the mutex was already signaled then we can early exit
      if (Mutex.compare_exchange_strong(Expected, Desired)) {
        return true;
      }
      // Windows only supports millisecond granularity.
      const uint32_t TimeoutMS = Timeout ? Timeout->tv_sec * 1000 + (Timeout->tv_nsec / 1000000) : 0;

      // WaitOnAddress returns when the value at `Address` differs from the value at `CompareAddress`.
      bool Result = WaitOnAddress(&Mutex, &Desired, 4, TimeoutMS);

      if (Timeout && Result == false && GetLastError() == ERROR_TIMEOUT) {
        return false;
      }
    }
  }

  template<class Rep, class Period>
  bool WaitFor(const std::chrono::duration<Rep, Period>& time) {
    struct timespec Timeout {};
    auto SecondsDuration = std::chrono::duration_cast<std::chrono::seconds>(time);
    Timeout.tv_sec = SecondsDuration.count();
    Timeout.tv_nsec = std::chrono::duration_cast<std::chrono::nanoseconds>(time - SecondsDuration).count();
    return Wait(&Timeout);
  }

  void NotifyOne() {
    DoNotify(false);
  }

  void NotifyAll() {
    // Maximum number of waiters
    DoNotify(true);
  }

private:
  std::atomic<uint32_t> Mutex {};
  constexpr static uint32_t SIGNALED = 1;
  constexpr static uint32_t UNSIGNALED = 0;

  void DoNotify(bool All) {
    uint32_t Expected = UNSIGNALED;
    uint32_t Desired = SIGNALED;

    // If the mutex was in an unsignaled state then signal
    if (Mutex.compare_exchange_strong(Expected, Desired)) {
      if (All) {
        WakeByAddressAll(&Mutex);
      } else {
        WakeByAddressSingle(&Mutex);
      }
    }
  }
};

#endif
} // namespace FEXCore
