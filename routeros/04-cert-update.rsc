# 04-cert-update.rsc
# Optional periodic refresh of the DoH CA.
#
# For a single-provider Cloudflare setup this is usually NOT needed: the
# "SSL.com TLS ECC Root CA 2022" is valid until 2029-01-01, so a weekly job is
# pointless. Re-import the CA only if it is rotated or close to expiry.
#
# Security notes:
#   - Do NOT download a CA bundle over an untrusted channel with
#     check-certificate=no: an attacker on the path could substitute the bundle.
#     Prefer the specific CA from the CA's own site (certs/cloudflare-doh-ca.pem)
#     and verify its fingerprint.
#   - Do NOT toggle "verify-doh-cert=no/yes" to "reset the TLS session"; that
#     briefly disables certificate validation and is not a documented mechanism.

# ===== CONFIG =====
:local caFile "cloudflare-doh-ca.pem"   # already uploaded to the router
# ==================

/certificate import file-name=$caFile passphrase=""
/certificate set [find where name~"cloudflare-doh-ca"] trusted=yes
/certificate print where trusted=yes
