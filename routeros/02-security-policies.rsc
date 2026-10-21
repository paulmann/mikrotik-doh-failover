# 02-security-policies.rsc
# Force LAN clients through the router resolver and protect the resolver itself.
#
# Honest scope: these rules redirect CLASSIC DNS (UDP/TCP 53) to the router.
# They do NOT stop a client from using its own DoH (TCP 443), DoT (TCP 853) or
# hardcoded resolvers. To also reduce DoT bypass, uncomment the TCP/853 drop
# block at the bottom; blocking client DoH over 443 needs a proxy/DPI and is out
# of scope here.

# ===== CONFIG =====
:local bridge   "bridge"    # LAN bridge name (e.g. bridge / bridge1)
:local lanList  "LAN"       # interface list that contains LAN interfaces
:local wanList  "WAN"       # interface list that contains WAN interfaces
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

# 4) Optional: block DoT to public resolvers (TCP 853) for LAN clients.
# /ip firewall filter add chain=forward action=drop protocol=tcp dst-port=853 in-interface-list=$lanList comment="block DoT out"

# Verify:
/ip firewall nat print where comment~"force DNS"
/ip firewall filter print where comment~"DNS" or comment~"DoT"
