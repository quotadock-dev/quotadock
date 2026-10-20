# QuotaDock

**Your AI allowance, at a glance — on iPhone, Apple Watch, and widgets.**

[![CI](https://github.com/quotadock-dev/quotadock/actions/workflows/ci.yml/badge.svg)](https://github.com/quotadock-dev/quotadock/actions)
![Source preview](https://img.shields.io/badge/v0.1.0-source_preview-orange)
![Node](https://img.shields.io/badge/Node.js-22-43853d)
[![MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

QuotaDock turns the output of your **installed [CodexBar](https://github.com/steipete/CodexBar) CLI** into a small, authenticated snapshot. Provider credentials stay on the host. Clients receive remaining allowance, reset information, and freshness — not account identities.

> **v0.1.0 SOURCE PREVIEW.** No App Store, TestFlight, signed installer, or production-readiness claim. [App + collector](https://github.com/quotadock-dev/quotadock) and [website](https://github.com/quotadock-dev/quotadock-web) are public; server implementation is private. Provider availability depends on CodexBar and your account. Cloud sign-in and purchases remain gated on Apple configuration and trusted HTTPS.

![QuotaDock desktop web dashboard — demo data, not native iOS](docs/assets/dashboard-desktop.png)

<details>
<summary>Mobile web demo (Chromium touch emulation, not native iOS)</summary>
<img src="docs/assets/dashboard-mobile.png" alt="Mobile web demo with AI icons and remaining allowance bars" width="390" />
</details>

<details>
<summary>Native iPhone demo (Xcode 16.4 simulator, sample data)</summary>
<img src="docs/assets/native-demo.png" alt="Native QuotaDock app with provider icons, plans, remaining bars and explicit unknown readings" width="390" />
</details>

## How it works

```text
┌────────────────┐    ┌──────────┐    ┌───────────────────┐
│ Local accounts │───▶│ CodexBar │───▶│ QuotaDock bridge  │
└────────────────┘    └──────────┘    │ No account IDs    │
                                     └─────────┬─────────┘
                       bearer auth + private HTTPS (local web: loopback HTTP)
                                               │
                  ┌─────────────┬───────────────┴────────────┐
                  ▼             ▼                            ▼
          ┌───────────────┐ ┌────────┐             ┌──────────────────┐
          │ Web dashboard │ │ iPhone │             │ iOS widgets      │
          └───────────────┘ └────┬───┘             │ Home/Today/Lock  │
                                 │                 └──────────────────┘
                          WatchConnectivity (snapshot only, no token)
                                 ▼
                       ┌──────────────────┐
                       │ Watch + widgets  │
                       └──────────────────┘
```

The zero-dependency bridge invokes fixed CodexBar commands, caches results for 60 seconds, and serves the [v1 snapshot contract](docs/contract.md). A GET is not necessarily a fresh provider request. Optional polling runs only while the bridge process is running.

## Support matrix

| Surface | Requirements | Preview status / limits |
| --- | --- | --- |
| Bridge | Node.js 22; installed CodexBar for live data | Local source CLI; demo needs no provider login |
| Web dashboard | Modern browser on bridge host | React / strict TypeScript paired dashboard; separate React public website is a labelled demo |
| iPhone | iOS 17+, Mac with Xcode 16+ to build | Source only; real device requires trusted HTTPS |
| iOS widgets | iOS 17+, installed native app | OS-scheduled updates; not live counters |
| Apple Watch / widgets | watchOS 10+, paired iPhone | Cached sanitized snapshots; not direct provider login |

| Provider | What the display means |
| --- | --- |
| Claude | Account-dependent measured CodexBar windows |
| Codex | **Codex allowance under a ChatGPT plan, not total ChatGPT usage** |
| Gemini | Account/model-tier dependent; do not assume session/weekly windows |
| Grok | Account/source dependent; unavailable or unknown may be expected |

Unknown values stay unknown (`null`), never synthetic zero. Only a measured zero means exhausted. Windows must not be summed. Reset times are information, not a promise of quota replenishment.

OpenAI's [current Codex plan guide](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan) includes Free/Go, while its [pricing guide](https://learn.chatgpt.com/docs/pricing) notes surface/rollout restrictions. **Free is not automatically rejected.** Missing account eligibility or an unmeasurable quota remains Unknown; this app cannot infer eligibility from a failed lookup. Checked 2026-10-13; no real Free account test was performed.

## First run · 첫 실행

The feature-branch native source offers three resumable steps: **Welcome → Connection → Preferences**. Choose device language, English or 한국어; explicitly select in-memory **demo**, your **private HTTPS bridge**, **optional cloud**, or **connect later** before continuing. Refresh-on-open defaults on; turn it off for button/pull refresh. Settings lets you change language or review setup; Cancel discards a revisit's connection/refresh draft, not an immediately applied language change. Cloud still requires separate explicit consents and Apple authorization, not merely a setup selection. See [bilingual native instructions](apple/README.md#first-run-setup--첫-실행-설정).

네이티브 기능 브랜치의 첫 실행은 **시작 → 연결 → 환경설정** 3단계이며 저장된 진행을 이어갑니다. 기기 언어·English·한국어를 선택하고 **메모리 내 데모 / 사설 HTTPS 브리지 / 선택적 클라우드 / 나중에 연결** 중 하나를 직접 선택하세요. 앱을 열 때 새로고침은 기본으로 켜져 있으며 끄면 버튼·당기기로 갱신합니다. 설정에서 언어 변경·설정 다시 보기가 가능하며, 취소는 재설정 중의 연결·새로고침 초안만 버립니다. 클라우드는 별도 명시적 동의와 Apple 인증이 필요합니다.

Language switching never changes provider quota or performs new provider login. Installed widget language updates are OS-scheduled; Watch delivery is asynchronous. 언어 변경은 제공자 할당량이나 로그인을 바꾸지 않으며, 설치된 위젯 언어 갱신은 OS 일정에, Watch 전달은 비동기 연결에 따릅니다. This is feature-branch source, not `main` or deployed software; [native verification limits](apple/README.md#architecture-and-verification) still apply.

The paired web dashboard remembers automatic/manual checks in browser-local storage for future page loads; other already-open tabs keep their current choice. Manual mode does not request usage on reload, a timer or visibility changes; Connect and Refresh remain explicit actions. Demo visits never overwrite this preference. Failed language or automatic-check saves keep the current-page choice and explain that it may reset on reopening. Pairing tokens still use tab-session storage, never browser-local storage. 웹 대시보드의 수동 확인 선택은 재접속에도 유지되며, 저장 실패는 한국어·영어로 안내합니다. 브라우저 저장소를 지우면 기본 설정으로 돌아갑니다.

## Optional cloud · credentials stay local

The iPhone uses nonce-bound **Sign in with Apple**, without email/name scopes.
It creates provider slots and approves a short-lived collector pairing code.
The computer receives a **separate scoped 30-day grant**, never the phone's Apple
session. See [collector setup](bridge/cloud.md) and [native setup](apple/README.md).
Mobile login source now rotates one-hour access within a fixed 30-day family;
credentials stay in phone-only Keychain. Simulator contracts and disposable-server
renewal/revocation tests passed in [post-noon validation](apple/README.md#architecture-and-verification).
Real Apple login, device restart/lock and deployed recovery remain release gates;
this is not a longer-lived bearer or a physical-device login claim.

The computer must remain online with its local provider sessions. It polls for
phone jobs approximately every 20 seconds and checks due automatic collection
approximately every 20 minutes. The server enforces the tier interval using the
last successful **source observation**, not the cache-read time. Automatic local
collection defaults on and can be disabled independently of app-open refresh.
An offline collector cannot produce fresh usage, even while the server is online.

| QuotaDock plan | Accounts | Collector computers | Monthly / annual KRW |
|---|---:|---:|---|
| Free | 3 | 1 | Free |
| Plus | 10 | 3 | ₩2,990 / ₩29,900 |
| Pro | 25 | 5 | ₩5,990 / ₩59,900 |

Plus and Pro monthly/annual subscriptions are **paid from the first purchase,
with no free trial**. The permanent Free plan remains available. Prices above
describe product policy; actual localized prices and renewal charges come from
StoreKit. Products configured with introductory offers are unavailable in the app;
remove those offers in App Store Connect before enabling sales. Deleting the
cloud account does not cancel an Apple subscription.

Server policies and native StoreKit purchase/restore source are implemented;
**purchases remain disabled on the unconfigured pilot**. Product/signature/account
checks precede server verification; only the server's authoritative account read
applies a tier. Failed new deliveries remain unfinished for reconnect/Restore.
Live explicitly opts into
foreground requests at a target 60-second spacing for a server-owned 30-minute
session. Hidden/locked apps pause requests without extending that deadline.
Failed first collection, cached reads and duplicate completion do not spend a
refresh allowance. These allowances do not buy extra AI-provider quota.
The phone now waits on its specific server job ID, not changing quota timestamps.
Terminal processing can include collection failure and never guarantees fresh
quota. See the [release plan and failure contracts](docs/release-plan.md) for
purchase, cancellation, ownership, offline and signed-device acceptance gates.

**Independent provider-account collection is not verified.** Public CodexBar
0.77.1 usage JSON omits the internal account-selection key; discovery now reports
`unsupported_identity` instead of pretending no accounts exist. Explicit-key
adapters identify local scopes, not verified unique provider owners. A missing or
ambiguous mapping never falls back to a label, order or ambient account. See the
[collector compatibility boundary](bridge/cloud.md#independent-accounts).
Unmapped single-provider bridge readings are not verified account identities.

The phone selects up to 50 slots per refresh/Live batch; legacy excess records
are retained rather than silently deleted. New configurable widgets and Watch
source select exact UUIDs/windows and keep a removed selection unavailable. Names
and emails remain iPhone-private. Legacy static widget kinds retain the first-slot
projection. The new Apple UI/AppIntent integration compiles against Xcode 27.1
for all four targets; simulator contracts and isolated presentation hosts run
without provider access. Those hosts are not installed system widgets or a paired
Watch. A separate 2026-10-18 iOS/watchOS 27 simulator run exercised production
WatchConnectivity with synthetic sanitized accounts, native Watch selection and
offline restart, and installed small/medium iPhone widgets with explicit UUIDs
and quota windows. It exposed and corrected a native Watch picker layout defect
and a populated-widget recommendation crash. This is simulator evidence, not
physical-device or real-provider acceptance. Actual provider access, policy
permission and two real independent accounts remain unverified; see
[current validation limits](apple/BILLING.md#validation-limits).

The server stores sanitized quota **and pseudonymous identity, hashed sessions,
collector grants, consent, billing/transaction IDs and counters**. A database leak
would include that metadata, not just quota. Provider passwords/tokens, email,
names, raw diagnostics and Apple JWTs are not stored. Deletion revokes owned
sessions/grants and cascades owned records; backups have separate expiry.

## 빠른 시작 · Korean quickstart

Node.js 22를 설치하고 저장소 루트에서 실행하세요. 수집기 자체는 Node 내장 API를 사용하고,
웹 대시보드는 React·strict TypeScript·Vite로 빌드합니다.

```sh
git clone --branch feat/quota-dock https://github.com/quotadock-dev/quotadock.git
cd quotadock
npm ci --ignore-scripts
node bridge/cli.mjs init
node bridge/cli.mjs status --demo
npm run demo
```

현재 소스는 [PR #2](https://github.com/quotadock-dev/quotadock/pull/2)의 `feat/quota-dock` 브랜치에 있습니다. `main` 병합 전에는 위 브랜치를 지정해야 합니다.

`init`는 로컬 페어링 토큰을 생성합니다. **토큰을 터미널 로그, 이슈, 스크린샷에 공유하지 마세요.** 웹 화면은 같은 컴퓨터의 `http://127.0.0.1:8787`에서 확인합니다. Demo 표시는 실제 계정 사용량이 아닙니다.

계정 없이 UI만 둘러보려면 `http://127.0.0.1:8787/?demo=1`을 여세요.
기본 화면의 연결 폼은 같은 주소에서만 작동합니다. 토큰 파일을 로컬에서
안전하게 열어 폼에 입력하세요. 다른 호스트의 토큰을 입력하지 마세요.

실제 사용량: CodexBar를 별도로 설치하고 앱에서 계정을 설정한 후 CLI를 설치하세요 (CodexBar → Preferences → Advanced → Install CLI). 다음 명령으로 확인합니다.

```sh
node bridge/cli.mjs status
npm start
```

iPhone에서 `127.0.0.1`은 Mac이 아닌 iPhone 자신입니다. 실제 기기는 **사설 VPN과 HTTPS 리버스 프록시** 또는 아래 네이티브 TLS 구성을 사용하고 신뢰할 수 있는 인증서를 설정하세요. 인증 없이 공개 인터넷에 노출하면 안 됩니다.

## Configuration

| Environment variable | Default / requirement |
| --- | --- |
| `QUOTADOCK_HOST` | `127.0.0.1` |
| `QUOTADOCK_PORT` | `8787` |
| `QUOTADOCK_TOKEN_FILE` | `~/.config/quotadock/token` |
| `QUOTADOCK_CODEXBAR_BIN` | `codexbar` |
| `QUOTADOCK_POLL_SECONDS` | Optional; at least `60` |
| `QUOTADOCK_TLS_CERT` | PEM certificate path; paired with TLS key |
| `QUOTADOCK_TLS_KEY` | PEM private-key path; paired with certificate |

Both TLS settings are required for non-loopback binding. Use private networking and restrict access with a firewall; TLS is not a substitute for bearer authentication. A reverse proxy must preserve authentication and must not log authorization headers. Do not publish the service on an unauthenticated tunnel.

## Build the Apple app, widgets, and Watch

1. Use a **Mac with Xcode 16+** and install XcodeGen. Linux cannot build Apple targets.
2. From `apple/`, run `xcodegen generate` using `project.yml`, then open the generated `.xcodeproj` in Xcode.
3. Select the iOS app scheme and an iOS 17+ simulator. Simulator builds can be unsigned; physical devices require your development team and signing setup.
4. For devices, configure the bundle prefix (`com.quotadock.app` by default), App Group (`group.com.quotadock.app`), and shared Keychain access group consistently across targets. Configure signing locally; never commit signing credentials.
5. In the app, pair with your private HTTPS bridge and its token. Tokens belong in iPhone-only Keychain; widgets read only sanitized App Group cache, never tokens.
6. Add **All AI allowances** for the four-provider overview, or individual provider widgets from the Home Screen / Today View gallery. Add rectangular/circular/inline widgets on the Lock Screen. Install the companion Watch app on a paired watch and add its widget/complication where supported.

Provider icons are MIT-licensed Lobe Icons assets with provenance and trademark
notices in [third-party notices](THIRD_PARTY_NOTICES.md). Xcode 16.4 simulator
builds and native contract tests are tracked by the CI badge. Screenshots are
demo renders, not real-provider or physical-device proof.
Physical-device signing/pairing and untested system widget families remain unverified;
see [native verification limits](apple/README.md).

Watch receives snapshots through WatchConnectivity, **never the bridge token**. Watch widgets read the Watch's local cache. Use Xcode's scheme list as the source of truth for actual generated target names.

## Refresh and security tradeoffs

- iPhone refreshes on foreground when refresh-on-open is enabled (default), or on manual request; WidgetKit scheduling is controlled by the OS. Background delivery and Watch connectivity are not guaranteed. No push-notification or real-time refresh promise.
- Data older than 15 minutes is stale. Check the observed time before relying on a bar.
- The bridge host and CodexBar have privileged access to provider sessions. Keep both trusted and patched. QuotaDock is not a credential vault or an official provider client.
- Bearer tokens grant snapshot access. HTTPS protects transport; VPN/firewalls reduce exposure. Neither prevents access by someone who has stolen the token.
- Live quota queries may contact providers through CodexBar. Demo is the offline-safe starting point.

## Development and community

Offline tests need Node 22+, Python 3.10+ and a POSIX host. The collector TLS
regression also needs OpenSSL with `req -addext`; it generates temporary fake
certificates and uses loopback only, without provider accounts or cloud access.

```sh
npm ci --ignore-scripts
npx playwright install --with-deps chromium
npm test
python3 .agents/skills/checking-codexbar-usage/scripts/test_codexbar.py
```

`npm test` strictly typechecks and builds the React dashboard, runs the bridge
contracts, then Chromium browser contracts against the built bridge. Those
check safe pairing, cache preservation, disconnect races, deadlines, background
pause and keyboard controls. `web-dist/` is generated, not committed; direct
`node bridge/cli.mjs serve` requires `npm run build` first. Collector-only commands
do not require a frontend build. Linux browser tests do not verify native iOS.

See [contributing](CONTRIBUTING.md), [security reporting](SECURITY.md), [changelog](CHANGELOG.md), and [third-party notices](THIRD_PARTY_NOTICES.md). Use the issue forms for reproducible bugs or focused proposals; never paste raw provider diagnostics or credentials. Repository-local skills provide read-only CodexBar inspection and safe QuotaDock verification; they are not installed globally.

Licensed under [MIT](LICENSE). QuotaDock is independent of CodexBar and the AI providers; provider names belong to their respective owners.
