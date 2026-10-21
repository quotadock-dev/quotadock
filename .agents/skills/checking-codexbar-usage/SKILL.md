---
name: checking-codexbar-usage
description: "Reads installed CodexBar usage, limits, provider configuration health, and redacted JSON. Use when diagnosing the upstream data source without changing credentials or settings."
license: MIT
compatibility: Python 3.10+ on POSIX; installed CodexBar CLI required for live queries.
---

# Checking CodexBar usage

Read CodexBar without mutating configuration or authentication. Imported from
steipete/CodexBar at `5fdb2c79f7b8a4d09a9d190802a1711fdfbdb947`;
see `LICENSE` and the repository's THIRD_PARTY_NOTICES.md.

From the repository root:

```sh
python3 .agents/skills/checking-codexbar-usage/scripts/codexbar doctor
python3 .agents/skills/checking-codexbar-usage/scripts/codexbar providers
python3 .agents/skills/checking-codexbar-usage/scripts/codexbar usage --provider codex
```

- Start with `doctor` when install/config health is unknown.
- Plain `usage` reads enabled providers; prefer one provider for focused checks.
- `usage --all` is expensive: use only when specifically needed.
- Never use `--include-identities` in this project's verification workflow.
- Never print credential files or share raw diagnostics. Redaction is best-effort;
  report only safe aggregate findings, not captured stdout/stderr.
- Live queries can contact providers and use existing local sessions. Obtain
  authorization before doing so; use fake tests for offline verification.
- Fixed allowlist only: no auth repair, enabling providers, key storage, installs,
  config writes, or deployment.

Binary discovery: `CODEXBAR_BIN`, PATH, app bundle, Homebrew cask. This helper
uses `CODEXBAR_BIN`, not the bridge's `QUOTADOCK_CODEXBAR_BIN`. Do not install a
binary automatically. Set a trusted existing path if needed.

`CODEXBAR_TIMEOUT` defaults to 120 seconds. Each output stream is captured up to
1 MiB and fully drained; timed-out process groups are stopped. Narrow the scope
before increasing timeouts. Output retains upstream JSON shape, not QuotaDock's
snapshot contract.

Offline resource checks:

```sh
python3 .agents/skills/checking-codexbar-usage/scripts/test_codexbar.py
```
