import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, readFile, stat, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import http from 'node:http';
import { snapshotFromRows, demoSnapshot } from './snapshot.mjs';
import { collect, cachedCollector } from './collector.mjs';
import { createBridge } from './server.mjs';
import { formatStatus } from './status.mjs';

test('upstream used percentages become remaining; null/placeholder/error are not exhaustion and identities never leave host', () => {
  const snapshot = snapshotFromRows([
    { provider: 'claude', diagnostic: 'secret-diag', account: 'private@example.com', rateWindowLabels: { primary: 'Session', secondary: 'privatecredential' }, usage: { updatedAt: '2026-10-13T09:01:02Z', identity: { loginMethod: 'Max', accountEmail: 'private@example.com' }, primary: { usedPercent: 28 }, secondary: { usedPercent: 100 }, tertiary: { usedPercent: 0, isSyntheticPlaceholder: true } } },
    { provider: 'codex', usage: { loginMethod: 'Bearer privatecredential', primary: { usedPercent: 142 }, secondary: { usedPercent: -8 } } },
    { provider: 'gemini', rateWindowLabels: { primary: 'Pro', secondary: 'Flash' }, usage: { primary: { usedPercent: 7.25 }, secondary: null } },
    { provider: 'grok', error: { message: 'secret-diag private@example.com' } },
  ]);
  const [claude, codex, gemini, grok] = snapshot.providers;
  assert.deepEqual(claude.windows.map(w => w.remainingPercent), [72, 0, null]);
  assert.equal(claude.windows[1].label, 'Weekly');
  assert.equal(claude.plan, 'Max');
  assert.equal(claude.observedAt, '2026-10-13T09:01:02.000Z');
  assert.equal(codex.plan, null);
  assert.deepEqual(codex.windows.map(w => w.remainingPercent), [0, null]);
  assert.equal(gemini.windows[0].remainingPercent, 92.75);
  assert.equal(gemini.windows[0].label, 'Pro');
  assert.equal(grok.state, 'error'); assert.deepEqual(grok.windows, []);
  assert.doesNotMatch(JSON.stringify(snapshot), /secret-diag|private@example|privatecredential|Bearer/);
  assert.equal(snapshotFromRows([]).providers.every(p => p.state === 'unavailable' && !p.windows.length), true);
  assert.equal(demoSnapshot().demo, true);
});

test('HTTP contract requires bearer; rejects hostile origin/host, traversal, writes, oversized data and request floods', async t => {
  const token = 'a'.repeat(64);
  let snapshot = demoSnapshot();
  const server = await createBridge({ token, getSnapshot: async () => snapshot });
  await new Promise(ok => server.listen(0, '127.0.0.1', ok));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const auth = { Authorization: `Bearer ${token}` };
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  assert.equal((await fetch(`${base}/v1/snapshot`)).status, 401);
  assert.equal((await fetch(`${base}/v1/snapshot`, { headers: { Authorization: 'Bearer wrong' } })).status, 401);
  const response = await fetch(`${base}/v1/snapshot`, { headers: auth });
  assert.deepEqual(await response.json(), snapshot);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.match(response.headers.get('content-security-policy'), /connect-src 'self'/);
  assert.equal(response.headers.get('access-control-allow-origin'), null);
  assert.equal((await fetch(`${base}/v1/snapshot`, { headers: { ...auth, Origin: 'https://evil.test' } })).status, 403);
  const hostileHostStatus = await new Promise((resolve, reject) => {
    const request = http.get(`${base}/v1/snapshot`, { headers: { ...auth, Host: 'evil.test' } }, response => { response.resume(); resolve(response.statusCode); });
    request.on('error', reject);
  });
  assert.equal(hostileHostStatus, 403);
  assert.equal((await fetch(`${base}/v1/snapshot`, { method: 'POST', headers: auth })).status, 405);
  assert.equal((await fetch(`${base}/%2e%2e/.git/config`)).status, 404);
  assert.equal((await fetch(`${base}/icons/grok.svg`)).status, 200);
  const chevron = await fetch(`${base}/chevron-down.svg`);
  assert.equal(chevron.status, 200);
  assert.equal(chevron.headers.get('content-type'), 'image/svg+xml');
  assert.match(chevron.headers.get('content-security-policy'), /img-src 'self';/);
  snapshot = { data: 'x'.repeat(262145) };
  assert.equal((await fetch(`${base}/v1/snapshot`, { headers: auth })).status, 503);
  snapshot = demoSnapshot();
  let last;
  for (let i = 0; i < 31; i++) last = await fetch(`${base}/v1/snapshot`);
  assert.equal(last.status, 429);
  const afterAttack = await fetch(`${base}/v1/snapshot`, { headers: auth });
  assert.equal(afterAttack.status, 200);
  assert.deepEqual(await afterAttack.json(), snapshot);
  for (let i = 0; i < 31; i++) last = await fetch(`${base}/v1/snapshot`, { headers: auth });
  assert.equal(last.status, 429);
  await assert.rejects(createBridge({ host: '0.0.0.0', token, getSnapshot: async () => snapshot }), /requires TLS/);
});

test('collector isolates errors, accepts valid JSON on nonzero exit, and bounds hung or oversized CLI output', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'quotadock-test-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const fake = join(dir, 'fake-cli');
  await writeFile(fake, `#!${process.execPath}
const id = process.argv[process.argv.indexOf('--provider') + 1];
if (id === 'grok') { setInterval(() => {}, 1000); }
else if (id === 'gemini') { process.stdout.write('x'.repeat(1048577)); }
else if (id === 'claude') { process.stdout.write(JSON.stringify([{provider:id,usage:{loginMethod:'Pro',primary:{usedPercent:31}}}])); process.exitCode=1; }
else { process.stdout.write('not json privatecredential'); }
`, { mode: 0o700 });
  const snapshot = await collect({ binary: fake, timeoutMs: 1500 });
  assert.equal(snapshot.providers[0].windows[0].remainingPercent, 69);
  assert.equal(snapshot.providers[0].plan, 'Pro');
  assert.equal(snapshot.providers.slice(1).every(p => p.state === 'error'), true);
  assert.doesNotMatch(JSON.stringify(snapshot), /privatecredential/);
  const missing = await collect({ binary: join(dir, 'missing') });
  assert.equal(missing.providers.every(p => p.state === 'error'), true);
});

test('concurrent readers share a cached reading until its TTL expires', async () => {
  let time = 0, calls = 0;
  const get = cachedCollector(async () => ({ reading: ++calls }), { now: () => time, ttlMs: 60000 });
  assert.deepEqual(await Promise.all([get(), get(), get()]), [{ reading: 1 }, { reading: 1 }, { reading: 1 }]);
  time = 59999; assert.deepEqual(await get(), { reading: 1 });
  time = 60000; assert.deepEqual(await get(), { reading: 2 });
});

test('default cache clock expires by elapsed time even when Date.now moves backward', async t => {
  let wallTime = Date.now(), calls = 0;
  t.mock.method(Date, 'now', () => wallTime);
  const stamp = '2026-10-13T09:01:02.000Z';
  const get = cachedCollector(async () => { calls++; return demoSnapshot(new Date(stamp)); }, { ttlMs: 20 });
  const first = await get();
  wallTime -= 3600000;
  // Use real elapsed time: mocking an injected clock would bypass the production default.
  await new Promise(resolve => setTimeout(resolve, 60));
  const refreshed = await get();
  assert.equal(calls, 2);
  assert.notStrictEqual(refreshed, first);
  assert.equal(refreshed.generatedAt, stamp);
  assert.equal(refreshed.providers[0].observedAt, stamp);
});

test('concurrent load failures clear single-flight state so readers can retry', async () => {
  const failed = Promise.withResolvers();
  const error = new Error('load failed');
  let calls = 0;
  const get = cachedCollector(() => ++calls === 1 ? failed.promise : { reading: calls });
  const failures = [get(), get()].map(result => assert.rejects(result, error));
  await Promise.resolve();
  assert.equal(calls, 1);
  failed.reject(error);
  await Promise.all(failures);
  assert.deepEqual(await Promise.all([get(), get()]), [{ reading: 2 }, { reading: 2 }]);
  assert.equal(calls, 2);
  assert.deepEqual(await get(), { reading: 2 });
});

test('init preserves an existing token and refuses insecure token file permissions', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'quotadock-token-test-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, 'token');
  const run = (...args) => promisify(execFile)(process.execPath, ['bridge/cli.mjs', ...args], { cwd: new URL('..', import.meta.url), env: { ...process.env, QUOTADOCK_TOKEN_FILE: file } });
  const created = await run('init');
  const token = await readFile(file, 'utf8');
  assert.match(token.trim(), /^[a-f0-9]{64}$/);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.ok(!created.stdout.includes(token.trim()));
  await run('init'); assert.equal(await readFile(file, 'utf8'), token);
  await chmod(file, 0o644);
  await assert.rejects(run('serve', '--demo'), error => error.stderr.includes('mode 0600') && !error.stderr.includes(token.trim()));
});

test('status text preserves independent measured, zero and unknown windows without exposing upstream text; default stays JSON', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'quotadock-status-test-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const fake = join(dir, 'codexbar');
  await writeFile(fake, `#!${process.execPath}
const id = process.argv[process.argv.indexOf('--provider') + 1];
const usage = { loginMethod: 'Max', updatedAt: '2020-01-02T03:04:05Z',
  primary: { usedPercent: 100, resetsAt: '2020-01-02T04:00:00Z' },
  secondary: { usedPercent: 72.75 }, tertiary: { usedPercent: 0, isSyntheticPlaceholder: true } };
if (id === 'grok') process.stdout.write(JSON.stringify([{ provider: id, error: { message: 'privatecredential\\u001b[2J private@example.com' } }]));
else process.stdout.write(JSON.stringify([{ provider: id, usage: id === 'claude' ? usage : { ...usage, updatedAt: null, loginMethod: 'privatecredential' } }]));
`, { mode: 0o700 });
  const run = (...args) => promisify(execFile)(process.execPath, ['bridge/cli.mjs', ...args], {
    cwd: new URL('..', import.meta.url), env: { ...process.env, QUOTADOCK_CODEXBAR_BIN: fake },
  });
  const json = JSON.parse((await run('status')).stdout);
  assert.equal(json.schemaVersion, 1);
  assert.equal(json.demo, false);
  assert.deepEqual(json.providers[0].windows.map(window => window.remainingPercent), [0, 27.25, null]);
  const en = (await run('status', '--text')).stdout;
  assert.match(en, /Allowmark · LOCAL CHECK/);
  assert.match(en, /Claude · Plan: Max/);
  assert.match(en, /Observed: 2020-01-02T03:04:05\.000Z · STALE/);
  assert.ok(en.includes('Session [------------------------------] 0% remaining'));
  assert.ok(en.includes('Weekly [########----------------------] 27.25% remaining'));
  assert.ok(en.includes('Additional [??????????????????????????????] Unknown'));
  assert.match(en, /Reset: 2020-01-02T04:00:00\.000Z/);
  assert.match(en, /Codex · Plan: Unknown\n  Observed: Unknown · UNKNOWN TIME/);
  assert.match(en, /Grok · Plan: Unknown/);
  assert.match(en, /Times are UTC.*Windows are independent.*does not refill.*not total ChatGPT usage/);
  const ko = (await run('status', '--text', '--language=ko')).stdout;
  assert.match(ko, /Claude · 요금제: Max/);
  assert.ok(ko.includes('세션 [------------------------------] 0% 남음'));
  assert.ok(ko.includes('추가 [??????????????????????????????] 알 수 없음'));
  assert.match(ko, /오래된 관측/);
  assert.match(ko, /각 구간은 독립적이며 합산하지 않습니다/);
  assert.doesNotMatch(en + ko + JSON.stringify(json), /privatecredential|private@example|\u001b/);
  const demo = (await run('status', '--text', '--demo', '--language=en')).stdout;
  assert.match(demo, /DEMO · SAMPLE DATA/);
  for (const args of [['serve', '--text'], ['init', '--text'], ['status', '--language=ko'],
    ['status', '--text', '--language=fr'], ['status', '--text', '--language=en', '--language=ko']]) {
    await assert.rejects(run(...args), error => error.stdout === '' && error.stderr.includes('Usage:'));
  }
});

test('text freshness follows the original observation boundary, not generated or reset times', () => {
  const observedAt = '2026-10-21T10:00:00Z';
  const snapshot = snapshotFromRows([{ provider: 'claude', usage: { updatedAt: observedAt,
    primary: { usedPercent: 1.25, resetsAt: observedAt } } },
  { provider: 'codex', usage: { updatedAt: observedAt, primary: { usedPercent: 99.996 },
    secondary: { usedPercent: 0.0001 }, tertiary: { usedPercent: 0 } } }], new Date('2026-10-21T12:00:00Z'));
  const now = Date.parse(observedAt);
  assert.match(formatStatus(snapshot, { now: now + 900000 }), /Observed: .* · RECENT OBSERVATION/);
  const expired = formatStatus(snapshot, { now: now + 900001 });
  assert.match(expired, /Observed: .* · STALE/);
  assert.match(expired, /98\.75% remaining/);
  assert.match(formatStatus(snapshot, { now: now - 1 }), /Observed: .* · FUTURE TIMESTAMP/);
  assert.ok(expired.includes('Session [#-----------------------------] Less than 0.01% remaining'));
  assert.ok(expired.includes('Weekly [#############################-] More than 99.99% remaining'));
  assert.ok(expired.includes('Additional [##############################] 100% remaining'));
  const ko = formatStatus(snapshot, { language: 'ko', now });
  assert.match(ko, /0\.01% 미만 남음/);
  assert.match(ko, /99\.99% 초과 남음/);
});
