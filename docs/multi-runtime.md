# Runtime architecture

This branch adds a real interpreter core behind the live Madeira frontend. It
does not revive the excluded legacy Linux backend or duplicate Madeira's Steam,
JIT or Wine state machines. The original Windows library remains authoritative.

## Boundary and selection

`IridiumGame` exposes shared library identity, title, artwork and platform while
retaining either the original Madeira entry or an independent console record.
The registry declares supported platforms, JIT policy, pause capability and
whether stopping requires a process restart. Driver state comes from the actual
backend. Only Madeira and SameBoy are selectable; a research candidate is not a
working runtime entry.

Madeira's driver delegates launch and graceful close to its existing callbacks.
Four declared launch guards prevent Windows, Dock and delayed-JIT continuations
from starting while the console core owns the process. The console driver also
checks Wine/server liveness and Madeira's session count. Switching away from a
previous Windows session requires an app restart because its native process
state is not safely unloadable. SameBoy sessions can stop and restart normally.

For new engines, `none` always selects the interpreter, `optional` falls back to
the interpreter when JIT is unavailable, and `required` fails preflight. A
debugger attachment alone is not a promise that an engine's allocator can run:
an optional/required-JIT adapter needs its own executable-memory preparation and
failure handling. No new executable code is downloaded at runtime.

## First core

`vendor/SameBoy` is pinned to the official 1.0.3 source at
`208ba4afabffab9edde416f2dbb8ae459e34adb8`.
The build compiles its 21 Core/Libretro/generated-boot C units without RetroArch
or libretro-common. It generates replacement boot-ROM arrays from reviewed
hexadecimal data assembled from upstream's replacement boot code. The source
and output hashes must match before compiling. Commercial games, console
keys and proprietary BIOS files are not supplied.

The builder first inventories defined symbols, then recompiles every core and
adapter symbol into a private namespace. Hiding exports alone would not prevent
duplicate static-link definitions. This isolates all exported C symbols,
not just `retro_*`. An audit rejects unisolated symbols. Compiler flags, source
count, source pin, target and archive hash are recorded in the build output.

The generated Libretro adapter calls the existing public `GB_set_sample_rate`
API with 48 kHz instead of clock/2. The upstream Core and APU are unchanged.
This keeps ordinary frames inside the bounded audio queue without silently
dropping half of the high-rate upstream output. The adapted source hash and
sample rate are recorded in the build manifest.

The C bridge owns one interpreter instance, bounds ROM/video/audio buffers,
accepts only the supported software pixel format, and copies frame data before
the next step. Audio callbacks consume dropped overflow rather than causing a
retry loop. Actual core timing supplies frame and sample rates; the audio mixer
converts to the device output rate. UI deliveries and queued audio are bounded.

Touch controls, arrow keys with Z/X/Space/Return, and controller sampling route
to the active console instance. Controller Menu+Options opens pause; Select
resumes and Back requests Quit while paused. Backgrounding pauses and saves;
the user explicitly resumes. Madeira controller handlers are not replaced.

## Persistence and recovery

Console records live in `Documents/IridiumRuntimes/library.json`, version 1.
Their ROMs are copied into UUID-named folders. Saves are isolated by runtime and
game UUID. Files-provider imports are coordinated and bounded. Paths cannot
escape the root or pass through symlinks. A corrupt/newer library is preserved
and blocks writes rather than being replaced with an empty library.

Removing an entry keeps ROM and save files. A failed import persistence may
leave an unlisted copy for recovery. Madeira's library and Wine saves are never
rewritten by console import. There is no automatic merge of save formats across
different cores. Battery RAM and RTC data are saved periodically and on pause
or Quit. A save-write failure keeps the core paused in memory for a retry.

## Building and testing

The existing manual frontend app build initializes SameBoy and compiles its
static archive before Xcode links the generated project. To compile one Apple
slice directly, use an explicit SDK and target:

```sh
python3 ci/build-sameboy.py --sdk iphoneos --target arm64-apple-ios18.0 --output .build/sameboy/iphoneos
python3 ci/build-sameboy.py --sdk iphonesimulator --target arm64-apple-ios18.0-simulator --output .build/sameboy/iphonesimulator
```

Ordinary source checks do not trigger emulator compilation. The following
explicit check builds the real core and executes an original synthetic
cartridge, with no downloaded game assets:

```sh
python3 ci/check-sameboy.py
python3 -B -m unittest discover -s ci -p 'test_multi_runtime.py'
```

`ci/sameboy-bootroms.json` contains upstream replacement boot data and hashes,
not proprietary console firmware. Ordinary builds need no RGBDS installation.
To reproduce it, build RGBDS 0.9.4 from the unchanged source checkout at
`https://github.com/gbdev/rgbds` commit
`d1829ed92327a9f9210ffd45d865331f24dfa4e6` using its documented host compiler,
Bison, Make/CMake and libpng prerequisites. Then run:

```sh
python3 ci/sameboy_bootroms.py --rgbds /path/to/rgbds-source --output /tmp/sameboy-bootroms.json
cmp ci/sameboy-bootroms.json /tmp/sameboy-bootroms.json
```

The generator writes only to a temporary build directory and a new output
file. It verifies tool versions and source hashes; the vendor checkout remains
unchanged. A source archive includes the original assembly and this recipe.

The core fixture checks CPU-executed battery markers, button press/release,
frames, audio, repeated start/stop, and SRAM/RTC round trips. Foundation tests
execute real registry, ownership and persistence code when Swift is installed.
Their results establish host behavior only. Apple compilation, simulator
interaction, physical-device rendering, audio, controller behavior, save
recovery, LiveContainer operation and performance are separate evidence gates.

## Extending the registry

PPSSPP is a practical next candidate, with an iOS interpreter fallback in its
Libretro interface. Its hardware/software display path and executable-memory
adapter still need integration and validation. Advanced engines must also
isolate C++ dependencies, graphics loaders and process-lifetime global state.

Husk is a separate Android candidate. Its native Android engine launchers may
remain loaded for the entire process lifetime, requiring an explicit restart
boundary. Its QEMU configuration and transitive license manifest need review
before combining it with this application. Static versus dynamic packaging
does not by itself resolve license compatibility.

MeloNX's custom license conditions require separate review; it is not enabled.
Other candidates are deferred until an actual driver, legal inputs, source
collection, tests and a supported launch path exist. This document does not
claim PSP, GameCube, Wii, 3DS, PS2, Dreamcast, Switch, Vita, Xbox or Android support.
