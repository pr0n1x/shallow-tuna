#!/bin/sh
set -e

# Lifecycle wrapper (mirrors host-routing): attach the nDPI DROP rules on start,
# detach them on stop. The rules live in the host's DOCKER-USER chain, so they
# must be removed when this service goes down.

cleanup() {
    echo "xt-ndpi-rules: detaching rules..."
    bash /app/manage.sh detach || true
    exit 0
}
trap cleanup TERM INT

bash /app/manage.sh attach
echo "xt-ndpi-rules: running, will detach on stop"

while true; do sleep 86400 & wait $!; done