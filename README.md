# mikrotik-doh-failover

Reproducible, versioned RouterOS configuration for **failover DNS-over-HTTPS (DoH)** on MikroTik.

This repository is the "how to reproduce and maintain" companion to the article
[«Архитектура отказоустойчивого DNS-over-HTTPS в RouterOS»](https://sysadministrator.ru/%d0%b0%d1%80%d1%85%d0%b8%d1%82%d0%b5%d0%ba%d1%82%d1%83%d1%80%d0%b0-%d0%be%d1%82%d0%ba%d0%b0%d0%b7%d0%be%d1%83%d1%81%d1%82%d0%be%d0%b9%d1%87%d0%b8%d0%b2%d0%be%d0%b3%d0%be-dns-over-https-%d0%b2-routeros/)
(on `sysadministrator.ru`). The article explains *why* the design is the way it
is; this repo holds the *diffable, testable* `.rsc` scripts, diagrams, a test
checklist and a changelog.

## What the system does

| Component | What it provides |
|---|---|
| `routeros/00-install-ca.rsc` | Trust anchor for `verify-doh-cert=yes` |
| `routeros/01-configure-doh.rsc` | One DoH upstream + plain bootstrap/fallback |
| `routeros/02-security-policies.rsc` | Force classic DNS to the router, protect the resolver |
| `routeros/03-capsman.rsc` | Targeted CAPsMAN/DHCP integration (legacy stack) |
| `routeros/04-cert-update.rsc` | Optional CA refresh (usually not needed) |
| `routeros/05-dns-health-monitor.rsc` | Health-check + automatic failover to plain DNS |

> **Honest scope.** The design encrypts the router→provider DNS path through a
> **single** DoH upstream, monitors its health and, on failure, temporarily
> switches to plain family DNS. The `02-security-policies.rsc` rules redirect
> classic DNS (UDP/TCP 53) from the LAN to the router, but they do **not**
> prevent a client from using its own DoH/DoT or hardcoded resolvers. That
> requires additional block policies (TCP/853, address lists) or a proxy/DPI.

## Requirements

- RouterOS **7.20+** (tested on 7.23.1 and 7.24.5).
- NTP synchronized — certificate validation needs an accurate clock:
  `/system ntp client set enabled=yes servers=162.159.200.1,216.239.35.0`.
- `device-mode` other than `home` if you want the failover **scheduler**
  (`home` blocks `/tool fetch` and `/system scheduler`; the scripts and
  force-DNS still work, but the monitor must be run by hand).

## Quick start (Cloudflare Family)

1. Upload `certs/cloudflare-doh-ca.pem` to the router (WinBox → Files, or scp/SFTP).
2. `import routeros/00-install-ca.rsc`  — import and trust the CA.
3. `import routeros/01-configure-doh.rsc` — set DoH + bootstrap.
4. `import routeros/02-security-policies.rsc` — force-DNS + firewall (gateways).
5. `import routeros/05-dns-health-monitor.rsc` — failover script + scheduler.

Verify:

```rsc
/ip dns cache flush
:put [:resolve example.com]     # real IP
:put [:resolve pornhub.com]     # 0.0.0.0 with the Family filter
```

For other providers (Quad9, Google, Cloudflare standard/security) edit the
values in `routeros/config.example.rsc`.

## Repository layout

```text
mikrotik-doh-failover/
├── README.md
├── LICENSE
├── CHANGELOG.md
├── docs/
│   ├── architecture.md       # full design rationale
│   ├── verification.md       # commands + test checklist
│   └── troubleshooting.md    # known failures and workarounds
├── diagrams/                 # Mermaid sources
├── routeros/                 # one logical block per .rsc file
├── certs/                    # Cloudflare DoH CA (SSL.com TLS ECC Root CA 2022)
└── examples/                 # provider-specific configs
```

## Known limitations & risks

- **Single DoH upstream.** RouterOS supports one `use-doh-server`. There is no
  native "backup DoH" — fallback is the plain `servers` list plus the failover
  script. Do not use `/ip dns static-server type=doh` as a backup; that is not
  a real mechanism.
- **Bootstrap dependency.** The router must resolve the DoH hostname first.
  The scripts pin it with a static A record (`01-configure-doh.rsc`); keep those
  records in sync with the provider's current addresses.
- **Third-party trust.** Choosing Cloudflare/Quad9/Google means trusting that
  provider with your DNS queries. DoH hides the queries from the local link but
  does not make the resolver trustworthy by itself.
- **CA bootstrap.** Download the CA over a trusted channel and verify its
  fingerprint; `check-certificate=no` is acceptable only for a one-time
  bootstrap and must not stay in a permanent config.
- **Static DNS overrides.** `/ip dns static` entries take precedence over the
  DoH answer and can silently defeat the family filter for a specific domain.

## Contributing

Found an incompatibility with another RouterOS build or a different provider?
Open an **issue** or a pull request. Report the RouterOS version, the exact
error from `/log print where message~"connection error"`, and a sanitized
`/ip dns print`.

## License

MIT — see [LICENSE](LICENSE).
