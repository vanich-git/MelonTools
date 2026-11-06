#!/usr/bin/env node
// Regression harness for the Local AI publication contract on the Connections
// and Models screens:
//   * the Connections card shows a publication error instead of hiding it;
//   * the card has its own check that compares the public /v1/models list with
//     the models the registry marks Ready;
//   * start/stop refresh the Models page, because the gateway catalogue is the
//     only source that page renders;
//   * the connection diagnostics and the API check include Local AI.
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const ui = path.resolve(__dirname, '../ui');

const calls = [];
let gatewayModels = [];
let localModels = [];
let runtimeStatus = { isRunning: true, modelId: 'local/qwen', publicationError: null };

const sandbox = {
  window: {},
  NAV: [],
  S: {
    lang: 'en',
    section: 'providers',
    busy: {},
    settings: { port: 18317, apiKey: 'gateway-secret' },
    localAi: { models: [], runtime: {} },
    models: [],
  },
  document: {
    getElementById: () => null,
    querySelector: () => null,
    addEventListener: () => {},
    activeElement: null,
  },
  render: () => {},
  toast: () => {},
  errorText: String,
  t: (key) => key,
  confirm: () => true,
  setInterval,
  clearInterval,
  setTimeout,
  clearTimeout,
  console,
  // Collect the background promises `run()` starts so the harness can wait on
  // the real work instead of sleeping for a guessed number of milliseconds.
  pendingRuns: [],
  run(action, fn) {
    const pending = Promise.resolve().then(fn);
    sandbox.pendingRuns.push(pending);
    return pending;
  },
  IS_TAURI: false,
};
vm.createContext(sandbox);
for (const name of ['mt-utils.js', 'mt-i18n.js', 'mt-api.js', 'mt-actions.js', 'mt-pages.js', 'mt-redesign-actions.js']) {
  vm.runInContext(fs.readFileSync(path.join(ui, name), 'utf8'), sandbox);
}
const run = (code) => vm.runInContext(code, sandbox);
// `inv` is a function declaration in mt-api.js, so it must be replaced after
// the scripts load; assigning it inside the sandbox literal would be shadowed.
sandbox.inv = async (command) => {
  calls.push(command);
  switch (command) {
    case 'gateway_models': return gatewayModels;
    case 'gateway_check': return JSON.stringify({ model: 'gpt-5' });
    case 'gateway_status': return { running: true, port: 18317 };
    case 'settings_get': return sandbox.S.settings;
    case 'vault_list': return [];
    case 'local_ai_runtime_status': return runtimeStatus;
    case 'local_ai_models_list': return localModels;
    case 'vercel_refresh': return null;
    default: return {};
  }
};
const api = sandbox.window.api;
api.localAi.modelsList = async () => localModels;
api.localAi.runtimeStatus = async () => runtimeStatus;
api.localAi.startModel = async () => {};
api.localAi.stopRuntime = async () => {};

async function main() {
  // 1. A Ready model missing from the public catalogue is a failure, not an
  // empty success.
  localModels = [{ id: 'local/qwen', runtimeStatus: 'ready', displayName: 'Qwen' }];
  runtimeStatus = { isRunning: true, modelId: 'local/qwen', publicationError: null };
  gatewayModels = [];
  sandbox.S.localAi.connectionCheck = null;
  await run('A.localAiConnectionsCheck()');
  let check = sandbox.S.localAi.connectionCheck;
  assert(check, 'the Connections check must produce a verdict');
  assert.equal(check.ok, false, 'a Ready model missing from /v1/models must fail the check');
  assert.match(check.text, /missing from the API/, 'the verdict must name the missing model');

  // 2. The same model in the catalogue passes.
  gatewayModels = [{ id: 'local/qwen' }];
  await run('A.localAiConnectionsCheck()');
  check = sandbox.S.localAi.connectionCheck;
  assert.equal(check.ok, true, 'a published Ready model must pass the check');
  assert.match(check.text, /Local AI: published local\/qwen/);

  // 3. A stopped engine with a stale catalogue entry is a failure.
  localModels = [];
  runtimeStatus = { isRunning: false, publicationError: null };
  gatewayModels = [{ id: 'local/qwen' }];
  await run('A.localAiConnectionsCheck()');
  check = sandbox.S.localAi.connectionCheck;
  assert.equal(check.ok, false, 'a stopped engine must not leave a callable local alias');
  assert.match(check.text, /stopped models still in the API/);

  // 4. The runtime's publication error reaches the card verbatim.
  sandbox.S.localAi.runtime = { isRunning: true, publicationError: 'gateway did not publish local/qwen' };
  sandbox.S.localAi.connectionCheck = null;
  const card = run('localAiConnectionCard()');
  assert(card.includes('gateway did not publish local/qwen'), 'the card must render publicationError');
  assert(card.includes('data-action="localAiConnectionsCheck"'), 'the card must expose the check action');

  // 5. Starting and stopping a model refreshes the public catalogue view.
  let loads = 0;
  run('A.modelsLoad = async () => { globalThis.__loads = (globalThis.__loads || 0) + 1; }');
  sandbox.S.localAi.runtime = { binaryPath: 'llama-server.exe' };
  runtimeStatus = { isRunning: true, modelId: 'local/qwen', binaryPath: 'llama-server.exe' };
  await run('A.localAiStart("local/qwen")');
  await run('A.localAiStop()');
  loads = run('globalThis.__loads');
  assert.equal(loads, 2, 'start and stop must each reload the Models page');

  // 6. Connection diagnostics include Local AI with the served count.
  localModels = [{ id: 'local/qwen', runtimeStatus: 'ready' }];
  runtimeStatus = { isRunning: true, publicationError: null };
  gatewayModels = [{ id: 'local/qwen' }];
  await run('A.diagRun()');
  const rows = (sandbox.S.diag && sandbox.S.diag.rows) || [];
  const localRow = rows.find((row) => row.name === 'Local AI');
  assert(localRow, 'the connection diagnostics must include a Local AI row');
  assert.equal(localRow.models.text, '1', 'the Local AI row must count served local/* models');

  // 7. The API check reports the local catalogue as well.
  gatewayModels = [];
  sandbox.S.checkPassed = true;
  await run('A.checkApi()');
  // `checkApi` returns before its run() finishes; drain the collected work.
  await Promise.all(sandbox.pendingRuns.splice(0));
  assert.equal(sandbox.S.checkPassed, false, 'the API check must fail when a Ready model is not published');
  assert.match(String(sandbox.S.checkResult), /missing from the API/);

  // 8. A publicationError means the last publication failed even when the
  // alias is currently visible; neither check may report a pass.
  localModels = [{ id: 'local/qwen', runtimeStatus: 'ready' }];
  runtimeStatus = { isRunning: true, publicationError: 'the gateway config could not be written: disk full' };
  gatewayModels = [{ id: 'local/qwen' }];
  sandbox.S.localAi.connectionCheck = null;
  await run('A.localAiConnectionsCheck()');
  check = sandbox.S.localAi.connectionCheck;
  assert.equal(check.ok, false, 'publicationError must fail the card check even with the alias present');
  assert.match(check.text, /disk full/, 'the verdict must carry the publication error');
  sandbox.S.checkPassed = true;
  await run('A.checkApi()');
  await Promise.all(sandbox.pendingRuns.splice(0));
  assert.equal(sandbox.S.checkPassed, false, 'publicationError must fail the API check');
  assert.match(String(sandbox.S.checkErrorDetail), /disk full/);

  // 9. A running engine that still advertises an alias no Ready row backs is a
  // failure: clients can call it and get a 404.
  runtimeStatus = { isRunning: true, publicationError: null };
  gatewayModels = [{ id: 'local/qwen' }, { id: 'local/stale' }];
  await run('A.localAiConnectionsCheck()');
  check = sandbox.S.localAi.connectionCheck;
  assert.equal(check.ok, false, 'stale served aliases must fail the card check');
  assert.match(check.text, /stopped models still in the API/);
  sandbox.S.checkPassed = true;
  await run('A.checkApi()');
  await Promise.all(sandbox.pendingRuns.splice(0));
  assert.equal(sandbox.S.checkPassed, false, 'stale served aliases must fail the API check');
  assert.match(String(sandbox.S.checkErrorDetail), /stopped models still in the API/);

  // 10. A local IPC failure is not a pass: the app cannot read its own state.
  api.localAi.runtimeStatus = async () => { throw new Error('ipc unavailable'); };
  sandbox.S.localAi.connectionCheck = null;
  await run('A.localAiConnectionsCheck()');
  check = sandbox.S.localAi.connectionCheck;
  assert.equal(check.ok, false, 'an IPC failure must not pass the card check');
  assert.match(check.text, /ipc unavailable/);
  sandbox.S.checkPassed = true;
  await run('A.checkApi()');
  await Promise.all(sandbox.pendingRuns.splice(0));
  assert.equal(sandbox.S.checkPassed, false, 'an IPC failure must not pass the API check');
  assert.match(String(sandbox.S.checkErrorDetail), /ipc unavailable/);
  api.localAi.runtimeStatus = async () => runtimeStatus;

  // 11. The bridge still allows every command these screens use.
  const bridge = fs.readFileSync(path.join(ui, 'mt-bridge.js'), 'utf8');
  for (const command of ['local_ai_models_list', 'local_ai_runtime_status', 'gateway_models']) {
    assert(bridge.includes(`"${command}"`), `${command} must be allowed through the narrow bridge`);
  }
  console.log('local-connections-check ok');
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
