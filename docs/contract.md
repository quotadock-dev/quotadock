# Snapshot contract v1

`GET /v1/snapshot` requires `Authorization: Bearer <pairing token>`.
No provider credentials or account identifiers cross this boundary.
All dates are UTC ISO 8601 strings. All properties below are present;
nullable values remain null, never zero. The snapshot is at most 256 KiB.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-10-13T10:00:00Z",
  "demo": false,
  "providers": [{
    "id": "claude",
    "name": "Claude",
    "plan": "Max",
    "state": "available",
    "source": "codexbar",
    "message": null,
    "observedAt": "2026-10-13T09:59:00Z",
    "windows": [{
      "id": "primary",
      "label": "Session",
      "remainingPercent": 72,
      "resetsAt": "2026-10-13T14:00:00Z"
    }]
  }]
}
```

Provider IDs are `claude`, `codex`, `gemini`, `grok`. Names: Claude,
Codex, Gemini, Grok. State: `available`, `unavailable`, `error`.
Plan, message, observedAt, remainingPercent, resetsAt are nullable.
Source is `codexbar` or `demo`. Unknown quotas and synthetic placeholders
use null percentages. Only a measured 0 means exhausted.
Codex is the Codex allowance under a ChatGPT plan, NOT total ChatGPT usage.
Gemini windows are model tiers, not assumed session/weekly windows.

Render long bars as **remaining**, clamped to 0–100. Never sum windows.
Show plan unknown when no identity.loginMethod/loginMethod is supplied.
Show last observed time; data older than 15 minutes is stale. Reset dates
are information, not a promise of new quota. Display demo on every sample
surface. Unavailable providers remain visible. Errors use fixed safe messages;
upstream diagnostics, identities, email, raw JSON are not transmitted.

Bridge runs fixed `codexbar usage --provider <id> --format json --json-only`
commands; caches snapshots for 60 seconds; GET does not always mean a new
provider request. Optional `QUOTADOCK_POLL_SECONDS` (minimum 60) refreshes
while the process runs. The iPhone pulls on foreground/manual refresh;
WidgetKit reads sanitized local cache subject to OS scheduling. Watch receives
sanitized snapshots using WatchConnectivity. No push notification promise.

Apple targets: iOS 17+, watchOS 10+, Xcode 16+. Bundle prefix
`com.quotadock.app`, app group `group.com.quotadock.app`; configurable via
XcodeGen project settings. Store bridge token only in iPhone Keychain;
widgets have no token or Keychain entitlement. Cache sanitized snapshot in App Group.
Never send the token to Watch. Watch widgets read its local cached snapshot.
