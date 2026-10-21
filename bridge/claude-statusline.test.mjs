import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { parseClaudeStatusline } from './claude-statusline.mjs';

const now = 1800000000000;
const parse = (data, time = now) => parseClaudeStatusline(Buffer.from(JSON.stringify(data)), time);
const cli = (input, args = []) => spawnSync(process.execPath, [new URL('./claude-statusline.mjs', import.meta.url).pathname, ...args], { input, encoding: 'utf8' });

test('exact allowlist, decimal percentages, preserved past reset and unknown identity', () => {
  const result = parse({ email: 'PRIVATE', session_id: 'PRIVATE', cwd: 'PRIVATE', model: 'PRIVATE', cost: 'PRIVATE', transcript_path: 'PRIVATE', arbitrary: { secret: 'PRIVATE' }, rate_limits: { five_hour: { used_percentage: 23.5, resets_at: 1, secret: 'PRIVATE' }, seven_day: { used_percentage: 41.2, resets_at: 1900000000 }, spend_limit: { secret: 'PRIVATE' } } });
  assert.deepEqual(result, { experimental: true, provider: 'claude', source: 'claude_code_statusline', identity: 'unknown', receivedAt: '2027-01-15T08:00:00.000Z', providerObservedAt: null, quota: { fiveHour: { usedPercentage: 23.5, remainingPercentage: 76.5, resetsAt: 1 }, sevenDay: { usedPercentage: 41.2, remainingPercentage: 58.8, resetsAt: 1900000000 } } });
  assert.ok(!JSON.stringify(result).includes('PRIVATE'));
});

test('absence, partial windows, zero and exhaustion remain distinct', () => {
  assert.deepEqual(parse({}).quota, { fiveHour: null, sevenDay: null });
  assert.deepEqual(parse({ rate_limits: { five_hour: {} } }).quota.fiveHour, { usedPercentage: null, remainingPercentage: null, resetsAt: null });
  assert.deepEqual(parse({ rate_limits: { seven_day: { resets_at: 0 } } }).quota.sevenDay, { usedPercentage: null, remainingPercentage: null, resetsAt: 0 });
  for (const used of [0, 0.01, 99.99, 100]) {
    const window = parse({ rate_limits: { five_hour: { used_percentage: used } } }).quota.fiveHour;
    assert.equal(window.usedPercentage, used);
    assert.equal(window.remainingPercentage, 100 - used);
    assert.equal(window.resetsAt, null);
  }
});

test('repeated input updates receipt only, not observation or old quota', () => {
  const data = { rate_limits: { five_hour: { used_percentage: 100, resets_at: 1 } } };
  const a = parse(data), b = parse(data, now + 1000);
  assert.notEqual(a.receivedAt, b.receivedAt);
  assert.equal(b.providerObservedAt, null);
  assert.deepEqual(a.quota, b.quota);
});

test('strict shape and numeric validation with fixed private-safe errors', () => {
  const bad = [null, [], 'PRIVATE', 1, { rate_limits: null }, { rate_limits: [] }];
  for (const window of [null, [], 1, { used_percentage: null }, { used_percentage: 'PRIVATE' }, { used_percentage: -1 }, { used_percentage: 100.01 }, { resets_at: null }, { resets_at: -1 }, { resets_at: 1.5 }, { resets_at: Number.MAX_SAFE_INTEGER + 1 }]) bad.push({ rate_limits: { seven_day: window } });
  for (const data of bad) assert.throws(() => parse(data), { code: 'invalid_shape', message: 'Claude statusline: invalid_shape' });
  assert.throws(() => parseClaudeStatusline('{}', now), { code: 'invalid_input' });
  assert.throws(() => parse({}, NaN), { code: 'invalid_receipt_time' });
  assert.throws(() => parseClaudeStatusline(Buffer.from('{"rate_limits":{"five_hour":{"used_percentage":1e999}}}'), now), { code: 'invalid_shape' });
});

test('byte boundary, strict UTF-8 and JSON', () => {
  const exact = Buffer.from(`{"private":"${'é'.repeat(32761)}"}`);
  assert.equal(exact.length, 65536);
  assert.equal(parseClaudeStatusline(exact, now).identity, 'unknown');
  assert.throws(() => parseClaudeStatusline(Buffer.concat([exact, Buffer.from(' ')]), now), { code: 'input_limit' });
  assert.throws(() => parseClaudeStatusline(Buffer.from([0xff]), now), { code: 'invalid_utf8' });
  for (const raw of ['', 'PRIVATE', '{}{}', '\ufeff{}']) assert.throws(() => parseClaudeStatusline(Buffer.from(raw), now), { code: 'invalid_json' });
});

test('CLI emits one sanitized JSON line or fixed error without input', () => {
  const result = cli('{"session_id":"PRIVATE","rate_limits":{"five_hour":{"used_percentage":0}}}');
  assert.equal(result.status, 0);
  assert.equal(result.stderr, '');
  assert.equal(JSON.parse(result.stdout).quota.fiveHour.remainingPercentage, 100);
  assert.equal(result.stdout.trim().split('\n').length, 1);
  assert.ok(!result.stdout.includes('PRIVATE'));
  for (const [input, code, args] of [['PRIVATE', 'invalid_json', []], [Buffer.from([255]), 'invalid_utf8', []], [Buffer.alloc(65537, 65), 'input_limit', []], ['{}', 'invalid_arguments', ['PRIVATE']]]) {
    const failure = cli(input, args);
    assert.equal(failure.status, 1);
    assert.equal(failure.stdout, '');
    assert.equal(failure.stderr, `Claude statusline: ${code}\n`);
  }
});
