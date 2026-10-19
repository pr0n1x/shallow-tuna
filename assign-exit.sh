#!/bin/bash
set -euo pipefail

# Manage per-client exit IP routing for VPN containers.
# Assignments persist across container restarts.
#
# Usage:
#   ./assign-exit.sh [container] add <client-ip> <network>
#   ./assign-exit.sh [container] remove <client-ip>
#   ./assign-exit.sh [container] list
#
# Container defaults to the single running VPN container (awg-easy or wg-easy).
# Network names are resolved via Docker, table IDs from EXIT_ROUTES order.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ROUTES_FILE="/etc/wireguard/exit-routes"

case "${1:-}" in
    add|remove|rm|del|list|ls) set -- "" "$@" ;;
esac
CONTAINER="${1:-}"
ACTION="${2:-}"

# Compose project that owns the exit networks (Docker names them
# <project>_<network>). Unless COMPOSE_PROJECT is set explicitly, take it from
# the container's compose label, else fall back to the directory name — which
# is Compose's own default project name.
if [ -z "${COMPOSE_PROJECT:-}" ] && [ -n "$CONTAINER" ]; then
    COMPOSE_PROJECT=$(docker inspect "$CONTAINER" \
        --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)
fi
COMPOSE_PROJECT="${COMPOSE_PROJECT:-$(basename "$SCRIPT_DIR")}"

# Load EXIT_ROUTES from .env
if [ -f "$ENV_FILE" ]; then
    EXIT_ROUTES=$(grep -E '^EXIT_ROUTES=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)
fi

if [ -z "${EXIT_ROUTES:-}" ]; then
    echo "ERROR: EXIT_ROUTES not set in $ENV_FILE" >&2
    exit 1
fi

# Build gateway → table_id and gateway → external_ip mappings
declare -A GATEWAY_TO_TABLE
declare -A GATEWAY_TO_EXTERNAL
table_id=100
IFS=','
for route in $EXIT_ROUTES; do
    gateway="${route%%:*}"
    external_ip="${route##*:}"
    GATEWAY_TO_TABLE["$gateway"]=$table_id
    GATEWAY_TO_EXTERNAL["$gateway"]=$external_ip
    table_id=$((table_id + 1))
done
unset IFS

# Build network_name → gateway mapping from Docker
declare -A NETWORK_TO_GATEWAY
for net in $(docker network ls --format '{{.Name}}' | grep "^${COMPOSE_PROJECT}_"); do
    gw=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
    if [ -z "$gw" ]; then
        subnet=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
        [ -n "$subnet" ] && gw="${subnet%.*}.1"
    fi
    [ -n "$gw" ] && NETWORK_TO_GATEWAY["${net#${COMPOSE_PROJECT}_}"]="$gw"
done

# List available networks with their table IDs
list_networks() {
    for network in "${!NETWORK_TO_GATEWAY[@]}"; do
        gateway="${NETWORK_TO_GATEWAY[$network]}"
        table_id="${GATEWAY_TO_TABLE[$gateway]:-}"
        [ -n "$table_id" ] || continue
        echo "  $network: table $table_id → ${GATEWAY_TO_EXTERNAL[$gateway]}"
    done | sort
}

usage() {
    echo "Usage: $0 [container] <command> [args]"
    echo
    echo "Commands:"
    echo "  [container] add <client-ip> <network>   Route client via exit network"
    echo "  [container] remove <client-ip>          Remove client exit routing"
    echo "  [container] list                        Show current assignments"
    echo
    echo "Container defaults to the running VPN container (awg-easy or wg-easy);"
    echo "it must be given when both are running."
    echo
    echo "Available networks:"
    list_networks
    echo
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 add 10.8.0.2 exit1"
    echo "  $0 remove 10.8.0.2"
    echo "  $0 wg-easy add 10.8.0.3 exit2"
    exit 1
}

[ -z "$ACTION" ] && usage

if [ -z "$CONTAINER" ]; then
    mapfile -t vpn_containers < <(docker ps \
        --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
        --format '{{.Names}}' | grep -E '^a?wg-easy$' || true)
    case ${#vpn_containers[@]} in
        1) CONTAINER="${vpn_containers[0]}" ;;
        0) echo "ERROR: no VPN container (awg-easy/wg-easy) running in project '$COMPOSE_PROJECT'" >&2; exit 1 ;;
        *) echo "ERROR: several VPN containers running (${vpn_containers[*]}); specify one" >&2; exit 1 ;;
    esac
elif ! docker inspect --type container "$CONTAINER" >/dev/null 2>&1; then
    echo "ERROR: container '$CONTAINER' not found. Running containers in project '$COMPOSE_PROJECT':" >&2
    docker ps --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --format '{{"  "}}{{.Names}}' >&2
    exit 1
fi

case "$ACTION" in
    add)
        CLIENT_IP="${3:?Missing client IP}"
        NETWORK="${4:?Missing network name}"

        GATEWAY="${NETWORK_TO_GATEWAY[$NETWORK]:-}"
        [ -z "$GATEWAY" ] && { echo "ERROR: network '$NETWORK' not found" >&2; exit 1; }

        TABLE_ID="${GATEWAY_TO_TABLE[$GATEWAY]:-}"
        [ -z "$TABLE_ID" ] && { echo "ERROR: network '$NETWORK' not in EXIT_ROUTES" >&2; exit 1; }

        # Remove any existing rule for this client
        docker exec "$CONTAINER" sh -c '
            while ip rule del from "$1" 2>/dev/null; do :; done
        ' -- "$CLIENT_IP"

        # Add new routing rule
        docker exec "$CONTAINER" ip rule add from "$CLIENT_IP" lookup "$TABLE_ID"

        # Persist assignment (replace existing entry for this client)
        docker exec "$CONTAINER" sh -c '
            touch "$2"
            grep -v "^$1 " "$2" > "$2.tmp" 2>/dev/null || true
            echo "$1 $3" >> "$2.tmp"
            mv "$2.tmp" "$2"
        ' -- "$CLIENT_IP" "$ROUTES_FILE" "$TABLE_ID"

        echo "Assigned: $CLIENT_IP → $NETWORK (table $TABLE_ID)"
        ;;

    remove|rm|del)
        CLIENT_IP="${3:?Missing client IP}"

        # Remove all routing rules for this client
        docker exec "$CONTAINER" sh -c '
            while ip rule del from "$1" 2>/dev/null; do :; done
        ' -- "$CLIENT_IP"

        # Remove from persistent file
        docker exec "$CONTAINER" sh -c '
            [ -f "$2" ] || exit 0
            grep -v "^$1 " "$2" > "$2.tmp" 2>/dev/null || true
            mv "$2.tmp" "$2"
        ' -- "$CLIENT_IP" "$ROUTES_FILE"

        echo "Removed: $CLIENT_IP"
        ;;

    list|ls)
        echo "Available networks:"
        list_networks
        echo
        echo "Active routing rules in $CONTAINER:"
        docker exec "$CONTAINER" ip rule show \
            | grep -v -E 'lookup (local|main|default)' || echo "  (none)"
        echo
        echo "Persistent assignments in $CONTAINER ($ROUTES_FILE):"
        docker exec "$CONTAINER" cat "$ROUTES_FILE" 2>/dev/null || echo "  (none)"
        ;;

    *)
        usage
        ;;
esac