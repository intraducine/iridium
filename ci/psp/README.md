# Explicit PSP host checks

Run manually with a trusted, already-built component matching the host OS/CPU:

```
python3 ci/check-ppsspp.py --component /path/ppsspp_libretro.so \
  --api-header /path/IridiumPSPAPI.h --assets /path/ppsspp/assets
```

The component must export `ir_ppsspp_boot_pending` and the Libretro functions used
by the current repository bridge. A mobile-device or simulator component is not
a host component. The API input may be the corresponding self-contained upstream
`libretro.h`; the runner stages it under the bridge's `IridiumPSPAPI.h` name.
Use `--repo-root` when reviewing these candidate tests outside the repository.

The runner compiles the actual repository `IRPSPBridge.c`, never a prototype copy.
The callback test includes that same source through its include path. Assertions
remain enabled. Each process has a timeout and a nonzero exit fails the check.
Only temporary storage receives generated ELF files, executables, copied assets,
and saves. No component build, dependency installation, network download, or
upstream source edit is performed. Nothing invokes this script from ordinary
unittest discovery or CI automatically.

The fixture is original MIPS code assembled by `make_fixture.py`, not console SDK,
firmware, game content, or a checked-in binary. It exercises a two-color frame,
controller-driven color change, and stereo square-wave audio. The checked
fixture bytes are deterministic. The 34 matched runtime assets are supplied
separately by the caller and copied into temporary storage.

Coverage: three playback/reopen cycles; copied video and bounded nonzero audio;
button press/release; duplicate-open exclusion; three cancellations before boot
pumping; malformed-ELF asynchronous failure and cleanup; the same lifecycle with
an existing alternate signal stack; serialized teardown on another thread while
preserving both threads' alternate stacks; geometry/timing, video/audio, digital
and analog callback contracts.

Not covered: iOS or physical devices, commercial PSP compatibility, save-game
persistence, actual audibility/output hardware, all emulated button mappings,
performance thresholds, dialog/font appearance, and injected stack-restore
failure. These checks do not certify those behaviors.

Source files in this directory are original Iridium fixtures/tests under
AGPL-3.0-only. Supplied PPSSPP components, API headers, and assets retain their
own licenses; this runner does not replace their notice/provenance obligations.
