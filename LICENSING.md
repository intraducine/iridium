# Licensing

Original Iridium-authored code in `iridium/`, `iridium-runtime-sdk/`, and the root publication tools is licensed under **AGPL-3.0-only**, unless a file or component has a more specific notice. The full text is in LICENSE. This grant does not replace third-party grants or claim ownership of upstream code. Contributions to these original components are accepted under the same terms.

## Third-party boundaries

- `iridium-fex-ios/`: upstream FEX MIT license and component notices are retained. Existing fork material is distributed under its existing notices.
- `iridium-wine-ios/`: Wine LGPL-2.1-or-later and component-specific notices are retained. Existing fork material is distributed under its existing notices.
- `testrepos/Madeira/`: Madeira GPL-3.0-or-later. Its FEX and DXMT forks retain upstream MIT grants while Madeira modifications use GPL-3.0-or-later. Its Wine fork documents GPL-3.0-or-later conversion in LICENSE-MADEIRA.md. Those terms are not replaced with AGPL.
- Madeira-derived portions within Iridium, including the adapted JIT script, retain GPL-3.0-or-later. The copied notices in `iridium/apps/ios/MadeiraSupport/Notices/` and `iridium/apps/ios/BuiltinJIT/StikJITNotices/` remain applicable. New independently authored Iridium integration code is AGPL-3.0-only.
- The on-screen controller in `iridium/apps/ios/Iridium/Input/TouchControllerOverlay.swift` follows Moonlight iOS's touch-event pattern. Its button and stick images are copied into `iridium/apps/ios/Iridium/Assets.xcassets/`. The Moonlight material is GPL-3.0; its license is retained in `iridium/apps/ios/MadeiraSupport/Notices/Moonlight-LICENSE.txt`.
- StikJIT source and textual-interface modifications retain MPL-2.0 where applicable; idevice retains MIT. The binary is not included. Source URLs and the pinned archive digest are in BuiltinJIT.
- Other libraries, test data, fonts, and tools retain their embedded notices. The root license does not override them. Public upstream copyright names and contact details are retained as attribution, not presented as Iridium maintainer identity.

GPLv3 and AGPLv3 section 13 permit combining the covered components under their respective terms. This is a mixed-license repository, not a blanket AGPL relicensing of upstream work. Previously granted licenses are not revoked.

## Source publication and binary releases

Keep the supplied licenses and attribution files with redistributed copies. Modification information is recorded in CHANGES-FROM-UPSTREAM.md.

If you publish an IPA, also publish the matching source code, including changes
to third-party libraries, and the instructions needed to rebuild it. Include
the required license notices. Keep these files available with that release;
a branch that changes later is not enough.

CI replaces StikJIT's opaque idevice archive with a pinned source build. The script comparison and AGPL notice are recorded in StikJITNotices/SOURCES.md. Resolved crate notices still require review. Resolve the recorded audit items before distributing a binary. GStreamer, codecs, crypto libraries, and the runtime must also be inventoried at their actual build revisions. Do not include game files, commercial artwork, Apple SDKs, Developer Disk Images, Microsoft runtime installers, or personal signing/pairing material.

AGPL permits commercial use and forks. It requires source sharing under its terms, including the network-interaction requirement for modified versions where applicable. It does not require unrelated games merely run by the runtime to become AGPL.

## Source-build recipes

ANGLE is built from Google ANGLE commit `6024e9c05548480c3b2ea42836a112509a549a95`, whose BSD-style license is copied by the build recipe. Its dependencies retain separate licenses. The Cerbero recipe uses revision `59548269f4fd0f701818f0bafdb102959ec81e65`; Cerbero source headers grant LGPL-2.0-or-later, while individual codecs and libraries retain their own terms. A source-built SDK is not by itself a complete distribution audit.

The Linux recipe collects exact Debian source-package versions and copyright files for copied libraries. An IPA must include a matching complete source archive and notices for all target dependencies. Build requirements are recorded in `ci/binary-release-blockers.json`; final binary audit requirements are in `ci/binary-package-blockers.json`.

## Windows compiler runtime sources

The pinned llvm-mingw 20260421 toolchain uses LLVM 22.1.4 and mingw-w64
`b2b5e53e9d9be406e60ebc152a9cf161b87d4e12`, as specified in its build scripts
at `81fba99f8a388b07b2c14be0e4e17af6bd9d59a4`. The source collector includes
these complete source archives and the toolchain build scripts, each with a
verified digest. Their component notices remain inside the archives. LLVM 15,
used separately by the native graphics component, is also retained.

This covers the pinned toolchain source inputs, not a completed link audit.
The final audit must still match the linked target libraries to these inputs,
retain notices with the binary distribution, and review libraries supplied by
other compiler inputs. The retained native artifact from run 34650568812
identifies Clang 22.1.4 (`35990504507d79e0b9deb809c8ee5e1b34ceef20`)
in all three xinput DLLs and iridium-mfprobe.exe. Despite the GCC command
names, CI places the pinned llvm-mingw wrappers before Homebrew on PATH;
these helper binaries do not establish a Homebrew GCC dependency.

The vendored OpenSSL 0.10.76, tokio-rustls 0.26.4 and untrusted 0.9.0 sources
include seven public certificate/key test or verification files. The collector permits only their verified upstream bytes, pinned by
SHA-256 in `ci/collect-release-source.py`. These are upstream test data, not
maintainer signing credentials. Changed files, unlisted signing files and
symlinks remain rejected. The fixture pins were checked against the crate
archive digests recorded in idevice's Cargo.lock. All 359 registry crate archives
were checksum-verified and scanned for these file types; no other exceptions
were found. This is a lockfile-wide source check, not the resolved iOS link audit.

The source package also requires Cargo's license inventory and the iOS
`idevice-ffi` dependency tree (normal and build dependencies, excluding tests).
These records accompany the vendored sources for the final target review.

Rust's standard-library source is collected from the `rust-src` component of
the pinned toolchain. Its library copyright inventory, license texts and
`rustc -vV` version/commit record are retained beside the crate sources. Missing
source or notice files stop collection. The compiler itself remains a build
tool; the linked standard-library source is part of the release audit.

## Media compiler and source-package boundaries

The pinned Cerbero revision uses Rust 1.96.0 for its Rust plugins, independently
of idevice's Rust toolchain. Source packaging also collects that version's
official `rust-src` archive, including its copyright and license files. Its
digest is pinned in `ci/collect-release-source.py`; changing Cerbero requires
review of this separate pin. The JIT standard library is not a substitute.

Cerbero's source distribution needs its recipes, nested patches, package
definitions, configuration, tools and launcher. The source-manifest patch and
the pre-compilation packaging check preserve those inputs. Cargo source
collection also preserves nested source directories named `target` and
checksum-verified upstream fixtures required by vendored manifests.

The media SDK contains more plugins than the app registers. The app's 24
explicit registrations are in `MediaSupport/MediaRuntime.c`; all are present in
the retained media library. A minimal iPhone link of those registrations also
pulls in MoltenVK and Rust objects. Their obligations cannot be dismissed on the
basis that Iridium does not explicitly register a Vulkan or Rust plugin.

Cerbero copies MoltenVK from the Vulkan SDK 1.3.283.0 installer, rather than
building that library. The retained binary identifies MoltenVK 1.2.9, consistent
with [LunarG's release record](https://www.lunarg.com/lunarg-releases-vulkan-sdk-1-3-283-0-for-windows-linux-macos/).
The retained GStreamer MoltenVK object matches the SDK's iPhone object byte for
byte (SHA-256 `52a9140c04f2366e83b6693ae3e612dcb84a0412534495776efb16530b6403a8`).
The SDK's VERSIONS.txt identifies commit
`bf097edc74ec3b6dfafdcd5a38d3ce14b11952d6`. Source collection includes
that commit and its pinned external sources, with archive digests in
`ci/moltenvk-source-inputs.json`. Their upstream notices accompany the app in
`MadeiraSupport/Notices/MoltenVK`. These sources supplement the installer image;
the installer alone is not the source inventory.

The selected Cargo notice records also distinguish upstream SPDX declarations
from embedded grants. `plist_ffi` retains libplist's LGPL-covered C++/test files;
its Cargo MIT field is not a blanket grant for those files. See the supplemental
Cargo SOURCES.md and supplied standard texts. Original project licenses remain
unchanged.


The media notice resources include the upstream C/C++ component texts found in
the app-registration link probe, with per-file digests. The FFmpeg 7.1 recipe
uses its Meson port's disabled GPL default and explicitly disables version3 and
nonfree. Preserve its license explanation and the recipe patches in source
releases. See [FFmpeg's licensing guidance](https://ffmpeg.org/legal.html).
The media Rust vendor tree is broader than the runtime helper objects linked
by the probe; a vendor-wide inventory does not establish the final link inventory.
Static LGPL libraries require a usable modification and relinking path. Verify
the supplied app sources and build instructions support that path before release.


Rust's `rust-src` component does not contain its registry crate dependencies.
Media source collection therefore reads the bundled library/Cargo.lock, downloads
all locked registry archives, and verifies each Cargo checksum. The media link
probe's `gstaws` object defines allocation shims; it does not establish that AWS
service code is linked. The associated standard-library and helper notices are
in `MadeiraSupport/Notices/MediaRust`. The final app map must confirm this boundary.


The same registry-source collection applies to JIT's Rust standard-library
lockfile, independently of idevice's Cargo.lock. The retained Rust 1.98.1
library lockfile has 30 registry crates. Its helper notices supplement the
Rust copyright inventory in `StikJITNotices/RustDependencies`. Both Rust
collections reject missing or ambiguous library lockfiles, unknown registries,
and mismatched crate digests. Lockfile coverage includes other platforms and
must not be presented as a list of libraries linked into the final app.


Xcode's installed Acknowledgments.pdf includes LLVM's University of Illinois/NCSA
notice and separate Swift runtime terms. These are component-specific notices,
not a blanket source grant for Apple SDKs. Apple SDKs and Xcode remain externally
obtained build prerequisites. Retain the notices already identified for these inputs. Remaining Apple-specific
coverage uncertainty is a residual licensing risk, not an open-ended provenance
requirement. Do not describe LLVM 22 source as Apple LLVM 21 source.

Review source obligations separately from permission to distribute compiler
runtime code. GPLv3 and AGPLv3 section 1 exclude qualifying System Libraries
from Corresponding Source and expressly include compilers as Major Components.
A compiler-supplied support routine may qualify; its presence in a static link
alone does not establish a source-distribution requirement. Record the basis
for that classification against the exact linked object. This exception does
not itself grant permission to redistribute Apple or third-party code.

Apply the actual license version. LGPL 2.1 section 6 has its own exception for
normally supplied major-component material, qualified when that component
accompanies the executable. Do not assume the GPLv3 System Library definition
settles this different provision. Record any valid later-version license route
explicitly; this audit does not change the project's or components' licenses.

For Xcode inputs, retain the existing toolchain identification, applicable notices,
and completed source-exception analysis. Exact per-object source correspondence
is not a release requirement without evidence that it is needed to comply with
a license. Remaining Apple compiler-runtime coverage uncertainty is a residual
risk. Public unsigned-IPA contractual authorization is acknowledged separately
and is outside this open-source compliance audit; this does not grant permission.

References: [GPLv3 section 1](https://gcc.gnu.org/onlinedocs/gcc/Copying.html),
[LLVM license policy](https://llvm.org/docs/DeveloperPolicy.html), and
[Apple Xcode agreement](https://www.apple.com/legal/sla/docs/xcode.pdf).


Before final source packaging, restored idevice archives are checked against
every vendored Cargo file digest. Restored Cerbero archives must retain their
launcher, iPhone configuration, recipe and package entry points. Cached binaries
do not exempt their accompanying sources from these checks. A rejected source
archive needs source repair or recollection; a prior successful compilation is
not evidence that its source package is complete.


Restored source archives are repaired independently of compiler outputs before
package validation. Missing Cargo files come only from crate archives that match
the vendored package checksum and individual file checksums. Cerbero's missing
build files come from its prepared pinned source with the recorded patches.
Repairs use atomic archive replacement and retain existing members and file modes.


The retained ANGLE artifact from run 34667058073 identifies revision
`6024e9c05548480c3b2ea42836a112509a549a95`. Both frameworks passed the
arm64 iOS 18.0 minimum, unsigned state, public API and dynamic-dependency checks.
A local relink of the same source exposes Xcode's `chkstk_darwin.S.o` and
`chkstk_darwin2.S.o`. The first object's two function bodies match byte sequences
in the retained GLES framework; the second object's short branch is not unique
and is not independently matched by that comparison. Their remaining Apple-specific license coverage uncertainty is recorded as a
residual risk. No further instruction matching is required by this audit.

LGPL replacement material must permit users to modify the covered library and
recombine or relink the application under the applicable license version.
For LGPL 2.1 section 6(a), the work that uses the library may be supplied as
object code and/or source code. Complete buildable Iridium source, required
inputs and usable instructions can satisfy this route without a separate .o
kit. Source files alone are insufficient if required generators, dependencies
or link inputs are missing. Preserve modification and reverse-engineering rights
for debugging those modifications. Check LGPLv3 components under section 4,
including Installation Information where that section requires it.

Engineering tests support this review. A modified-library marker test is
optional evidence, not a general license requirement for every library.
Byte-identical rebuilds are not required unless reproducibility is the stated
test. Original release hashes identify the shipped artifacts; replacement
artifacts normally have different hashes. Device behavior is a separate check.

## Practical compliance completion

The open-source compliance package is complete when major shipped components
have identified licenses and required notices, required GPL/LGPL source and
modifications are supplied, the buildable application material and instructions
permit LGPL replacement/relinking, and packaged binaries have component owners.
The accepted inventory covers 2,423 binaries and 24 static archives. Reuse it;
do not require prose for each binary, intermediate-object hashes, reproducible
builds, or per-library marker tests. Runtime testing is a separate release task.

Residual risks: Apple compiler-runtime grant coverage remains uncertain; the
public unsigned-IPA route has a separately acknowledged contractual risk. These
do not keep the open-source audit open once the material requirements are met.
