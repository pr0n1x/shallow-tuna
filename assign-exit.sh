#!/bin/bash
set -euo pipefail

# Manage per-client exit IP routing for VPN containers.
# Assignments persist across container restarts.
#
# Usage:
#   ./assign-exit.sh <container> add <client-ip> <network>
#   ./assign-exit.sh <container> remove <client-ip>
#   ./assign-exit.sh <container> list
#
# Network names are resolved via Docker, table IDs from EXIT_ROUTES order.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ROUTES_FILE="/etc/wireguard/exit-routes"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-wg-easy}"

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
    [ -n "$gw" ] && NETWORK_TO_GATEWAY["${net#${COMPOSE_PROJECT}_}"]="$gw"
done

# List available networks with their table IDs
list_networks() {
    for network in "${!NETWORK_TO_GATEWAY[@]}"; do
        gateway="${NETWORK_TO_GATEWAY[$network]}"
        table_id="${GATEWAY_TO_TABLE[$gateway]:-}"
        external_ip="${GATEWAY_TO_EXTERNAL[$gateway]:-}"
        [ -n "$table_id" ] && echo "  $network: table $table_id → $external_ip"
    done | sort
}

usage() {
    echo "Usage: $0 <container> <add|remove|list> [client-ip] [network]"
    echo
    echo "Commands:"
    echo "  add <client-ip> <network>   Route client via exit network"
    echo "  remove <client-ip>          Remove client exit routing"
    echo "  list                        Show current assignments"
    echo
    echo "Available networks:"
    list_networks
    echo
    echo "Examples:"
    echo "  $0 wg-easy add 10.8.0.2 exit1"
    echo "  $0 wg-easy add 10.8.0.3 exit2"
    echo "  $0 wg-easy remove 10.8.0.2"
    echo "  $0 wg-easy list"
    exit 1
}

CONTAINER="${1:-}"
ACTION="${2:-}"
[ -z "$CONTAINER" ] || [ -z "$ACTION" ] && usage

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
        echo "Active routing rules:"
        docker exec "$CONTAINER" ip rule show \
            | grep -v -E 'lookup (local|main|default)' || echo "  (none)"
        echo
        echo "Persistent assignments ($ROUTES_FILE):"
        docker exec "$CONTAINER" cat "$ROUTES_FILE" 2>/dev/null || echo "  (none)"
        ;;

    *)
        usage
        ;;
esac