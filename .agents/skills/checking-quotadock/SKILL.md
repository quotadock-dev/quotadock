---
name: checking-quotadock
description: "Verifies QuotaDock snapshot semantics and local test results without credential disclosure or deployment. Use when checking bridge status, demo behavior, or preview readiness."
license: MIT
compatibility: Node.js 22; Mac with Xcode 16+ for Apple checks.
---

# Checking QuotaDock

Perform safe, read-only inspection. Do not initialize pairing, start servers,
change settings, install tools, repair auth, deploy, publish, or push commits.

1. Read `docs/contract.md` and `README.md`; inspect `package.json` and actual
   platform manifests. Do not guess commands or target names.
2. Check Node version and run `npm test`. Tests may write temporary fixtures;
   do not run them against production credentials or services.
3. Run `node bridge/cli.mjs status --demo`. Never read/print the token file,
   authorization headers, environment dumps, or raw upstream diagnostics.
4. Check schema version 1, all required properties, four visible providers,
   remaining values within 0–100, explicit demo flags, and nullable unknowns.
   Check that only measured zero means exhaustion, windows are not summed,
   and stale observations are flagged after 15 minutes.
5. Run live `status` only with authorization for provider access. Summarize
   states and freshness; do not attach account identifiers or raw JSON.
   For upstream diagnosis, use the sibling checking-codexbar-usage skill.
6. On a Mac, inspect `apple/project.yml`, generate/list schemes only if the
   caller permits generated build artifacts, and test an unsigned simulator
   build with actual schemes. Otherwise report Apple verification unavailable.
7. Report exact checks, pass/fail counts, platform limits, and any uncertainty.

For UI review, verify demo labeling, unknown/unavailable/error states, observed
timestamps, and remaining-bar direction. Do not capture pairing screens or
real-account screenshots. Check ChatGPT/Codex distinction and model-tier Gemini
semantics against the contract. Watch must receive no token; widgets must not
claim real-time refresh. Do not probe a remote endpoint or expose a local bridge.
