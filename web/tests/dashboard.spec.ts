import { test, expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
const secret = 'a'.repeat(64);
test.use({ locale: 'ko-KR' });
const snapshot = () => ({ schemaVersion: 1, demo: false, generatedAt: '2026-01-01T00:00:00.000Z', providers: [{ id: 'claude', plan: 'Max', source: 'codexbar', state: 'available', observedAt: new Date().toISOString(), windows: [{ label: 'Session', remainingPercent: 42, resetsAt: null }] }] });
async function pair(page: Page) {
  if (!await page.locator('#token').isVisible()) await page.locator('#settings-toggle').click();
  await page.locator('#token').fill(secret); await page.getByRole('button', { name: '연결하기' }).click();
}
test('safe bearer pairing; malformed, oversized and rejected fetch retains original cache; disconnect focus', async ({ page }) => {
  let body: unknown = snapshot(), rejected = false;
  await page.route('**/v1/snapshot', async route => {
    expect(route.request().url()).toBe('http://127.0.0.1:4317/v1/snapshot'); expect(route.request().headers().authorization).toBe(`Bearer ${secret}`);
    if (rejected) await route.abort(); else await route.fulfill({ json: body });
  });
  await page.goto('/'); await expect(page.locator('#endpoint')).toBeHidden();
  await page.locator('#settings-toggle').focus(); await page.keyboard.press('Enter');
  await expect(page.locator('#endpoint')).toBeFocused();
  await pair(page); await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  await expect(page.locator('#endpoint')).toBeHidden(); await expect(page.locator('#settings-toggle')).toBeFocused();
  const updated = await page.locator('#updated').textContent(); await expect(page.locator('#token')).toHaveValue('');
  expect(await page.evaluate(() => sessionStorage.getItem('quotadock.token'))).toBe(secret); expect(await page.evaluate(() => localStorage.length)).toBe(0);
  for (const invalid of [{}, { ...snapshot(), providers: [snapshot().providers[0], snapshot().providers[0]] }, { ...snapshot(), generatedAt: '2026-02-30T00:00:00.000Z' }, '가'.repeat(90000)]) {
    body = invalid; await page.locator('#refresh').click(); await expect(page.locator('#status')).toContainText('연결 오류');
    await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42'); await expect(page.locator('.provider').first()).toContainText('STALE'); expect(await page.locator('#updated').textContent()).toBe(updated);
  }
  rejected = true; await page.locator('#refresh').click(); await expect(page.locator('#status')).toContainText('연결 오류');
  await page.locator('#disconnect').click(); await expect(page.locator('#endpoint')).toBeFocused(); await expect(page.locator('#mode')).toHaveText('연결되지 않음'); await expect(page.getByRole('progressbar')).toHaveCount(0); expect(await page.evaluate(() => sessionStorage.length)).toBe(0);
});
test('HTTP failures give fixed bilingual recovery actions without exposing bodies or replacing observations', async ({ page }) => {
  let status = 200;
  await page.route('**/v1/snapshot', route => route.fulfill({ status, body: status === 200 || status === 201 ? JSON.stringify(snapshot()) : 'private diagnostic <script>alert(1)</script> account@example.test', contentType: 'application/json' }));
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/'); await pair(page); await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  await page.locator('#auto-refresh').uncheck();
  const observed = await page.locator('#updated').textContent();
  const cases = [
    { code: 401, ko: '페어링이 거부됐습니다. 토큰을 확인해 주세요.', en: 'Pairing refused. Check your token.' },
    { code: 403, ko: '브리지 접근이 차단됐습니다. 접근 설정을 확인해 주세요.', en: 'Bridge access blocked. Check access settings.' },
    { code: 429, ko: '요청이 많습니다. 잠시 후 다시 확인해 주세요.', en: 'Too many requests. Try again shortly.' },
    { code: 503, ko: '사용량 수집에 실패했습니다. 로컬 수집기를 확인해 주세요.', en: 'Could not collect usage. Check your local collector.' },
  ];
  for (const scenario of cases) {
    status = scenario.code; await page.locator('#refresh').click();
    await expect(page.locator('#connection-message')).toHaveText(scenario.ko);
    await expect(page.locator('#connection-message')).toBeVisible(); await expect(page.locator('#endpoint')).toBeHidden();
    await expect(page.locator('#status')).toContainText('연결 오류');
    expect(await page.locator('#updated').textContent()).toBe(observed);
    await page.locator('header select').selectOption('en');
    await expect(page.locator('#connection-message')).toHaveText(scenario.en);
    await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
    await expect(page.locator('#refresh')).toBeEnabled();
    await expect(page.locator('body')).not.toContainText('private diagnostic');
    await expect(page.locator('body')).not.toContainText('account@example.test');
    if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: `.amp/in/artifacts/bridge-http-${status}-en.png`, fullPage: true });
    await page.locator('header select').selectOption('ko');
    if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: `.amp/in/artifacts/bridge-http-${status}-ko.png`, fullPage: true });
  }
  for (status of [201, 500]) {
    await page.locator('#refresh').click(); await expect(page.locator('#status')).toContainText('연결 오류');
    await expect(page.locator('#connection-message')).toContainText('주소, 토큰과 HTTPS 설정');
    await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  }
  status = 200; await page.locator('#refresh').click();
  await expect(page.locator('#status')).toHaveText('남은 사용량을 확인했어요');
  await expect(page.locator('#connection-message')).toBeEmpty();
});
test('an endless HTTP error body stops downloading when recovery is shown', async ({ page }) => {
  // Serve the real built UI behind a deliberately broken local proxy. An error
  // body never ends, so merely showing an error must not leave it downloading.
  const files = new Map(await Promise.all([
    ['/', 'index.html', 'text/html'], ['/app.js', 'app.js', 'text/javascript'], ['/style.css', 'style.css', 'text/css'],
  ].map(async ([path, file, type]) => [path, { type, body: await readFile(new URL(`../../web-dist/${file}`, import.meta.url)) }] as const)));
  let closed = false;
  const server = createServer((request, response) => {
    if (request.url === '/v1/snapshot') {
      response.writeHead(403, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' }); response.flushHeaders();
      const timer = setInterval(() => { if (!response.writableNeedDrain) response.write('private diagnostic'.repeat(512)); }, 20);
      response.once('close', () => { clearInterval(timer); closed = true; });
      return;
    }
    const file = files.get(request.url || '');
    response.writeHead(file ? 200 : 404, { 'Content-Type': file?.type || 'text/plain' }); response.end(file?.body);
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const address = server.address(); if (!address || typeof address === 'string') throw new Error('Missing test listener');
    await page.goto(`http://127.0.0.1:${address.port}`); await pair(page);
    await expect(page.locator('#connection-message')).toContainText('브리지 접근이 차단됐습니다.');
    await expect(page.locator('#refresh')).toBeEnabled();
    await expect.poll(() => closed, { timeout: 3000 }).toBe(true);
    await expect(page.locator('body')).not.toContainText('private diagnostic');
  } finally {
    server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve()));
  }
});
test('memory-only pairing warning survives reads and language changes until disconnect or a successful save', async ({ page }) => {
  let rejected = false;
  await page.route('**/v1/snapshot', route => rejected ? route.abort() : route.fulfill({ json: snapshot() }));
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/');
  // An older saved token must not survive a failed replacement's partial write.
  await page.evaluate(() => { sessionStorage.setItem('quotadock.endpoint', location.origin); sessionStorage.setItem('quotadock.token', 'c'.repeat(64)); });
  const restoreWrites = await page.evaluateHandle(() => {
    const original = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      if (this === sessionStorage && key === 'quotadock.token') throw new DOMException('Quota exceeded', 'QuotaExceededError');
      return original.call(this, key, value);
    };
    return () => { Storage.prototype.setItem = original; };
  });
  const koreanWarning = page.getByText('세션 저장이 차단되어 이 페이지에서만 연결을 유지합니다.', { exact: true });
  const englishWarning = page.getByText('Session storage is blocked; pairing lasts only on this page.', { exact: true });
  await pair(page); await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  await expect(koreanWarning).toBeVisible();
  expect(await page.evaluate(() => [sessionStorage.getItem('quotadock.endpoint'), sessionStorage.getItem('quotadock.token')])).toEqual([null, null]);
  await page.locator('header select').selectOption('en'); await expect(englishWarning).toBeVisible();
  if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: '.amp/in/artifacts/pairing-storage-en-memory-only.png', fullPage: true });
  rejected = true; await page.locator('#refresh').click(); await expect(page.locator('#status')).toContainText('Connection error');
  await expect(englishWarning).toBeVisible(); await expect(page.locator('#connection-message')).toContainText('Check');
  await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  await page.locator('header select').selectOption('ko'); await expect(koreanWarning).toBeVisible();
  if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: '.amp/in/artifacts/pairing-storage-ko-network-error.png', fullPage: true });
  await page.locator('#disconnect').click(); await expect(koreanWarning).toBeHidden();
  rejected = false; await pair(page); await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  await expect(koreanWarning).toBeVisible();
  await restoreWrites.evaluate(restore => restore());
  await pair(page); await expect(koreanWarning).toBeHidden();
  expect(await page.evaluate(() => sessionStorage.getItem('quotadock.token'))).toBe(secret);
  await expect(page.locator('body')).not.toContainText(secret);
  await page.evaluate(() => { Storage.prototype.removeItem = () => { throw new DOMException('Denied', 'SecurityError'); }; });
  await page.locator('#disconnect').click();
  await expect(page.locator('#mode')).toHaveText('연결되지 않음'); await expect(page.getByRole('progressbar')).toHaveCount(0);
  await expect(page.getByText('저장된 연결을 지우지 못했습니다. 현재 페이지의 변경만 적용되며, 다시 열면 이전 연결이 복원될 수 있습니다.', { exact: true })).toBeVisible();
  if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: '.amp/in/artifacts/pairing-storage-ko-clear-blocked.png', fullPage: true });
  await page.locator('header select').selectOption('en');
  await expect(page.getByText('Could not remove the saved pairing. Changes apply only on this page; reopening it may restore the previous pairing.', { exact: true })).toBeVisible();
  if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: '.amp/in/artifacts/pairing-storage-en-clear-blocked.png', fullPage: true });
});
test('cross-origin, userinfo, path, query and fragment rejected before bearer sends', async ({ page }) => {
  let calls = 0; page.on('request', r => { if (r.headers().authorization) calls++; }); await page.goto('/');
  await page.locator('#settings-toggle').click();
  for (const endpoint of ['https://other.invalid', 'http://other.invalid', 'http://user@127.0.0.1:4317', 'http://127.0.0.1:4317/path', 'http://127.0.0.1:4317/?q=1', 'http://127.0.0.1:4317/#x']) {
    await page.locator('#endpoint').fill(endpoint); await pair(page); await expect(page.locator('#pairing-message')).toContainText('같은 브리지');
    await expect(page.locator('#pairing-message')).toBeVisible(); await expect(page.locator('#endpoint')).toBeVisible();
  } expect(calls).toBe(0);
});
test('stale/unknown and private vocabulary never become measured zero', async ({ page }) => {
  const s = snapshot(); s.providers[0].observedAt = '2026-01-01T00:00:00.000Z';
  await page.route('**/v1/snapshot', r => r.fulfill({ json: s })); await page.goto('/'); await pair(page); await expect(page.locator('.provider').first()).toContainText('STALE');
  await page.unroute('**/v1/snapshot'); await page.route('**/v1/snapshot', r => r.fulfill({ json: { ...s, providers: [{ ...s.providers[0], plan: 'private@example.test', state: 'error', windows: [{ label: 'private diagnostic', remainingPercent: 99, resetsAt: null }] }] } }));
  await page.locator('#refresh').click(); await expect(page.getByRole('progressbar')).toHaveCount(0); await expect(page.locator('#providers')).not.toContainText('private'); await expect(page.locator('.provider').first()).toContainText('알 수 없음');
});
test('disconnect cancels late response and reconnect isolates generations', async ({ page }) => {
  let release: (() => void) | undefined;
  await page.route('**/v1/snapshot', async r => { await new Promise<void>(resolve => { release = resolve; }); await r.fulfill({ json: snapshot() }).catch(() => {}); });
  await page.goto('/'); await pair(page); await expect(page.locator('#refresh')).toBeDisabled(); await page.locator('#disconnect').click(); release?.();
  await expect(page.locator('#mode')).toHaveText('연결되지 않음'); await expect(page.getByRole('progressbar')).toHaveCount(0);
  await page.unroute('**/v1/snapshot'); await page.route('**/v1/snapshot', r => r.fulfill({ json: snapshot() })); await pair(page); await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
});
test('60s checks, manual-only setting and keyboard focus', async ({ page }) => {
  await page.clock.install(); let calls = 0; await page.route('**/v1/snapshot', r => { calls++; return r.fulfill({ json: snapshot() }); });
  await page.goto('/'); await pair(page); await expect(page.locator('#refresh')).toBeEnabled(); await page.clock.fastForward(60000); await expect.poll(() => calls).toBe(2);
  await page.locator('#auto-refresh').uncheck(); await page.clock.fastForward(120000); expect(calls).toBe(2); await page.locator('#refresh').click(); await expect.poll(() => calls).toBe(3);
  await page.locator('#auto-refresh').focus(); await page.keyboard.press('Space'); await expect(page.locator('#auto-refresh')).toBeChecked(); await expect(page.locator('#auto-refresh')).toBeFocused();
});
test('manual observations age without fetching or changing timestamps, including after returning to the page', async ({ page }) => {
  const start = new Date('2026-10-15T00:00:00.000Z');
  const data = snapshot(); data.generatedAt = data.providers[0].observedAt = start.toISOString();
  await page.clock.install({ time: new Date(start.getTime() - 60000) }); let calls = 0;
  await page.route('**/v1/snapshot', route => { calls++; return route.fulfill({ json: data }); });
  await page.goto('/'); await page.clock.pauseAt(start); await pair(page); await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  await page.locator('#auto-refresh').uncheck();
  const provider = page.locator('.provider').first(), badge = provider.locator('.badge');
  const updated = await page.locator('#updated').textContent(), observed = await provider.locator('.source').textContent();
  await page.clock.fastForward(900000); await expect(badge).toHaveText('최근 관측');
  await page.clock.fastForward(60000); await expect(badge).toContainText('STALE');
  expect(calls).toBe(1); await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  expect(await page.locator('#updated').textContent()).toBe(updated);
  await expect(provider.locator('.source')).toContainText(observed!);
  data.generatedAt = data.providers[0].observedAt = new Date(start.getTime() + 960000).toISOString();
  await page.locator('#refresh').click(); await expect(badge).toHaveText('최근 관측');
  const refreshed = await page.locator('#updated').textContent();
  await page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, value: true }); document.dispatchEvent(new Event('visibilitychange')); });
  await page.clock.fastForward(960000); expect(calls).toBe(2);
  await page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, value: false }); document.dispatchEvent(new Event('visibilitychange')); });
  await expect(badge).toContainText('STALE'); expect(calls).toBe(2);
  await expect(page.locator('#auto-refresh')).not.toBeChecked();
  await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  expect(await page.locator('#updated').textContent()).toBe(refreshed);
});
test('manual checks survive reopening and demo visits without restoring automatic requests', async ({ page }) => {
  await page.clock.install(); let calls = 0;
  await page.route('**/v1/snapshot', route => { calls++; return route.fulfill({ json: snapshot() }); });
  await page.goto('/'); await expect(page.locator('#auto-refresh')).toBeChecked();
  await pair(page); await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  await page.locator('#auto-refresh').uncheck();
  await page.reload(); await expect(page.locator('#auto-refresh')).not.toBeChecked();
  await expect(page.locator('#disconnect')).toBeVisible();
  await expect(page.locator('#status')).toHaveText('수동 확인 · 새로고침을 눌러 주세요');
  await expect(page.locator('.provider').first().locator('.badge')).toHaveText('관측 없음');
  await expect(page.locator('.provider').first().locator('.unknown')).toHaveText('새로고침하여 남은 사용량을 확인하세요.');
  if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: '.amp/in/artifacts/manual-restored-ko.png', fullPage: true });
  await page.clock.fastForward(120000);
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, value: true }); document.dispatchEvent(new Event('visibilitychange'));
    Object.defineProperty(document, 'hidden', { configurable: true, value: false }); document.dispatchEvent(new Event('visibilitychange'));
  });
  expect(calls).toBe(1); await expect(page.getByRole('progressbar')).toHaveCount(0);
  await page.locator('#refresh').click(); await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42'); expect(calls).toBe(2);
  await page.goto('/?demo=1'); await expect(page.locator('#auto-refresh')).toBeDisabled();
  await page.goto('/'); await expect(page.locator('#auto-refresh')).not.toBeChecked();
  await page.clock.fastForward(120000); expect(calls).toBe(2);
  await page.locator('header select').selectOption('en');
  await expect(page.locator('#status')).toHaveText('Manual checks · Choose Refresh now');
  await expect(page.locator('.provider').first().locator('.badge')).toHaveText('No observation');
  await expect(page.locator('.provider').first().locator('.unknown')).toHaveText('Choose Refresh now to check remaining quota.');
  if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: '.amp/in/artifacts/manual-restored-en.png', fullPage: true });
  await page.locator('#auto-refresh').check(); await page.reload();
  await expect(page.locator('#auto-refresh')).toBeChecked();
  await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42'); expect(calls).toBe(3);
  await page.goto('/?demo=1'); await page.goto('/');
  await expect(page.locator('#auto-refresh')).toBeChecked();
  await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42'); expect(calls).toBe(4);
  await page.clock.fastForward(60000); await expect.poll(() => calls).toBe(5);
  expect(await page.evaluate(() => localStorage.getItem('quotadock.token'))).toBeNull();
});
test('an unsaved automatic-check choice remains effective and its warning survives requests and language changes', async ({ page }) => {
  await page.clock.install(); let calls = 0;
  await page.route('**/v1/snapshot', route => { calls++; return route.fulfill({ json: snapshot() }); });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/'); await pair(page); await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  const restoreWrites = await page.evaluateHandle(() => {
    const original = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      if (this === localStorage && key === 'quotadock.auto-refresh') throw new DOMException('Denied', 'SecurityError');
      return original.call(this, key, value);
    };
    return () => { Storage.prototype.setItem = original; };
  });
  // Safari need not focus a checkbox on pointer clicks. Exercise the keyboard
  // contract explicitly: publishing the save warning must not steal focus.
  const autoRefresh = page.locator('#auto-refresh');
  await autoRefresh.focus(); await page.keyboard.press('Space');
  await expect(autoRefresh).not.toBeChecked(); await expect(autoRefresh).toBeFocused();
  await expect(page.locator('#auto-refresh-warning')).toContainText('자동 확인 설정을 저장하지 못했습니다.');
  await page.clock.fastForward(120000); expect(calls).toBe(1);
  if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: '.amp/in/artifacts/auto-refresh-unsaved-ko.png', fullPage: true });
  await page.locator('#refresh').click(); await expect.poll(() => calls).toBe(2);
  await expect(page.locator('#auto-refresh-warning')).toBeVisible();
  await page.locator('header select').selectOption('en');
  await expect(page.locator('#auto-refresh-warning')).toHaveText('Could not save automatic-check settings. Your choice applies on this page; reopening it may restore the previous setting.');
  await expect(page.locator('#auto-refresh')).not.toBeChecked();
  if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: '.amp/in/artifacts/auto-refresh-unsaved-en.png', fullPage: true });
  await page.locator('#auto-refresh').check(); await page.locator('#auto-refresh').uncheck();
  await expect(page.locator('#auto-refresh-warning')).toBeVisible();
  await restoreWrites.evaluate(restore => restore());
  await page.locator('#auto-refresh').check(); await expect(page.locator('#auto-refresh-warning')).toHaveCount(0);
  await page.reload(); await expect(page.locator('#auto-refresh')).toBeChecked();
  await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42'); expect(calls).toBe(3);
});
test('visibility cancels an active request; foreground auto resumes but manual does not', async ({ page }) => {
  let release: (() => void) | undefined, calls = 0;
  await page.route('**/v1/snapshot', async r => {
    calls++;
    if (calls === 1 || calls === 3) await new Promise<void>(resolve => { release = resolve; });
    await r.fulfill({ json: snapshot() }).catch(() => {});
  });
  await page.goto('/'); await pair(page); await expect.poll(() => calls).toBe(1);
  // Headless Chromium doesn't consistently hide tabs. Deliver browser visibility
  // transitions to the real React UI, without replacing its DOM or client logic.
  await page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, value: true }); document.dispatchEvent(new Event('visibilitychange')); });
  release?.(); await expect(page.getByRole('progressbar')).toHaveCount(0);
  await page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, value: false }); document.dispatchEvent(new Event('visibilitychange')); });
  await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  await page.locator('#auto-refresh').uncheck();
  await page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, value: true }); document.dispatchEvent(new Event('visibilitychange')); Object.defineProperty(document, 'hidden', { configurable: true, value: false }); document.dispatchEvent(new Event('visibilitychange')); });
  expect(calls).toBe(2);
  const updated = await page.locator('#updated').textContent();
  await page.locator('#refresh').click(); await expect.poll(() => calls).toBe(3);
  await expect(page.locator('#status')).toHaveText('사용량 확인 중…');
  await page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, value: true }); document.dispatchEvent(new Event('visibilitychange')); });
  release?.();
  await page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, value: false }); document.dispatchEvent(new Event('visibilitychange')); });
  await expect(page.locator('#status')).toHaveText('확인 중단 · 다시 새로고침할 수 있습니다');
  await expect(page.locator('#refresh')).toBeEnabled();
  await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42');
  expect(await page.locator('#updated').textContent()).toBe(updated); expect(calls).toBe(3);
  await page.locator('header select').selectOption('en');
  await expect(page.locator('#status')).toHaveText('Check stopped · You can refresh again');
  await page.locator('#refresh').click(); await expect.poll(() => calls).toBe(4);
  await expect(page.locator('#status')).toHaveText('Remaining quota checked');
});
test('15s deadline cancels stalled body and allows retry', async ({ page }) => {
  await page.clock.install(); await page.goto('/');
  await page.evaluate(() => {
    window.fetch = async () => new Response(new ReadableStream({ cancel() { sessionStorage.setItem('body-cancelled', 'yes'); } }));
  });
  await pair(page); await expect(page.locator('#refresh')).toBeDisabled(); await page.clock.fastForward(15000);
  await expect(page.locator('#status')).toContainText('연결하지 못했습니다'); await expect(page.locator('#refresh')).toBeEnabled();
  expect(await page.evaluate(() => sessionStorage.getItem('body-cancelled'))).toBe('yes');
});
test('built serving refuses sources and arbitrary paths with unchanged CSP', async ({ request }) => {
  for (const path of ['/src/App.tsx', '/src/client.ts', '/package.json', '/icons/LICENSE', '/chunk-unknown.js']) expect((await request.get(path)).status()).toBe(404);
  const response = await request.get('/'); expect(response.headers()['content-security-policy']).toContain("connect-src 'self'"); expect(await response.text()).toContain('/app.js');
});
test('a positive quota below display precision is not presented as exhausted', async ({ page }) => {
  const sample = snapshot();
  sample.providers[0].windows = [
    { label: 'Session', remainingPercent: 0.004, resetsAt: null },
    { label: 'Weekly', remainingPercent: 0, resetsAt: null },
    { label: 'Daily', remainingPercent: 0.01, resetsAt: null },
  ];
  await page.route('**/v1/snapshot', route => route.fulfill({ json: sample }));
  await page.setViewportSize({ width: 320, height: 844 });
  await page.goto('/'); await pair(page);
  for (const language of ['ko', 'en']) {
    await page.locator('header select').selectOption(language);
    await expect(page.locator('.window-heading strong')).toHaveText(language === 'ko'
      ? ['0.01% 미만 남음', '0% 남음', '0.01% 남음']
      : ['Less than 0.01% remaining', '0% remaining', '0.01% remaining']);
    await expect(page.locator('.provider').first().locator('.badge')).toHaveText(language === 'ko' ? '최근 관측' : 'Recent observation');
    expect(await page.getByRole('progressbar').evaluateAll(bars => bars.map(bar => (bar as HTMLProgressElement).value))).toEqual([0.004, 0, 0.01]);
    await expect(page.getByRole('progressbar').first()).toHaveAttribute('aria-valuetext', language === 'ko' ? '0.01% 미만 남음' : 'Less than 0.01% remaining');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: `.amp/in/artifacts/readability-tiny-quota-${language}-320.png`, fullPage: true });
  }
});
test('demo desktop/mobile appearance, icons and unknown Grok', async ({ page }) => {
  await page.goto('/?demo=1'); await expect(page.locator('#mode')).toContainText('DEMO'); await expect(page.getByRole('progressbar')).toHaveCount(6); await expect(page.locator('.provider').last().getByRole('progressbar')).toHaveCount(0); await expect(page.locator('#auto-refresh')).toBeDisabled();
  expect(await page.locator('.provider-icon').evaluateAll(images => images.every(img => img instanceof HTMLImageElement && img.naturalWidth > 0))).toBe(true);
  for (const width of [320, 390, 1440]) {
    await page.setViewportSize({ width, height: 844 });
    expect((await page.locator('header select').boundingBox())!.height).toBeGreaterThanOrEqual(44);
  }
  const codexGuide = page.getByText('Codex 허용량 · 전체 ChatGPT 사용량 아님. Free 지원은 화면·롤아웃에 따라 다르며 측정 불가는 알 수 없음입니다.', { exact: true });
  await expect(codexGuide).toBeHidden();
  await page.getByText('Codex 안내', { exact: true }).focus(); await page.keyboard.press('Enter');
  await expect(codexGuide).toBeVisible(); await expect(page.getByRole('progressbar')).toHaveCount(6);
  await page.keyboard.press('Enter'); await expect(codexGuide).toBeHidden();
  if (process.env.CAPTURE_DASHBOARD) {
    await page.setViewportSize({ width: 1440, height: 1100 }); await page.screenshot({ path: '.amp/in/artifacts/dashboard-desktop.png', fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 }); await page.screenshot({ path: '.amp/in/artifacts/dashboard-mobile.png', fullPage: true });
  }
  await page.setViewportSize({ width: 320, height: 844 });
  await page.evaluate(() => { document.documentElement.style.fontSize = '200%'; });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  expect(await page.getByRole('progressbar').evaluateAll(bars => bars.map(bar => (bar as HTMLProgressElement).value))).toEqual([72, 91, 84, 63, 88, 96]);
  if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: '.amp/in/artifacts/dashboard-demo-ko-320-root-200.png', fullPage: true });
});

test('plans stay read-only, bilingual and concise without collecting paired quota', async ({ page }) => {
  const quotaRequests: string[] = [];
  page.on('request', request => { if (request.url().includes('/v1/snapshot')) quotaRequests.push(request.url()); });
  await page.addInitScript(() => {
    sessionStorage.setItem('quotadock.endpoint', location.origin);
    sessionStorage.setItem('quotadock.token', 'a'.repeat(64));
  });
  await page.goto('/?view=plans');
  for (const width of [390, 320, 1440]) {
    await page.setViewportSize({ width, height: 844 });
    for (const language of ['ko', 'en']) {
      await page.locator('header select').selectOption(language);
      await expect(page.getByRole('heading', { name: language === 'ko' ? '요금제' : 'Plans', exact: true })).toBeVisible();
      await expect(page.getByRole('article')).toHaveCount(3);
      const plus = page.getByRole('article', { name: 'QuotaDock Plus', exact: true });
      const pro = page.getByRole('article', { name: 'QuotaDock Pro', exact: true });
      for (const cycle of ['month', 'year']) {
        await page.getByRole('combobox', { name: language === 'ko' ? '결제 주기' : 'Billing cycle' }).selectOption(cycle);
        await expect(plus.locator('.plan-price')).toContainText(cycle === 'month' ? '2,990' : '29,900');
        await expect(pro.locator('.plan-price')).toContainText(cycle === 'month' ? '5,990' : '59,900');
        await expect(pro).toContainText(language === 'ko' ? 'AI 계정 최대 25개' : 'Up to 25 AI accounts');
        for (const [card, amount] of [[plus, cycle === 'month' ? '2,990' : '29,900'], [pro, cycle === 'month' ? '5,990' : '59,900']] as const) {
          const payment = card.locator('p').filter({ hasText: language === 'ko' ? '첫 구매 시 결제:' : 'Charged at first purchase:' });
          await expect(payment).toContainText(amount);
          await expect(payment).toContainText(language === 'ko' ? '자동 갱신' : 'auto-renewing');
          await expect(payment).toContainText(language === 'ko' ? cycle === 'month' ? '/ 월' : '/ 년' : cycle === 'month' ? '/ month' : '/ year');
        }
        await expect(page.getByRole('article', { name: 'QuotaDock Free', exact: true })).toContainText(language === 'ko' ? '기간 제한 없이 무료' : 'Free with no time limit');
        await expect(page.locator('main')).not.toContainText(/1개월 무료|1 month free|introductory offer|무료 1개월 후|after 1 free month|혜택 적용|offer eligibility/);
        await expect(page.locator('.trial-details')).toHaveCount(0);
        await expect(page.locator('.plan-terms')).toContainText(language === 'ko' ? '무료 체험 없이 첫 구매부터 결제' : 'charged from the first purchase, with no free trial');
        await expect(page.locator('.plan-terms')).toContainText(language === 'ko' ? '첫 구매 시 1년 전액' : 'full year at first purchase');
        await expect(page.locator('.plan-terms')).toContainText(language === 'ko' ? '선택한 월간 또는 연간 주기로 자동 갱신' : 'Renews automatically on the selected monthly or annual cycle');
        for (const state of ['closed', 'expanded']) {
          await page.locator('.plan-terms').evaluate((element, open) => { (element as HTMLDetailsElement).open = open; }, state === 'expanded');
          expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
          if (process.env.CAPTURE_PLANS) await page.screenshot({ path: `.amp/in/artifacts/final-plans-${language}-${width}-${cycle}-${state}.png`, fullPage: true });
        }
      }
      await page.locator('.plan-terms summary').click();
      await expect(page.getByRole('button')).toHaveCount(0);
      await expect(page.locator('main')).not.toContainText(/목표|출시|준비 중|release target|not on sale|not available yet|month target/i);
      await expect(page.locator('.plan-terms')).not.toHaveAttribute('open');
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      if (process.env.CAPTURE_PLANS) await page.screenshot({ path: `.amp/in/artifacts/plans-${language}-${width}.png`, fullPage: true });
    }
  }
  await page.locator('header select').selectOption('ko');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator('.plan-terms summary').focus();
  await page.keyboard.press('Enter');
  await expect(page.getByText('개인정보', { exact: true })).toBeVisible();
  await expect(page.locator('.plan-terms')).toContainText('Apple StoreKit');
  if (process.env.CAPTURE_PLANS) await page.screenshot({ path: '.amp/in/artifacts/plans-ko-details-390.png', fullPage: true });
  await page.evaluate(() => { document.documentElement.style.fontSize = '200%'; });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  expect(quotaRequests).toEqual([]);
  await page.getByRole('link', { name: '← 사용량 보드' }).click();
  await expect(page.getByRole('link', { name: '요금제', exact: true })).toBeVisible();
});
