# AWG VPS Kit

**English** · [Русский](README.ru.md)

[![CI](https://github.com/thejohnd0e/awg-vps-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/thejohnd0e/awg-vps-kit/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![Last commit](https://img.shields.io/github/last-commit/thejohnd0e/awg-vps-kit)](https://github.com/thejohnd0e/awg-vps-kit/commits/master) ![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white) ![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-A81D33?logo=debian&logoColor=white) ![Protocol](https://img.shields.io/badge/protocol-AmneziaWG%20(UDP)-blue)

AmneziaWG (userspace `amneziawg-go`) on UDP 443 and the `awg-client` command to manage
clients. UDP-based, so it works where the ISP throttles TCP from foreign VPS hosters
(see "When to use it").

## Part of the VPS kit family

`quality-vps-kit` is one of several independent tools for the same workflow: evaluate a VPS first, then set up VPN/proxy services on it.

| Project | Purpose |
|---|---|
| [quality-vps-kit](https://github.com/thejohnd0e/quality-vps-kit) | read-only evaluation of a fresh VPS |
| [xray-vps-kit](https://github.com/thejohnd0e/xray-vps-kit) | VLESS/Reality server installer and client management |
| **awg-vps-kit** (this repo) | AmneziaWG server installer and client management |
| [hysteria-vps-kit](https://github.com/thejohnd0e/hysteria-vps-kit) | Hysteria2 server installer and client management |

The kits are independent: none of them modifies or requires the others.

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

**Not supported (on purpose):**

- **firewalld.** The installer integrates only with `ufw` (port and route rules) and its own
  nftables table `awg_nat`. With firewalld active the tunnel is blocked: verified on Debian 13
  with the default `public` zone, even `ping 10.99.0.1` fails. Open UDP 443 and allow forwarding
  yourself, or disable firewalld and use ufw. `install.sh` prints a warning when `firewall-cmd`
  reports `running`. Docker/iptables-nft works (its `FORWARD` policy does not override the kit's
  forward chain).
- **IPv6.** The tunnel is IPv4-only. Generated client profiles contain `AllowedIPs = 0.0.0.0/0`,
  so a client with native IPv6 sends that traffic **outside the VPN** (a leak), and the server
  does no IPv6 filtering. If your provider or mobile network hands out IPv6, treat it as
  unprotected.

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

`install.sh` options (all optional; `install.sh --help` prints the same list). Values are validated
before anything is installed: the port must be 1-65535 and every subnet octet 0-255.

| Option | Default | Meaning |
|---|---|---|
| `--subnet 10.79.0` | `10.77.0` | tunnel /24 prefix, the server gets `.1`. **Use a different one per server** (e.g. `10.77.0`, `10.78.0`). The installer refuses a /24 that overlaps a network the server is connected to (or a more specific route), and warns when it falls inside a broader route. |
| `--port 443` | `443` | UDP listen port |
| `--endpoint IP/HOST` | auto (api.ipify.org, then ifconfig.me, icanhazip.com) | address written into client configs |
| `--wan-if eth0` | from default route | interface used for NAT |
| `--bin-dir DIR` | build | use prebuilt `amneziawg-go`, `awg`, `awg-quick` from `DIR` (copy them from another server, e.g. `/opt/amneziawg/bin`, to skip the build) |
| `--build-only DIR` | | only build the binaries into `DIR` and exit |
| `--protocol 1.0\|1.5\|2.0\|3.1` | `1.0` (asked in a terminal) | AmneziaWG protocol version, see below |
| `--first-client NAME` | none | create a client at the end and print its config |
| `--no-service` | | write files only (no systemd, sysctl, firewall), for testing |
| `--allow-outdated` | | install even if this git checkout is behind upstream (by default it stops and asks for `git pull`) |

**Protocol version.** Without `--protocol`, an interactive run asks for it first (1 = 1.0, 2 = 1.5, 3 = 2.0, 4 = 3.1; Enter = 1.0); with
`curl | bash` the question is still asked through the terminal, and without a terminal 1.0 is used.
The choice is recorded in `/etc/amnezia/amneziawg/protocol`, `awg-client` follows it and `update.sh`
never changes it.

| Version | Adds | Notes |
|---|---|---|
| 1.0 | `Jc/Jmin/Jmax`, `S1/S2`, `H1`-`H4` (single numbers) | works with every client |
| 1.5 | `I1` signature packet (QUIC-like), client side only | client needs 1.5 support |
| 2.0 | `S3/S4`, `H1`-`H4` as ranges `x-y` | client needs 2.0 support; the values must match on both ends |
| 3.1 | `HeaderProtectionKey`, equal `S1`-`S4`, `H1`-`H4` = 1/2/3/4, `RandomTrailers`, `ContentPaddingAddition`, timer ranges | client needs 3.1 support (Amnezia VPN >= 5.0.1.5); `S1`-`S4`, `H1`-`H4`, `HeaderProtectionKey` and `RandomTrailers` must match on both ends (`ContentPaddingAddition` and the timers are sender-side); client MTU defaults to 1280 |

Protocol 3.1 needs a reviewed engine: the installer warns, and `awg-client protocol 3.1` refuses, when
the installed `amneziawg-go` is not the reviewed 3.1 build (run `update.sh`). Its client configs default
to MTU 1420 like 1.0-2.0, and the minimum client versions are Amnezia VPN >= 5.0.1.5, AmneziaWG
Android >= v3.1.20260814 and Windows >= 3.1.0. Servers whose configs feed
[AmneziaWG-to-Proxy](https://github.com/thejohnd0e/AmneziaWG-to-Proxy) must stay on 2.0 or lower until
the engine in that container image is updated: it is 2.0 or older and does not know the 3.1 fields.

What the installer does:

1. builds (or takes) `amneziawg-go`, `awg`, `awg-quick` and installs them to `/usr/local/bin`;
2. installs `qrencode`, `nftables`, `iproute2`;
3. generates server keys and random obfuscation parameters (`S1`, `S2`, `H1`-`H4`; `S3/S4` for 2.0; for 3.1 equal `S1`-`S4` (15-32), fixed `H1`-`H4` = 1/2/3/4, a `HeaderProtectionKey`, `RandomTrailers = on` and `ContentPaddingAddition = 10-100`; `Jc/Jmin/Jmax` fixed at 5/40/900);
4. writes `/etc/amnezia/amneziawg/awg0.conf` and the NAT rules (nftables table `awg_nat`, removed when the service stops);
5. enables `net.ipv4.ip_forward`, and if `ufw` is active opens the UDP port and adds a forwarding
   rule (firewalld is not supported, see "Not supported" above);
6. creates and starts the systemd service `awg-quick@awg0`;
7. enables `awg-watchdog.timer`: every 30 s it checks that `awg0` still exists while the
   unit reports `active`, and restarts the tunnel if `amneziawg-go` died (it skips while a
   kit operation holds the lock).

It refuses to run if `awg0.conf` already exists. If an install fails before the tunnel is up,
it disables the service, removes the NAT table and the ufw rules it added, and moves its files
to `/etc/amnezia/amneziawg.failed-<timestamp>`, so the next run starts clean; delete that folder
once you have looked at it. If the provider has a cloud firewall /
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
| Watchdog | `awg-watchdog.timer` / `.service` (script `/usr/local/bin/awg-watchdog`) |
| Binaries | `/usr/local/bin/{amneziawg-go,awg,awg-quick,awg-client}` |
| Shared helpers | `/usr/local/lib/awg-vps-kit/common.sh` (sourced by `awg-client`; `update.sh` refreshes it together with the other files and restores it if an update fails) |

## Managing clients: `awg-client`

Run as root.

```bash
awg-client help            # short help
awg-client add <name>      # create a client, print config + QR code
awg-client show <name>     # print config + QR code again
awg-client list            # clients and their tunnel addresses (AllowedIPs)
awg-client list -v         # plus last handshake, traffic and endpoint of each client
awg-client remove <name>   # remove a client
awg-client rename <old> <new>   # new name for a client; the device keeps working
awg-client export [file.tar.gz] # every client config in one archive (holds private keys)
awg-client version          # installed kit and amneziawg versions
awg-client protocol 2.0     # switch the server to AmneziaWG 1.0 / 1.5 / 2.0 / 3.1 (without an argument: show it)
awg-client mtu 1420         # MTU written into client configs (without an argument: show it; default 1420 on every protocol)
awg-client endpoint 203.0.113.5  # server address written into client configs, after the server IP changed (without an argument: show it; IPv4, IPv6 or DNS name; no restart)
awg-client dns 9.9.9.9      # DNS servers written into client configs (up to 3 IPv4; `default` = 1.1.1.1)
```

- Name: letters, digits, `_`, `-`, up to 32 characters.
- The next free address is picked automatically.
- A new client works immediately (added to the running tunnel with `awg set`) and is
  also appended to `awg0.conf`, so it survives a reboot.
- `add` and `remove` stage the new `awg0.conf` first and roll back if any step fails. Only
  `protocol` keeps copies (`awg0.conf.bak-protocol-*`, `protocol.bak-*`; the 5 newest of each).
- One config = one device. Two devices on the same config kick each other off.
- `list -v` reads the running interface. `HANDSHAKE` is the age of the client's last handshake: `never`
  means the device has not connected since the tunnel started; a connected device with the default
  keepalive shows a couple of minutes at most, anything older means it is offline or blocked (see the
  note on `latest handshake` below). `RX`/`TX` are bytes received from / sent to the client since the
  tunnel started. Without a running tunnel it still lists the clients and says there is no live data.
- `rename` changes the name in `awg0.conf` and the file names in `clients/`; the client config contains no
  name, so devices need no new config. It refuses a name that is already used and rolls back if a file
  cannot be moved.
- `export` regenerates every config in the current format (current MTU, DNS and protocol) into one
  `.tar.gz` (default `./awg-clients-<host>-<time>.tar.gz`, mode 600, never overwrites). **It contains
  the clients' private keys**: store it like a password and delete it when it has served its purpose.
- `dns` changes the `DNS =` line of client configs only (no server restart). Only IPv4 addresses are
  accepted because the tunnel is IPv4-only. As with MTU, a device keeps its old DNS until it imports
  `awg-client show <name>` again.
- Do not remove a client that is in use: that device loses its VPN immediately.
- Client MTU is 1420 by default on every protocol (including 3.1). Some sites (for example 2ip.io) flag a
  tunnel MTU of 1280 as "VPN fingerprint". The server interface stays at 1280; `awg-client mtu N`
  (1280-1500) changes only the client configs and overrides the default. A device keeps its old MTU until
  it imports `awg-client show <name>` again. If the server's own uplink MTU is below 1500, use WAN MTU minus 80.
- The server does **not** clamp the TCP MSS (a clamp to 1240 shows up on leak pages as "MTU 1280", a VPN fingerprint). `update.sh` removes the clamp rules that kits 1.3.x-1.4.0 wrote into `nat-up.nft`.
- **Phone / PC:** import the printed config (or scan the QR code) in the AmneziaWG or
  Amnezia VPN app.
- **OpenWrt (ZeroBlock / RouteRich):** create a network interface with
  `proto 'amneziawg'`, `awg_jc`, `awg_jmin`, `awg_jmax`, `awg_s1`, `awg_s2`, `awg_h1`-`awg_h4`,
  `mtu '1420'`, and one peer with `public_key`, `preshared_key`, `endpoint_host`,
  `endpoint_port '443'`, `allowed_ips '0.0.0.0/0'`, `persistent_keepalive '25'`,
  **`route_allowed_ips '0'`** (routing is done by ZeroBlock, not by the interface). Then add
  a ZeroBlock section of type `vpn` with that interface.

**Changing the protocol of a running server:** `awg-client protocol 3.1` (or `2.0`, `1.5`, `1.0`) rewrites the
obfuscation fields of `awg0.conf` (`S3/S4/H1-H4`, or for 3.1 `S1`-`S4`, `H1`-`H4`, `HeaderProtectionKey`,
`RandomTrailers`, `ContentPaddingAddition`; backup `awg0.conf.bak-protocol-<old>.<timestamp>`), keeps the keys,
address plan and every client, and restarts the tunnel. All clients are offline until each gets its new
config (`awg-client show <name>`); the old configs stop working. Switching only between `1.0` and `1.5`
changes client-side data: the server fields are identical, so `awg0.conf` is not rewritten, the tunnel is
not restarted and existing clients keep working; `awg-client show` then adds the `I1`-`I5` fields (or
leaves them out for 1.0). Custom `I1`-`I5` values in `protocol` are preserved. `protocol 3.1` first checks
that the installed `amneziawg-go` is the reviewed 3.1 build and refuses otherwise (run `update.sh`); it
keeps the client MTU default at 1420. The version does not change
speed (measured: 1.0, 1.5 and 2.0 give the same throughput within the noise).

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
systemctl status awg-watchdog.timer              # watchdog is active
journalctl -u awg-watchdog.service -n 20         # restarts the watchdog performed
```

The unit is `oneshot`: if `amneziawg-go` dies, systemd still reports `active` while the
interface and the UDP port are gone. `awg-watchdog.timer` runs every 30 s and restarts the
unit in that case (logged in `awg-watchdog.service`); it does not restart on its own while
`add`/`remove`/`protocol`/`update` holds the kit lock. It also restores the `awg_nat` table
if something removed it. If the unit is in the `failed` state (for example a start that did not
work), the watchdog starts it again, but at most once per 5 minutes so a permanent fault does not
turn into a restart loop; read the reason with `journalctl -u awg-quick@awg0`. A unit you stopped
yourself (`systemctl stop`) is `inactive`, not `failed`, and is left alone. To turn the watchdog
off: `systemctl disable --now awg-watchdog.timer`.

**Do not run `systemctl restart nftables`** on this host: the default `/etc/nftables.conf`
starts with `flush ruleset` and wipes `awg_nat` and the ufw rules. If it happens, the watchdog
recreates `awg_nat` within 30 s and, when ufw is active, runs `ufw reload` to bring its rules
(and `ufw route allow` for the tunnel) back. The `block-ping` table is not restored by the
watchdog: run `systemctl restart block-ping` if you use it.

A `latest handshake` older than a couple of minutes for an enabled client means the
tunnel does not work: UDP port blocked (provider firewall / ISP), wrong keys, or
mismatched parameters.

## Updating

Run on the server, from any folder (the script refreshes the kit in `/opt/awg-vps-kit` first):

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/update.sh | bash
```

It compares the installed versions (kit `VERSION`, `amneziawg-go` and `amneziawg-tools`
commits; see `awg-client version`) with the ones the kit ships (see "Upstream versions" below) and prints either
`Update available: ... ; updating.` or `Latest version is installed (...)`.
The server config, keys and clients are not touched. A binary update restarts the
service (clients reconnect in a few seconds) only when the running interface is usable
(`systemctl is-active` plus `awg show`); otherwise it stops before replacing anything.
If the restart or the check afterwards fails, the previous binaries, `versions`,
`kit-version`, `awg-client` and README are restored and the old version is started again;
the failed attempt is reported with exit 1. The previous, matching set is kept in
`/opt/amneziawg/prev` after a successful update. With `--no-restart` (or when the service
is stopped) the files are installed but the runtime is not verified, and the script says so.
Servers installed before `update.sh` existed have no recorded
versions and are reported as "unknown", so the first update rebuilds. Options go after
`bash -s --`: `--check` (report only; exit code 0 = latest installed, 10 = update available;
does not pull the kit or change installed files), `--force`, `--bin-dir DIR`, `--no-restart`,
`--upstream-head` (see below).
An update also installs and enables `awg-watchdog.timer` on servers created by an older kit.

### Upstream versions

`amneziawg-go` and `amneziawg-tools` run as root, so the kit does not build whatever their
default branch holds today: `upstream.lock` lists the two reviewed commits, and `install.sh` and
`update.sh` build exactly those (the build prints `pinned in upstream.lock`). A new upstream
commit reaches servers only after the kit itself moves the lock. `update.sh` and `update.sh --check`
print a `note:` when upstream has newer commits than the reviewed ones; that is information, not an
update. The lock comes with the kit version, so `--check` reports what the *next* kit version would
install when the kit is behind.

`--upstream-head` (on `install.sh` and `update.sh`) builds the newest upstream code instead. It is
unreviewed; the next plain `update.sh` brings the server back to the pinned commits. Maintainers
move the pins with `tools/bump-upstream.sh` (shows the difference and compare links; `--apply` only
edits `upstream.lock`, after which the build and the test suites have to be run before committing).

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/awg-vps-kit/master/uninstall.sh | bash
```

It asks for confirmation. Add `-s -- --keep-config` after `bash` to keep `/etc/amnezia` (keys,
clients) for a reinstall, or `-s -- --yes` to skip the question.

Removes the service, watchdog timer, `block-ping` (table, unit and files), nftables table, ufw rules,
sysctl file, binaries, `/etc/amnezia` and the kit clone in `/opt/awg-vps-kit`. Installed apt packages
are left in place. `--keep-config` keeps `/etc/amnezia`, including `clients/`, `protocol` and any
unfinished `transactions/` directory; a later reinstall still refuses to overwrite an existing
`awg0.conf`, so restore it deliberately rather than re-running the installer over it.

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

Pure Bash, no build step. Code that more than one script needs (locking, `kv`, backup pruning, the H/S/I1 generators) lives in `lib/common.sh`; `uninstall.sh`, `block-ping` and `awg-watchdog` deliberately stay self-contained. Check syntax with `bash -n install.sh awg-client` (and
`shellcheck` if installed). `./install.sh --no-service` writes files only, for a dry
run on a Linux host. CI also runs `tests/test-install.sh` in Debian and Ubuntu containers (install, client management, update, uninstall; no live tunnel) and checks that the built commits equal `upstream.lock`.

## License

MIT, see `LICENSE`.
