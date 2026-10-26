# cloudflare-family.rsc
# Complete, self-contained example for Cloudflare Family DoH (1.1.1.3 / 1.0.0.3).
# Run after uploading certs/cloudflare-doh-ca.crt to the router.
#
# READ THIS FIRST (0.2.0): Family is a FILTERING resolver, and since 0.2.0 it is
# not the default. Measured 2026-10-26 from two independent vantage points:
# Family answered example.com, example.org, tailwindcss.com, cdn.tailwindcss.com,
# cdnjs.cloudflare.com and unpkg.com with the pair 8.6.112.0 / 8.47.69.0 — a
# valid answer that is simply not reachable from some providers, so CDNs do not
# open while the resolver looks healthy. The same pair was later observed from the
# STANDARD endpoint too, so switching resolvers is not a cure; see
# docs/troubleshooting.md §6.10. Choose Family deliberately, for its filtering.
# 1) NTP first (certificate validation needs accurate time)
/system ntp client set enabled=yes servers=162.159.200.1,216.239.35.0
# 2) Trust anchor
/certificate import file-name=cloudflare-doh-ca.crt passphrase=""
/certificate set [find where name~"cloudflare-doh-ca"] trusted=yes
# 3) Bootstrap static A records (both endpoints: the monitor probes the fallback too)
/ip dns static add name=family.cloudflare-dns.com address=1.1.1.3 ttl=1d comment="DoH bootstrap"
/ip dns static add name=family.cloudflare-dns.com address=1.0.0.3 ttl=1d comment="DoH bootstrap"
/ip dns static add name=dns.google address=8.8.8.8 ttl=1d comment="DoH bootstrap (fallback)"
/ip dns static add name=dns.google address=8.8.4.4 ttl=1d comment="DoH bootstrap (fallback)"
# 4) DoH (Family) + plain bootstrap
/ip dns set servers=1.1.1.3,1.0.0.3
/ip dns set use-doh-server="https://family.cloudflare-dns.com/dns-query" verify-doh-cert=yes
/ip dns set allow-remote-requests=yes
# 5) force-DNS + resolver protection (gateway; bridge name may differ)
/ip firewall nat add chain=dstnat action=redirect protocol=udp dst-port=53 in-interface=bridge comment="force DNS UDP"
/ip firewall nat add chain=dstnat action=redirect protocol=tcp dst-port=53 in-interface=bridge comment="force DNS TCP"
/ip firewall filter add chain=input action=accept protocol=udp dst-port=53 in-interface-list=LAN comment="DNS UDP from LAN" place-before=0
/ip firewall filter add chain=input action=accept protocol=tcp dst-port=53 in-interface-list=LAN comment="DNS TCP from LAN" place-before=0
/ip firewall filter add chain=input action=drop protocol=udp dst-port=53 in-interface-list=WAN comment="drop DNS UDP from WAN" place-before=0
/ip firewall filter add chain=input action=drop protocol=tcp dst-port=53 in-interface-list=WAN comment="drop DNS TCP from WAN" place-before=0
# 6) Verify
/ip dns cache flush
:put [:resolve example.com]     # 104.20.x/172.66.x = real; 8.6.112.0/8.47.69.0 = stub pair (§6.10)
:put [:resolve pornhub.com]     # 0.0.0.0 with the Family filter
