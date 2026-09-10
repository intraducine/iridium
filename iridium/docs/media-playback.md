# Media playback integration

Status: iPhone Media Foundation video decode and end-of-stream passed for the
first Hollow Knight intro; full playback acceptance is pending.

First device probe: COM and MFStartup succeeded; Wine loaded the ARM64EC
`winegstreamer.dll` and reached the native GStreamer table. Source creation then
stalled with `failed to create deinterlace`. The next build registers that
filter and logs codec-factory availability. Frame decoding on the phone is
not confirmed by that first probe. The corrected probe then succeeded:
`CreateSourceReader=0`, 953 video samples of 3,110,400 bytes, final timestamp
381600000 in 100 ns units, `EOS=1`, final HRESULT 0. Evidence:
`/tmp/iridium-media-filter-result.log`. This matches the host's 953-frame count.
All 25 logged codec/parser factories were available on the iPhone. Factory
availability does not establish playback success for the other formats.

## Confirmed failure

Hollow Knight's `Player.log` reports `WindowsVideoMedia 0xc00d36c4` in
`CreateObjectFromByteStream` for `sharedassets5.resource`. Madeira packages
`mf.dll`, `mfplat.dll` and `mfreadwrite.dll`, but no `winegstreamer.dll` or its
native backend. The source resolver falls back to the GStreamer COM class;
that class previously had no implementation in the bundle.

The resource contains two complete MP4 sequences at offsets 2045536 and 6173616.
FFprobe identifies H.264 video and AAC audio. The first is 1920x1080 at 25 fps.
AVAssetReader on the Mac decoded 953 and 906 video frames respectively, reaching
completion without errors. This proves file validity, not iPhone Wine playback.

## Implementation

The adapter compiles Madeira's existing Wine GStreamer native sources for iOS,
links GStreamer 1.28.6, and supplies a matching ARM64EC Windows DLL. A generated
copy of Madeira's native loader registers the additional Unix function table;
the original checkout and original native archive remain intact.

The isolated prefix receives the media DLL and stream-handler COM registration
before its Wine server starts. The runtime retains Wine's media-source and
sample-reader code. It does not replace the cutscene with an unrelated UI player.

Static plugins include MP4/ASF/WebM/Ogg/AVI/MPEG demuxers, native Apple media,
Libav, Theora, Vorbis, Opus and audio/video conversion. Registration is not proof
that every codec and playback operation works.

Sources and dependencies:

- Madeira Wine source in the local checkout, with its GPL-3.0-or-later notices.
- [GStreamer iOS SDK](https://gstreamer.freedesktop.org/documentation/installing/for-ios-development.html)
- Archive: `https://gstreamer.freedesktop.org/data/pkg/ios/1.28.6/gstreamer-1.28.6-xcframework.tar.xz`
- SHA256: `48437f2a8f17bc1de40097eec9aedc0d307a30c15d9e996bf75bc07562bd79a5`

Retain GStreamer and included dependency notices and corresponding source/relink
materials before distribution. This is a private test build, not a release or a
change to Iridium's project license. No game video is committed or published.

## Required acceptance matrix

Each row requires both Media Foundation and DirectShow where the format applies,
plus audio sync, seek, pause/resume, skip and automatic end-of-stream tests.
No row below has passed that full set yet.

| Format | Fixture | Device status |
|---|---|---|
| MP4 H.264 + AAC | Hollow Knight intro and synthetic clip | MF video decode/EOS passed for first intro; audio and game presentation pending |
| ASF WMV + WMA | Synthetic WMV2/WMA2 | Not tested |
| ASF VC-1 + WMA | Fixture still needed | Not tested |
| WebM VP8 + Vorbis | Synthetic clip | Not tested |
| WebM VP9 + Opus | Synthetic clip | Not tested |
| Ogg Theora + Vorbis | Fixture still needed | Not tested |
| AVI MPEG-4 Part 2 + MP3 | Synthetic clip | Not tested |
| AVI MJPEG + PCM | Synthetic clip | Not tested |
| MPEG-1/2 + MP2 | Synthetic clips | Not tested |
| Bink / Bink 2 bundled game decoder | Game files still needed | Not tested |
| CRI Sofdec / USM | Game files still needed | Not tested |

The current `mfprobe.c` checks video samples and completion for one MP4 through
Media Foundation. It does not yet measure audible sync or the other control
operations. Generated codec clips are not a replacement for bundled-decoder
game tests. `IRIDIUM_MADEIRA_TEST=media` runs this probe; `game` restores the game.

Build sequence, using Xcode-beta's DEVELOPER_DIR:

1. `Scripts/prepare_media_sdk.sh` downloads/verifies the pinned iOS SDK.
2. `Scripts/build_media_runtime.sh` builds native and ARM64EC media libraries.
3. `xcodegen generate --spec madeira.yml`, then build the Iridium scheme.
4. Re-sign after the existing bundle finalizer; verify the final signature.

`MediaSupportTests/extract_mp4.py` extracts the test videos without modifying
the game resource and checks malformed boundaries. `DecodeMP4.swift` exercises
native macOS decoding. `generate_corpus.py` produces eight synthetic clips with
FFmpeg; it currently does not encode VC-1 or Theora. A host-generated clip is
only a fixture, not an iPhone playback pass.


### Video processor integration (local verification only)

The Hollow Knight log reports `0xc00d5212` at “Setting media type for first
video stream.” The integrated ARM64EC package lacked `msvproc.dll`. It is now
built from Madeira's existing Wine source and staged in `MediaRuntime`.
The build script generates its COM and Media Foundation transform registration
from the upstream input/output format lists. The GStreamer processor class is
also registered. Registration is applied offline only to the separate test prefix.

Local checks passed: ARM64EC build, existing imported DLLs, Swift installer
compilation, registry preservation and repeat-install stability. The generator
checks 22 input and 21 output formats. No updated app was installed from this
side conversation. Actual format negotiation, rendered video, sound and completion
remain unverified on the phone. The missing processor is a concrete integration
gap; the logs alone do not prove it is the only playback fault.

License notice: `wine/dlls/msvproc/msvproc.c` and `msvproc.idl` identify
Copyright 2024 Rémi Bernon for CodeWeavers and GPL-3.0-or-later. The binary is
built without changing those files. Its GPL license text is bundled alongside
it as `msvproc-COPYING.txt`. This records a component obligation; it does not
change Iridium's project license or authorize public distribution. Distribution
requires the applicable corresponding-source and combined-work license review.


### iPhone asynchronous sample test, 2026-09-08

The RGB32 + PCM asynchronous source-reader probe completed on iPhone:
953 video frames and 1,786 audio buffers; both end-of-stream events arrived;
HRESULT 0. Final timestamps were 381600000 and 381013333 (100 ns units).
This verifies converted sample delivery, not audible sync or game presentation.
Evidence: `/tmp/iridium-side-av-result.log`.

The game subsequently needs its own trace because its previous log showed
`0x80004004` at `IMFSourceReader::WaitForSample`, without enough detail to
distinguish cancellation from a runtime delivery failure. `IRIDIUM_MEDIA_TRACE=1`
enables targeted mfreadwrite/mfplat logging, persisted across StikDebug relaunch.
Use `IRIDIUM_MEDIA_TRACE=0` to turn it off. The optional environment branch in
Madeira's WineProcessBridge leaves its existing default logging unchanged.


### Shared GPU texture failure and pending regression test

Targeted game trace `/tmp/iridium-side-trace-failed.log` shows advanced video
processing, ARGB32 output and a DXGI device manager. The first sample creates
six shared textures; each fails in DXMT's WMTBootstrapRegister path with
`DeviceTexture: Failed to register mach port for shared texture`. The processor
then releases its sample allocator and does not deliver the requested sample.
This explains why memory-buffer probes passed while the game waited.

`Scripts/build_media_graphics.sh` compiles a generated copy of winemetal with
an iOS-only process-local port namespace. Original DXMT source/archive remain
unchanged. `LocalSharedPorts.h` retains send rights and supplies a new reference
for each lookup; tests cover lookup, replacement, unregister and reference
balance. Names are local to this single-process runtime. Cross-process sharing
is not supported; registered rights remain until unregister or process exit.

The current probe requests asynchronous GPU ARGB32 video plus PCM audio and
checks every video sample exposes an ID3D11Texture2D. Its new build passed
compilation, app signing and integration checks, and was installed on the phone.
The GPU test is waiting for JIT; no GPU playback pass is claimed yet.


GPU regression result: `/tmp/iridium-side-gpu-result2.log` confirms device
creation, GPU ARGB32 and PCM negotiation all succeeded. All 953 video samples
exposed ID3D11Texture2D resources. Audio delivered 1,786 buffers. Both streams
reached EOS, HRESULT 0. The failed shared-texture path now completes in the
iPhone probe. Hollow Knight was restored to game mode for visible playback
verification; actual video and audible sound still require confirmation.


### Final-frame sharing fix and GPU pixel proof

GPU readback recovered real, opaque intro imagery (frame 400, 1920x1080).
The unpatched final reader allocator returned non-shared textures: GetSharedHandle
returned S_OK with NULL, and opening on another device failed with 0x80070057.
The isolated mfreadwrite variant now defaults DXGI final samples to shared
textures; explicit caller settings still override the default. Original Wine
source remains unchanged. Build via `Scripts/build_media_reader.py`; the bundle
finalizer stages the variant in arm64ec-windows, since Madeira relinks system DLLs.

Device test `/tmp/iridium-final-shared-result.log` passed: valid shared handles,
successful OpenSharedResource on a second D3D11 device, nonblack opaque pixel
readback on both devices, 953 video textures, 1786 audio buffers and both EOS
signals. Frame 400's second-device readback exactly matches the previous
first-device PPM. This verifies the texture handoff in the probe; audible sync
and visible playback inside Hollow Knight still need confirmation.

Diagnostic GPU images are `/tmp/iridium-video-frame-400.ppm` and
`/tmp/iridium-video-frame-10400.ppm`. They are extracted frame data from the phone,
not screenshots of the game screen. After the test, Iridium was relaunched in
game mode and targeted tracing disabled.
