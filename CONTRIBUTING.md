# Contributing

## Before you start

- Read the [README](README.md) and [`docs/`](docs/).
- For a non-trivial change, open an issue first.
- Security issues are reported privately per [SECURITY.md](SECURITY.md).

## Verification rules (specific to this project)

RouterOS behaviour varies between versions. A claim is accepted only when it
was verified on a concrete version, and the report must name that version.
Guesses are rejected.

- State the RouterOS version (`/system resource print` → `version`) and
  `device-mode` for every test.
- Quote the exact error from `/log print where message~"connection error"`.
- A `.rsc` script must be imported on a real device before it is merged; a
  syntax that only "looks right" is not a test.

## Development

1. Fork and create a feature branch from `main`.
2. One logical change per commit.
3. Run the scripts on a test device (`/import file-name=...`).
4. Update the relevant `docs/` page and the compatibility table in `README.md`.
5. Open a pull request describing the change, the RouterOS version tested, and
   the verification output.

## Commit messages

Imperative subject, one logical change. Body explains *why* and names the
RouterOS version verified.

## File rules

- No secrets, tokens, private keys, or router exports with credentials.
- UTF-8 without BOM, LF line endings (`.gitattributes` enforces this).
- `routeros/*.rsc` keep one logical block per file; tunables live in a
  `# ===== CONFIG =====` block at the top.
- Keep the README honest: measured numbers, known limits, no unverified claims.
