# Iridium FEX iOS Bridge

This directory holds the Iridium-owned iOS bridge surface for the FEX fork.

## Supported build mode

- required configure mode: `IRIDIUM_IOS_EMBEDDED=ON`
- canonical build entrypoint: `iridium/ios/build_embedded_translator.sh`
- canonical platform selector: `--platform device|simulator|host`
- canonical output artifact when using the default build root: `build-iridium-ios-<platform>/artifacts/libiridium-fex-ios-embedded.a`

Run:

```bash
./iridium/ios/build_embedded_translator.sh
```

The script is the only supported Phase 2C producer for the embedded translator
archive. It configures the fork in embedded mode, builds the
`iridium-fex-ios-embedded` target, and fails if the embedded manifest or the
canonical archive path is missing.

Platform mapping:

- `--platform device` is the default and emits an archive in `build-iridium-ios-device`; when the default build root is used the script also refreshes the SDK alias `build-iridium-ios-iphoneos`
- `--platform simulator` emits an archive in `build-iridium-ios-simulator`; when the default build root is used the script also refreshes the SDK alias `build-iridium-ios-iphonesimulator`
- `--platform host` emits a `macosx` artifact in `build-iridium-ios-host`
- non-host default-root builds also refresh `build-iridium-ios-current` as a compatibility symlink, but the product app and SDK consumers should use the SDK-specific alias roots above rather than relying on `build-iridium-ios-current`

Only the host build runs the embedded bridge executable tests. Device and
simulator builds are compile-only verification paths.

## Canonical verification

Use the host build script plus `ctest` as the supported fork-local verification path:

```bash
./iridium/ios/build_embedded_translator.sh --platform host
ctest --test-dir build-iridium-ios-host --output-on-failure
```

The host `ctest` suite is expected to cover:

- bridge contract checks
- forced `required`, `unavailable`, and `ready` probe outcomes
- a real host opt-in split RX/RW allocator probe that allocates, writes, and executes through the same path the bridge uses

Device and simulator verification remain compile-only from this fork; physical-device proof is documented in the main app repo runbook.

## Bridge ownership

This repo owns the fork-local C bridge that `iridium-runtime-sdk` consumes:

- `iridium_fex_ios_probe_readiness`
- `iridium_fex_ios_validate_launch`
- `iridium_fex_ios_start_guest_execution`
- `iridium_fex_ios_poll_guest_state`
- `iridium_fex_ios_collect_guest_exit`

The bridge owns:

- translator artifact presence detection
- explicit external-JIT gating
- direct-launch-only enforcement
- win64-only launch validation
- deterministic session lifecycle and terminal reporting

The bridge does not own:

- Wine userland staging
- final runtime-bundle import into the main app repo
- physical-device proof

## Current execution behavior

`probe_readiness` only reports launchable when both the translator archive and
explicit JIT-ready input are present. `validate_launch` rejects malformed
runtime contracts, non-direct launches, and non-win64 guest assumptions.
If metadata says a debugger-backed helper bootstrap is still required,
readiness remains blocked before host fallback readiness can report success.
Host builds surface the concrete helper-bootstrap blocker unless the bootstrap
command path is simulated for tests or completed by a supported helper.
Non-smoke guest execution now wires the embedded Darwin syscall bridge into the
FEXCore context instead of using dummy syscall handlers. The upstream FEX
`LinuxEmulation` target is Linux frontend reference code here; linking or
detecting it is not treated as proof that guest syscalls can be routed to iOS
native APIs.
When the translator archive and JIT-ready input are present, `probe_readiness`
can now report `launch_ready=1` with `launch_status=ready`.
The bridge includes a separately tested minimal Darwin syscall handler for the
first embedded Wine subset: file reads (`open`, `read`, `close`),
interpreter file access (`access`, `openat`, `pread64`, `lseek`), Linux-to-Darwin
open flag translation, explicit x86-64 Linux stat packing (`fstat`,
`newfstatat`), memory mapping/protection (`mmap`, `mprotect`, `munmap`, `brk`),
Linux directory enumeration (`getdents64`), prefix filesystem setup (`chdir`,
`mkdir`, `symlink`), vectored writes (`writev`),
diagnostics/process hints (`write`, `prctl(PR_SET_NAME)`,
`prctl(PR_SET_VMA/PR_SET_VMA_ANON_NAME)`), uid/gid queries, loader startup calls
(`getpid`, `getppid`, `gettid`, `set_tid_address`, `set_robust_list`,
`clock_gettime`), a non-blocking futex compatibility subset (`FUTEX_WAIT`
mismatch/zero-timeout handling and `FUTEX_WAKE`), loader identity/path queries
(`uname`, `getcwd`, `readlink`, `readlinkat`), CPU probe fallbacks (`getcpu`,
`sched_getaffinity`, `sched_setaffinity`, `rseq`), resource probing
(`prlimit64` stack-limit queries), guest exit capture (`exit`, `exit_group`),
guest-side signal setup bookkeeping (`rt_sigaction`, `rt_sigprocmask`), limited
descriptor control (`fcntl`), pipes (`pipe`, `pipe2`), and Unix socket client
calls (`socket`, `connect`, `setsockopt`, `sendmsg`, `recvmsg` with `SCM_RIGHTS`
translation), and `arch_prctl` FS/GS base operations as a
foundation for the iOS bridge. That is still not full Wine launch support.
Unsupported syscalls return the Linux ABI `ENOSYS` value so guest libc fallback
paths do not misinterpret Darwin errno numbers.

`start_guest_execution` now wires real in-process guest execution:

- Parses the Wine x86-64 ELF binary and maps all PT_LOAD segments at their
  canonical virtual addresses with correct per-segment permissions.
- Treats `wine-preloader` as a discovery/validation artifact only when a sibling
  Unix-side `wine`/`wine64` companion exists. Embedded execution loads the
  companion directly, maps its `PT_INTERP` program interpreter from the bundled
  userland root, and sets `WINELOADERNOEXEC=1` so Wine stays in the in-process
  FEX image instead of re-execing through the preloader contract.
- The host Darwin bring-up path now gets through Wine shared-data setup,
  `wineserver` socket/message exchange, Wine syscall-frame initialization, direct
  target PE mapping, and repeated deterministic MinGW x64 `exit0.exe` terminal
  completion with the guarded native host `wineserver` hook. The hook is a
  host-only smoke gate, not the final iOS process model.
- Zero-fills BSS (p_memsz > p_filesz).
- Applies dynamic relocations: RELA/REL tables, JMPREL/PLT, R_X86_64_RELATIVE,
  R_X86_64_64, R_X86_64_GLOB_DAT, R_X86_64_JUMP_SLOT, and the x86-64 TLS
  relocation family (`DTPMOD64`, `DTPOFF64`, `TPOFF64`). Undefined weak symbols
  resolve to 0. Unresolved strong data symbols still produce a hard load
  failure, while unresolved PLT function imports are patched to a deterministic
  guest-side `UD2` trap stub instead of blocking the initial load.
- Builds an amd64 System V initial stack image: argc, argv[], envp[], auxv
  entries (AT_PHDR, AT_PHENT, AT_PHNUM, AT_BASE, AT_ENTRY, AT_RANDOM,
  AT_PAGESZ, AT_NULL). `IridiumFEXIOSLaunchPaths` also carries
  `launch_arguments`; the runtime host forwards JSON `launchArguments` after
  the selected Windows executable path so direct launches do not silently drop
  game-specific command-line arguments.
- Creates a FEXCore context, calls InitCore(), dispatches the guest via
  CreateThread(entrypoint, stack_pointer) and ExecuteThread(). Guest `exit` and
  `exit_group` are trapped back to the host runtime so session collection writes
  a terminal result instead of letting the unsupported syscall crash the host.
  On macOS host harness runs, the bridge enables the split RX/RW code allocator
  before InitCore() unless a caller selected a code allocator explicitly; this
  avoids null dispatcher code-buffer writes when the normal executable mapping
  path is unavailable.
- Before non-smoke execution, probes whether the host process can reserve
  Wine's complete high-address startup arena. When `0x7ffe0000` is blocked by
  arm64 Darwin's default 4GB `__PAGEZERO`, the bridge injects Wine's
  `IRIDIUM_WINE_USER_SHARED_DATA_ADDRESS` fallback and verifies enough adjacent
  space for shared data, TEB blocks, and Wine's virtual-address tracking heap.

Session polling and collection are deterministic. The smoke execution path
(IRIDIUM_FEX_IOS_SMOKE_EXECUTION=1) is a short-circuit before FEXCore init for
embedded host tests.

Remaining gaps before physical-device proof:
- The current in-process direct-address model uses a Wine high-address fallback
  for `KUSER_SHARED_DATA` and first TEB reservation when the low 4GB range is
  reserved. The canonical rebuilt Wine userland now carries that source change;
  generated binary patches are only local diagnostic artifacts.
- No complete syscall bridge: non-smoke execution can enter Wine and now reaches
  terminal runtime results, but the guest still lacks the Wine-grade iOS syscall
  surface needed for successful process/thread/file/signal behavior.
- Wine now maps a deterministic MinGW x64 `exit0.exe` directly when the guarded
  host-only diagnostic native `wineserver` hook is enabled, and no longer falls
  back through `start.exe` for relocated-main-image success. The host smoke path
  now produces repeated completed terminal results without simulators or devices,
  but it is not a final iOS process model.
- Direct `PT_INTERP` startup is intentionally narrow: host-side relocation is
  still only for loaderless payloads, while `ld-linux` handles dynamic Wine
  relocation in guest execution.
- No full runtime TLS block/thread setup beyond applying static TLS relocation
  entries during ELF load.
