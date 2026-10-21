import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { normalizeAmpCLI, readAmpQuota } from './amp-cli.mjs';
import { providers } from './snapshot.mjs';

const row = () => ({ provider: 'amp', source: 'cli', account: 'private@example.test', diagnostic: 'secret', rateWindowLabels: { primary: 'Agent usage', secondary: 'Orb usage' }, usage: { updatedAt: '2026-10-21T00:00:00Z', primary: { usedPercent: 0 }, secondary: { usedPercent: 100 }, extraRateWindows: [{ id: 'amp-free', window: { usedPercent: 25, resetsAt: '2026-10-22T00:00:00Z' } }] } });

test('distinct Agent, Orb and Free windows; whitelist output and unchanged defaults', () => {
  const result = normalizeAmpCLI([row()]);
  assert.equal(result.state, 'available');
  assert.deepEqual(result.windows.map(w => [w.id, w.remainingPercent]), [['agent', 100], ['orb', 0], ['free', 75]]);
  assert.equal(result.windows[2].resetsAt, '2026-10-22T00:00:00.000Z');
  assert.doesNotMatch(JSON.stringify(result), /private|secret/);
  assert.deepEqual(Object.keys(providers), ['claude', 'codex', 'gemini', 'grok']);
});

test('unknown, synthetic, credit-only, ambiguous and non-CLI contracts fail closed', () => {
  for (const value of [null, -1, 101, '20', NaN]) {
    const r = row(); r.usage.primary.usedPercent = value; r.usage.secondary.isSyntheticPlaceholder = true; r.usage.extraRateWindows = [];
    assert.equal(normalizeAmpCLI([r]).state, 'unavailable');
  }
  for (const rows of [[], [row(), row()], [{ ...row(), source: 'api' }], [{ provider: 'amp', source: 'cli', usage: { credits: 100 } }]]) assert.equal(normalizeAmpCLI(rows).state, 'unsupported');
  assert.equal(normalizeAmpCLI([{ ...row(), error: { message: 'secret' } }]).state, 'error');
  const free = { provider: 'amp', source: 'cli', usage: { identity: { loginMethod: 'Amp Free' }, primary: { usedPercent: 50 } } };
  assert.equal(normalizeAmpCLI([free]).windows[0].id, 'free');
});

async function fixture(t, body) {
  const home = await mkdtemp(join(tmpdir(), 'quotadock-amp-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const executable = join(home, 'fake');
  await writeFile(executable, `#!${process.execPath}\n${body}`, { mode: 0o700 });
  return { executable, home, path: '/usr/bin:/bin', timeoutMs: 1500 };
}

test('explicit CLI-only arguments, isolated environment and sanitized result', async t => {
  const options = await fixture(t, `
import assert from 'node:assert/strict';
assert.deepEqual(process.argv.slice(2), ['usage','--provider','amp','--source','cli','--format','json','--json-only']);
assert.deepEqual(Object.keys(process.env).sort(), ['HOME','NO_COLOR','PATH','XDG_CACHE_HOME','XDG_CONFIG_HOME'].sort());
assert.equal(process.cwd(), process.env.HOME);
process.stdout.write(${JSON.stringify(JSON.stringify([row()]))});`);
  assert.equal((await readAmpQuota(options)).state, 'available');
});

for (const [mode, body, code] of [
  ['hung', 'setInterval(()=>{},1000)', 'deadline'],
  ['oversize', "process.stdout.write('x'.repeat(1048577))", 'output_limit'],
  ['malformed', "process.stdout.write('private secret')", 'invalid_json'],
  ['nonzero', `process.stdout.write(${JSON.stringify(JSON.stringify([row()]))});process.exitCode=1`, 'provider_failed'],
]) test(`bounded ${mode}`, async t => {
  const options = await fixture(t, body);
  if (mode === 'hung') options.timeoutMs = 100;
  await assert.rejects(readAmpQuota(options), { message: `Amp quota: ${code}` });
});

test('no default executable, home, PATH or insecure profile fallback', async t => {
  await assert.rejects(readAmpQuota(), /invalid_scope/);
  const options = await fixture(t, '');
  await chmod(options.home, 0o755);
  await assert.rejects(readAmpQuota(options), /invalid_scope/);
});
