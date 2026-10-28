# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog 2.0.0](https://keepachangelog.com/en/2.0.0/) and the project
uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

_No unreleased changes._

## [0.4.1] - 2026-10-28

### Changed
- `routeros/05-dns-health-monitor.rsc` — every `/tool fetch` probe now carries
  `duration=5s`, so a hung endpoint cannot block the run past the scheduler
  interval (verified on RouterOS 7.23.1).
- The tertiary switch now does the same verify-after-switch with rollback as the
  secondary, and every real switch (secondary, tertiary, plain) increments
  `DNSFailoverAttempts`, so the counter reflects the whole chain.

### Fixed
- `routeros/05-dns-health-monitor.rsc` — recovery from the plain fallback now
  climbs back to **any** DoH endpoint, not only the primary: if the primary is
  still down but the secondary answers, the monitor leaves plain DNS and returns
  to DoH (clearing `servers`).

## [0.4.0] - 2026-10-28

### Added
- `routeros/05-dns-health-monitor.rsc` — ordered failover chain: primary →
  secondary → tertiary (`dohUrlC`, optional, empty disables it) → plain DNS
  (`plainFallback`, optional). The plain step is logged `PRIVACY DEGRADED`, and a
  new `plain` state recovers back to the primary once it answers again.

### Changed
- `routeros/05-dns-health-monitor.rsc` — the probe now uses
  `/tool fetch ... as-value output=user` (the response body comes back in memory),
  removing the temporary files in `/file` and the cleanup races. The JSON check
  tolerates both `"Status":0` and `"Status": 0`.
- New tunables: `dohUrlC`, `probeUrlC`, `plainFallback`, `plainServers`.

## [0.3.1] - 2026-10-28

### Added
- `routeros/02-security-policies.rsc` — `enforcement=strict` mode: blocks DoT
  (TCP 853) and the well-known public DoH endpoints (address-list `public-doh`),
  with the residual risk documented instead of hidden.
- `zabbix/` — fleet monitoring for Zabbix 8: a collector that reads DoH state
  (`/ip dns use-doh-server`, three canaries) and VPN state (WireGuard peers,
  handshake age) from six routers over SSH and pushes it to trapper items;
  eight items, five triggers, two service trees (`DoH на микротиках`,
  `VPN -> Микротики`). Added on `main` after the `v0.2.0` tag.
- `zabbix/systemd/` — timer and service units (run every 2 minutes).
- `zabbix/README.md` (English) and `zabbix/README.ru.md` (Russian original),
  matching the repository's `*.ru.md` convention for translated copies.

### Changed
- `routeros/05-dns-health-monitor.rsc` — explicit state machine
  (`HEALTHY → SUSPECT → FALLBACK → RECOVERING → HEALTHY`, plus `STUB`,
  `DEGRADED`, `CLOCK_INVALID`, `MANUAL-ONLY`); configurable `interval` (60s
  default, was a hardcoded 3m); `failureThreshold`/`recoveryThreshold` hysteresis
  as the anti-flap mechanism; `MONITOR_DISABLED_BY_DEVICE_MODE` diagnostics for
  `device-mode=home`; wording "managed failover" instead of implying transparency.
- `routeros/05-dns-health-monitor.rsc` (hardening) — concurrency guard: an
  overlapping scheduler run is skipped and the flag is cleared in an `on-error`
  handler, so a crashed run cannot leave the monitor locked; failover is driven by
  **endpoint health** together with the content check, so a primary that dies
  while the cache still holds answers is detected before the cache TTL expires;
  the clock guard rejects dates outside `2025..2035` (past **and** future).
- `routeros/config.example.rsc` — new tunables: `monitorInterval`,
  `failureThreshold`, `recoveryThreshold`, `enforcement`.
- `docs/architecture.md`, `README.md`, `docs/troubleshooting.md`,
  `docs/verification.md` — the state machine, thresholds, vendor coupling
  (fallback is a different operator) and the `device-mode=home` diagnostics.
- Documentation brought up to the 0.2.0 code: the five translated READMEs
  (`README.ru.md`, `README.de.md`, `README.zh.md`, `README.hi.md`,
  `README.es.md`) were written before the 0.2.0 changes landed and still
  described the Family default and a plain-DNS fallback; they are rewritten
  against the same facts as `README.md`.
- `AGENTS.md` rewritten for 0.2.0: the verification table no longer expects
  `$DNSCurrentMode` (the global does not exist any more), the state-test
  described as `[:typeof $ip] = "ip"` is replaced by the content check, and the
  pinned ref moved from `v0.1.0` to `v0.2.0`.
- Wiki pages updated for 0.2.0: failover is DoH to DoH, the health check judges
  answer content, and the Zabbix fleet monitoring has its own page.
- `SECURITY.md`: supported version is v0.3.1 (tagged 2026-10-28).

### Fixed
- `routeros/05-dns-health-monitor.rsc` — **recovery flapping**: the monitor used
  to switch back to the primary as soon as the *fallback* answered, without
  checking that the primary was reachable again, so a primary that stayed down
  caused an A↔B flap. Recovery is now gated on `probeA == "ok"`.
- `CHANGELOG.md`: the 0.2.0 section claimed six Zabbix triggers; the setup script
  creates five (`TRIGGERS` in `zabbix/doh-zabbix-setup.py`). The `AGENTS.md` and
  social-preview entries of v0.1.0 that had drifted under the 0.2.0 heading are
  back in their own release.

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
- `docs/verification.md` — 0.2.0 checklist (eight scenarios: failover, rollback,
  stub pair, clock guard) and the re-verified results on RouterOS 7.23.1.
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
- `AGENTS.md` — agent-facing operational contract: fetch, apply, verify and roll back
  on RouterOS, with the measured expected outputs and the deliberate limits.
- `assets/social-preview.png` (1280x640) — README header banner and repository
  social preview, and the banner is now embedded in `README.md` under the badges.

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

[Unreleased]: https://github.com/paulmann/mikrotik-doh-failover/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/paulmann/mikrotik-doh-failover/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/paulmann/mikrotik-doh-failover/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/paulmann/mikrotik-doh-failover/compare/v0.2.0...v0.3.1
[v0.2.0]: https://github.com/paulmann/mikrotik-doh-failover/compare/v0.1.0...v0.2.0
[v0.1.0]: https://github.com/paulmann/mikrotik-doh-failover/releases/tag/v0.1.0
