import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer, request } from 'node:https';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { api, runOnce } from './cloud.mjs';

const slot = { id: 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa', provider: 'codex' };
const config = () => ({ base: 'https://example.invalid', collectorToken: 'c'.repeat(43), accounts: [slot], expiresAt: Date.now() + 60000 });
const secret = 'PRIVATE_TOKEN_email@example.test';
const lost = { code: 'ECONNRESET', message: secret };
function transport(handler) {
  const calls = [];
  const requestFn = (url, options, callback) => {
    assert.equal(url.protocol, 'https:');
    assert.equal(url.origin, 'https://example.invalid');
    assert.equal(options.headers.cookie, undefined);
    assert.equal(options.rejectUnauthorized, true);
    const req = new EventEmitter();
    req.destroy = () => req.emit('close');
    req.end = wire => {
      const call = { path: url.pathname, wire, options, at: Date.now() };
      calls.push(call);
      queueMicrotask(() => {
        const reply = handler(call, calls);
        if (reply.hang) return;
        if (reply.code) {
          req.emit('error', Object.assign(Error(reply.message), { code: reply.code }));
          req.emit('close');
          return;
        }
        const res = new EventEmitter();
        res.statusCode = reply.status ?? 200;
        res.headers = reply.headers ?? {};
        let destroyed = false;
        res.destroy = () => { destroyed = true; req.emit('close'); };
        callback(res);
        if (!destroyed) {
          res.emit('data', Buffer.from(reply.raw ?? JSON.stringify(reply.body ?? { job: null })));
          res.emit('end');
          req.emit('close');
        }
      });
    };
    return req;
  };
  return { requestFn, calls };
}

test('collector verifies TLS despite NODE_TLS_REJECT_UNAUTHORIZED=0; explicit test CA works', { timeout: 20000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'quotadock-tls-'));
  const previous = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
  const sockets = new Set();
  let server;
  t.after(async () => {
    if (previous === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    else process.env.NODE_TLS_REJECT_UNAUTHORIZED = previous;
    for (const socket of sockets) socket.destroy();
    try {
      if (server?.listening) await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(Error('HTTPS cleanup timeout')), 2000);
        server.close(error => { clearTimeout(timer); if (error) reject(error); else resolve(); });
      });
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
  // Generated only when this test is executed, never checked in. This private
  // self-signed test CA also serves as the loopback server certificate.
  await promisify(execFile)('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', join(dir, 'key.pem'), '-out', join(dir, 'cert.pem'), '-days', '1',
    '-subj', '/CN=QuotaDock local TLS test', '-addext', 'basicConstraints=critical,CA:TRUE',
    '-addext', 'subjectAltName=IP:127.0.0.1'], { timeout: 5000, killSignal: 'SIGKILL', maxBuffer: 16384 });
  const cert = await readFile(join(dir, 'cert.pem'));
  const received = [];
  server = createServer({ key: await readFile(join(dir, 'key.pem')), cert, handshakeTimeout: 2000 }, (req, res) => {
    received.push({ path: req.url, authorization: req.headers.authorization });
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ job: null }));
  });
  server.requestTimeout = 3000;
  server.on('connection', socket => {
    sockets.add(socket);
    const timer = setTimeout(() => socket.destroy(), 3000);
    socket.once('close', () => { clearTimeout(timer); sockets.delete(socket); });
  });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Error('HTTPS listen timeout')), 2000);
    server.once('error', error => { clearTimeout(timer); reject(error); });
    server.listen(0, '127.0.0.1', () => { clearTimeout(timer); resolve(); });
  });
  const base = `https://127.0.0.1:${server.address().port}`;
  const token = 't'.repeat(43); // Fake scoped collector credential only.
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
  // Same live endpoint, with trust supplied only through the existing I/O seam.
  assert.deepEqual(await api(base, '/trusted-control', token, undefined, {
    timeoutMs: 2000,
    requestFn: (url, options, callback) => {
      assert.equal(options.rejectUnauthorized, true);
      return request(url, { ...options, ca: cert, agent: false }, callback);
    },
  }), { job: null });
  assert.deepEqual(received, [{ path: '/trusted-control', authorization: `Bearer ${token}` }]);
  received.length = 0;
  // Exercise the default node:https transport, not a simulated TLS error.
  await assert.rejects(api(base, '/untrusted', token, undefined, { timeoutMs: 2000 }),
    error => error.message === 'service' && error.retryable === false);
  assert.deepEqual(received, [], 'untrusted TLS must fail before any HTTP bearer request');
});

test('committed automatic request with lost reply replays identical key and bytes', async () => {
  const committed = new Map();
  let posts = 0;
  const io = transport(call => {
    if (call.path.endsWith('/next')) return { body: { job: null } };
    const key = JSON.parse(call.wire).idempotencyKey;
    if (committed.has(key)) assert.equal(call.wire, committed.get(key));
    else committed.set(key, call.wire);
    return ++posts === 1 ? lost : { body: { status: 'pending' } };
  });
  await runOnce(config(), { automatic: true, requestFn: io.requestFn });
  assert.equal(posts, 2);
  assert.equal(committed.size, 1);
  const requests = io.calls.filter(c => c.wire);
  assert.equal(requests[0].wire, requests[1].wire);
});

test('lost committed completion replays original sanitized observation without recollection', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'quotadock-retry-'));
  const binary = join(dir, 'codexbar'), counter = join(dir, 'collections');
  const previous = process.env.QUOTADOCK_CODEXBAR_BIN;
  t.after(async () => {
    if (previous === undefined) delete process.env.QUOTADOCK_CODEXBAR_BIN;
    else process.env.QUOTADOCK_CODEXBAR_BIN = previous;
    await rm(dir, { recursive: true, force: true });
  });
  const stamp = '2026-10-13T01:00:00.000Z';
  await writeFile(binary, `#!${process.execPath}\nconst { appendFileSync } = require('node:fs');\nappendFileSync(${JSON.stringify(counter)}, '1');\nprocess.stderr.write(${JSON.stringify(secret)});\nprocess.stdout.write(JSON.stringify([{provider:'codex',email:${JSON.stringify(secret)},usage:{updatedAt:${JSON.stringify(stamp)},primary:{usedPercent:20}}}]));\n`, { mode: 0o700 });
  process.env.QUOTADOCK_CODEXBAR_BIN = binary;
  const job = { id: 'bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb', accounts: [slot], accountIds: [slot.id], createdAt: new Date(Date.now() - 5000).toISOString(), expiresAt: new Date(Date.now() + 60000).toISOString() };
  const completions = [];
  const io = transport(call => {
    if (call.path.endsWith('/next')) return { body: { job } };
    completions.push(call.wire);
    return completions.length === 1 ? lost : { body: { status: 'complete' } };
  });
  await runOnce(config(), { requestFn: io.requestFn });
  assert.equal(await readFile(counter, 'utf8'), '1');
  assert.equal(completions.length, 2);
  assert.equal(completions[0], completions[1]);
  const observation = JSON.parse(completions[0]).observations[0];
  assert.equal(observation.observedAt, stamp);
  assert.equal(observation.windows[0].remainingPercent, 80);
  assert.doesNotMatch(completions[0], /PRIVATE_TOKEN|email@example/);
  job.expiresAt = new Date(Date.now() + 2000).toISOString();
  const expiring = transport(call => call.path.endsWith('/next') ? { body: { job } } : { status: 503, headers: { 'retry-after': '2' } });
  await assert.rejects(runOnce(config(), { requestFn: expiring.requestFn }), { message: 'service' });
  assert.equal(expiring.calls.length, 2);
  assert.equal(await readFile(counter, 'utf8'), '11');
  // A mapped slot must not consume that same keyless ambient/public row.
  const mapped = { ...config(), bindings: { [slot.id]: { provider: 'codex', source: 'oauth', fingerprint: '1'.repeat(64) } } };
  for (const failCompletion of [false, true]) {
    const bodies = [];
    const incompatible = transport(call => {
      if (call.path.endsWith('/next')) return { body: { job } };
      bodies.push(call.wire);
      return bodies.length === 1 ? lost : failCompletion ? { status: 500 } : { body: { status: 'complete' } };
    });
    await assert.rejects(runOnce(mapped, { automatic: true, requestFn: incompatible.requestFn }), { message: 'unsupported_identity' });
    assert.equal(incompatible.calls.length, 3);
    assert.equal(bodies.length, 2);
    assert.equal(bodies[0], bodies[1]);
    assert.deepEqual(JSON.parse(bodies[0]).observations.map(o => [o.state, o.observedAt, o.windows]), [['error', null, []]]);
    assert.doesNotMatch(bodies[0], /PRIVATE_TOKEN|email@example|fingerprint|unsupported_identity/);
  }
});

test('only allowlisted transient HTTP and transport failures retry, at most three attempts', async () => {
  for (const status of [429, 502, 503, 504]) {
    const io = transport(() => ({ status, raw: secret }));
    await assert.rejects(runOnce(config(), { requestFn: io.requestFn }), { message: 'service' });
    assert.equal(io.calls.length, 3);
  }
  for (const status of [400, 401, 403, 404, 409, 422, 500, 301, 302, 307, 308]) {
    const io = transport(() => ({ status, raw: secret }));
    await assert.rejects(runOnce(config(), { requestFn: io.requestFn }), e => ['service', 'revoked', 'forbidden'].includes(e.message) && !e.message.includes(secret));
    assert.equal(io.calls.length, 1);
  }
  const tls = transport(() => ({ code: 'CERT_HAS_EXPIRED', message: secret }));
  await assert.rejects(runOnce(config(), { requestFn: tls.requestFn }), { message: 'service' });
  assert.equal(tls.calls.length, 1);
});

test('absolute deadline, grant expiry and Retry-After bound retries', async t => {
  for (const grant of [false, true]) {
    const io = transport(() => ({ hang: true }));
    const c = config();
    if (grant) c.expiresAt = Date.now() + 80;
    const start = Date.now();
    await assert.rejects(runOnce(c, { requestFn: io.requestFn, operationTimeoutMs: grant ? 5000 : 80 }), { message: 'service' });
    assert.equal(io.calls.length, 1);
    assert.ok(Date.now() - start < 1500);
  }
  const safe = transport((call, calls) => calls.length === 1 ? { status: 429, headers: { 'retry-after': '1' } } : {});
  await runOnce(config(), { requestFn: safe.requestFn });
  assert.ok(safe.calls[1].at - safe.calls[0].at >= 1000);
  // Model an early timer wake-up without relaxing the server's minimum delay.
  const setTimer = globalThis.setTimeout;
  const earlyTimer = t.mock.method(globalThis, 'setTimeout', (callback, delay, ...args) =>
    setTimer(callback, delay === 1000 ? 980 : delay, ...args));
  const early = transport((call, calls) => calls.length === 1 ? { status: 429, headers: { 'retry-after': '1' } } : {});
  await runOnce(config(), { requestFn: early.requestFn });
  earlyTimer.mock.restore();
  assert.ok(early.calls[1].at - early.calls[0].at >= 1000);
  for (const value of ['999999999999999999', secret, '1']) {
    const io = transport(() => ({ status: 503, headers: { 'retry-after': value } }));
    await assert.rejects(runOnce(config(), { requestFn: io.requestFn, operationTimeoutMs: 500 }), { message: 'service' });
    assert.equal(io.calls.length, 1);
  }
});

test('hostile and oversized success bodies are fatal and never exposed', async () => {
  for (const raw of [secret, secret.repeat(4000)]) {
    const io = transport(() => ({ raw }));
    await assert.rejects(runOnce(config(), { requestFn: io.requestFn }), { message: 'response' });
    assert.equal(io.calls.length, 1);
  }
  const io = transport(() => ({}));
  await assert.rejects(runOnce({ ...config(), base: 'http://example.invalid' }, { requestFn: io.requestFn }), { message: 'configuration' });
  await assert.rejects(async () => api('https://example.invalid', 'https://evil.invalid/next', null, undefined, { requestFn: io.requestFn }), { message: 'configuration' });
  assert.equal(io.calls.length, 0);
});

test('expired jobs never start collection or completion', async () => {
  const job = { id: 'bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb', accounts: [slot], accountIds: [slot.id], createdAt: new Date(Date.now() - 5000).toISOString(), expiresAt: new Date(Date.now() - 1000).toISOString() };
  const io = transport(() => ({ body: { job } }));
  await runOnce(config(), { requestFn: io.requestFn });
  assert.equal(io.calls.length, 1);
});

test('job target set rejects repeated or missing identities before collecting; casing and order are immaterial', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'quotadock-targets-'));
  const binary = join(dir, 'codexbar'), counter = join(dir, 'collections');
  const previous = process.env.QUOTADOCK_CODEXBAR_BIN;
  t.after(async () => {
    if (previous === undefined) delete process.env.QUOTADOCK_CODEXBAR_BIN;
    else process.env.QUOTADOCK_CODEXBAR_BIN = previous;
    await rm(dir, { recursive: true, force: true });
  });
  await writeFile(binary, `#!${process.execPath}\nconst { appendFileSync } = require('node:fs');\nappendFileSync(${JSON.stringify(counter)}, '1');\nprocess.stdout.write(JSON.stringify([{provider:'codex',usage:{primary:{usedPercent:20}}},{provider:'claude',usage:{primary:{usedPercent:83}}}]));\n`, { mode: 0o700 });
  process.env.QUOTADOCK_CODEXBAR_BIN = binary;
  const other = { id: 'cccccccc-cccc-4ccc-cccc-cccccccccccc', provider: 'claude' };
  const c = { ...config(), accounts: [slot, other] };
  const job = { id: 'bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb', accounts: c.accounts,
    createdAt: new Date(Date.now() - 5000).toISOString(), expiresAt: new Date(Date.now() + 60000).toISOString() };
  for (const accountIds of [[slot.id, slot.id], [slot.id, slot.id.toUpperCase()], [slot.id],
    [slot.id, null], [slot.id, 'dddddddd-dddd-4ddd-dddd-dddddddddddd']]) {
    const io = transport(() => ({ body: { job: { ...job, accountIds } } }));
    await assert.rejects(runOnce(c, { requestFn: io.requestFn }), { message: 'response' });
  }
  await assert.rejects(readFile(counter), { code: 'ENOENT' });
  let completion;
  const io = transport(call => {
    if (call.path.endsWith('/next')) return { body: { job: { ...job, accountIds: [other.id.toUpperCase(), slot.id.toUpperCase()] } } };
    completion = JSON.parse(call.wire).observations;
    return { body: { status: 'completed' } };
  });
  await runOnce(c, { requestFn: io.requestFn });
  assert.equal((await readFile(counter, 'utf8')).length, 2);
  assert.deepEqual(completion.map(o => [o.accountId, o.provider, o.windows[0].remainingPercent]),
    [[slot.id, 'codex', 80], [other.id, 'claude', 17]]);
});
