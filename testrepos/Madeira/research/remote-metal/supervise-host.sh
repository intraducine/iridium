#!/bin/sh
# Keep rmetald running. A daemon that dies mid-session silently costs a device
# run: the guest reports "cannot reach" and falls back to local, which looks
# exactly like a successful local render. Restart it and record why it exited.
cd "$(dirname "$0")"
BIND="${1:-10.0.1.53}"
: "${RMETAL_TOKEN:?set RMETAL_TOKEN}"

# BUILD FIRST. This script only ran the existing binary, so editing rmetald.m
# and restarting the supervisor kept serving the OLD code -- twice in a row,
# while the source said otherwise. Building here means "restart" can never
# again mean "restart the stale one".
echo "  building rmetald (protocol v$(sed -n 's/^#define RM_VERSION \([0-9]*\)u.*/\1/p' protocol.h))"
rm -f host/rmetald
clang -O1 -w -fobjc-arc -fdeclspec -framework Foundation -framework Metal \
      -framework QuartzCore -framework AppKit -o host/rmetald host/rmetald.m || exit 1

while :; do
    host/rmetald "$BIND" >>/tmp/rmetald.log 2>&1
    rc=$?
    echo "[supervisor] rmetald exited rc=$rc -- restarting" >>/tmp/rmetald.log
    i=0
    while [ $i -lt 100 ]; do
        lsof -nP -iTCP:47821 -sTCP:LISTEN >/dev/null 2>&1 || break
        i=$((i+1))
    done
done
