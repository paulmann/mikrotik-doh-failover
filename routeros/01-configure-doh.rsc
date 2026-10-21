# 01-configure-doh.rsc
# Configure a single DoH upstream plus plain-DNS bootstrap/fallback.
#
# RouterOS supports exactly ONE active DoH server (use-doh-server). Do NOT try
# to add "backup DoH servers" via /ip dns static-server type=doh: that syntax
# does not exist and does not produce failover. Redundancy is instead:
#   - plain upstreams in `servers` (used as bootstrap and as fallback),
#   - a failover script (05-dns-health-monitor.rsc) that clears use-doh-server
#     when DoH is unreachable and restores it after recovery.

# ===== CONFIG =====
:local dohUrl      "https://family.cloudflare-dns.com/dns-query"   # Cloudflare Family (1.1.1.3)
:local dohHost     "family.cloudflare-dns.com"
:local dohServerA  "1.1.1.3"
:local dohServerB  "1.0.0.3"
:local dohServers  "1.1.1.3,1.0.0.3"    # plain bootstrap + fallback (same family policy)
:local allowRemote "yes"                # yes on a LAN gateway, no on a pure AP/test box
# ==================

# Bootstrap: static A records so the DoH hostname resolves even when plain DNS
# is unavailable (breaks the chicken-and-egg dependency). Keep these in sync
# with Cloudflare's current addresses.
/ip dns static add name=$dohHost address=$dohServerA ttl=1d comment="DoH bootstrap"
/ip dns static add name=$dohHost address=$dohServerB ttl=1d comment="DoH bootstrap"

# Plain upstreams first, then the DoH endpoint.
/ip dns set servers=$dohServers
/ip dns set use-doh-server=$dohUrl verify-doh-cert=yes
/ip dns set allow-remote-requests=$allowRemote

# Verify (run 00-install-ca.rsc first, and make sure NTP is synchronized):
/ip dns print
/ip dns cache flush
:put [:resolve example.com]        # expect a real IP
:put [:resolve pornhub.com]        # expect 0.0.0.0 with the Family filter
