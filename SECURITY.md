# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| `main` (0.3.1, unreleased) | yes — explicit state machine, hysteresis thresholds, concurrency guard, endpoint-driven failover |
| v0.2.0 (tag `v0.2.0`, 2026-10-26) | yes — last tagged release |
| v0.1.0 | no — the health check there accepted the stub pair `8.6.112.0`/`8.47.69.0` as a healthy answer and fell back to plain DNS |

## Reporting a vulnerability

Do **not** open a public issue. Use GitHub Security Advisories ("Report a
vulnerability" on the repository's Security tab) or contact the maintainer.

Include:

- affected RouterOS version and the script/step;
- reproduction steps or a proof of concept;
- impact (DNS leak, bypass of the family filter, denial of service, privilege escalation);
- whether the issue is already public.

You will receive an acknowledgement and a remediation plan. Please allow time
for a fix before disclosure.

## What must never be committed

API keys, tokens, passwords, private keys, `.env` files, router configuration
exports that contain secrets (WireGuard private keys, pre-shared keys, user
passwords) and customer data.

## Security model of this project

- The scripts import a CA **explicitly**; they never use `check-certificate=no`
  in a persistent configuration (bootstrap-only at most).
- Since 0.2.0 the failover never falls back to plain DNS: measured substitution
  on the path makes a plain fallback a silent outage. Both endpoints are DoH.
- Since 0.3 the monitor fails over on **endpoint health** (not only on the
  content check), so a primary that dies while the cache still holds answers is
  detected before the cache expires. The monitor is guarded against overlapping
  scheduler runs (a global flag cleared in `on-error`), and it refuses to act on
  a clock date outside `2025..2035` (past **and** future break certificate
  validation).
- Script policies are narrowed to `read,write,policy,test`; the failover script
  does not carry `ftp`, `reboot`, `password`, `sniff`, `sensitive` or `romon`.
- The resolver drops DNS from WAN and only redirects classic DNS (53). Client
  DoH/DoT bypass is documented, not silently ignored.
