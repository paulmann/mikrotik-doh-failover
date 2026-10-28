# v0.3.1 — Hardened failover monitor

This release makes the DoH failover monitor operationally robust: an explicit
state machine with hysteresis, a failover driven by endpoint health (no delay
from the DNS cache), a concurrency guard against overlapping scheduler runs, a
clock-range guard, and a fix for a recovery flap. It is the first release since
`v0.2.0`; `main` was at 0.3.1 when the tag was cut.

## Added

- `routeros/02-security-policies.rsc` — `enforcement=strict` mode: blocks DoT
  (TCP 853) and the well-known public DoH endpoints (address-list `public-doh`),
  with the residual risk documented instead of hidden.
- `routeros/05-dns-health-monitor.rsc` — explicit state machine
  (`HEALTHY → SUSPECT → FALLBACK → RECOVERING → HEALTHY`, plus `STUB`,
  `DEGRADED`, `CLOCK_INVALID`, `MANUAL-ONLY`), logged with UPPERCASE tags.
- `routeros/05-dns-health-monitor.rsc` — `monitorInterval` (60 s default),
  `failureThreshold` and `recoveryThreshold` (both 2) as the anti-flap hysteresis.
- `routeros/config.example.rsc` — the new tunables (`monitorInterval`,
  `failureThreshold`, `recoveryThreshold`, `enforcement`).
- `docs/release-notes-v0.3.1.md` (this file).

## Changed

- Failover is now driven by **endpoint health** (`probeA`) together with the
  content check, not by the content check alone. A primary that dies while the
  cache still holds valid answers is detected before the cache TTL expires.
- The scheduler interval is configurable (was a hardcoded 3 m; 60 s default).
- `device-mode=home` is diagnosed explicitly: the monitor logs
  `MONITOR_DISABLED_BY_DEVICE_MODE` and enters `manual-only` instead of reporting
  "both endpoints unreachable".
- Wording: **managed failover**, not transparent — the fallback is a different
  operator, so answers, filtering and geo behaviour may change on a switch.
- Documentation (`README`, `AGENTS.md`, `SECURITY.md`, `docs/architecture.md`,
  `docs/verification.md`, the five translated READMEs, the wiki) brought up to
  0.3.1.

## Fixed

- **Recovery flapping**: the monitor used to switch back to the primary as soon
  as the *fallback* answered, without checking that the primary was reachable,
  so a primary that stayed down caused an A↔B flap. Recovery is now gated on
  `probeA == "ok"`.
- **Concurrency guard**: an overlapping scheduler run is skipped, and the flag is
  cleared in an `on-error` handler, so a crashed run cannot lock the monitor.
- **Clock range**: dates outside `2025..2035` are rejected — a future date passes
  a "year < 2025" check but still breaks `verify-doh-cert`.

## Upgrade

```rsc
/import file-name=02-security-policies.rsc
/import file-name=05-dns-health-monitor.rsc
:global DNSMonitorState; :set DNSMonitorState ""
:global DNSFailCount; :set DNSFailCount 0
:global DNSRecoverCount; :set DNSRecoverCount 0
:global DNSFailoverAttempts; :set DNSFailoverAttempts 0
:global DNSMonitorRunning; :set DNSMonitorRunning false
```

The key, configuration, queue and data are preserved; only the two scripts are
re-imported.

## Known limitations

- Automatic scheduler execution requires `device-mode=advanced`; on `home`
  devices the monitor runs manually only.
- Client DoH/DoT is not blocked by the default; `enforcement=strict` blocks DoT
  (853) and known public DoH endpoints, but client DoH over arbitrary HTTPS/443
  needs a proxy/DPI.
- A Quad9 fallback cannot be probed with the DNS-JSON API (`docs/troubleshooting.md`
  §6.12); use Google or change `probeUrlB`.

Full changelog: [CHANGELOG.md](../CHANGELOG.md).
