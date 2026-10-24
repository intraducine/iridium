# PSP atlas generation

This host recipe uses the pinned PPSSPP rasterizer and production metadata/ZIM
readers with FreeType, libpng, and Zstandard. Build instructions are in the
[IPA guide](../../docs/actions-ipa.md#replace-psp-and-other-console-engines).

Adaptations:

- `ranges.json` preserves historical glyph ranges/order for every fallback font.
- Missing glyph records are zero-initialized; rasterizer pixels are checked against serialization.
- ZIMSave disables vectorization and checks every RGBA4444 pixel against scalar output.
- Postprocessing pads textures for PSP addressing, updates UVs, preserves icon
  texels, and fits U+3031/U+3032 into horizontal cells.
- Font metrics are recomputed from final quads. Licensed font inputs remain unchanged.

Review production-parser checks and actual-size multilingual proofs. They cover
glyph lookup and metrics, not device wrapping, shaping/BiDi, or game dialogs.
