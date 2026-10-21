# 00-install-ca.rsc
# Install the Certificate Authority required by verify-doh-cert=yes.
#
# WHY THIS IS NEEDED (verified on RouterOS 7.23.1 and 7.24.5):
#   verify-doh-cert=yes validates the DoH server's TLS chain. With no trusted
#   CA imported the resolver fails ("dns server failure") and, because
#   use-doh-server is the ONLY resolution path, the whole network loses DNS.
#   The built-in trust store (/certificate settings builtin-trust-store=default)
#   does NOT cover the Cloudflare DoH chain on these versions, so an explicit
#   import is mandatory. (There is no "builtin-trust-anchors" parameter.)
#
# For Cloudflare family / security / standard DoH the chain is:
#   Cloudflare Inc -> SSL.com -> Comodo AAA
# so the required root is "SSL.com TLS ECC Root CA 2022".
# The PEM file is shipped in certs/cloudflare-doh-ca.pem. Upload it to the
# router (WinBox -> Files, or scp/SFTP), then run:

/certificate import file-name=cloudflare-doh-ca.pem passphrase=""
/certificate set [find where name~"cloudflare-doh-ca"] trusted=yes

# Verify: you must see a TRUSTED cert "SSL.com TLS ECC Root CA 2022".
/certificate print where trusted=yes
