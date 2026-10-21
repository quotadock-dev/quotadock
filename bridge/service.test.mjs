import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, copyFile, writeFile, mkdir, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const cli = fileURLToPath(new URL('./service.mjs', import.meta.url));
const render = (args, file = cli, env = {}) => spawnSync(process.execPath, [file, ...args], {
  encoding: 'utf8', timeout: 5000,
  env: { ...process.env, ...env },
});
const userOnly = process.getuid?.() === 0 || !['linux', 'darwin'].includes(process.platform);

test('public help is harmless, deterministic, and describes readiness', () => {
  const a = render(['--help'], cli, { collectorToken: 'DO_NOT_EXPORT' });
  const b = render([]);
  assert.equal(a.status, 0);
  assert.equal(a.stderr, '');
  assert.equal(a.stdout, b.stdout);
  assert.match(a.stdout, /prior cloud.mjs pairing/);
  assert.match(a.stdout, /online and awake/);
  assert.match(a.stdout, /never root/);
  assert.doesNotMatch(a.stdout, /DO_NOT_EXPORT/);
});

test('public CLI rejects unsupported commands and extra/secret arguments without echoing', () => {
  for (const args of [['install'], ['systemd'], ['systemd', '--node', process.execPath], ['launchd', '--codexbar', process.execPath, 'SECRET_TOKEN']]) {
    const result = render(args);
    assert.equal(result.status, 1);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /See --help/);
    assert.doesNotMatch(result.stderr, /SECRET_TOKEN/);
  }
});

test('root cannot render a service (help remains available)', { skip: process.getuid?.() !== 0 }, () => {
  const result = render(['systemd', '--codexbar', process.execPath]);
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
});

test('public render pins actual executable and checkout with independent format expectations', { skip: userOnly }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'quotadock-service-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  // Node's ESM loader rejects backslashes in module paths; exercise that literal
  // in the CodexBar directory instead, which is serialized but never imported.
  const checkout = join(dir, 'space & <tag> "quote" %n $HOME end');
  await mkdir(join(checkout, 'bridge'), { recursive: true });
  const file = join(checkout, 'bridge', 'service.mjs');
  await copyFile(cli, file);
  // Not executed: rendering must not import or run the collector or CodexBar.
  await writeFile(join(checkout, 'bridge', 'cloud.mjs'), 'throw Error("MUST_NOT_RUN");');
  const binaryDir = join(checkout, 'literal \\ directory');
  await mkdir(binaryDir);
  const binary = join(binaryDir, 'codexbar');
  await writeFile(binary, 'not an executable program', { mode: 0o700 });
  const privateHome = join(dir, 'private-home');
  await mkdir(join(privateHome, '.config', 'quotadock-cloud'), { recursive: true });
  await writeFile(join(privateHome, '.config', 'quotadock-cloud', 'collector.json'), 'SECRET_GRANT');
  await writeFile(join(privateHome, '.config', 'quotadock-cloud', 'accounts.json'), 'SECRET_MAPPING');
  const env = { HOME: privateHome, collectorToken: 'SECRET_ENV', QUOTADOCK_CODEXBAR_BIN: 'SECRET_OVERRIDE' };
  const plist = render(['launchd', '--codexbar', binary], file, env);
  assert.equal(plist.status, 0, plist.stderr);
  assert.match(plist.stdout, /space &amp; &lt;tag&gt; &quot;quote&quot; %n \$HOME end/);
  assert.ok(plist.stdout.includes('<key>QUOTADOCK_CODEXBAR_BIN</key><string>' + dir + '/space &amp; &lt;tag&gt; &quot;quote&quot; %n $HOME end/literal \\ directory/codexbar</string>'));
  assert.ok(plist.stdout.includes(`<string>${await realpath(process.execPath)}</string>`));
  assert.match(plist.stdout, /<string>run<\/string><\/array>/);
  assert.match(plist.stdout, /<key>KeepAlive<\/key><false\/>/);
  const linux = render(['systemd', '--codexbar', binary], file, env);
  assert.equal(linux.status, 0, linux.stderr);
  assert.match(linux.stdout, /\nExecStart=:/);
  assert.ok(linux.stdout.includes('space & <tag> \\"quote\\" %%n $HOME end/bridge/cloud.mjs" "run"'));
  assert.ok(linux.stdout.includes('Environment="QUOTADOCK_CODEXBAR_BIN=' + dir + '/space & <tag> \\"quote\\" %%n $HOME end/literal \\\\ directory/codexbar"'));
  assert.ok(linux.stdout.includes('%%n $HOME')); // Dollar expansion is disabled, not substituted.
  assert.match(linux.stdout, /\nRestart=no\n/);
  assert.match(linux.stdout, /\nWantedBy=default.target\n/);
  for (const output of [plist.stdout, linux.stdout]) {
    assert.doesNotMatch(output, /SECRET_|collector\.json|accounts\.json|\/bin\/sh|sudo|Restart=always/);
  }
  assert.equal(render(['systemd', '--codexbar', binary], file, env).stdout, linux.stdout);
});

test('public CLI rejects ambiguous, control, missing and non-executable paths with empty stdout', { skip: userOnly }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'quotadock-service-reject-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const plain = join(dir, 'not-executable');
  await writeFile(plain, 'data', { mode: 0o600 });
  for (const path of ['relative', `${dir}/../node`, `${dir}//node`, `${dir}/bad\npath`, `${dir}/bad\tpath`, `${dir}/bad\u202epath`, `${dir}/missing`, dir, plain]) {
    for (const format of ['launchd', 'systemd']) {
      const result = render([format, '--codexbar', path]);
      assert.equal(result.status, 1);
      assert.equal(result.stdout, '');
      assert.match(result.stderr, /unsafe\/inaccessible path/);
    }
  }
});
