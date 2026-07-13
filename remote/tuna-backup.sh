#!/usr/bin/env bash
set -euo pipefail

# deliberately do NOT resolve symlinks: when the script is invoked via a
# symlink from another dir, the env file is looked up next to the SYMLINK —
# so each project dir can hold its own tuna-adm.env beside its links
# (one env file shared with tuna-adm.sh — same TUNA_ADM_* namespace)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${TUNA_ADM_ENV:-${SCRIPT_DIR}/tuna-adm.env}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

SSH_HOST="${TUNA_ADM_SSH_HOST:-your-ssh-tuna-host}"
REMOTE_DIR="${TUNA_ADM_REMOTE_DIR:-shallow-tuna}"
BACKUP_DIR="${TUNA_ADM_BACKUP_DIR:-backups}"

usage() {
    local base_name
    base_name="$(basename "$0")"
    cat <<EOF
Usage: $base_name [output-dir]

Run the backup service on the server and download the archive over the
SSH pipe into <output-dir>/wg-data-<timestamp>.tar.gz. The archive is
streamed only — nothing is stored on the server.

Defaults:
  output-dir    $BACKUP_DIR (TUNA_ADM_BACKUP_DIR)
  ssh-host      $SSH_HOST   (TUNA_ADM_SSH_HOST)
  remote dir    $REMOTE_DIR (TUNA_ADM_REMOTE_DIR)

The output-dir argument is resolved against the caller's CWD; the
TUNA_ADM_BACKUP_DIR / built-in default, when relative, is resolved
against the env file dir. Remote dir is relative to the SSH user's
home on the server.

All can be set in $ENV_FILE, shared with tuna-adm.sh (override its path
with TUNA_ADM_ENV).

Examples:
  $base_name
  $base_name ~/backups
EOF
    exit 0
}

case "${1:-}" in
    -h|--help) usage ;;
esac

if [[ -n "${1:-}" ]]; then
    BACKUP_DIR="$1"                        # argument: relative to the caller's CWD
elif [[ "$BACKUP_DIR" != /* ]]; then
    BACKUP_DIR="$SCRIPT_DIR/$BACKUP_DIR"   # env/default: relative to the env file dir
fi

mkdir -p "$BACKUP_DIR"
OUT="$BACKUP_DIR/wg-data-$(date +%Y%m%d-%H%M%S).tar.gz"

echo "Backing up $SSH_HOST:$REMOTE_DIR -> $OUT"
# the stream is the whole deliverable — verify it arrived intact, and don't
# leave a broken timestamped file behind on failure
if ! ssh "$SSH_HOST" \
        "cd '$REMOTE_DIR' && docker compose run --rm -T --quiet-pull backup --stdout" \
        > "$OUT" || ! gzip -t "$OUT"; then
    rm -f "$OUT"
    echo "Backup failed — removed incomplete $OUT" >&2
    exit 1
fi
echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Contents:"
tar -tzf "$OUT" | head -20