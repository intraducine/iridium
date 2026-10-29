# Licensing

Original Iridium code is **AGPL-3.0-only**, unless a file states otherwise.
See [LICENSE](LICENSE). Third-party licenses and copyright notices remain in
force; this summary does not replace them.

## Components

Current revisions are in [UPSTREAM-SOURCES.json](UPSTREAM-SOURCES.json).

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
| Menu audio | Atkey's royalty-free UI Sound Pack license, retained in `iridium/apps/ios/App/Resources/MenuAudio/Atkey-license.txt`; app use and modification allowed, standalone sound redistribution/resale prohibited |

Madeira's pinned Wine branch specifies LGPL-2.1-or-later in its own
`LICENSE-MADEIRA.md`; its older top-level GPL summary does not override that file.
Madeira's Converter Exception covers only the copyright named by the exception.
It grants no rights to Apple's library or unrelated components.

| Console component | Terms |
| --- | --- |
| SameBoy Core, Libretro adapter, replacement boot ROMs | Expat/MIT; Libretro API header has its own MIT notice |
| DolphiniOS, Azahar, Flycast | GPL-2.0-or-later and file/dependency-specific terms |
| Play! | BSD-2-Clause and dependency-specific terms |
| PPSSPP | GPL-family, including GPLv3 libkirk/xBRZ; LGPL-2.1-or-later at3_standalone; dependency-specific terms |
| PSP MoltenVK 1.2.9 and Azahar MoltenVK 1.4.1 | Apache-2.0 and dependency-specific MIT/Khronos/BSD terms |

Selected GPL-or-later components may use GPLv3 when combined with AGPLv3.
Original grants remain intact. A dynamic-library boundary is not a license
exception or a determination that components are separate works.

## Notices and source

- Retain the app's `licenses` directory, Madeira runtime/Dock/converter notices,
  and per-file notices. Adaptations are listed in [CHANGES-FROM-UPSTREAM.md](CHANGES-FROM-UPSTREAM.md).
- Deliver exact matching dependency sources, local patches, generators, component
  records, and usable build/relink instructions with an IPA. Keep source beside
  the binary at a permanent versioned URL; an expiring Actions artifact is insufficient.
- Complete buildable application source can provide LGPL replacement material.
  Include required tools/inputs and Installation Information where applicable.
  Preserve the right to modify LGPL libraries and reverse engineer the app to
  debug those changes. Replacement binaries need not match release checksums.
- Keep games, commercial artwork, Apple SDKs, disk images, Microsoft installers,
  private logs, and signing/pairing material out of source packages. Wine Mono
  downloads have their own notices and are excluded from the frontend package.

Build receipts and source collection retain the console dependency sources,
MoltenVK archives, FFmpeg codec source, and original notices. Exact reviewed
unused signing fixtures and prebuilt archives are excluded by path and digest;
changed files fail the audit. See [build/replacement](docs/actions-ipa.md) and
[release requirements](docs/releasing.md).

## Fonts and retained components

PSP font provenance, original grants, checksums, and historical blob IDs are in
`iridium/apps/ios/RuntimeSupport/Notices/PPSSPPFonts/PGF-PROVENANCE.json` and its
adjacent notices. PGF inputs identify Source Han Sans (SIL OFL) and Ume fonts
(unrestricted grant); bundled TTF inputs retain OFL records. These records do not
identify every original TTF version or later glyph adjustment.

New UI/PSP atlases use locked, unmodified OFL inputs through the upstream
rasterizer. The recipe retains notices and source and excludes only exact
superseded atlas bytes. Original Arial Unicode/Kozuka references do not establish
redistribution permission. Older delivered builds are unchanged.

The retained FEX fork is MIT with component notices; Wine is LGPL-2.1-or-later.
Madeira modifications retain their file-specific GPL terms and exceptions.
Moonlight-derived controls retain GPL-3.0 and their bundled notice. StikJIT
modifications retain MPL-2.0; idevice retains MIT. ANGLE, GStreamer/Cerbero,
codecs, fonts, and other retained dependencies keep their own notices.

## Distribution limits

Public binary distribution still requires combined-app review, including
PPSSPP's independent GPL copyright holders and Apple's Metal Shader Converter.
Madeira's exception does not automatically extend to them. The converter
agreement permits distribution only under its stated conditions. A successful
build or separate dylib does not resolve these questions.

Retain applicable Apple LLVM/NCSA and Swift compiler-runtime notices. System
Library and compiler exclusions depend on the actual license version; they do
not grant redistribution permission or rights to Apple SDK source. Apple-specific
compiler-runtime coverage remains a residual risk. Public unsigned-IPA contractual
permission is a separate acknowledged risk. Do not require byte-identical builds
or per-object source matching without a license reason.

See [GPLv3](https://www.gnu.org/licenses/gpl-3.0.html),
[LGPL-2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html),
[LLVM policy](https://llvm.org/docs/DeveloperPolicy.html), and the
[Xcode agreement](https://www.apple.com/legal/sla/docs/xcode.pdf).
