import { pathToFileURL } from 'node:url';

const MAX_BYTES = 65536;
const fail = (code) => Object.assign(new Error(`Claude statusline: ${code}`), { code });
const check = (ok, code = 'invalid_shape') => { if (!ok) throw fail(code); };
const record = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const own = (value, key) => Object.hasOwn(value, key);

function quotaWindow(value) {
  check(record(value));
  const used = own(value, 'used_percentage') ? value.used_percentage : null;
  const reset = own(value, 'resets_at') ? value.resets_at : null;
  check(!own(value, 'used_percentage') || (typeof used === 'number' && Number.isFinite(used) && used >= 0 && used <= 100));
  check(!own(value, 'resets_at') || (Number.isSafeInteger(reset) && reset >= 0));
  return { usedPercentage: used, remainingPercentage: used === null ? null : 100 - used, resetsAt: reset };
}

/** Pure bytes-to-allowlisted-data conversion. receivedAtMs is the caller's local receipt time. */
export function parseClaudeStatusline(input, receivedAtMs) {
  check(input instanceof Uint8Array, 'invalid_input');
  check(input.byteLength <= MAX_BYTES, 'input_limit');
  check(Number.isSafeInteger(receivedAtMs) && receivedAtMs >= 0 && receivedAtMs <= 8640000000000000, 'invalid_receipt_time');
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(input); }
  catch { throw fail('invalid_utf8'); }
  let data;
  try { data = JSON.parse(text); }
  catch { throw fail('invalid_json'); }
  check(record(data));
  const limits = own(data, 'rate_limits') ? data.rate_limits : {};
  check(record(limits));
  const fiveHour = own(limits, 'five_hour') ? quotaWindow(limits.five_hour) : null;
  const sevenDay = own(limits, 'seven_day') ? quotaWindow(limits.seven_day) : null;
  return {
    experimental: true,
    provider: 'claude',
    source: 'claude_code_statusline',
    identity: 'unknown',
    receivedAt: new Date(receivedAtMs).toISOString(),
    providerObservedAt: null,
    quota: { fiveHour, sevenDay },
  };
}

async function main() {
  if (process.argv.length !== 2) throw fail('invalid_arguments');
  const chunks = [];
  let size = 0;
  try {
    for await (const chunk of process.stdin) {
      size += chunk.length;
      if (size > MAX_BYTES) throw fail('input_limit');
      chunks.push(chunk);
    }
  } catch (error) {
    throw fail(error?.code === 'input_limit' ? 'input_limit' : 'stdin_failed');
  }
  const receivedAtMs = Date.now();
  const result = parseClaudeStatusline(Buffer.concat(chunks, size), receivedAtMs);
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
