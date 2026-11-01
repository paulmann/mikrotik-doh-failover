# Release notes — 0.4.3 (2026-11-02)

## Why this release exists

0.4.2 made the probe judge a self-hosted endpoint by answer quality (`probeMode "resolve"`).
One path was left on the old rule: before switching to the fallback endpoint, the monitor
still asked the fallback over DNS-JSON. A self-hosted endpoint answers that request with
`400 Bad Request` — it serves wire format only — so `probeB` stayed `bad` and the switch
never happened. A dead primary therefore stayed in place while a working reserve sat idle.

Measured: with the primary endpoint stopped, `/ip dns` kept the dead upstream and
`:resolve` returned `failure` for the whole observation window.

## What changed

| Area | Before | Now |
|---|---|---|
| Fallback probe in resolve mode | DNS-JSON request, always `bad` for a self-hosted endpoint | not probed; the monitor switches and verifies by `:resolve` after the switch |
| Fallback probe in JSON mode | only `Status: 0` | also reports `substituted` when the payload carries a stub address |
| Documentation | — | running a reserve endpoint on a separate host, with the `dnsdist 2.x` HTTP/2 pitfall |

## Upgrade

Re-import `routeros/05-dns-health-monitor.rsc` (or set the script source from the file).
Nothing else changes: thresholds, states and the plain-DNS reserve stay as in 0.4.2.

## Verification status — read this

The switch itself could **not** be observed on the live router: with the primary stopped,
the monitor produced no log lines at all from that host, so the run could not be traced.
What is confirmed: the reserve endpoint answers correctly (`200`, honest addresses), the
access list rejects an address removed from it (`403`), and clients receive honest answers
through the primary. Treat the automatic switch as verified by code inspection, not by a
field test — see `docs/verification.md`.
