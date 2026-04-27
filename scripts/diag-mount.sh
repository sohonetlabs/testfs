#!/bin/bash
# Run a mount attempt while streaming the fskit/testfs unified log.
# Everything — mount command output AND log stream — ends up in one
# file and on the terminal, so we can finally see what fskit_agent
# is actually doing during the 15s hang.
#
# Usage: scripts/diag-mount.sh [tree.json] [mountpoint]
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"

LOGFILE="/tmp/testfs-diag-$(date +%Y%m%d-%H%M%S).log"

echo "=== diag-mount ==="
echo "log file: $LOGFILE"
echo

# Start log stream in background. Predicate is deliberately wide so we
# catch fskit_agent, fskitd, mount(8), our extension's subsystem, and
# anything ExtensionKit says about launching/rejecting the .appex.
log stream \
    --level debug \
    --style compact \
    --predicate 'subsystem CONTAINS[c] "fskit" OR subsystem CONTAINS[c] "testfs" OR subsystem CONTAINS[c] "sohonet" OR subsystem CONTAINS[c] "extensionkit" OR process == "mount" OR process == "fskit_agent" OR process == "fskitd" OR process == "pluginkit"' \
    2>&1 | tee -a "$LOGFILE" &
LOGPID=$!
trap 'kill $LOGPID 2>/dev/null || true' EXIT INT TERM

# Give log stream a moment to start emitting.
sleep 1

{
    echo
    echo "--- mount attempt at $(date +%H:%M:%S) ---"
} | tee -a "$LOGFILE"

# Run the mount. Don't abort on failure — we want the log either way.
"$HERE/mount.sh" "$@" 2>&1 | tee -a "$LOGFILE"
MOUNT_RC=${PIPESTATUS[0]}

{
    echo
    echo "--- mount returned rc=$MOUNT_RC at $(date +%H:%M:%S) ---"
    echo "letting log drain for 5s ..."
} | tee -a "$LOGFILE"

sleep 5

{
    echo
    echo "--- done. log saved to $LOGFILE ---"
} | tee -a "$LOGFILE"
