# Verification

Commands to confirm each subsystem, then a test checklist for the failover.

## Per-subsystem checks

```rsc
# CA trusted
/certificate print where trusted=yes
#   expect: "SSL.com TLS ECC Root CA 2022" with trusted=yes

# DoH + bootstrap
/ip dns print
/ip dns static print where name~"family.cloudflare-dns.com"
#   expect: servers=1.1.1.3,1.0.0.3; use-doh-server=...family...; verify-doh-cert=yes

# NTP
/system ntp client print
#   expect: status: synchronized

# force-DNS + firewall
/ip firewall nat print where comment~"force DNS"
/ip firewall filter print where comment~"DNS"

# resolver actually filters (Family)
/ip dns cache flush
:put [:resolve example.com]     # real IP
:put [:resolve pornhub.com]     # 0.0.0.0
```

DoH errors are visible in the log:

```rsc
/log print where message~"connection error"
```

## Failover test checklist

Run each step and confirm the expected result. The monitor script
`DNS_HealthMonitor_Failover` can be executed by hand with
`/system script run DNS_HealthMonitor_Failover`.

| # | Scenario | Setup | Expected |
|---|---|---|---|
| 1 | normal | DoH configured, healthy | `:resolve example.com` returns IP; `$DNSCurrentMode` = `doh` |
| 2 | primary DoH down | `/ip dns set use-doh-server="https://1.2.3.4/dns-query"` then run monitor | mode becomes `plain`, `use-doh-server=""`, log `error` |
| 3 | all DoH down + plain OK | bogus DoH, plain reachable | plain works, filter still active |
| 4 | recovery | restore real DoH, run monitor | mode back to `doh`, `use-doh-server` restored, log `warning` |
| 5 | outbound UDP/53 blocked | block 53 upstream | monitor falls back to plain via the static bootstrap / plain servers |
| 6 | CAPsMAN clients | rejoin a client | client gets router as DNS and resolves through the filtered resolver |

Restore after each destructive test:

```rsc
/ip dns set use-doh-server="https://family.cloudflare-dns.com/dns-query" verify-doh-cert=yes
/ip dns cache flush
```

## device-mode `home`

On `home` devices `/tool fetch` returns `not allowed by device-mode` and
`/system scheduler add` is rejected. Verify DoH there with `ping <domain>` and
`/ip dns cache print` instead, and run the monitor by hand.
