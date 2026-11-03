# Live checks on a disposable VM

The container suite (`tests/test-install.sh`, `tests/test-reliability.sh`) covers files,
permissions, locking, transactions and rollback with a stubbed interface and systemd.
It cannot prove that a real tunnel passes traffic, that nftables/ufw compose with the
host firewall, or that a userspace process crash is visible to systemd.

Run these checks only on a throwaway Debian 12/13 or Ubuntu 24.04 VM, never on a server
that clients use. Each case starts from a snapshot. Use synthetic client keys.
Never paste production keys, endpoints, QR codes or full configs into logs.

## Record

| Field | Value |
|---|---|
| Date | 2026-11-03 |
| OS image | Debian 13.7 (trixie), kernel 6.12.107, VirtualBox `Deb_13_test` (192.168.0.141) |
| Kit commit | 621634d (`master`, before the doc-only commit) |
| amneziawg-go / tools commits | b5928ef (2026-08-28) / ee0f0a9 (2026-08-12) |
| Client platform | network namespace on the same VM running `awg-quick` (userspace client) |
| Result | baseline, update, rollback, protocol changes, ufw, watchdog, NAT idempotence, Docker, firewalld and keep-config checks executed; see the table |

## Results 2026-11-03

Executed on the snapshot `before-reliability-2026-11-03` (VirtualBox), then the VM was left with
the working installation. Values are from that run.

| Check | Result |
|---|---|
| `tests/test-install.sh /opt/awg-bin` | pass on Debian 13.7 |
| `tests/test-reliability.sh /opt/awg-bin all` | pass (cli, bootstrap, cleanup, lock, peers, protocol, update) |
| Live install (`--subnet 10.99.0 --endpoint 192.168.0.141 --first-client vmclient`) | service `active` + `enabled`, UDP 443 bound (v4 and v6), `awg_nat` loaded, `ip_forward=1` |
| File modes | dir 700, `awg0.conf`/`srv.key`/client files 600, README 644 |
| Tunnel traffic (client in a netns) | handshake, ping 10.99.0.1, ping 1.1.1.1 via NAT, HTTP 301 through the tunnel |
| Reboot | service auto-started, `awg_nat` present, traffic worked again |
| `update.sh --force` (healthy) | restart + `Done.`, exit 0 |
| `update.sh --force` with a broken `amneziawg-go` | restart failed, files restored (hash equal), old version restarted, exit 1 |
| `update.sh --check` | exit 0, config/binary mtimes and hashes unchanged |
| ufw active (non-English-safe status) | installer added `443/udp` and `route allow in on awg0 out on enp0s3`; traffic still passed |
| `protocol 1.5` | `awg0.conf` hash and `ActiveEnterTimestamp` unchanged, client got `I1`, no restart |
| `protocol 2.0` then `1.0` | restart, `S3/S4` + H ranges, reissued client config carried traffic |
| Kill `amneziawg-go` | **before the watchdog:** `systemctl is-active` still `active`, `awg show` failed, interface and UDP port gone, no auto-restart; `update.sh` refused with "active but not usable" and left binaries unchanged |
| Watchdog migration via `update.sh --force` | `awg-watchdog.timer` installed, enabled and active on the existing installation |
| Kill `amneziawg-go` with the watchdog | interface down right after the kill, back within ~30 s without manual action (`awg-watchdog.service` logged the restart), traffic worked again |
| `nft -f nat-up.nft` twice | before the fix: second load succeeded and duplicated the rules (1 → 2 masquerade); after the guard was added: still 1 |
| `awg-quick down` with the NAT table deleted | before: `PostDown` failed and `down` returned 1 (interface still removed); after `2>/dev/null || true`: return 0 |
| `systemctl restart nftables` (default `flush ruleset`) | `awg_nat` vanished, the unit stayed `active` and client traffic stopped; the watchdog's new NAT check restored the table after 16 s and traffic worked again. ufw rules are flushed too and need `ufw reload` |
| Docker installed (`FORWARD` policy DROP) | tunnel traffic kept working: the `awg_forward` base chain at `priority filter - 1` accepts the packet for the forward hook before the later chain's policy applies |
| firewalld active (default `public` zone) | tunnel completely dead: ping to 10.99.0.1 lost 100%, forwarding blocked; unsupported without explicit zone/forward configuration |
| `uninstall.sh --yes` | service inactive, watchdog timer `not-found`, script and units removed, `/etc/amnezia` removed |
| `uninstall.sh --keep-config` | config kept, service and timer stopped, watchdog binary removed; a reinstall refused the existing `awg0.conf` as documented |
| Reinstall after removal | new install with client `vmclient3`, timer active, traffic worked |
| IPv6 | the VM has only a link-local address on `enp0s3` and no IPv6 default route, so a dual-stack leak test was not possible here |

Not executed: a dual-stack IPv6 client (the VM has no global IPv6). Decision (2026-11-03): firewalld
support is out of scope and documented as unsupported; Docker works as shown above; the tunnel stays
IPv4-only with the IPv6 leak documented in README.


## Baseline

1. Install with `--first-client test1` and a dedicated `--subnet`.
2. Import the client config on a separate test device and check IPv4 TCP, UDP and DNS.
3. `systemctl status awg-quick@awg0 --no-pager`, `awg show awg0`.
4. Reboot; repeat step 2 without touching the server.
5. `awg-client add test2`, `show`, `remove`; repeat step 2 for test1.
6. `install.sh --no-service` on a *separate* snapshot must write files and change no
   service, sysctl or firewall state.

## Firewall composition (one snapshot per case)

1. `nft -f /etc/amnezia/amneziawg/nat-up.nft` twice: record whether rules duplicate.
2. `awg-quick down awg0`, then delete the table first and run it again: record the error
   and whether the down path still completes.
3. `systemctl restart nftables` (default `/etc/nftables.conf` starts with `flush ruleset`):
   record whether `awg_nat` survives and whether NAT still works.
4. ufw active, with a non-English locale: install and check the rules were added.
5. Docker/iptables-nft present: check forwarded traffic with its FORWARD policy DROP.
6. firewalld present: same, and record the zone behaviour.
7. IPv6: with a dual-stack client, confirm the current IPv4-only profile does not carry or
   protect IPv6. Do not change `AllowedIPs` or forwarding during this check.

For every case write down supported / unsupported / unverified for that exact host
configuration. A universal workaround is out of scope.

## Lifecycle

1. Start a long transfer through the tunnel.
2. Kill `amneziawg-go` only on this VM; record `systemctl is-active` and whether traffic
   resumes without a manual restart.
3. Do not simulate OOM by exhausting memory. If memory use matters, measure a normal
   build and a running tunnel instead.
4. Update with `--force` while the tunnel is healthy, then check traffic again.
5. Update with a deliberately broken restart (see the container test for the mechanism);
   record that the previous binaries, `versions`, `kit-version`, `awg-client` and README
   come back together, that `awg show` lists peers, and that traffic works.
6. Re-run `update.sh --check` and `awg-client version`; values must match the restored set.

## Follow-up

Findings that require changing installed files (NAT idempotence, down path, nftables reload,
watchdog/unit) need a separate approved design with an exact migration manifest, backup and
restore. Do not add `schema`/`migrate_N` before that design is approved.
