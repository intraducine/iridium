StikJIT 1.5.0: https://github.com/StikDebug/StikJIT/tree/1.5.0
License: MPL-2.0. The binary is unchanged. Iridium's prepare.py corrects two
Swift textual interfaces for Xcode 27 and supplies missing framework metadata.

Madeira JIT script: https://github.com/willfaust/Madeira
License: GPL-3.0-or-later. Iridium adds an attach failure guard and one helper
readiness notification. Corresponding script is included in this source tree.

idevice: https://github.com/jkcoxson/idevice
MIT license text retained. The StikJIT release bundles libidevice_ffi.a and
universal/legacy scripts under their respective licenses. Exact vendored revision
and complete transitive notices must be established before external distribution.

See docs/builtin-stikjit-ios27.md for source, changes, build instructions, and
pending physical-device verification. This local experiment does not change the
main project's licensing or authorize external distribution.
