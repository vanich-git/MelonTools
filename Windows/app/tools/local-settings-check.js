#!/usr/bin/env node
// Settings regressions only: no HF, chat or connections coverage here.
const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const ui = path.resolve(__dirname, "../ui");
const model = { id: "local/test", displayName: "Test", fileSize: 1024, userSettings: { contextLength: 8192, flashAttention: true, profile: "auto" } };
let saveError = null;
let saves = 0;
let starts = 0;
let holdSave;
const button = { disabled: false };
const timers = new Map();
let nextTimer = 0;
const estimates = [];
const run = (code) => vm.runInContext(code, sandbox);
function fireEstimateTimer() {
  const [id, callback] = timers.entries().next().value;
  timers.delete(id);
  return callback();
}
const sandbox = {
  S: { lang: "en", localAi: { editingModel: structuredClone(model), models: [model], runtime: { isRunning: true, currentModel: { id: model.id } } } },
  window: { api: { localAi: {
    saveSettings: async () => { saves++; if (holdSave) await holdSave; if (saveError) throw saveError; return model; },
    modelsList: async () => [model], runtimeStatus: async () => ({ isRunning: true }),
    startModel: async () => { starts++; },
    estimateMemory: (params) => new Promise((resolve, reject) => estimates.push({ params, resolve, reject })),
  } } },
  document: { getElementById: () => null, querySelector: () => button },
  render: () => {}, toast: () => {}, errorText: String, t: (key) => key,
  clearTimeout: (id) => timers.delete(id),
  setTimeout: (callback) => { const id = ++nextTimer; timers.set(id, callback); return id; }, console,
};
vm.createContext(sandbox);
for (const name of ["mt-utils.js", "mt-actions.js", "mt-pages.js"]) {
  vm.runInContext(fs.readFileSync(path.join(ui, name), "utf8"), sandbox);
}
async function main() {
  const markup = vm.runInContext("localAiSettingsModalMarkup()", sandbox);
  assert.equal((markup.match(/data-action="localAiSettingsSave"/g) || []).length, 1);
  assert.equal((markup.match(/data-action="localAiSettingsClose"/g) || []).length, 1);
  assert(!markup.includes("localAiSettingsSaveRestart"));
  saveError = new Error("restart failed");
  await vm.runInContext("A.localAiSettingsSave()", sandbox);
  assert(sandbox.S.localAi.editingModel, "restart/save error must keep dialog open");
  assert.equal(sandbox.S.localAi.savingSettings, false);
  assert.equal(button.disabled, false);
  saveError = null;
  let release;
  holdSave = new Promise((resolve) => { release = resolve; });
  const first = vm.runInContext("A.localAiSettingsSave()", sandbox);
  await vm.runInContext("A.localAiSettingsSave()", sandbox);
  vm.runInContext("A.localAiSettingsClose()", sandbox);
  assert(sandbox.S.localAi.editingModel, "cannot close during save");
  assert.equal(saves, 2, "double click must not send another save");
  release();
  await first;
  assert.equal(sandbox.S.localAi.editingModel, null, "success closes dialog");
  assert.equal(starts, 0, "renderer must not independently start/restart models");

  // Deferred IPC + manual debounce timers reproduce same-model races without
  // wall-clock sleeps, including the input-to-request debounce window.
  await run('A.localAiSettingsModal("local/test")');
  const older = fireEstimateTimer();
  sandbox.S.localAi.editingModel.userSettings.contextLength = 4096;
  run('A.localAiEstimateInput()');
  estimates[0].resolve({ totalBytes: 100 });
  await older;
  assert.equal(sandbox.S.localAi.estimate, null, "new input invalidates old success before its debounce fires");
  assert.equal(sandbox.S.localAi.estimating, true, "stale finally cannot clear the new loading state");
  const newest = fireEstimateTimer();
  assert.equal(estimates[1].params.contextLength, 4096);
  estimates[1].resolve({ totalBytes: 200 });
  await newest;
  assert.equal(sandbox.S.localAi.estimate.totalBytes, 200);

  run('A.localAiRefreshEstimate()');
  const lateSuccess = fireEstimateTimer();
  run('A.localAiRefreshEstimate()');
  const earlySuccess = fireEstimateTimer();
  estimates[3].resolve({ totalBytes: 400 });
  await earlySuccess;
  estimates[2].resolve({ totalBytes: 300 });
  await lateSuccess;
  assert.equal(sandbox.S.localAi.estimate.totalBytes, 400, "out-of-order same-model success cannot overwrite newest estimate");

  run('A.localAiRefreshEstimate()');
  const lateFailure = fireEstimateTimer();
  run('A.localAiRefreshEstimate()');
  estimates[4].reject(new Error("obsolete estimate"));
  await lateFailure;
  assert.equal(sandbox.S.localAi.estimateError, null, "stale failure cannot surface an error");
  assert.equal(sandbox.S.localAi.estimating, true, "stale failure finally cannot end newer debounce");
  const beforeClose = fireEstimateTimer();
  run('A.localAiSettingsClose()');
  await run('A.localAiSettingsModal("local/test")');
  estimates[5].resolve({ totalBytes: 500 });
  await beforeClose;
  assert.equal(sandbox.S.localAi.estimate, null, "close/reopen of same id invalidates old estimate");
  assert.equal(sandbox.S.localAi.estimating, true);
  const reopened = fireEstimateTimer();
  estimates[6].resolve({ totalBytes: 600 });
  await reopened;
  assert.equal(sandbox.S.localAi.estimate.totalBytes, 600);
  assert.equal(sandbox.S.localAi.estimating, false);
  run('A.localAiSettingsClose()');
  console.log("local-settings-check ok");
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
