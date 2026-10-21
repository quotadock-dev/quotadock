# Third-party notices

## CodexBar read-only agent skill (MIT)

Source: https://github.com/steipete/CodexBar

Pinned revision: `5fdb2c79f7b8a4d09a9d190802a1711fdfbdb947`.

Imported from `.agents/skills/codexbar/` into
`.agents/skills/checking-codexbar-usage/`. The `scripts/codexbar` and
`scripts/test_codexbar.py` resources are unchanged. Instructions were adapted
for the repository-local path, gerund naming, and stricter privacy guidance.
The upstream root MIT license is preserved alongside the skill as `LICENSE`:
Copyright (c) 2026 Peter Steinberger. That notice and its full permission and
warranty text apply to the imported resources.

Both downloaded scripts were reviewed in full before import. The wrapper
discovers an existing local executable and permits version, config validation,
provider listing, and usage queries only. It uses argv (no shell), bounds each
captured stream, redacts common secrets/identities, and terminates timed-out
process groups. It does not install software or modify provider configuration.
The tests create temporary fake executables/logs and test timeout cleanup; they
do not contact providers. Redaction is best-effort, not a guarantee for unknown
upstream output formats. Review output locally before sharing.

## Allowmark design guidance (Apache-2.0)

Source: [Anthropic skills / frontend-design](https://github.com/anthropics/skills/tree/dbd4588f9e1033efb41dad4bef2f7947c8993d44/skills/frontend-design),
revision `dbd4588f9e1033efb41dad4bef2f7947c8993d44`.
The instruction text is adapted in `.agents/skills/designing-allowmark-ui/`.
The skill names the upstream source and modifications; the unmodified upstream
`LICENSE.txt` accompanies it. Both source files were reviewed before import.
This is text-only design guidance: no executable scripts, MCP servers, plugins,
package installation or credential access. Product accuracy and accessibility
constraints take precedence over general aesthetic suggestions.

The Allowmark endcap/span marks and app icon are original project artwork,
covered by the repository's MIT license. They do not modify provider trademarks
or imply that the new working name has received trademark clearance.

## External runtime

CodexBar is installed independently by the user; its application/executable is
not vendored by QuotaDock. See its own licenses and notices. The Node bridge
has zero npm runtime dependencies. Apple SDKs and developer tools remain
subject to their respective vendor terms.

## Provider icons (Lobe Icons, MIT)

Claude, OpenAI (used to identify Codex), Gemini and Grok SVGs come from
[LobeHub/lobe-icons](https://github.com/lobehub/lobe-icons/tree/05a9b8c41e4735a4a2b6d2f1e43574bd8ec6c8cb/packages/static-svg/icons),
revision `05a9b8c41e4735a4a2b6d2f1e43574bd8ec6c8cb`. Original SVGs are in
`web/icons/`, and template PNG derivatives are in `apple/Assets.xcassets/`.
The full MIT license, Copyright (c) 2023 LobeHub, is in `web/icons/LICENSE`.
SVGs were inspected: no scripts, external references, or embedded resources.
Icons identify services only; trademarks remain owned by their respective
owners. The software license does not grant trademark rights or endorsement.
