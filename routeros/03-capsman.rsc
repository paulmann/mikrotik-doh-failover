# 03-capsman.rsc
# CAPsMAN integration for legacy /caps-man (NOT the newer /interface wifi stack).
#
# This is optional and only for the CAPsMAN controller. It targets ONE
# configuration by name instead of [find] (which would change every
# configuration, including ones where another bridge or isolation is intended).

# ===== CONFIG =====
:local capConfig  "cfg1"           # your CAPsMAN configuration name
:local capBridge  "bridge-local"   # bridge the CAPs must join
:local dnsIp      "192.168.88.1"   # router IP handed to clients as DNS
# ==================

/caps-man configuration set [find name=$capConfig] bridge=$capBridge client-isolation=no

# DHCP: point the LAN clients' DNS at the router (or leave the router as-is if
# the DHCP network already sets dns-server correctly). Set the network by its
# exact address (the address field carries a CIDR, e.g. 192.168.88.0/24):
/ip dhcp-server network set [find where address="192.168.88.0/24"] dns-server=$dnsIp gateway=$dnsIp

# NOTE for newer hardware: the current wireless stack is /interface wifi
# (packages wifi-qcom / wifi-qcom-ac). If your APs use it, configure the
# equivalent settings there, not in /caps-man.
