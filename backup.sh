#!/usr/bin/env bash
set -euo pipefail

# Cron-friendly wrapper around the 'backup' compose service: creates an
# archive in workdir/backups and appends a timestamped record to
# workdir/backup.log. Keeps the crontab entry down to a bare script path
# (no shell quoting or '%' escaping pitfalls):
#   0 */3 * * * /home/<user>/shallow-tuna/backup.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/workdir/backup.log"

cd "$SCRIPT_DIR"
{
    echo ""
    echo "Backup at $(date -Iseconds)"
    docker compose run --rm --quiet-pull backup
} >> "$LOG_FILE" 2>&1
