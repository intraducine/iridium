# Licensing

Original Iridium code and publication tools are **AGPL-3.0-only**, unless a
file has a more specific notice. The full text is in [LICENSE](LICENSE).
Third-party code keeps its own license and copyright notices.

## Frontend app components

The frontend app uses `vendor/Madeira` at the revision in
[UPSTREAM-SOURCES.json](UPSTREAM-SOURCES.json). Its major components are:

| Component | Applicable terms |
| --- | --- |
| Madeira app, Swift Steam client and D3D12 implementation | GPL-3.0-or-later with Madeira's adopted Converter Exception; file-specific notices still apply |
| Wine and Wine-derived native libraries | LGPL-2.1-or-later on the pinned `madeira-lgpl` branch; see `vendor/Madeira/wine/LICENSE-MADEIRA.md` |
| FEX and DXMT | Upstream MIT; Madeira modifications GPL-3.0-or-later |
| DXMT D3D9/DXSO frontend | LGPL-2.1-or-later; see `vendor/Madeira/dxmt/LICENSE-MADEIRA.md` |
| Madeira Dock | GPL-3.0-or-later with its Converter Exception; compiler-runtime notices in `dock-notices.txt` |
| rpmalloc | 0BSD; Will Faust's modifications GPL-3.0-or-later |
| GMP 6.3.0, Nettle/Hogweed 3.10.1 | LGPL-3.0-or-later or GPL-2.0-or-later |
| GnuTLS 3.8.9 | LGPL-2.1-or-later |
| FFmpeg 7.1.1 | LGPL-2.1-or-later with the supplied LGPL-only build configuration |
| FreeType | FreeType License or GPL-2.0; retain its source notices |
| LLVM libraries and LLVM-MinGW runtime | LLVM and MinGW component notices, including the LLVM exceptions where stated |
| StikJIT 1.9.0 | MPL-2.0; embedded idevice MIT and dependency-specific notices |
| On-device pairing | Madeira wrapper GPL-3.0-or-later; idevice MIT and crate-specific terms in `legal/LICENSES-rppairing-crates.txt` |
| fmt, xxHash, Cephes and SoftFloat | MIT, BSD-2-Clause, Moshier permissive notice and BSD-3-Clause, respectively |
| Zstandard decoder | BSD-3-Clause selected |
| Wine's bundled libxml2 and libxslt; NVAPI headers | MIT with their respective copyright notices |
| Apple Metal Shader Converter | Apple's converter agreement; headers Apache-2.0 |

The component's own notice controls if a summary differs. In particular,
Madeira's top-level Wine table describes its GPL fork; the pinned Wine branch's
`LICENSE-MADEIRA.md` specifies LGPL-2.1-or-later.

The app includes notices from `vendor/Madeira/LICENSES/`, the runtime's `legal/`
folder, Dock, and the converter. Iridium's AGPL text is added to the app's
`licenses` folder. Keep these notices with redistributed copies. Changes are
recorded in [CHANGES-FROM-UPSTREAM.md](CHANGES-FROM-UPSTREAM.md).

GPLv3 and AGPLv3 section 13 permit combining covered components under their
respective terms. This does not relicense upstream code. Madeira's Converter
Exception applies only to the copyright it covers and does not grant rights to
Apple's library or change Iridium's license. Games run by the app remain
separate works.

## Source and library replacement

The multi-runtime branch additionally links SameBoy's Libretro core at the
revision in `UPSTREAM-SOURCES.json`. The selected Core, Libretro adapter and
replacement boot ROMs use SameBoy's Expat (MIT) license. The Libretro API header
retains its separate MIT notice. The upstream iOS and HexFiend frontends are not
linked. The build preserves those notices in `licenses/LICENSE-SAMEBOY*.txt`,
and source collection includes the pinned submodule, boot-ROM assembly,
generated boot data and its reproducible generation recipe.
The boot ROMs are SameBoy's replacement implementation, not supplied console
firmware. The generated private symbol prefix and the generated Libretro
adapter's 48 kHz public-API setting are Iridium build adaptations; upstream
source files and emulation Core logic are not modified. This does not import RetroArch or grant
rights to third-party game content. No additional emulator's license has been
approved merely because it appears in the candidate research.

The PSP component uses pinned PPSSPP and its selected dependencies, with original
per-file grants preserved. This includes GPL-family PPSSPP code, GPLv3 libkirk
and xBRZ material, LGPL-2.1-or-later at3_standalone, and permissive dependencies.
The native iOS player links MoltenVK 1.2.9 built from the digest-locked source
closure in `ci/moltenvk-source-inputs.json`, with original Apache-2.0 and dependency
notices. It does not link the release submodule's opaque prebuilt archive. Its
receipt records the verified expanded source and actual linked archive hashes.
The native iOS player includes upstream FFmpeg media decoders, graphics and
frontend resources. FFmpeg is rebuilt from its release dependency source using
the upstream selected-codec recipe. The generated `licenses/PPSSPP` directory contains upstream terms,
GPLv3/LGPLv2.1 texts and source attribution; the build receipt records selected
source pins and actual compiled units. It is not a blanket relicense.

The eighteen bundled PGF replacement fonts retain the selected release's bytes.
Their historical headers before upstream name camouflage identify Source Han
Sans (Japanese/Korean), Ume Hy Gothic and Ume P Mincho (Latin). Full SIL OFL 1.1
and Ume unrestricted grants, license-source checksums, historical blob IDs and
release-file checksums are preserved in
`iridium/apps/ios/RuntimeSupport/Notices/PPSSPPFonts/PGF-PROVENANCE.json`. That
records family provenance and redistribution terms; it does not assert exact
original TTF versions or reproduce all manual glyph/metric adjustments.

The five bundled TTF assets identify SIL Open Font License 1.1 in their embedded
name records. Their original copyright/author/license records, checksums and
full pinned upstream OFL texts are preserved beside the PGF notices. The
Roboto-only asciifont atlas has an identified OFL input.

The separate UI font_atlas and PSP ppge_atlas resources remain unresolved.
Their pinned generators reference Arial Unicode and Kozuka Gothic font files
absent from the snapshot. Microsoft's redistribution FAQ explicitly excludes
converting Windows fonts to bitmap fonts for game/app redistribution. An upstream
comment saying bitmap conversion is sufficient does not supply those rights.
See https://learn.microsoft.com/en-us/typography/fonts/font-faq . Obtain an
applicable grant or regenerate both atlases and metrics from pinned licensed
open fonts; keep required resources and language coverage. PGF/TTF grants do not
cover those other font inputs. User-game font extraction, if invoked by upstream,
stays in that game's writable memory-stick directory.

Before public binary distribution, review the combined component terms,
including PPSSPP dependencies and the proprietary Metal Shader Converter.
Madeira's Converter Exception does not automatically extend to PPSSPP or other
copyright holders. Separating a dylib is an engineering boundary, not by itself
a determination of copyright aggregation or permission. Private validation and
successful compilation do not establish clearance for a public release.
The pinned Madeira `docs/LICENSING.md` expressly requires review of the assembled
app before public release. Apple's supplied converter agreement section 2.B
permits dylib distribution solely for shader conversion, subject to its other
terms. Madeira's adopted exception covers its author-owned components and
specified contributions, while LGPL Wine/media retain their own relink and
notice obligations. The native PPSSPP image does not link or reference the
converter, but the host loads both runtimes in one process and embeds PPSSPP's
controller via its C boundary. The reviewed engineering boundary alone does not
establish that this is a GPL section-5 aggregate or extend the exception to
PPSSPP, libkirk, xBRZ or other independent GPL copyright holders. That combined
work determination remains unresolved; the build recipe is not permission to
ignore it.

An IPA release must include matching source, modifications, license texts,
third-party notices, a component manifest, and usable build/relink instructions.
Keep them available with that release. A changing branch or an expiring Actions
artifact is not permanent source delivery.

The frontend source collector includes the repository, required dependency
sources, tracked Madeira crypto and FFmpeg archives, pairing crates, generated build
inputs and instructions. The component manifest records source revisions,
packaged binaries and final static link inputs. See
[build and replacement instructions](docs/actions-ipa.md) and
[release requirements](docs/releasing.md).

LGPL-2.1 section 6(a) permits application object code and/or source code as
replacement material. A complete buildable application source package can
supply a relink path without a separate object-file kit. Include all required
generators, dependencies and link inputs. Preserve rights to modify the LGPL
library and reverse engineer the application to debug those changes. Apply
LGPLv3 section 4 to components using that version, including Installation
Information where required. Rebuilt libraries can have different checksums.

Do not include game files, commercial artwork, Apple SDKs, Developer Disk
Images, Microsoft installers, or personal signing and pairing material in the
source package. Wine Mono is downloaded from WineHQ on request; the frontend
release package excludes it. Its own notices apply to that download.

## Other repository components

Retained integration and recovery source keeps its embedded terms:

- `iridium-fex-ios/`: FEX MIT and component notices.
- `iridium-wine-ios/`: Wine LGPL-2.1-or-later and component notices.
- `testrepos/Madeira/`: Madeira GPL-3.0-or-later and its dependency notices,
  including the Wine LGPL branch and DXMT D3D9/DXSO LGPL material.
- Madeira-derived Iridium material retains GPL-3.0-or-later. Notices are in
  `iridium/apps/ios/MadeiraSupport/Notices/` and
  `iridium/apps/ios/BuiltinJIT/StikJITNotices/`.
- Moonlight touch-controller images and derived material retain GPL-3.0;
  the notice is `iridium/apps/ios/MadeiraSupport/Notices/Moonlight-LICENSE.txt`.
- StikJIT modifications retain MPL-2.0 where applicable; idevice retains MIT.
- ANGLE, GStreamer/Cerbero, codecs, fonts, tests and other retained dependencies
  keep their own license files. These are not linked by the frontend target.

Public upstream author names and copyright notices are attribution. Original
grants remain in effect.

## Apple toolchain terms

Xcode's installed acknowledgements include the LLVM University of Illinois/NCSA
notice and separate Swift runtime terms. Retain the applicable notices. These
do not grant source rights to Apple's SDKs. Xcode and the SDK remain external
build prerequisites.

GPLv3 and AGPLv3 section 1 exclude qualifying System Libraries from Corresponding
Source and include compilers as Major Components. Compiler-supplied support
routines may qualify under this definition. LGPL-2.1 section 6 has a separate
exception for normally supplied major-component material, subject to its stated
condition when that component accompanies the executable. Apply the actual
license version; the GPLv3 definition does not replace the LGPL-2.1 provision.
These exceptions address source obligations, not redistribution permission.

Apple-specific compiler-runtime license coverage remains a residual risk.
Public unsigned-IPA distribution has a separate acknowledged Apple contractual
risk outside the open-source compliance review. No byte-identical rebuild or
per-object source comparison is required without a license reason for it.

References: [GPLv3](https://www.gnu.org/licenses/gpl-3.0.html),
[LGPL-2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html),
[LLVM license policy](https://llvm.org/docs/DeveloperPolicy.html), and
[Apple Xcode agreement](https://www.apple.com/legal/sla/docs/xcode.pdf).
