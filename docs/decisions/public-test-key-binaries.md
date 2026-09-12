# Public test keys in bundled libraries

The package privacy check permits only the exact binary hashes listed in
`ci/public-key-fixture-binaries.json`. Any changed byte requires a new review.
Signing-material and device-ID checks still run.

libmbedcrypto and libssh contain only NUL-terminated PEM parser markers.
All 11 GnuTLS key blocks match `gnutls-3.8.9/lib/crypto-selftests-pk.c`
in the supplied source, after joining C literals and expanding newline escapes.
These are public self-test inputs, not user credentials.
The source archive `gnutls28_3.8.9.orig.tar.xz` has SHA-256:
69e113d802d1670c4d5ac1b99040b1f2d5c7c05daec5003813c049b5184820ed

A general binary exemption was rejected because it could hide new credentials.
Removing the listed hashes restores the former rejection behavior. This does
not clear the source, license, or relinking release gates.
