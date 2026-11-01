# Release notes — 0.4.2 (2026-11-02)

## Why this release exists

A healthy resolver can still hand out addresses that open nothing. Measured 2026-11-02 on one
network: the same DoH URL, with the same certificate, answered honestly from a host whose
DNS left through an encrypted tunnel and returned the stub pair from the router itself.
The substitution is on the router's path, not at the resolver — and it is unstable, so one
successful probe proves nothing.

Two consequences shaped 0.4.2:

* a probe that only looks at `"Status":0` calls a substituted answer `ok`;
* a probe that insists on DNS-JSON calls a self-hosted endpoint `bad-status` and pushes
  the router onto a public fallback, where the substitution happens.

## What changed

| Area | Before | Now |
|---|---|---|
| Probe verdict | `ok` / `bad-status` / `unreachable` | plus `substituted` — stub prefixes found in the payload |
| Own endpoint | JSON probe reported it as dead | `probeMode "resolve"`: liveness from live-answer quality, no external request |
| `STUB` state | declared immediately | one cache flush + re-check first (`STUB_CLEARED` when the stub was cached) |
| `STUB` message | "switching the resolver does not help" | states the path is intercepted and points at the remedy |

## Upgrade

```
/file remove [find where name="05-dns-health-monitor.rsc"]
# upload the new file, then:
/import file-name=05-dns-health-monitor.rsc
# for a self-hosted endpoint:
/system script set [find name="DNS_HealthMonitor_Failover"] source=[/file get "05-dns-health-monitor.rsc" contents]
```

Then set `probeMode` and `dohUrlA` in the script's CONFIG block. Nothing else changes:
the state machine, thresholds and the plain-DNS reserve are the same as 0.4.1.

## Verification

See `docs/verification.md` → "0.4.2 — re-verified 2026-11-02". The checks include a
substituted payload being reported as `substituted`, the `STUB_CLEARED` path, and three
consecutive runs with `applyChanges=false` leaving `/ip dns` untouched.
