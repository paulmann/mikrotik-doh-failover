# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-22

Initial release.

### Added
- `routeros/00-install-ca.rsc` — install and trust the DoH CA.
- `routeros/01-configure-doh.rsc` — single DoH upstream + bootstrap static A records.
- `routeros/02-security-policies.rsc` — force-DNS (redirect 53) + resolver protection.
- `routeros/03-capsman.rsc` — targeted CAPsMAN/DHCP integration.
- `routeros/04-cert-update.rsc` — optional CA refresh.
- `routeros/05-dns-health-monitor.rsc` — health-check + failover script and scheduler.
- `docs/architecture.md`, `docs/verification.md`, `docs/troubleshooting.md`.
- Mermaid diagrams under `diagrams/`.
- `certs/cloudflare-doh-ca.pem` (SSL.com TLS ECC Root CA 2022).

### Verified against
- RouterOS **7.23.1** (RB2011UiAS) and **7.24.5** (Chateau PRO ax, RB4011iGS+,
  hAP ax², RB951Ui, cAP ax).
- Cloudflare Family DoH (`family.cloudflare-dns.com`, 1.1.1.3 / 1.0.0.3).

### Notes for RouterOS changes
- `7.20+`: `use-doh-server` is the single DoH path; no native backup DoH.
- `7.23/7.24`: `/certificate settings` exposes `builtin-trust-store` (default),
  **not** `builtin-trust-anchors`; the builtin store does not cover the
  Cloudflare DoH chain, so the CA import in `00-install-ca.rsc` is mandatory.
