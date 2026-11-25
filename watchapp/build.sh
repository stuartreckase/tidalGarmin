#!/bin/bash
# Build + run in simulator. Usage: ./build.sh [-r] (with -r, push to simulator)
SDKM="$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.3.0-2026-10-20-95888f262"
KEY="$HOME/Library/Application Support/Garmin/ConnectIQ/developer_key.der"
cd "$(dirname "$0")"

"$SDKM/bin/monkeyc" -d fenix8solar47mm -f monkey.jungle -o bin/tidal.prg \
    -y "$KEY" -w -O 2 | grep -v "launcher icon"
[ ${PIPESTATUS[0]} -ne 0 ] && { echo BUILD FAILED; exit 1; }

if [ "$1" == "-r" ]; then
    # simulator must be running: "$SDKM/bin/connectiq" opens it
    "$SDKM/bin/monkeydo" bin/tidal.prg fenix8solar47mm
fi
