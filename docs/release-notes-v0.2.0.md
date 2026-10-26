# Release notes — v0.2.0

**Date:** 2026-10-26. **Verified on:** RouterOS 7.23.1 (hAP ax²), plus field
checks against 7.24.5.

## Why this release exists

While deploying this project to a branch network, a page that had worked for
weeks stopped opening — and the resolver looked perfectly healthy. The cause was
not the router and not the filter: Cloudflare answered with the pair
`8.6.112.0` / `8.47.69.0`, and that pair has no path from some networks. v1's
health check treated any valid IP as healthy, so the outage was invisible.

Measurements behind the change (2026-10-26, three vantage points):

| Query | Answer |
|---|---|
| DoH, standard endpoint, from a Russian ISP | `104.26.x` at first, `8.6.112.0`/`8.47.69.0` about 30 minutes later |
| DoH, Family endpoint, same vantage | `8.6.112.0` / `8.47.69.0` |
| plain DNS to 1.1.1.1 and 8.8.8.8, same vantage | the same pair (Google answered `8.6.112.5`) |
| the same questions from Germany | `104.26.x`, `172.66.x` |
| `curl --resolve …:8.6.112.0` from the gateway WAN | `200` with a valid certificate |
| the same from a branch network behind another ISP | connection timeout |

So the pair is real, is served by Cloudflare, and is simply unreachable from some
networks. Switching resolvers does not fix it; reaching the addresses does.

## What changed

1. **Default upstream is the standard resolver** (`cloudflare-dns.com`,
   1.1.1.1/1.0.0.1). Filtering stays available as an opt-in; it is no longer the
   default and no longer presented as the safe choice.
2. **Failover is DoH → DoH.** Plain DNS is bootstrap only. Measured plain
   answers in Russia are substituted, so falling back to plain DNS turned a
   visible outage into a silent one.
3. **The health check judges answers, not types.** Three canaries; empty,
   `0.0.0.0` and the stub pair all count as unusable.
4. **The check no longer disturbs the resolver.** Both endpoints are probed with
   `/tool fetch` against their DNS-JSON API instead of flipping
   `use-doh-server`.
5. **Failover is verified and reversible.** The fallback is probed before the
   switch, the switch is verified after it, and a failed attempt is rolled back —
   the router is never left on a dead endpoint. Attempts are capped per outage.
6. **Clock guard.** With a wrong date `verify-doh-cert` can never succeed; the
   monitor now says so instead of reporting "DoH down" forever.
7. **Narrow scheduler policy** (`read,write,policy,test`).
8. **Documentation**: new troubleshooting sections §6.10–§6.12, a rewritten
   verification checklist, a corrected architecture document and failover diagram,
   and the 0.1.0 note that recorded `8.6.112.0` as "real IP" is corrected.

## Upgrading from 0.1.0

```rsc
# 1. New scripts
/import file-name=01-configure-doh.rsc     # now standard resolver + dual bootstrap
/import file-name=05-dns-health-monitor.rsc
# 2. If you keep Family on purpose, set filtering=true in 05 and use
#    examples/cloudflare-family.rsc values instead.
# 3. Clear the old state globals so the new monitor logs its transitions
:global DNSMonitorState; :set DNSMonitorState ""
:global DNSFailoverAttempts; :set DNSFailoverAttempts 0
```

The old global `DNSCurrentMode` is no longer used and can be unset.

## Known limits

- The router cannot tell whether the stub pair is reachable from its LAN — that
  check must be done from a client (`curl --resolve`, see §6.10).
- Quad9 cannot be used as the fallback with the JSON probe; Google can.
- `device-mode=home` blocks `fetch`, so the monitor degrades to "keep the current
  configuration" there.
