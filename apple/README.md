# QuotaDock native Apple apps

Small SwiftUI source tree targeting **iOS 17 / watchOS 10, Xcode 16+**. No runtime dependencies. XcodeGen 2.42+ is the only project-generation tool.

## Try the UI before Apple Developer enrollment

`project-preview.yml` builds a separate **QD Preview** iPhone app with bundle ID
`com.quotadock.app.preview`. It reuses the production provider cards, gauges,
icons, translations and first-run views. It displays labelled sample data only;
it is **not** a substitute for signing or integration-testing the production app.
The original `project.yml` and its four targets/entitlements are unchanged.

```sh
cd apple
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --spec project-preview.yml
open QuotaDockPreview.xcodeproj
# Select the existing Personal Team for QuotaDockPreview, then run on iPhone.
# Use a disposable simulator for the preview's UI test scheme.
```

Device UI tests may target only a **fresh, explicitly authorized QD Preview
installation**. They change that preview's language/setup choices and may need a
separately provisioned UI-test runner. Never run the production persistence
harness on a phone. A stalled simulator test is not a passing result; a device
preview test is separate evidence, not production integration acceptance.

The preview source allowlist excludes bridge/cloud clients, connection authority,
purchases, Watch and widget adapters. No App Group, shared Keychain group, Apple
sign-in capability or embedded extension is configured. `SnapshotStore` and
`CacheFiles` compile solely because setup reads `RefreshSettings`; the preview
does not call their cache operations, and its Info.plist has no App Group key.
Language/setup preferences live in the preview's separate app sandbox. No provider
credential, server URL or real account can be entered. The refresh preference is
display-only configuration here: no collection or background refresh occurs.

The **Sample state** menu switches between normal, unknown, stale and exhausted
readings. Unknown is not 0%; stale retains the sample observation time, shifted
one hour earlier. Language/scenario changes never make that observation fresh.
Settings supports English/Korean and revisiting setup. A Personal Team installation
normally needs re-signing after seven days. Actual widgets/Watch, Apple sign-in,
StoreKit and provider collection remain production integration gates.

## Plans and account labels

Open **Settings → Plans** to compare Free, Plus and Pro. Prices come from
StoreKit; the current-plan badge comes from the server, never a local selection.
Unavailable products cannot be purchased. Renewal terms stay in an expandable
section; restore remains accessible. The isolated preview shares only this
presentation, with purchases disabled. The workstation browser has a read-only
comparison at `/?view=plans`; it has no checkout.

Free supports 3 accounts/1 collector, Plus 10/3 and Pro 25/5. Korean storefront
configuration targets are Plus KRW 2,990/month or 29,900/year and Pro KRW
5,990/month or 59,900/year. Both paid tiers charge from the first purchase with
no free trial. Keep all four products free of introductory offers in App Store
Connect; the app rejects products with those offers and never queries trial
eligibility. StoreKit `displayPrice` remains authoritative. The permanent Free
plan, annual Plus monthly benefit refills, Live and due-refresh policies are
unchanged. See [billing](BILLING.md).

Open the dashboard's person icon for the **Accounts** sheet. Add a provider, then
open its individual account to enter a name/email, inspect quota and copy its UUID.
**Link this account** approves the computer's pairing code for that UUID only,
with explicit consent bound to the current server/login family. Map the UUID to
the correct durable local CLI account fingerprint separately; approval is not
provider sign-in or proof of a fresh reading. Collector revocation remains in
connection settings. Removing an account requires confirmation.

Accounts accept a manually entered **Account name or email**. Labels are not
verified provider identities. They stay in private iPhone preferences, scoped to
the server, login family and slot, and are absent from uploads, shared caches,
Watch/widgets and logs. Logout/account deletion clears the current scope; removing
a slot clears its label. Token renewal retains labels; a new login family does
not inherit them. Legacy sessions use the connection generation instead.

## Generate, build and test on a Mac

```sh
brew install xcodegen
cd apple
xcodegen generate
open QuotaDock.xcodeproj
# Pick an installed iPhone simulator (list with xcrun simctl list devices available).
xcodebuild -project QuotaDock.xcodeproj -scheme QuotaDock \
  -destination 'platform=iOS Simulator,name=iPhone 16' test CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
xcodebuild -project QuotaDock.xcodeproj -target QuotaDockWatch \
  -sdk watchsimulator build CODE_SIGNING_ALLOWED=NO
xcodebuild -project QuotaDock.xcodeproj -target QuotaDockWatchWidgets \
  -sdk watchsimulator build CODE_SIGNING_ALLOWED=NO
```

The iPhone simulator tests use ad-hoc signing to retain App Group entitlements;
disabling signing denies the host access to the shared cache. This uses no Apple
account, development certificate or provisioning profile. The separate unsigned
Watch commands check compilation only, not runtime entitlements or delivery.

The dependency-free Foundation storage and bridge contracts also run with Swift
5.9+ on Linux/macOS: `swift test --package-path apple`. Use a non-root account so
the real read-only-directory cases execute rather than skip. These tests execute
the production generation fence, authority transitions, bounded cache and bridge
transport; they do **not** emulate Keychain, UIKit, WidgetKit or WatchConnectivity.
The latest local run used Swift 6.1.3 on Linux. Native integration still needs
Xcode and signed-device verification; Linux success does not close those gates.

Before physical-device builds, set `DEVELOPMENT_TEAM`, `BUNDLE_PREFIX`, and `APP_GROUP` in `project.yml` and regenerate. Defaults are `com.quotadock.app` and `group.com.quotadock.app`. Register the four bundle IDs (base, `.widgets`, `.watch`, `.watch.widgets`) and App Group with your team. Enable the group for all four targets. Enable **Sign In with Apple only for the main iOS App ID**, and configure the server's Apple audience to that exact bundle ID. Real sign-in requires the user's Apple Team/provisioning and reachable configured server; simulator CI does not authenticate a real Apple account. The iPhone alone has separate `.bridge` and `.cloud` Keychain groups. Watch/widgets have **no token or Keychain entitlement**. App Groups are local to each device; WatchConnectivity bridges sanitized snapshots between devices.

XcodeGen embeds the iOS widget and modern single-target Watch app into the iPhone app; the Watch app embeds its WidgetKit extension. Generated plists, entitlements and project are ignored. No ATS exceptions, background modes, push capability, or insecure certificate bypass are supplied. The shared iOS/watchOS app icon is an opaque 1024px rendering of `web/favicon.svg`. Release/App Store distribution additionally needs listing artwork, team provisioning and device/OS review.

### Real simulator Keychain and process-relaunch verification

Use a **disposable iPhone simulator**, never a physical phone or an existing
installation containing useful authority. `NativePersistenceTests` replaces its
connection with synthetic `.invalid` bridge/cloud credentials. The test executes
the production Security.framework adapter and entitled App Group cache, without
an Apple login, provider access or injected credential storage. Its ordinary
in-process run restores prior language/refresh preferences, including absent
values; its explicit multi-process phases intentionally preserve those values.

When the global developer selection is Command Line Tools, export the Xcode path
in **each shell invocation** (including the Python runner's environment), rather
than changing the global selection. Do not update Xcode during a run; rebuild
fresh products after an SDK/CoreSimulator change.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -version
xcrun --find simctl
# Set SIMULATOR_ID to a disposable simulator UUID from simctl's list.
xcodebuild -project QuotaDock.xcodeproj -scheme QuotaDock \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath DerivedData build-for-testing \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
RUN=$(find DerivedData/Build/Products -maxdepth 1 -name '*.xctestrun')
python3 verify-persistence.py --xctestrun "$RUN" \
  --simulator-id "$SIMULATOR_ID" --output /tmp/quotadock-persistence-results
```

The output directory must not already exist. Each of ten phases launches a new
host process and records its PID; a missing phase marker or reused consecutive
PID fails the run. The phases cover both bridge/cloud switch directions, bearer
rotation within one family, rejected-cloud observation retention, logout, legacy
items with missing authority, and the persisted state left between fence advance
and authority replacement. Real obsolete files are deliberately restored after
cleanup to establish that generation checks—not deletion success—exclude them.
Original fractional observation timestamps, stale versus unknown/non-demo data,
language preference and sanitized Watch outbox payloads are checked after reads.
No production launch hook or authentication bypass is added.

On 2026-10-17, fresh Xcode 27.1 (27A9275) products on an iPhone 17/iOS 27.0
simulator passed **97 native units, all ten separate-process persistence phases,
and 22 cloud pagination/retry regressions with Korean selected**. All three
EN↔KO/onboarding/consent UI flows passed separately, with their existing assertions
and no retries. Synthetic switch interactions now deliberately press the native
thumb for 0.3 seconds: instantaneous taps sometimes left the settled control OFF
on this simulator. This is a test interaction change, not a production workaround.
All 19 non-root portable contracts also passed. Mac verification corrected a
`/var` versus `/private/var` test URL comparison and English-only budget assertions;
no production storage defect was demonstrated. The iPhone build includes both
WidgetKit extensions and the Watch app; independent unsigned Watch/widget builds
also passed. No watchOS runtime was installed, so Watch runtime/delivery and
system-widget installation were not established. An earlier run interrupted by
an Xcode/CoreSimulator update is not counted as passing evidence.

This is simulator persistence evidence, **not** device lock/file-protection,
real Apple authorization, server revocation, actual HTTPS/provider collection,
physical-device provisioning or Watch delivery evidence. The interrupted-switch
state is constructed at the storage boundary, not an arbitrary instruction-level
process kill. OS-rendered widgets and an offline Watch can still retain previously
rendered content. Keep those signed-device release gates open.

## First-run setup · 첫 실행 설정

These instructions describe feature-branch source, not `main` or a deployed release.

1. **Welcome:** choose **Use device language**, **English**, or **한국어**. Device language uses the first supported English/Korean preference, falling back to English.
2. **Connection:** explicitly select **Explore demo**, **Pair my own bridge**, **Optional cloud account**, or **Connect later** before continuing. Demo is in-memory sample data, never saved live observations or fabricated Watch transfers. Bridge needs your private trusted HTTPS URL and pairing token, not a provider password. Cloud opens a separate connection screen; Later opens the dashboard without deleting existing connections/cache. Selecting a route alone does not connect or sign in.
3. **Preferences:** **Refresh when I open the app** defaults on; turn it off for refresh-button/pull-only operation. This is separate from collector background collection. Finish setup to apply the refresh choice. The welcome-screen demo shortcut selects demo and jumps to this step.

Interrupted first-run progress resumes locally if saving succeeds. Use **Settings → Review setup** to revisit, or **Cancel** to discard that revisit's route/refresh draft; language changes apply immediately and are not rolled back. Language can also be changed in Settings. Switching language never changes provider quota or performs a new provider login. Installed widget language updates are OS-scheduled; Watch language delivery is asynchronous, not instantaneous.

Cloud selection is **not consent**: on its separate screen, review the server and explicitly enable both initially-off consents (quota/account-metadata storage and local collector processing) before Sign in with Apple. Setup itself requests no provider login, payment or system permission.

1. **시작:** **기기 언어 사용**, **English**, **한국어** 중 선택하세요. 기기 언어는 선호 언어 중 지원되는 영어·한국어를 사용하며, 없으면 영어로 표시합니다.
2. **연결:** **데모 살펴보기**, **내 브리지 연결**, **클라우드 계정 (선택 사항)**, **나중에 연결** 중 하나를 직접 선택해야 계속할 수 있습니다. 데모는 메모리 안의 예시이며 실제 캐시를 덮어쓰거나 Watch에 가짜 관측을 보내지 않습니다. 브리지에는 사설 HTTPS 주소와 페어링 토큰을 입력하며 제공자 비밀번호는 입력하지 않습니다. 클라우드는 별도 연결 화면을 열고, 나중에 연결은 기존 연결·캐시를 지우지 않고 대시보드를 엽니다. 경로 선택만으로 연결·로그인되지 않습니다.
3. **환경설정:** **앱을 열 때 새로고침**은 기본으로 켜져 있습니다. 끄면 버튼이나 당겨서 수동 새로고침하세요. 수집기의 백그라운드 수집 설정과는 별개이며, 설정 완료 시 적용됩니다. 시작 화면의 데모 바로가기는 데모를 선택하고 이 단계로 이동합니다.

저장에 성공한 첫 실행 진행 상황은 중단 후 이어집니다. **설정 → 초기 설정 다시 보기**에서 다시 열고 **취소**하면 재설정 중의 연결·새로고침 초안을 버립니다. 언어는 즉시 적용되므로 취소해도 되돌아가지 않으며 설정에서도 바꿀 수 있습니다. 언어 변경은 제공자 할당량을 바꾸거나 새 제공자 로그인을 수행하지 않습니다. 설치된 위젯의 언어 갱신은 OS 일정에 따르고 Watch 전달은 비동기입니다.

클라우드 경로 선택은 **동의가 아닙니다**. 별도 화면에서 서버를 확인하고, 기본으로 꺼진 사용량·계정 메타데이터 저장 동의와 로컬 수집기 처리 동의를 각각 켠 뒤 Apple로 로그인하세요. 초기 설정 자체는 제공자 로그인·결제·시스템 권한을 요청하지 않습니다.

## Pair and use

Run the bridge behind a trusted, device-reachable HTTPS endpoint (valid TLS certificate), then enter its **base URL** and pairing bearer token in Pair. `/v1/snapshot` is appended. Never enter Claude/OpenAI/other provider credentials. URL and token are held together in the phone-private, device-only `WhenUnlockedThisDeviceOnly` connection record; no token goes to UserDefaults, snapshot cache, logs or Watch. Redirects are refused to prevent bearer forwarding. Plain HTTP, URL credentials, queries and fragments are rejected. Forget pairing durably disconnects before attempting inactive-data cleanup; unsuccessful persistence or cleanup is reported separately. Watch can retain its old snapshot until a new transfer, and offline widgets can retain OS-rendered content.

Connection authority is one Keychain union: signed out, bridge or cloud, bound to
the current cache generation. Switching advances the shared generation before
replacing that union; missing, unreadable or mismatched state never falls back to
another credential. Legacy installs without this record must **reconnect once**;
old pairing/session records are not silently imported. Failed cleanup can leave
inactive bytes on disk without selecting them. If no durable write succeeds,
persistent disconnection is unconfirmed, not guaranteed across restart. Rejected
cloud sessions retain sanitized observations after successful authority rejection.

iPhone fetches on foreground activation when refresh-on-open is enabled, and on manual/pull refresh. The bridge may return cached measurements. **All widgets are cache-only timeline readers**, never background bridge/provider/cloud clients. They have neither network client source nor Keychain entitlements. Timeline requests are hints, not guaranteed refresh intervals. Add the **All AI allowances** overview or individual provider widgets to **Home Screen or Today View**, or rectangular/circular/inline widgets on the Lock Screen. Overview shows four providers with icons, freshness and the first window; individual medium widgets show up to two windows plus the plan, while smaller surfaces show the first window. Open the app for every window and reset time. Watch Smart Stack widgets and complications use only the local cache. Open both paired apps and refresh iPhone to initiate WatchConnectivity transfer; no instantaneous/push update promise.

## Optional cloud (v2, server-verified tiers; pilot purchases closed)

Choose **Optional cloud account** and separately affirm quota-storage/account-metadata and local collector-processing consent before starting real Apple authorization. Both toggles default off and reset when the server URL or session changes; a missing consent prevents challenge requests as well as Apple authorization. Default server is `https://usage.mvtp.cloud`; the editable URL is stored locally and must be trusted HTTPS, with no URL credentials/query/fragment. There is no fake identity, provider login or OpenAI login. DNS, TLS, Apple capability/configuration and server failures are reported without exposing diagnostics.

The client POSTs `/v2/auth/challenge`, requires exactly its three documented fields, a canonical UUID, a 43-byte base64url nonce and 300-second lifetime, and checks foreground authority again before presenting Apple authorization. It sets the AuthorizationServices request nonce to **exactly `challenge.nonce`**, requests no email/name scopes, and POSTs the returned identity JWT with the challenge ID and affirmative consent to `/v2/auth/apple`. The returned opaque access/refresh credentials, family UUID and absolute deadlines are persisted together in the iPhone-only device-only Keychain (`WhenUnlockedThisDeviceOnly`). Access lasts at most one hour; the login family has a fixed 30-day deadline that rotation never extends. No identity JWT or credential is stored in quota caches, UserDefaults, Watch or widgets. Requests use ephemeral sessions, no cookies/cache, no redirects, streamed 256 KiB response bounds and 20-second resource timeouts.

Foreground operations renew through `/v2/auth/refresh` before reusing access with
130 seconds or less remaining. Concurrent callers share one rotation. Before a
send, the phone durably saves the original UUID, start time and send reservation;
uncertain delivery retries the identical body/key, at most twice within 60 seconds
including process restart. The response must retain the original family/deadline
and change both credentials. Its absolute `expiresAt` prevents a recovered response
from starting another hour. An exhausted or old unresolved attempt stays blocked
until sign-out/reconnection; the phone never mints a replacement key with a possibly
spent refresh token. Lock/background cancels transport, not that saved attempt.
There is no background credential-renewal service or generic 401 mutation replay.
Legacy two-field login replies remain readable but cannot renew. Family changes
invalidate old work; ordinary rotation preserves observations and quota-job intents.
Simulator and disposable-server renewal contracts passed in post-noon validation
below. Real Apple authorization, device lock/restart and deployed recovery remain
unverified; injected simulator transport is not genuine Apple authentication.

`/v2/me` displays verified tier, limits, early-refresh and Live counters;
`/v2/accounts` manages UUID slots (Free 3, Plus 10, Pro 25, enforced server-side).
`/v2/snapshot` preserves separate same-provider accounts and every window.
Phone rows use UUIDs and private unverified labels. Schema-v3 sanitized account
snapshots support fixed UUID/window widget selections, medium two-account
comparisons, `quotadock://account/<UUID>` links and Watch account/window selection.
Missing selections stay unavailable, never retarget another account. Legacy
static provider widgets and legacy Watch views still use a first-account-per-
provider projection; neither surface represents totals. Names/emails never enter
these shared snapshots. Original observation times survive caching and transfer;
server errors use fixed safe text. Real device delivery remains unverified.

StoreKit 2 purchase/restore source requires `purchasesAvailable` and the UUID
`appAccountToken` from authenticated `/v2/me`. It loads only the known monthly and annual
auto-renewable products and shows Apple's localized price. Apple signature and
account checks precede transient signed-transaction submission to the server;
only a valid accepted response permits `finish()`. Failed new deliveries remain
unfinished; expired/refunded acceptance does not grant paid access. A server read,
not the product ID, applies the tier. After receipt acceptance it fetches only
`/v2/me`, preserving quota observations, caches, collectors and refresh selection.
If another read is active, pending entitlement reads coalesce into one follow-up
under the same session revision; logout or loss of foreground prevents delivery.
The app-lifetime update listener retains
newer signed changes to an in-flight transaction. New sessions recover unfinished
transactions/current entitlements; only explicit Restore calls `AppStore.sync`.
Context revisions reject stale completions on logout/server/session/account
switch. No receipt is logged, persisted, cached or transferred to Watch/widgets.
Account erasure does not cancel Apple's subscription. Purchase/restore, Ask to Buy,
renewal/refund and account-switch behavior still require actual StoreKit sandbox
and signed-device validation; see [release plan](../docs/release-plan.md).

Foreground automatic refresh honors Settings and submits `mode:auto`; manual/pull refresh submits `mode:force` (an early batch may use Free allowance). Requests use a fresh UUID idempotency key per user operation. Select 1–50 owned slots in **Refresh batch**, initially the first 50. That in-memory selection survives account-list reads, removes deleted slots, and resets on owner/logout changes. Registration above 50 does not block smaller batches. Live restores its authoritative server slot set and 30-minute wall deadline; stop it before changing targets. Hidden/locked apps pause requests, not the deadline.

Modern reads traverse tenant-owned snapshot pages at 250 rows using ascending
UUID cursors and derive slots from those same rows, avoiding a second account
traversal. A full read is bounded to 60 seconds, 8 MiB and 20 pages (5,000 slots),
independent of the current 25-account Pro limit. Request starts are spaced
at least 500 ms apart. Malformed, duplicate, nonadvancing or incomplete pages
retain the last usable reading; pages are not a frozen snapshot across requests.
Only a first-page 404 enables legacy fallback, which also validates the snapshot
against an owned slot list. Deploy the 250-row API before this client; an old
50-row-only endpoint rejects this query with 400, not a compatibility 404.
If a full local snapshot exceeds 256 KiB, the offline cache explicitly retains
only the first 50 accounts without changing original observation timestamps.

A pending job means **waiting for the scoped local collector**, not updated quota. Pair/approve/revoke it using [collector setup](../bridge/cloud.md); provider credentials remain on the computer. Independent Claude/Codex/Grok accounts need explicit local durable-key mappings; Gemini remains one local account. The phone cannot obtain provider quotas directly without granted APIs, and does not collect/complete jobs. Pending requests poll their exact `/v2/jobs/:id`, every five seconds while foreground, with a 60-second polling deadline and bounded request timeout. Job ID, mode, targets and lease must remain consistent. Terminal replies are followed by one bounded account/snapshot read (separate 60-second limit); `completed` can mean failed collection, not fresh quota. Unknown/failure remains unknown and previous source observations remain visible. An old backend without status lookup fails waiting closed rather than guessing completion from observation timestamps.

Logout clears local authority first, then POSTs the captured refresh credential to
`/v2/auth/revoke`, which revokes the entire login family even after access expiry.
Legacy sessions use `/v2/auth/logout`. Account erasure renews access if necessary,
then clears local sessions/caches before DELETE `/v2/me` after destructive
confirmation. An intervening account/sign-in change cancels that old erasure;
old in-flight completions cannot restore authority. Failed revocation/erasure is
explicitly **not confirmed**; reconnect to retry erasure. An unrevoked family can
remain valid until its original 30-day deadline. Slot deletion uses the real
DELETE endpoint and clears local caches before re-reading. Switching cloud/bridge
owners clears both caches and sends an empty Watch snapshot; offline Watch and
OS-rendered widgets may retain previously rendered content until delivery/reload.
Switching to the bridge attempts family revocation and never treats its legacy
token as a cloud session. A parsed fresh login that cannot be saved or loses
foreground authority is revoked best-effort; an entirely lost login response
cannot be assumed revoked.

Graphite/mint bars mean **remaining**, clamped to 0–100, never summed. Null is unknown, not exhausted. Plans are displayed as supplied by the sanitized contract; null is “Plan unknown.” Codex refers to the **Codex allowance under a ChatGPT plan**, not overall ChatGPT usage. Gemini window labels are preserved as model tiers. Unavailable/error providers remain visible, diagnostics are replaced with fixed safe text, and readings older than 15 minutes are stale. Reset dates are informational, not a quota promise.

“Explore demo” is explicitly labeled and stays in memory: it never overwrites live cache or transfers fabricated readings. Legacy Xcode/WidgetKit samples use `Snapshot.preview`, with `demo: true` and `source: demo`. Selected-account widget placeholders instead have no account snapshot and remain unavailable.

## Architecture and verification

The 2026-10-17 isolated Mac validation compiled the final iPhone, iOS widget,
Watch and Watch-widget targets with Xcode 27.1. All **110 hosted native units,
four production onboarding UI tests and 31 macOS Foundation contracts** passed.
The original three onboarding flows and entitlement-read coalescing assertions
remain unchanged. The added EN/KO footer regression scrolls the complete final
paragraph above the fixed footer, with 44pt clearance in both languages.

Six isolated presentation tests passed for monthly/annual Plus eligible/ineligible
display, Pro with an adversarial trial flag, Korean accessibility3 text, UUID
selection, missing accounts and shared Watch selection/trust confirmation.
Small/medium/rectangular/circular/inline host captures were inspected, including
distinct 0% and stale 73% accounts and a missing UUID without substitution.
These are iPhone-hosted shared components, not installed WidgetKit surfaces or
a running Watch. Purchase callbacks are inert, not StoreKit eligibility proof.
There is no Watch runtime on that Mac; no phone, provisioning or Apple account
was used. Actual Apple purchases and paired-device behavior remain open; see
[billing validation limits](BILLING.md#validation-limits).

The older validation runs below are historical evidence for their tested
revisions, not acceptance of later source.

- `Shared/Snapshot.swift`: contract v1 Codable values, shared 64-byte ASCII ISO8601 quota dates truncated to server milliseconds, explicit null re-encoding, 256 KiB bound, safe-message sanitization and demo samples.
- `Shared/Bridge.swift`: HTTPS pairing, Keychain and ephemeral URLSession client; rejects redirects/non-200/schema errors.
- `Shared/CacheFiles.swift` and `Shared/SnapshotStore.swift`: generation-fenced, bounded atomic sanitized JSON cache; inactive-file cleanup never restores an owner.
- `Shared/WatchSync.swift`: latest application-context transfer, no secrets, Watch cache/timeline reload.
- `Shared/QuotaViews.swift`: reusable remaining bars/provider cards.
- `Shared/Localization.swift` and `Resources/`: allowlisted English/Korean presentation, shared language preference and canonical model values.
- `iOS/FirstRun.swift`: locally resumable setup, explicit route selection and separate session-only/persisted refresh choices.
- `iOS/ConnectionState.swift` and `iOS/ConnectionStore.swift`: phone-private Keychain authority union, conditional renewal, checked legacy cleanup and transport admission guards.
- `iOS/Cloud.swift`: real nonce-bound Apple/server authorization, selected cloud session, v2 account-list decoding, sandbox full-slot cache, foreground collector-job requests and bounded job-ID polling.
- `iOS/Purchases.swift`: StoreKit product loading, UUID-bound purchase/restore, update recovery and server-accepted delivery. No client-side entitlement assignment.
- `iOS/`, `Watch/`, `Widgets/`: small native surfaces and timeline adapters.
- `Tests/ContractTests.swift`: public model decode/encode, nullable values, clamps, staleness, demo, schema/date/size rejection, URL restrictions, request authorization and response sanitization/status tests using URLProtocol (no real credentials or server).
- `PortableTests/`: restart/switch/logout and real file-permission failures plus URLProtocol bridge bounds/deadlines. Security-adapter tests remain iOS-only.
- `UITests/OnboardingUITests.swift`: real simulator interaction for language changes, retained choices, cancel/relaunch and separate connection/consent screens. These tests do not perform provider login or Apple authorization.

The [pushed connection/cache CI](https://github.com/quotadock-dev/quotadock/actions/runs/38728138540)
passed 96 native unit tests, all three simulator interaction tests, iPhone/Watch/
WidgetKit builds and the non-root portable storage/bridge job. The unchanged
5,000-slot read and offline-cache-retention case failed when signing was disabled
and passed with simulator-only ad-hoc signing. No production cache or authority
guard was bypassed. This verifies simulator contracts, not physical-device file
protection, real Apple authorization or Watch delivery; consult current PR checks
for later revisions.

The [2026-10-15 bilingual baseline](https://github.com/quotadock-dev/quotadock/actions/runs/38662891736)
passed 83 native contracts, two English↔Korean interaction flows, iPhone/Watch/WidgetKit
builds, 22 bridge contracts, 14 React browser contracts and 10 imported skill tests;
the root-only bridge control skipped on the nonroot CI runner. Sixteen interaction
captures and 31 demo captures were exported. English/Korean welcome, connection,
preferences and dashboard captures, Korean settings/cloud/widget hosts and large
Dynamic Type were inspected. Text below the scroll boundary is not all visible in
one capture. This baseline predates the additional bridge/cloud-route interaction
case; consult the PR's checks for the exact current revision.

Physical iPhone/Watch behavior, Apple authentication/purchases, provisioning and
deployment remain unverified for this feature-branch source. Widget/Watch galleries
are shared-component hosts, not proof of system-widget layout or Watch delivery.

Historical post-noon [2026-10-14 CI](https://github.com/quotadock-dev/quotadock/actions/runs/38506753875)
passed **73 native tests**, iPhone/Watch/WidgetKit builds, **30 Node 22 tests**
and **10 imported skill tests**. The single root-only service test was skipped
under the CI runner's nonroot user; a separate disposable Node 22 root control
passed it. Nineteen demo captures were generated; default, unknown, cloud consents,
bridge rejection, expired session and pending erasure were inspected. The default
is scrollable; its lower providers are offscreen, not all visible in one capture.
This phase's new source remains undeployed and unsigned for physical devices.

Validation reproduced a genuine iOS timestamp defect: a valid 64-byte timestamp
lost `.123` entirely in `ISO8601DateFormatter`. The unchanged decoder failed;
the shared bounded parser now truncates fractional digits to server milliseconds
before parsing. UTC-offset equivalence, nonrounding `.000`/`.999` boundaries,
cloud/shared cache round trips and invalid inputs passed. A real local HTTPS
before/after probe also showed the old collector accepting untrusted TLS under
`NODE_TLS_REJECT_UNAUTHORIZED=0`; the fixed collector rejects it before a bearer
HTTP request, while an explicitly trusted test CA succeeds. Neither probe proves
public TLS or provider account access.

The [prior CI run](https://github.com/quotadock-dev/quotadock/actions/runs/38460764173) generated the project with XcodeGen, built iPhone/Watch/WidgetKit, and passed 29 native XCTests on an iPhone simulator, plus 18 bridge/web and 10 imported skill tests on Node 22. Twelve captures were inspected: default, dark, unknown, settings, separate cloud consents, distinct-slot batch selection, individual/overview/accessory widget hosts, empty/stale Watch hosts and large Dynamic Type. Visual inspection caught and resolved preview-routing and truncated widget-footer defects after an earlier passing test run. The large-text capture verifies visible long labels, 0% and 0.75%; its lower content remains offscreen. The [native demo](../docs/assets/native-demo.png) is from this run. Screenshots show scrollable app content and shared-component hosts, not system widgets or a physical Watch.

The [purchase/job-status integration CI](https://github.com/quotadock-dev/quotadock/actions/runs/38469463457)
passed 34 native tests, iPhone/Watch/WidgetKit builds, 18 bridge/web tests and
10 imported skill tests. Sixteen captures were generated; five affected captures
were inspected: cloud consents and subscription unavailable/catalogue/verifying/
failure. An earlier passing run exposed globally disabled preview links and
ambiguous billing text; these were fixed and recaptured. This validates compilation,
contract guards and presentation, **not real StoreKit purchases or event delivery**.
Purchase samples use inert callbacks and display-only prices, never real products
or credentials. `--purchases-preview`, `--purchases-unavailable-preview`,
`--purchases-pending-preview` and `--purchases-error-preview` render those samples.

This is not physical-device validation. On a Mac, inspect embedding/signing in Xcode and test Keychain sharing, first-unlock fallback, Home/Today/Lock Screen layout, Watch pairing/transfer, complications and stale/offline readings. Small accessory layouts are deliberately terse; large Dynamic Type, long tier/plan labels and system widget rendering require device visual review. Unit tests do not establish real TLS, Keychain provisioning or WatchConnectivity delivery.

Regression cases cover same-provider slots, multiple windows/nulls, safe cache projections with fractional observation timestamps, duplicate/oversized/insecure input rejection, selected batches/ownership boundaries, fixed Live selections, missing consent and mode-switch cache/revision clearing. Debug-only `--unknown-preview`, `--settings-preview`, `--cloud-preview`, `--batch-preview`, `--widgets-preview`, `--widgets-overview-preview`, `--widgets-accessories-preview`, `--watch-preview`, `--watch-stale-preview` and `--accessibility-preview` enable deterministic UI captures. These isolated samples do not provide identity, session, entitlement or authentication bypass. Widget and Watch host galleries render the shared content inside iPhone-sized frames; they are not system WidgetKit layout or physical Watch evidence.

Debug-only `--connection-error-preview`, `--cloud-expired-preview` and
`--cloud-erasing-preview` render the actual dashboard/cloud form with failure
or pending-erasure copy and explicitly demo readings. The pending sample shows
muted consent controls and reconnect; its status never claims confirmed erasure.
Server editing is disabled in source, but the screenshot cannot establish input
interaction and its URL text is not visibly muted. The sample does not execute erasure.
They install no fake session or entitlement and do not simulate a completed
login. Their post-noon CI screenshots were inspected as presentation evidence only.

Real Apple sign-in, logout/erasure, collector completion, purchases and Watch delivery remain signed-device end-to-end gates with the user's Apple Team and trusted configured server. No provider account or Free Codex account was used in simulator tests.
