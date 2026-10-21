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
