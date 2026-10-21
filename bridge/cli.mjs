import { mkdir, open, lstat, readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { randomBytes } from 'node:crypto';
import { collect, cachedCollector } from './collector.mjs';
import { demoSnapshot } from './snapshot.mjs';
import { createBridge } from './server.mjs';
import { formatStatus } from './status.mjs';

const file = resolve(process.env.QUOTADOCK_TOKEN_FILE || `${homedir()}/.config/quotadock/token`);
async function initToken() {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  try {
    const fd = await open(file, 'wx', 0o600);
    try { await fd.writeFile(`${randomBytes(32).toString('hex')}\n`); } finally { await fd.close(); }
    process.stdout.write(`Pairing token created at ${file}. Transfer privately; do not paste into issues.\n`);
  } catch (error) { if (error.code === 'EEXIST') process.stdout.write('Token already exists; not replaced.\n'); else throw error; }
}
async function readToken() {
  const stat = await lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) || stat.uid !== process.getuid?.() || stat.size > 128) throw new Error('Token file must be owned by you, regular, and mode 0600.');
  const token = (await readFile(file, 'utf8')).trim();
  if (!/^[a-f0-9]{64}$/.test(token)) throw new Error('Invalid token file.');
  return token;
}
async function main() {
  const [command, ...flags] = process.argv.slice(2);
  const text = flags.includes('--text');
  const languages = flags.filter(flag => flag.startsWith('--language='));
  if (!['init', 'status', 'serve'].includes(command)
    || flags.some(flag => !['--demo', '--text', '--language=en', '--language=ko'].includes(flag))
    || (command === 'init' && flags.length)
    || (command !== 'status' && (text || languages.length))
    || (languages.length && !text) || languages.length > 1) {
    throw new Error('Usage: node bridge/cli.mjs init | status [--demo] [--text [--language=en|ko]] | serve [--demo]');
  }
  if (command === 'init') return initToken();
  const demo = flags.includes('--demo');
  const getSnapshot = cachedCollector(demo ? async () => demoSnapshot() : () => collect({ binary: process.env.QUOTADOCK_CODEXBAR_BIN || 'codexbar' }));
  if (command === 'status') {
    const snapshot = await getSnapshot();
    process.stdout.write(text ? formatStatus(snapshot, { language: languages[0]?.slice('--language='.length) ?? 'en' }) : `${JSON.stringify(snapshot, null, 2)}\n`);
    return;
  }
  const host = process.env.QUOTADOCK_HOST || '127.0.0.1';
  const port = Number(process.env.QUOTADOCK_PORT || 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port.');
  const cert = process.env.QUOTADOCK_TLS_CERT, key = process.env.QUOTADOCK_TLS_KEY;
  if (!!cert !== !!key) throw new Error('Set both TLS certificate and key paths.');
  const tls = cert ? { cert: await readFile(cert), key: await readFile(key) } : null;
  const poll = process.env.QUOTADOCK_POLL_SECONDS ? Number(process.env.QUOTADOCK_POLL_SECONDS) : null;
  if (poll !== null && (!Number.isInteger(poll) || poll < 60 || poll > 86400)) throw new Error('Polling must be between 60 and 86400 seconds.');
  const server = await createBridge({ host, token: await readToken(), tls, getSnapshot });
  await new Promise((ok, fail) => { server.once('error', fail); server.listen(port, host, ok); });
  process.stdout.write(`QuotaDock ${demo ? 'DEMO ' : ''}listening on ${tls ? 'https' : 'http'}://${host}:${port}. No credentials are logged.\n`);
  let timer;
  if (poll) { void getSnapshot().catch(() => {}); timer = setInterval(() => void getSnapshot().catch(() => {}), poll * 1000); }
  const stop = () => { clearInterval(timer); server.close(); };
  process.on('SIGINT', stop); process.on('SIGTERM', stop);
}
main().catch(error => {
  // Never print child output, tokens, TLS contents, or full Node error objects.
  process.stderr.write(`QuotaDock: ${['ENOENT', 'EACCES'].includes(error.code) ? 'Required local file/binary is missing or inaccessible; run init and check configuration.' : error.message}\n`);
  process.exitCode = 1;
});
