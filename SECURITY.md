# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| v0.1.0 (latest) | yes |
| earlier | best effort |

## Reporting a vulnerability

Do **not** open a public issue. Use GitHub Security Advisories ("Report a
vulnerability" on the repository's Security tab) or contact the maintainer.

Include:

- affected RouterOS version and the script/step;
- reproduction steps or a proof of concept;
- impact (DNS leak, bypass of the family filter, denial of service, privilege escalation);
- whether the issue is already public.

You will receive an acknowledgement and a remediation plan. Please allow time
for a fix before disclosure.

## What must never be committed

API keys, tokens, passwords, private keys, `.env` files, router configuration
exports that contain secrets (WireGuard private keys, pre-shared keys, user
passwords) and customer data.

## Security model of this project

- The scripts import a CA **explicitly**; they never use `check-certificate=no`
  in a persistent configuration (bootstrap-only at most).
- Script policies are narrowed to `read,write,policy,test`; the failover script
  does not carry `ftp`, `reboot`, `password`, `sniff`, `sensitive` or `romon`.
- The resolver drops DNS from WAN and only redirects classic DNS (53). Client
  DoH/DoT bypass is documented, not silently ignored.
