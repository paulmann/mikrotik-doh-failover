# config.example.rsc
# All tunable values used across the routeros/ scripts, in one place for
# review. Copy the values you need into the corresponding script's CONFIG
# section (RouterOS scripts cannot "source" a shared file, so each script keeps
# its own CONFIG block and this file is documentation + a copy-paste reference).

# --- DNS / DoH (01-configure-doh.rsc, 05-dns-health-monitor.rsc) ---
# Cloudflare Family (blocks malware + adult):
:global dohUrl     "https://family.cloudflare-dns.com/dns-query"
:global dohHost    "family.cloudflare-dns.com"
:global dohServers "1.1.1.3,1.0.0.3"
# Cloudflare standard (no filtering):   use https://cloudflare-dns.com/dns-query, 1.1.1.1,1.0.0.1
# Cloudflare security (malware only):   use https://security.cloudflare-dns.com/dns-query, 1.1.1.2,1.0.0.2
# Quad9:                                use https://dns.quad9.net/dns-query, 9.9.9.9,149.112.112.112
# Google:                               use https://dns.google/dns-query, 8.8.8.8,8.8.4.4

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
