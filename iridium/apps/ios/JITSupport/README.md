# Checked JIT transport

`ScriptRunner.swift` is adapted from StikJIT 1.9.0, commit
`32287268fa5824f9edce4cb359f5833ce0cf7b00`, under MPL-2.0. The upstream licence
is retained in the app's `legal/LICENSE-StikJIT-MPL-2.0.txt`.

`ci/stikjit_frontend.py` builds this runner with the pinned StikJIT Swift source
and source-built idevice FFI. It stages only the resulting framework into the
owned helper. The runtime adapters, their pins and the shared memory ABI remain
separate. The framework includes its checked source/binary receipt and dependency
notices. Release source collection retains both pinned archives and locked Cargo
sources.

The checked bridge takes hexadecimal strings, uses all 64 address bits, and
checks every page response in bounded batches. It never calls the older SDK's
unchecked batch function. External SDKs without the checked bridge use the safe
per-page fallback.
