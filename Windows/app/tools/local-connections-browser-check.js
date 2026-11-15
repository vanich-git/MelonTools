#!/usr/bin/env node
// Real Chromium DOM smoke. API data is deterministic; no Tauri/user state is used.
// Usage: PLAYWRIGHT_MODULE=/absolute/path/to/playwright-core CHROME_BIN=... node this-file
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright-core');

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true,
  });
  try {
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
    // Only local static resources: this test cannot contact external services.
    await context.route(/^https?:/, route => route.abort());
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(pathToFileURL(path.resolve(__dirname, '../ui/index.html')).href);
    await page.waitForFunction(() => typeof A !== 'undefined' && S.settings);
    await page.evaluate(async () => {
      window.__browserLocalModels = [{ id: 'local/browser-qwen', displayName: 'Browser Qwen', runtimeStatus: 'ready' }];
      window.__browserGatewayModels = [{ id: 'local/browser-qwen', displayName: 'Browser Qwen' }];
      window.__browserRuntime = { isRunning: true, modelId: 'local/browser-qwen', currentModel: { id: 'local/browser-qwen', displayName: 'Browser Qwen' } };
      A.onboardingDone();
      const preview = inv;
      inv = async (command, args) => {
        if (command === 'gateway_models') return window.__browserGatewayModels;
        if (command === 'local_ai_models_list') return window.__browserLocalModels;
        if (command === 'local_ai_runtime_status') return window.__browserRuntime;
        if (command === 'gateway_check') return JSON.stringify({ model: 'local/browser-qwen' });
        return preview(command, args);
      };
      window.api.localAi.modelsList = async () => window.__browserLocalModels;
      window.api.localAi.runtimeStatus = async () => window.__browserRuntime;
      S.lang = 'en';
      S.section = 'providers';
      S.localAi.connectionCheck = null;
      await A.modelsLoad();
      render();
    });
    const checkButton = page.locator('[data-action="localAiConnectionsCheck"]');
    await checkButton.waitFor({ state: 'visible' });
    await checkButton.click();
    await page.waitForFunction(() => S.localAi.connectionCheck && !S.busy.localAiCheck);
    assert.equal(await page.evaluate(() => S.localAi.connectionCheck.ok), true);
    assert.match(await page.locator('#main').innerText(), /local\/browser-qwen/);
    const localCard = page.locator('#main .card').filter({ has: page.locator('[data-action="localAiConnectionsCheck"]') });
    assert.deepEqual(await localCard.locator('.provider-metrics .value').allTextContents(), ['1', '1'], 'Connections must count the loaded model and published alias');
    await page.evaluate(() => {
      window.__browserRuntime.publicationError = 'published but catalog failed';
      S.localAi.connectionCheck = null;
    });
    await checkButton.click();
    await page.waitForFunction(() => S.localAi.connectionCheck && !S.busy.localAiCheck);
    assert.equal(await page.evaluate(() => S.localAi.connectionCheck.ok), false, 'publication error must fail the check even with alias present');

    await page.evaluate(() => {
      window.__browserRuntime.publicationError = null;
      window.__browserGatewayModels = [];
      S.localAi.connectionCheck = null;
    });
    await checkButton.click();
    await page.waitForFunction(() => S.localAi.connectionCheck && !S.busy.localAiCheck);
    assert.equal(await page.evaluate(() => S.localAi.connectionCheck.ok), false);
    assert.match(await page.locator('#main .danger').allTextContents().then(items => items.join(' ')), /local\/browser-qwen/);

    await page.evaluate(() => {
      window.__browserLocalModels = [];
      window.__browserRuntime = { isRunning: false };
      window.__browserGatewayModels = [{ id: 'local/browser-qwen' }];
      S.localAi.connectionCheck = null;
    });
    await checkButton.click();
    await page.waitForFunction(() => S.localAi.connectionCheck && !S.busy.localAiCheck);
    assert.equal(await page.evaluate(() => S.localAi.connectionCheck.ok), false);

    await page.evaluate(async () => {
      window.__browserGatewayModels = [];
      S.localAi.connectionCheck = null;
      await A.modelsLoad();
      render();
    });
    assert.equal(await page.evaluate(() => S.models.some(model => model.id === 'local/browser-qwen')), false);
    assert.deepEqual(await localCard.locator('.provider-metrics .value').allTextContents(), ['0', '0'], 'Connections must clear counts after unload');
    await page.evaluate(() => { S.localAi.runtime.publicationError = 'browser publication failure'; render(); });
    assert.match(await page.locator('#main').innerText(), /browser publication failure/);
    await page.evaluate(() => { S.localAi.runtime.publicationError = null; render(); });
    await page.locator('[data-action="localAiConnectionsOpen"]').click();
    await page.waitForFunction(() => S.section === 'local_ai' && S.localAi.tab === 'models');
    await page.waitForFunction(() => document.querySelector('#main').innerText.includes('Local AI'));
    if (process.env.SMOKE_SCREENSHOT) await page.screenshot({ path: process.env.SMOKE_SCREENSHOT, fullPage: true });
    assert.deepEqual(errors, [], 'Chromium must have no uncaught page errors');
    console.log('PASS Chromium Connections/Models: visible check, ready/missing/stale, catalog removal, publication error; mocked API only');
    await context.close();
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
