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

## Native iOS player

The active PSP path now stages the upstream v1.20.4 iOS player, not this legacy
Libretro fixture host. Native validation is separate from the fixtures above.
The native component checks its linked H.264 decoder using an original red frame
before a session can open. Regenerate that source fixture with an installed FFmpeg:

```sh
ffmpeg -f lavfi -i color=c=red:s=16x16:r=1 -frames:v 1 -c:v libx264 -profile:v baseline -x264-params keyint=1:bframes=0 -bsf:v filter_units=remove_types=6 -f h264 red-frame.h264
```

The output is represented as the byte array in IRPPSSPPCodecCheck.c; game files
and proprietary firmware are not fixture inputs. A passed fixture establishes
one linked H.264 decode, not God of War compatibility. Native GPU operation,
audio output, settings/save persistence, lifecycle and the actual subtitle
transition still require an Apple build and device evidence.

Run a source-built codec check explicitly on an Apple Silicon Mac:

```sh
python3 ci/check-ppsspp-native-codec.py --output .build/ppsspp/host-codec-check
```

This uses the exact selected FFmpeg revision and upstream codec options, builds
out of tree and executes the same check used at native session startup. It does
not certify iPhone decoding, graphics or game compatibility.
