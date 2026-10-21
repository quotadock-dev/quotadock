import http from 'node:http';
import https from 'node:https';
import { readFile } from 'node:fs/promises';
import { timingSafeEqual } from 'node:crypto';

const files = { '/': ['index.html', 'text/html; charset=utf-8'], '/index.html': ['index.html', 'text/html; charset=utf-8'], '/app.js': ['app.js', 'text/javascript; charset=utf-8'], '/style.css': ['style.css', 'text/css; charset=utf-8'] };
files['/favicon.svg'] = ['favicon.svg', 'image/svg+xml'];
files['/chevron-down.svg'] = ['chevron-down.svg', 'image/svg+xml'];
for (const id of ['claude', 'codex', 'gemini', 'grok']) files[`/icons/${id}.svg`] = [`icons/${id}.svg`, 'image/svg+xml'];
const loopback = host => ['127.0.0.1', '::1', 'localhost'].includes(host);

export async function createBridge({ host = '127.0.0.1', token, getSnapshot, tls = null }) {
  if (!loopback(host) && !tls) throw new Error('Non-loopback binding requires TLS.');
  if (typeof token !== 'string' || !/^[a-f0-9]{64}$/.test(token)) throw new Error('Invalid pairing token.');
  const secret = Buffer.from(`Bearer ${token}`);
  const buckets = new Map();
  // Fixed build filenames only: never expose source modules or arbitrary filesystem paths.
  // Loading is deferred until serving, so collector-only imports need no frontend build.
  const staticFiles = new Map(await Promise.all(Object.entries(files).map(async ([url, [file, type]]) => [url, { body: await readFile(new URL(`../web-dist/${file}`, import.meta.url)), type }])));
  const handler = async (req, res) => {
    const headers = {
      'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
      'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
      'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
    };
    const reply = (code, body, type = 'application/json; charset=utf-8') => { res.writeHead(code, { ...headers, 'Content-Type': type }); res.end(body); };
    // Prevent browser DNS-rebinding / cross-origin reads. Native clients have no Origin.
    const authority = req.headers.host;
    let hostName;
    try { hostName = new URL(`http://${authority}`).hostname.replace(/^\[|\]$/g, ''); } catch { reply(400, '{"error":"bad_host"}'); return; }
    if (!authority || (loopback(host) && !loopback(hostName)) || (req.headers.origin && req.headers.origin !== `${tls ? 'https' : 'http'}://${authority}`)) { reply(403, '{"error":"origin_rejected"}'); return; }
    if (req.method !== 'GET') { reply(405, '{"error":"method_not_allowed"}'); return; }
    const url = req.url?.split('?')[0];
    if (url === '/healthz') { reply(200, '{"ok":true}'); return; }
    if (url === '/v1/snapshot') {
      const address = req.socket.remoteAddress;
      const auth = Buffer.from(req.headers.authorization || '');
      const authorized = auth.length === secret.length && timingSafeEqual(auth, secret);
      const now = Date.now();
      if (buckets.size >= 2048) for (const [key, value] of buckets) if (now - value.at > 60000) buckets.delete(key);
      let bucket = buckets.get(address);
      if (!bucket || now - bucket.at >= 60000) { bucket = { at: now, authorized: 0, rejected: 0 }; if (buckets.size >= 2048) { reply(429, '{"error":"rate_limited"}'); return; } buckets.set(address, bucket); }
      // Failed authentication must not spend a paired client's refresh allowance.
      if (++bucket[authorized ? 'authorized' : 'rejected'] > 30) { reply(429, '{"error":"rate_limited"}'); return; }
      if (!authorized) { reply(401, '{"error":"unauthorized"}'); return; }
      try {
        const body = JSON.stringify(await getSnapshot());
        if (Buffer.byteLength(body) > 262144) throw new Error('Oversized snapshot');
        reply(200, body);
      } catch { reply(503, '{"error":"snapshot_unavailable"}'); }
      return;
    }
    const file = staticFiles.get(url);
    if (!file) { reply(404, '{"error":"not_found"}'); return; }
    reply(200, file.body, file.type);
  };
  const server = tls ? https.createServer({ ...tls, minVersion: 'TLSv1.2' }, handler) : http.createServer(handler);
  server.requestTimeout = 20000;
  server.headersTimeout = 10000;
  server.maxRequestsPerSocket = 100;
  return server;
}
