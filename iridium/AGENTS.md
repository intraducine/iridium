# Project Guidelines

## Search Workflow
- Prefer `codedb` for codebase exploration in this repository when a snapshot already exists or when you expect repeated lookups.
- Refresh the local `codedb` snapshot after code changes if you plan to do multiple searches, symbol lookups, outlines, or dependency checks.
- Use `codedb` first for identifier lookup, symbol definitions, outlines, dependency/reverse-dependency checks, and batched code archaeology.
- Use `rg` for a single immediate up-to-date text or regex search right after an edit when paying the snapshot refresh cost is not worth it.
- Do not default to plain `grep` for repository search unless neither `codedb` nor `rg` is available.

## Search Heuristics
- Local measurements on this repo showed `codedb` queries around 1-2 ms, snapshot refresh around 280 ms, and `rg` around 30-50 ms for representative source-tree searches.
- With a fresh snapshot cost included, `rg` is usually cheaper for one quick search.
- After roughly 6 exact identifier searches or about 10 substring searches, the refreshed `codedb` path is usually faster overall than repeating `rg`.
- Once refreshed, prefer `codedb` for the rest of the exploration session unless you specifically need raw live text search semantics.

## Token Discipline
- Treat snapshot refresh as a fixed overhead in both time and tool output.
- If one `rg` query answers the question, use `rg`.
- If the task will involve several searches or structural lookups, refresh `codedb` once and stay on that path.
