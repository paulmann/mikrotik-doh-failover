# config.example.rsc
# All tunable values used across the routeros/ scripts, in one place for
# review. Copy the values you need into the corresponding script's CONFIG
# section (RouterOS scripts cannot "source" a shared file, so each script keeps
# its own CONFIG block and this file is documentation + a copy-paste reference).
# --- DNS / DoH (01-configure-doh.rsc, 05-dns-health-monitor.rsc) ---
# Default since 0.2.0: the STANDARD resolver, no filtering.
:global dohUrl     "https://cloudflare-dns.com/dns-query"
:global dohHost    "cloudflare-dns.com"
:global dohServers "1.1.1.1,1.0.0.1"
:global filtering  false        # true only for family/security
# Filtering alternatives (opt-in):
#   Cloudflare Family (malware + adult):   https://family.cloudflare-dns.com/dns-query,   1.1.1.3,1.0.0.3
#   Cloudflare Security (malware only):    https://security.cloudflare-dns.com/dns-query, 1.1.1.2,1.0.0.2
# Why filtering is not the default: measured 2026-10-26, Cloudflare answers a number of
# legitimate names (example.com, example.org, tailwindcss.com, cdn.tailwindcss.com,
# cdnjs.cloudflare.com, unpkg.com) with the pair 8.6.112.0 / 8.47.69.0 for clients in
# some networks — Status:0 and a valid A record, but from some providers there is no
# path to that pair, so CDNs do not open while the resolver looks healthy. The same pair
# was also observed from the standard endpoint, so this is NOT a filtering-only effect:
# see docs/troubleshooting.md §6.10 before blaming the resolver.
# --- DoH failover (05-dns-health-monitor.rsc) ---
# Only one DoH endpoint can be active; the monitor switches between these two.
# This is MANAGED failover (the upstream changes), not "transparent": primary and
# fallback are different operators and may answer differently (filtering, geo,
# CDN steering). There is no multi-endpoint list in RouterOS — one active
# use-doh-server — so "a list of fallbacks" is at most "try one, then another".
:global dohUrlB    "https://dns.google/dns-query"                 # fallback
:global probeUrlA  "https://cloudflare-dns.com/dns-query?name=example.com&type=A"
:global probeUrlB  "https://dns.google/resolve?name=example.com&type=A"
# Optional tertiary DoH endpoint (0.4.0). Leave BOTH empty to disable it. The probe
# must speak DNS-JSON (Cloudflare/Google); Quad9 does not.
:global dohUrlC    ""                                             # e.g. "https://security.cloudflare-dns.com/dns-query"
:global probeUrlC  ""
# Optional last-resort plain DNS (0.4.0), OFF by default. When enabled and every
# DoH endpoint is unreachable, the monitor clears use-doh-server, sets these plain
# resolvers and logs "PRIVACY DEGRADED". This is a deliberate privacy downgrade.
:global plainFallback false
:global plainServers  "1.1.1.1,1.0.0.1,8.8.8.8,8.8.4.4"
# The fallback needs its own root CA in the trust store, otherwise verify-doh-cert=yes
# rejects it and the monitor rolls back (and says so in the log).
# Quad9 cannot be used as the fallback with the JSON probe (its dns-query does not
# decode the GET ?name= form) — see docs/troubleshooting.md §6.12.
# --- Monitor tuning (05-dns-health-monitor.rsc) ---
:global monitorInterval   "60s"   # 45-60s for an office; 3m acceptable for home
:global failureThreshold  2       # consecutive bad runs before a failover (anti-flap)
:global recoveryThreshold 2       # consecutive good runs before coming home (anti-flap)
:global maxAttempts       3       # failover attempts per outage
# --- Enforcement (02-security-policies.rsc) ---
:global enforcement "standard"    # "standard" (53 redirect only) | "strict" (+ block DoT 853 and known public DoH endpoints)
# --- CA (00-install-ca.rsc) ---
# Cloudflare DoH chain root: SSL.com TLS ECC Root CA 2022  (certs/cloudflare-doh-ca.crt)
# Quad9/Google need their own root CA; take it from the provider's site.
# --- Network / firewall (02-security-policies.rsc) ---
:global bridge  "bridge"    # LAN bridge name
:global lanList "LAN"       # interface list for LAN
:global wanList "WAN"       # interface list for WAN
# --- CAPsMAN (03-capsman.rsc) ---
:global capConfig "cfg1"
:global capBridge "bridge-local"
:global dnsIp     "192.168.88.1"
# --- NTP (needed for certificate validation) ---
# /system ntp client set enabled=yes servers=162.159.200.1,216.239.35.0
