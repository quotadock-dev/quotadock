# EXPERIMENTAL standalone Codex allowance reader

This is a local supported-machine-interface candidate, **not integrated with the
server, collector, cloud, native app or phone**. No real-account validation has
been performed. It measures Codex allowance, not total ChatGPT usage.

## Contract and invocation

Node's `readCodexQuota({codexHome, executable, scopeKey, timeoutMs})` starts one
dedicated owned stdio child with fixed arguments, no shell. Both paths must be
explicit absolute trusted local configuration; the existing home must be owned,
not group/world writable, and exactly its realpath (no symlink aliases). The
executable defaults to `/usr/local/bin/codex`; explicitly select an installed
official Codex executable. Do not expose executable/home/endpoint selection to
HTTP. The reader never discovers profiles or reads/copies auth files or keyrings.
Codex itself uses its existing auth/config; config files are not edited by this
reader. User configuration and installed executables remain a local trust boundary.

Standalone CLI:

```sh
# Provision a private stable random >=32-byte local key outside this command.
export QUOTADOCK_SCOPE_KEY='your-private-stable-random-key-at-least-32-bytes'
node bridge/codex-app-server.mjs /absolute/existing/codex-home /absolute/bin/codex
```

Do not use the example literal as a production key. The HMAC fingerprint binds
the local canonical home and provider workspace ID; changing the key changes
fingerprints. Neither raw workspace ID nor email is exported. Email is compared
only as an in-memory change signal, never as verified identity or a selection key.

Protocol reference: official [app-server documentation](https://developers.openai.com/codex/app-server)
and openai/codex commit `ce0323f2f2d3b25e82806cd555237da3db4e1897`, specifically
`codex-rs/cli/src/main.rs`, `core/src/config/mod.rs`, and
`app-server-protocol/src/protocol/v2/account.rs` plus generated v2 schemas.
CLI `-c` overrides pin `chatgpt_base_url` to the source's official default
`https://chatgpt.com/backend-api/`, disable analytics/feedback/system proxies,
and select `app-server --listen stdio://`. Inherited environment is allowlisted:
HOME, USER, LOGNAME, TMPDIR, SYSTEMROOT plus fixed PATH and selected CODEX_HOME;
auth, backend, proxy and TLS override environment variables are not inherited.

The sequence is initialize (experimentalApi=true), initialized, account/read
(refreshToken=false), account/rateLimits/read (excludeResetCreditDetails=true,
supportsLunaReserve=false), account/read (refreshToken=false). No login, token
export, inference, credit consumption or fabricated provider traffic occurs.
Codex may perform its own normal auth maintenance; false does not promise that
the underlying CLI never refreshes credentials during a quota request.

Only ChatGPT accounts with known plan enum, requiresOpenaiAuth=true, and nonempty
experimental workspaceRouting.chatgptAccountId are accepted. Before quota, routing
must report backendOrigin exactly `https://chatgpt.com` with
accountRoutingOverride `NO_CONSTRAINT`; custom and regional routing fail closed.
Both account reads must agree on workspace, plan and nullable email. Quota's
nonnull backend `accountId` must match that workspace. Missing installed-version
metadata, provider errors and account/login change notifications discard the
sample. No label/order/email fallback exists. Unexpected/out-of-order response IDs
fail closed (requests are deliberately serialized). Rate-limit notifications are
not substituted for the requested attributed response.

Only the `codex` bucket is exported (map entry preferred, otherwise explicitly
identified single-bucket view); unknown buckets/plans fail closed. Other buckets,
credits, banners and arbitrary provider strings are not exported or summed.
Nullable primary/secondary means unknown, never zero or unlimited. Integer percent
zero remains zero. Window duration is minutes and resetsAt stays Unix **seconds**;
null reset remains unknown and old reset times are not advanced. `receivedAt` is
local receipt time; `providerObservedAt` is always null because the provider has
no observation timestamp. Repeated responses need not be fresh samples.

Bounds: 8s default deadline (50ms–30s configurable), 64KiB frame, 256KiB total
stdout and 64KiB stderr. Private stdout/stderr are not logged. Errors use fixed
codes, never provider text. Only the owned detached process group is terminated,
TERM then KILL with a 120ms cleanup allowance. POSIX ownership/process groups
are required; Windows support is not claimed.

## Attribution limits and integration requirements

Backend account IDs identify provider workspaces/accounts, **not unique humans**.
Different users sharing a workspace cannot be distinguished by these IDs. The
bracket catches observed changes but cannot prove arbitrary undelivered A→B→A
switches, nor changes after the final account response. The caller must not
advertise verified-person attribution. No provider observation freshness claim
is possible. Installed versions without this experimental contract are unsupported.

Integrators must explicitly provision trusted home/executable/key, preserve
unknown/freshness semantics, prevent overlapping profile mutation if stronger
attribution is needed, and keep this opt-in and experimental. Do not merge this
output into a server/phone account on the basis of labels, order or email.
CodexBar public JSON lacks selection keys and is not a substitute. Upstream docs
explicitly state that app-server authentication is not permitted for commercial
or hosted services. This experiment is not connected to QuotaDock's paid or
hosted service. A commercial product needs a separately permitted authentication
and data interface; the existence of a quota method is not that permission.

Tests use disposable fake stdio executables only:

```sh
node --test bridge/codex-app-server.test.mjs
node --test bridge/*.test.mjs
```
