# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org/).

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
