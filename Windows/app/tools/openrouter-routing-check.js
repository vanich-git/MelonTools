#!/usr/bin/env node
// Exercise the real settings action without starting the Tauri webview.
const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const source = fs.readFileSync(path.resolve(__dirname, "../ui/mt-actions.js"), "utf8");

async function save(config, globalFallback, modelFallback, only = "special") {
  const modelId = "vendor/model";
  const fields = {
    "[data-openrouter-model-strategy]": [{ value: "", dataset: { openrouterModelStrategy: modelId } }],
    "[data-openrouter-model-order]": [{ value: "", dataset: { openrouterModelOrder: modelId } }],
    "[data-openrouter-model-only]": [{ value: only, dataset: { openrouterModelOnly: modelId } }],
    "[data-openrouter-model-ignore]": [{ value: "", dataset: { openrouterModelIgnore: modelId } }],
    "[data-openrouter-model-fallbacks]": [{ value: modelFallback === null ? "" : String(modelFallback), dataset: { openrouterModelFallbacks: modelId } }],
  };
  const sandbox = {
    window: {}, console,
    S: { settings: { openrouterConfig: config }, providerModelsError: {} },
    document: {
      getElementById: id => id === "or-fallbacks" ? { checked: globalFallback } : null,
      querySelectorAll: selector => fields[selector] || [],
    },
    run: (_, fn) => { sandbox.pending = fn(); },
    inv: async (_, payload) => { sandbox.saved = payload.settings; return payload.settings; },
    toast: () => {}, t: key => key,
  };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  sandbox.window.A.saveKeys();
  await sandbox.pending;
  return JSON.parse(JSON.stringify(sandbox.saved.openrouterConfig));
}

(async () => {
  let result = await save({ allowFallbacks: true }, true, null);
  assert.equal(result.modelProviders["vendor/model"].allowFallbacks, null, "new list override must inherit fallback");
  result = await save(result, false, null);
  assert.equal(result.modelProviders["vendor/model"].allowFallbacks, null, "global change must continue to propagate");
  result = await save(result, false, true);
  assert.equal(result.modelProviders["vendor/model"].allowFallbacks, true, "user can explicitly override fallback");
  result = await save(result, true, true);
  assert.equal(result.modelProviders["vendor/model"].allowFallbacks, true, "explicit choice survives matching global value");
  result = await save(result, true, false);
  assert.equal(result.modelProviders["vendor/model"].allowFallbacks, false, "user can explicitly disable fallback");
  result = await save(result, false, null);
  assert.equal(result.modelProviders["vendor/model"].allowFallbacks, null, "default restores inheritance");
  result = await save(result, false, null, "");
  assert.equal(result.modelProviders["vendor/model"], undefined, "empty inherited override is removed");
  const rows = [
    { dataset: { search: "vendor/free free model", free: "true" }, hidden: false },
    { dataset: { search: "vendor/paid paid model", free: "false" }, hidden: false },
    { dataset: { search: "vendor/unknown unknown model", free: "false" }, hidden: false },
  ];
  const checkbox = { checked: true };
  const input = { value: "", focus() {} };
  const ui = {
    window: {}, console, S: {},
    document: {
      querySelectorAll: selector => selector === "[data-openrouter-filter-row]" ? rows : [],
      getElementById: id => id === "openrouter-models-free-only" ? checkbox : input,
    },
    searchClearSync: () => {},
  };
  vm.createContext(ui);
  vm.runInContext(source, ui);
  ui.window.A.openrouterModelsFreeToggle();
  assert.deepEqual(rows.map(row => row.hidden), [false, true, true], "free filter hides paid and unknown prices");
  ui.window.A.openrouterModelsSearch("PAID");
  assert.deepEqual(rows.map(row => row.hidden), [true, true, true], "search and free filter combine");
  checkbox.checked = false;
  ui.window.A.openrouterModelsFreeToggle();
  assert.deepEqual(rows.map(row => row.hidden), [true, false, true], "search remains active after changing free filter");
  ui.window.A.openrouterModelsClearSearch();
  assert.deepEqual(rows.map(row => row.hidden), [false, false, false], "clearing search restores all rows");
  const loadCalls = [];
  const loader = {
    window: {}, console,
    S: { settings: { openrouterKey: "old", openrouterModels: [{ id: "old" }] }, providerModelsError: {} },
    document: { getElementById: id => id === "or-key" ? { value: " new-key " } : null },
    run: (_, fn) => { loader.pending = fn(); },
    inv: async (command, args) => {
      loadCalls.push({ command, args });
      if (command === "settings_set") return args.settings;
      if (command === "provider_models_load") return { models: [{ id: "vendor/free:free" }], count: 1 };
      throw new Error("unexpected command");
    },
    toast: () => {}, t: key => key, errorText: String,
  };
  vm.createContext(loader);
  vm.runInContext(source, loader);
  loader.window.A.loadProviderModels("openrouter");
  await loader.pending;
  assert.deepEqual(loadCalls.map(call => call.command), ["settings_set", "provider_models_load", "settings_set"]);
  assert.equal(loadCalls[0].args.settings.openrouterKey, "new-key");
  assert.equal(loadCalls[1].args.provider, "openrouter");
  assert.equal(loader.S.settings.openrouterModels[0].id, "vendor/free:free");
  const failureCalls = [];
  loader.inv = async (command, args) => {
    failureCalls.push(command);
    if (command === "settings_set") return args.settings;
    throw new Error("OpenRouter unavailable");
  };
  loader.window.A.loadProviderModels("openrouter");
  await assert.rejects(loader.pending, /OpenRouter unavailable/);
  assert.deepEqual(failureCalls, ["settings_set", "provider_models_load"], "failure must not replace the cached catalog");
  assert.match(loader.S.providerModelsError.openrouter, /OpenRouter unavailable/);
  assert.equal(loader.S.settings.openrouterModels[0].id, "vendor/free:free");

  const pages = fs.readFileSync(path.resolve(__dirname, "../ui/mt-pages.js"), "utf8");
  const render = {
    window: {}, console,
    S: { busy: {}, openrouterModelsFreeOnly: true },
    t: key => key,
    esc: value => String(value ?? "").replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;"),
    finiteNumber: value => typeof value === "number" ? value : null,
    formatMoney: value => String(value ?? "-"),
  };
  vm.createContext(render);
  vm.runInContext(pages, render);
  vm.runInContext('historyStrip = () => ""', render);
  const html = render.openRouterCard({
    openrouterConfig: {},
    openrouterModels: [
      { id: "vendor/free:free", display: "Suffix" },
      { id: "vendor/zero", display: "Zero", promptPerToken: 0, completionPerToken: 0 },
      { id: "vendor/unknown", display: "Unknown" },
      { id: "vendor/partial", display: "Partial", promptPerToken: 0 },
      { id: 'vendor/<unsafe>"', display: "Escaped", promptPerToken: 0, completionPerToken: 1 },
    ],
  });
  const markupRows = [...html.matchAll(/<div data-openrouter-filter-row[^>]*>/g)].map(match => match[0]);
  assert.equal(markupRows.length, 5);
  assert.match(markupRows[0], /data-free="true"/);
  assert.match(markupRows[1], /data-free="true"/);
  assert.match(markupRows[2], /data-free="false" hidden/);
  assert.match(markupRows[3], /data-free="false" hidden/);
  assert.match(markupRows[4], /data-free="false" hidden/);
  assert.ok(!html.includes('vendor/<unsafe>"'), "model identifiers are HTML escaped");
  assert.match(html, /aria-label="modelRouting: vendor\/zero"/);
  const inherited = html.match(/<select aria-label="orFallbacks: vendor\/zero"[\s\S]*?<\/select>/)[0];
  assert.match(inherited, /value="" selected/);
  render.S.providerModelsError = { openrouter: '<failed> "catalog"' };
  const errorHTML = render.openRouterCard({ openrouterConfig: {}, openrouterModels: [] });
  assert.ok(errorHTML.includes('&lt;failed&gt; &quot;catalog&quot;'), "catalog errors are visible and escaped");
  const overrideHTML = render.openRouterCard({
    openrouterConfig: { allowFallbacks: true, modelProviders: { "vendor/zero": { allowFallbacks: true } } },
    openrouterModels: [{ id: "vendor/zero", display: "Zero" }],
  });
  const explicit = overrideHTML.match(/<select aria-label="orFallbacks: vendor\/zero"[\s\S]*?<\/select>/)[0];
  assert.match(explicit, /value="true" selected/);
  assert.doesNotMatch(explicit, /value="" selected/);
  console.log("openrouter-routing-check ok");
})().catch(error => { console.error(error); process.exitCode = 1; });
