import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, stat, chmod, readdir, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { accounts, origin, observations } from './cloud.mjs';
import { collectAccounts, listAccounts, validateBindings } from './collector.mjs';
import { snapshotFromRows } from './snapshot.mjs';
const a = { id: 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa', provider: 'codex' };
const b = { id: 'bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb', provider: 'codex' };
test('doctor CLI is read-only, bounded and never emits private or child diagnostics', async t => {
  const home = await mkdtemp(join(tmpdir(), 'quotadock-doctor-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const dir = join(home, '.config', 'quotadock-cloud');
  const file = join(dir, 'collector.json'), binary = join(home, 'fake-codexbar');
  const secret = 'FAKE_TOKEN_private@example.test_raw-account-key';
  const fake = async body => writeFile(binary, `#!${process.execPath}\nif (JSON.stringify(process.argv.slice(2)) !== '["--version"]') process.exit(99);\n${body}`, { mode: 0o700 });
  await fake(`process.stdout.write(${JSON.stringify(secret)}); process.stderr.write(${JSON.stringify(secret)});`);
  const cli = async (...args) => {
    let result;
    try { result = await promisify(execFile)(process.execPath, [new URL('./cloud.mjs', import.meta.url).pathname, ...args], { env: { ...process.env, HOME: home, QUOTADOCK_CODEXBAR_BIN: binary }, timeout: 5000 }); }
    catch (e) { result = e; }
    const output = result.stdout + result.stderr;
    assert.doesNotMatch(output, /FAKE_TOKEN|private@example|raw-account-key|cccccccccccc|111111111111/);
    return { output, code: result.code ?? 0 };
  };
  assert.match((await cli('doctor')).output, /\[configuration\]/);
  await assert.rejects(stat(dir), { code: 'ENOENT' });
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const config = { base: 'https://example.invalid', collectorToken: 'c'.repeat(43), expiresAt: Date.now() + 60000, accounts: [a] };
  const save = value => writeFile(file, JSON.stringify(value), { mode: 0o600 });
  await save(config);
  const before = await readFile(file, 'utf8');
  const ok = await cli('doctor');
  assert.equal(ok.code, 0); assert.match(ok.output, /CodexBar --version: OK \(output withheld\)/);
  t.diagnostic(ok.output.trim());
  assert.equal(await readFile(file, 'utf8'), before);
  assert.deepEqual(await readdir(dir), ['collector.json']);
  const mappingFile = join(dir, 'accounts.json');
  const mapping = JSON.stringify({ [a.id]: { provider: 'codex', source: 'oauth', fingerprint: '1'.repeat(64) } });
  await writeFile(mappingFile, mapping, { mode: 0o600 });
  assert.equal((await cli('doctor')).code, 0);
  assert.equal(await readFile(mappingFile, 'utf8'), mapping);
  await rm(mappingFile);
  await save({ ...config, expiresAt: 1 });
  for (const command of ['doctor', 'once', 'run']) {
    const expired = await cli(command);
    assert.equal(expired.code, 1);
    assert.match(expired.output, /\[grant_expired\]/);
    if (command === 'once') t.diagnostic(expired.output.trim());
  }
  await save({ ...config, accounts: [a, b] });
  assert.match((await cli('doctor')).output, /\[bindings\]/);
  await save(config);
  await chmod(file, 0o644);
  assert.match((await cli('doctor')).output, /\[permissions\]/);
  await chmod(file, 0o600);
  await symlink(file, join(dir, 'accounts.json'));
  assert.match((await cli('doctor')).output, /\[permissions\]/);
  await rm(join(dir, 'accounts.json'));
  assert.match((await cli('accounts', 'codex', 'cli')).output, /\[unsupported_source\]/);
  await save({ ...config, accounts: Array.from({ length: 51 }, () => a) });
  assert.match((await cli('doctor')).output, /\[configuration\]/);
  await writeFile(file, secret);
  assert.match((await cli('doctor')).output, /\[configuration\]/);
  await save(config);
  for (const body of [`process.stderr.write(${JSON.stringify(secret)}); process.exitCode=1;`, "process.stdout.write('x'.repeat(5000));", 'setInterval(() => {}, 1000);']) {
    await fake(body);
    assert.match((await cli('doctor')).output, /\[cli_availability\]/);
  }
  await rm(binary);
  assert.match((await cli('doctor')).output, /\[cli_availability\]/);
});
test('cloud boundary accepts bounded independent slots but rejects unsafe origins and unsupported Gemini mapping', () => {
  for (const url of ['http://example.com', 'https://user:pass@example.com', 'https://example.com/path', 'https://example.com?token=secret']) assert.throws(() => origin(url));
  assert.equal(origin('https://example.com'), 'https://example.com');
  assert.deepEqual(accounts([a, b]), [a, b]);
  assert.throws(() => accounts([a, a]));
  assert.throws(() => accounts([a, { ...a, id: a.id.toUpperCase() }]));
  assert.throws(() => accounts([a, b].map(s => ({ ...s, provider: 'gemini' }))));
  assert.throws(() => observations([a, b], snapshotFromRows([])));
});
test('cloud uploads only whitelist fields and preserves source timestamp/no-data', () => {
  const stamp = '2026-10-13T12:00:00.000Z';
  const snapshot = snapshotFromRows([{ provider: 'codex', email: 'SECRET', usage: { updatedAt: stamp, identity: { loginMethod: 'ChatGPT Pro', token: 'SECRET' }, primary: { usedPercent: 20 } } }]);
  const [o] = observations([a], snapshot);
  assert.equal(o.observedAt, stamp); assert.equal(o.windows[0].remainingPercent, 80);
  assert.equal(JSON.stringify(o).includes('SECRET'), false); assert.equal(Object.hasOwn(o, 'message'), false);
  const [missing] = observations([a], snapshotFromRows([]));
  assert.equal(missing.observedAt, null); assert.equal(missing.state, 'unavailable');
});

test('mapping CLI stores private canonical bindings and preserves them on invalid or unsafe updates', async t => {
  const home = await mkdtemp(join(tmpdir(), 'quotadock-map-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const dir = join(home, '.config', 'quotadock-cloud');
  await mkdir(dir, { recursive: true, mode: 0o700 });
  await writeFile(join(dir, 'collector.json'), JSON.stringify({
    base: 'https://example.invalid', collectorToken: 'c'.repeat(43),
    expiresAt: Date.now() + 60000, accounts: [a, b],
  }), { mode: 0o600 });
  const cli = (...args) => promisify(execFile)(process.execPath, [new URL('./cloud.mjs', import.meta.url).pathname, 'map', ...args], {
    env: { ...process.env, HOME: home }, timeout: 5000,
  });
  const first = '1'.repeat(64), second = '2'.repeat(64);
  await cli(a.id.toUpperCase(), 'codex', first, 'oauth');
  await cli(b.id.toUpperCase(), 'codex', second, 'oauth');
  const file = join(dir, 'accounts.json');
  const saved = await readFile(file, 'utf8');
  assert.deepEqual(JSON.parse(saved), {
    [a.id]: { provider: 'codex', fingerprint: first, source: 'oauth' },
    [b.id]: { provider: 'codex', fingerprint: second, source: 'oauth' },
  });
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  for (const args of [[b.id, 'codex', first, 'oauth'], [a.id, 'codex', first, 'cli'], ['cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'codex', first, 'oauth']]) {
    await assert.rejects(cli(...args));
    assert.equal(await readFile(file, 'utf8'), saved);
  }
  await chmod(file, 0o644);
  await assert.rejects(cli(a.id, 'codex', second, 'oauth'));
  assert.equal(await readFile(file, 'utf8'), saved);
  assert.deepEqual((await readdir(dir)).sort(), ['accounts.json', 'collector.json']);
});

test('unverified explicit-key adapter selects local scopes, not verified provider owners', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'quotadock-accounts-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const binary = join(dir, 'codexbar');
  const rows = [
    { provider: 'codex', cacheAccountKey: 'codex:workspace:two:email:private@example.com', account: 'SECRET', usage: { updatedAt: '2026-10-13T12:01:02Z', loginMethod: 'ChatGPT Pro', primary: { usedPercent: 87 } } },
    { provider: 'codex', cacheAccountKey: 'codex:stored:one', account: 'SECRET', usage: { updatedAt: '2026-10-13T12:03:04Z', loginMethod: 'Free', primary: { usedPercent: 16 } } },
  ];
  const writeCLI = async value => writeFile(binary, `#!${process.execPath}\nif (process.argv.includes('--version')) process.exit(0);\nconst selected = process.argv.includes('--all-accounts') && process.argv[process.argv.indexOf('--source') + 1] === 'oauth';\nprocess.stdout.write(JSON.stringify(selected ? ${JSON.stringify(value)} : [{provider:'codex',usage:{primary:{usedPercent:1}}}]));\nprocess.exitCode=1;\n`, { mode: 0o700 });
  await writeCLI(rows);
  const fingerprint = key => createHash('sha256').update(`codex\0${key}`).digest('hex');
  const bindings = {
    [a.id]: { provider: 'codex', fingerprint: fingerprint(rows[1].cacheAccountKey), source: 'oauth' },
    [b.id]: { provider: 'codex', fingerprint: fingerprint(rows[0].cacheAccountKey), source: 'oauth' },
  };
  const listed = await listAccounts('codex', 'oauth', { binary });
  assert.deepEqual(listed, [bindings[b.id].fingerprint, bindings[a.id].fingerprint]);
  const result = observations([a, b], await collectAccounts([a, b], bindings, { binary }));
  assert.deepEqual(result.map(o => o.windows[0].remainingPercent), [84, 13]);
  assert.deepEqual(result.map(o => o.observedAt), ['2026-10-13T12:03:04.000Z', '2026-10-13T12:01:02.000Z']);
  assert.deepEqual(result.map(o => o.plan), ['Free', 'ChatGPT Pro']);
  assert.doesNotMatch(JSON.stringify(result), /SECRET|private@example|fingerprint|cacheAccountKey|codex:stored|codex:workspace/);
  assert.throws(() => validateBindings([a, b], {}));
  assert.throws(() => validateBindings([a, b], { ...bindings, [b.id]: bindings[a.id] }));
  assert.throws(() => validateBindings([a], { [a.id]: { ...bindings[a.id], source: 'cli' } }));
  assert.throws(() => validateBindings([a], { [b.id]: bindings[b.id] }));
  await assert.rejects(listAccounts('gemini', 'oauth', { binary }));
  await writeCLI([rows[1], rows[1]]);
  await assert.rejects(listAccounts('codex', 'oauth', { binary }), { message: 'ambiguous_scope' });
  const failed = observations([a, b], await collectAccounts([a, b], bindings, { binary }));
  assert.deepEqual(failed.map(o => [o.state, o.observedAt, o.windows]), [['error', null, []], ['error', null, []]]);
  // Public ProviderPayload CodingKeys at upstream 6480977b (0.77.1):
  // account is a display label; cacheAccountKey is deliberately not serialized.
  const publicRows = rows.map(({ cacheAccountKey, ...row }, index) => ({ ...row, source: 'oauth', version: '0.77.1', account: `private${index}@example.test` }));
  for (const value of [publicRows, [...publicRows].reverse()]) {
    await writeCLI(value);
    await assert.rejects(listAccounts('codex', 'oauth', { binary }), { message: 'unsupported_identity' });
    const snapshot = await collectAccounts([a, b], bindings, { binary });
    assert.equal(snapshot.compatibilityError, 'unsupported_identity');
    const uploaded = observations([a, b], snapshot);
    assert.deepEqual(uploaded.map(o => [o.state, o.observedAt, o.windows]), [['error', null, []], ['error', null, []]]);
    assert.doesNotMatch(JSON.stringify(uploaded), /private|SECRET|cacheAccountKey|fingerprint/);
    await assert.rejects(promisify(execFile)(process.execPath, [new URL('./cloud.mjs', import.meta.url).pathname, 'accounts', 'codex'], {
      env: { ...process.env, QUOTADOCK_CODEXBAR_BIN: binary }, timeout: 5000,
    }), error => {
      assert.equal(error.code, 1);
      assert.equal(error.stdout, '');
      assert.match(error.stderr, /\[unsupported_identity\].*Stop the worker/);
      assert.doesNotMatch(error.stderr, /private|SECRET|fingerprints|cacheAccountKey/);
      return true;
    });
  }
  await writeCLI([]);
  assert.deepEqual(await listAccounts('codex', 'oauth', { binary }), []);
  await writeCLI([{ provider: 'codex', error: { message: 'private@example.test' } }]);
  await assert.rejects(listAccounts('codex', 'oauth', { binary }), { message: 'provider_lookup' });
});
