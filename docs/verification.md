# Verification

Commands to confirm each subsystem, then a test checklist for the failover.

## Per-subsystem checks

```rsc
# CA trusted
/certificate print where trusted=yes
#   expect: "SSL.com TLS ECC Root CA 2022" with trusted=yes

# DoH + bootstrap
/ip dns print
/ip dns static print where comment~"DoH bootstrap"
#   expect (0.2.0 defaults): servers=1.1.1.1,1.0.0.1;
#           use-doh-server=...cloudflare-dns.com...; verify-doh-cert=yes
#           two pinned addresses for cloudflare-dns.com AND two for dns.google

# clock (the monitor refuses to act on a wrong year)
/system clock print
#   expect: the current date

# NTP
/system ntp client print
#   expect: status: synchronized

# force-DNS + firewall
/ip firewall nat print where comment~"force DNS"
/ip firewall filter print where comment~"DNS"

# answers are real, not a stub pair (see §6.10 of troubleshooting)
/ip dns cache flush
:put [:resolve example.com]     # 104.20.x / 172.66.x = real
                                # 8.6.112.0 / 8.47.69.0 = stub pair
:put [:resolve pornhub.com]     # filtering resolvers: 0.0.0.0; standard: a real IP

# endpoint answers at all (does not touch /ip dns, no temp file)
:local r [/tool fetch url="https://cloudflare-dns.com/dns-query?name=example.com&type=A" \
    http-header-field="accept: application/dns-json" mode=https as-value output=user]
:put ($r->"status")                            # finished
:put ([:find ($r->"data") "\"Status\":0"])     # >= 0
```

DoH errors are visible in the log:

```rsc
/log print where message~"connection error"
/log print where message~"DNS monitor"
```

## Failover test checklist (0.4.0)

Run each step and confirm the expected result. The monitor can be executed by
hand with `/system script run DNS_HealthMonitor_Failover`. With the hysteresis a
failover needs `failureThreshold` (2) consecutive bad runs and the return needs
`recoveryThreshold` (2) consecutive good runs, so the transitions below
deliberately run the monitor more than once. Reset the state globals first to see
each transition logged:

```rsc
:global DNSMonitorState; :set DNSMonitorState ""
:global DNSFailCount; :set DNSFailCount 0
:global DNSRecoverCount; :set DNSRecoverCount 0
:global DNSFailoverAttempts; :set DNSFailoverAttempts 0
:global DNSMonitorRunning; :set DNSMonitorRunning false
```

| # | Scenario | Setup | Expected |
|---|---|---|---|
| 1 | normal | DoH configured, answers real | state `healthy`, log `HEALTHY: answers look sane …` (once) |
| 2 | single blip | break the primary, run the monitor **once** | state `suspect`, log `SUSPECT: primary unreachable (1/2)` — **no** failover yet (anti-flap) |
| 3 | two bad runs | run the monitor a second time | state `fallback`, log `FALLBACK: switched to fallback DoH …`, `use-doh-server` = fallback |
| 4 | stub pair | resolver returns `8.6.112.0`/`8.47.69.0` | state `stub`, log `STUB: answers are the stub pair …`, **no** failover |
| 5 | both down | primary and fallback both unreachable | state `degraded`, log `DEGRADED: both endpoints unreachable …`, `use-doh-server` unchanged |
| 6 | fallback answers but does not resolve | fallback host has no trusted CA | log `DEGRADED: fallback DoH did not resolve either — rolled back`; `use-doh-server` back to the primary |
| 7 | recovery, first run | restore the primary, run the monitor once | state `recovering`, log `RECOVERING: primary answers again (1/2)` — still on the fallback |
| 8 | recovery, second run | run the monitor again | state `healthy`, log `HEALTHY: primary DoH answers again …` |
| 9 | wrong clock | set the year back, run monitor | log `CLOCK_INVALID: clock looks wrong …`, nothing else |
| 10 | device-mode home | run the monitor on a `home` device | log `MONITOR_DISABLED_BY_DEVICE_MODE …`, state `manual-only` |
| 11 | CAPsMAN clients | rejoin a client | client gets the router as DNS and resolves through it |
| 12 | concurrency guard | `:global DNSMonitorRunning; :set DNSMonitorRunning true`, run the monitor | log `DNS monitor: skipped — a previous run is still active`, state unchanged |
| 13 | plain-DNS last resort | set `plainFallback=true`, break the primary, secondary and tertiary, run the monitor twice | log `PRIVACY DEGRADED: all DoH endpoints unreachable — switched to plain DNS`, state `plain`; on the `home` device the plain step is skipped (`manual-only`) |

Restore after each destructive test:

```rsc
/ip dns set use-doh-server="https://cloudflare-dns.com/dns-query" verify-doh-cert=yes
/ip dns cache flush
:global DNSMonitorState; :set DNSMonitorState ""
:global DNSFailCount; :set DNSFailCount 0
:global DNSRecoverCount; :set DNSRecoverCount 0
:global DNSFailoverAttempts; :set DNSFailoverAttempts 0
:global DNSMonitorRunning; :set DNSMonitorRunning false
```

## device-mode `home`

On `home` devices `/tool fetch` returns `not allowed by device-mode` and
`/system scheduler add` is rejected. Verify DoH there with `ping <domain>` and
`/ip dns cache print` instead, and run the monitor by hand. Note that without
`fetch` the probe cannot run: the monitor then reports both endpoints
unreachable and keeps the current configuration.

## Verified results

### 0.2.0 — re-verified 2026-10-26 on RouterOS 7.23.1 (hAP ax², test box)

| Check | Command | Observed |
|---|---|---|
| script imports | `/import file-name=05-dns-health-monitor.rsc` | `Script file loaded and executed successfully`; script + scheduler created |
| scheduler policy | `/system scheduler print detail` | `policy=read,write,policy,test` (v1 created it with the full default set) |
| JSON probe | `/tool fetch url="…/dns-query?name=example.com&type=A" …` | `code 200`, body 251 bytes, `"Status":0` found by `:find` |
| content check | monitor run, resolver answering | `answers look sane (N of 3)` / `answers are the stub pair …` |
| failover | primary set to `https://192.0.2.1/dns-query` | switched to the fallback, `example.com -> 8.6.112.0`, `use-doh-server` = fallback |
| rollback | primary and fallback both unreachable | `both endpoints unreachable — keeping the current configuration`; configuration untouched |
| clock guard | wrong year in `/system clock` | `clock looks wrong (…)` and no further action |
| Quad9 JSON | `curl https://dns.quad9.net/dns-query?name=example.com&type=A` | `DoH unable to decode BASE64-URL` — not probeable (§6.12) |

### 0.1.0 — fleet baseline recorded 2026-10-22 (RouterOS 7.23.1 / 7.24.5)

Kept for comparison; note the last row, which 0.2.0 turned into a documented
finding rather than "normal".

| Check | Command | Observed |
|---|---|---|
| CA import | `/certificate import file-name=cacert.pem` | 118 CAs imported; `trusted=yes` set |
| CA required | untrust all imported CAs, `:resolve example.com` | `failure: dns server failure` — import is mandatory |
| builtin store | `/certificate settings set builtin-trust-anchors=trusted` | `bad parameter` — the parameter is `builtin-trust-store` |
| family filter | `:resolve pornhub.com` | `0.0.0.0` on all five devices |
| `:resolve server=` | `:resolve cloudflare.com server=1.1.1.3` | `104.16.132.229` (supported) |
| `:resolve timeout=` | `:resolve cloudflare.com timeout=5s` | `bad parameter timeout` (not supported) |
| bootstrap | `/ip dns static print where name="family.cloudflare-dns.com"` | `1.1.1.3` / `1.0.0.3` |
| DoH resolve | `:resolve example.com` | `8.6.112.0` / `8.47.69.0` — recorded as "real IP" in 0.1.0; it is the stub pair, see troubleshooting §6.10 |
