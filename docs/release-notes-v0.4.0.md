# v0.4.0 — In-memory probe, ordered DoH chain, optional plain fallback

This release hardens the monitor's probe and extends the failover from a single
fallback to an ordered chain. The probe no longer writes to `/file`, the failover
can try a tertiary DoH endpoint and — if explicitly enabled — a plain-DNS last
resort, and the JSON check tolerates both `"Status":0` and `"Status": 0`.
`plainFallback` is **off by default**.

## Added

- **Ordered failover chain** (primary → secondary → tertiary → plain): the
  tertiary endpoint is `dohUrlC` (empty disables it); the plain-DNS step is
  `plainFallback` (off by default) and logs `PRIVACY DEGRADED`.
- **`plain` state** with recovery back to the primary once it answers again.
- New tunables in `routeros/config.example.rsc`: `dohUrlC`, `probeUrlC`,
  `plainFallback`, `plainServers`.
- `docs/release-notes-v0.4.0.md` (this file).

## Changed

- **The endpoint probe now runs in memory**: `/tool fetch ... as-value
  output=user` returns the JSON body in `$r->"data"`, so the monitor creates no
  temporary files in `/file` and cannot leave stale ones behind. Verified on
  RouterOS 7.23.1.
- The JSON check accepts both `"Status":0` and `"Status": 0`.
- Documentation (`README`, `AGENTS.md`, `SECURITY.md`, `docs/architecture.md`,
  `docs/verification.md`, `docs/troubleshooting.md`, the five translated READMEs,
  the wiki) brought up to 0.4.0.

## Upgrade

```rsc
/import file-name=05-dns-health-monitor.rsc
:global DNSMonitorState; :set DNSMonitorState ""
:global DNSFailCount; :set DNSFailCount 0
:global DNSRecoverCount; :set DNSRecoverCount 0
:global DNSFailoverAttempts; :set DNSFailoverAttempts 0
:global DNSMonitorRunning; :set DNSMonitorRunning false
```

No change is required on the router: `dohUrlC` and `plainFallback` default to
disabled, so the behaviour on an existing 0.3.x setup is unchanged until you set
them.

## Known limitations

- Only DNS-JSON providers can be probed: Cloudflare and Google. Quad9 answers
  `DoH unable to decode BASE64-URL` to the JSON GET, so it cannot be a chained
  endpoint while the JSON probe is used.
- `netwatch type=https-get` was evaluated and rejected: on 7.23.1 it requires an
  **IP** host (a hostname gives `failure: IPv4 or IPv6 host expected`), which
  breaks SNI/certificate validation, and it carries no path/header support, so it
  cannot check the DoH JSON response. The `as-value` probe covers liveness, TLS
  and the JSON status in one call.
- Automatic scheduler execution still requires `device-mode=advanced`; on `home`
  devices the monitor runs manually only.

Full changelog: [CHANGELOG.md](../CHANGELOG.md).
