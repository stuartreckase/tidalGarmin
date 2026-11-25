#!/bin/bash
# Build the watch app.
#   ./build.sh [-r] [device]  one device (default fenix8solar47mm) -> bin/tidal.prg
#                             (-r: also run it in the running simulator)
#   ./build.sh -a             every manifest device with a downloaded pack
#                             -> bin/prg/tidal-<device>.prg
#   ./build.sh -e             release package for all manifest devices -> bin/tidal.iq
#                             (needs every device pack; SDK Manager > Devices)
SDKM="${SDKM:-$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.3.0-2026-10-20-95888f262}"
KEY="${KEY:-$HOME/Library/Application Support/Garmin/ConnectIQ/developer_key.der}"
DEVICES="$HOME/Library/Application Support/Garmin/ConnectIQ/Devices"
cd "$(dirname "$0")"

quiet() { grep -v "container access\|container assignment\|Invalid device id"; }

if [ "$1" == "-e" ]; then
    "$SDKM/bin/monkeyc" -e -f monkey.jungle -o bin/tidal.iq -y "$KEY" -r -w 2>&1 | quiet
    [ ${PIPESTATUS[0]} -ne 0 ] && { echo "EXPORT FAILED"; exit 1; }
    echo "-> bin/tidal.iq"; exit 0
fi

if [ "$1" == "-a" ]; then
    mkdir -p bin/prg
    ok=0; failed=""; missing=0
    for d in $(sed -n 's/.*<iq:product id="\([^"]*\)".*/\1/p' manifest.xml); do
        if [ ! -f "$DEVICES/$d/compiler.json" ]; then missing=$((missing + 1)); continue; fi
        if "$SDKM/bin/monkeyc" -d "$d" -f monkey.jungle -o "bin/prg/tidal-$d.prg" -y "$KEY" -O 2 -r >/dev/null 2>&1; then
            ok=$((ok + 1))
        else
            failed="$failed $d"
        fi
    done
    echo "built $ok; failed:${failed:- none}; packs not downloaded: $missing"
    [ -z "$failed" ]; exit $?
fi

RUN=0
[ "$1" == "-r" ] && { RUN=1; shift; }
DEV="${1:-fenix8solar47mm}"

"$SDKM/bin/monkeyc" -d "$DEV" -f monkey.jungle -o bin/tidal.prg -y "$KEY" -w -O 2 2>&1 | quiet
[ ${PIPESTATUS[0]} -ne 0 ] && { echo BUILD FAILED; exit 1; }

if [ $RUN -eq 1 ]; then
    # simulator must be running: "$SDKM/bin/ConnectIQ.app/Contents/MacOS/simulator"
    "$SDKM/bin/monkeydo" bin/tidal.prg "$DEV"
fi
