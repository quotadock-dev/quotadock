import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { providers, snapshotFromRows, normalizeProvider } from './snapshot.mjs';

// Never run a shell or accept provider commands over HTTP. Upstream logs stay private.
function query(binary, id, timeoutMs, source = null) {
  return new Promise(resolve => {
    let chunks = [], size = 0, completed = false;
    const args = ['usage', '--provider', id, '--format', 'json', '--json-only'];
    if (source) args.push('--all-accounts', '--source', source);
    const child = spawn(binary, args, { stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true, detached: process.platform !== 'win32' });
    const failed = () => [{ provider: id, error: { kind: 'provider' } }];
    const stop = () => {
      try { if (process.platform !== 'win32') process.kill(-child.pid, 'SIGKILL'); else child.kill('SIGKILL'); } catch {}
    };
    const finish = rows => { if (!completed) { completed = true; clearTimeout(timer); resolve(rows); } };
    const timer = setTimeout(() => { stop(); finish(failed()); }, timeoutMs);
    child.on('error', () => finish(failed()));
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size > 1024 * 1024) { stop(); finish(failed()); } else chunks.push(chunk);
    });
    child.on('close', () => {
      if (completed) return;
      try {
        // Some providers fail independently and still emit usable JSON with nonzero exit.
        const rows = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        finish(Array.isArray(rows) && (rows.length === 0 || rows.some(row => row?.provider === id)) ? rows.filter(row => row?.provider === id) : failed());
      } catch { finish(failed()); }
    });
  });
}

export async function collect({ binary = 'codexbar', timeoutMs = 12000 } = {}) {
  const rows = (await Promise.all(Object.keys(providers).map(id => query(binary, id, timeoutMs)))).flat();
  return snapshotFromRows(rows);
}

// Explicit adapter keys are unverified local selection scopes, not provider-owner
// identities: replacing credentials can change the owner behind the same key.
// Public CodexBar 0.77.1 omits cacheAccountKey from ProviderPayload.CodingKeys.
// Keys can contain upstream email/workspace identifiers. Only opaque hashes stay
// in local mapping files; neither raw keys nor hashes are uploaded in observations.
export function accountFingerprint(provider, key) {
  if (!Object.hasOwn(providers, provider) || typeof key !== 'string' || !key.length || key.length > 1024) return null;
  return createHash('sha256').update(`${provider}\0${key}`).digest('hex');
}
function accountSource(provider, source) {
  if (!['claude', 'codex', 'grok'].includes(provider) || !['oauth', 'web'].includes(source) || (provider === 'codex' && source !== 'oauth')) throw Error('unsupported_mapping');
}
export async function listAccounts(provider, source = 'oauth', { binary = 'codexbar', timeoutMs = 12000 } = {}) {
  accountSource(provider, source);
  const rows = await query(binary, provider, timeoutMs, source);
  const problem = scopeProblem(provider, rows);
  if (problem) throw Error(problem);
  if (rows.some(r => r.error)) throw Error('provider_lookup');
  const keys = rows.map(r => accountFingerprint(provider, r.cacheAccountKey)).filter(Boolean);
  return keys;
}
function scopeProblem(provider, rows) {
  if (rows.some(r => !r.error && !accountFingerprint(provider, r.cacheAccountKey))) return 'unsupported_identity';
  const keys = rows.map(r => accountFingerprint(provider, r.cacheAccountKey)).filter(Boolean);
  return new Set(keys).size !== keys.length ? 'ambiguous_scope' : null;
}
export function validateBindings(slots, bindings) {
  if (!bindings || typeof bindings !== 'object' || Array.isArray(bindings) || Object.keys(bindings).length > 50) throw Error('unsupported_mapping');
  const seen = new Set();
  for (const [id, b] of Object.entries(bindings)) {
    const slot = slots.find(a => a.id === id);
    if (!slot || !b || Object.keys(b).sort().join(',') !== 'fingerprint,provider,source' || b.provider !== slot.provider || !/^[a-f0-9]{64}$/.test(b.fingerprint)) throw Error('unsupported_mapping');
    accountSource(b.provider, b.source);
    const key = `${b.provider}:${b.fingerprint}`;
    if (seen.has(key)) throw Error('unsupported_mapping');
    seen.add(key);
  }
  for (const slot of slots) {
    const duplicates = slots.filter(a => a.provider === slot.provider).length > 1;
    if (duplicates && (slot.provider === 'gemini' || !bindings[slot.id])) throw Error('unsupported_mapping');
  }
}
export async function collectAccounts(slots, bindings, { binary = 'codexbar', timeoutMs = 12000 } = {}) {
  validateBindings(slots, bindings);
  const groups = new Map();
  for (const slot of slots) {
    const source = bindings[slot.id]?.source ?? null;
    groups.set(`${slot.provider}:${source}`, { provider: slot.provider, source });
  }
  const rows = new Map(await Promise.all([...groups].map(async ([key, { provider, source }]) => [key, await query(binary, provider, timeoutMs, source)])));
  const compatibilityError = [...groups].filter(([, g]) => g.source).map(([key, g]) => scopeProblem(g.provider, rows.get(key))).find(Boolean);
  const result = slots.map(slot => {
    const binding = bindings[slot.id];
    const group = rows.get(`${slot.provider}:${binding?.source ?? null}`);
    const candidates = binding && scopeProblem(slot.provider, group) ? [] : group.filter(row => !binding || accountFingerprint(slot.provider, row.cacheAccountKey) === binding.fingerprint);
    // No positional, label or ambient-account fallback for a missing/ambiguous key.
    const payload = candidates.length === 1 ? candidates[0] : { error: { kind: 'account' } };
    return { accountId: slot.id, ...normalizeProvider(slot.provider, payload) };
  });
  // Local-only signal: complete outstanding jobs with sanitized errors before stopping.
  Object.defineProperty(result, 'compatibilityError', { value: compatibilityError });
  return result;
}

export function cachedCollector(load, { ttlMs = 60000, now = () => performance.now() } = {}) {
  let last = null, loadedAt = 0, pending = null;
  return async () => {
    if (last && now() - loadedAt < ttlMs) return last;
    if (!pending) pending = Promise.resolve().then(load).then(snapshot => { last = snapshot; loadedAt = now(); return snapshot; }).finally(() => { pending = null; });
    return pending;
  };
}
