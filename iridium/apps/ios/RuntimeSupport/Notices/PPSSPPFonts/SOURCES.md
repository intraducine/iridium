# Native PSP font notices

The bundled TTF files are unchanged from PPSSPP v1.20.4. FONT-NOTICES.json records
checksums and original copyright, author, license and license-URL name records.
The embedded grants identify SIL Open Font License 1.1. Full upstream OFL texts
and their exact source revisions are retained beside this record. These are
license-text sources; they are not claims that current font releases are the
exact old binary font inputs.

The eighteen PGF replacements are unchanged from PPSSPP v1.20.4.
PGF-PROVENANCE.json records their exact checksums and historical source evidence.
Before upstream camouflaged the names in dc34bea8d4dee77629da3cbaedc83fc8c05af159,
the merged PGF headers identify Japanese/Korean Source Han Sans, Latin Ume Hy
Gothic and Ume P Mincho. Source Han Sans carries SIL OFL 1.1; the Ume original
source archive supplies its unrestricted use/copy/distribution/modification
grant. Full original notices are retained here. The font source version and
manual glyph/metric conversion steps are not claimed to be byte reproducible.
The historical family attribution is stronger evidence than current compatibility
header names, which are not claims that Sony glyphs were extracted.

The separate font_atlas and ppge_atlas bitmap resources are not cleared by these
PGF grants. Their generator inputs still reference Arial Unicode and Kozuka
Gothic files absent from the selected snapshot. Those atlases require their own
redistribution grant or regeneration from licensed open fonts before public
binary distribution. The Roboto-only asciifont atlas has an identified OFL input.
No user or commercial game assets are added.

## Owned UI/PSP atlas replacements

The generated font_atlas and ppge_atlas resources use the unmodified font inputs
locked in `ci/psp-atlas-inputs.json`. `ATLAS-FONT-NOTICES.json` preserves each
input's embedded copyright, family, author, manufacturer and license records.
The six Noto inputs come from noto-fonts commit
`ffebf8c1ee449e544955a7e813c54f9b73848eac` (hinted/ttf family directories):
Noto Sans, Noto Sans Hebrew, Noto Sans Thai, Noto Sans Coptic, Noto Sans Symbols,
and Noto Sans Math. Their full OFL 1.1 text is `Noto-OFL.txt`, from
https://github.com/notofonts/noto-fonts/blob/ffebf8c1ee449e544955a7e813c54f9b73848eac/LICENSE .

Source Han Sans Regular is the full Japanese OTF from Adobe's 2.005R release:
https://github.com/adobe-fonts/source-han-sans/releases/tag/2.005R . The lock
records both the archive and extracted input digests. Its embedded notice names
Adobe and the Reserved Font Name Source; the existing full Source Han OFL text
is retained. Roboto Condensed Regular is the exact pinned PPSSPP TTF already
covered by FONT-NOTICES.json and Roboto-OFL.txt.

The four PSP button icons retain the exact upstream atlas texels, image IDs and
sizes. Their extraction provenance and PNG/pixel digests are recorded in
`ci/psp-atlas-host/icons.json`. No proprietary font bitmap is used by these new
resources. Older delivered personal builds remain unchanged.
