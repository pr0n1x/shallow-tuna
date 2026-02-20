#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root (sudo $0 install|uninstall)" >&2
    exit 1
fi

usage() {
    local base_name
    base_name="$(basename "$0")"
    cat <<EOF
Usage: $base_name <command>

Commands:
  install     Install WireGuard kernel module and tools
  uninstall   Remove WireGuard

Examples:
  sudo $base_name install
  sudo $base_name uninstall
EOF
    exit 0
}

do_install() {
    echo "── Installing WireGuard ──"
    apt-get update
    apt-get install -y wireguard wireguard-tools

    echo ""
    echo "── Loading kernel modules ──"
    modprobe wireguard
    modprobe ip6table_nat
    modprobe ip6_tables

    echo ""
    echo "── Persisting modules across reboots ──"
    for mod in wireguard ip6table_nat ip6_tables; do
        grep -qxF "$mod" /etc/modules-load.d/wireguard.conf 2>/dev/null || echo "$mod" >> /etc/modules-load.d/wireguard.conf
    done

    echo ""
    echo "── Verifying ──"
    lsmod | grep -E 'wireguard|ip6table_nat|ip6_tables'

    echo ""
    echo "Done. WireGuard is installed and loaded."
}

do_uninstall() {
    echo "This will remove WireGuard kernel module and tools."
    read -rp "Continue? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "── Unloading kernel module ──"
    modprobe -r wireguard 2>/dev/null || true

    echo ""
    echo "── Removing WireGuard packages ──"
    apt-get purge -y wireguard wireguard-tools wireguard-dkms 2>/dev/null || true
    apt-get autoremove -y

    echo ""
    echo "Done. WireGuard has been removed."
}

case "${1:-}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *)         usage ;;
esac