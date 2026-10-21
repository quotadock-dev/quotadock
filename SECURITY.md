# Security policy

## Supported versions

`v0.1.0` is a source preview, not a hardened hosted service. Security fixes target
the current default branch; no older release support or response SLA is promised.

## Report privately

Do not disclose tokens, provider credentials, or an exploitable vulnerability in
a public issue. Use GitHub's **Security → Report a vulnerability** at
https://github.com/quotadock-dev/quotadock/security/advisories/new when private
reporting has been enabled by the repository owner. If that option is unavailable,
ask the maintainer for a private reporting channel in a public issue containing
only a general request — no exploit details or sensitive attachments.

Include affected revision, platform, a minimal reproduction using synthetic data,
expected/actual behavior, and impact. Review all attachments for identifiers.
Please allow coordinated remediation before public disclosure.

## Trust boundaries

- Provider sessions stay with the host's installed CodexBar. Only sanitized
  quota snapshots cross the bridge API boundary.
- Every snapshot request requires a bearer pairing token. Treat it as a secret.
- Web pairing uses tab-scoped session storage when available. Disconnect clears
  the current page, not the server's bearer token. If the browser refuses stored
  removal, the UI warns that an older pairing may return after reopening.
- Default loopback HTTP is for the same-host web client. Real devices require
  trusted HTTPS on private networking; never expose publicly without auth.
- Non-loopback native binding requires both TLS certificate and private key.
  Protect their files and token storage; never commit them.
- iOS stores tokens in device-only Keychain; widgets cannot access tokens. Watch receives only
  sanitized data. App Group and Watch caches still reveal usage patterns.
- Host compromise, malicious CodexBar binaries, stolen tokens, and compromised
  paired devices are outside the protection provided by sanitizing the API.
- Optional cloud stores quota plus pseudonymous Apple/session/billing/consent
  metadata; a database leak is not limited to quota alone. Scoped local collectors
  cannot manage users or subscriptions. Account deletion revokes collector grants.

Do not paste raw CodexBar JSON, auth headers, email addresses, account IDs, or
token-file contents into issues. Redaction helpers are not a universal data-loss
prevention system. Review locally and share only a synthetic reproduction.
