#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="${SSH_HOST:-your-ssh-tuna-host}"
REMOTE_DIR="${REMOTE_DIR:-shallow-tuna}"

usage() {
    local base_name
    base_name="$(basename "$0")"
    cat <<EOF
Usage: $base_name [output-file] [ssh-host]

Run the backup service on the server and download the archive over the
SSH pipe. A copy also stays on the server in ${REMOTE_DIR}/workdir/backups/,
chowned to BACKUP_USER_ID:BACKUP_GROUP_ID from the server's .env.

Defaults:
  output-file   ./wg-data-<timestamp>.tar.gz
  ssh-host      $SSH_HOST   (or set SSH_HOST env)
  remote dir    $REMOTE_DIR (set REMOTE_DIR env to override)

Examples:
  $base_name
  $base_name ~/backups/wg.tar.gz
  $base_name ~/backups/wg.tar.gz your-other-tuna-host
EOF
    exit 0
}

case "${1:-}" in
    -h|--help) usage ;;
esac

OUT="${1:-wg-data-$(date +%Y%m%d-%H%M%S).tar.gz}"
if [[ -n "${2:-}" ]]; then
    SSH_HOST="$2"
fi

echo "Backing up $SSH_HOST:$REMOTE_DIR -> $OUT"
ssh "$SSH_HOST" \
    "cd '$REMOTE_DIR' && docker compose run --rm -T --quiet-pull backup --stdout" \
    > "$OUT"

# the stream is the whole deliverable — make sure it arrived intact
gzip -t "$OUT"
echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Contents:"
tar -tzf "$OUT" | head -20