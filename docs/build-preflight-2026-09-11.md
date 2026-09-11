# Build preflight review: 2026-09-11

Reviewed public source commit `2791cf06487d66ffb84cec9cbaa90d4c3c101b0d`.
No GitHub workflow was dispatched and no changes were pushed during this review.

## Confirmed failure and correction

Run 34562066536 failed in Cerbero's vvdec 3.1.0 recipe. Its real compiler command
used the iOS 27 SDK with `-miphoneos-version-min=12.0` and `-Werror`. libc++
rejects that old target. The application specifies iOS 27.0.

The media configuration now reads the app's explicit deployment target rather
than falling back to Cerbero's iOS 12 default. It does not suppress the warning
or remove the codec. Host tools retain their separate macOS deployment target.

`prepare-media-sdk.sh --preflight` resolves Cerbero's actual host and target
configuration, compiles and links C++14, C++17 and C++20 probes for both, runs
the host probe, checks iPhone architecture, prints Mach-O platform metadata,
and checks that the gperf recipe patch applies. This runs before bootstrap.
Existing different user Cerbero configuration is not overwritten.

Native preparation now checks tools needed by later stages, and downloads and
checks the separately installed Metal compiler before compiling LLVM or FEX.

## Evidence

- The original iOS 12 configuration fails the new compiler probe with the same
  libc++ error. The test explicitly requires a nonzero exit.
- All six compiler/linker probes pass with Xcode 27 and the corrected target.
  The iPhone output reports ARM64, platform IOS, minimum 27.0, SDK 27.0.
- vvdec 3.1.0 was downloaded, checked against Cerbero's SHA-256, and built with
  both patches listed in the pinned recipe. The iOS 27 ARM64 static-library
  target builds successfully. This was a focused CMake build, not a full
  Cerbero SDK package build.
- All 18 CI unit tests pass. These include app-target propagation, repeat
  configuration, preservation of differing user configuration, patch
  application, source collection, artifact transfer, and package rejection.
- Source privacy, repository standards, shell syntax, and whitespace checks pass.

## Whole-pipeline review and remaining evidence

| Stage | Review | Still requires execution |
| --- | --- | --- |
| Linux Wine | Read preparation, package-source collection, provenance checks, and previous run errors. Existing source tests cover artifact rejection. | A successful producer artifact with matching source for the selected revision. |
| Media | Verified resolved target/host flags, recipe patch, vvdec source build, package filenames and XCFramework layout against pinned Cerbero code. | Full bootstrap, all recipes, XCFramework assembly, and offline source bundle. |
| Native Wine/FEX/DXMT | Read preparation order, source patches, archive outputs, shader generation and external tool use. Moved late tool failures earlier. | Full clean compilation and archive/link validation. |
| Windows modules | Read Wine staging, ARM64EC translator, Meson machine files, compiler paths, prefix preparation and architecture checks. | ARM64EC/aarch64 module builds and fresh prefix creation. |
| Graphics | Read pinned ANGLE/depot_tools setup, GN flags, source collection and expected framework outputs. | GN generation, compilation and exact framework output verification. |
| JIT | Read pinned Rust/idevice build, source inventory, framework archive and unsigned settings. Rustup is now checked early. | Crate compilation, StikJIT framework and device validation. |
| Packaging | Read legacy host packaging, source archive collector, prerequisites, unsigned app workflow and rejection tests. | Full app link, package audit and device installation. |

The small probes cannot validate every recipe's flag changes, generated source,
link dependency, archive name, or network download. The actual codec test covers
more than the probe but does not establish full media support.

The source/license gate remains closed. A full run is expected to stop there
until its recorded audit items are resolved, even if all compilation succeeds.
Do not remove that gate merely to get a green run.

## Next build sequence

1. Review and explicitly authorize pushing these changes. Keep build dispatch
   manual. Use the exact reviewed commit, not a moving local working tree.
2. Run the existing media-only workflow first. Require the complete SDK and
   corresponding-source artifacts, not only a passed vvdec compile.
3. Inspect any failure together with recipe logs and generated compiler/link
   settings. Reproduce the failing stage before another full workflow run.
4. Run the complete pipeline after media succeeds. Reuse Linux output only
   through the existing provenance and checksum checks. Media cross-run reuse
   is not implemented; do not substitute an unverified local SDK.
5. Keep compile success, license audit, package verification and physical-device
   results separate. None establishes the others.

## Follow-up: run 34593935375

The compiler preflight passed. The media build then failed in applemedia's
legacy iosassetsrc header: AssetsLibrary APIs are obsoleted for iOS 26 and later.
The earlier C++ probes and focused vvdec build did not cover this Objective-C
plugin. This was a gap in the initial validation.

The patch uses Meson's Objective-C compiler check for the actual target. It
includes iosassetsrc and its registration only when AssetsLibrary is usable.
AVFoundation and VideoToolbox remain enabled. Source guards and the Meson source
list use the same feature definition.

Validation: the pinned gst-plugins-bad 1.28.6 tarball digest matches the Cerbero
recipe. The source patch applies using Cerbero's git-am mechanism. The actual
Meson compiler check passes for an iOS 17 minimum and rejects the removed API
for iOS 27, with assertions on the resulting source list. Run it with:

```sh
python3 ci/check-applemedia-api.py /path/to/patched/gst-plugins-bad-1.28.6
```

This check needs Meson, Ninja, and Xcode with an iOS 26+ SDK. Full applemedia
compilation and complete media packaging still require the next manual run.

## Follow-up: run 34597470104

The full media compile and XCFramework assembly passed. The subsequent
corresponding-source bundle failed because Homebrew Python 3.14 had no
setuptools. This packaging dependency was missing from the earlier preflight.

Media preparation now creates an isolated Python environment with setuptools
80.9.0, runs Cerbero's real sdist command on a small supplied source directory,
and checks that the resulting archive preserves that source. This happens
before bootstrap. The final bundle-source command uses the same interpreter.
No source/license gate is removed. This does not yet verify the full source
bundle with every compiled dependency.
