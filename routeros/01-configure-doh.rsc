# 01-configure-doh.rsc
# Configure a single DoH upstream plus plain-DNS bootstrap/fallback.
#
# RouterOS supports exactly ONE active DoH server (use-doh-server). Do NOT try
# to add "backup DoH servers" via /ip dns static-server type=doh: that syntax
# does not exist and does not produce failover. Redundancy is instead:
#   - plain upstreams in `servers` (bootstrap for the DoH hostname only),
#   - a failover script (05-dns-health-monitor.rsc) that switches to a SECOND
#     DoH endpoint when the first stops answering.
#
# WHY THE DEFAULT IS THE STANDARD RESOLVER AND NOT FAMILY (changed in 0.2.0):
#   Cloudflare's filtering resolvers (family 1.1.1.3, security 1.1.1.2) answer a
#   number of perfectly legitimate names with the pair 8.6.112.0 / 8.47.69.0 for
#   clients in some networks. Measured on 2026-10-26 from two independent
#   Russian ISP vantage points: example.com, example.org, tailwindcss.com,
#   cdn.tailwindcss.com, cdnjs.cloudflare.com and unpkg.com all came back with
#   that pair, while the standard resolver returned the real addresses
#   (104.26.x / 172.67.x). The pair is served by Cloudflare and answers
#   correctly where it is reachable, but from some providers there is no path to
#   it at all — so CDNs "do not open" while the resolver looks perfectly
#   healthy (Status:0, valid A record).
#   Filtering stays available as a deliberate opt-in: see below.
# ===== CONFIG =====
:local dohUrl      "https://cloudflare-dns.com/dns-query"   # standard Cloudflare (1.1.1.1), no filtering
:local dohHost     "cloudflare-dns.com"
:local dohServerA  "1.1.1.1"
:local dohServerB  "1.0.0.1"
:local dohServers  "1.1.1.1,1.0.0.1"    # plain bootstrap for the DoH hostname (NOT a working fallback)
:local filtering   false                 # true = this endpoint filters; 05 reads the same flag
:local allowRemote "yes"                 # yes on a LAN gateway, no on a pure AP/test box
# ==================
#
# Filtering alternatives (opt-in — read the note above first):
#   Cloudflare Family   (malware + adult): https://family.cloudflare-dns.com/dns-query,   1.1.1.3,1.0.0.3
#   Cloudflare Security (malware only):    https://security.cloudflare-dns.com/dns-query, 1.1.1.2,1.0.0.2
#   With either of them also set filtering=true in 05-dns-health-monitor.rsc.
#
# Bootstrap: static A records so the DoH hostnames resolve even when plain DNS
# is unavailable (breaks the chicken-and-egg dependency). Both the primary and
# the fallback host are pinned: the health monitor probes them over HTTPS, and
# that probe cannot resolve a hostname through a resolver that is already dead.
# Keep these in sync with the providers' current addresses.
/ip dns static add name=$dohHost address=$dohServerA ttl=1d comment="DoH bootstrap"
/ip dns static add name=$dohHost address=$dohServerB ttl=1d comment="DoH bootstrap"
/ip dns static add name="dns.google" address=8.8.8.8 ttl=1d comment="DoH bootstrap (fallback)"
/ip dns static add name="dns.google" address=8.8.4.4 ttl=1d comment="DoH bootstrap (fallback)"
# Plain upstreams first, then the DoH endpoint.
/ip dns set servers=$dohServers
/ip dns set use-doh-server=$dohUrl verify-doh-cert=yes
/ip dns set allow-remote-requests=$allowRemote
# Verify (run 00-install-ca.rsc first, and make sure NTP is synchronized):
/ip dns print
/ip dns cache flush
:put [:resolve example.com]        # standard resolver: expect 104.20.x / 172.66.x
                                   # 8.6.112.0 or 8.47.69.0 here means the answer is a
                                   # stub pair — see docs/troubleshooting.md §6.10
:put [:resolve pornhub.com]        # filtering resolvers: 0.0.0.0; standard: a real IP
