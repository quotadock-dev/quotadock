# Release plan and failure contracts

Source-preview plan, documentation updated 2026-10-17. Implemented code is not a signed release or proof
of Apple purchases, provider access, public HTTPS or physical-device behavior.
Release gates remain open until their real-stack scenarios below pass.
Historical validation below applies to its tested revision. The 2026-10-17
product-review follow-up is described separately near the end; neither is
acceptance of real Apple/provider/device behavior.

The historical 2026-10-14 12:00 KST gate passed. [Post-noon application CI](https://github.com/quotadock-dev/quotadock/actions/runs/38506753875)
passed 73 native tests and iPhone/Watch/WidgetKit builds, 30 Node 22 tests and
10 imported skill tests; the root-only service test also passed separately.
Private-backend CI passed 127 HTTP/cryptography/disposable PostgreSQL tests.
Real local TLS and disposable Compose probes reproduced and fixed certificate
validation, long-fraction timestamp and proxy address-allocation defects.
Six affected/demo states were inspected. These results validate source contracts,
not real Apple/provider/device flows or activation of the new server source.

## English/Korean first-run acceptance

The first-run draft records only local route/refresh preferences, never credentials
or cloud consent. First completion requires an explicit demo, bridge, cloud or later
choice. Bridge/cloud choices open their real connection screens; they do not create
authority. Existing paired users choosing Later may resume their existing connection
when refresh-on-open is enabled. Demo remains in memory and never replaces saved
observations or becomes the Watch language-sync payload.

Language changes apply immediately, including during a revisited wizard. Cancel
discards that visit's route/refresh draft, not the global language preference.
Finishing saves the refresh choice before the completion record; a session-only
save-failure escape must also honor manual-only refresh. Broken/unsupported drafts
restart setup without overwriting the prior refresh setting.

The [bilingual baseline](https://github.com/quotadock-dev/quotadock/actions/runs/38662891736)
passed both EN→KO and KO→EN simulator interaction flows, including retained choices,
cancel/relaunch and dashboard redraw. Browser contracts exercise stored/blocked
preferences, retained pairing/readings and demo state. A separate 320px doubled-text
stress probe found real English selector and Korean heading overflow; the public
website fix and regression passed [website CI](https://github.com/quotadock-dev/quotadock-web/actions/runs/38664282127).
This is not Safari zoom, physical-device text sizing or completed release acceptance.

The [pushed connection/cache validation](https://github.com/quotadock-dev/quotadock/actions/runs/38728138540)
passed all 96 native unit tests and all three simulator interaction flows, including
separate initially-off cloud consents, activation and withdrawal. iPhone, Watch and
WidgetKit builds passed. The previous cache failure reproduced with signing disabled:
the host was not entitled to its App Group. Simulator-only ad-hoc signing restored
that entitlement and the unchanged 5,000-slot/cache-retention test passed. This uses
no Apple account or development certificate and does not verify physical-device
provisioning, real Apple authentication or Watch delivery. Source is pushed to the
existing PR branches; no merge or deployment is implied. Consult current PR checks
for later revisions rather than treating historical results as current acceptance.

On a signed iPhone, repeat fresh install and upgrade from an existing pairing in
both languages and System mode. Interrupt each setup step, relaunch, switch language
with a draft open, cancel a revisit, then finish with refresh-on-open disabled/enabled.
Confirm the last observed values and timestamps survive; a cloud route still needs
both separate consents and real Apple authorization. Exercise all three steps and
connection forms at large accessibility text sizes with VoiceOver, not just captures
of the top viewport. Add Home/Today/Lock widgets and a paired Watch in each language;
verify the saved preference eventually propagates without replacing quota with demo.
OS-scheduled widget reloads and asynchronous Watch delivery have no exact-time promise.
These signed-device checks remain open.

## Account and data boundaries

The phone owns its Apple-derived opaque access/refresh credentials in device-only
Keychain. Access lasts at most one hour, within a fixed absolute 30-day login
family. Foreground operations coalesce renewal before the access deadline;
rotation never extends the family. The original renewal UUID, start time and
two-send reservation survive restart. A same-key retry can recover only the
immediate unused child within the server's 60-second window; spent-token replay
outside that contract revokes the family and its access credentials. There is
no automatic replay of a rejected mutation. Legacy access-only sessions still
require sign-in on expiry. Logout uses the refresh credential to revoke the
captured family even if access expired; erasure cascades all families. These
are validated simulator/disposable-server contracts, not proof of persistent device login.
The computer owns provider credentials and a separately revocable scoped
collector grant. Watch/widgets receive sanitized quota and original timestamps,
not either credential. The server owns tier enforcement and job accounting.
Its database also stores pseudonymous identity, consent, hashes, transaction
identifiers and counters; a database leak would expose that metadata too.

Free supports 3 accounts/1 collector, Plus 10/3, Pro 25/5. Every refresh selects at most 50.
Due intervals are Free 120m, Plus 60m and Pro 20/30/60/120m. A successful early
Free batch costs one of 10 allowances per KST day, not one per account. Plus
Live allows 5 sessions per monthly benefit period (also on annual billing), Pro 5 per KST day.
The server starts Live's 30-minute deadline on first fresh measured success.
Local collection needs an online computer; iOS background and WidgetKit timing
cannot guarantee these intervals.

## Refresh completion: implemented source

1. Submit selected IDs, mode and a new idempotency UUID; validate the job's mode,
   target IDs, state and expiry. Auto may target only the due subset.
   Transient uncertainty retries the same serialized body/key, at most two sends
   within one 60-second operation. Continuing an unchanged batch first resolves
   `/v2/jobs/request/:key`; known jobs are polled, not reposted. A definitive
   rejection clears the intent. Auto/force commands are saved before sending in
   the phone-only device-bound Keychain; unknown outcomes survive process restart
   only within the same login family, including normal bearer rotation; legacy
   records remain bound to their exact access credential. The saved command contains
   selected UUIDs, mode, original key and exact body, not a bearer token. Recovery
   rechecks owned slots after a successful server read and then resolves that
   key. Inaccessible, malformed or no-longer-owned saved commands block refresh
   sends, not validated server reads; a later read retries recovery without
   deleting the unresolved record. Explicit clear/sign-out resets that state.
   Foreground auto-refresh continues an unresolved forced command instead
   of issuing a different key. Logout, account switch, selection change after
   successful recovery and terminal completion discard it. Live commands remain memory-only; resuming
   Live after restart still requires explicit opt-in and server session state.
2. Poll the returned job ID every five seconds, for at most 60 seconds in the
   foreground. Each lookup rechecks the session and tenant under the owner lock.
3. `cached` means no due collection; `expired` means the lease ended. `completed`
   includes failed/stale collection, **not necessarily fresh quota**.
4. After a terminal result, perform one authoritative owned snapshot traversal
   and derive the slot list from those same rows. It reads at most 20 pages of
   250 rows/5,000 slots, 8 MiB and 60 seconds, spacing request starts by at least
   500 ms without weakening server limits. Legacy first-page 404 fallback also
   validates against an owned account list. Preserve last usable data on failure.
5. Background, lock, logout and account switch cancel waiting. A polling timeout
   does not cancel the server job, fabricate quota or spend a credit. An explicit
   retry of the unchanged batch resolves/resumes that same intent. The collector
   can still complete the five-minute lease; a later read sees it.

An old backend without job lookup makes waiting unavailable, not successful.
Deploy the status endpoint and 250-row page support before this client; an old
50-row-only page route returns 400, not the legacy-fallback 404. New quota date
strings are bounded to 64 ASCII bytes, without changing their original value;
legacy oversized records need inspection before rollout, not invented timestamps.
Malformed replies, foreign job IDs, changed targets and changed leases are
rejected. Observation timestamps never stand in for job identity.

## Purchases and restoration: implemented source, sale disabled on pilot

1. Read authenticated `/v2/me`. Purchases need server availability, its UUID
   `appAccountToken` and the current session; quota/provider plans grant nothing.
2. Load the four known monthly/annual auto-renewable Plus/Pro products in one
   subscription group. Korean targets are Plus KRW 2,990/month or 29,900/year,
   Pro 5,990/month or 59,900/year; only StoreKit `displayPrice` is displayed.
   Both tiers charge from first purchase with no introductory offer or free trial.
   Remove introductory offers from all four products in App Store Connect before
   enabling sales. The app rejects products with such offers and does not query
   introductory eligibility. Recheck offer absence, period, group and price before
   purchase; changed metadata stops purchase and asks for reload.
   Show annual totals and renewal terms. Unavailable products cannot be purchased.
3. Purchase with that UUID; pending approval and cancellation do not grant access.
4. Require StoreKit verification and exact account ownership. Send the bounded
   signed transaction transiently to the server; never persist or log the JWS.
   The server verifies Apple signatures, app/environment, ownership and replay,
   then queries current App Store state for that exact original chain/group and
   verifies the returned transaction/renewal. Historical validity alone is not
   a paid grant. Missing current-state configuration disables purchases; upstream
   failure leaves verification unconfirmed, rather than trusting an old receipt.
5. Finish only after a valid accepted server response. A server `free` response
   also acknowledges an expired/refunded transaction but grants no paid tier.
   Re-read only `/v2/me`; the purchase model never assigns Plus/Pro itself.
   Receipt delivery does not traverse quota pages or rewrite quota caches and
   selection. A concurrent quota read coalesces pending entitlement reads into
   one follow-up, scoped to the same session revision and foreground authority.
   Live preflight also reads metadata only; terminal jobs still reload quota
   pages. It waits while another request/read owns the model instead of treating
   a skipped send as an unconfirmed collection.
6. Keep the update listener for app lifetime. Recover unfinished transactions and
   current entitlements once on a new configured session. Explicit Restore alone
   calls `AppStore.sync`; ordinary quota reads do not repeatedly upload receipts.
7. Deduplicate the same in-flight transaction, but retain newer signed updates
   (including refund/revocation) for another pass. Logout/server/session/account
   changes invalidate completions and clear queued receipts/products.
   A 401 during receipt delivery also invalidates cloud authority, stops Live
   and requests sign-in again; it never finishes the unconfirmed transaction.
8. Network/server failure leaves delivery unconfirmed for reconnect/Restore;
   new unfinished transactions are not finished. Different-cloud-account purchases
   are refused, not silently transferred. Account erasure does not cancel Apple's subscription; link to
   Apple's subscription management and explain this before purchase/erasure.

Account erasure followed by a new cloud registration creates a new UUID. The
current implementation consequently refuses an old subscription's account token,
even for the same Apple sign-in. Define and validate an authenticated recovery
policy before opening sales; never bypass ownership or retain erased identity
records silently to make Restore appear successful.

The native billing policy permits purchases/recovery/receipt delivery only at
the official HTTPS `usage.mvtp.cloud` origin, default port 443, without credentials,
custom path, query or fragment. Custom origins cannot honor these products merely
by using HTTPS. Signed StoreKit verification of this guard, including old saved
custom-origin sessions, remains required before sales.

A client-only signed ownership/count proof cannot preserve Live spending across
repeated erasure: an older valid proof can replay a lower count. One proposal is
an explicitly disclosed, bounded HMAC purchase-period/day ledger retained after
erasure, combined with authenticated ownership recovery. That changes the deletion
promise and requires privacy/product approval before implementation. It also
needs a defined proof-loss/reinstall path, recovered notification ownership and
the existing per-user Pro-day semantics across multiple purchase chains. No such
ledger or erased-account recovery is implemented; sales stay closed.

## Credential and cache failures

Before presenting Apple authorization, the client rejects a challenge unless it
has exactly the three documented fields, a canonical UUID, a 43-byte base64url
nonce and the server's 300-second lifetime. A response arriving after background,
lock or cancellation cannot start the Apple dialog. These source guards need
native tests; they do not replace server nonce consumption or signature checks.

Cloud 401, an expired login family or an expired legacy session clears device-only
authority and invalidates in-flight completions without deleting usable quota
observations. Access expiry within a valid family first permits foreground
renewal. Inaccessible or failed Keychain replacement never deletes an old usable
credential first. A failed/old/exhausted pending renewal remains saved and blocks
new authorization sends until explicit sign-out/reconnection; no new key is
issued with a possibly spent parent. Parsed fresh grants that cannot be saved
or lose foreground authority are revoked best-effort; completely lost auth
responses can leave unconfirmed server families until their fixed deadline.
Quota reads track their own revision so a superseded metadata response cannot
release a replacement account's read ownership or publish another owner's data.
While login or remote erasure is busy, the form freezes the selected server and
consents. Erasure clears local authority first and displays pending confirmation;
it does not declare server deletion successful before the bounded response.
Bridge 401/403 have fixed reconnect/access-policy
messages, without displaying server bodies or diagnostics. HTTPS bridge fetches
reject redirects and cookies, have a 20-second absolute deadline and a 256 KiB
stream limit, including silent or trickling bodies. Pairing URLs are limited to
2,048 UTF-8 bytes and the encoded Keychain item to 8 KiB on both save and load;
oversized or insecure stored pairings do not start a request.

### Implemented source; open native gate: persistent connection selection

The previous separate bridge/cloud items could disagree with the last user choice
after failed deletion or termination between switch writes. Source now replaces
them with one phone-private `WhenUnlockedThisDeviceOnly` Keychain union containing
`signedOut`, `bridge` or `cloud`, its selected credential and cache generation.
Transitions validate the destination, atomically advance the App Group generation,
replace the union, install memory and only then clean up inactive bytes. No cache
or Watch/widget payload contains this union. Renewal conditionally replaces the
exact selected cloud credential without advancing its generation.

Missing, unreadable, malformed or generation-mismatched state never falls back to
another credential or repairs a manifest from old authority. Legacy markerless
installs intentionally **require reconnect on upgrade**; silent cloud-first import
cannot distinguish a legitimate legacy login from a prior failed removal.
Legacy deletion accepts only success/not-found; cleanup failure is reported
separately from committed disconnection. A rejected cloud credential becomes
signed out while sanitized observations remain; failed rejection attempts a new
fence and blocks the process. If **no durable write succeeds**, persistent
disconnection cannot be promised across restart; the UI reports it unconfirmed.

Portable Foundation contracts reconstruct storage after interrupted/failed
commits, cover both switch directions and logout, reject late renewal, preserve
old credential bytes on replacement failure and reject malformed/legacy state.
The real bridge transport also checks authority at request admission; rejected
admission does not start its URLProtocol. These are Linux/portable contracts, not
device process-kill tests. The pushed simulator run above compiled the native
Security.framework adapters and passed injected adapter/cache/model contracts;
it does not exercise real device lock or account authorization. Before closing
the gate, repeat on signed
iPhone with actual Keychain success/not-found/failure, lock/restart and terminated
switches, and observe the credential (or absence) reaching actual HTTPS transport.

### Implemented source; open native gate: failed cache invalidation

Shared and phone-private cache filenames are generation-bound. Reads and writes
check the current manifest before and after I/O; an old-owner completion cannot
publish into the new namespace. Logout/switch advances the fence before authority
replacement, so failed physical deletion does not reactivate readable old files.
Watch sends reread gated phone disk instead of accepting arbitrary captured
snapshots; activation and language sync use the same source. Watch reception
advances its local generation and retries obsolete-file cleanup after successful
storage, avoiding unbounded normal-update accumulation. Original observation
timestamps are never replaced by generation changes or local persistence times.

Non-root portable tests use real readable-but-undeletable files, verify exclusion
after reconstruction, and retry cleanup without deleting current/foreign files.
They also cover exact 256 KiB and oversized write/read boundaries. App Group file
protection, Watch activation/language sync, WidgetKit reload, failed Keychain
selection and offline devices still need native integration and signed-device
testing. A committed logical fence is not secure disk erasure or an instantaneous
removal of content already rendered by the OS or an offline Watch.

### Browser recovery boundary verified locally

The React bridge dashboard accepts HTTP 200 only. Fixed EN/KO recovery guidance
distinguishes pairing refusal (401), access policy (403), throttling (429) and
collector failure (503); other failures use generic guidance. Error bodies are
cancelled without parsing, and neither diagnostics nor account addresses enter
the rendered UI. Last observations and their timestamps survive failure.
A real local HTTP server's endless 403 stream closes when recovery appears; the
same browser regression fails with cancellation removed and passes when restored.
This validates the browser boundary, not actual provider authentication.

The phone's Watch outbox keeps only the latest sanitized intention. Activation
reconciles from authoritative phone disk: an absent cache queues an empty,
non-demo snapshot even after process restart. A clear arriving before activation
must not silently leave old quota on Watch. WCSession acceptance is not delivery
confirmation; offline devices can retain previously rendered content until the
OS delivers the new snapshot. Widgets only read sanitized local cache.

## Recovery must not reopen obsolete authority

A database backup can predate logout, refresh rotation, refund or account erasure.
Restoring it can consequently revive a spent credential, an erased account or a
previously paid entitlement. An empty-database restore proves none of those
boundaries. Keep restored user data isolated from public traffic until the recovery
procedure invalidates restored access/families, collector grants, pairings and
challenges, reconciles current subscription state, and accounts for erasures made
after the backup. Force phone sign-in and collector re-pairing; keep the stable
pseudonym key, rather than rotating it to simulate credential invalidation.

The erasure reconciliation source, backup/offsite retention and recovery objective
still need a disclosed policy and tested procedure. Do not silently introduce a
retained erasure journal. A restored instance must stay closed if that evidence
is unavailable. This is a release gate, not an implemented recovery automation;
shared-database restore or invalidation requires separate operator approval.

## Workstation-first plan screen and account labels — 17 October 2026

The owner stopped Mac/device work after manually trusting and opening the isolated
QD Preview app. Its physical UI assertions did not run; runner compilation is not
runtime acceptance. No later workstation change is installed on that phone.

Settings and cloud management now link to a dedicated Free/Plus/Pro screen. Real
prices remain StoreKit-owned and paid status remains server-owned. The browser
comparison is read-only, without checkout or development/launch-target banners.
Product screens omit placeholder purchase buttons; unavailable products cannot
be purchased. The dashboard person icon opens an account sheet with private
labels, UUID-specific collector approval and confirmed account removal. Approval
is scoped to the current login family, not inferred provider sign-in. The actual
local CLI account still requires its independent fingerprint mapping.
User-entered cloud slot names/emails stay phone-private and are never added to
collector payloads, App Group snapshots or Watch transfers.

Product-review follow-up: the app passed its build, 30 Chromium contracts,
55 bridge contracts (one root-only skip), 10 imported skill contracts and
31 nonroot Linux Foundation tests. The landing passed 18 browser contracts,
its build and Chromium/macOS WebKit CI. EN/KO monthly/annual plans and expanded
terms at 320/390/1440 pixels were rendered and inspected. Disposable PostgreSQL
backend tests passed 74 Python and 127 separate legacy Node contracts; dependency
audits found no known vulnerabilities at the checked versions.

The reauthorized isolated Mac check compiled all four Apple targets with
Xcode 27.1 and passed 110 hosted units, four production onboarding UI tests,
31 macOS Foundation contracts and six isolated presentation tests. Original
renewal ownership/coalescing assertions remain unchanged. The new EN/KO footer
regression proves the last paragraph scrolls fully above Finish setup, with
44pt clearance. Shared widget/Watch hosts cover fixed UUID/window selection,
missing UUID, zero/unknown/stale, monthly/annual Plus offers, Pro without trial
and large text. Hosts and inert callbacks do not establish actual StoreKit
eligibility, system widgets or paired Watch delivery. Those, provider access,
recovery and eligible Apple Team gates below remain open.

## Release sequence and required evidence

Current schema-v3 account surfaces use fixed UUID/window widget selections,
medium comparisons, UUID deep links and Watch account/window selection. Missing
selections remain unavailable; legacy static widgets/Watch projections still
show only the first account per provider. Labels/emails remain phone-private and
unverified. Real WidgetKit rendering and paired Watch delivery are open gates.

CodexBar HEAD `6480977b` public CLI JSON omits internal `cacheAccountKey`.
Recent installation alone does not enable keyed `--all-accounts` output; cloud
multi-account collection fails closed with `unsupported_identity`/`ambiguous_scope`.
The standalone experimental `bridge/codex-app-server.mjs` is not integrated,
cloud-ready or real-account verified. It exposes workspace-scoped Codex quota
without email, not verified humans or total ChatGPT usage. No credential scraping.

| Stage | Exit evidence | Current gate |
|---|---|---|
| Source integration | Real HTTP/Postgres policy tests, simulator native tests and inspected UI states | Post-noon checks above passed; physical-device/provider/Apple behavior remains open |
| Private pilot | New API healthy, unauthorized requests refused, resource caps preserved; no unrelated services changed | Dedicated VM runs the prior pilot; new source/schema not activated, public DNS/TLS absent |
| Bilingual first run | Fresh/upgrade setup, interruption, language switch, cancelled draft, manual refresh, large text and VoiceOver in EN/KO/System | Simulator/browser contracts and inspected renders; signed-device acceptance remains open |
| Identity/device | Valid HTTPS; signed iPhone nonce login, rotation/restart/replay, family expiry, logout and erasure; no credentials in shared caches | Apple Team/provisioning and owner DNS |
| Provider collection | Actual owned CLI slots; fresh/null/error/stale readings, offline collector and independent account mapping | Real accounts not exercised |
| StoreKit sandbox | Buy/cancel/Ask to Buy/restore/reinstall, failed delivery retry, renewal/refund/revocation, newer update during delivery, account switch, ownership conflict and deleted-account recreation | App Store products, roots, sandbox configuration and recovery policy |
| Small surfaces | Real Home/Today/Lock widgets and paired Watch, cache deletion/offline/stale and large text | Physical-device run |
| Release operations | User-data backup/restore, deletion/retention, privacy/EULA reachable over HTTPS, independent security review and load budget | Not production-ready |

App Store/TestFlight publication, paid Apple enrollment and merges require
separate authorization. Do not open sales merely because a compiler or dependency
audit is green. Keep existing GitHub release-gate issues open until verified.
