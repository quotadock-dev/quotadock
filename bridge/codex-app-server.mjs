import { spawn } from 'node:child_process';
import { realpath, stat } from 'node:fs/promises';
import { isAbsolute } from 'node:path';
import { createHmac } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const plans = new Set(['free', 'go', 'plus', 'pro', 'prolite', 'promax', 'team', 'self_serve_business_prolite', 'self_serve_business_usage_based', 'business', 'ent26', 'enterprise_cbp_automation', 'enterprise_cbp_usage_based', 'enterprise', 'edu', 'edu_plus', 'edu_pro', 'unknown']);
const fail = (code) => Object.assign(new Error(`Codex quota: ${code}`), { code });
const check = (ok, code = 'unsupported_contract') => { if (!ok) throw fail(code); };
const textId = (s) => typeof s === 'string' && s.length > 0 && s.length <= 512;

function identity(result) {
  const a = result?.account;
  const r = result?.workspaceRouting;
  check(a?.type === 'chatgpt' && plans.has(a.planType) && result.requiresOpenaiAuth === true);
  // Deliberately support only the unconstrained official origin, not regional/custom routing.
  check(textId(r?.chatgptAccountId) && r.backendOrigin === 'https://chatgpt.com' && r.accountRoutingOverride === 'NO_CONSTRAINT');
  check(a.email === null || typeof a.email === 'string');
  return { id: r.chatgptAccountId, plan: a.planType, email: a.email };
}

function window(value) {
  if (value == null) return null;
  check(Number.isInteger(value.usedPercent) && value.usedPercent >= 0 && value.usedPercent <= 100);
  for (const key of ['windowDurationMins', 'resetsAt']) {
    check(value[key] == null || (Number.isSafeInteger(value[key]) && value[key] >= 0));
  }
  return { usedPercent: value.usedPercent, windowDurationMins: value.windowDurationMins ?? null, resetsAt: value.resetsAt ?? null };
}

/** Local trusted API only. executable and scopeKey must never come from HTTP input. */
export async function readCodexQuota({ codexHome, executable = '/usr/local/bin/codex', scopeKey, timeoutMs = 8000 } = {}) {
  check(typeof codexHome === 'string' && isAbsolute(codexHome), 'invalid_home');
  check(typeof executable === 'string' && isAbsolute(executable), 'invalid_executable');
  check(typeof scopeKey === 'string' && Buffer.byteLength(scopeKey) >= 32, 'invalid_scope_key');
  check(Number.isInteger(timeoutMs) && timeoutMs >= 50 && timeoutMs <= 30000, 'invalid_deadline');
  let child;
  let timer;
  let killTimer;
  const pending = new Map();
  let fatal;
  const abort = (code) => {
    fatal ??= fail(code);
    for (const { reject } of pending.values()) reject(fatal);
    pending.clear();
  };
  try {
    const home = await realpath(codexHome).catch(() => { throw fail('invalid_home'); });
    const info = await stat(home).catch(() => { throw fail('invalid_home'); });
    check(home === codexHome && info.isDirectory() && info.uid === process.getuid?.() && (info.mode & 0o022) === 0, 'invalid_home');
    const env = { CODEX_HOME: home };
    // Allowlist rather than trying to enumerate every token, proxy and TLS override.
    for (const key of ['HOME', 'USER', 'LOGNAME', 'TMPDIR', 'SYSTEMROOT']) if (process.env[key]) env[key] = process.env[key];
    env.PATH = '/usr/bin:/bin';
    child = spawn(executable, ['-c', 'chatgpt_base_url="https://chatgpt.com/backend-api/"', '-c', 'analytics.enabled=false', '-c', 'feedback.enabled=false', '-c', 'respect_system_proxy=false', 'app-server', '--listen', 'stdio://'], { cwd: home, env, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
    child.on('error', () => abort('child_failed'));
    child.on('exit', () => abort('child_exited'));
    child.stdin.on('error', () => abort('child_failed'));
    let buffer = Buffer.alloc(0);
    let stdoutBytes = 0;
    let stderrBytes = 0;
    child.stderr.on('data', (data) => { stderrBytes += data.length; if (stderrBytes > 65536) abort('output_limit'); });
    child.stdout.on('data', (data) => {
      if (fatal) return;
      stdoutBytes += data.length;
      if (stdoutBytes > 262144) return abort('output_limit');
      buffer = Buffer.concat([buffer, data]);
      if (buffer.length > 65536 && !buffer.includes(10)) return abort('output_limit');
      let end;
      while ((end = buffer.indexOf(10)) !== -1) {
        const line = buffer.subarray(0, end);
        buffer = buffer.subarray(end + 1);
        try {
          check(line.length <= 65536, 'output_limit');
          const msg = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(line));
          check(msg && typeof msg === 'object' && !Array.isArray(msg), 'invalid_frame');
          if ('method' in msg) {
            check(typeof msg.method === 'string' && !('id' in msg), 'unexpected_request');
            if (msg.method.startsWith('account/') && msg.method !== 'account/rateLimits/updated') throw fail('account_changed');
            continue;
          }
          check(pending.has(msg.id), 'unexpected_response');
          check(!('error' in msg) && 'result' in msg, 'provider_error');
          const p = pending.get(msg.id);
          pending.delete(msg.id);
          p.resolve(msg.result);
        } catch (error) { abort(error.code || 'invalid_frame'); return; }
      }
      if (buffer.length > 65536) abort('output_limit');
    });
    timer = setTimeout(() => abort('deadline'), timeoutMs);
    let nextId = 0;
    const send = (msg) => child.stdin.write(`${JSON.stringify(msg)}\n`);
    const request = (method, params) => new Promise((resolve, reject) => {
      if (fatal) return reject(fatal);
      const id = nextId++;
      pending.set(id, { resolve, reject });
      send({ id, method, params });
    });
    const initialized = await request('initialize', { clientInfo: { name: 'quotadock_experimental', version: '0.1.0' }, capabilities: { experimentalApi: true } });
    check(typeof initialized?.userAgent === 'string');
    send({ method: 'initialized', params: {} });
    const before = identity(await request('account/read', { refreshToken: false }));
    const quota = await request('account/rateLimits/read', { excludeResetCreditDetails: true, supportsLunaReserve: false });
    const receivedAt = new Date().toISOString();
    const after = identity(await request('account/read', { refreshToken: false }));
    check(!fatal, 'account_changed');
    check(before.id === after.id && before.plan === after.plan && before.email === after.email, 'account_changed');
    check(textId(quota?.accountId) && quota.accountId === before.id, 'account_mismatch');
    const bucket = quota.rateLimitsByLimitId?.codex ?? quota.rateLimits;
    check(bucket?.limitId === 'codex');
    check(bucket.planType == null || (plans.has(bucket.planType) && bucket.planType === before.plan));
    return { experimental: true, provider: 'codex', scopeFingerprint: createHmac('sha256', scopeKey).update(JSON.stringify([home, before.id])).digest('hex'), planType: before.plan, receivedAt, providerObservedAt: null, quota: { limitId: 'codex', primary: window(bucket.primary), secondary: window(bucket.secondary) } };
  } catch (error) {
    throw fail(typeof error?.code === 'string' && /^[a-z_]+$/.test(error.code) ? error.code : 'reader_failed');
  } finally {
    clearTimeout(timer);
    if (child?.pid) {
      const stop = (signal) => { try { process.kill(-child.pid, signal); } catch { /* owned child already gone */ } };
      stop('SIGTERM');
      killTimer = setTimeout(() => stop('SIGKILL'), 100);
      await new Promise((resolve) => setTimeout(resolve, 120));
      clearTimeout(killTimer);
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.length !== 4) { process.stderr.write('Usage: node codex-app-server.mjs ABSOLUTE_CODEX_HOME ABSOLUTE_CODEX_EXECUTABLE\n'); process.exitCode = 1; }
  else {
    try { process.stdout.write(`${JSON.stringify(await readCodexQuota({ codexHome: process.argv[2], executable: process.argv[3], scopeKey: process.env.QUOTADOCK_SCOPE_KEY }))}\n`); }
    catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
  }
}
