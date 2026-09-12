#!/bin/sh
# Run the PE wineboot produced by an out-of-tree Wine build.
set -eu
exec "${WINE:?Missing Wine launcher}" "${WINEBOOT_PE:?Missing wineboot PE path}" "$@"
