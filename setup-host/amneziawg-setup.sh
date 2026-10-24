#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root (sudo $0 install|fix-dkms|status|uninstall)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Compat fix for amneziawg-dkms on kernels that backported the 7.1.5
# udp_tunnel API change (Ubuntu 7.0.0-38+). See the patch header.
COMPAT_PATCH="$SCRIPT_DIR/patches/amneziawg-dkms-udp-tunnel-compat.patch"

usage() {
    local base_name
    base_name="$(basename "$0")"
    cat <<USAGE
Usage: $base_name <command>

Commands:
  install     Install AmneziaWG kernel module and tools
  fix-dkms    Patch the amneziawg DKMS sources for newer kernels and rebuild
  status      Show package / DKMS / module state
  uninstall   Remove AmneziaWG and its PPA

Examples:
  sudo $base_name install
  sudo $base_name fix-dkms     # after a kernel or amneziawg-dkms update broke the build
  sudo $base_name uninstall
USAGE
    exit 0
}

# Apply the compat patch to every amneziawg DKMS source tree that still has the
# unpatched version-gated udp_tunnel wrappers. Idempotent: trees that are
# already patched, or that upstream has since fixed, are left alone.
# Sets PATCHED=1 if any tree was changed.
patch_dkms_sources() {
    PATCHED=0
    local src hdr
    shopt -s nullglob
    for src in /usr/src/amneziawg-*; do
        hdr="$src/compat/compat.h"
        [[ -f "$hdr" ]] || continue
        if grep -q '__compat_setup_udp_tunnel_sock' "$hdr"; then
            echo "  $src: already patched"
            continue
        fi
        if ! grep -qF 'setup_udp_tunnel_sock(net, sk->sk_socket, sock_cfg)' "$hdr"; then
            echo "  $src: no version-gated udp_tunnel wrapper, nothing to patch"
            continue
        fi
        if ! patch -p2 -N -s --dry-run -d "$src" < "$COMPAT_PATCH"; then
            echo "ERROR: $COMPAT_PATCH does not apply to $hdr" >&2
            echo "       Upstream changed the compat layer; update or drop the patch." >&2
            return 1
        fi
        # -b keeps the PPA original next to it as compat.h.orig
        patch -p2 -N -b -d "$src" < "$COMPAT_PATCH"
        echo "  $src: patched"
        PATCHED=1
    done
    shopt -u nullglob
}

# Build the DKMS module for every installed kernel that has headers. The
# package postinst does this itself, but when it failed on an unpatched tree
# we have to finish its job: first let dpkg re-run the postinst (which
# rebuilds everything), then fill in any kernel it still missed.
rebuild_dkms() {
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a

    local src ver build krel dkms_out
    shopt -s nullglob
    for src in /usr/src/amneziawg-*; do
        ver="${src##*/amneziawg-}"
        for build in /lib/modules/*/build; do
            [[ -d "$build" ]] || continue   # dangling link: headers removed
            krel="$(basename "$(dirname "$build")")"
            dkms_out="$(dkms status "amneziawg/$ver" -k "$krel" 2>/dev/null)" || true
            grep -q ': installed' <<<"$dkms_out" && continue
            echo "  building amneziawg/$ver for $krel"
            dkms install "amneziawg/$ver" -k "$krel"
        done
    done
    shopt -u nullglob
}

fix_dkms() {
    echo "── Patching amneziawg DKMS sources ──"
    patch_dkms_sources
    echo ""
    echo "── Rebuilding amneziawg for installed kernels ──"
    rebuild_dkms
    echo ""
    echo "── DKMS status ──"
    dkms status amneziawg
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
    # The PPA's amneziawg-dkms postinst builds the module for every kernel with
    # headers and fails the whole install when one of them doesn't compile
    # (Ubuntu 7.0.0-38+). Don't abort here: fix-dkms below patches the sources
    # and finishes the configure; if that can't help either, it fails itself.
    if ! apt-get install -y amneziawg amneziawg-tools; then
        echo ""
        echo "apt-get failed (DKMS build error above?) — applying the compat fix"
    fi

    echo ""
    fix_dkms

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

do_fix_dkms() {
    fix_dkms
    echo ""
    if [[ "$PATCHED" == 1 ]]; then
        echo "Done. Sources patched and module rebuilt."
    else
        echo "Done. Nothing needed patching."
    fi
    echo "(The patch is re-applied by 'fix-dkms'; an amneziawg-dkms package"
    echo " update replaces the sources, so re-run it if that update fails to build.)"
}

do_status() {
    echo "── Packages ──"
    dpkg-query -W -f='  ${Package} ${Version} (${db:Status-Status})\n' \
        amneziawg amneziawg-dkms amneziawg-tools 2>/dev/null || echo "  not installed"
    echo ""
    echo "── DKMS ──"
    dkms status amneziawg 2>/dev/null || echo "  (none)"
    echo ""
    echo "── Compat patch ──"
    local src
    shopt -s nullglob
    for src in /usr/src/amneziawg-*; do
        if grep -q '__compat_setup_udp_tunnel_sock' "$src/compat/compat.h" 2>/dev/null; then
            echo "  $src: patched"
        else
            echo "  $src: unpatched"
        fi
    done
    shopt -u nullglob
    echo ""
    echo "── Module ──"
    lsmod | grep -E '^(amneziawg|ip6table_nat|ip6_tables) ' || echo "  amneziawg not loaded"
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
    fix-dkms)  do_fix_dkms ;;
    status)    do_status ;;
    uninstall) do_uninstall ;;
    *)         usage ;;
esac
