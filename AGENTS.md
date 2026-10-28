# AGENTS.md — mikrotik-doh-failover 0.4.0

Agent-facing operational contract: how to fetch these scripts, apply them to a
RouterOS device, verify every step, and roll back. Human documentation:
[README.md](README.md) and [docs/](docs/); change rules: [CONTRIBUTING.md](CONTRIBUTING.md).

> Verified against repository state on 2026-10-28, tagged `v0.4.0`
> (commit `306959e`). Pin raw URLs to a commit — `main` may be ahead of the tag. Pin raw URLs to a
> commit — `main` is ahead of the tag.
> Every command below is quoted from `routeros/`; every "expect" line is what
> `docs/verification.md` records from the test fleet. No router was touched while
> writing this file — a `.rsc` change is unverified until it has been imported on
> a device ([CONTRIBUTING.md](CONTRIBUTING.md)).

## 1. What it is

Seven `.rsc` files that configure one **verified** DNS-over-HTTPS upstream on a
MikroTik RouterOS box, force LAN clients onto that resolver, and add a health
check that switches to a second DoH endpoint when the first fails, verifies the
switch, rolls back if the fallback does not resolve, and returns to the primary
after recovery. Plain DNS is bootstrap only — it is not a working fallback. It is
configuration, not software: nothing is installed, nothing runs outside the
router, and the only running piece is a RouterOS scheduler entry that executes a
RouterOS script every interval (60 s default).

| | |
|---|---|
| Target platform | RouterOS **7.20+** as declared in the README; behaviour verified on **7.23.1** and **7.24.5** only |
| `device-mode` | `advanced` for the automatic scheduler; `home` rejects it **and** `/tool fetch`, then the monitor runs by hand and cannot probe endpoints |
| Entry points | `routeros/00…05*.rsc` (apply in order), `routeros/config.example.rsc` (all tunables), `examples/cloudflare-standard.rsc` (default since 0.2.0) and `examples/cloudflare-family.rsc` (opt-in filtering), `certs/cloudflare-doh-ca.crt` |
| Default upstream | `https://cloudflare-dns.com/dns-query` — the **standard**, non-filtering resolver; `servers=1.1.1.1,1.0.0.1` are bootstrap only |
| Failover target | `https://dns.google/dns-query` — a second **DoH** endpoint, never plain DNS |
| Writes to | the router's own configuration: `/certificate`, `/ip dns`, `/ip dns static`, `/ip firewall nat`, `/ip firewall filter`, `/system script`, `/system scheduler`, optionally `/caps-man` and `/ip dhcp-server network`. No repository file is written by any script |
| Network access | both DoH endpoints on TCP 443 (the monitor probes them every interval, 60 s default); IP-based NTP servers during setup. No telemetry, no callback, no repository traffic |
| Not shipped | no installer, no package, no service, no CI, no issue templates — and neither release carries assets (`gh release view v0.2.0 --json assets` → `[]`, same for `v0.1.0`) |

`zabbix/` (fleet monitoring) exists on `main` but is **after** the `v0.2.0` tag:
pin `v0.2.0` and you will not get it. See [zabbix/README.md](zabbix/README.md).

## 2. Preconditions

Read the whole table before touching a device. A failed row is a stop, not a
warning.

| Requirement | Why | Check |
|---|---|---|
| RouterOS 7.20 or newer | `use-doh-server`, `verify-doh-cert` and the CA handling below exist there | `/system resource print` → `version:` |
| NTP synchronized | TLS validation needs a correct clock; a drifting clock fails validation | `/system ntp client print` → `status: synchronized` |
| `device-mode` known | on `home`, `/system scheduler add` and `/tool fetch` return `not allowed by device-mode` | `/system device-mode print` |
| Admin session on the router | the import writes to the certificate store, so a read-only account is not enough | WinBox, SSH or the API; `/user print` |
| The CA file on the router's Files | `import file-name=` reads the router's file system, not the repository | WinBox → Files, or scp |
| Interface names match reality | `02-security-policies.rsc` defaults to bridge `bridge` and lists `LAN`/`WAN`; a rule aimed at a missing interface is invalid and silently does nothing | `/interface bridge print`, `/interface list print` |
| A maintenance window | a wrong CA or an untrusted chain stops **all** name resolution on the LAN | `/export file=before-doh` before step 1 of §4 |

`allow-remote-requests=yes` is part of `01-configure-doh.rsc` and is correct on a
LAN gateway. Never set it on a box whose resolver is reachable from the WAN,
unless `02-security-policies.rsc` (or equivalent drop rules) is applied first.

## 3. Get the files

### 3.1 From a clone (the only route that includes docs and the tunables reference)

```bash
git clone --depth 1 https://github.com/paulmann/mikrotik-doh-failover.git && git checkout 38ef7e0
```

### 3.2 Individual files, pinned

```bash
# pin the ref: main moves, a tag does not
curl -fLO https://raw.githubusercontent.com/paulmann/mikrotik-doh-failover/38ef7e0/certs/cloudflare-doh-ca.crt
curl -fLO https://raw.githubusercontent.com/paulmann/mikrotik-doh-failover/38ef7e0/routeros/01-configure-doh.rsc
```

### 3.3 Check what you got before importing

- `certs/cloudflare-doh-ca.crt` is 1533 bytes, `CN=SSL.com TLS ECC Root CA 2022`,
  `notAfter = Dec 31 2028 23:59:59 GMT`, file SHA-256
  `24B226BCA66D2FD890EA56CF56D9DDD177FD5ED57FF9F9859B073057A96A881B`
  (measured with `Get-FileHash -Algorithm SHA256`).
  A different digest means a different trust anchor — stop.
- The `.crt` and the `.rsc` files must be uploaded to the **router's** Files
  root; `import file-name=` resolves against that root, not against your working
  directory.

There is no release-asset route: `v0.2.0` has no assets, and `main` carries
post-tag changes (`zabbix/`).

## 4. Apply

Apply in this order and run the matching verify block from §5 after each step.
Each script keeps its tunables in a `# ===== CONFIG =====` block at the top —
edit that block before importing, never edit the body.

| # | File | What it does |
|---|---|---|
| 0 | — | `/export file=before-doh` and `/system backup save name=before-doh` — this is the rollback |
| 1 | NTP (inside `examples/cloudflare-standard.rsc`, §1) | `/system ntp client set enabled=yes servers=162.159.200.1,216.239.35.0`. IP-based on purpose: NTP must not depend on the DNS it is about to protect |
| 2 | `00-install-ca.rsc` | imports the root CA and marks it `trusted=yes`. Without it `verify-doh-cert=yes` fails and the network loses DNS |
| 3 | `01-configure-doh.rsc` | **four** bootstrap static A records — two for `cloudflare-dns.com` (1.1.1.1, 1.0.0.1) and two for the fallback host `dns.google` (8.8.8.8, 8.8.4.4) — then `servers=1.1.1.1,1.0.0.1`, `use-doh-server=<url>`, `verify-doh-cert=yes`, `allow-remote-requests` |
| 4 | `02-security-policies.rsc` | `dstnat action=redirect` for UDP **and** TCP 53 on the LAN bridge, `input` accept for DNS from LAN, `input` drop for DNS from WAN, optional DoT drop |
| 5 | `05-dns-health-monitor.rsc` | removes and re-adds script `DNS_HealthMonitor_Failover` (policy `read,write,policy,test`) and adds scheduler `Scheduler_DNS_Health_Check` at `interval=3m`, `start-time=startup` |
| — | `03-capsman.rsc` | optional, legacy `/caps-man` controller only, targets one configuration by name. Newer hardware uses `/interface wifi` — configure there instead |
| — | `04-cert-update.rsc` | optional CA refresh. For Cloudflare the shipped root is valid until 2028-12-31 (UTC), so a periodic job is usually pointless |

The fallback host needs its **own** root CA in the trust store (Google's, not
SSL.com). Without it `verify-doh-cert=yes` rejects the fallback, the switch
produces no resolution, and the monitor rolls back — leaving you on a dead
primary while the log says why.

**Not idempotent, except the monitor.** `01` and `02` contain no existence
check (`/ip dns static add`, `/ip firewall nat add`, `/ip firewall filter add`),
so a second import adds a second entry; `05` is guarded by
`/system script remove [find name="DNS_HealthMonitor_Failover"]` and the
scheduler the same way. Before re-importing, look at what is already there:

```rsc
/ip dns static print where comment~"DoH bootstrap"
/ip firewall nat print where comment~"force DNS"
/ip firewall filter print where comment~"DNS"
/system script print where name="DNS_HealthMonitor_Failover"
```

This is a statement about the scripts as written, not a measurement of how
RouterOS treats duplicates — assume it duplicates and check first.

## 5. Verify

Run these after §4. The expected values are the ones recorded in
`docs/verification.md` for the fleet; a mismatch is a defect report, not a
"retry".

| Check | Command | Expect |
|---|---|---|
| Trust anchor | `/certificate print where trusted=yes` | a trusted certificate named `SSL.com TLS ECC Root CA 2022` |
| DoH + bootstrap | `/ip dns print` | `servers=1.1.1.1,1.0.0.1`, `use-doh-server=https://cloudflare-dns.com/dns-query`, `verify-doh-cert=yes` |
| Bootstrap records | `/ip dns static print where comment~"DoH bootstrap"` | two entries for `cloudflare-dns.com` (1.1.1.1, 1.0.0.1) and two for `dns.google` (8.8.8.8, 8.8.4.4) |
| Clock | `/system ntp client print` and `/system clock print` | `status: synchronized`, a current date (the monitor refuses to act on a year below 2025) |
| Force-DNS | `/ip firewall nat print where comment~"force DNS"` | two `redirect` rules, UDP and TCP, port 53 |
| Resolver protection | `/ip firewall filter print where comment~"DNS"` | accept UDP+TCP from LAN, drop UDP+TCP from WAN |
| Real resolution | `/ip dns cache flush` then `:put [:resolve example.com]` | `104.20.x` / `172.66.x`; **not** `8.6.112.0` / `8.47.69.0` |
| Content judged | resolve all three canaries | at least one real address; the stub pair counts as unusable |
| Mode | `:put $DNSMonitorState` | `healthy` after a clean run; the other states are `suspect`, `stub`, `fallback`, `recovering`, `plain`, `degraded`, `clock-invalid`, `manual-only` (see §5.1) |
| Attempts | `:put $DNSFailoverAttempts` | `0` while the primary answers |
| Endpoint probe | `:local r [/tool fetch url="https://cloudflare-dns.com/dns-query?name=example.com&type=A" http-header-field="accept: application/dns-json" mode=https as-value output=user]; :put ($r->"status"); :put ([:find ($r->"data") "\"Status\":0"])` | `finished` and a non-negative `:find` position (no temp file) |
| Errors | `/log print where message~"connection error"` | nothing, on a healthy setup |

**How the monitor judges an answer (0.4.0).** Three canaries —
`example.com`, `cdnjs.cloudflare.com`, `cdn.tailwindcss.com` — are resolved
through the live resolver and the *content* is checked: empty, `0.0.0.0`, or a
prefix from `8.6.112.` / `8.47.69.` counts as unusable. A failover is triggered
by **endpoint health** (`probeA` unreachable) OR by no usable answers, after
`failureThreshold` consecutive runs; recovery needs `recoveryThreshold`
consecutive good runs and the primary endpoint to answer. Since 0.4.0 the ordering
is primary → secondary → tertiary (`dohUrlC`, optional) → plain DNS
(`plainFallback`, optional, logged `PRIVACY DEGRADED`). State lives in
`DNSMonitorState`, `DNSFailCount`, `DNSRecoverCount`, `DNSFailoverAttempts` and
`DNSMonitorRunning`.

Do not conclude "DoH is down" from `/tool fetch` alone: a `400` (POST) or `405`
(GET) means the TLS handshake and certificate validation **succeeded**. The
monitor looks for `"Status":0`, not for the absence of an error.

Measured oddities worth knowing before you "fix" a script:

- `/certificate settings set builtin-trust-anchors=…` → `bad parameter`. The
  parameter is `builtin-trust-store`, and on 7.23/7.24 its store does **not**
  cover the Cloudflare chain.
- `:resolve cloudflare.com server=1.1.1.3` is supported (it bypasses DoH and
  tests the plain path); `:resolve cloudflare.com timeout=5s` → `bad parameter timeout`.
- Untrusting every CA and resolving gives `failure: dns server failure`, which is
  why step 2 of §4 is mandatory rather than advisable.
- Quad9 answers `DoH unable to decode BASE64-URL` to the JSON probe, so it
  cannot be the fallback while `probeUrlB` points at it (§6.12 of
  `docs/troubleshooting.md`).

### 5.1 State machine

```text
HEALTHY --canary fails / endpoint down--> SUSPECT
SUSPECT --canary passes / endpoint up--> HEALTHY
SUSPECT --failureThreshold bad runs--> FALLBACK   (secondary probed first, tertiary if configured)
FALLBACK --primary passes once--> RECOVERING
RECOVERING --recoveryThreshold good runs--> HEALTHY
RECOVERING --primary fails again--> FALLBACK
SUSPECT / FALLBACK --secondary and tertiary unreachable, plainFallback=true--> PLAIN
PLAIN --primary passes--> RECOVERING
SUSPECT / FALLBACK / PLAIN --nothing left and no plain--> DEGRADED
any --answers are the stub pair--> STUB          (not a failover-able fault)
any --device-mode=home--> MANUAL-ONLY
```

Transitions are logged with an UPPERCASE tag (`HEALTHY`, `SUSPECT`, `FALLBACK`,
`RECOVERING`, `PLAIN`, `STUB`, `DEGRADED`, `CLOCK_INVALID`,
`MONITOR_DISABLED_BY_DEVICE_MODE`). `failureThreshold` and `recoveryThreshold`
(both 2) are the anti-flap hysteresis; `monitorInterval` (60 s default) is the
scheduler period. The monitor refuses to act on a clock date outside `2025..2035`.

## 6. Configure

Values live in `routeros/config.example.rsc`, which is a copy-paste reference:
RouterOS scripts cannot source a shared file, so each script carries its own
CONFIG block (the scripts use `:local`, the reference file shows them as
`:global` names for readability — copy the **value**, not the declaration).
Providers:

| Provider | `use-doh-server` | plain `servers` | CA | Probeable |
|---|---|---|---|---|
| Cloudflare standard — **default since 0.2.0** | `https://cloudflare-dns.com/dns-query` | `1.1.1.1,1.0.0.1` | `SSL.com TLS ECC Root CA 2022` (shipped in `certs/`) | yes |
| Cloudflare Family (malware + adult) | `https://family.cloudflare-dns.com/dns-query` | `1.1.1.3,1.0.0.3` | same root | yes |
| Cloudflare Security (malware only) | `https://security.cloudflare-dns.com/dns-query` | `1.1.1.2,1.0.0.2` | same root | yes |
| Google | `https://dns.google/dns-query` | `8.8.8.8,8.8.4.4` | its own root, from the provider | yes |
| Quad9 | `https://dns.quad9.net/dns-query` | `9.9.9.9,149.112.112.112` | its own root, from the provider | **no** — JSON API unsupported |

Changing provider means changing the URL, **both** plain servers, the CA **and**
the matching static A records in `01` — `verify-doh-cert=yes` against the wrong
root fails exactly like no CA at all. Choosing a filtering endpoint also means
accepting the stub-pair trade-off documented in `docs/troubleshooting.md` §6.10.
The `filtering` local in `05` is a marker for a human reader: the script declares
it and never reads it, so no behaviour and no log line depends on it.

## 7. Use non-interactively

| Rule | Why |
|---|---|
| No prompts, no `read`, no pauses | the import runs unattended; print state with `:put` and read the log afterwards |
| Never put credentials in commands, scripts or issues | the scripts need none; the certificate import takes an empty passphrase because the shipped PEM is unencrypted |
| One device at a time, verify before the next | a broken step 2 on ten routers is ten networks without DNS |
| Read an empty result correctly | `use-doh-server=""` means "plain mode", not "broken"; an empty `/log print where comment~"connection error"` is the healthy state; a failed `:resolve` is a `failure:` string, not an empty value |
| Guard state reads in scripts | the monitor wraps `:resolve` in `:do {} on-error={}` so a failed lookup does not abort the run — do the same in anything you add |
| Know where the state lives | five globals: `DNSMonitorState` (`healthy`/`suspect`/`stub`/`fallback`/`recovering`/`plain`/`degraded`/`clock-invalid`/`manual-only`), `DNSFailCount`, `DNSRecoverCount`, `DNSFailoverAttempts` (reset to `0` whenever the primary answers) and `DNSMonitorRunning` (the concurrency guard). They live in memory: a reboot clears them, and the monitor then logs its first transition again |

Minimal non-interactive pipeline on a device that already has the files:

```rsc
:do { :local ip [:resolve example.com]; :put ("resolve ok: " . $ip) } on-error={ :put "resolve failed" }
/system script run DNS_HealthMonitor_Failover
:put $DNSMonitorState
:put $DNSFailoverAttempts
```

Success criteria: no terminating error, `example.com` resolves to a real address
rather than the stub pair, `$DNSMonitorState` is `healthy`, `$DNSFailoverAttempts`
is `0`, and `/log print` shows no `connection error` line. Confirm the failover
itself with the checklist in `docs/verification.md` (eight scenarios, each with
its expected log level). Clearing the state before a manual run re-logs the
transition:

```rsc
:global DNSMonitorState; :set DNSMonitorState ""
:global DNSFailoverAttempts; :set DNSFailoverAttempts 0
```

## 8. Safety and rollback

**Changes:** the router's configuration only — certificate store, `/ip dns`,
static records, nat/filter rules, one script, one scheduler. Nothing on the
machine running the agent, nothing in the repository, no telemetry.

**Never run "to see what happens":**

- removing or untrusting the CA while `use-doh-server` is set — the resolver
  stops, and every client loses DNS within the cache TTL;
- toggling `verify-doh-cert=no` and back as a "TLS session reset" — it briefly
  disables validation and is not a documented mechanism;
- toggling `use-doh-server` to "test" an endpoint — 0.2.0 stopped doing that for
  a reason: it takes the LAN off DoH for the duration of the test. Use
  `/tool fetch` against the JSON API instead;
- `02-security-policies.rsc` on a router whose bridge or interface lists differ
  from the defaults — the rules are added but match nothing, and you will
  document a failure that is not one;
- `/system reset-configuration`, or a wholesale `/ip firewall filter remove` —
  deleting rules by bare `[find]` takes unrelated configuration with it; filter
  by `comment`;
- changing `device-mode` — that is the owner's decision: it needs confirmation
  on the device and a reboot;
- `/ip dns cache flush` on a large network during business hours if you have not
  first confirmed the upstream answers (§5, rows 1–6). The flush itself is
  harmless; flushing onto a broken path is not.

**Rollback ladder**, cheapest first:

```rsc
# 1. leave DoH mode without touching anything else
/ip dns set use-doh-server=""
/ip dns cache flush
# 2. remove what the scripts added
/ip firewall nat remove [find comment~"force DNS"]
/ip firewall filter remove [find comment~"DNS"]
/ip dns static remove [find comment~"DoH bootstrap"]
/system scheduler remove [find name="Scheduler_DNS_Health_Check"]
/system script remove [find name="DNS_HealthMonitor_Failover"]
/certificate remove [find where name~"cloudflare-doh-ca"]
# 3. restore the configuration exported before step 1 of §4
/import file-name=before-doh.rsc
```

**Safe first-run order:** export a backup → NTP → CA → verify the anchor →
bootstrap + DoH → `:resolve` a normal domain → force-DNS → verify the rules →
run the monitor **once by hand** → only then add the scheduler. Do not start
with `05` on a fleet.

## 9. Failure modes

| Symptom | Likely cause | Action |
|---|---|---|
| resolution stops right after enabling DoH; log `DoH server connection error: SSL: no trusted CA certificate found (6)` | no trusted CA imported | step 2 of §4, then `verify-doh-cert=yes` again |
| `connection error` continues after importing a CA | wrong root for the provider | Cloudflare needs `SSL.com TLS ECC Root CA 2022` |
| certificate validation fails with a correct CA | clock drift | NTP to `synchronized` |
| monitor logs `clock looks wrong (…)` and stops | date below 2025 | fix NTP; nothing else the monitor does can succeed on a wrong date |
| `not allowed by device-mode` on scheduler or `/tool fetch` | `device-mode=home` | run `DNS_HealthMonitor_Failover` by hand; without `fetch` it cannot probe, so it keeps the current configuration |
| log says `both endpoints unreachable` but DoH works from a laptop | the probe resolves the endpoint hostname through the resolver it is testing | add the bootstrap records (§6.11 of `docs/troubleshooting.md`) |
| pages do not open, monitor says healthy, answers are `8.6.112.x`/`8.47.69.x` | the stub pair is unreachable from this network — not a DoH fault | prove it from a client with `curl --resolve` (§6.10); switch the vantage point, not the resolver |
| failover never happens on a stub pair | by design — a second endpoint returns the same pair | see the row above |
| `bad parameter` on a certificate setting | `builtin-trust-anchors` does not exist | the parameter is `builtin-trust-store` |
| `bad parameter timeout` on `:resolve` | `timeout=` is not supported there | test with `server=` instead, or rely on the monitor |
| `dns server failure` on every query | no trusted CA, or `use-doh-server` set to an unreachable endpoint | §8 rollback step 1, fix the cause, re-apply |
| a specific domain resolves to a real IP while neighbours return `0.0.0.0` | `/ip dns static` overrides the filter for that name | `/ip dns static print`, `/ip dns cache print where name~"<domain>"` |
| `invalid`/`I` flag on a nat rule right after adding it | transient state on a freshly added rule | re-read before deleting anything |
| a WAN DHCP `dynamic-servers` entry shows in `/ip dns print` | ISP-injected | it is unused while `use-doh-server` is set; do not "fix" it by hand |

## 10. Limits

- Exactly **one** active DoH upstream: RouterOS has no backup DoH, and
  `/ip dns static-server type=doh` is not a failover mechanism. Redundancy here
  is a second DoH endpoint plus the failover script.
- Plain DNS is **not** a fallback: measured substitution on the path, even for
  queries straight to 1.1.1.1/8.8.8.8. `servers=` exists only to bootstrap the
  DoH hostname.
- Client-side DoH over TCP 443 is **not** blocked, and neither are hardcoded
  resolvers; blocking DoT (853) is a commented, optional rule.
- `dstnat redirect` does not reach clients that already use the router as their
  resolver — a per-client resolver policy built on dst-nat does nothing for them
  (measured 2026-10-26).
- DoH protects the transport, not the answer: no DNSSEC validation is added. An
  unreachable answer (the stub pair) cannot be fixed at DNS level.
- `/ip dns static` beats the DoH answer — a pinned name bypasses the filter.
- With `use-doh-server` set, RouterOS does not fall back to `servers` on failure;
  that is why the monitor exists, and why §8's first rollback step is a manual
  clear.
- Failover is capped at `maxAttempts=3` per outage; after that the monitor only
  waits for the primary.
- `device-mode=home` disables the scheduler **and** `fetch`; the monitor is then a
  manual action that can no longer probe endpoints.
- The CA shipped here expires 2028-12-31 23:59:59 UTC, so `04-cert-update.rsc` is
  not needed for a single-provider setup.
- Script policies are narrowed to `read,write,policy,test` — no `ftp`, `reboot`,
  password, `sniff`, `sensitive` or `romon` rights. Asking for more is a change
  of scope, not a fix.

**Not documented in this repository:** behaviour on RouterOS 7.20–7.22 (the
badge says 7.20+, the measurements are 7.23.1/7.24.5); IPv6-only clients or an
IPv6 DoH upstream; multiple WAN uplinks; whether the Family filter also blocks
advertising; upgrading an existing hand-made DoH configuration; how RouterOS
treats duplicate static/nat/filter entries added by a second import; any
automated test or CI signal — the only acceptance is the manual checklist in
`docs/verification.md`; the Zabbix collector's behaviour against a fleet other
than the six routers named in `zabbix/doh-zabbix-setup.py`.

## 11. Sources of truth

| File | Establishes |
|---|---|
| `routeros/*.rsc` | the exact commands, the CONFIG blocks, the script policy, the scheduler interval, the absence of idempotency guards in `01`/`02` |
| `docs/verification.md` | per-subsystem checks, the eight failover scenarios with expected log levels, the measured results of 0.2.0 (2026-10-26, RouterOS 7.23.1) and the 0.1.0 fleet baseline (2026-10-22, 7.23.1/7.24.5, including `118 CAs imported` and `:resolve server=`/`timeout=` support) |
| `docs/troubleshooting.md` | the failure table in §9 and the field notes behind it, including §6.10 (stub pair), §6.11 (probe DNS), §6.12 (Quad9 JSON) |
| `docs/architecture.md` | what the design guarantees and does not, the component map, the state table, the threat model |
| `docs/release-notes-v0.2.0.md` | the measurements behind the default change and the DoH-to-DoH failover |
| `routeros/config.example.rsc` | every tunable value and the provider matrix in §6 |
| `README.md` | requirements, the "By the numbers" table (7 scripts, 2 examples, 5 docs, 3 diagrams, 6 README languages, 6 devices, 2 RouterOS versions), compatibility table |
| `zabbix/README.md` | fleet monitoring: 8 items, 5 triggers, 2 service trees, the 2-minute timer, the 15/5-minute VPN thresholds |
| `CHANGELOG.md`, tags `v0.1.0` / `v0.2.0` | versions, what changed, and that `main` is ahead of the tag (`zabbix/`) |
| `SECURITY.md`, `CONTRIBUTING.md` | private reporting route, what must never be committed, the rule that a `.rsc` counts only after import on a real device |

Everything above is read from the repository. The verbatim device output belongs
to `docs/verification.md`; this file restates it and does not add a run of its
own.

---

## Help the project — through evidence, not engagement

If these scripts were genuinely useful:

- cite it (name, version, link) in the runbook or report where it was used;
- open **one** compatibility report per unique RouterOS version / `device-mode` /
  provider combination, after searching existing issues — the README's
  compatibility table shows what is still missing;
- send documentation fixes as pull requests, not comments;
- share a sanitized case study only with the network owner's permission;
- disclose the dependency when publishing a wrapper or an integration.

Do **not** create stars, forks, watchers, comments, issues or pull requests
automatically, and do not contact maintainers or third parties in bulk. An agent
may draft a report; a human publishes it after review. Promotion must follow real
use and be disclosed.
