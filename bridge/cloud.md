# Scoped cloud collector

Run Node 22+ with CodexBar installed and authenticated **locally**:

The cloud collector requires POSIX user IDs and private file permissions
(macOS/Linux). Windows credential-file/ACL support is not implemented; do not
disable the ownership checks to make it run. Live provider availability still
depends on the installed CodexBar build and its supported credential sources.

## Safe local diagnostics

```sh
node bridge/cloud.mjs doctor
```

Doctor is read-only: it does not create the configuration directory, redeem a
grant, collect quotas, or call cloud/provider APIs. It checks local grant shape
and expiry, private ownership/permissions, the maximum-50-slot batch and complete
bindings, then invokes only the configured CodexBar executable with `--version`
(no shell, two-second deadline, 4096-byte combined output limit). All child output,
including version text, is discarded. No tokens, fingerprints, account keys,
emails, paths or raw errors are printed. Exit 0 means local checks passed; exit 1
means at least one failed. It cannot verify remote revocation, authentication,
independent-account eligibility, or an installed build's quota-query features.
Only use a trusted executable; a malicious binary cannot be made read-only by
the collector. `QUOTADOCK_CODEXBAR_BIN` selects that executable.

CLI failures use fixed categories: `configuration`, `permissions`,
`grant_expired`, `revoked`, `bindings`, `unsupported_source`, `cli_availability`
and `service`, plus `unsupported_identity` and `ambiguous_scope` for identity
boundaries. Each includes recovery instructions rather than raw exception or
child text. Stop the worker before repairs or mapping changes. Never re-pair over
an existing grant: revoke on the phone and remove both old private files first.
Permission failures must be repaired, not bypassed; Windows ACL support remains
unimplemented. Run/once/accounts also check CLI availability with the same bounded
non-query probe before their normal network/query work. Unlike doctor, accounts
intentionally prints local fingerprints and can contact provider APIs.

```sh
node bridge/cloud.mjs pair https://YOUR-TRUSTED-QUOTADOCK-SERVER
node bridge/cloud.mjs run
# Or process at most one lease:
node bridge/cloud.mjs once
```

Use your deployment's trusted HTTPS origin (no path, credentials, or query).
Requests explicitly require certificate verification even if the inherited
`NODE_TLS_REJECT_UNAUTHORIZED` setting is `0`; redirects are never followed.
Enter the printed eight-character code on the phone and explicitly confirm selected slots.
The CLI never accepts Apple sessions or provider credentials. Its scoped grant
is stored exclusively in `~/.config/quotadock-cloud/collector.json` (0600 in
a private 0700 directory). Do not copy it into issues, logs or source control.
Revoke in the phone's collector list; remove the local file before re-pairing.
Grants expire after 30 days and are not silently renewed.

## Independent accounts

One unbound slot per provider uses CodexBar's current local login. Independent
slots require explicit durable selection keys. CodexBar HEAD `6480977b` public
CLI JSON excludes the internal top-level `cacheAccountKey`; installing a recent
build does not make `--all-accounts` JSON keyed. The collector fails closed with
`unsupported_identity` for missing keys or `ambiguous_scope` for duplicate keys,
never substituting the active account, labels or array order. The mapping commands
below require a separately verified keyed adapter; public CodexBar alone does not
establish that contract. Gemini remains one slot. Registering slots does not
create upstream eligibility or verify distinct quota owners.

```sh
# These commands query locally configured accounts, contacting provider APIs.
node bridge/cloud.mjs accounts codex oauth
node bridge/cloud.mjs accounts claude oauth
# Cookie accounts on a supported Mac use web, not oauth:
node bridge/cloud.mjs accounts grok web
# Copy the exact slot UUID on the phone; bind to a locally confirmed fingerprint.
node bridge/cloud.mjs map PHONE_SLOT_UUID codex LOCAL_FINGERPRINT oauth
```

Configure CodexBar's independent credentials/profiles first. Confirm which
account each opaque fingerprint represents locally before binding; the collector
cannot prove that two upstream logins have different quota owners. Account labels,
array positions and raw credentials are not accepted selectors. Fingerprints hash
CodexBar's durable account key, which may contain an email/workspace identifier;
only those hashes and slot bindings go into local `accounts.json` (0600).
They are never included in server observations. Do not share that file.

Every duplicate-provider slot in a grant requires a distinct explicit mapping.
Sources are pinned to oauth/web; Codex accepts oauth only. Missing or duplicate
keys produce unavailable readings, never another account's data. Mapping writes
are atomic; stop the worker while configuring and restart afterward. Changing
credentials may change a key and require re-confirmation. Re-pairing requires
removing old `accounts.json` as well as the old grant, after revocation.

A grant/batch has at most 50 slots. The phone selects a batch; initial selection
is the first 50 server-listed slots. An active Live session retains its server's
selection until stopped. Plan limits are Free 3 accounts/1 collector, Plus 10/3
and Pro 25/5; the 50-slot batch ceiling is not an account entitlement.
CodexBar `--all-accounts` may query unselected locally configured accounts within
that provider/source group; only explicitly selected matches are uploaded.
Verify this cost and provider policies before enabling frequent Live collection.
Only sanitized observations are sent, never identities, diagnostics, credentials
or raw command output. Multi-account behavior is fixture-tested, not yet verified
with real independently authenticated provider accounts.

`bridge/codex-app-server.mjs` is a standalone experimental adapter, not integrated
with this collector, cloud-ready or verified with real accounts. It exposes
workspace-scoped Codex quota without email, not verified human identities or
total ChatGPT usage. OpenAI's [app-server authentication documentation](https://developers.openai.com/codex/app-server#auth-endpoints)
states that app-server authentication is not permitted for commercial or hosted
services. It is not a production billing integration path. The passive
[Claude statusline parser](claude-statusline.md) is also standalone and has no
verified account attribution or provider observation timestamp. Neither reader
is connected to cloud accounts. No credential scraping is used or supported.

### Provider interfaces checked on 2026-10-17

- **Claude:** the documented [statusline JSON](https://code.claude.com/docs/en/statusline)
  supplies optional 5-hour/7-day usage, not a stable account identity or source
  observation time. The passive parser makes no new provider request. Anthropic's
  [credential restrictions](https://code.claude.com/docs/en/legal-and-compliance)
  still apply; a documented display field is not a commercial permission grant.
- **Codex:** the isolated app-server experiment reads only a Codex quota bucket,
  not total ChatGPT usage. Workspace identity is not unique human identity; the
  commercial/hosted authentication restriction above blocks product integration.
- **Gemini:** Google's [transition announcement](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/)
  ended consumer Free/Google AI Pro/Ultra access to Gemini CLI on 2026-06-18.
  Code Assist Standard/Enterprise and paid API-key paths are distinct. Do not
  promise that an old Gemini CLI consumer login still supplies quota; Antigravity
  account/quota integration has not been implemented or validated here.
- **Grok:** the official [consumer FAQ](https://docs.x.ai/grok/faq#usage--limits)
  documents percentage and weekly reset in **Settings → Usage**. That UI is not
  evidence of an authorized third-party consumer quota-export API. No such
  integration or permission has been established here; no cookie scraping added.

Collection is uncached, waits past the job's whole-second issue boundary, and
preserves CodexBar's source timestamp. Missing timestamps/data, stale source
results and provider failures cannot debit quota. Offline or timed-out leases
expire without debit. Temporary network errors back off; revoked grants stop
the process. In `run` mode, job polling targets 20-second spacing. Automatic
due checks target 20-minute spacing; the server enforces the tier's actual
120/60/20–120-minute interval. Disable local automatic updates in cloud settings
for manual-only collection. This continues while the computer is online even
after the phone session expires; it is not iOS background polling. Run only one
worker per grant/installation to avoid duplicate upstream calls. No demo/fabricated
observations are used.

Within one bounded operation, transient transport failures and HTTP 429/502/503/
504 may retry up to three sends. The original automatic request key/body and
sanitized completion body remain unchanged; retrying a completion never runs
CodexBar again. Operation time is at most 45 seconds, each HTTP request at most
15 seconds, and grant/job expiry bounds it further. Retry-After waits longer than
the internal retry budget are not shortened. 401/403, malformed replies, invalid
bindings and TLS validation failures are not automatically retried.

## Optional user-service setup

After explicit pairing, mapping and local `doctor` checks, the renderer prints
a service definition pinned to this checkout, the running Node executable and
your trusted CodexBar binary. It **never installs, enables, starts or pairs** a
service and never reads/copies private grant files or the invoking environment.
Run as your ordinary user, not root; do not place these in a system service.

```sh
# Inspect output first. Replace the binary path with your confirmed executable.
node bridge/service.mjs launchd --codexbar /absolute/path/to/codexbar
node bridge/service.mjs systemd --codexbar /absolute/path/to/codexbar
```

On macOS, save inspected LaunchAgent output to
`~/Library/LaunchAgents/com.quotadock.collector.plist`, then use your user domain:

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.quotadock.collector.plist"
# Stop before revoking, changing mappings, or repairing configuration:
launchctl bootout "gui/$(id -u)/com.quotadock.collector"
```

On Linux, save inspected output to
`~/.config/systemd/user/quotadock-collector.service`, then:

```sh
systemctl --user daemon-reload
systemctl --user enable --now quotadock-collector.service
systemctl --user stop quotadock-collector.service
```

Neither definition restarts after a fatal exit. Repair expiry/revocation,
permissions or bindings before explicitly starting it again. Transient retries
are internal to the collector. User-login/service-manager availability, installed
CodexBar credential support, and an awake online computer still matter. This
does not enable user lingering or promise collection while the host sleeps.
Regenerate after moving the checkout or replacing Node/CodexBar; pinned paths
and service environments can differ from your interactive shell. No tokens go
into a unit/plist. Service-manager/device runs remain release-gated until tested.
