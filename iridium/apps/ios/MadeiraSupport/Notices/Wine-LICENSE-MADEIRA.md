# Licensing of this Wine fork (LGPL branch `madeira-lgpl`)

This repository is a fork of [Wine](https://www.winehq.org/), which upstream
distributes under **LGPL-2.1-or-later**. This branch keeps that licence.

- Upstream code: LGPL-2.1-or-later, all upstream copyright and licence
  notices unchanged. Baseline: upstream tag `wine-11.4`.
- Modifications and new files authored for
  [Madeira](https://github.com/willfaust/Madeira): **LGPL-2.1-or-later**,
  Copyright (C) 2026 Will Faust, except the third-party contributions
  listed below. The new `dlls/wineios.drv` files are
  derived from upstream `winecoreaudio.drv` and keep its CodeWeavers and
  Huw Davies copyright notices.
- Provenance: the branch was rebuilt from the upstream baseline with the 51
  commits listed in the Madeira repository's `docs/wine-lgpl-provenance.md`,
  cherry-picked from the earlier GPL-converted branch with `-x` (each commit
  message names its origin). Later changes are committed on this branch
  directly. The earlier branch's LGPL-section-3 conversion to
  GPL-3.0 is NOT applied here; that conversion is irreversible for that
  copy, which is why this branch was rebuilt from the upstream baseline
  instead.
- Third-party contributions, **LGPL-2.1-or-later**, copyright retained by
  their authors, each signed off under the DCO (see `CONTRIBUTING.md`):
  - `feb96ad2be4` xinput: read Madeira host controller snapshots through
    win32u. Author: 125hz. Merged from pull request #1 on 2026-09-25.
  - The iOS WoW64 series, author 125hz, merged from pull requests #6-#12 on
    2026-09-29: `970dac54a4e` (WoW64 guest pointer conversion),
    `2ebe9374b26` (wow64win), `db62a711998` (unixlib wow64 thunks),
    `e9289051644` (ntdll per-thread WoW64), `1a73c698b8c` (win32u per-process
    state), `f9074408fd9` (server WoW64 thread contexts), `059cb1923c0` (AFD
    pointers, I/O status owner, volume serial).
  - `56f69bc7528` dinput: opt-in joystick backed by the Madeira host gamepad slot.
    Author: 125hz. Merged from pull request #3 on 2026-09-29.
  - `3ba35adcbdd` server iOS: queue a process-wide system APC on a live thread when
    none can be signalled. Author: 125hz. Merged from pull request #13 on
    2026-09-29.
  - Round 3, author 125hz, merged on 2026-09-30:
    `4e85de8c795`, `8d4c3d9ab5b`, `5c4d1f7a6f2` (nsi reads through the
    in-process fallback without `\\.\Nsi`, pull request #14);
    `c3119789ade` (server iOS: hand an undeliverable async I/O APC to a
    waiting thread, pull request #15); `e200a5e19a9`, `f6848ad4e98` (opt-in
    fastsync for events and semaphores, pull request #16); `d770df01ae7`
    (ntdll ARM64EC: opt-in guard against a self-deadlock in the loader's
    image-map notification, pull request #17).

The LGPL permits combining this library with proprietary components (such
as Apple's Metal Shader Converter) subject to LGPL-2.1 section 6; see the
Madeira repository's `docs/LICENSING.md`.
