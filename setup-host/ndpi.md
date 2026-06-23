# Block BitTorrent through the VPN (nDPI / xt_ndpi)

Drops BitTorrent traffic transiting the VPN using **nDPI deep packet
inspection**. Detection is flow-based, so it catches **encrypted (MSE/PE)**
torrents and DHT/uTP — not just plaintext handshakes or well-known ports.

> **Target:** Ubuntu 24.04. `xt_ndpi` is an out-of-tree kernel module shipped
> as DKMS packages (see [`../ndpi`](../ndpi)); DKMS builds it against the
> running kernel and rebuilds it **automatically** on kernel upgrades.

## How it works

```
VPN client ──▶ wg0 (inside container) ──▶ MASQUERADE (inside container)
          ──▶ docker bridge ──▶ host FORWARD ──▶ uplink
                                      ▲
                          DOCKER-USER chain: -m ndpi --proto bittorrent -j DROP
```

- `xt_ndpi.ko` (from `xt-ndpi-dkms`) + `libxt_ndpi.so` (from `xt-ndpi-iptables`)
  are installed on the **host**. The module is global to the host kernel; the
  iptables extension cannot run inside the Alpine/musl VPN containers, so the
  rule is enforced on the host.
- VPN client traffic is MASQUERADEd inside the container and then forwarded by
  the host, so it passes through the host `FORWARD` chain. The rule is placed in
  Docker's **`DOCKER-USER`** chain — the supported hook for user rules there,
  and one Docker does not flush on container restart.
- A `ndpi-filter.service` systemd unit (`PartOf=docker.service`) re-applies
  the rule every time Docker (re)starts, since dockerd recreates `DOCKER-USER`.

## Install

First build the `.deb` packages with Docker Compose (no root needed), then
install them:

```bash
./setup-host/ndpi-setup.sh build      # -> ../ndpi/artifacts/*.deb
sudo ./setup-host/ndpi-setup.sh install
```

`install` apt-installs `xt-ndpi-dkms` + `xt-ndpi-iptables` + `xt-ndpi-filter`
(DKMS builds `xt_ndpi` against the running kernel; the packages provide the
`-m ndpi` match and the `ndpi-filter` rule engine + `xt_ndpi` autoload). It
then writes the rule config to `/etc/default/ndpi-filter` and enables
`ndpi-filter.service`.

The nDPI revision is pinned in [`../ndpi/NDPI_REF`](../ndpi/NDPI_REF); override
per-build with `NDPI_REF=<tag|commit> ./setup-host/ndpi-setup.sh build`.

## Maintenance — kernel upgrades

Nothing to do. DKMS rebuilds `xt_ndpi` for the new kernel automatically on
upgrade (via `/etc/kernel/postinst.d/dkms`), so blocking keeps working across
reboots without intervention.

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
client traffic). The rule engine (`xt-ndpi-filter`) is generic — edit the
`NDPI_RULES` / `NDPI_CHAIN` config in `/etc/default/ndpi-filter` (and re-run
`sudo systemctl restart ndpi-filter`) to scope it or block other protocols,
e.g. limit to a subnet:

```bash
NDPI_CHAIN="DOCKER-USER"
NDPI_RULES=(
  "-s 172.100.0.0/24 -m ndpi --proto bittorrent -j DROP"
)
```

The canonical config is written by `ndpi-setup.sh`'s `write_config()`.

## Remove

```bash
sudo ./setup-host/ndpi-setup.sh uninstall
```

Disables the service, removes the rule, unloads the module, and purges the
`xt-ndpi-dkms` / `xt-ndpi-iptables` packages.

## Commands

| Command     | Action                                                        |
|-------------|---------------------------------------------------------------|
| `build`     | Build the `.deb` packages with Docker Compose (no root)       |
| `install`   | Install the packages and enable BitTorrent blocking           |
| `status`    | Show package / module / iptables extension / rule state       |
| `uninstall` | Remove blocking and purge the packages                        |