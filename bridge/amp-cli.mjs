import { spawn } from 'node:child_process';
import { realpath, stat } from 'node:fs/promises';
import { isAbsolute } from 'node:path';

const failure = code => Object.assign(new Error(`Amp quota: ${code}`), { code });
const date = value => typeof value === 'string' && Number.isFinite(Date.parse(value)) ? new Date(value).toISOString() : null;

// Separate experimental contract: deliberately not a shared snapshot/provider entry.
export function normalizeAmpCLI(rows) {
  const base = { experimental: true, provider: 'amp', source: 'cli', state: 'unsupported', observedAt: null, windows: [] };
  if (!Array.isArray(rows) || rows.length !== 1 || rows[0]?.provider !== 'amp') return base;
  const row = rows[0];
  if (row.error) return { ...base, state: 'error' };
  if (row.source !== 'cli' || !row.usage || typeof row.usage !== 'object') return base;
  const usage = row.usage;
  base.observedAt = date(usage.updatedAt);
  const add = (id, label, window) => {
    if (!window || typeof window !== 'object') return;
    const percent = window.usedPercent;
    const known = !window.isSyntheticPlaceholder && typeof percent === 'number' && Number.isFinite(percent) && percent >= 0 && percent <= 100;
    base.windows.push({ id, label, remainingPercent: known ? 100 - percent : null, resetsAt: date(window.resetsAt) });
  };
  // Older "Other usage" is not silently relabelled as Agent.
  if (row.rateWindowLabels?.primary === 'Agent usage') add('agent', 'Agent', usage.primary);
  else if ((usage.identity?.loginMethod ?? usage.loginMethod) === 'Amp Free' && !usage.secondary) add('free', 'Free', usage.primary);
  if (row.rateWindowLabels?.secondary === 'Orb usage') add('orb', 'Orb', usage.secondary);
  const free = Array.isArray(usage.extraRateWindows) ? usage.extraRateWindows.filter(w => w?.id === 'amp-free') : [];
  if (free.length === 1 && !base.windows.some(w => w.id === 'free')) add('free', 'Free', free[0].window);
  if (base.windows.length) base.state = base.windows.some(w => w.remainingPercent !== null) ? 'available' : 'unavailable';
  return base;
}

/** Trusted local opt-in only. home is an explicitly provisioned isolated CLI profile,
 * not a verified account identity. Never use this result for account-slot binding. */
export async function readAmpQuota({ executable, home, path, timeoutMs = 12000 } = {}) {
  if (![executable, home].every(v => typeof v === 'string' && isAbsolute(v)) || typeof path !== 'string' || !path.split(':').every(p => isAbsolute(p))) throw failure('invalid_scope');
  if (!Number.isInteger(timeoutMs) || timeoutMs < 50 || timeoutMs > 30000) throw failure('invalid_deadline');
  const resolved = await realpath(home).catch(() => null);
  const info = resolved && await stat(resolved).catch(() => null);
  if (resolved !== home || !info?.isDirectory() || info.uid !== process.getuid?.() || (info.mode & 0o077)) throw failure('invalid_scope');
  return new Promise((resolve, reject) => {
    const child = spawn(executable, ['usage', '--provider', 'amp', '--source', 'cli', '--format', 'json', '--json-only'], {
      cwd: home, env: { HOME: home, XDG_CONFIG_HOME: `${home}/.config`, XDG_CACHE_HOME: `${home}/.cache`, PATH: path, NO_COLOR: '1' },
      stdio: ['ignore', 'pipe', 'ignore'], detached: process.platform !== 'win32', windowsHide: true,
    });
    let done = false, size = 0;
    const chunks = [];
    const finish = (code, result) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { if (process.platform !== 'win32') process.kill(-child.pid, 'SIGKILL'); else child.kill('SIGKILL'); } catch {}
      if (code) reject(failure(code)); else resolve(result);
    };
    const timer = setTimeout(() => finish('deadline'), timeoutMs);
    child.on('error', () => finish('child_failed'));
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size > 1048576) finish('output_limit');
      else if (!done) chunks.push(chunk);
    });
    child.on('close', code => {
      if (done) return;
      if (code !== 0) return finish('provider_failed');
      try { finish(null, normalizeAmpCLI(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))))); }
      catch { finish('invalid_json'); }
    });
  });
}
