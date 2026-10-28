# 02-security-policies.rsc
# Force LAN clients through the router resolver and protect the resolver itself.
#
# Honest scope: the standard mode redirects CLASSIC DNS (UDP/TCP 53) to the
# router. It does NOT stop a client from using its own DoH (TCP 443), DoT
# (TCP 853) or a hardcoded resolver. The optional `enforcement=strict` mode adds
# a DoT block and a block of the well-known public DoH endpoints, but even then
# blocking client DoH over arbitrary HTTPS/443 needs a proxy/DPI and is out of
# scope. A strict profile does NOT claim 100% coverage; it documents the residual
# risk instead of hiding it.
#
# AND — measured 2026-10-26, easy to miss — the redirect rules do not apply to
# clients that already ask the router itself (the address handed out by DHCP).
# Such a query arrives on the router's own address, is answered locally, and
# never enters the dstnat chain. Consequence: "per-client resolver" policies
# built on dst-nat simply do not work for those clients. If you need different
# resolvers per client, hand out the resolver address by DHCP or run a separate
# resolver — do not rely on redirect.
# ===== CONFIG =====
:local bridge   "bridge"    # LAN bridge name (e.g. bridge / bridge1)
:local lanList  "LAN"       # interface list that contains LAN interfaces
:local wanList  "WAN"       # interface list that contains WAN interfaces
:local enforcement "standard"   # "standard" | "strict"
# ==================
# 1) Force-DNS: redirect every DNS query arriving on the LAN bridge to the router.
#    `redirect` rewrites the destination to the router's own address on that
#    interface (prefer it over dst-nat to a hardcoded local IP).
/ip firewall nat add chain=dstnat action=redirect protocol=udp dst-port=53 in-interface=$bridge comment="force DNS UDP"
/ip firewall nat add chain=dstnat action=redirect protocol=tcp dst-port=53 in-interface=$bridge comment="force DNS TCP"
# 2) Allow DNS to the router from LAN (UDP AND TCP - both are required).
/ip firewall filter add chain=input action=accept protocol=udp dst-port=53 in-interface-list=$lanList comment="DNS UDP from LAN" place-before=0
/ip firewall filter add chain=input action=accept protocol=tcp dst-port=53 in-interface-list=$lanList comment="DNS TCP from LAN" place-before=0
# 3) Drop DNS from the outside so the router is not an open resolver.
/ip firewall filter add chain=input action=drop protocol=udp dst-port=53 in-interface-list=$wanList comment="drop DNS UDP from WAN" place-before=0
/ip firewall filter add chain=input action=drop protocol=tcp dst-port=53 in-interface-list=$wanList comment="drop DNS TCP from WAN" place-before=0
# 4) Strict enforcement: block DoT and the well-known public DoH endpoints.
#    Residual risk: DoH over an unknown endpoint or a hardcoded CDN IP on 443
#    still passes; fully closing that needs a proxy/DPI.
:if ($enforcement = "strict") do={
    /ip firewall filter add chain=forward action=drop protocol=tcp dst-port=853 in-interface-list=$lanList comment="block DoT out (strict)" place-before=0
    /ip firewall address-list add list=public-doh address=1.1.1.1 comment="Cloudflare"
    /ip firewall address-list add list=public-doh address=1.0.0.1 comment="Cloudflare"
    /ip firewall address-list add list=public-doh address=8.8.8.8 comment="Google"
    /ip firewall address-list add list=public-doh address=8.8.4.4 comment="Google"
    /ip firewall address-list add list=public-doh address=9.9.9.9 comment="Quad9"
    /ip firewall address-list add list=public-doh address=149.112.112.112 comment="Quad9"
    /ip firewall filter add chain=forward action=drop protocol=tcp dst-port=443 dst-address-list=public-doh in-interface-list=$lanList comment="block known DoH endpoints (strict)" place-before=0
}
# Verify:
/ip firewall nat print where comment~"force DNS"
/ip firewall filter print where comment~"DNS" or comment~"DoT" or comment~"DoH"
