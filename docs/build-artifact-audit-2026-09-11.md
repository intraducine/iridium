# Retained artifact and staging audit

## Evidence

Audited native and Wine artifacts from run `34650568812`, and Windows artifacts
from run `34658867572`. All three archive checksums match their manifests.

- The native artifact contains all required native, media, and input files listed
  in the IPA prerequisite checker. All 12 native prerequisite archives contain arm64.
- Real Wine files stage successfully: 1,501 resources, including source fonts.
- All eight DXMT DLLs exist and pass the PE architecture checks.
- FEX was linked into `build-arm64ec/Bin/libarm64ecfex.dll`, but was omitted from
  the Windows archive. The compiler step now copies it to the retained location
  and validates it, together with all eight DXMT DLLs, before returning success.
- Wine contains `programs/wineboot/aarch64-windows/wineboot.exe`, not a host
  `programs/wineboot/wineboot` executable. CI now invokes that PE through Wine.

## Remaining stages

Reviewed the prefix script, ANGLE and StikJIT build recipes, legacy SDK bundle
script, source collector, Xcode project inputs, prerequisite gate, and unsigned
IPA packager. This review does not establish successful execution.

The local attempt to run the retained Wine launcher ended with signal 9 and no
stderr, including after ad-hoc signing the temporary host copies. Prefix creation
therefore remains unverified on the runner. No user prefix or save was used.
ANGLE, StikJIT, legacy host compilation, final source collection, app linking,
and real IPA packaging have not yet passed in this pipeline. The three recorded
source/license blockers remain in force; this run cannot publish an IPA while
they remain unresolved.

## Reuse and validation

These fixes change the Windows compiler recipe and prefix staging only. Native,
Wine, and media compiler inputs are unchanged. Windows must rebuild because its
previous artifact is incomplete. Artifacts keep their original seven-day expiry.

Local checks: 39 CI tests, repository standards, shell syntax, whitespace, and a
clean-source privacy scan. Tests exercise the FEX output handoff, a missing DLL,
Wineboot argument forwarding, source-font staging, and packaging-only Wine reuse.
No device or gameplay claim follows from these checks.
