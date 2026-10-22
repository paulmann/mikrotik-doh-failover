# v0.1.0 — Initial tested release

Initial public release of the RouterOS DoH failover configuration.

Tested on RouterOS 7.23.1 and 7.24.5 (also targets 7.20.6+). Includes one
active DoH upstream, a conventional plain-DNS fallback, a scheduled health-check
failover, bootstrap DNS records and a targeted CAPsMAN example.

## Added

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

## Fixed

- Removed the invalid `static-server type=doh` "backup DoH" mechanism; replaced
  with a single active DoH upstream plus a managed plain-DNS fallback.
- Replaced `dst-nat to-addresses=<router-ip>` force-DNS with `action=redirect`.
- Narrowed script policies to `read,write,policy,test`.
- Corrected CA guidance: `builtin-trust-store=default` does not cover the
  Cloudflare chain on 7.23/7.24, and `builtin-trust-anchors` is not a parameter.

## Known limitations

- Automatic scheduler execution requires `device-mode=advanced`; on `home`
  devices the monitor runs manually only.
- Client DoH/DoT is not blocked; classic DNS (53) is redirected.

Full changelog: [CHANGELOG.md](../CHANGELOG.md).
