import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readCodexQuota } from './codex-app-server.mjs';

async function fixture(t, mode = 'ok', profile = 'A') {
  const home = await mkdtemp(join(tmpdir(), 'quotadock-fake-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const executable = join(home, 'fake');
  await writeFile(executable, `#!${process.execPath}
import readline from 'node:readline';
import assert from 'node:assert/strict';
const mode = ${JSON.stringify(mode)}, profile = ${JSON.stringify(profile)};
const send = x => process.stdout.write(JSON.stringify(x)+'\\n');
let reads=0, initialized=false;
const account = () => ({account: {type:'chatgpt',email:'private@example.test',planType: mode==='plan'?'future':'plus'},requiresOpenaiAuth:true,workspaceRouting:mode==='routingMissing'?null:{chatgptAccountId: mode==='switch' && reads>1?'switched':profile,backendOrigin:mode==='custom'?'http://evil.test':'https://chatgpt.com',accountRoutingOverride:'NO_CONSTRAINT'}});
readline.createInterface({input:process.stdin}).on('line', line=>{
 const m=JSON.parse(line);
 if(m.method==='initialized'){initialized=true;return;}
 if(mode==='stallInit')return;
 if(mode==='exit')process.exit(2);
 if(mode==='malformed'){process.stdout.write('private@example.test\\n');return;}
 if(mode==='invalid'){send([]);return;}
 if(mode==='invalidUtf8'){process.stdout.write(Buffer.from([255,10]));return;}
 if(mode==='oversize'){process.stdout.write('x'.repeat(70000));return;}
 if(mode==='stderr'){process.stderr.write('x'.repeat(70000));return;}
 if(mode==='outOfOrder'){send({id:999,result:{}});return;}
 if(m.method==='initialize'){
  assert.equal(m.params.capabilities.experimentalApi,true);
  assert.equal(process.env.OPENAI_API_KEY,undefined);
  assert.equal(process.env.NODE_TLS_REJECT_UNAUTHORIZED,undefined);
  assert.equal(process.env.HTTPS_PROXY,undefined);
  assert.equal(process.env.QUOTADOCK_SCOPE_KEY,undefined);
  send({id:m.id,result:{userAgent:'fake'}});return;
 }
 assert.equal(initialized,true);
 if(m.method==='account/read') {assert.equal(m.params.refreshToken,false);reads++;send({id:m.id,result:account()});return;}
 assert.equal(m.method,'account/rateLimits/read');
 assert.deepEqual(m.params,{excludeResetCreditDetails:true,supportsLunaReserve:false});
 if(mode==='stallBody')return;
 if(mode==='notify')send({method:'account/updated',params:{email:'private@example.test'}});
 if(mode==='login')send({method:'account/login/completed',params:{}});
 if(mode==='benign')send({method:'account/rateLimits/updated',params:{}});
 if(mode==='error'){send({id:m.id,error:{message:'private@example.test'}});return;}
 const bucket={limitId:mode==='bucket'?'future':'codex',planType:null,primary:mode==='unknown'?null:{usedPercent:profile==='A'?0:87,windowDurationMins:300,resetsAt:mode==='nullTime'?null:1730947200},secondary:{usedPercent:40,windowDurationMins:10080,resetsAt:1730950800}};
 send({id:m.id,result:{accountId:mode==='missing'?null:mode==='mismatch'?'other':profile,rateLimits:bucket,rateLimitsByLimitId:null}});
});
`, { mode: 0o700 });
  return { codexHome: home, executable, scopeKey: 's'.repeat(32), timeoutMs: 1500 };
}

test('asymmetric explicit scopes; sanitized stable fingerprints, zero, reset seconds and unchanged old times', async (t) => {
  const a = await fixture(t);
  const b = await fixture(t, 'ok', 'B');
  const [one, two] = await Promise.all([readCodexQuota(a), readCodexQuota(b)]);
  assert.notEqual(one.scopeFingerprint, two.scopeFingerprint);
  assert.equal(one.quota.primary.usedPercent, 0);
  assert.equal(two.quota.primary.usedPercent, 87);
  assert.equal(one.quota.secondary.resetsAt, 1730950800);
  const again = await readCodexQuota(a);
  assert.equal(one.scopeFingerprint, again.scopeFingerprint);
  assert.equal(one.quota.primary.resetsAt, again.quota.primary.resetsAt);
  assert.equal(one.providerObservedAt, null);
  assert.ok(Date.parse(one.receivedAt));
  assert.ok(!JSON.stringify(one).includes('private@'));
  assert.ok(!JSON.stringify(one).includes(a.codexHome));
});

for (const mode of ['unknown', 'nullTime', 'benign']) test(mode, async (t) => {
  const result = await readCodexQuota(await fixture(t, mode));
  if (mode === 'unknown') assert.equal(result.quota.primary, null);
  if (mode === 'nullTime') assert.equal(result.quota.primary.resetsAt, null);
});

for (const mode of ['switch', 'missing', 'mismatch', 'routingMissing', 'custom', 'plan', 'bucket', 'malformed', 'invalid', 'invalidUtf8', 'oversize', 'stderr', 'outOfOrder', 'notify', 'login', 'error', 'exit', 'stallInit', 'stallBody']) test(`reject ${mode} without PII`, async (t) => {
  const options = await fixture(t, mode);
  if (mode.startsWith('stall')) options.timeoutMs = 200;
  const start = Date.now();
  await assert.rejects(readCodexQuota(options), (error) => {
    assert.match(error.message, /^Codex quota: [a-z_]+$/);
    assert.ok(!error.message.includes('private'));
    return true;
  });
  assert.ok(Date.now() - start < 3000);
});

test('inherited secrets and transport overrides are not forwarded', async (t) => {
  const options = await fixture(t);
  const keys = ['OPENAI_API_KEY', 'NODE_TLS_REJECT_UNAUTHORIZED', 'HTTPS_PROXY', 'QUOTADOCK_SCOPE_KEY'];
  const prior = keys.map(key => process.env[key]);
  try {
    for (const key of keys) process.env[key] = 'secret';
    await readCodexQuota(options);
  } finally {
    keys.forEach((key, i) => { if (prior[i] === undefined) delete process.env[key]; else process.env[key] = prior[i]; });
  }
});

test('reject aliases and missing scope key before launching', async (t) => {
  const options = await fixture(t);
  const alias = `${options.codexHome}-alias`;
  await symlink(options.codexHome, alias);
  t.after(() => rm(alias));
  await assert.rejects(readCodexQuota({ ...options, codexHome: alias }), /invalid_home/);
  await assert.rejects(readCodexQuota({ ...options, scopeKey: '' }), /invalid_scope_key/);
});
