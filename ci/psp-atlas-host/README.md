# Native PSP atlas generation

This host target compiles the pinned PPSSPP rasterizer, atlas metadata reader,
ZIM reader/writer, FreeType, libpng and Zstandard outside the upstream checkout.
Only host stdio/path/logging adapters replace app services. The production
metadata and ZIM parsing code is compiled unchanged with active bounds assertions.
The composed rasterizer changes input-range selection and zero-initializes two
missing/glyph records whose dimensions are otherwise undefined. It captures the
actual rasterizer pixels for the serialization check. Font rasterization,
distance-field calculation and rectangle packing retain the upstream algorithms.

The historical shipped metadata has different ranges from the current upstream
scripts. ranges.json preserves its required codepoints and range order exactly,
including intentionally empty ranges. Every fallback receives the same ranges,
keeping the upstream per-range font/vertical-offset indexing aligned.

The host ZIM writer uses the upstream flags and scalar RGBA4444 conversion.
Clang auto-vectorization of that conversion produced incorrect pixels on this
host, so only ZIMSave.cpp disables loop and SLP vectorization. Every generated
texture pixel is compared with its scalar reference before postprocessing; this
fails closed if a toolchain produces different output. Diagnostic libpng output
is not the serialization reference or a delivered proof.

Postprocessing pads the canvas to a power of two for PSP GE texture addressing,
updates UVs, preserves the four input icons' exact RGBA4444 texels, and fits
Source Han's U+3031/U+3032 vertical repeat forms into the existing horizontal
one-character cells. Their advances and complete sampled glyphs are retained.
Font metrics are recomputed from the resulting quads, so line boxes contain
every glyph. The OFL inputs are unmodified; generic atlas names identify the
output resource rather than a renamed font family.

The proof renderer uses production getChar results, bilinear texture alpha,
horizontal bearings and advances at upstream UI sizes (14/17/22/28 points) and
PSP dialog scales (0.6/0.65). Glyph shaping and BiDi behavior remain upstream's.
Proofs do not establish actual device wrapping, game dialogs or GOW acceptance.
See docs/actions-ipa.md for regeneration and review instructions.
