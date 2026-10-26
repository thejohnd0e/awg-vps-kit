# AWG VPS Kit
[![CI](https://github.com/thejohnd0e/awg-vps-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/thejohnd0e/awg-vps-kit/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![Last commit](https://img.shields.io/github/last-commit/thejohnd0e/awg-vps-kit)](https://github.com/thejohnd0e/awg-vps-kit/commits/master) ![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white) ![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-A81D33?logo=debian&logoColor=white) ![Protocol](https://img.shields.io/badge/protocol-AmneziaWG%20(UDP)-blue)

AmneziaWG (userspace `amneziawg-go`) on UDP 443 and the `awg-client` command to manage
clients. UDP-based, so it works where the ISP throttles TCP from foreign VPS hosters
(see "When to use it").

## Related Projects

These projects complement each other: the kits set up the servers, and the proxy containers bring a
tunnel into your local network as a plain HTTP/SOCKS5 proxy.

- [xray-vps-kit](https://github.com/thejohnd0e/xray-vps-kit): installer, client manager and updater for an
  **Xray VLESS + REALITY + Vision** server over TCP. AWG covers UDP, Xray covers TCP: use whichever your
  network lets through, or run both on one server (see "Companion: xray-vps-kit").
- [AmneziaWG-to-Proxy](https://github.com/thejohnd0e/AmneziaWG-to-Proxy): a Docker container that turns the
  client config printed by `awg-client show NAME` into an HTTP/SOCKS5 proxy with automatic config failover.
- [VLESS-to-HTTP](https://github.com/thejohnd0e/VLESS-to-HTTP): the same idea for **VLESS + REALITY**, a
  container that turns a `vless://` link into an HTTP/SOCKS5 proxy.

## Requirements

Minimum VPS instance:

| | Minimum | Notes |
|---|---|---|
| OS | **Debian 12 or 13 (recommended)**, Ubuntu 22.04+ | CI tests Debian 12 and Ubuntu 24.04; other distros are not supported (`apt` is required) |
| CPU | 1 vCPU | userspace `amneziawg-go` tops out around 200 Mbit/s on 1 vCPU |
| RAM | 1 GB | enough for the build (low-memory settings); RAM use of the running service: not measured |
| Network | public IPv4, UDP port open | default UDP 443; open it in the provider's firewall too |
| Access | root | |
| Virtualization | KVM/Xen/VMware with `/dev/net/tun` | OpenVZ/LXC containers often lack the TUN device and will not work unless the provider enables it |
| CPU architecture | x86_64 or aarch64 | other architectures: TBD |

**Why Debian:** a lean default install (few preinstalled services, which leaves more of 1 GB RAM for the build), a stable release with long security support, and it is the primary target of `install.sh` (listed first and tested in CI). Ubuntu works equally well as far as the CI test shows; there is no benchmark comparing them.

Disk space and traffic needs are not measured: TBD.

## Install on a new server

See "Requirements" above. The binaries are built
from the official sources (`amnezia-vpn/amneziawg-go`, `amnezia-vpn/amneziawg-tools`),
which takes a few minutes and works on 1 GB of RAM. Run it on the server as root, from any folder:

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/install.sh | bash -s -- --subnet 10.79.0 --first-client user_01
```

The script installs `git` if needed, puts the kit in `/opt/awg-vps-kit` (updating it if it is
already there) and continues from that copy with the options you passed. If `curl` is missing,
run `apt-get update && apt-get install -y curl` first.

**Update** (checks the latest versions and updates only if something is newer):

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/update.sh | bash
```

**Uninstall** (asks for confirmation; details in "Uninstall"):

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/uninstall.sh | bash
```

`install.sh` options (all optional):

| Option | Default | Meaning |
|---|---|---|
| `--subnet 10.79.0` | `10.77.0` | tunnel /24 prefix, the server gets `.1`. **Use a different one per server** (e.g. `10.77.0`, `10.78.0`). |
| `--port 443` | `443` | UDP listen port |
| `--endpoint IP/HOST` | auto (api.ipify.org) | address written into client configs |
| `--wan-if eth0` | from default route | interface used for NAT |
| `--bin-dir DIR` | build | use prebuilt `amneziawg-go`, `awg`, `awg-quick` from `DIR` (copy them from another server, e.g. `/opt/amneziawg/bin`, to skip the build) |
| `--build-only DIR` | | only build the binaries into `DIR` and exit |
| `--protocol 1.0\|1.5\|2.0` | `1.0` (asked in a terminal) | AmneziaWG protocol version, see below |
| `--first-client NAME` | none | create a client at the end and print its config |
| `--no-service` | | write files only (no systemd, sysctl, firewall), for testing |
| `--allow-outdated` | | install even if this git checkout is behind upstream (by default it stops and asks for `git pull`) |

**Protocol version.** Without `--protocol`, an interactive run asks for it first (1 = 1.0, 2 = 1.5, 3 = 2.0; Enter = 1.0); with
`curl | bash` the question is still asked through the terminal, and without a terminal 1.0 is used.
The choice is recorded in `/etc/amnezia/amneziawg/protocol`, `awg-client` follows it and `update.sh`
never changes it.

| Version | Adds | Notes |
|---|---|---|
| 1.0 | `Jc/Jmin/Jmax`, `S1/S2`, `H1`-`H4` (single numbers) | works with every client |
| 1.5 | `I1` signature packet (QUIC-like), client side only | client needs 1.5 support |
| 2.0 | `S3/S4`, `H1`-`H4` as ranges `x-y` | client needs 2.0 support; the values must match on both ends |

Later "3+" features (header protection, content padding, timings) are not supported. Old clients
(e.g. the `amnezia-bridge` container with awg-tools 2021) do not know the new fields: re-issue
their configs or stay on 1.0.

What the installer does:

1. builds (or takes) `amneziawg-go`, `awg`, `awg-quick` and installs them to `/usr/local/bin`;
2. installs `qrencode`, `nftables`, `iproute2`;
3. generates server keys and random obfuscation parameters (`S1`, `S2`, `H1`-`H4`, plus `S3/S4` for 2.0; `Jc/Jmin/Jmax` fixed at 5/40/900);
4. writes `/etc/amnezia/amneziawg/awg0.conf` and the NAT rules (nftables table `awg_nat`, removed when the service stops);
5. enables `net.ipv4.ip_forward`, and if `ufw` is active opens the UDP port and adds a forwarding rule;
6. creates and starts the systemd service `awg-quick@awg0`.

It refuses to run if `awg0.conf` already exists. If the provider has a cloud firewall /
security group, open UDP 443 there yourself.

## Layout on the server

| | |
|---|---|
| Config | `/etc/amnezia/amneziawg/awg0.conf` |
| Server keys | `srv.key`, `srv.pub` (same directory) |
| Public address for client files | `endpoint` (same directory) |
| Clients | `clients/<name>.{conf,key,pub,psk}` |
| NAT rules | `nat-up.nft` |
| Service | `awg-quick@awg0` (unit in `/etc/systemd/system/awg-quick@.service`) |
| Binaries | `/usr/local/bin/{amneziawg-go,awg,awg-quick,awg-client}` |

## Managing clients: `awg-client`

Run as root.

```bash
awg-client help            # short help
awg-client add <name>      # create a client, print config + QR code
awg-client show <name>     # print config + QR code again
awg-client list            # clients and their tunnel addresses
awg-client remove <name>   # remove a client
awg-client version          # installed kit and amneziawg versions
awg-client protocol 2.0     # switch the server to AmneziaWG 1.0 / 1.5 / 2.0 (without an argument: show it)
awg-client mtu 1420         # MTU written into client configs (without an argument: show it; default 1420)
```

- Name: letters, digits, `_`, `-`, up to 32 characters.
- The next free address is picked automatically.
- A new client works immediately (added to the running tunnel with `awg set`) and is
  also appended to `awg0.conf`, so it survives a reboot.
- Before every change a copy is saved as `awg0.conf.bak-awg-client`.
- One config = one device. Two devices on the same config kick each other off.
- Do not remove a client that is in use: that device loses its VPN immediately.
- Client MTU is 1420 by default (1500 minus the tunnel overhead). Some sites (for example 2ip.io)
  flag a tunnel MTU of 1280 as "VPN fingerprint". The server interface stays at 1280; `awg-client mtu N`
  (1280-1500) changes only the client configs. A device keeps its old MTU until it imports
  `awg-client show <name>` again. If the server's own uplink MTU is below 1500, use WAN MTU minus 80.

### Using a client config

- **Phone / PC:** import the printed config (or scan the QR code) in the AmneziaWG or
  Amnezia VPN app.
- **OpenWrt (ZeroBlock / RouteRich):** create a network interface with
  `proto 'amneziawg'`, `awg_jc`, `awg_jmin`, `awg_jmax`, `awg_s1`, `awg_s2`, `awg_h1`-`awg_h4`,
  `mtu '1420'`, and one peer with `public_key`, `preshared_key`, `endpoint_host`,
  `endpoint_port '443'`, `allowed_ips '0.0.0.0/0'`, `persistent_keepalive '25'`,
  **`route_allowed_ips '0'`** (routing is done by ZeroBlock, not by the interface). Then add
  a ZeroBlock section of type `vpn` with that interface.

**Changing the protocol of a running server:** `awg-client protocol 2.0` (or `1.5`, `1.0`) rewrites the
`S3/S4/H1-H4` fields of `awg0.conf` (backup `awg0.conf.bak-protocol-<old>`), keeps the keys, address
plan and every client, and restarts the tunnel. All clients are offline until each gets its new
config (`awg-client show <name>`); the old configs stop working. The version does not change speed
(measured: 1.0, 1.5 and 2.0 give the same throughput within the noise).

The obfuscation parameters must be identical on server and client; `awg-client` copies
them from `awg0.conf` (and `I1` from `protocol`). Do not change them on a server that has clients unless you
re-issue all client configs.

## Hiding the server from ping: `block-ping`

Some sites measure round-trip times to the server and to the client and flag the difference
as a tunnel (2ip.io "tunnel detection / double-sided ping"). Dropping incoming ping on the
server removes that signal. It is **not** a guarantee against all VPN detection.

```bash
block-ping on                  # drop incoming ping on the uplink, also after reboot
block-ping on --wan-if eth0    # choose the interface(s) yourself (comma separated)
block-ping status              # active or not, dropped packets
block-ping off                 # remove it completely
./install.sh --block-ping      # do it right at install time
```

- Works with or without ufw/firewalld: it uses its own nftables table (`inet block_ping`, input
  hook, priority -10) that runs before them and does not touch their rules. IPv4 and IPv6.
- Only echo requests are dropped; other ICMP (errors, path MTU, neighbour discovery) stays.
- Ping-based monitoring of the server will report it as down. It is off by default.
- Without the kit: `curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/block-ping | bash -s -- on`

## Service and diagnostics

```bash
systemctl status awg-quick@awg0
awg show awg0                                    # peers, last handshake, traffic
journalctl -u awg-quick@awg0 -n 30 --no-pager    # if it does not start
systemctl restart awg-quick@awg0                 # drops all clients for a few seconds
```

A `latest handshake` older than a couple of minutes for an enabled client means the
tunnel does not work: UDP port blocked (provider firewall / ISP), wrong keys, or
mismatched parameters.

## Updating

Run on the server, from any folder (the script refreshes the kit in `/opt/awg-vps-kit` first):

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/update.sh | bash
```

It compares the installed versions (kit `VERSION`, `amneziawg-go` and `amneziawg-tools`
commits; see `awg-client version`) with the latest ones and prints either
`Update available: ... ; updating.` or `Latest version is installed (...)`.
The server config, keys and clients are not touched. A binary update restarts the
service (clients reconnect in a few seconds); the previous binaries are kept in
`/opt/amneziawg/prev`. Servers installed before `update.sh` existed have no recorded
versions and are reported as "unknown", so the first update rebuilds. Options go after
`bash -s --`: `--check` (report only; exit code 0 = latest installed, 10 = update available),
`--force`, `--bin-dir DIR`, `--no-restart`.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/uninstall.sh | bash
```

It asks for confirmation. Add `-s -- --keep-config` after `bash` to keep `/etc/amnezia` (keys,
clients) for a reinstall, or `-s -- --yes` to skip the question.

Removes the service, nftables table, ufw rules, sysctl file, binaries, `/etc/amnezia` and the kit clone in `/opt/awg-vps-kit`.
It does not touch `block-ping`: run `block-ping off` first if you want the ping block removed too.
Installed apt packages are left in place.

## When to use it

Background (diagnosed October 2026 on a home ISP in Russia): inbound **TCP** from
foreign VPS ranges was throttled to 1-4 Mbit/s, so every VLESS/TCP VPN was slow, while
**UDP** passed at full speed. AmneziaWG (UDP) gave ~150 Mbit/s where VLESS gave <1.

Before choosing AWG for a link, test it:

```bash
iperf3 -c SERVER -R          # TCP download      (slow here = TCP throttling)
iperf3 -c SERVER -R -u -b 100M   # UDP download: look at "Lost/Total"
```

- UDP loss up to ~7% is fine; at 10%+ TCP inside the tunnel collapses (1-5 Mbit/s on a
  second ISP). There use a VLESS server in a country the ISP does not throttle.
- Userspace `amneziawg-go` tops out around 200 Mbit/s on 1 vCPU. A kernel module would
  go faster but needs headers and DKMS.
- Port 443/udp does not conflict with an xray/3x-ui listening on 443/tcp.

## Companion: xray-vps-kit

If UDP is blocked or filtered on your network, there is a separate, independent kit for
VLESS + REALITY + Vision over TCP: [xray-vps-kit](https://github.com/thejohnd0e/xray-vps-kit).
It has its own installer and client manager, does not touch AWG files, and both can run on
one server (AWG on UDP 443, Xray on TCP 443).

| | awg-vps-kit (this) | xray-vps-kit |
|---|---|---|
| Transport | AmneziaWG over UDP | VLESS + REALITY + Vision over TCP |
| Management command | `awg-client` | `xray-client` |

## Development and testing

Pure Bash, no build step. Check syntax with `bash -n install.sh awg-client` (and
`shellcheck` if installed). `./install.sh --no-service` writes files only, for a dry
run on a Linux host. CI also runs `tests/test-install.sh` in Debian and Ubuntu containers (install, client management, update, uninstall; no live tunnel).

## License

MIT, see `LICENSE`.
