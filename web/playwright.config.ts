import { defineConfig } from '@playwright/test';
import { existsSync } from 'node:fs';
export default defineConfig({ testDir: 'tests', workers: 1,
  use: { baseURL: 'http://127.0.0.1:4317' },
  projects: [
    { name: 'chromium', use: { browserName: 'chromium', launchOptions: { executablePath: process.env.CHROME_PATH || (existsSync('/usr/bin/google-chrome') ? '/usr/bin/google-chrome' : undefined) } } },
    { name: 'webkit', use: { browserName: 'webkit' } },
  ],
  // The bridge pins built assets at startup; reuse could silently test an old bundle.
  webServer: { command: 'node tests/serve.mjs', url: 'http://127.0.0.1:4317/healthz', reuseExistingServer: false }
});
