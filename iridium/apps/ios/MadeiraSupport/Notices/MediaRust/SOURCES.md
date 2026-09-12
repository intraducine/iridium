# Media Rust runtime notices

The media library uses Rust 1.96.0. These upstream texts come unchanged from its
official rust-src archive and checksum-verified crates pinned in library/Cargo.lock.
The corresponding-source collector includes all 40 registry crates in that lockfile.

The media link probe contains std, core, alloc, panic_unwind, compiler_builtins,
object, addr2line, gimli and rustc-demangle objects. The object named gstaws contains
Rust allocation shims in this probe, not AWS service functions. The helper notices
here also include the standard library's compression and platform dependencies.
The complete Rust source archive retains its internal file-specific notices.

This record describes the app-registration link probe. The final app link must
still be checked before distribution. Archive member prefixes alone do not prove
that a plugin's service code or its entire Cargo graph is linked.
