# Changelog

Notable user-visible changes are recorded here. Source-preview entries do not
imply a signed binary release or App Store availability.

## 0.1.0 — Source preview

- English/Korean interfaces with device-language fallback; language changes retain measurements and connection state.
- Resumable native setup with explicit demo/private bridge/optional cloud/later choice, refresh-on-open or manual refresh, and Settings revisit/cancel. Cloud consent remains separate; demo stays in memory.
- Web pairing storage warnings survive successful reads and language changes; partial saves are cleared when possible, and blocked removal explicitly warns that an older pairing may return on reload.
- Local-first, zero-dependency Node.js 22 bridge around an installed CodexBar CLI.
- Authenticated v1 snapshots with explicit unknown, unavailable, demo, and stale semantics.
- Source clients for a web dashboard, iPhone, widgets, and Apple Watch.
- Private HTTPS device connection model; provider sessions remain on the host.
- Repository-local read-only inspection skills and public contribution workflows.
- Bounded cloud cursor traversal with distinct account slots and explicit partial offline caches.
- Streamed response limits and cancellation that preserve the last usable observation.
- Shared widget/Watch freshness and empty-cache presentation, plus large-text layouts.
- Fractional remaining allowances stay distinct from zero on every native surface.
- Read-only collector diagnostics with fixed non-secret errors.
- Refresh waits on the submitted server job ID; completed processing never promises fresh quota.
- Native StoreKit purchase/restore source with account binding and server-accepted delivery; pilot sales remain disabled.
- Explicit release acceptance gates for identity, purchases, provider collection and physical-device surfaces.

No App Store/TestFlight distribution, real-time background refresh guarantee,
or account-independent provider availability is promised.
