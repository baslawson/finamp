#!/bin/sh
# Runs the service as PUID:PGID when they're set, after giving that user the data folder. Without them it runs as
# root, as before, so existing installs keep reading music and Jellyfin backups whatever their owner.
set -e
if [ "$(id -u)" = "0" ] && [ -n "$PUID" ]; then
    PGID="${PGID:-$PUID}"
    mkdir -p "${DATA_DIR:-/data}"
    # Only what isn't already theirs, so a large karaoke cache isn't walked on every start.
    find "${DATA_DIR:-/data}" \( ! -user "$PUID" -o ! -group "$PGID" \) -exec chown -h "$PUID:$PGID" {} +
    # Root's home isn't writable for that user; librosa's compiled-code cache needs somewhere to go.
    export HOME=/tmp NUMBA_CACHE_DIR=/tmp/numba-cache
    exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups "$@"
fi
exec "$@"
