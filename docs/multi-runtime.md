# Runtime architecture

Dolphin, Azahar, Play!, and Flycast builds, storage/input adapters and
physical-device verification requirements are documented in
[console-engines.md](console-engines.md).

This branch adds a real interpreter core behind the live Madeira frontend. It
does not revive the excluded legacy Linux backend or duplicate Madeira's Steam,
JIT or Wine state machines. The original Windows library remains authoritative.

## Boundary and selection

`IridiumGame` exposes shared library identity, title, artwork and platform while
retaining either the original Madeira entry or an independent console record.
The registry declares supported platforms, JIT policy, pause capability and
whether stopping requires a process restart. Driver state comes from the actual
backend. Madeira, SameBoy and the compiled-in PSP adapter are selectable. A research
candidate without a bundled driver is not a working runtime entry.

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

`vendor/SameBoy` is pinned to the official 1.0.4 source at
`98da08c3117a7bf39c7329fc662c0d18cb54707d`.
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

The unchanged Libretro adapter uses its target-sample-rate environment API
at 96 kHz, matching standalone iOS. The host selects CGB E for ordinary DMG/CGB
cartridges, SGB2 for SGB-capable DMG headers, modern-balanced color correction
and accurate high-pass filtering. CGB replacement boot code can therefore
colorize DMG games, without frontend tinting. The game viewport omits SGB borders.
The build manifest records the complete source/header/boot/recipe fingerprint,
flags, archive and private-namespace hashes; app generation rejects stale cores.

The C bridge owns one interpreter instance, bounds ROM/video/audio buffers,
accepts only the supported software pixel format, and copies frame data before
the next step. Audio callbacks consume dropped overflow rather than causing a
retry loop. Actual core timing supplies frame and sample rates; the audio mixer
converts to the device output rate. UI deliveries and queued audio are bounded.
SameBoy playback prefills 50 ms and caps queued audio at 150 ms. A monotonic
frame clock recovers coalesced timer events with at most three steps per event;
long stalls discard timing debt. Empty audio queues prefill again. Pause clears
queued samples and starts a fresh clock on resume. Logs record queue duration,
underruns, dropped frames, timer delays and core/output rates. These measures
address host buffering gaps; real-device crackling still requires comparison.
For cartridges without an RTC, old unused clock files are preserved and ignored.

Touch controls, arrow keys with Z/X/Space/Return, and controller sampling route
to the active console instance. Controller Menu+Options opens the player menu.
Directional input selects a menu row, A activates it, and B goes back. Closing
uses a separate confirmation with Cancel selected initially. Backgrounding
pauses and saves; the user explicitly resumes. Madeira controller handlers are
not replaced.

## Shared frontend experience

The shipping Madeira frontend uses shared app-owned control faces, menu rows,
confirmation UI, artwork storage and import entry points. Platform labels and
available actions follow each runtime's capabilities. Landscape console video
aspect-fits the available viewport before translucent controls are overlaid;
keyboard mappings live under Player Menu > Help. Connecting a usable physical
controller hides touch controls, with a temporary override in Controls.
Windows retains its existing editable input layouts and native input delivery.

Library covers use select-first interaction. Touch scrolling owns the carousel
through dragging and deceleration; controller navigation requests a scroll
explicitly. Backdrops retain the displayed image while replacement artwork
loads and crossfade when it is ready. Reduced-motion settings remove the fade.

Add Game starts with Files or Steam. Supported console files are inspected and
routed to their adapter. A selected Windows folder can include dependencies;
selecting only an EXE copies only that file. Imports preserve the source files.
There is no migration screen. Existing library IDs and save locations remain
valid; these presentation changes do not require reimporting existing entries.

Game Options provides shared title and artwork editing. Steam metadata supplies
Windows artwork; GB/GBC/PSP use the public per-platform Libretro thumbnail
catalogs. Automatic matching accepts a unique normalized title, while ambiguous
matches require a choice. Catalog outages do not block play, and local images
can be selected manually. Artwork records remain separate from launch/save
records, and late automatic results cannot replace a newer manual choice.

Touch and keyboard transitions are retained until an actual native input poll.
Each source has bounded queues, with the D-pad submitted as one atomic mask to
avoid invented opposing directions. Pause, focus loss and session changes clear
pending input. This prevents short event-driven taps disappearing between
frames; physical controllers still use sampled state, and slow emulation is a
separate performance limitation.

## Persistence and recovery

Console records live in `Documents/IridiumRuntimes/library.json`, version 1.
Their ROMs are copied into UUID-named folders. Saves are isolated by runtime and
game UUID. Files-provider imports are coordinated and bounded. Paths cannot
escape the root or pass through symlinks. A corrupt/newer library is preserved
and blocks writes rather than being replaced with an empty library.

Removing an entry keeps ROM and save files. A failed import persistence may
leave an unlisted copy for recovery. Madeira's library and Wine saves are never
rewritten by console import. There is no automatic merge of save formats across
different cores. SameBoy battery RAM and RTC data are saved periodically and on pause
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

The embedded native PSP integration is described below. JIT allocator
verification and physical-device acceptance remain separate work. Advanced engines must also isolate
C++ dependencies, graphics loaders and process-lifetime global state.

Husk is a separate Android candidate. Its native Android engine launchers may
remain loaded for the entire process lifetime, requiring an explicit restart
boundary. Its QEMU configuration and transitive license manifest need review
before combining it with this application. Static versus dynamic packaging
does not by itself resolve license compatibility.

MeloNX's custom license conditions require separate review; it is not enabled.
Other candidates are deferred until an actual driver, legal inputs, source
collection, tests and a supported launch path exist. This document does not
claim GameCube, Wii, 3DS, PS2, Dreamcast, Switch, Vita, Xbox or Android support.

## PSP component

PPSSPP is pinned to published v1.20.4 at
`fa50bb1976065c4f8b1b47af227d367fe9771555`. Iridium embeds upstream's native iOS
player in a separate dylib with an audited C interface. Its UI, codecs, graphics,
configuration and full resource tree remain available. Generated platform hooks
replace app/window ownership, route restart/exit through Iridium, choose each
game's existing memory stick and drain render threads while the main run loop
can service graphics callbacks. Emulator HLE, CPU, GPU and serialization source
are unchanged. Madeira remains at its existing exact pin and dependencies.

Imports accept bounded PSP ELF, ISO, CSO v0/v1 and PBP headers. Each game retains
its UUID memory-stick directory. Upstream manages its configuration, saves and
advanced settings in that directory. New memory sticks start with OpenGL,
2× resolution and the IR interpreter. Each game's **Use JIT** option defaults
off, including existing records. Enabling it uses the same app-level
`JITCoordinator` and Launch Support configuration as Windows. The coordinator's
single-flight gate also covers Shortcut cleanup. Cancelling a console launch
discards its continuation without terminating a debugger helper or resuming a
different game later. PSP holds activation admission through native validation
and releases it after restoring the Shortcut's network changes, before starting
either player mode. Cancellation waits for any active native probe to acknowledge
completion before that cleanup; stale cleanup cannot release a later owner.
PSP cleanup does not acquire debugger ownership: it sends no private detach RPC
and does not replace SIGTRAP, for either a ready debugger or a newly enabled helper.

Activation is followed by a PPSSPP-specific check of its own 16 MB allocation,
upstream W^X protection and cache path, generated ARM64 execution, and rewriting
and executing the same page again. Only a successful check consumed by the
next native player exposes JIT capability. An activation or check failure
starts the IR interpreter and reports the reason in PSP Settings. A stalled
probe retains ownership and requires restart; it cannot safely be abandoned
under a new player. A Madeira JIT lease alone never enables PPSSPP JIT. The
native adapter does not substitute Madeira's split RX/RW allocator for
PPSSPP's upstream allocator. Platforms that reject that allocator fall back.
The execution guard also declines to run when a custom fault handler is already
installed; it does not emulate another handler's masks, flags or alternate stack.
The effective CPU/graphics configuration is logged separately from the option.

JIT attempts also keep a private diagnostic journal in
`Documents/iridium-psp-jit-stages.log` and one `.previous.log` file, each bounded
to 32 KiB. The header identifies the attempt, source/build and UTC/monotonic
anchor; records contain fixed stage names, pass numbers, numeric results and
the app/native image UUIDs and bases plus the probe allocation base. These
private address anchors must persist before execution; a missing image UUID
or failed anchor write declines the probe. They contain no game paths, game data, pairing
records or arbitrary native log text. Each boundary uses checked writes and
`fsync` before continuing. This preserves completed records across process
termination; it does not establish power-loss durability or diagnose the cause
of an execution window that never returns.

The follow-up probe records `code.length` and `code.word.0` through `.3` for
at most 16 bytes of its own constant-return instructions, before cache/RX
transitions. No game code is recorded. `exec.enter`
precedes TLS setup; `call.enter` follows the TLS accessor and an unarmed flag
write, immediately before arming and calling the generated leaf. A missing
return still does not establish the faulting instruction or termination cause.

The pinned emitter has a declared one-line overlay initializing its chunk
flags; full-production-emitter UBSan/constant-emission tests cover optimized
and unoptimized W/X values. This repairs demonstrated uninitialized reads,
without claiming to fix physical-device JIT execution.

The generated Madeira helper stores `Documents/iridium-jit-helper.log` plus
one `.previous.log` in **the helper's own private container**. Each is at most
4 KiB/16 records, with checked writes and `fsync`; write failure only disables
file recording. Export All App Logs requests a bounded snapshot over the existing
extension request/response channel, including on a later app launch. The app
validates the response's request ID and every complete allowlisted record, then
atomically merges up to 32 records into `iridium-jit-helper-mirror.log` for normal
export. Enable requests and their helper records share a random attempt ID;
historical attempts remain tagged separately. A two-second retrieval timeout,
empty response or incomplete tail preserves the app's existing mirror. Retrieval
runs outside the helper's debugger work queue and does not rotate journals or
perform pairing/preparation. Physical-device delivery remains unverified; no
shared-container entitlement or permission is added. Records retain build/UTC,
attempt ID, setup reply categories (`ok`, `empty`, `error`,
`stop`, `other`) and the first stop/fault/exit's bounded signal/exception/code
fields. The first non-BRK fault also records `pc` and the second repeated
`medata` as 16 lowercase hexadecimal digits, or explicit `missing`/`invalid`;
`md` is `0`, `1`, `2` or `more`, and `insn` is `mov42`, `mov7`, `ret`, `other`
or `unreadable`. The PC comes from the already parsed little-endian register;
the instruction category reuses the existing memory-read result. No extra
debugger operation is issued. The private journal is mode 0600, capped at 240
bytes per record, and stores the first fault only. System logging and the app
mirror strip `pc`/`addr`, retaining only the bounded categories. Ordinary
export and recent-log display redact private tuple/base lines defensively.
Raw packets, thread/process IDs, paths, pairing data, unknown instruction bytes
and unknown progress strings are dropped. The script is overlaid from pinned Madeira,
not the separate alternate `BuiltinJIT/Helper` script. Neither acknowledgements
nor diagnostics change readiness, forwarding policy, debugger commands or
ownership. Private local collection of both journals can compare the actual PC
with the probe and image anchors. Missing/invalid fields remain unknown; a
stage marker alone cannot locate a fault. Cache flush still precedes RX in
both probe passes; the separate cache-order proposal is not part of this change.

Journal work runs off main. A cancelled or timed-out worker and its restoration
callbacks retain the same journal; a new attempt cannot rotate a live writer.
Failed journal admission or a required write declines JIT with interpreter
fallback. The additive ABI-3 diagnostic export is required by this app's build
receipt, so an older untraced component cannot silently satisfy validation.
The native error callback is installed before preflight. Only known memory
failure classifications and their explicit upstream errno fields are retained;
`error=-1` means the status is unavailable. Cache flush and unmap wrappers return
void upstream, so their return records do not claim checked syscall success.

Signal recovery records are written after the existing `siglongjmp`, in ordinary
C flow. The handler only saves the signal number and bounded generated-code
offset. It performs no journal I/O, allocation, callback or locking. Debugger
Mach exception routing and nonrecoverable OS/helper termination remain outside
this guard. Diagnostic I/O counts toward the existing five-second probe
watchdog; an instrumented timeout retains ownership and requires restart.
Host journal, cancellation and execution-guard tests are separate from physical
iPhone JIT/TXM validation. No runtime switching or allocator/debugger policy is
changed by this instrumentation.

PPSSPP owns its native touch, keyboard and controller input. Iridium provides
the menu and return-to-library actions. Backgrounding and audio interruptions
pause the player without changing the user's pause intent. Return waits for
render/audio teardown before releasing the runtime lease; a timeout retains
ownership and requires an application restart. Controller handlers and the
prior audio category are restored. No source or settings are fetched after
installation. Windows input and JIT continue to use Madeira.

The native builder compiles the pinned FFmpeg dependency with upstream's selected
H.264, MPEG, AAC, ATRAC and related codec recipe. It checks an original H.264
frame before opening a session, audits exported symbols and dynamic dependencies,
records compiled inputs and copies the full upstream assets. Required resources
are hashed in the build receipt. Matching source includes selected dependencies,
generated embedding hooks, the recipe and build receipt. The source collector
omits only exact reviewed unused FFmpeg binaries, which are never linked.

```sh
python3 ci/build-ppsspp-native.py --initialize
python3 ci/build-ppsspp-native.py --sdk iphoneos --output .build/ppsspp/iphoneos
```

These commands need Xcode, CMake, Ninja and make. Outputs stay outside upstream
source and the enclosing app requires iOS 18. The selected upstream MoltenVK
package currently contains only a device slice; simulator graphics validation
needs an audited compatible MoltenVK build, rather than dropping that backend.
A source recipient can rebuild and replace the component with the same recipe,
then rebuild/re-sign the enclosing app using their own Apple installation setup.

Compilation, the codec fixture and preparation checks do not establish native
GPU presentation, audio output, settings/save round trips, repeated sessions or
God of War's subtitle transition. Those require simulator/device evidence. The
legacy Libretro fixture host below remains useful only for historical comparison
and is not the active player or its acceptance test.

Host guest-execution checks cover original synthetic CPU, video, audio, input,
per-game save and repeated launch/quit fixtures. Apple component compilation and
host execution are separate from physical iPhone performance, actual game
compatibility, interactive UI and LiveContainer validation.

For a trusted, already-built host PPSSPP component with the companion export,
run the checked-in original guest fixture against the actual C bridge:

```sh
python3 ci/check-ppsspp.py --component /path/to/ppsspp_libretro.dylib --api-header /path/to/libretro.h --assets /path/to/PPSSPP/assets
```

This explicit check uses only temporary outputs and does not compile or download
the emulator. See `ci/psp/README.md` for covered behavior and limits.
