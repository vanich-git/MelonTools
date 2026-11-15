#!/usr/bin/env node
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const ui = path.resolve(__dirname, '../ui');
let clock = 1000;
let response;
const sandbox = {
  window: {}, S: { lang: 'en', settings: { port: 18317, apiKey: 'gateway-secret' },
    localAi: { models: [{ id: 'local/qwen', displayName: 'Qwen' }], runtime: { isRunning: true, modelId: 'local/qwen', port: 18318, internalToken: 'secret' } } },
  document: { getElementById: () => null },
  performance: { now: () => clock }, AbortController, TextDecoder, setInterval, clearInterval,
  setTimeout, clearTimeout, console, fetch: async (url, options) => {
    if (url.endsWith('/v1/models')) {
      sandbox.catalogueProbes = (sandbox.catalogueProbes || 0) + 1;
      return { ok: true, json: async () => ({ data: sandbox.catalogueProbes < 2 ? [] : [{ id: 'local/qwen' }] }) };
    }
    sandbox.lastRequest = { url, options };
    return response;
  },
  render: () => {}, toast: () => {}, errorText: String, confirm: () => true,
  t: (key) => key, IS_TAURI: false,
};
vm.createContext(sandbox);
for (const name of ['mt-utils.js', 'mt-api.js', 'mt-actions.js', 'mt-pages.js']) {
  vm.runInContext(fs.readFileSync(path.join(ui, name), 'utf8'), sandbox);
}
const run = (code) => vm.runInContext(code, sandbox);
async function main() {
  run('A.localAiTestModal("local/qwen")');
  sandbox.window.api.localAi.runtimeStatus = async () => sandbox.S.localAi.runtime;
  sandbox.window.api.localAi.startModel = async () => {};
  const tm = sandbox.S.localAi.testModal;
  sandbox.chunk = { choices: [{ delta: { reasoning_content: 'private thought' } }] };
  run('localAiTestNote(S.localAi.testModal, chunk, 1000)');
  assert.equal(tm.response, '');
  assert.equal(tm.stats.firstTokenMs, null);
  for (const content of ['<thi', 'nk>secret', '</think>**Final**']) {
    sandbox.chunk = { choices: [{ delta: { content } }] };
    clock += 100;
    run('localAiTestNote(S.localAi.testModal, chunk, 1000)');
  }
  assert.equal(tm.response, '**Final**');
  sandbox.chunk = { choices: [{ finish_reason: 'length' }], usage: { completion_tokens: 20, prompt_tokens: 40 }, timings: { predicted_per_second: 8, predicted_ms: 2500, prompt_per_second: 10 } };
  run('localAiTestNote(S.localAi.testModal, chunk, 1000)');
  assert.equal(tm.stats.tokensPerSec, 8);
  assert.equal(tm.stats.completionTokens, 20);
  assert(tm.truncated);
  assert(run('localAiTestModalMarkup()').includes('<strong>Final</strong>'));
  assert(!run('localAiTestModalMarkup()').includes('private thought'));
  const chunks = ['data: {"choices":[{"delta":{"content":"Привет"}}]}\r', '\ndata: {"usage":{"completion_tokens":7}}'];
  let cancelled = 0;
  response = { ok: true, body: { getReader: () => ({
    read: async () => chunks.length ? { value: new TextEncoder().encode(chunks.shift()), done: false } : { done: true },
    cancel: async () => { cancelled++; }, releaseLock: () => {},
  }) } };
  const received = [];
  await sandbox.window.api.localAi.testRequest({ runtime: sandbox.S.localAi.runtime,
    settings: sandbox.S.settings, gateway: false, body: { stream: true }, onChunk: (chunk) => received.push(chunk) });
  assert.equal(received.length, 2, 'unterminated final SSE line must be consumed');
  assert.equal(cancelled, 1);
  assert(sandbox.lastRequest.url.includes(':18318/'));
  assert.equal(sandbox.lastRequest.options.headers.Authorization, 'Bearer secret');
  response = { ok: false, status: 400, text: async () => '{"error":{"message":"secret sk-abc failure"}}' };
  await assert.rejects(sandbox.window.api.localAi.testRequest({ runtime: sandbox.S.localAi.runtime,
    settings: sandbox.S.settings, gateway: false, body: {} }), /HTTP 400: <redacted> <redacted> failure/);
  response = { ok: true, json: async () => ({ choices: [{ message: { tool_calls: [{ type: 'function', function: { name: 'get_weather', arguments: '{"city":"Paris"}' } }] } }], usage: { completion_tokens: 15 } }) };
  await run('A.localAiTestTool()');
  assert.equal(sandbox.S.localAi.testModal.toolProbe.ok, true);
  assert.equal(sandbox.S.localAi.testModal.stats.completionTokens, 15);
  assert.equal(JSON.parse(sandbox.lastRequest.options.body).tools[0].function.name, 'get_weather');
  sandbox.S.localAi.testModal.mode = 'gateway';
  await run('A.localAiTestTool()');
  assert(sandbox.lastRequest.url.includes(':18317/'));
  assert.equal(sandbox.catalogueProbes, 2, 'gateway request must wait for hot-reloaded model alias');
  assert.equal(sandbox.lastRequest.options.headers.Authorization, 'Bearer gateway-secret');
  response.json = async () => ({ choices: [{ message: { content: 'I can call get_weather' } }] });
  await run('A.localAiTestTool()');
  assert.equal(sandbox.S.localAi.testModal.toolProbe.ok, false, 'prose is not a tool call');
  sandbox.S.models = [{ id: 'local/qwen' }];
  assert(run('localAiConnectionCard()').includes('localAiConnectionsOpen'));
  const bridge = fs.readFileSync(path.join(ui, 'mt-bridge.js'), 'utf8');
  for (const command of ['local_ai_models_list', 'local_ai_runtime_status', 'local_ai_start_model', 'local_ai_stop_runtime']) {
    assert(bridge.includes(`"${command}"`), `${command} must be allowed through the narrow bridge`);
  }
  console.log('local-chat-check ok');
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
