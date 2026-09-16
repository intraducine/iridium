# Constrained FEX arena: thread initialization and allocation overhead

## Observed failure

The native log supplied after the guest-headroom change records eight successful
`0x1ffff000` guest reservations. Wine and Unity/Mono are running. The translator
then fails the thirteenth call-return-stack reservation: `size=0x1002000`, largest
remaining gap `0xff0000`, inside the 1 GiB FEX interval. The old initializer adds
`0x1000` to the null result and scrubs that invalid address. Exception dispatch
then attempts guest callbacks before the thread's CPU area has been initialized.
This is separate from the preceding 4 GiB-arena run's failed guest allocation.

## Why the previous changes were insufficient

Earlier supplied host-log sections recorded a 16 GiB FEX reservation under a
`0x8000000000` task ceiling. Later native logs have a `0x7180000000` ceiling, with
only approximately 6 GiB in the usable high-address interval. A map-walk tail
above that ceiling is not allocatable. The logs do not establish what changed the
host task's ceiling, or identify the original first bad app commit by themselves.

`e44e9dbd` tried direct 16/8/4 GiB reservations before the legacy allocator. Its
4 GiB selection on the constrained layout left insufficient room for Unity.
`0e450f43` required guest headroom, selecting 1 GiB on that layout. It addressed
the observed guest shortage but did not test the translator's live-thread demand.
A test that only serves guest reservations misses this second failure.

## Corrections

- Keep the guest-headroom policy and host/guest isolation. Do not enlarge the FEX
  arena again, spill host allocations into guest space, change game files, or
  select behavior by executable name or device model.
- Apply an additive patch to pinned rpmalloc: 4 MiB spans instead of 16 MiB,
  with matching 4 MiB large pages. Existing medium pages are already 4 MiB.
  Classes with no room for a block plus header use the existing exact-size huge
  allocation path. Each thread's lightly populated heap therefore reserves less
  address space. Full 16 MiB call-return stacks and their guard geometry remain.
- Check stack reservation and commitment before publishing or scrubbing a
  call-return stack. The ARM64EC initializer cleans up and returns
  `STATUS_NO_MEMORY` before publishing dispatcher/thread state. It releases the
  thread-creation lock through its ordinary scoped return. Other frontends keep
  a fail-fast wrapper; this is not general recovery from every constructor OOM.
- Bound the existing `rpm_avail_check` diagnostic. Its 256-byte stack buffer was
  too short even for the ordinary `consume` corruption report, independently
  reproduced with undefined-behavior sanitization. Preserve the report rather
  than suppressing corruption warnings. This does not identify the origin of
  every reported allocator consistency problem.
- Apply both allocator patches transactionally on fresh and already-patched
  local sources. Include the patch/helper in native and Windows component reuse
  fingerprints so a build cannot silently reuse the old FEX DLL.

## Executable validation and limits

The regression executable compiles the actual pinned rpmalloc C implementation
and the production call-return-stack header. Only platform memory/syscall and
unrelated context boundaries are modeled. It holds eight approximately 512 MiB
guest reservations and image headroom in one 6 GiB anonymous mapping, with the
upper 1 GiB reserved exclusively for FEX. The FEX side exercises 28 simultaneously
live heaps, every span type, 28 full call-return stacks, L1 reservations, and four
16+8 MiB compiler workspaces. These are live heap states, not 28 simultaneously
executing OS threads or a complete replay of every game allocation.

The pre-compaction allocator exhausts the same workload. The revised allocator
peaks at 985,202,688 bytes in the 1 GiB arena and leaves guest sentinels intact.
Additional tests cover size/alignment boundaries including the large-to-huge
transition, reserve/commit failures and retry, repeated cleanup, old/new diagnostic
formatting, and local patch upgrade/conflict/idempotence. A scoped compilation of
the actual ARM64EC initialization prefix exercises its cleanup/status return and
checks that its mutex is unlocked.

These tests do not run the ARM64EC ABI, Wine, Metal, or UIKit on an iPhone. They
support the allocation and null-handling corrections, not a claim that Hollow
Knight now renders or that an unlimited number of guest threads can be created.
