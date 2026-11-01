# Troubleshooting

Field notes from deploying this on a fleet of RouterOS 7.23.1 / 7.24.5 devices
(Chateau PRO ax, RB4011iGS+, hAP ax², RB951Ui, cAP ax, RB2011UiAS), ordered by
frequency.

| Problem | Symptom | Fix |
|---|---|---|
| No trusted CA | `DoH server connection error: SSL: no trusted CA certificate found (6)` / `dns server failure` | import CA + `trusted=yes` |
| Wrong CA | `connection error` persists after import | Cloudflare = `SSL.com TLS ECC Root CA 2022` |
| NTP off/drifted | cert validation fails | enable NTP → `synchronized` |
| `device-mode=home` | `not allowed by device-mode` on fetch/scheduler | use `ping`, run monitor by hand |
| DoH down | resolution stops, `servers` do not help | monitor switches to the fallback DoH endpoint |
| Static DNS | filter "leaks" specific domains | check `/ip dns static` |
| **Sites do not open, monitor says healthy** | resolution fine, CDNs time out | stub pair — §6.10 |
| Fallback never activates | log line `both endpoints unreachable` | the probe needs the endpoint hostname to resolve — add bootstrap records (§6.10) |

## 6.1 No trusted CA — the network "drops"

`verify-doh-cert=yes` with no imported CA ends in a log error and a full stop of
resolution. **Verified:** the built-in trust store (`builtin-trust-store=default`)
does not cover the Cloudflare DoH chain, and `builtin-trust-anchors` is not a
parameter at all. Import the CA explicitly.

```rsc
/certificate import file-name=cloudflare-doh-ca.crt passphrase=""
/certificate set [find where name~"cloudflare-doh-ca"] trusted=yes
```

## 6.2 The Cloudflare CA cannot be guessed

Chain is `Cloudflare Inc → SSL.com → Comodo AAA`; the root is
`SSL.com TLS ECC Root CA 2022` — not DigiCert, not GlobalSign. The same root
covers the standard endpoint (`cloudflare-dns.com`), Family (`family.cloudflare-dns.com`)
and Security (`security.cloudflare-dns.com`).

## 6.3 NTP off or drifted

Certificate validation needs an accurate clock. Use IP-based NTP servers so the
setup does not depend on DNS (chicken-and-egg):

```rsc
/system ntp client set enabled=yes servers=162.159.200.1,216.239.35.0
```

The 0.2.0 monitor checks the date before anything else and says so explicitly
(`clock looks wrong … certificate validation cannot succeed`), because otherwise
a wrong clock looks exactly like "DoH is down" and the monitor burns through
failover attempts forever.

## 6.4 device-mode `home` blocks fetch and the scheduler

On `home` devices `/tool fetch` and `/system scheduler add` are rejected with
`not allowed by device-mode`. DoH and force-DNS still work. Verify with
`ping <domain>` + `/ip dns cache print`, and run the monitor manually.

```rsc
/system script run DNS_HealthMonitor_Failover    # manual run
```

Note that without `fetch` the monitor cannot probe the endpoints. Since 0.3.0 it
detects this explicitly and logs once

```rsc
/log print where message~"MONITOR_DISABLED_BY_DEVICE_MODE"
#   MONITOR_DISABLED_BY_DEVICE_MODE: device-mode=home — /tool fetch and the
#   scheduler are unavailable; run the monitor by hand and expect no failover
```

and enters the `manual-only` state instead of reporting `unreachable` for both
endpoints as if it were a network fault.

To enable the scheduler, switch the device to `advanced` (owner decision,
then confirm and reboot):

```rsc
/system/device-mode/update device-mode=advanced
```

## 6.5 force-DNS: prefer `redirect`

`dst-nat to-addresses=<router-ip>` works but may be flagged `invalid`
(transiently). Use `action=redirect` — it rewrites to the local address of the
incoming interface and needs no hardcoded IP. A transient `I` flag right after
adding rules usually clears within seconds; re-read before deleting anything.

**Scope limit (measured 2026-10-26):** these rules do **not** touch clients that
already use the router as their resolver — the packet goes to the router's own
address and is answered locally, never reaching `dstnat`. So a "different
resolver for one workstation" built from dst-nat rules silently does nothing for
such a workstation. Check the client: `ipconfig /all` → `DNS Servers`.

## 6.6 A health check that only looks at the answer type is worthless

`:resolve <domain>` returning a value proves almost nothing: a substituted or
stub answer is still a valid IP. Two different questions, two commands:

```rsc
# 1. does the endpoint answer at all? (does not touch /ip dns, no temp file)
:local r [/tool fetch url="https://cloudflare-dns.com/dns-query?name=example.com&type=A" \
    http-header-field="accept: application/dns-json" mode=https as-value output=user]
:put ($r->"status")                            # finished
:put ([:find ($r->"data") "\"Status\":0"])     # >= 0
#   a 400/405 means the TLS handshake and certificate validation succeeded —
#   the endpoint is alive, only the request form was wrong

# 2. are the ANSWERS usable? (content, not type)
:put [:resolve example.com]        # 104.20.x / 172.66.x = real
                                   # 8.6.112.0 / 8.47.69.0 = stub pair, see §6.10
:put [:resolve pornhub.com]        # filtering resolvers only: 0.0.0.0
```

`:resolve ... server=` **is** supported (verified on 7.23.1/7.24.5);
`:resolve ... timeout=` is not.

## 6.7 `use-doh-server` is the only path

With `use-doh-server` set, RouterOS does **not** fall back to `servers` on
failure — resolution stops. That is why the monitor exists. Since 0.2.0 it
switches to a second **DoH** endpoint rather than to plain DNS, and rolls back
if the second one does not actually resolve.

Restore by hand if needed:

```rsc
/ip dns set use-doh-server="https://cloudflare-dns.com/dns-query" verify-doh-cert=yes
/ip dns cache flush
```

## 6.8 Static DNS overrides the filter

`/ip dns static` entries take precedence over the DoH answer. A pinned domain
will bypass the filter (and a pinned address will keep working after the provider
changes its own). Example: `:resolve pornhub.com` returns a real IP on one device
while neighbours return `0.0.0.0`.

```rsc
/ip dns static print
/ip dns cache print where name~"pornhub"
```

The same property is useful in reverse: pin internal split-horizon names, block
domains with `type=NXDOMAIN` — or pin a reachable address for a name whose DoH
answer is a stub pair (§6.10).

## 6.9 ISP dynamic servers

A WAN DHCP may inject `dynamic-servers` into `/ip dns print`. They are not used
while `use-doh-server` is set, but they confuse diagnostics. Confirm facts with
commands, not assumptions.

## 6.10 Sites do not open while the resolver looks healthy — the stub pair

**Symptom.** `https://cdn.tailwindcss.com/`, `cdnjs.cloudflare.com`, `unpkg.com`
and similar names time out in the browser. The router is fine: DoH answers,
`Status:0`, a valid A record, the monitor reports healthy.

**What is actually returned.** The pair **`8.6.112.0` / `8.47.69.0`**. Measured
2026-10-26 from two independent vantage points:

| Query | Answer |
|---|---|
| `:resolve example.com` / DoH JSON, standard endpoint | `8.47.69.0`, `8.6.112.0` |
| same, Family (1.1.1.3) endpoint | the same pair |
| plain DNS to `1.1.1.1` and `8.8.8.8` | the same pair (Google even answered `8.6.112.5`) |
| the same questions asked from Germany | `104.26.x`, `172.66.x` — real addresses |
| `curl --resolve example.com:443:8.6.112.0` **from the router's own WAN** | `200`, valid certificate |
| the same from a branch network behind another ISP | **connection timeout** |

So the pair is served by Cloudflare and is a *real* answer — not a block and not
a filter artefact. It is simply **not reachable from some networks**. Where the
path to it is missing, every name that resolves to it stops working, no matter
which Cloudflare endpoint you chose: switching resolvers does not help.

**How to confirm from a client** (the router cannot answer this reliably —
`/tool fetch` cannot tell a dead path from an HTTP refusal):

```bash
nslookup cdn.tailwindcss.com              # which pair/address do you get?
curl -sS -o /dev/null --max-time 10 \
  --resolve cdn.tailwindcss.com:443:8.6.112.0 \
  -w '%{http_code} %{time_total}s\n' https://cdn.tailwindcss.com/
#  302 in ~0.2 s  -> the address is reachable, the pair is harmless here
#  timeout        -> the pair is unreachable: this is your outage
```

**What actually fixes it** (proved on a branch network on 2026-10-26):

1. Route the pair (or the affected prefixes) through a working tunnel, or
2. pin reachable addresses with `/ip dns static` for the names you need, or
3. use a resolver in a network where the pair is reachable — i.e. change the
   vantage point, not the resolver brand.

A DNS-level trick does **not** help: `/ip dns static type=FWD forward-to=1.1.1.1`
was tried and the router forwarded the query over plain DNS, which returned the
same pair.

**What the monitor does about it.** It marks the state `stub` and logs once per
transition, with the measured answers and this section. It does not failover,
because a second endpoint would return the same pair.

## 6.11 The failover never triggers — check the probe's own DNS

The 0.2.0 probe asks the endpoint over HTTPS by hostname. If the resolver is
already dead, that hostname cannot be resolved, the probe fails, and the monitor
concludes "both endpoints unreachable — keeping the current configuration".

That is why `01-configure-doh.rsc` pins bootstrap records for **both** endpoint
hosts (`cloudflare-dns.com` and `dns.google`). If you change the endpoints,
update the bootstrap records too:

```rsc
/ip dns static print where comment~"DoH bootstrap"
```

Expected: two addresses for the primary host and two for the fallback host.

## 6.12 Not every endpoint speaks the JSON API

The probe uses `accept: application/dns-json`, which Cloudflare and Google
support:

| Endpoint | JSON probe URL |
|---|---|
| Cloudflare (all three) | `https://cloudflare-dns.com/dns-query?name=example.com&type=A` |
| Google | `https://dns.google/resolve?name=example.com&type=A` |
| Quad9 | **not supported** — `https://dns.quad9.net/dns-query?name=…` answers `DoH unable to decode BASE64-URL` |

Quad9 is fine as a DoH upstream for the router, but it cannot be probed this
way, so a Quad9 fallback would always look "unreachable". Use Google as the
fallback, or change `probeUrlB` to something your fallback does support.

**A self-hosted endpoint has the same problem** — and a worse consequence. Your own
resolver serves wire format, not DNS-JSON, so the probe reports `bad-status` for a
perfectly healthy primary and the monitor moves the router onto a public fallback.
That is the wrong direction: the fallback is exactly where answers get substituted
(see §6.13).

Since 0.4.2 set `probeMode "resolve"` for such endpoints. Liveness is then judged by
the quality of the live resolver answers (`:resolve` + the stub check), with no
external request at all:

```
:local probeMode    "resolve"                       # own endpoint, no JSON API
:local dohUrlA      "https://doh.example.net/dns-query"
:local probeUrlA    ""                              # not used in resolve mode
```

## 6.13 The network substitutes DoH answers as well

The resolver looks healthy, the probe returns `Status: 0`, and clients still get
addresses that open nothing.

Measured 2026-11-01. The same URL on both sides:

| Where the request went | Answer for the same name |
|---|---|
| from the router, over its normal uplink | `8.6.112.0`, `8.47.69.0` (stub pair) |
| from a host whose DNS left through an encrypted tunnel | `104.18.32.47`, `172.64.155.209` (real) |

Same name, same DoH endpoint, same certificate — different answers. The substitution
happens on the router's path, not at the resolver. It is also **unstable**: repeated
queries to the same endpoint alternate between honest and stubbed answers, so a single
successful probe proves nothing.

What follows:

1. `Status: 0` is not proof of an honest answer. Since 0.4.2 the probe also checks the
   payload for stub prefixes and reports `substituted` instead of `ok`.
2. Failover between public operators does not help. If the network substitutes the
   path, Cloudflare, Google and Quad9 all answer with the same stub pair.
3. Filtering resolvers — `1.1.1.3`, `1.0.0.3`, anything advertised as "family" — answer
   stubs for filtered names by design. Never use them as the health baseline, and never
   use them to bypass filtering.
4. The only reliable fix is a path the network does not intercept: your own resolver on
   a host whose traffic is already inside an encrypted tunnel, published over DoH, used
   as `dohUrlA` with `probeMode "resolve"`. Rule of thumb: if a client on the same LAN
   opens the sites but the router's resolver does not, the difference is the path, not
   the resolver.

How to tell the two apart in one minute (replace the name and the endpoint):

```
# from the router
/tool fetch url="https://doh.example.org/dns-query?name=example.com&type=A"     http-header-field="accept: application/dns-json" output=user

# from a host behind your own tunnel, same URL
curl -s -H 'accept: application/dns-json' \
     "https://doh.example.org/dns-query?name=example.com&type=A"
```

If the two answers differ, the path is intercepted and no resolver setting on the
router can repair it. Read the configured stub prefixes from your own network: the
default pair in `stubPrefixes` is one operator's example, not a universal value.

## 6.14 A reserve endpoint on a separate host

A failover between two public resolvers is weak: both sit behind the same path, so both get
substituted together (§6.13). A reserve that actually helps is your own resolver on a host
that is not on the broken path — typically the same machine that terminates your tunnel.

The working shape, and the one thing that will stop you:

| Layer | What it is |
|---|---|
| TLS | your existing web server on 443, one extra `location = /dns-query` |
| access control | `allow`/`deny` in that location — the endpoint is public, the list is not |
| DoH front end | something that speaks HTTP/1.1 on loopback and forwards to the resolver |
| resolver | `unbound`, `forward-tls-upstream` to `1.1.1.1@853` / `9.9.9.9@853` |

**The pitfall:** on Ubuntu 26.04 the packaged `dnsdist` is 2.x, and its plain-HTTP DoH
listener is HTTP/2-only. It answers an HTTP/1.1 request with an HTTP/2 frame, so the client
sees `BadStatusLine` / `000`, and nginx cannot proxy to it at all (nginx has no HTTP/2
upstream for `proxy_pass`). `h2=false` is not a valid option — dnsdist reports
`Unknown key 'h2' given - ignored`.

Two options that work:

1. `dnsdist` 1.7 as on Debian 12 — `addDOHLocal(..., nil, nil, {"/dns-query"})` serves
   HTTP/1.1 and is proxied by nginx without fuss.
2. A ~40-line gateway: `http.server` on `127.0.0.1:8053`, POST body → UDP to the resolver,
   answer back. No dependencies, HTTP/1.1, easy to read. This is what the reference setup
   uses where `dnsdist` 2.x is packaged.

`unbound` itself cannot sit behind a plaintext reverse proxy: `http-endpoint` requires TLS
(`tls-service-key` / `tls-service-pem`), and the packaged service usually cannot read a
Let's Encrypt key without a copy and a deploy hook.

Verify, in this order:

```
# the gateway alone
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'content-type: application/dns-message' --data-binary @q.bin http://127.0.0.1:8053/dns-query

# through nginx, from the host itself
curl -s -o /dev/null -w '%{http_code}\n' https://doh.example.org/dns-query   # 400 is correct: GET is not DoH

# from a client, with the real wire format
# 200 + honest addresses = works; 403 = the address is not in the allow list
```

A `400` on a plain GET means TLS and the route are fine — it is the same signal as in §6.9.
