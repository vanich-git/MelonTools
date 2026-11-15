#!/usr/bin/env node
// Codex manual pool participation: render, settings IPC and quota preflight.
const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const ui = path.resolve(__dirname, "../ui");
const source = (name) => fs.readFileSync(path.join(ui, name), "utf8");
const calls = [];
const controls = {
  "account-res-h": { value: "5" }, "account-res-w": { value: "5" },
  "account-res-h-enabled": { checked: true }, "account-res-w-enabled": { checked: false },
  "account-preferred": { checked: true }, "account-backup": { checked: false },
  "account-pool-enabled": { checked: false },
};
for (const control of Object.values(controls)) control.closest = () => null;
const sandbox = {
  S: { lang: "en", accounts: [], busy: {}, routing: {}, settings: {} },
  DICT: { ru: {}, en: {} }, NAV: [], A: { go() {}, onboardingGo() {} }, IS_TAURI: false,
  window: {}, document: { getElementById: (id) => controls[id] || null, querySelector: () => null },
  render() {}, toast() {}, errorText: String, console, setTimeout,
  t: (key) => sandbox.DICT.en[key] || key,
  historyStrip: () => "history-kept", ageText: () => "now", round: String,
  quotaTint: () => "ok", resetText: () => "reset", resetCountLabel: String,
  inv: async (command, args) => {
    calls.push([command, args]);
    return command === "save_reserves" ? sandbox.S.accounts : { accounts: sandbox.S.accounts };
  },
};
sandbox.run = (_key, callback) => { sandbox.pending = callback(); return sandbox.pending; };
vm.createContext(sandbox);
vm.runInContext(source("mt-utils.js"), sandbox);
// app.js boots the real application at top level; evaluate its pure functions only.
const app = source("app.js");
const preflight = app.slice(app.indexOf("function percentLabel("), app.indexOf("function poolPauseWindows("));
vm.runInContext(preflight, sandbox);
vm.runInContext(app.slice(app.indexOf("function historySamples("), app.indexOf("// MARK: - Dashboard 2.0")), sandbox);
sandbox.S.history = [{ key: "disabled", hourlyLeft: 72, weeklyLeft: 88 }];
vm.runInContext(source("mt-redesign.js"), sandbox);
vm.runInContext(source("mt-redesign-actions.js"), sandbox);
const disabled = {
  id: "disabled", email: "kept@example.invalid", poolEnabled: false,
  blocked: true, blockInfo: { code: "manual_disabled" },
  hourlyRemaining: 72, weeklyRemaining: 88, quotaUpdatedAt: 123,
};
const paused = { id: "quota", blocked: true, blockInfo: { code: "hourly_reserve", remaining: 5, limit: 5 }, hourlyRemaining: 5 };
sandbox.S.accounts = [disabled, paused];
sandbox.S.routing = { orderedIds: ["quota"], blockedIds: ["quota"] };
sandbox.S.accountSettings = "disabled";
const evaluate = (code) => vm.runInContext(code, sandbox);
const card = evaluate("accountCard(S.accounts[0])");
assert(card.includes("account-pool-disabled"));
for (const text of ["kept@example.invalid", "72", "88", "account-history", 'data-action="refreshQuota"', 'data-action="accountSettingsOpen"']) assert(card.includes(text), text);
const modal = evaluate("accountSettingsModal()");
assert(modal.includes('role="switch" id="account-pool-enabled"'));
assert(!/id="account-pool-enabled" checked/.test(modal));
assert.equal(evaluate("orderingState().ordered.length"), 2, "excluded account must remain listed");
assert(!evaluate("priorityList()").includes("kept@example.invalid"), "excluded account is not a routing candidate");
assert.equal(evaluate("quotaTotals(S.accounts, 'hourlyRemaining').total"), 5);
assert.equal(evaluate("poolPauseState().blocks.length"), 1);
sandbox.S.accounts = [disabled];
assert.equal(evaluate("poolPauseState()"), null, "manual exclusion never offers automatic/reserve resume");
sandbox.S.accounts = [{ id: "legacy" }];
sandbox.S.accountSettings = "legacy";
assert(/id="account-pool-enabled"[^>]* checked/.test(evaluate("accountSettingsModal()")));
async function main() {
  evaluate("A.accountSettingsSave('legacy')");
  await sandbox.pending;
  assert.equal(calls[0][0], "save_reserves");
  assert.equal(calls[0][1].poolEnabled, false);
  assert.equal(calls[0][1].hourly, 5);
  controls["account-pool-enabled"].checked = true;
  sandbox.S.accountSettings = "legacy";
  evaluate("A.accountSettingsSave('legacy')");
  await sandbox.pending;
  assert.equal(calls[2][1].poolEnabled, true);
  assert.equal(sandbox.S.accountSettings, null);
  const preview = { window: {}, S: { lang: "en" }, console };
  vm.createContext(preview);
  vm.runInContext(source("mt-api.js"), preview);
  await vm.runInContext("mock('save_reserves', {id:'demo-1',poolEnabled:false})", preview);
  assert.equal((await vm.runInContext("mock('vault_list', {})", preview)).find(a => a.id === "demo-1").poolEnabled, false);
  assert.equal((await vm.runInContext("mock('set_account_role', {})", preview)).accounts.find(a => a.id === "demo-1").poolEnabled, false);
  await vm.runInContext("mock('save_reserves', {id:'demo-1',poolEnabled:true})", preview);
  assert.equal((await vm.runInContext("mock('vault_list', {})", preview)).find(a => a.id === "demo-1").blocked, false);
  // routing_state does not contain accounts: polling must read both IPCs.
  sandbox.IS_TAURI = true;
  sandbox.S.section = "accounts";
  sandbox.onboardingVisible = () => false;
  sandbox.editsInProgress = () => false;
  sandbox.renderFooter = () => {};
  sandbox.invTimed = async (command) => command === "vault_list"
    ? [{ id: "fresh", hourlyRemaining: 91 }]
    : command === "routing_state" ? { orderedIds: ["fresh"], blockedIds: [] } : {};
  await evaluate("A.refreshStatus()");
  assert.equal(sandbox.S.accounts[0].id, "fresh");
  assert.equal(sandbox.S.routing.orderedIds[0], "fresh");
  console.log("account-pool-check ok");
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
