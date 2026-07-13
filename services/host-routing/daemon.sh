#!/bin/sh
set -e

cleanup() {
    echo "host-routing: detaching rules..."
    sh /app/manage.sh detach
    exit 0
}
trap cleanup TERM INT

sh /app/manage.sh attach
echo "host-routing: running, will detach on stop"

while true; do sleep 86400 & wait $!; done
