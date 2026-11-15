#!/usr/bin/env node
// Real Chromium regression for the four shared search fields: theme-visible
// frame, click-to-focus on the glyph and padding, native cancel suppression,
// keyboard clearing, and the model-pool dialog's a11y/Escape contract.
// Usage: PLAYWRIGHT_MODULE=/absolute/path/to/playwright-core CHROME_BIN=... node this-file
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright-core');

const UI = path.resolve(__dirname, '../ui');
const GOLD = 'rgb(245, 158, 11)';

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true,
  });
  try {
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: 'dark' });
    // Only local static resources: this test cannot contact external services.
    await context.route(/^https?:/, route => route.abort());
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(pathToFileURL(path.join(UI, 'index.html')).href);
    await page.waitForFunction(() => typeof A !== 'undefined' && typeof S !== 'undefined' && S.settings);
    await page.evaluate(() => {
      A.onboardingDone();
      document.querySelectorAll('dialog').forEach(dialog => dialog.remove());
      document.body.inert = false;
      S.lang = 'en';
      window.api.localAi.hfSearch = async () => [];
      S.models = [
        { id: 'mistral-7b', displayName: 'Mistral 7B' },
        { id: 'qwen2-7b', displayName: 'Qwen2 7B' },
        { id: 'llama-3-8b', displayName: 'Llama 3 8B' },
      ];
      S.modelsQuery = '';
      S.localAi.searchQuery = '';
      S.localAi.models = [
        { id: 'local/mistral', displayName: 'Mistral Local', fileSize: 1024, quantization: 'Q4' },
        { id: 'local/qwen', displayName: 'Qwen Local', fileSize: 2048, quantization: 'Q5' },
      ];
      S.localAi.catalogQuery = '';
      S.localAi.catalogResults = [];
      S.localAi.catalogLoading = false;
      S.localAi.catalogSort = 'trendingScore';
      S.section = 'providers';
      render();
    });

    // --- shared frame: tokens instead of a white overlay -------------------
    const frame = async id => page.evaluate(fieldId => {
      const input = document.getElementById(fieldId);
      const wrapper = input.closest('.search-field');
      const inner = getComputedStyle(input);
      const outer = getComputedStyle(wrapper);
      return {
        wrapperTag: wrapper.tagName,
        wrapperBorder: outer.borderTopWidth + ' ' + outer.borderTopStyle + ' ' + outer.borderTopColor,
        wrapperBackground: outer.backgroundColor,
        innerBorder: inner.borderTopWidth,
        innerOutline: inner.outlineStyle,
        innerShadow: inner.boxShadow,
        appearance: inner.appearance,
        height: outer.height,
      };
    }, id);

    const dark = await frame('models-search');
    assert.equal(dark.wrapperTag, 'DIV', 'the wrapper must be a plain div: a label would forward clear clicks to the input');
    assert.equal(dark.wrapperBorder, '1px solid rgb(58, 58, 62)', 'dark frame must use --border, not transparent');
    assert.equal(dark.wrapperBackground, 'rgb(42, 42, 45)', 'dark fill must use --soft');
    assert.equal(dark.innerBorder, '0px');
    assert.equal(dark.innerOutline, 'none');
    assert.equal(dark.innerShadow, 'none', 'input must not keep its own focus ring');
    assert.equal(dark.appearance, 'none');
    assert.equal(dark.height, '28px');

    // --- light palette: the field is still visible -------------------------
    await page.emulateMedia({ colorScheme: 'light' });
    const light = await page.evaluate(() => {
      const wrapper = document.querySelector('#models-search').closest('.search-field');
      const card = wrapper.closest('.card') || document.querySelector('.card');
      const outer = getComputedStyle(wrapper);
      return {
        border: outer.borderTopColor,
        background: outer.backgroundColor,
        cardBackground: card ? getComputedStyle(card).backgroundColor : '',
      };
    });
    assert.equal(light.border, 'rgb(219, 219, 225)', 'light frame must use the light --border token');
    assert.equal(light.background, 'rgb(240, 240, 244)', 'light fill must use the light --soft token');
    assert.notEqual(light.background, light.cardBackground, 'light fill must not disappear into the card');
    await page.emulateMedia({ colorScheme: 'dark' });

    // --- focus: exactly one ring, on the wrapper ---------------------------
    const focusStyles = await page.evaluate(() => {
      const input = document.getElementById('models-search');
      input.focus({ focusVisible: true });
      const wrapper = input.closest('.search-field');
      const outer = getComputedStyle(wrapper);
      const inner = getComputedStyle(input);
      return {
        border: outer.borderTopColor,
        shadow: outer.boxShadow,
        outline: outer.outlineStyle,
        innerShadow: inner.boxShadow,
        innerOutline: inner.outlineStyle,
        focusVisible: input.matches(':focus-visible'),
      };
    });
    assert.equal(focusStyles.border, GOLD, 'focus must tint the wrapper border');
    assert.equal(focusStyles.focusVisible, true, 'keyboard focus must match :focus-visible in Chromium');
    // The border and this solid shadow merge into one 3px ring. A wrapper
    // outline (or a second ring on the input) would stack a second frame.
    assert.equal(focusStyles.shadow, GOLD + ' 0px 0px 0px 2px', 'focus must add one solid shadow ring');
    assert.equal(focusStyles.outline, 'none', 'focus must not add a separate wrapper outline');
    assert.equal(focusStyles.innerOutline, 'none');
    assert.equal(focusStyles.innerShadow, 'none', 'the input must not draw its own ring');
    await page.evaluate(() => document.activeElement.blur());

    // --- click-to-focus on the glyph and on the padding --------------------
    const clickFocus = async id => {
      const input = page.locator(`#${id}`);
      await input.scrollIntoViewIfNeeded();
      await page.evaluate(() => { document.activeElement.blur(); });
      const icon = input.locator('xpath=preceding-sibling::*[1]');
      const iconBox = await icon.boundingBox();
      await page.mouse.click(iconBox.x + iconBox.width / 2, iconBox.y + iconBox.height / 2);
      const iconFocused = await page.evaluate(fieldId => document.activeElement && document.activeElement.id === fieldId, id);

      await page.evaluate(() => { document.activeElement.blur(); });
      const box = await input.locator('xpath=..').boundingBox();
      await page.mouse.click(box.x + 2, box.y + box.height / 2);
      const paddingFocused = await page.evaluate(fieldId => document.activeElement && document.activeElement.id === fieldId, id);
      return { iconFocused, paddingFocused };
    };
    assert.deepEqual(await clickFocus('models-search'), { iconFocused: true, paddingFocused: true }, 'glyph and padding must focus the input');

    // --- the clear button must not forward a click to the input ------------
    // A <label> wrapper would re-dispatch the click on the clear button to the
    // labelled control. Count clicks on the input during a real mouse click on
    // the button, and check that the query is cleared with focus back in field.
    await page.evaluate(() => {
      window.__searchClicks = { input: 0, clear: 0 };
      const input = document.getElementById('models-search');
      input.addEventListener('click', () => { window.__searchClicks.input += 1; });
      input.closest('.search-field').querySelector('.search-clear')
        .addEventListener('click', () => { window.__searchClicks.clear += 1; });
    });
    const modelsInput = page.locator('#models-search');
    await modelsInput.fill('qwen');
    await page.evaluate(() => { window.__searchClicks = { input: 0, clear: 0 }; });
    const clearButton = page.locator('.search-field .search-clear').first();
    assert.equal(await clearButton.isVisible(), true, 'clear must be visible with a query');
    await clearButton.click();
    await page.waitForTimeout(100);
    const cleared = await page.evaluate(() => ({
      value: document.getElementById('models-search').value,
      focused: document.activeElement && document.activeElement.id,
      hidden: document.getElementById('models-search').closest('.search-field').querySelector('.search-clear').hidden,
      clicks: window.__searchClicks,
    }));
    assert.equal(cleared.value, '');
    assert.equal(cleared.clicks.input, 0, 'a clear click must not be forwarded to the input');
    assert.equal(cleared.clicks.clear, 1, 'the clear button must handle exactly one click');
    assert.equal(cleared.focused, 'models-search', 'clearing must leave focus in the field');
    assert.equal(cleared.hidden, true);

    // --- keyboard: Tab reaches the clear button, Enter clears --------------
    await modelsInput.click();
    await page.keyboard.type('llama');
    await page.keyboard.press('Tab');
    const onClear = await page.evaluate(() => document.activeElement === document.querySelector('.search-field .search-clear'));
    assert.equal(onClear, true, 'Tab must reach the visible clear button');
    const clearFocus = await page.evaluate(() => {
      const style = getComputedStyle(document.querySelector('.search-field .search-clear'));
      return style.outlineStyle + ' ' + style.outlineWidth + ' ' + style.outlineColor;
    });
    assert.equal(clearFocus, 'solid 2px ' + GOLD, 'the clear button keeps its own visible keyboard ring');
    await page.keyboard.press('Enter');
    await page.waitForTimeout(100);
    const keyboardCleared = await page.evaluate(() => ({
      value: document.getElementById('models-search').value,
      focused: document.activeElement && document.activeElement.id,
    }));
    assert.equal(keyboardCleared.value, '', 'Enter on the clear button must clear the query');
    assert.equal(keyboardCleared.focused, 'models-search', 'Enter on clear must return focus to the field');

    // --- native cancel glyph stays suppressed -----------------------------
    // Chromium refuses CSSOM access to file:// stylesheets, so the source is the
    // stable evidence here; the computed input appearance above pins the rest.
    const css = require('node:fs').readFileSync(path.join(UI, 'mt.css'), 'utf8');
    for (const pseudo of ['::-webkit-search-cancel-button', '::-webkit-search-decoration', '::-webkit-search-results-button']) {
      assert.match(css, new RegExp(pseudo.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '[^{]*\\{[^}]*display:\\s*none'), `${pseudo} must be hidden`);
    }

    // --- typing keeps focus and caret; Esc clears without blurring ---------
    const field = page.locator('#models-search');
    await field.click();
    await page.keyboard.type('qwen');
    const typing = await page.evaluate(() => ({
      value: document.getElementById('models-search').value,
      caret: document.getElementById('models-search').selectionStart,
      focused: document.activeElement.id,
      rows: document.querySelectorAll('#provider-model-list .row').length,
      count: document.querySelector('#provider-models-count').textContent,
      clearHidden: document.querySelector('#models-search').closest('.search-field').querySelector('.search-clear').hidden,
    }));
    assert.equal(typing.value, 'qwen');
    assert.equal(typing.caret, 4, 'typing must not move the caret');
    assert.equal(typing.focused, 'models-search', 'typing must not move focus');
    assert.equal(typing.rows, 1, 'qwen must narrow the providers list');
    assert.match(typing.count, /^1 models$/);
    assert.equal(typing.clearHidden, false, 'clear must appear with a query');

    await page.keyboard.press('Escape');
    const escaped = await page.evaluate(() => ({
      value: document.getElementById('models-search').value,
      focused: document.activeElement.id,
      rows: document.querySelectorAll('#provider-model-list .row').length,
      clearHidden: document.querySelector('#models-search').closest('.search-field').querySelector('.search-clear').hidden,
    }));
    assert.equal(escaped.value, '');
    assert.equal(escaped.focused, 'models-search', 'Esc must keep focus in the field');
    assert.equal(escaped.rows, 3);
    assert.equal(escaped.clearHidden, true);

    // --- local AI and Hugging Face use the same component ------------------
    await page.evaluate(() => {
      document.activeElement.blur();
      S.section = 'local_ai';
      S.localAi.tab = 'models';
      render(true);
    });
    assert.equal(await page.locator('#local-ai-search').count(), 1);
    assert.deepEqual(await clickFocus('local-ai-search'), { iconFocused: true, paddingFocused: true });
    await page.locator('#local-ai-search').click();
    await page.keyboard.type('qwen');
    assert.equal(await page.evaluate(() => document.querySelectorAll('#local-ai-model-list .local-ai-card').length), 1);
    await page.keyboard.press('Escape');
    assert.equal(await page.evaluate(() => document.getElementById('local-ai-search').value), '');

    await page.evaluate(() => {
      S.localAi.tab = 'catalog';
      render(true);
    });
    assert.equal(await page.locator('#hf-search').count(), 1);
    assert.deepEqual(await clickFocus('hf-search'), { iconFocused: true, paddingFocused: true });
    await page.locator('#hf-search').click();
    await page.keyboard.type('qwen');
    assert.equal(await page.evaluate(() => document.getElementById('hf-search').value), 'qwen');
    await page.keyboard.press('Escape');
    assert.equal(await page.evaluate(() => document.getElementById('hf-search').value), '');

    await page.evaluate(() => { document.activeElement.blur(); });
    const hfFrame = await frame('hf-search');
    assert.equal(hfFrame.wrapperTag, 'DIV');
    assert.equal(hfFrame.wrapperBorder, '1px solid rgb(58, 58, 62)');

    // --- model-pool dialog: role, focus, trap, Escape ----------------------
    await page.evaluate(() => {
      S.section = 'providers';
      S.pool = {
        models: [
          { slug: 'alpha', display: 'Alpha', selectedCount: 0 },
          { slug: 'beta', display: 'Beta', selectedCount: 0 },
          { slug: 'gamma', display: 'Gamma', selectedCount: 0 },
        ],
        selectedCount: 0,
        accountCount: 0,
      };
      S.poolQuery = '';
      render(true);
    });
    const trigger = page.locator('[data-action="poolOpen"]');
    await trigger.click();
    await page.waitForSelector('#pool-modal');
    const dialog = await page.evaluate(() => {
      const modal = document.getElementById('pool-modal');
      const title = document.getElementById('pool-title');
      return {
        role: modal.getAttribute('role'),
        ariaModal: modal.getAttribute('aria-modal'),
        labelledBy: modal.getAttribute('aria-labelledby'),
        titleId: title && title.id,
        titleText: title && title.textContent.trim(),
        focused: document.activeElement.id,
        fields: modal.querySelectorAll('.search-field').length,
        clears: modal.querySelectorAll('.search-clear').length,
        modalCount: document.querySelectorAll('#pool-modal').length,
      };
    });
    assert.equal(dialog.role, 'dialog');
    assert.equal(dialog.ariaModal, 'true');
    assert.equal(dialog.labelledBy, 'pool-title');
    assert.equal(dialog.titleId, 'pool-title');
    assert.ok(dialog.titleText.length > 0);
    assert.equal(dialog.focused, 'pool-search', 'opening the dialog must focus its search field');
    assert.equal(dialog.fields, 1);
    assert.equal(dialog.clears, 1);
    assert.equal(dialog.modalCount, 1);

    // Tab cycles inside the aria-modal dialog instead of reaching the page.
    const focusable = await page.evaluate(() => {
      const modal = document.getElementById('pool-modal');
      return Array.from(modal.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'))
        .filter(element => element.offsetParent !== null)
        .map(element => element.getAttribute('data-action') || element.id || element.className);
    });
    assert.ok(focusable.length >= 4);
    await page.evaluate(() => {
      const modal = document.getElementById('pool-modal');
      const items = Array.from(modal.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'))
        .filter(element => element.offsetParent !== null);
      items[items.length - 1].focus();
    });
    await page.keyboard.press('Tab');
    assert.equal(await page.evaluate(() => document.activeElement.getAttribute('data-action')), 'poolClose', 'Tab on the last control must wrap to the first');
    await page.keyboard.press('Shift+Tab');
    const lastAction = await page.evaluate(() => document.activeElement.getAttribute('data-action'));
    assert.ok(lastAction && lastAction !== 'poolClose', 'Shift+Tab on the first control must wrap to the last');

    // An empty field lets Esc close the dialog instead of doing nothing.
    await page.evaluate(() => document.getElementById('pool-search').focus());
    await page.keyboard.press('Escape');
    await page.waitForFunction(() => !document.getElementById('pool-modal'));
    assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.getAttribute('data-action')), 'poolOpen', 'closing must return focus to the opener');

    // A non-empty field consumes the first Esc; the next one closes.
    await trigger.click();
    await page.waitForSelector('#pool-modal');
    await page.locator('#pool-search').click();
    await page.keyboard.type('al');
    const poolTyped = await page.evaluate(() => ({
      rows: document.querySelectorAll('#pool-list .pool-row').length,
      focused: document.activeElement.id,
    }));
    assert.equal(poolTyped.rows, 1);
    assert.equal(poolTyped.focused, 'pool-search');
    await page.keyboard.press('Escape');
    assert.equal(await page.evaluate(() => document.getElementById('pool-search').value), '');
    assert.equal(await page.locator('#pool-modal').count(), 1, 'the first Esc must only clear the query');
    await page.keyboard.press('Escape');
    await page.waitForFunction(() => !document.getElementById('pool-modal'));

    // Esc on a dialog button (not the field) closes it too.
    await trigger.click();
    await page.waitForSelector('#pool-modal');
    await page.evaluate(() => document.querySelector('#pool-modal [data-action="poolApply"]').focus());
    await page.keyboard.press('Escape');
    await page.waitForFunction(() => !document.getElementById('pool-modal'));

    // Outside the dialog Esc does nothing and must not throw.
    await page.keyboard.press('Escape');

    // Closing the picker opened from account settings restores focus to that
    // dialog, not to the card underneath it.
    await page.evaluate(() => {
      S.accounts = [{ id: 'acc-1', email: 'a@example.com', displayName: 'A', selectedModels: null }];
      S.accountSettings = null;
      S.section = 'accounts';
      render(true);
      A.accountSettingsOpen('acc-1');
    });
    await page.evaluate(() => {
      const choose = document.querySelector('[data-action="accountSettingsModels"]');
      choose.focus();
      choose.click();
    });
    await page.waitForSelector('#pool-modal');
    assert.equal(await page.evaluate(() => document.activeElement.id), 'pool-search');
    await page.evaluate(() => A.poolClose());
    const back = await page.evaluate(() => ({
      settings: !!document.querySelector('.account-settings-card'),
      modal: !!document.getElementById('pool-modal'),
      focused: document.activeElement.id,
    }));
    assert.equal(back.settings, true, 'the account settings dialog must be back on screen');
    assert.equal(back.modal, false);
    assert.equal(back.focused, 'account-pool-enabled', 'focus must return into the settings dialog');

    if (process.env.SMOKE_SCREENSHOT) await page.screenshot({ path: process.env.SMOKE_SCREENSHOT, fullPage: true });
    assert.deepEqual(errors, [], 'Chromium must have no uncaught page errors');
    console.log('PASS Chromium search fields: 4 surfaces, light/dark frame, click-to-focus, Esc, dialog a11y/trap; mocked API only');
    await context.close();
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
