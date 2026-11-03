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
| Date | not executed in this session (2026-11-03) |
| OS image | |
| Kit commit | |
| amneziawg-go / tools commits | |
| Client platform | |
| Result | |

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
