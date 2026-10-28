# v0.4.1 — Hard timeout, symmetric tertiary, plain→DoH recovery

A small hardening release on top of 0.4.0. It adds a hard timeout to every probe
fetch, makes the tertiary switch as safe as the secondary (verify after switch
with rollback), keeps the failover attempt counter consistent across the whole
chain, and lets the monitor climb back from plain DNS to any DoH endpoint instead
of waiting only for the primary.

## Changed

- Every `/tool fetch` probe now carries `duration=5s` (verified on RouterOS
  7.23.1), so a hung endpoint cannot block the run past the scheduler interval.
- The tertiary switch now does probe-before + verify-after-switch + rollback, the
  same as the secondary: if `dohUrlC` is reachable but does not resolve, the
  monitor rolls back to the primary instead of parking on a broken tertiary.
- `DNSFailoverAttempts` now increments on every real switch — secondary, tertiary
  and plain — so the counter and `maxAttempts` reflect the whole chain, not just
  the first fallback.

## Fixed

- Recovery from the plain fallback no longer waits only for the primary. If the
  primary is still down but the secondary answers, the monitor climbs back to DoH
  (clearing `servers`), because DoH — any DoH — is better than plain DNS.

## Upgrade

```rsc
/import file-name=05-dns-health-monitor.rsc
:global DNSMonitorState; :set DNSMonitorState ""
:global DNSFailCount; :set DNSFailCount 0
:global DNSRecoverCount; :set DNSRecoverCount 0
:global DNSFailoverAttempts; :set DNSFailoverAttempts 0
:global DNSMonitorRunning; :set DNSMonitorRunning false
```

## Known limitations

- Climb is "up" (towards a better endpoint), not full re-prioritisation: the
  monitor climbs from plain to any DoH endpoint, and from a fallback back to the
  primary, but does not track "on secondary" vs "on tertiary" separately to hop
  sideways. Strict priority (always prefer the primary) is preserved.
- Only DNS-JSON providers (Cloudflare, Google) can be probed; Quad9 cannot be a
  chained endpoint while the JSON probe is used.

Full changelog: [CHANGELOG.md](../CHANGELOG.md).
