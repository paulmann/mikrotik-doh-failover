# cloudflare-standard.rsc
# Complete, self-contained example for the STANDARD Cloudflare DoH endpoint
# (1.1.1.1 / 1.0.0.1, no content filtering). This is the default since 0.2.0.
# Run after uploading certs/cloudflare-doh-ca.crt to the router.
# 1) NTP first (certificate validation needs accurate time)
/system ntp client set enabled=yes servers=162.159.200.1,216.239.35.0
# 2) Trust anchor
/certificate import file-name=cloudflare-doh-ca.crt passphrase=""
/certificate set [find where name~"cloudflare-doh-ca"] trusted=yes
# 3) Bootstrap static A records (so the DoH hostnames resolve without the resolver)
/ip dns static add name=cloudflare-dns.com address=1.1.1.1 ttl=1d comment="DoH bootstrap"
/ip dns static add name=cloudflare-dns.com address=1.0.0.1 ttl=1d comment="DoH bootstrap"
/ip dns static add name=dns.google address=8.8.8.8 ttl=1d comment="DoH bootstrap (fallback)"
/ip dns static add name=dns.google address=8.8.4.4 ttl=1d comment="DoH bootstrap (fallback)"
# 4) DoH (standard, no filtering)
/ip dns set servers=1.1.1.1,1.0.0.1
/ip dns set use-doh-server="https://cloudflare-dns.com/dns-query" verify-doh-cert=yes
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
:put [:resolve example.com]     # expect 104.20.x / 172.66.x
                                # 8.6.112.0 / 8.47.69.0 means the "stub pair" — see
                                # docs/troubleshooting.md §6.10 (not a DoH failure)
:put [:resolve pornhub.com]     # standard resolver: a real IP (no filtering)
