# Experimental Amp CLI adapter (not activated)

`readAmpQuota({ executable, home, path, timeoutMs })` in `amp-cli.mjs` is a
trusted local opt-in API, not an HTTP route or an account-slot collector.
Supply an absolute CodexBar executable, a canonical owner-only (0700) isolated
home directory provisioned by the operator with Amp CLI login, and an explicit
absolute-directory PATH containing the Amp executable and its runtime.
There are no ambient home, PATH, token, proxy, or executable defaults. The
adapter does not read credentials or extract sessions. Do not expose these
arguments to HTTP callers. A home directory is not verified account identity;
OS keychain/login-shell behavior inside upstream tools is not attested here.

Only `usage --provider amp --source cli --format json --json-only` is invoked.
No shell, all-accounts, auto, API or browser retry is used. stdout is limited
to 1 MiB; deadline defaults to 12 seconds (allowed 50–30000 ms); owned process
groups are killed on completion/failure on POSIX. stderr is discarded.
Nonzero exits, missing executables, malformed JSON and bounds violations throw
sanitized `Amp quota: <code>` errors without upstream diagnostics.

The separate result contains `experimental`, `provider`, `source`, `state`,
`observedAt`, and `windows`. States are available, unavailable (recognized but
unmeasured windows), unsupported (unrecognized/ambiguous contract), or error
(upstream provider error). Only finite measured used percentages in [0,100]
become remaining percentages. Agent, Orb and Free remain distinct. Synthetic
or invalid measurements remain null. Credit balances, dollar amounts, details,
identity, arbitrary labels and diagnostics are never copied or converted.
Legacy Other usage is deliberately not interpreted as Agent.

Contract reference: steipete/CodexBar revision
`489aad74fbd55a22db570c025b6d57aac654cd5a`, specifically
`AmpProviderDescriptor.swift` (CLI strategy has no fallback),
`AmpUsageSnapshot.swift` (Agent/Orb primary/secondary and named amp-free extra
window), and `CLIPayloads.swift` (source and rateWindowLabels). Tests use fake
executables only; real installed-version compatibility remains unverified.

Activation requires a coordinated shared provider/schema change across bridge,
web, Apple and cloud validation, preserving extra windows and status semantics;
explicit local service configuration and opt-in selection; and a verified
account-scope mechanism before multi-account binding/upload. Upstream payload
omits cacheAccountKey, so do not bind by row order, email or ambient account.
The existing four-provider defaults, collector and snapshots are unchanged.
