# Licensing of this Wine fork

This repository is a fork of [Wine](https://www.winehq.org/), which upstream
distributes under **LGPL-2.1-or-later**.

## This copy is distributed under GPL-3.0-or-later

LGPL-2.1 **section 3** expressly permits this:

> You may opt to apply the terms of the ordinary GNU General Public License
> instead of this License to a given copy of the Library. To do this, you must
> alter all the notices that refer to this License, so that they refer to the
> ordinary GNU General Public License, version 2, instead of to this License.
> (If a newer version than version 2 of the ordinary GPL has appeared, then you
> can specify that version instead if you wish.) Do not make any other change
> in these notices.

That is what has been done here, and only that:

- Every Wine-owned notice referring to the Lesser GPL now refers to the
  ordinary GPL, version 3. **5,738 existing files were modified** and 3 files
  added (`COPYING`, this file, `CONTRIBUTING.md`) — 5,741 paths in the commit
  in total. The modified set covers source headers, the top-level `LICENSE`,
  the READMEs and their translations, the manpages, the PO catalogues and the
  font source (`.sfd`) files.
- Translations of **both** licence messages — `shell32` (the About dialog) and
  `winecfg` (Wine Configuration) — that still described the Lesser GPL are
  marked `#, fuzzy`, so gettext falls back to the corrected English source
  rather than showing a user the wrong licence. **76 entries across 49
  catalogs.** Rewriting licence text in every language was not attempted.
  Verified with `msgattrib --no-fuzzy --translated | msggrep -e Lesser`: no
  active translation mentions the Lesser GPL, and all 49 catalogs compile.
- Manpages and font sources that pointed readers at `COPYING.LIB` now point at
  `COPYING`.
- Every copyright line is preserved exactly. No other wording was altered.
- `COPYING` is the GPL-3.0 text. `COPYING.LIB` is retained unchanged as the
  record of the licence this copy was received under.

### What was deliberately NOT converted

**Bundled third-party works.** LGPL-2.1 §3 speaks of applying the GPL to a copy
of *the Library*. Wine bundles code from other projects under their own grants,
and those are not ours to relicense, so their notices are untouched:

- `libs/fluidsynth/` — the FluidSynth project
- `libs/vkd3d/` — the vkd3d project, which has its own AUTHORS
- `dlls/jscript/regexp.*`, `dlls/vbscript/regexp.*` — Mozilla-derived
- `dlls/jscript/tests/sunspider-string-base64.js` — MPL 1.1 / GPL 2.0 / LGPL
  2.1 tri-licensed
- `libs/mpg123/`, `libs/lcms2/` and similar bundled libraries

**Historical statements, which are records rather than notices.** For example
`dlls/mfplat/main.c` noting code was "released under LGPL2", and
`dlls/storage.dll16/storage.c` noting a 2004 contribution. Converting these
would falsify history.

**`fonts/*.ttf` (12 files)** carry the notice inside binary font metadata,
where rewriting means regenerating font tables and checksums. They are
unmodified upstream works, LGPL still describes them accurately, and LGPL code
is compatible inside a GPL work. Compiled artifacts under `build-*/` regenerate
from converted sources.

### Limits of this classification

Wine-owned code was distinguished from bundled third-party code by provenance:
directory (`libs/<project>/`), the presence of a separate AUTHORS or licence
file, and foreign licence markers (MPL, Netscape, Apache). Files carrying a
`Copyright ... for CodeWeavers` or similar attribution were treated as Wine's,
because those are Wine contributors.

**This classification is by directory and notice, not a per-file authorship
audit of ~5,700 files.** If you hold copyright in code here that you believe
was wrongly converted, please open an issue and it will be reverted.

## What this does and does not achieve

Upstream Wine remains LGPL and is unaffected. Anyone may still obtain Wine
under LGPL **from upstream** — this changes only the licence of *this copy*.

The effect is that a distributed derivative of this fork must be GPL-compatible
and offer source. LGPL would have permitted linking it into a proprietary
program; the GPL does not.

Limits worth stating plainly:

- The GPL constrains **distribution**, not private modification or internal use.
- Copies obtained earlier under LGPL keep those rights. This is not retroactive.
- It does not cover programs merely *run* by Wine. Those are separate works.

Contributions authored for Madeira by Will Faust are **GPL-3.0-or-later**.

## Contributing

See `CONTRIBUTING.md`. Contributions are accepted under GPL-3.0-or-later.
