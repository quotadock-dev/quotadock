export const names = { claude: 'Claude', codex: 'Codex', gemini: 'Gemini', grok: 'Grok' };
export type ProviderId = keyof typeof names;
export interface QuotaWindow { readonly label: string; readonly remainingPercent: number | null; readonly resetsAt: string | null }
export interface Provider { readonly id: ProviderId; readonly state: 'available' | 'unavailable' | 'error'; readonly source: 'codexbar' | 'demo'; readonly plan: string | null; readonly observedAt: string | null; readonly windows: readonly QuotaWindow[] }
export interface Snapshot { readonly schemaVersion: 1; readonly demo: boolean; readonly generatedAt: string; readonly providers: readonly Provider[] }
export interface Pairing { readonly endpoint: string; readonly token: string }
export const safeEndpoint = (url: URL) => url.origin === location.origin && !url.username && !url.password && !url.search && !url.hash && ['', '/'].includes(url.pathname) && (url.protocol === 'https:' || (url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)));
const object = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === 'object' && !Array.isArray(v);
const timestamp = (v: unknown): v is string => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(v) && Number.isFinite(Date.parse(v)) && new Date(v).toISOString() === v;
const nullableDate = (v: unknown): v is string | null => v === null || timestamp(v);
const shortText = (v: unknown): v is string => typeof v === 'string' && v.length > 0 && v.length <= 80;
const providerId = (v: unknown): v is ProviderId => v === 'claude' || v === 'codex' || v === 'gemini' || v === 'grok';
const plans = new Set(['Free','Plus','Pro','Max','Max 5x','Max 20x','Team','Enterprise','Standard','Google AI Pro','Google AI Ultra','SuperGrok','SuperGrok Heavy','ChatGPT Plus','ChatGPT Pro','Claude Pro','Claude Max']);
const labels = new Set(['Session','Weekly','Monthly','Daily','Credits','Pro','Flash','Flash Lite','5-hour','7-day','Pro tier','Flash tier','Flash Lite tier','Secondary','Additional']);
export function parseSnapshot(s: unknown): Snapshot {
  if (!object(s) || s.schemaVersion !== 1 || typeof s.demo !== 'boolean' || !timestamp(s.generatedAt) || !Array.isArray(s.providers) || s.providers.length > 4) throw new Error('schema');
  const ids = new Set<ProviderId>();
  const providers = s.providers.map((p: unknown): Provider => {
    if (!object(p) || !providerId(p.id) || ids.has(p.id) || (p.state !== 'available' && p.state !== 'unavailable' && p.state !== 'error') || (p.source !== 'codexbar' && p.source !== 'demo') || !(p.plan === null || shortText(p.plan)) || !nullableDate(p.observedAt) || !Array.isArray(p.windows) || p.windows.length > 3) throw new Error('schema');
    ids.add(p.id);
    const seen = new Set<string>();
    const windows = p.windows.map((w: unknown): QuotaWindow => {
      if (!object(w) || !shortText(w.label) || seen.has(w.label) || !(w.remainingPercent === null || (typeof w.remainingPercent === 'number' && Number.isFinite(w.remainingPercent))) || !nullableDate(w.resetsAt)) throw new Error('schema');
      seen.add(w.label);
      return Object.freeze({ label: labels.has(w.label) ? w.label : '사용량', remainingPercent: p.state === 'available' ? w.remainingPercent : null, resetsAt: w.resetsAt });
    });
    return Object.freeze({ id: p.id, state: p.state, source: p.source, plan: p.plan !== null && plans.has(p.plan) ? p.plan : null, observedAt: p.observedAt, windows: Object.freeze(windows) });
  });
  return Object.freeze({ schemaVersion: 1, demo: s.demo, generatedAt: s.generatedAt, providers: Object.freeze(providers) });
}
export class BridgeHTTPError extends Error {
  constructor(readonly status: number) { super('Bridge request failed'); }
}
export async function fetchSnapshot(pair: Pairing, signal: AbortSignal): Promise<Snapshot> {
  if (!safeEndpoint(new URL(pair.endpoint)) || !/^[a-f0-9]{64}$/.test(pair.token)) throw new Error('pairing');
  const response = await fetch(`${pair.endpoint}/v1/snapshot`, { headers: { Authorization: `Bearer ${pair.token}` }, cache: 'no-store', credentials: 'omit', redirect: 'error', signal });
  if (response.status !== 200) {
    // Error bodies can contain diagnostics or an unbounded stream. Never read them.
    void response.body?.cancel().catch(() => {});
    throw new BridgeHTTPError(response.status);
  }
  if (!response.body) throw new Error('request');
  const reader = response.body.getReader();
  const cancel = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener('abort', cancel, { once: true });
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let size = 0, body = '', complete = false;
  try {
    while (true) {
      if (signal.aborted) throw new Error('aborted');
      const { done, value } = await reader.read();
      if (signal.aborted) throw new Error('aborted');
      if (done) break;
      size += value.byteLength;
      if (size > 262144) throw new Error('size');
      body += decoder.decode(value, { stream: true });
    }
    body += decoder.decode(); complete = true;
    return parseSnapshot(JSON.parse(body));
  } finally { signal.removeEventListener('abort', cancel); if (!complete) cancel(); reader.releaseLock(); }
}
export function demoSnapshot(): Snapshot {
  const now = Date.now(), observedAt = new Date(now).toISOString();
  const window = (label: string, remainingPercent: number, hours: number): QuotaWindow => ({ label, remainingPercent, resetsAt: new Date(now + hours * 3600000).toISOString() });
  const snapshot: Snapshot = { schemaVersion: 1, demo: true, generatedAt: observedAt, providers: [
    { id: 'claude', plan: 'Max', state: 'available', source: 'demo', observedAt, windows: [window('Session',72,3),window('Weekly',91,96)] },
    { id: 'codex', plan: 'ChatGPT Pro', state: 'available', source: 'demo', observedAt, windows: [window('5-hour',84,2),window('Weekly',63,72)] },
    { id: 'gemini', plan: 'Standard', state: 'available', source: 'demo', observedAt, windows: [window('Pro model tier',88,12),window('Flash model tier',96,12)] },
    { id: 'grok', plan: null, state: 'unavailable', source: 'demo', observedAt: null, windows: [{ label: '사용량', remainingPercent: null, resetsAt: null }] }
  ] };
  for (const provider of snapshot.providers) {
    provider.windows.forEach(Object.freeze);
    Object.freeze(provider.windows);
    Object.freeze(provider);
  }
  Object.freeze(snapshot.providers);
  return Object.freeze(snapshot);
}
