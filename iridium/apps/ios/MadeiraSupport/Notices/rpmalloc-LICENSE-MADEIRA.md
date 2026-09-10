# Licensing of Madeira's modifications to rpmalloc

This repository is a fork of [rpmalloc](https://github.com/FEX-Emu/rpmalloc),
itself a fork of Mattias Jansson's rpmalloc. **The upstream licence is
unchanged and continues to apply to all upstream code.** See `LICENSE` (0BSD /
public-domain-equivalent).

## What is licensed how

| Code | Licence |
|---|---|
| Original rpmalloc, and all upstream FEX-Emu changes | as in `LICENSE` (0BSD) — unchanged |
| Commits authored by **Ryan Houdek** on the `ios-mythic` branch | as in `LICENSE` (0BSD) — **not** relicensed |
| Commits authored by **Will Faust**, as offered on the `ios-madeira` branch | **GPL-3.0-or-later** |

`git log --format='%an'` distinguishes them. Where a single file contains both,
the file as a whole may only be distributed under terms compatible with
GPL-3.0-or-later, because the GPL-covered contributions cannot be separated
from it. The underlying upstream code remains available under 0BSD **from
upstream**, and nothing here withdraws that.

## Why

The intent is that derivatives of this work which are *distributed* remain open
source. A permissive licence allows a proprietary derivative; the GPL does not.

Two limits are worth stating honestly rather than leaving implied:

- The GPL constrains **distribution**, not private modification or use.
- Changes published earlier under a permissive licence were granted under it,
  and that grant cannot be revoked. See the branch note below.

## Branches, and what each one offers

This distinction matters and is easy to get wrong:

| Branch | Status |
|---|---|
| **`ios-mythic`** (through `61f5b29`) | The previously published history. It **retains its prior permissive grants** — anyone who has it keeps 0BSD/MIT rights to that material, and nothing here withdraws them. Kept unchanged because a published FEX gitlink references it. |
| **`ios-madeira`** | The same material, **re-offered under GPL-3.0-or-later**, with the licensing boundary placed before the first Madeira-authored commit. |

So the replayed commits are *dual-availability*: obtainable under their original
permissive grant from `ios-mythic`, and under the GPL from `ios-madeira`. That
is a consequence of having published them permissively first, and it cannot be
undone.

**Only contributions first published after this migration are GPL-only.** Those
are the ones for which no permissive grant was ever made.

## Contributing

Contributions are accepted under **GPL-3.0-or-later**. See `CONTRIBUTING.md`.
