#!/bin/bash

# awg-switch.sh - AmneziaWG VPN configuration switcher
# Usage: awg-switch.sh [config_name|list|status|down]

set -e

# Configuration directory (adjust if needed)
CONFIG_DIR="${AWG_CONFIG_DIR:-/etc/amnezia/amneziawg}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
    local base_name;
    base_name="$(basename "$0")"
    echo "Usage: $base_name [command|config_name]"
    echo ""
    echo "Commands:"
    echo "  list, ls, l    List available configurations"
    echo "  status, s      Show current connection status"
    echo "  down, d        Disconnect current VPN"
    echo "  help, h        Show this help message"
    echo ""
    echo "Examples:"
    echo "   list        # List all available configs"
    echo "  $base_name de          # Switch to de.conf"
    echo "  $base_name down        # Disconnect VPN"
    echo ""
    echo "Environment:"
    echo "  AWG_CONFIG_DIR  Config directory (default: /etc/amnezia/awg)"
}

get_active_interface() {
    ip link show type wireguard 2>/dev/null | grep -oP '^\d+: \K[^:]+' | head -1
}

list_configs() {
    echo -e "${BLUE}Available configurations in ${CONFIG_DIR}:${NC}"
    echo ""

    if [[ ! -d "$CONFIG_DIR" ]]; then
        echo -e "${RED}Config directory not found: ${CONFIG_DIR}${NC}"
        exit 1
    fi

    local active
    active=$(get_active_interface)

    local configs
    configs=$(sudo ls "$CONFIG_DIR"/*.conf 2>/dev/null) || {
        echo -e "${YELLOW}No .conf files found in ${CONFIG_DIR}${NC}"
        return
    }

    for conf in $configs; do
        local name
        name=$(basename "$conf" .conf)

        if [[ "$name" == "$active" ]]; then
            echo -e "  ${GREEN}* ${name}${NC} (active)"
        else
            echo "    ${name}"
        fi
    done
}

show_status() {
    local active
    active=$(get_active_interface)

    if [[ -z "$active" ]]; then
        echo -e "${YELLOW}No active AmneziaWG connection${NC}"
        return
    fi

    echo -e "${GREEN}Active interface: ${active}${NC}"
    echo ""
    sudo awg show "$active"
}

disconnect() {
    local active
    active=$(get_active_interface)

    if [[ -z "$active" ]]; then
        echo -e "${YELLOW}No active connection to disconnect${NC}"
        return
    fi

    echo -e "${BLUE}Disconnecting ${active}...${NC}"
    sudo awg-quick down "$active"
    echo -e "${GREEN}Disconnected${NC}"
}

switch_to() {
    local target="$1"
    local config_file="${CONFIG_DIR}/${target}.conf"

    if ! sudo test -f "$config_file"; then
        echo -e "${RED}Configuration not found: ${config_file}${NC}"
        echo ""
        list_configs
        exit 1
    fi

    local active
    active=$(get_active_interface)

    # Check if already connected to target
    if [[ "$active" == "$target" ]]; then
        echo -e "${GREEN}Already connected to ${target}${NC}"
        exit 0
    fi

    # Disconnect current if active
    if [[ -n "$active" ]]; then
        echo -e "${BLUE}Disconnecting ${active}...${NC}"
        sudo awg-quick down "$active"
    fi

    # Connect to new config
    echo -e "${BLUE}Connecting to ${target}...${NC}"
    sudo awg-quick up "$target"
    echo -e "${GREEN}Connected to ${target}${NC}"
}

# Main
case "${1:-}" in
    ""|help|h|-h|--help)
        print_usage
        ;;
    list|ls|l)
        list_configs
        ;;
    status|s)
        show_status
        ;;
    down|d)
        disconnect
        ;;
    *)
        switch_to "$1"
        ;;
esac
