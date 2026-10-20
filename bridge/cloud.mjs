import { request } from 'node:https';
import { mkdir, open, lstat, rename, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { homedir } from 'node:os';
import { dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { collectAccounts, listAccounts, validateBindings } from './collector.mjs';
import { providers } from './snapshot.mjs';

const credential = /^[A-Za-z0-9_-]{43}$/;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const wait = async ms => {
  const until = Date.now() + ms;
  do {
    await new Promise(resolve => setTimeout(resolve, Math.max(1, until - Date.now())));
  } while (Date.now() < until);
};
export function origin(value) {
  const u = new URL(value);
  if (u.protocol !== 'https:' || u.username || u.password || u.search || u.hash || u.pathname !== '/') throw Error('configuration');
  return u.origin;
}
export function accounts(value) {
  if (!Array.isArray(value) || !value.length || value.length > 50 || value.some(a => !uuid.test(a?.id) || !Object.hasOwn(providers, a?.provider)) || value.filter(a => a.provider === 'gemini').length > 1 || new Set(value.map(a => a.id.toLowerCase())).size !== value.length) throw Error('unsupported_slots');
  return value.map(({ id, provider }) => ({ id: id.toLowerCase(), provider }));
}
const transientCodes = new Set(['ECONNRESET', 'ECONNREFUSED', 'EPIPE', 'ETIMEDOUT', 'EAI_AGAIN', 'ENETUNREACH', 'EHOSTUNREACH']);
function failure(message, retryable = false, retryAfter = 0) {
  return Object.assign(Error(message), { retryable, retryAfter });
}
function retryDelay(value) {
  if (value === undefined) return 0;
  if (typeof value !== 'string' || value.length > 128) return Infinity;
  const ms = /^\d+$/.test(value) ? Number(value) * 1000 : Date.parse(value) - Date.now();
  return Number.isFinite(ms) && ms <= 2000 ? Math.max(0, ms) : Infinity;
}
export function api(base, path, token, body, { requestFn = request, timeoutMs = 15000 } = {}) {
  // The injection seam changes only I/O, never origin or TLS validation/options.
  const url = new URL(path, origin(base));
  if (url.origin !== origin(base)) throw Error('configuration');
  const wire = body === undefined ? undefined : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const transportFailure = e => reject(failure('service', transientCodes.has(e?.code)));
    const req = requestFn(url, { rejectUnauthorized: true, method: body === undefined ? 'GET' : 'POST', headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body === undefined ? {} : { 'content-type': 'application/json' }) } }, res => {
      res.on('error', transportFailure);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        reject(failure(res.statusCode === 401 ? 'revoked' : res.statusCode === 403 ? 'forbidden' : 'service', [429, 502, 503, 504].includes(res.statusCode), retryDelay(res.headers?.['retry-after'])));
        res.destroy();
        return;
      }
      let size = 0; const chunks = [];
      res.on('data', chunk => { size += chunk.length; if (size > 65536) { reject(failure('response')); req.destroy(); } else chunks.push(chunk); });
      res.on('aborted', () => reject(failure('service', true)));
      res.on('end', () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch { reject(failure('response')); }
      });
    });
    // Absolute deadline, not an inactivity timeout; redirects are never followed.
    const timer = setTimeout(() => { reject(failure('service', true)); req.destroy(); }, Math.max(1, Math.min(15000, timeoutMs)));
    req.on('close', () => clearTimeout(timer)); req.on('error', transportFailure);
    req.end(wire);
  });
}
async function retryAPI(base, path, token, body, deadline, requestFn) {
  // Serialize once: retries cannot mint a key or mutate sanitized observations.
  const stable = body === undefined ? undefined : JSON.stringify(body);
  for (let attempt = 0; attempt < 3; attempt++) {
    if (Date.now() >= deadline) throw failure('service');
    try {
      return await api(base, path, token, stable === undefined ? undefined : JSON.parse(stable), { requestFn, timeoutMs: deadline - Date.now() });
    } catch (e) {
      const delay = Math.max(250 * (attempt + 1), e.retryAfter ?? 0);
      if (!e.retryable || attempt === 2 || Date.now() + delay >= deadline) throw e;
      await wait(delay);
    }
  }
}
async function privateDirectory(file, create = true) {
  if (typeof process.getuid !== 'function' || !constants.O_NOFOLLOW) throw Error('permissions');
  if (create) await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  const s = await lstat(dirname(file));
  if (!s.isDirectory() || s.isSymbolicLink() || s.uid !== process.getuid() || (s.mode & 0o077)) throw Error('permissions');
}
async function save(file, data) {
  await privateDirectory(file);
  const fd = await open(file, 'wx', 0o600);
  try { await fd.writeFile(JSON.stringify(data)); await fd.sync(); } finally { await fd.close(); }
}
async function loadJSON(file) {
  await privateDirectory(file, false);
  // Nonblocking open prevents a substituted FIFO from hanging diagnostics;
  // the descriptor's regular-file/owner checks remain authoritative.
  const fd = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const s = await fd.stat();
    if (!s.isFile() || s.uid !== process.getuid() || (s.mode & 0o077)) throw Error('permissions');
    if (s.size > 16384) throw Error('configuration');
    return JSON.parse(await fd.readFile('utf8'));
  } finally { await fd.close(); }
}
async function load(file) {
  const c = await loadJSON(file);
  if (!c || !credential.test(c.collectorToken) || !Number.isFinite(c.expiresAt)) throw Error('configuration');
  if (c.expiresAt <= Date.now()) throw Error('grant_expired');
  return { base: origin(c.base), collectorToken: c.collectorToken, expiresAt: c.expiresAt, accounts: accounts(c.accounts) };
}
async function loadBindings(file) {
  try { return await loadJSON(file); } catch (e) { if (e.code === 'ENOENT') return {}; throw e; }
}
const diagnostics = {
  unsupported_identity: 'Stop the worker. This CLI output lacks explicit local selection keys; public CodexBar 0.77.1 cannot discover independent account mappings. Use a separately verified adapter or remove mapped slots; labels and order are not identities.',
  ambiguous_scope: 'Stop the worker. The adapter returned duplicate local selection keys. Resolve ambiguous scopes before restarting; keys do not verify provider ownership.',
  provider_lookup: 'CodexBar provider lookup failed. Check the provider locally; private child diagnostics are withheld.',
  configuration: 'Check command syntax and private configuration. Stop the worker; if the grant is missing or malformed, revoke on the phone and remove old collector.json and accounts.json before re-pairing.',
  permissions: 'Stop the worker. Use an owned, non-symlink private directory (0700) and regular private files (0600) on POSIX; do not bypass ownership checks.',
  grant_expired: 'Stop the worker. Revoke on the phone, remove old collector.json and accounts.json, then re-pair with the trusted HTTPS origin.',
  revoked: 'Stop the worker. The grant was rejected; revoke on the phone, remove old collector.json and accounts.json, then re-pair.',
  bindings: 'Stop the worker. Map every duplicate-provider slot to a distinct confirmed local fingerprint (at most 50 slots), then restart. Failed updates preserve existing mappings.',
  unsupported_source: 'Use codex oauth, or claude/grok oauth or web; Gemini has no independent mapping. Stop the worker before changing mappings.',
  cli_availability: 'Install a working CodexBar CLI or set QUOTADOCK_CODEXBAR_BIN to its executable. Doctor checks only --version, not authentication or quota support.',
  service: 'Check connectivity and trusted server availability; no raw remote or child diagnostics are displayed.',
};
function category(e) {
  if (['EACCES', 'EPERM', 'ELOOP'].includes(e?.code)) return 'permissions';
  if (e?.code === 'ENOENT') return 'configuration';
  if (e?.message === 'unsupported_mapping') return 'bindings';
  if (e?.message === 'unsupported_slots' || e instanceof SyntaxError || e instanceof TypeError) return 'configuration';
  return Object.hasOwn(diagnostics, e?.message) ? e.message : 'service';
}
function report(e) {
  const kind = category(e);
  process.stderr.write(`QuotaDock cloud [${kind}]: ${diagnostics[kind]}\n`);
}
function sourceCheck(provider, source) {
  if (!['codex', 'claude', 'grok'].includes(provider) || !['oauth', 'web'].includes(source) || (provider === 'codex' && source !== 'oauth')) throw Error('unsupported_source');
}
function checkBindings(slots, bindings) {
  if (bindings && typeof bindings === 'object' && !Array.isArray(bindings)) {
    for (const b of Object.values(bindings)) if (b && Object.hasOwn(providers, b.provider)) sourceCheck(b.provider, b.source);
  }
  validateBindings(slots, bindings);
}
async function checkCLI() {
  await new Promise((resolve, reject) => {
    const child = spawn(process.env.QUOTADOCK_CODEXBAR_BIN || 'codexbar', ['--version'], {
      shell: false, stdio: ['ignore', 'pipe', 'pipe'], detached: process.platform !== 'win32', windowsHide: true,
    });
    let done = false, size = 0;
    const finish = ok => {
      if (done) return;
      done = true; clearTimeout(timer);
      try { if (process.platform !== 'win32' && child.pid) process.kill(-child.pid, 'SIGKILL'); else child.kill('SIGKILL'); } catch {}
      if (ok) resolve(); else reject(Error('cli_availability'));
    };
    const timer = setTimeout(() => finish(false), 2000);
    // Never retain or display child output, including purported version strings.
    for (const stream of [child.stdout, child.stderr]) stream.on('data', chunk => { size += chunk.length; if (size > 4096) finish(false); });
    child.on('error', () => finish(false));
    child.on('close', code => finish(code === 0));
  });
}
export function observations(slots, snapshot) {
  return accounts(slots).map(a => {
    if (!Array.isArray(snapshot) && slots.filter(s => s.provider === a.provider).length > 1) throw Error('unsupported_mapping');
    const candidates = Array.isArray(snapshot) ? snapshot.filter(p => p.accountId === a.id && p.id === a.provider) : snapshot.providers.filter(p => p.id === a.provider);
    if (candidates.length !== 1) throw Error('response');
    const [p] = candidates;
    return { accountId: a.id, provider: a.provider, plan: p.plan, state: p.state, source: 'codexbar', observedAt: p.observedAt, windows: p.windows.map(w => ({ id: w.id, label: w.label, remainingPercent: w.remainingPercent, resetsAt: w.resetsAt })) };
  });
}
export async function runOnce(c, { automatic = false, requestFn = request, operationTimeoutMs = 45000 } = {}) {
  if (!Number.isFinite(operationTimeoutMs) || (c.expiresAt !== undefined && !Number.isFinite(c.expiresAt))) throw Error('configuration');
  const grantExpiry = c.expiresAt ?? Infinity;
  if (Date.now() >= grantExpiry) throw Error('grant_expired');
  const deadline = Math.min(grantExpiry, Date.now() + Math.max(1, Math.min(45000, operationTimeoutMs)));
  origin(c.base);
  const call = (path, body, until = deadline) => retryAPI(c.base, path, c.collectorToken, body, Math.min(deadline, until), requestFn);
  validateBindings(c.accounts, c.bindings ?? {});
  let { job } = await call('/v2/collector/jobs/next');
  if (!job && automatic) {
    try {
      const result = await call('/v2/collector/refresh', { accountIds: c.accounts.map(a => a.id), mode: 'auto', idempotencyKey: randomUUID() });
      if (result.status === 'pending') ({ job } = await call('/v2/collector/jobs/next'));
    } catch (e) { if (e.message === 'forbidden') return; throw e; }
  }
  if (!job) return;
  const slots = accounts(job.accounts);
  const ids = Array.isArray(job.accountIds) ? job.accountIds.map(id => typeof id === 'string' ? id.toLowerCase() : null) : [];
  if (!uuid.test(job.id) || slots.some(a => !c.accounts.some(g => g.id === a.id && g.provider === a.provider)) ||
      ids.length !== slots.length || new Set(ids).size !== slots.length || ids.some(id => !slots.some(a => a.id === id))) throw Error('response');
  const issued = Date.parse(job.createdAt), expires = Date.parse(job.expiresAt);
  if (!Number.isFinite(issued) || !Number.isFinite(expires) || issued > Date.now() + 5000) throw Error('response');
  const until = Math.min(expires, deadline);
  const delay = Math.max(0, Math.floor(issued / 1000) * 1000 + 1001 - Date.now());
  if (Date.now() + delay >= until) return;
  await wait(delay);
  if (Date.now() >= until) return;
  const bindings = Object.fromEntries(slots.filter(a => c.bindings?.[a.id]).map(a => [a.id, c.bindings[a.id]]));
  const snapshot = await collectAccounts(slots, bindings, { binary: process.env.QUOTADOCK_CODEXBAR_BIN || 'codexbar', timeoutMs: Math.min(12000, until - Date.now()) });
  if (Date.now() >= until) {
    if (snapshot.compatibilityError) throw Error(snapshot.compatibilityError);
    return;
  }
  try {
    await call(`/v2/collector/refresh/${job.id}/complete`, { observations: observations(slots, snapshot) }, until);
  } finally {
    // Completion retains bounded identical-body retries, but incompatibility must
    // stop the worker even if completion fails, rather than minting more due jobs.
    if (snapshot.compatibilityError) throw Error(snapshot.compatibilityError);
  }
}
async function main() {
  const [command, ...args] = process.argv.slice(2);
  const [base] = args;
  const file = `${homedir()}/.config/quotadock-cloud/collector.json`;
  const mappingFile = `${dirname(file)}/accounts.json`;
  if (command === 'doctor') {
    if (args.length) throw Error('configuration');
    let failed = false;
    try {
      const c = await load(file);
      checkBindings(c.accounts, await loadBindings(mappingFile));
      process.stdout.write('Local grant, permissions and bindings: OK (maximum 50 slots).\n');
    } catch (e) { failed = true; report(e); }
    try { await checkCLI(); process.stdout.write('CodexBar --version: OK (output withheld).\n'); }
    catch (e) { failed = true; report(e); }
    process.stdout.write('Read-only local checks only; cloud grant validity, credentials and quota support were not tested.\n');
    if (failed) process.exitCode = 1;
    return;
  }
  if (command === 'accounts') {
    if (args.length < 1 || args.length > 2) throw Error('configuration');
    sourceCheck(args[0], args[1] ?? 'oauth');
    await checkCLI();
    const fingerprints = await listAccounts(args[0], args[1] ?? 'oauth', { binary: process.env.QUOTADOCK_CODEXBAR_BIN || 'codexbar' });
    process.stdout.write(`${JSON.stringify({ provider: args[0], source: args[1] ?? 'oauth', fingerprints })}\n`); return;
  }
  if (command === 'map') {
    if (args.length < 3 || args.length > 4) throw Error('configuration');
    const [inputID, provider, fingerprint, source = 'oauth'] = args;
    sourceCheck(provider, source);
    if (!uuid.test(inputID)) throw Error('configuration');
    const id = inputID.toLowerCase();
    const c = await load(file);
    const bindings = await loadBindings(mappingFile);
    const next = { ...bindings, [id]: { provider, fingerprint, source } };
    // Partial configuration is allowed while adding mappings; run validates all slots.
    checkBindings(c.accounts.filter(a => Object.hasOwn(next, a.id)), next);
    const temporary = `${mappingFile}.${randomUUID()}.tmp`;
    try { await save(temporary, next); await rename(temporary, mappingFile); }
    finally { await unlink(temporary).catch(e => { if (e.code !== 'ENOENT') throw e; }); }
    process.stdout.write('Local account mapping saved. Restart the collector after configuring every duplicate-provider slot.\n'); return;
  }
  if (!['pair', 'run', 'once'].includes(command) || args.length !== (command === 'pair' ? 1 : 0)) throw Error('configuration');
  if (command === 'pair') {
    const trusted = origin(base);
    // Never redeem a grant if it cannot be saved without overwriting an existing one.
    await privateDirectory(file);
    try { await lstat(file); throw Error('configuration'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    const p = await api(trusted, '/v2/collector/pair', null, {});
    if (!/^[A-F0-9]{8}$/.test(p.code) || !credential.test(p.pollingToken) || p.expiresIn !== 300) throw Error('response');
    process.stdout.write(`Approve code ${p.code} on your phone. Confirm the selected account slots explicitly.\n`);
    const deadline = Date.now() + 300000;
    while (Date.now() < deadline) {
      await wait(3000);
      const r = await api(trusted, '/v2/collector/pair', p.pollingToken);
      if (r.status === 'pending') continue;
      if (r.status !== 'approved' || !credential.test(r.collectorToken) || r.expiresIn !== 2592000) throw Error('response');
      await save(file, { base: trusted, collectorToken: r.collectorToken, expiresAt: Date.now() + r.expiresIn * 1000, accounts: accounts(r.accounts) });
      process.stdout.write('Collector paired. Provider credentials remain local.\n'); return;
    }
    throw Error('timeout');
  }
  const c = await load(file);
  c.bindings = await loadBindings(mappingFile);
  checkBindings(c.accounts, c.bindings);
  await checkCLI();
  let nextAutoAt = 0;
  do {
    if (Date.now() >= c.expiresAt) throw Error('grant_expired');
    const automatic = command === 'run' && Date.now() >= nextAutoAt;
    if (automatic) nextAutoAt = Date.now() + 20 * 60000;
    try { await runOnce(c, { automatic }); }
    catch (e) {
      if (category(e) !== 'service' || command === 'once') throw e;
      process.stderr.write(`QuotaDock cloud [service]: ${diagnostics.service} Retrying safely.\n`);
    }
    if (command === 'run') await wait(20000);
  } while (command === 'run');
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main().catch(e => {
  report(e); process.exitCode = 1;
});
