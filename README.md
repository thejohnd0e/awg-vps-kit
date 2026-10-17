# AWG VPS Kit
[![CI](https://github.com/thejohnd0e/awg-vps-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/thejohnd0e/awg-vps-kit/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/github/license/thejohnd0e/awg-vps-kit)](LICENSE) [![Last commit](https://img.shields.io/github/last-commit/thejohnd0e/awg-vps-kit)](https://github.com/thejohnd0e/awg-vps-kit/commits/master) [![Stars](https://img.shields.io/github/stars/thejohnd0e/awg-vps-kit?style=flat)](https://github.com/thejohnd0e/awg-vps-kit/stargazers) ![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white) ![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-A81D33?logo=debian&logoColor=white) ![Protocol](https://img.shields.io/badge/protocol-AmneziaWG%20(UDP)-blue)

AmneziaWG (userspace `amneziawg-go`) on UDP 443 and the `awg-client` command to manage
clients. UDP-based, so it works where the ISP throttles TCP from foreign VPS hosters
(see "When to use it").

Files in this directory:

| File | Purpose |
|---|---|
| `install.sh` | one-shot installer for a fresh Debian/Ubuntu server |
| `awg-client` | client manager, installed to `/usr/local/bin` |
| `update.sh` | checks and applies updates (kit + amneziawg binaries) |
| `uninstall.sh` | removes everything `install.sh` created |
| `README.md` | this file, also copied to `/etc/amnezia/amneziawg/README.md` on the server |

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
which takes a few minutes and works on 1 GB of RAM. Run the commands below on the server itself.

```bash
# on the server, as root:
apt-get update && apt-get install -y git
git clone https://github.com/thejohnd0e/awg-vps-kit.git
cd awg-vps-kit
./install.sh --subnet 10.79.0 --first-client user_01
```

**Update** (later, from the same folder; details in "Updating"):

```bash
cd ~/awg-vps-kit    # the folder you cloned into
./update.sh --check # only report
./update.sh         # apply: git pull, rebuild binaries if upstream has news, restart
```

**Uninstall** (details in "Uninstall"):

```bash
cd ~/awg-vps-kit
./uninstall.sh      # asks for confirmation; add --keep-config to keep keys and clients
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
| `--first-client NAME` | none | create a client at the end and print its config |
| `--no-service` | | write files only (no systemd, sysctl, firewall), for testing |
| `--allow-outdated` | | install even if this git checkout is behind upstream (by default it stops and asks for `git pull`) |

What the installer does:

1. builds (or takes) `amneziawg-go`, `awg`, `awg-quick` and installs them to `/usr/local/bin`;
2. installs `qrencode`, `nftables`, `iproute2`;
3. generates server keys and random obfuscation parameters (`S1`, `S2`, `H1`-`H4`; `Jc/Jmin/Jmax` fixed at 5/40/900);
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
```

- Name: letters, digits, `_`, `-`, up to 32 characters.
- The next free address is picked automatically.
- A new client works immediately (added to the running tunnel with `awg set`) and is
  also appended to `awg0.conf`, so it survives a reboot.
- Before every change a copy is saved as `awg0.conf.bak-awg-client`.
- One config = one device. Two devices on the same config kick each other off.
- Do not remove a client that is in use: that device loses its VPN immediately.

### Using a client config

- **Phone / PC:** import the printed config (or scan the QR code) in the AmneziaWG or
  Amnezia VPN app.
- **OpenWrt (ZeroBlock / RouteRich):** create a network interface with
  `proto 'amneziawg'`, `awg_jc`, `awg_jmin`, `awg_jmax`, `awg_s1`, `awg_s2`, `awg_h1`-`awg_h4`,
  `mtu '1280'`, and one peer with `public_key`, `preshared_key`, `endpoint_host`,
  `endpoint_port '443'`, `allowed_ips '0.0.0.0/0'`, `persistent_keepalive '25'`,
  **`route_allowed_ips '0'`** (routing is done by ZeroBlock, not by the interface). Then add
  a ZeroBlock section of type `vpn` with that interface.

The obfuscation parameters must be identical on server and client; `awg-client` copies
them from `awg0.conf`. Do not change them on a server that has clients unless you
re-issue all client configs.

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

Run from the cloned repo on the server (keep the clone, e.g. `/root/awg-vps-kit`):

```bash
cd /root/awg-vps-kit
./update.sh --check    # report only; exit code 0 = latest installed, 10 = update available
./update.sh            # updates only if something is newer, otherwise says so
```

It compares the installed versions (kit `VERSION`, `amneziawg-go` and `amneziawg-tools`
commits; see `awg-client version`) with the latest ones and prints either
`Update available: ... ; updating.` or `Latest version is installed (...)`.
The server config, keys and clients are not touched. A binary update restarts the
service (clients reconnect in a few seconds); the previous binaries are kept in
`/opt/amneziawg/prev`. Servers installed before `update.sh` existed have no recorded
versions and are reported as "unknown", so the first update rebuilds. Options:
`--force`, `--bin-dir DIR`, `--no-restart`.

## Uninstall

```bash
./uninstall.sh              # asks for confirmation
./uninstall.sh --keep-config   # keep /etc/amnezia (keys, clients) for a reinstall
```

Removes the service, nftables table, ufw rules, sysctl file, binaries and `/etc/amnezia`.
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
