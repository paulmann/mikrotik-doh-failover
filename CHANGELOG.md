# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `zabbix/` — fleet monitoring for Zabbix 8: a collector that reads DoH state
  (`/ip dns use-doh-server`, three canaries) and VPN state (WireGuard peers,
  handshake age) from every router over SSH and pushes it as trapper items;
  six triggers and two service trees (`DoH на микротиках`, `VPN -> Микротики`).
- `zabbix/systemd/` — timer and service units (run every 2 minutes).
## [v0.2.0] - 2026-10-26

Default upstream changed to the standard (non-filtering) resolver; failover now
switches between two DoH endpoints instead of falling back to plain DNS; the
health check judges answers by content.

### Added
- `examples/cloudflare-standard.rsc` — worked single-file example for the new
  default (`cloudflare-dns.com`, 1.1.1.1/1.0.0.1).
- `docs/troubleshooting.md` §6.10 — "sites do not open while the resolver looks
  healthy": the stub pair `8.6.112.0` / `8.47.69.0`, how to prove reachability
  from a client, and the three fixes that actually work.
- `docs/troubleshooting.md` §6.11 (probe needs its own DNS), §6.12 (Quad9 does
  not speak the DNS-JSON API).
- `docs/verification.md` — 0.2.0 checklist (failover, rollback, stub pair, clock
  guard) and the re-verified results on RouterOS 7.23.1.
- `docs/release-notes-v0.2.0.md`.
- `routeros/05-dns-health-monitor.rsc` — content-aware check, `/tool fetch`
  probe of both endpoints, clock guard, DoH-to-DoH failover with verification and
  rollback, `maxAttempts` guard, narrow scheduler policy.

### Changed
- `routeros/01-configure-doh.rsc` — default is the **standard** Cloudflare
  resolver; filtering (Family/Security) is an explicit opt-in. Bootstrap records
  are pinned for the fallback host as well, because the probe cannot resolve a
  hostname through a resolver that is already dead.
- `routeros/02-security-policies.rsc` — documented that `dstnat redirect` does
  not cover clients that already use the router as their resolver.
- `routeros/config.example.rsc`, `examples/cloudflare-family.rsc`, all six
  READMEs — new defaults and the reason for them.
- `routeros/05-dns-health-monitor.rsc` scheduler is now created with
  `policy=read,write,policy,test` instead of the full default set.

### Fixed
- Health check no longer calls a resolver healthy just because it returned an IP:
  the stub pair `8.6.112.0`/`8.47.69.0` is now reported instead of silently
  accepted (v1's own verification notes recorded it as "real IP").
- The check no longer flips `use-doh-server` to test it, so a routine check no
  longer takes the LAN off DoH.
- A failed failover is rolled back instead of leaving the router parked on a dead
  endpoint.
- Plain DNS is no longer treated as a working fallback: measured substitution on
  the path, even for queries straight to 1.1.1.1/8.8.8.8.


### Added
- `AGENTS.md` — agent-facing operational contract: fetch, apply, verify and roll back
  on RouterOS, with the measured expected outputs and the deliberate limits.
- `assets/social-preview.png` (1280x640) — README header banner and repository
  social preview, and the banner is now embedded in `README.md` under the badges.

## [v0.1.0] - 2026-10-22

Initial tested release.

### Added
- `routeros/00-install-ca.rsc` — install and trust the DoH CA.
- `routeros/01-configure-doh.rsc` — single DoH upstream + bootstrap static A records.
- `routeros/02-security-policies.rsc` — force-DNS (redirect 53) + resolver protection.
- `routeros/03-capsman.rsc` — targeted CAPsMAN/DHCP integration.
- `routeros/04-cert-update.rsc` — optional CA refresh.
- `routeros/05-dns-health-monitor.rsc` — health-check + failover script and scheduler.
- `routeros/config.example.rsc` — tunables reference.
- `docs/architecture.md`, `docs/verification.md`, `docs/troubleshooting.md`.
- Mermaid diagrams under `diagrams/`.
- `certs/cloudflare-doh-ca.crt` (SSL.com TLS ECC Root CA 2022).

### Fixed / Corrected
- Removed the invalid `static-server type=doh` "backup DoH" mechanism; replaced
  with a single active DoH upstream plus a managed plain-DNS fallback.
- Replaced `dst-nat to-addresses=<router-ip>` force-DNS with `action=redirect`.
- Narrowed script policies from the full set to `read,write,policy,test`.
- Added TCP/53 accept (the force-DNS rule redirects both UDP and TCP).
- Corrected the CA guidance: `builtin-trust-store=default` does not cover the
  Cloudflare chain on 7.23/7.24, and `builtin-trust-anchors` is not a parameter;
  an explicit CA import is required.

### Verified against
- RouterOS **7.23.1** (RB2011UiAS) and **7.24.5** (Chateau PRO ax, RB4011iGS+,
  hAP ax², RB951Ui, cAP ax).
- Cloudflare Family DoH (`family.cloudflare-dns.com`, 1.1.1.3 / 1.0.0.3).

### Known limitations
- Automatic scheduler execution requires `device-mode=advanced`; on `home`
  devices the monitor runs manually only.
- Client DoH/DoT is not blocked; classic DNS (53) is redirected, DoT (853) has
  an optional block rule.
