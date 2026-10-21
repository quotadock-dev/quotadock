import { test, expect } from '@playwright/test';
test.use({ locale: 'en-US' });
test('blocked localStorage getter leaves language usable even on storage events', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript(() => Object.defineProperty(window, 'localStorage', { get() { throw new DOMException('Blocked', 'SecurityError'); } }));
  await page.goto('/?demo=1');
  await page.locator('header select').selectOption('ko');
  await expect(page.locator('#language-save-status')).toHaveAttribute('role', 'status');
  await page.evaluate(() => window.dispatchEvent(new StorageEvent('storage', { key: 'quotadock.language', newValue: 'en' })));
  await expect(page.locator('html')).toHaveAttribute('lang', 'ko');
  expect(errors).toEqual([]);
});
for (const [languages, expected] of [
  [['fr-FR', 'ko-KR', 'en-US'], 'ko'],
  [['fr-FR', 'en-US', 'ko-KR'], 'en'],
  [['fr-FR', 'de-DE'], 'en'],
  [[], 'ko'],
] as const) test(`first supported system language: ${languages.join(',') || 'navigator.language fallback'}`, async ({ page }) => {
  await page.addInitScript(languages => {
    Object.defineProperty(navigator, 'languages', { configurable: true, value: languages });
    Object.defineProperty(navigator, 'language', { configurable: true, value: 'ko-KR' });
  }, languages);
  await page.goto('/?demo=1');
  await expect(page.locator('html')).toHaveAttribute('lang', expected);
  const language = page.locator('header select');
  await language.selectOption('en');
  await page.evaluate(() => {
    Object.defineProperty(navigator, 'languages', { configurable: true, value: ['fr-FR', 'ko-KR', 'en-US'] });
    window.dispatchEvent(new Event('languagechange'));
  });
  await expect(page.locator('html')).toHaveAttribute('lang', 'en');
  await page.reload();
  await expect(language).toHaveValue('en');
  await language.selectOption('system');
  await expect(page.locator('html')).toHaveAttribute('lang', expected);
  await page.evaluate(() => {
    Object.defineProperty(navigator, 'languages', { configurable: true, value: ['fr-FR', 'ko-KR', 'en-US'] });
    window.dispatchEvent(new Event('languagechange'));
  });
  await expect(page.locator('html')).toHaveAttribute('lang', 'ko');
});
test('iframe session storage cannot change the language preference', async ({ page, context }) => {
  await page.goto('/?demo=1');
  const language = page.locator('header select');
  await language.selectOption('en');
  await page.evaluate(() => {
    const frame = document.createElement('iframe');
    frame.src = 'about:blank';
    document.body.append(frame);
  });
  for (const clear of [false, true]) {
    const event = page.evaluate(() => new Promise(resolve => window.addEventListener('storage', event => resolve({ key: event.key, session: event.storageArea === sessionStorage }), { once: true })));
    await page.frames()[1].evaluate(clear => {
      if (clear) sessionStorage.clear();
      else sessionStorage.setItem('quotadock.language', 'ko');
    }, clear);
    expect(await event).toEqual({ key: clear ? null : 'quotadock.language', session: true });
    await expect(language).toHaveValue('en');
    await expect(page.locator('html')).toHaveAttribute('lang', 'en');
  }
  const second = await context.newPage();
  await second.goto('/?demo=1');
  await second.locator('header select').selectOption('ko');
  await expect(language).toHaveValue('ko');
  await expect(page.locator('html')).toHaveAttribute('lang', 'ko');
  await second.close();
});
test('language save failure is announced without changing pairing, readings or the manual-check choice', async ({ page }) => {
  let calls = 0;
  await page.route('**/v1/snapshot', route => {
    calls++;
    return route.fulfill({ json: { schemaVersion: 1, demo: false, generatedAt: '2026-01-01T00:00:00.000Z', providers: [{ id: 'claude', plan: 'Max', source: 'codexbar', state: 'available', observedAt: '2026-01-01T00:00:00.000Z', windows: [{ label: 'Weekly', remainingPercent: 37.5, resetsAt: null }] }] } });
  });
  await page.setViewportSize({ width: 320, height: 844 });
  await page.goto('/'); await page.locator('#settings-toggle').click(); await page.locator('#token').fill('b'.repeat(64));
  await page.locator('#connect-form button[type=submit]').click();
  await expect(page.getByRole('progressbar')).toHaveAttribute('value', '37.5');
  await page.locator('#auto-refresh').uncheck();
  const restoreWrites = await page.evaluateHandle(() => {
    const original = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      if (this === localStorage && key === 'quotadock.language') throw new DOMException('Quota exceeded', 'QuotaExceededError');
      return original.call(this, key, value);
    };
    return () => { Storage.prototype.setItem = original; };
  });
  const language = page.locator('header select'), feedback = page.locator('#language-save-status');
  for (const choice of ['ko', 'en']) {
    await language.focus(); await language.selectOption(choice); await expect(language).toBeFocused();
    await expect(page.locator('html')).toHaveAttribute('lang', choice);
    await expect(language).toHaveAttribute('aria-describedby', 'language-save-status');
    await expect(feedback).toHaveText(choice === 'ko' ? '언어 설정을 저장하지 못했습니다. 새로고침하면 선택이 유지되지 않을 수 있습니다.' : 'Could not save your language. Your choice may reset on reload.');
    await expect(page.getByRole('progressbar')).toHaveAttribute('value', '37.5');
    await expect(page.locator('#auto-refresh')).not.toBeChecked();
    await expect(page.locator('#disconnect')).toBeVisible(); expect(calls).toBe(1);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: `.amp/in/artifacts/dashboard-language-unsaved-${choice}-320.png`, fullPage: true });
  }
  await page.evaluate(() => {
    const sizes = [...document.querySelectorAll<HTMLElement>('body, body *')].map(element => ({ element, size: parseFloat(getComputedStyle(element).fontSize) }));
    for (const { element, size } of sizes) element.style.fontSize = `${size * 2}px`;
  });
  for (const choice of ['ko', 'en']) {
    await language.selectOption(choice); await expect(language).toBeFocused();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: `.amp/in/artifacts/dashboard-language-unsaved-${choice}-320-double-text.png`, fullPage: true });
  }
  await restoreWrites.evaluate(restore => restore());
  await language.selectOption('ko'); await expect(feedback).toBeEmpty();
  await page.reload(); await expect(language).toHaveValue('ko');
  await expect(page.locator('#auto-refresh')).not.toBeChecked();
  await expect(page.locator('#disconnect')).toBeVisible(); expect(calls).toBe(1);
});
test('tabs share language without sharing pairing or refreshing quota', async ({ page, context }) => {
  const secret = 'b'.repeat(64);
  let calls = 0;
  await context.route('**/v1/snapshot', route => {
    calls++;
    expect(route.request().headers().authorization).toBe(`Bearer ${secret}`);
    return route.fulfill({ json: { schemaVersion: 1, demo: false, generatedAt: '2026-01-01T00:00:00.000Z', providers: [{ id: 'claude', plan: 'Max', source: 'codexbar', state: 'available', observedAt: '2026-01-01T00:00:00.000Z', windows: [{ label: 'Weekly', remainingPercent: 37.5, resetsAt: null }] }] } });
  });
  await page.goto('/');
  await page.locator('#settings-toggle').click();
  await page.locator('#token').fill(secret);
  await page.locator('#connect-form button[type=submit]').click();
  await expect(page.getByRole('progressbar')).toHaveAttribute('value', '37.5');
  await page.locator('#auto-refresh').uncheck();
  const second = await context.newPage();
  await second.goto('/');
  const language = page.locator('header select');
  const secondLanguage = second.locator('header select');
  for (const choice of ['ko', 'en']) {
    await secondLanguage.selectOption(choice);
    await expect(language).toHaveValue(choice);
    await expect(page.locator('html')).toHaveAttribute('lang', choice);
    await expect(page.getByRole('progressbar')).toHaveAttribute('value', '37.5');
    await expect(page.locator('.window-heading span')).toHaveText(choice === 'ko' ? '주간' : 'Weekly');
    await expect(page.locator('#auto-refresh')).not.toBeChecked();
    await expect(page.locator('#disconnect')).toBeVisible();
    await expect(second.locator('#disconnect')).toBeHidden();
    await expect(second.getByRole('progressbar')).toHaveCount(0);
    expect(await page.evaluate(() => sessionStorage.getItem('quotadock.token'))).toBe(secret);
    expect(await second.evaluate(() => sessionStorage.getItem('quotadock.token'))).toBeNull();
    expect(calls).toBe(1);
  }
  await second.close();
});
for (const width of [390, 1440]) test(`language preserves pairing and readings at ${width}`, async ({ page }) => {
  await page.setViewportSize({ width, height: 1000 });
  let calls = 0, reject = false;
  const secret = 'a'.repeat(64);
  const upstreamPlan = 'Max';
  const upstreamWindow = 'Weekly';
  await page.route('**/v1/snapshot', route => {
    calls++; expect(route.request().headers().authorization).toBe(`Bearer ${secret}`);
    return reject ? route.abort() : route.fulfill({ json: { schemaVersion: 1, demo: false, generatedAt: '2026-01-01T00:00:00.000Z', providers: [{ id: 'claude', plan: upstreamPlan, source: 'codexbar', state: 'available', observedAt: '2026-01-01T00:00:00.000Z', windows: [{ label: 'Session', remainingPercent: 42.5, resetsAt: null }, { label: upstreamWindow, remainingPercent: null, resetsAt: null }] }] } });
  });
  await page.goto('/'); const language = page.locator('header select');
  await expect(page.locator('html')).toHaveAttribute('lang', 'en');
  await expect(page.locator('#token')).toBeHidden(); await page.locator('#settings-toggle').click();
  await expect(page.getByRole('heading', { name: 'Connecting for the first time?' })).toBeVisible();
  if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: `.amp/in/artifacts/dashboard-en-guide-${width}.png`, fullPage: true });
  await page.locator('#token').fill(secret); await language.focus(); await language.selectOption('ko'); await expect(language).toBeFocused();
  await expect(page.locator('#token')).toHaveValue(secret); expect(calls).toBe(0);
  await page.getByRole('button', { name: '연결 안내 닫기' }).focus(); await page.keyboard.press('Enter');
  await expect(page.locator('#endpoint')).toBeFocused();
  await page.getByRole('button', { name: '연결하기' }).click();
  await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42.5');
  await page.locator('#auto-refresh').uncheck(); await language.selectOption('en');
  await expect(page.locator('.plan').first()).toHaveText(`Plan · ${upstreamPlan}`);
  await expect(page.locator('.window-heading span').nth(1)).toHaveText(upstreamWindow);
  await expect(page.locator('#disconnect')).toBeVisible();
  expect(await page.evaluate(() => sessionStorage.getItem('quotadock.token'))).toBe(secret);
  await expect(page.getByRole('progressbar')).toHaveAttribute('aria-label', 'Claude Session Remaining quota');
  await expect(page.locator('#updated')).toContainText('Jan');
  expect(calls).toBe(1); await expect(page.locator('#auto-refresh')).not.toBeChecked();
  reject = true; await page.locator('#refresh').click(); await expect(page.locator('#status')).toContainText('Connection error');
  await language.selectOption('ko'); await expect(page.locator('#status')).toContainText('연결 오류');
  await expect(page.locator('.plan').first()).toHaveText(`플랜 · ${upstreamPlan}`);
  await expect(page.locator('.window-heading span').nth(1)).toHaveText('주간');
  await expect(page.locator('#disconnect')).toBeVisible();
  expect(await page.evaluate(() => sessionStorage.getItem('quotadock.token'))).toBe(secret);
  await expect(page.getByRole('progressbar')).toHaveAttribute('value', '42.5'); expect(calls).toBe(2);
  await expect(page.locator('body')).not.toContainText(secret);
  if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: `.amp/in/artifacts/dashboard-ko-error-${width}.png`, fullPage: true });
  await page.reload(); await expect(page.locator('html')).toHaveAttribute('lang', 'ko'); await expect(page.locator('#guide-title')).toHaveCount(0);
  await page.goto('/?demo=1'); const before = calls;
  const values = await page.getByRole('progressbar').evaluateAll(bars => bars.map(bar => (bar as HTMLProgressElement).value));
  await language.selectOption('en');
  expect(await page.getByRole('progressbar').evaluateAll(bars => bars.map(bar => (bar as HTMLProgressElement).value))).toEqual(values);
  const untranslated = await page.evaluate(() => [...document.querySelectorAll('body *')].flatMap(element => [...element.childNodes].filter(node => node.nodeType === Node.TEXT_NODE && element.tagName !== 'OPTION' && /[가-힣]/.test(node.textContent || '')).map(node => node.textContent)));
  expect(untranslated).toEqual([]);
  expect(calls).toBe(before); await expect(page.locator('#mode')).toContainText('DEMO');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  if (process.env.CAPTURE_DASHBOARD) await page.screenshot({ path: `.amp/in/artifacts/dashboard-en-demo-${width}.png`, fullPage: true });
  await language.selectOption('system'); await expect(page.locator('html')).toHaveAttribute('lang', 'en');
});
for (const mode of ['invalid', 'blocked']) test(`language fallback with ${mode} storage`, async ({ page }) => {
  await page.addInitScript(mode => {
    if (mode === 'blocked') for (const method of ['getItem', 'setItem', 'removeItem']) Object.defineProperty(Storage.prototype, method, { value() { throw new Error('blocked'); } });
    else localStorage.setItem('quotadock.language', '{invalid}');
  }, mode);
  let bearer = 0; page.on('request', request => { if (request.headers().authorization) bearer++; });
  await page.goto('/?demo=1'); await expect(page.locator('html')).toHaveAttribute('lang', 'en');
  await page.locator('header select').selectOption('ko'); await expect(page.locator('html')).toHaveAttribute('lang', 'ko');
  await page.reload(); await expect(page.locator('html')).toHaveAttribute('lang', 'en'); expect(bearer).toBe(0);
});
test.describe('unsupported system locale', () => {
  test.use({ locale: 'fr-FR' });
  test('defaults to English', async ({ page }) => {
    await page.goto('/?demo=1'); await expect(page.locator('html')).toHaveAttribute('lang', 'en');
    await expect(page.locator('header select')).toHaveValue('system');
  });
});
