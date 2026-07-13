#!/bin/sh
# Archives ./workdir/awg and ./workdir/wg (mounted at /data) into /backups.
# The container runs as root, so /backups and the archive are chowned to
# BACKUP_USER_ID:BACKUP_GROUP_ID afterwards — numeric IDs, the container's
# /etc/passwd knows nothing about host users.
#
# Modes:
#   (no args)   create the archive in /backups, print its basename on stdout
#   --stdout    stream the archive to stdout ONLY — nothing is written to
#               /backups:  docker compose run --rm -T backup --stdout > f
set -eu

STDOUT_MODE=0
[ "${1:-}" = "--stdout" ] && STDOUT_MODE=1

DIRS=""
for d in awg wg; do
    [ -d "/data/$d" ] && DIRS="$DIRS $d"
done
if [ -z "$DIRS" ]; then
    echo "backup: nothing to back up — neither /data/awg nor /data/wg exists" >&2
    exit 1
fi

# word splitting of $DIRS is intentional
if [ "$STDOUT_MODE" = 0 ]; then
    ARCHIVE="/backups/wg-data-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$ARCHIVE" -C /data $DIRS

    # also chown /backups itself: docker creates it as root on first mount, and
    # without write access there the host user couldn't delete old archives
    if [ -n "${BACKUP_USER_ID:-}${BACKUP_GROUP_ID:-}" ]; then
        chown "${BACKUP_USER_ID:-0}:${BACKUP_GROUP_ID:-0}" /backups "$ARCHIVE"
    fi

    echo "backup: created $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1)) from:$DIRS" >&2
    basename "$ARCHIVE"
else
    echo "backup: streaming archive of$DIRS to stdout" >&2
    exec tar -czf - -C /data $DIRS
fi