# Block BitTorrent through the VPN (nDPI / xt_ndpi)

Drops BitTorrent traffic transiting the VPN using **nDPI deep packet
inspection**. Detection is flow-based, so it catches **encrypted (MSE/PE)**
torrents and DHT/uTP — not just plaintext handshakes or well-known ports.

> **Target:** Ubuntu 24.04 (kernel 6.8.x) only. `xt_ndpi` is an out-of-tree
> kernel module built from source against the running kernel.

## How it works

```
VPN client ──▶ wg0 (inside container) ──▶ MASQUERADE (inside container)
          ──▶ docker bridge ──▶ host FORWARD ──▶ uplink
                                      ▲
                          DOCKER-USER chain: -m ndpi --proto bittorrent -j DROP
```

- `xt_ndpi.ko` (kernel module) + `libxt_ndpi.so` (iptables extension) are built
  and installed on the **host**. The module is global to the host kernel; the
  iptables extension cannot run inside the Alpine/musl VPN containers, so the
  rule is enforced on the host.
- VPN client traffic is MASQUERADEd inside the container and then forwarded by
  the host, so it passes through the host `FORWARD` chain. The rule is placed in
  Docker's **`DOCKER-USER`** chain — the supported hook for user rules there,
  and one Docker does not flush on container restart.
- A `ndpi-filter.service` systemd unit (`PartOf=docker.service`) re-applies
  the rule every time Docker (re)starts, since dockerd recreates `DOCKER-USER`.

## Install

```bash
sudo ./setup-host/ndpi-setup.sh install
```

This builds nDPI, installs the module + iptables extension, loads `xt_ndpi`,
persists it via `/etc/modules-load.d/xt_ndpi.conf`, and enables the rule.

Pin a specific nDPI revision for reproducible builds:

```bash
sudo NDPI_REF=4.12 ./setup-host/ndpi-setup.sh install
```

## Maintenance — after a kernel upgrade

The module is compiled against the running kernel. After a kernel upgrade
(including 6.8 point releases) **rebuild and reload it**:

```bash
sudo ./setup-host/ndpi-setup.sh rebuild
```

Until rebuilt, `modprobe xt_ndpi` will fail on the new kernel and blocking will
be **off**. If you want this automated, convert the build to DKMS — not done
here to avoid shipping an untested DKMS config.

## Verify it's working

```bash
sudo ./setup-host/ndpi-setup.sh status

# rule counters should climb while a test torrent is running:
sudo iptables -n -L DOCKER-USER -v --line-numbers | grep ndpi
```

Functional test: connect a client to the VPN, start a well-seeded torrent
(e.g. a Linux ISO), confirm peers fail to connect / transfer stalls. Note that
nDPI classifies a flow after its first few packets, so the *very* first packets
of each connection pass before the flow is tagged and dropped — the connection
still dies, it's just not a packet-1 block.

## Scope (optional)

By default **all** forwarded BitTorrent is dropped (every flow on a VPN exit is
client traffic). To limit it to specific exit networks, edit `MATCH` in
`/usr/local/sbin/ndpi-filter` to add a source subnet, e.g.:

```bash
MATCH=(-s 172.100.0.0/24 -m ndpi --proto bittorrent -j DROP)
```

## Remove

```bash
sudo ./setup-host/ndpi-setup.sh uninstall
```

Disables the service, removes the rule, unloads and uninstalls the module.

## Commands

| Command     | Action                                                        |
|-------------|---------------------------------------------------------------|
| `install`   | Build + install xt_ndpi and enable blocking                   |
| `rebuild`   | Rebuild module against current kernel, reload, re-apply rule   |
| `status`    | Show module / iptables extension / rule state                 |
| `uninstall` | Remove blocking and the module                                |