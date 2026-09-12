# Supplemental Cargo source notices

These standalone license files supplement the crate archives. They are copied
unchanged from the repository revisions recorded in each crate's
.cargo_vcs_info.json. Every crate archive was checked against the pinned
idevice Cargo.lock. Identical license texts share one file.

This is a lockfile-wide source inventory. It does not claim that every listed
crate is linked into the iOS app. Other crates retain their embedded notices.
The final build dependency tree identifies selected normal/build dependencies.

| Crate | Version | Notice | Exact upstream source |
| --- | --- | --- | --- |
| async-compression | 0.4.41 | [async-compression-MIT.txt](async-compression-MIT.txt) | [Source](https://raw.githubusercontent.com/Nullus157/async-compression/269174b4be20e3cfcbb7e7fa4d7d9596183e287b/LICENSE-MIT) |
| c2rust-bitfields | 0.21.0 | [c2rust-BSD-3-Clause.txt](c2rust-BSD-3-Clause.txt) | [Source](https://raw.githubusercontent.com/immunant/c2rust/93471e6bbdca883d7c18383cc842a07812e6e11e/LICENSE) |
| c2rust-bitfields-derive | 0.21.0 | [c2rust-BSD-3-Clause.txt](c2rust-BSD-3-Clause.txt) | [Source](https://raw.githubusercontent.com/immunant/c2rust/93471e6bbdca883d7c18383cc842a07812e6e11e/LICENSE) |
| compression-codecs | 0.4.37 | [async-compression-MIT.txt](async-compression-MIT.txt) | [Source](https://raw.githubusercontent.com/Nullus157/async-compression/9d848a02f13f3a56542e4123be8947a8da06097e/LICENSE-MIT) |
| compression-core | 0.4.31 | [async-compression-MIT.txt](async-compression-MIT.txt) | [Source](https://raw.githubusercontent.com/Nullus157/async-compression/2a28343998e67ea519b87005b9d295b134c00dd0/LICENSE-MIT) |
| valuable | 0.1.1 | [valuable-MIT.txt](valuable-MIT.txt) | [Source](https://raw.githubusercontent.com/tokio-rs/valuable/9efc29b6e58cef28f6566a47aa7e142a55fead77/LICENSE) |
| wasip2 | 1.0.2+wasi-0.2.9 | [bytecodealliance-MIT.txt](bytecodealliance-MIT.txt) | [Source](https://raw.githubusercontent.com/bytecodealliance/wasi-rs/06ce201370fcde0d1b0d47cac8ecb1b0b312c9f9/LICENSE-MIT) |
| wasip3 | 0.4.0+wasi-0.3.0-rc-2026-01-06 | [bytecodealliance-MIT.txt](bytecodealliance-MIT.txt) | [Source](https://raw.githubusercontent.com/bytecodealliance/wasi-rs/06ce201370fcde0d1b0d47cac8ecb1b0b312c9f9/LICENSE-MIT) |
| wasm-encoder | 0.244.0 | [bytecodealliance-MIT.txt](bytecodealliance-MIT.txt) | [Source](https://raw.githubusercontent.com/bytecodealliance/wasm-tools/d4e317f22c3bace76cb3205003bcc34b4929037d/LICENSE-MIT) |
| wasmparser | 0.244.0 | [bytecodealliance-MIT.txt](bytecodealliance-MIT.txt) | [Source](https://raw.githubusercontent.com/bytecodealliance/wasm-tools/d4e317f22c3bace76cb3205003bcc34b4929037d/LICENSE-MIT) |
| wit-component | 0.244.0 | [bytecodealliance-MIT.txt](bytecodealliance-MIT.txt) | [Source](https://raw.githubusercontent.com/bytecodealliance/wasm-tools/d4e317f22c3bace76cb3205003bcc34b4929037d/LICENSE-MIT) |
| wit-parser | 0.244.0 | [bytecodealliance-MIT.txt](bytecodealliance-MIT.txt) | [Source](https://raw.githubusercontent.com/bytecodealliance/wasm-tools/d4e317f22c3bace76cb3205003bcc34b4929037d/LICENSE-MIT) |

## Notice checksums

- `async-compression-MIT.txt`: `88d1e3160df48926ad3310a8ec5699b502889565908f1be7e77cd21282c7a709`
- `c2rust-BSD-3-Clause.txt`: `2bd73a6df34e41c531e4088a97e90a489b163926fb214ac90e9c172d124bc2f8`
- `valuable-MIT.txt`: `ed60d479b8fd1f64e9cbc3de449a16a53ac1b3d1b6aeb9bf9d190a8e93061b44`
- `bytecodealliance-MIT.txt`: `23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3`

## Packages with manifest declarations

The following exact upstream revisions declare their license in Cargo.toml
but do not supply a standalone license text. Their declared author is Jackson
Coxson. These are upstream author records, not newly assigned copyright years.
The standard [MIT text](MIT.txt) accompanies these declarations. Its placeholder
copyright line is the SPDX template, not an upstream copyright notice.

| Package | Version | Upstream revision | Declaration |
| --- | --- | --- | --- |
| ns-keyed-archive | 0.1.5 | [f8cec65e](https://github.com/jkcoxson/ns_keyed_archive/tree/f8cec65e865cb48301d33b2244bec45a2f3d2bc2) | MIT OR Apache-2.0 |
| plist-macro | 0.1.6 | [d1d48559](https://github.com/jkcoxson/plist_macro/tree/d1d48559ddc8e9bd263f36180bbe1d4f2a3d55e5) | MIT |
| plist_ffi | 0.1.6 | [26537916](https://github.com/jkcoxson/plist_ffi/tree/265379167ab3f9a5664621a7f1c0f494b2ac7c96) | MIT in Cargo; file-specific exceptions below |

`plist_ffi` also includes libplist C++ bindings, tests and tools. Their headers
retain LGPL-2.1-or-later grants and their original copyright notices. The
upstream README explicitly preserves those terms. The [LGPL 2.1 text](LGPL-2.1.txt)
is supplied for those files; the crate's MIT metadata does not replace them.
Its Cargo build script compiles `src/shims.c`, not the `cpp` directory. This
distinguishes the supplied source from the selected JIT build inputs.

`plist` 1.8.0 includes its complete MIT notice in `LICENCE`, with copyright
2015 Edward Barnard. That file remains in the vendored source. Notice searches
must include both LICENSE and LICENCE spellings.

Standard texts, downloaded unchanged:

- [SPDX MIT](https://spdx.org/licenses/MIT.txt), SHA-256
  `c3b1b78bc8bd3ea13aa4bc9778442d16560270afa235006d816e5e88cef24db4`.
- [GNU LGPL 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt), SHA-256
  `20e50fe7aae3e56378ebf0417d9de904f55a0e61e4df315333e632a4d3555d95`.
