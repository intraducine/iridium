# Graphics build audit: Xcode 27

## Cause and correction

Run 34665510357 used the requested commit, but the graphics recipe combined
Chromium Clang 20 with the iOS 27 SDK. The SDK expects compiler resource-header
support for `__need_infinity_nan` and a logging attribute that this older compiler
does not provide. A local SDK probe reproduced the INFINITY, NAN and logging
errors with the old compiler. The same probe passed with Xcode's compiler.
Changing individual callers could not repair that toolchain mismatch.

The final configuration uses Xcode's Clang, compiler resource version, C++
library, linker and archive tool. WebGPU is explicitly disabled: the previous
configuration enabled Dawn despite requesting a Metal runtime. ANGLE and its
dependency sources are unchanged. The two earlier header/warning patches are
removed. Pinned depot_tools is explicitly bootstrapped without updating it.

ANGLE's `treat_warnings_as_errors=false` option leaves upstream warnings visible
under the newer compiler. The audit encountered mutex-annotation, byte-copy,
virtual-specifier and deprecated Metal API diagnostics. This setting does not
suppress warnings or turn genuine compilation errors into successes. It does not
constitute a runtime or thread-safety audit of upstream ANGLE.

## Verification

- Local Xcode 27.0, build 27A5218g; iPhoneOS SDK build 24A5380g.
- ANGLE source: 6024e9c05548480c3b2ea42836a112509a549a95.
- Bootstrap depot_tools: 6794dd02d7ba80c074d2ff0d294a32b9c5dc0112.
- A clean output directory completed all 512 Ninja steps, including both links
  and framework bundles. This was an actual arm64 iOS compilation, not a simulator
  build or a mocked compiler test.
- The generated plan contains 492 iPhone compilation commands. It uses Xcode
  and contains no Dawn, bundled Clang/libc++ or LLVM archive/linker tools.
- Both frameworks have arm64 architecture, iOS platform, minimum OS 18.0,
  matching executable metadata and the expected EGL/GLES exported entry points.
  Linked library paths are system libraries or the sibling frameworks.
- Both frameworks are unsigned. They stage into the expected application input
  paths with the ANGLE license.
- Source collection includes dependency Git archives and revisions, plus the
  separately pinned bootstrap depot_tools checkout. No SDK is copied.
- The existing component packager successfully serialized the real frameworks
  and sources: 71 files, 917 MiB. Archive checksum, required source/license entries
  and framework bytes passed verification. Provenance metadata was a local test
  fixture; this artifact was not uploaded and is not a reusable CI producer.
- All 43 CI tests, shell syntax and repository standards passed. A clean source
  snapshot with only these changes returned zero privacy findings.
- Early SDK probing now runs before native preparation. Generated-command and
  finished-framework checks run before graphics outputs are retained.
- Native, Wine and Windows compiler inputs and workflow blocks are unchanged;
  these edits do not require rebuilding their matching retained artifacts.

## Limits

The local Xcode build differs from the hosted runner's beta 6 installation.
Hosted CI still needs verification. This audit does not establish device rendering,
input, audio or game compatibility. It does not clear the existing source/license
release blockers or validate the later StikJIT, application-link and IPA stages.
No new hosted release build was started during this audit.
