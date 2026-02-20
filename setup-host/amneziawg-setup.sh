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
  install     Install AmneziaWG kernel module and tools
  uninstall   Remove AmneziaWG and its PPA

Examples:
  sudo $base_name install
  sudo $base_name uninstall
EOF
    exit 0
}

do_install() {
    echo "── Installing prerequisites ──"
    apt-get update
    apt-get install -y software-properties-common

    echo ""
    echo "── Adding AmneziaWG PPA ──"
    add-apt-repository -y ppa:amnezia/ppa
    apt-get update

    echo ""
    echo "── Installing AmneziaWG ──"
    apt-get install -y amneziawg amneziawg-tools

    echo ""
    echo "── Loading kernel modules ──"
    modprobe amneziawg
    modprobe ip6table_nat
    modprobe ip6_tables

    echo ""
    echo "── Persisting modules across reboots ──"
    for mod in amneziawg ip6table_nat ip6_tables; do
        grep -qxF "$mod" /etc/modules-load.d/amneziawg.conf 2>/dev/null || echo "$mod" >> /etc/modules-load.d/amneziawg.conf
    done

    echo ""
    echo "── Verifying ──"
    lsmod | grep -E 'amneziawg|ip6table_nat|ip6_tables'

    echo ""
    echo "Done. AmneziaWG is installed and loaded."
}

do_uninstall() {
    echo "This will remove AmneziaWG kernel module, tools, and the PPA."
    read -rp "Continue? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "── Unloading kernel module ──"
    modprobe -r amneziawg 2>/dev/null || true

    echo ""
    echo "── Removing AmneziaWG packages ──"
    apt-get purge -y amneziawg amneziawg-dkms amneziawg-tools 2>/dev/null || true
    apt-get autoremove -y

    echo ""
    echo "── Removing PPA ──"
    add-apt-repository -y --remove ppa:amnezia/ppa

    echo ""
    echo "Done. AmneziaWG has been removed."
}

case "${1:-}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *)         usage ;;
esac