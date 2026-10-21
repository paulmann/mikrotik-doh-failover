# cloudflare-family.rsc
# Complete, self-contained example for Cloudflare Family DoH (1.1.1.3 / 1.0.0.3),
# as tested on RouterOS 7.23.1 / 7.24.5. Run after uploading
# certs/cloudflare-doh-ca.crt to the router.

# 1) NTP first (certificate validation needs accurate time)
/system ntp client set enabled=yes servers=162.159.200.1,216.239.35.0

# 2) Trust anchor
/certificate import file-name=cloudflare-doh-ca.crt passphrase=""
/certificate set [find where name~"cloudflare-doh-ca"] trusted=yes

# 3) Bootstrap static A records (so the DoH hostname always resolves)
/ip dns static add name=family.cloudflare-dns.com address=1.1.1.3 ttl=1d comment="DoH bootstrap"
/ip dns static add name=family.cloudflare-dns.com address=1.0.0.3 ttl=1d comment="DoH bootstrap"

# 4) DoH + plain fallback
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
:put [:resolve example.com]     # real IP
:put [:resolve pornhub.com]     # 0.0.0.0 (Family filter)
