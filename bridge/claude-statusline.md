# Experimental passive statusline quota reader

Standalone Node ESM experiment; not connected to QuotaDock's collector, server,
cloud or native clients. No dependencies, network, subprocesses, persistence,
credential reads, cron, or automatic configuration installation. Claude settings
are not changed. Only the tests spawn Node to exercise the local CLI.

## Verified documentation and policy boundary

Reviewed before implementation on 2026-10-17:

- [Official statusline documentation](https://code.claude.com/docs/en/statusline):
  Claude Code supplies session JSON on stdin. `rate_limits.five_hour` and
  `rate_limits.seven_day` independently may be absent; `used_percentage` is a
  percentage from 0 to 100 (the official example includes decimals), and
  `resets_at` is Unix epoch **seconds**. Rate limits appear only after the first
  API response, for eligible subscription/gateway configurations. Claude Code
  drops windows after their reset time passes. This reader ignores gateway spend
  limits and all other fields.
- [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance):
  applicable consumer/commercial terms and usage policy still apply. Third-party
  developers may not collect, store or intermediate Claude.ai credentials/session
  tokens or offer Claude.ai login in their applications. This experiment only
  transforms user-supplied passive statusline data; it does not authenticate,
  route inference or modify/run Claude Code. Documented statusline support is not
  a paid-product permission grant, endorsement, or legal compliance determination.

## Observable contract

`parseClaudeStatusline(input, receivedAtMs)` is the sole exported pure function.
`input` must be a Uint8Array (including Buffer), at most **65,536 bytes**, containing
one strict UTF-8 JSON object. BOM, malformed UTF-8/JSON, arrays and primitives are
rejected. `receivedAtMs` is an explicit local receipt timestamp: nonnegative safe
integer Unix milliseconds within JavaScript Date range. No implicit clock reads
occur in the function. CLI receipt time is captured locally after stdin EOF.

Successful return / CLI stdout (one JSON line) has exactly this structure:

```json
{
  "experimental": true,
  "provider": "claude",
  "source": "claude_code_statusline",
  "identity": "unknown",
  "receivedAt": "2027-01-15T08:00:00.000Z",
  "providerObservedAt": null,
  "quota": {
    "fiveHour": { "usedPercentage": 23.5, "remainingPercentage": 76.5, "resetsAt": 1 },
    "sevenDay": null
  }
}
```

Each absent window becomes `null`. A present window must be an object; its absent
fields become `null`. Present `used_percentage` must be a finite number in [0,100];
present `resets_at` must be a nonnegative safe integer in seconds. Explicit nulls,
strings, invalid ranges and malformed allowlisted containers reject the whole
input. Missing usage is unknown, not zero or exhaustion. Remaining percentage is
exactly `100 - used_percentage` with normal JavaScript floating-point precision;
zero used means 100 remaining and 100 used means zero remaining. Reset seconds are
preserved verbatim, including past timestamps: no rollover, inference of renewed
allowance, or timestamp shift. A past-reset reading is not current availability.

Only these fixed fields are emitted. Unknown fields are ignored, never copied;
email, session IDs, paths, model, cost, transcript, arbitrary private fields and
raw input are not exported or logged. No account identifier exists in this
contract. Attribution is **unverified/unknown**: never attach this output to a
cloud UUID or claim independent-account compatibility. A reported upstream
cross-session account-mixup allegation is not treated as proven; this reader
simply has no verified account attribution.

`receivedAt` is receipt, not provider observation. Repeated invocations can carry
identical cached data and do not establish a new provider observation;
`providerObservedAt` is always null. There is no freshness guarantee, account
binding, deduplication or persistent history.

Errors throw `Error` with fixed `code` and message `Claude statusline: CODE`.
Codes: `invalid_input`, `input_limit`, `invalid_receipt_time`, `invalid_utf8`,
`invalid_json`, `invalid_shape`; CLI additionally uses `invalid_arguments` and
`stdin_failed`. CLI rejects arguments, exits 1 on input failure, emits no stdout
and prints only the fixed error message to stderr, never parser details/input.
Stdin accumulation stops at the byte limit; there is no timeout for a producer
that never closes stdin. JSON duplicate keys follow JSON.parse last-key behavior.

## Manual synthetic usage (no provider or settings access)

```sh
printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1}}}' \
  | node bridge/claude-statusline.mjs
node --test bridge/claude-statusline.test.mjs
```

This outputs machine-readable JSON, not a polished status-bar renderer. Connecting
it to any real statusline is an explicit future user choice, not performed here.
