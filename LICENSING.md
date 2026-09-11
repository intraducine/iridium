# Licensing

Original Iridium-authored code in `iridium/`, `iridium-runtime-sdk/`, and the root publication tools is licensed under **AGPL-3.0-only**, unless a file or component has a more specific notice. The full text is in LICENSE. This grant does not replace third-party grants or claim ownership of upstream code. Contributions to these original components are accepted under the same terms.

## Third-party boundaries

- `iridium-fex-ios/`: upstream FEX MIT license and component notices are retained. Existing fork material is distributed under its existing notices.
- `iridium-wine-ios/`: Wine LGPL-2.1-or-later and component-specific notices are retained. Existing fork material is distributed under its existing notices.
- `testrepos/Madeira/`: Madeira GPL-3.0-or-later. Its FEX and DXMT forks retain upstream MIT grants while Madeira modifications use GPL-3.0-or-later. Its Wine fork documents GPL-3.0-or-later conversion in LICENSE-MADEIRA.md. Those terms are not replaced with AGPL.
- Madeira-derived portions within Iridium, including the adapted JIT script, retain GPL-3.0-or-later. The copied notices in `iridium/apps/ios/MadeiraSupport/Notices/` and `iridium/apps/ios/BuiltinJIT/StikJITNotices/` remain applicable. New independently authored Iridium integration code is AGPL-3.0-only.
- StikJIT source and textual-interface modifications retain MPL-2.0 where applicable; idevice retains MIT. The binary is not included. Source URLs and the pinned archive digest are in BuiltinJIT.
- Other libraries, test data, fonts, and tools retain their embedded notices. The root license does not override them. Public upstream copyright names and contact details are retained as attribution, not presented as Iridium maintainer identity.

GPLv3 and AGPLv3 section 13 permit combining the covered components under their respective terms. This is a mixed-license repository, not a blanket AGPL relicensing of upstream work. Previously granted licenses are not revoked.

## Source publication and binary releases

This release distributes source, not an IPA. The supplied licenses and attribution files must remain with redistributed copies. Modification information is recorded in CHANGES-FROM-UPSTREAM.md.

An IPA release needs the corresponding source for the exact binary, build scripts, required license notices, and clear source-download instructions beside the IPA. Keep that source available, including any modified dependencies. A moving upstream branch URL is not a replacement for exact corresponding source.

CI now replaces StikJIT's opaque idevice archive with a pinned source build. The script comparison and AGPL notice are recorded in StikJITNotices/SOURCES.md. Resolved crate notices still require review. Resolve the recorded audit items before distributing a binary. GStreamer, codecs, crypto libraries, and the runtime must also be inventoried at their actual build revisions. Do not include game files, commercial artwork, Apple SDKs, Developer Disk Images, Microsoft runtime installers, or personal signing/pairing material.

AGPL permits commercial use and forks. It requires source sharing under its terms, including the network-interaction requirement for modified versions where applicable. It does not require unrelated games merely run by the runtime to become AGPL.

## New source-build recipes

ANGLE is built from Google ANGLE commit `6024e9c05548480c3b2ea42836a112509a549a95`, whose BSD-style license is copied by the build recipe. Its dependencies retain separate licenses. The Cerbero recipe uses revision `59548269f4fd0f701818f0bafdb102959ec81e65`; Cerbero source headers grant LGPL-2.0-or-later, while individual codecs and libraries retain their own terms. A source-built SDK is not by itself a complete distribution audit.

The Linux recipe collects exact Debian source-package versions and copyright files for copied libraries. A future IPA must include a matching complete source archive and notices for all target dependencies. `ci/binary-release-blockers.json` lists the remaining work. These records permit source preparation to be reviewed; they do not declare a binary release compliant.
