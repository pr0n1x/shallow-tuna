#!/bin/sh
set -e

# No routes configured — nothing to attach/detach. Idle instead of exiting:
# under 'restart: unless-stopped' any exit (even 0) becomes a restart loop.
if [ -z "${EXIT_ROUTES:-}" ]; then
    echo "host-routing: EXIT_ROUTES is empty — no SNAT rules to manage, idling"
    while true; do sleep 86400 & wait $!; done
fi

cleanup() {
    echo "host-routing: detaching rules..."
    sh /app/manage.sh detach
    exit 0
}
trap cleanup TERM INT

sh /app/manage.sh attach
echo "host-routing: running, will detach on stop"

while true; do sleep 86400 & wait $!; done
