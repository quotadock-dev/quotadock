export const providers = Object.freeze({ claude: 'Claude', codex: 'Codex', gemini: 'Gemini', grok: 'Grok' });
const fallbackLabels = { claude: ['Session', 'Weekly', 'Additional'], codex: ['Session', 'Weekly', 'Additional'], gemini: ['Pro', 'Flash', 'Flash Lite'], grok: ['Credits', 'Secondary', 'Additional'] };
const date = value => typeof value === 'string' && Number.isFinite(Date.parse(value)) ? new Date(value).toISOString() : null;
// A whitelist, not redaction of arbitrary upstream text: diagnostics may contain credentials.
const plans = new Map([
  ['free', 'Free'], ['plus', 'Plus'], ['pro', 'Pro'], ['max', 'Max'], ['max 5x', 'Max 5x'],
  ['max 20x', 'Max 20x'], ['team', 'Team'], ['teams', 'Team'], ['enterprise', 'Enterprise'],
  ['standard', 'Standard'], ['google ai pro', 'Google AI Pro'], ['google ai ultra', 'Google AI Ultra'],
  ['supergrok', 'SuperGrok'], ['supergrok heavy', 'SuperGrok Heavy'], ['chatgpt plus', 'ChatGPT Plus'],
  ['chatgpt pro', 'ChatGPT Pro'], ['claude pro', 'Claude Pro'], ['claude max', 'Claude Max'],
]);
const safePlan = usage => {
  const value = usage?.identity?.loginMethod ?? usage?.loginMethod;
  return typeof value === 'string' ? plans.get(value.trim().toLowerCase()) ?? null : null;
};
const labels = new Set(['Session', 'Weekly', 'Monthly', 'Daily', 'Credits', 'Pro', 'Flash', 'Flash Lite', '5-hour', '7-day', 'Pro tier', 'Flash tier', 'Flash Lite tier']);
const safeLabel = (value, fallback) => labels.has(value) ? value : fallback;

export function normalizeProvider(id, payload) {
  const usage = payload?.usage;
  const base = { id, name: providers[id], plan: safePlan(usage), state: 'unavailable', source: 'codexbar', message: null, observedAt: date(usage?.updatedAt), windows: [] };
  if (payload?.error) return { ...base, state: 'error', message: 'Provider lookup failed. Check CodexBar locally.' };
  if (!usage || typeof usage !== 'object') return { ...base, message: 'No measured quota is available.' };
  for (const [index, key] of ['primary', 'secondary', 'tertiary'].entries()) {
    const window = usage[key];
    if (!window || typeof window !== 'object') continue;
    const known = !window.isSyntheticPlaceholder && typeof window.usedPercent === 'number' && Number.isFinite(window.usedPercent) && window.usedPercent >= 0;
    base.windows.push({ id: key, label: safeLabel(payload.rateWindowLabels?.[key], fallbackLabels[id][index]), remainingPercent: known ? Math.min(100, Math.max(0, 100 - window.usedPercent)) : null, resetsAt: date(window.resetsAt) });
  }
  if (base.windows.some(w => w.remainingPercent !== null)) base.state = 'available';
  else base.message = 'No measured quota is available.';
  return base;
}

export function snapshotFromRows(rows, now = new Date()) {
  if (!Array.isArray(rows)) throw new Error('Invalid provider response');
  return { schemaVersion: 1, generatedAt: now.toISOString(), demo: false, providers: Object.keys(providers).map(id => normalizeProvider(id, rows.find(row => row?.provider === id))) };
}

export function demoSnapshot(now = new Date()) {
  const stamp = now.toISOString();
  const reset = hours => new Date(now.getTime() + hours * 3600000).toISOString();
  const rows = [
    { provider: 'claude', usage: { loginMethod: 'Max', updatedAt: stamp, primary: { usedPercent: 28, resetsAt: reset(3) }, secondary: { usedPercent: 9, resetsAt: reset(96) } } },
    { provider: 'codex', usage: { loginMethod: 'ChatGPT Pro', updatedAt: stamp, primary: { usedPercent: 16, resetsAt: reset(2) }, secondary: { usedPercent: 37, resetsAt: reset(72) } } },
    { provider: 'gemini', usage: { loginMethod: 'Standard', updatedAt: stamp, primary: { usedPercent: 12, resetsAt: reset(12) }, secondary: { usedPercent: 4, resetsAt: reset(12) } } },
  ];
  const snapshot = snapshotFromRows(rows, now);
  snapshot.demo = true;
  for (const p of snapshot.providers) p.source = 'demo';
  return snapshot;
}
