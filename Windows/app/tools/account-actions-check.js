#!/usr/bin/env node
// Mac parity: per-account Launch opens the shared gateway, never direct auth.
const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const disabled = { id: "excluded", poolEnabled: false, current: false };
const enabled = { id: "active", poolEnabled: true, current: true };
const sandbox = { S: { accounts: [disabled, enabled] }, window: {}, console };
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.resolve(__dirname, "../ui/mt-actions.js"), "utf8"), sandbox);
vm.runInContext(`
  let launches = 0;
  const launchResult = Promise.resolve("opened");
  A.codexOpen = () => { launches++; return launchResult; };
`, sandbox);
const before = JSON.stringify(sandbox.S.accounts);
assert.equal(vm.runInContext("A.launchAccountInCodex('excluded') === launchResult", sandbox), true);
assert.equal(vm.runInContext("A.launchAccountInCodex('active') === launchResult", sandbox), true);
assert.equal(vm.runInContext("launches", sandbox), 2);
assert.equal(JSON.stringify(sandbox.S.accounts), before, "launch cannot mutate membership/current login");
assert.equal(vm.runInContext("A.launchAccountInCodex('removed')", sandbox), undefined);
assert.equal(vm.runInContext("launches", sandbox), 2, "stale card must not launch another account");
vm.runInContext("A.codexOpen = () => { throw new Error('launch failed'); }", sandbox);
assert.throws(() => vm.runInContext("A.launchAccountInCodex('excluded')", sandbox), /launch failed/);
assert.equal(JSON.stringify(sandbox.S.accounts), before);
console.log("account-actions-check ok");
