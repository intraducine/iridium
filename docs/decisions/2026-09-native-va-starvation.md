# Native launch address-space starvation and host-thread close fault

## Evidence

Two native logs supplied with the failing Actions #55 test show the same
sequence. They contain native loader/FEX output omitted from the earlier
host-only export. These observations supersede guesses based on that omission:

- The task's actual VM ceiling is `0x7180000000`, not the apparent map-walk end
  `0x8000000000`. JIT allocation succeeds, Wine connects to its server, and
  `UnityPlayer.dll` loads. This is not a missing-JIT or missing-Wine-start case.
- Wine adopts the application's FEX range `0x7080000000..0x7180000000` (4 GiB).
  The remaining high-address hole is only about 2 GiB. A later inventory shows
  3,936 MiB still uncommitted in the FEX reservation, while the guest cannot
  obtain another large reservation. A larger FEX reservation is not necessarily
  a healthier runtime: the game needs separate address space.
- Unity requests `0x1ffff000` bytes (approximately 512 MiB) repeatedly. Four
  reservations succeed, including one low-address reservation. The fifth fails
  in the ordinary guest search with `STATUS_NO_MEMORY`, immediately followed by
  a write through address zero and repeated `c0000005` exceptions in Unity code.
- The steering attempt `0x7400000000..0x7080000000` is also inverted. It is not
  sufficient evidence of the fatal failure by itself: the first four attempts
  fall back successfully. The fifth ordinary allocation fails as well.
- Closing the game causes a separate native fault at address `0x8a8`:
  `requestClose -> requestGuestClose -> madeira_request_guest_close ->
  NtUserGetForegroundWindow -> get_shared_input`. The caller is the UIKit
  thread, which has no Wine TEB. Moving this call to a GCD worker would not
  establish a Wine TEB either.

## Changes

`NativePool.c` now verifies a combined mappable interval for both the FEX arena
and guest headroom. It tries 16, 8, 4, 2 and 1 GiB arenas, requiring at least
three times the arena size, and at least 4 GiB, below the arena for the guest.
A fixed Mach allocation without overwrite proves the interval is available;
no pages are touched. After protection succeeds, the lower headroom portion is
released and only the upper arena is retained and published. A probe or
publication error prevents launch; the old unbudgeted fallback is not used.
Inherited environment strings are not accepted as ownership of a reservation.

On the measured 6 GiB high-address layout this selects a 1 GiB FEX arena,
leaving about 5 GiB in that window for the guest instead of about 2 GiB. The
policy reads the current process limit and checks real allocation success; it
contains no device model, game executable, Steam ID or fixed target address.
On fragmented or small maps it can refuse launch rather than take nearly all
available space. Headroom is verified at startup, not guaranteed forever, and
this conservative partition can select a smaller FEX arena on other layouts.

The host close adapter no longer invokes Wine's NtUser functions. It selects
the Swift adapter's existing Alt+F4 fallback, which queues balanced key events
through `winios_post_key` for processing on the guest side. This avoids the
observed host-thread fault; it is not a forced termination mechanism. An
unresponsive guest still produces an unconfirmed-shutdown result.

## Validation and limits

The production C reservation functions are compiled with an ownership-aware
Mach VM model and undefined-behavior sanitization. Twenty-one cases cover the
measured layout, several other ceilings, fragmentation, inaccessible gaps,
rollback, publication failure, stale environment values and repeat calls. The
old 4 GiB allocation reproduces failure of the fifth large guest reservation;
the budgeted policy serves eight in the same model without overlapping FEX.

The real C close adapter is tested on the main thread and a pthread with fatal
NtUser stubs. A scoped test compiles the actual Swift close helper with that C
adapter and verifies both ordinary and forced fallback queue the key-down and
key-up pairs after releasing held keys. UIKit and the real guest queue are not
executed by that test.

These tests validate the identified allocation-policy and close-call defects.
They do not establish that Hollow Knight or any other game now renders on a
real device. Remaining engine/FEX/graphics defects require device testing; the
repeated rpmalloc repair messages in these logs are not silently declared fixed.
