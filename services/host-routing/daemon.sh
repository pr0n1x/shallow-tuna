#!/bin/sh
set -e

# No routes configured — nothing to attach/detach. Exit cleanly; the
# service uses 'restart: on-failure', so exit 0 stops it for good.
if [ -z "${EXIT_ROUTES:-}" ]; then
    echo "host-routing: EXIT_ROUTES is empty — no SNAT rules to manage, exiting"
    exit 0
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
