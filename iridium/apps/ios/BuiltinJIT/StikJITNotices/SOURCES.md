# StikJIT source records

StikJIT 1.5.0 source: https://github.com/StikDebug/StikJIT/tree/640fac91de403fdb85a3778aa0bbb7f30737b74c
Root license: MPL-2.0. Its README separately reserves dependency/script licenses.
CI builds the framework from this source. It replaces the bundled opaque
idevice archive with a source build and replaces the FFI header with its generated
header. The Swift textual-interface qualification adjustment remains applied.
No framework binary is included in this repository.

idevice source: https://github.com/jkcoxson/idevice/tree/7a1cca397a79589e177de163d888ba761a137ce5
Root license: MIT. CI uses Cargo.lock, vendors dependencies, and records crate
license metadata. The resolved dependency notices still require review.
This source revision is a replacement, not a claim about the source used for
the old prebuilt archive. Build and device compatibility are unverified.

Madeira JIT script: https://github.com/willfaust/Madeira
License: GPL-3.0-or-later. Iridium adds an attach failure guard and one helper
readiness notification. The corresponding script is included in this tree.

StikJIT legacy.js matches the script in StikDebug commit
94bc9e8cf3b41f32f125f046abf33d913f4e1b2d (AGPL-3.0 license text).
The separate provenance/license record for its universal.js variant remains
unresolved. Do not infer permission from an unrelated root license.

Exact archive digests are in ci/runtime-inputs.json. Build steps are in
ci/prepare-stikjit.sh. Binary distribution stays blocked by
ci/binary-release-blockers.json until the source and notice audit is complete.
