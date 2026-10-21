# Troubleshooting

Field notes from deploying this on a fleet of RouterOS 7.23.1 / 7.24.5 devices
(Chateau PRO ax, RB4011iGS+, hAP ax², RB951Ui, cAP ax), ordered by frequency.

| Problem | Symptom | Fix |
|---|---|---|
| No trusted CA | `DoH server connection error: SSL: no trusted CA certificate found (6)` / `dns server failure` | import CA + `trusted=yes` |
| Wrong CA | `connection error` persists after import | Cloudflare = `SSL.com TLS ECC Root CA 2022` |
| NTP off/drifted | cert validation fails | enable NTP → `synchronized` |
| `device-mode=home` | `not allowed by device-mode` on fetch/scheduler | use `ping`, run monitor by hand |
| DoH down | resolution stops, `servers` do not help | failover script or `use-doh-server=""` |
| Static DNS | filter "leaks" specific domains | check `/ip dns static` |

## 6.1 No trusted CA — the network "drops"

`verify-doh-cert=yes` with no imported CA ends in a log error and a full stop of
resolution. **Verified:** the built-in trust store (`builtin-trust-store=default`)
does not cover the Cloudflare DoH chain, and `builtin-trust-anchors` is not a
parameter at all. Import the CA explicitly.

```rsc
/certificate import file-name=cloudflare-doh-ca.pem passphrase=""
/certificate set [find where name~"cloudflare-doh-ca"] trusted=yes
```

## 6.2 The Cloudflare CA cannot be guessed

Chain is `Cloudflare Inc → SSL.com → Comodo AAA`; the root is
`SSL.com TLS ECC Root CA 2022` — not DigiCert, not GlobalSign. For the Family
filter (1.1.1.3/1.0.0.3) there is a single endpoint:
`https://family.cloudflare-dns.com/dns-query`.

## 6.3 NTP off or drifted

Certificate validation needs an accurate clock. Use IP-based NTP servers so the
setup does not depend on DNS (chicken-and-egg):

```rsc
/system ntp client set enabled=yes servers=162.159.200.1,216.239.35.0
```

## 6.4 device-mode `home` blocks fetch and the scheduler

On `home` devices `/tool fetch` and `/system scheduler add` are rejected with
`not allowed by device-mode`. DoH and force-DNS still work. Verify with
`ping <domain>` + `/ip dns cache print`, and run the monitor manually; the only
way to automate is to switch the device to `advanced` (owner decision, reboot).

## 6.5 force-DNS: prefer `redirect`

`dst-nat to-addresses=<router-ip>` works but may be flagged `invalid`
(transiently). Use `action=redirect` — it rewrites to the local address of the
incoming interface and needs no hardcoded IP. A transient `I` flag right after
adding rules usually clears within seconds; re-read before deleting anything.

## 6.6 `/tool fetch` 400/405 is not "DoH down"

POSTing to `/dns-query` without a valid DNS-JSON body returns `400`, GET returns
`405`. Both mean the TLS handshake and certificate validation succeeded — the
endpoint is alive. Prefer `:resolve` for health checks:

```rsc
:put [:resolve cloudflare.com]                # real path (DoH)
:put [:resolve cloudflare.com server=1.1.1.3] # direct plain query, bypasses DoH
```

Note: `:resolve ... server=` **is** supported (verified on 7.23.1/7.24.5);
`:resolve ... timeout=` is not.

## 6.7 `use-doh-server` is the only path

With `use-doh-server` set, RouterOS does **not** fall back to `servers` on
failure — resolution stops. That is exactly why the failover script exists, or
restore by hand:

```rsc
/ip dns set use-doh-server=""
/ip dns cache flush
```

## 6.8 Static DNS overrides the filter

`/ip dns static` entries take precedence over the DoH answer. A pinned domain
will bypass the family filter. Example: `:resolve pornhub.com` returns a real IP
on one device while neighbours return `0.0.0.0`.

```rsc
/ip dns static print
/ip dns cache print where name~"pornhub"
```

The same property is useful in reverse: pin internal split-horizon names, or
block domains with `type=NXDOMAIN`.

## 6.9 ISP dynamic servers

A WAN DHCP may inject `dynamic-servers` into `/ip dns print`. They are not used
while `use-doh-server` is set, but they confuse diagnostics. Confirm facts with
commands, not assumptions.
