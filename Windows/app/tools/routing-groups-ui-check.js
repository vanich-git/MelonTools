#!/usr/bin/env node
// Routing groups: saving and applying are separate steps. A saved group must
// stay saved when gateway_sync fails, the sync error must stay visible, and a
// read error from the backend must be shown instead of an empty list.
const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const ui = path.resolve(__dirname, "../ui");
const source = (name) => fs.readFileSync(path.join(ui, name), "utf8");

const controls = {};
const toasts = [];
const calls = [];
let renders = 0;

const group = (id, alias, members) => ({ id, alias, note: "", enabled: true, members });

const sandbox = {
  window: { confirm: () => true },
  console,
  S: {
    lang: "en",
    section: "routing",
    busy: {},
    routingGroups: null,
    routingGroupLoaded: false,
    routingGroupDraft: null,
    routingGroupError: null,
    routingGroupApplyError: null,
  },
  document: { getElementById: (id) => controls[id] || null },
  render() { renders += 1; },
  toast(message, isError) { toasts.push({ message: String(message), isError: !!isError }); },
  inv: async (command, args) => {
    calls.push({ command, args });
    return invImpl(command, args);
  },
};

let invImpl = async () => ({});
const evaluate = (code) => vm.runInContext(code, sandbox);
const lastToast = () => toasts[toasts.length - 1];
const syncCalls = () => calls.filter((call) => call.command === "gateway_sync").length;

vm.createContext(sandbox);
vm.runInContext(source("mt-i18n.js"), sandbox);
vm.runInContext(source("mt-utils.js"), sandbox);
vm.runInContext(source("mt-actions.js"), sandbox);
vm.runInContext(source("mt-pages.js"), sandbox);

async function main() {
  // A saved settings response can contain a publication warning. It must
  // survive unrelated successful commands until an explicit sync succeeds.
  const apiState = { gatewayConfigWarning: null };
  let apiReply = {};
  const api = { S: apiState, window: { melon: { available: true, invoke: async () => apiReply } } };
  vm.createContext(api);
  vm.runInContext(source("mt-api.js"), api);
  apiReply = { configWarning: "<write failed>" };
  await vm.runInContext('inv("settings_set")', api);
  assert.equal(apiState.gatewayConfigWarning, "<write failed>");
  apiReply = {};
  await vm.runInContext('inv("settings_get")', api);
  assert.equal(apiState.gatewayConfigWarning, "<write failed>");
  apiReply = { gatewayRunning: false };
  await vm.runInContext('inv("gateway_sync")', api);
  assert.equal(apiState.gatewayConfigWarning, "<write failed>", "a stopped gateway does not sync auth files");
  apiReply = { gatewayRunning: true };
  await vm.runInContext('inv("gateway_sync")', api);
  assert.equal(apiState.gatewayConfigWarning, null);
  sandbox.S.gatewayConfigWarning = "failed";
  evaluate("A.dismissGatewayConfigWarning()");
  assert.equal(sandbox.S.gatewayConfigWarning, null);
  assert(source("app.js").includes('esc(S.gatewayConfigWarning)'), "warning text must be escaped");
  invImpl = async () => ({ saved: true, configWarning: "auth sync failed" });
  const beforeWarningToast = toasts.length;
  await evaluate('A.routingTuning({ requestRetry: 1 })');
  assert.equal(toasts.length, beforeWarningToast, "a partial save must not show a success toast");

  // 1. The backend can answer with a read error and an empty list. The list
  //    is unknown in that case: the error is shown and "no groups" is hidden.
  invImpl = async (command) => command === "routing_groups"
    ? { groups: [], sources: [], path: "routing-groups.json", error: "access denied" }
    : {};
  await evaluate("A.routingGroupsLoad(true)");
  assert.equal(sandbox.S.routingGroupError, "access denied", "read error is kept in state");
  let card = evaluate("groupsCard()");
  assert(card.includes('id="group-read-error"'), "read error is rendered");
  assert(card.includes("access denied"), "read error text is rendered");
  assert(card.includes('data-action="routingGroupsRetry"'), "read error provides a retry action");
  assert(!card.includes("No model groups yet"), "an unreadable list is not shown as empty");

  // 2. A later successful read clears the error and renders the groups.
  invImpl = async (command) => command === "routing_groups"
    ? {
        groups: [group("g1", "smart", [{ sourceId: "opencode", modelId: "gpt-5" }])],
        sources: [{ id: "opencode", title: "OpenCode", models: [{ id: "gpt-5", title: "gpt-5" }] }],
        path: "routing-groups.json",
      }
    : {};
  await evaluate("A.routingGroupsRetry()");
  assert.equal(sandbox.S.routingGroupError, null, "a good read clears the read error");
  card = evaluate("groupsCard()");
  assert(card.includes("smart"), "groups are rendered");
  assert(!card.includes("group-read-error"), "read error banner is gone");

  // Unavailable members remain visible and can be removed explicitly.
  sandbox.S.routingGroupDraft = { alias: "saved", members: [{ sourceId: "gone", modelId: "old-model" }] };
  const missingEditor = evaluate("groupEditorModal()");
  assert(missingEditor.includes("gone/old-model"), "missing member remains visible");
  evaluate('A.groupMember({ checked: false, dataset: { source: "gone", model: "old-model" } })');
  assert.equal(sandbox.S.routingGroupDraft.members.length, 0, "missing member can be removed explicitly");

  // 3. Any models can share one group: two models of one provider plus a
  //    model of another provider all reach the backend untouched.
  const mixed = [
    { sourceId: "opencode", modelId: "gpt-5" },
    { sourceId: "opencode", modelId: "claude-sonnet-4-6" },
    { sourceId: "zai", modelId: "glm-5.3" },
  ];
  sandbox.S.routingGroupDraft = { id: "", alias: "", note: "", enabled: true, members: [] };
  for (const member of mixed) {
    evaluate(`A.groupMember({ checked: true, dataset: { source: ${JSON.stringify(member.sourceId)}, model: ${JSON.stringify(member.modelId)} } })`);
  }
  assert.deepEqual(
    JSON.parse(JSON.stringify(sandbox.S.routingGroupDraft.members)),
    mixed,
    "the editor accepts different models and different providers in one group",
  );

  // 4. Save succeeds, apply fails: the group stays stored and closed, and the
  //    failure is reported as an apply failure, not as a save failure.
  controls["group-alias"] = { value: "mixed" };
  controls["group-note"] = { value: "note" };
  sandbox.S.routingGroupDraft.alias = "";
  sandbox.S.routingGroupDraft.note = "";
  const saved = group("g2", "mixed", mixed);
  invImpl = async (command, args) => {
    if (command === "routing_group_save") return { groups: [saved] };
    if (command === "gateway_sync") throw new Error("gateway offline");
    return {};
  };
  toasts.length = 0;
  await evaluate("A.groupSave()");
  const saveCall = calls.filter((call) => call.command === "routing_group_save").pop();
  assert.deepEqual(
    JSON.parse(JSON.stringify(saveCall.args.group.members)),
    mixed,
    "every chosen model is sent to the backend",
  );
  assert.equal(sandbox.S.routingGroupDraft, null, "a stored group closes the editor");
  assert.equal(sandbox.S.routingGroups.groups[0].id, "g2", "the stored group stays in the list");
  assert.equal(sandbox.S.routingGroupApplyError, "gateway offline", "apply error is kept in state");
  assert.equal(lastToast().isError, true, "the apply failure is an error");
  assert.match(lastToast().message, /Group saved/, "the toast still says the group was saved");
  assert.match(lastToast().message, /Could not write the gateway config/, "the toast names the config write step");
  card = evaluate("groupsCard()");
  assert(card.includes('id="group-apply-error"'), "apply error stays on the card");
  assert(card.includes("mixed"), "the saved group is visible next to the error");

  // 5. Save itself fails: nothing is applied and the typed values survive.
  sandbox.S.routingGroupApplyError = null;
  sandbox.S.routingGroupDraft = { id: "", alias: "", note: "", enabled: true, members: mixed.slice(0, 1) };
  controls["group-alias"] = { value: "bad alias" };
  controls["group-note"] = { value: "kept note" };
  const before = syncCalls();
  invImpl = async (command) => {
    if (command === "routing_group_save") throw new Error("aliasChars");
    return {};
  };
  toasts.length = 0;
  await evaluate("A.groupSave()");
  assert.notEqual(sandbox.S.routingGroupDraft, null, "a failed save keeps the editor open");
  assert.equal(sandbox.S.routingGroupDraft.alias, "bad alias", "the typed alias survives the failure");
  assert.equal(sandbox.S.routingGroupDraft.note, "kept note", "the typed note survives the failure");
  assert.equal(syncCalls(), before, "a failed save does not touch the engine");
  assert.equal(lastToast().isError, true, "the save failure is an error");

  // 5b. The backend reports an over-long alias as aliasTooLong; the UI
  //     localizes the code instead of showing it raw.
  invImpl = async (command) => {
    if (command === "routing_group_save") throw new Error("aliasTooLong");
    return {};
  };
  toasts.length = 0;
  await evaluate("A.groupSave()");
  assert.match(lastToast().message, /longer than 64 characters/, "aliasTooLong is localized");
  assert.doesNotMatch(lastToast().message, /aliasTooLong/, "the raw code is not shown");

  // 6. Toggle is stored, apply fails: the switch keeps the new state.
  sandbox.S.routingGroupApplyError = null;
  invImpl = async (command) => {
    if (command === "routing_group_toggle") {
      return { groups: [Object.assign({}, saved, { enabled: true })] };
    }
    if (command === "gateway_sync") throw new Error("engine down");
    return {};
  };
  const offSwitch = { dataset: { id: "g2" }, checked: true, disabled: false };
  toasts.length = 0;
  sandbox.__switch = offSwitch;
  await evaluate("A.groupToggle(__switch)");
  assert.equal(sandbox.__switch.checked, true, "a failed apply does not roll the switch back");
  assert.equal(sandbox.S.routingGroupApplyError, "engine down", "the toggle apply error is kept");
  assert.equal(lastToast().isError, true, "the toggle apply failure is an error");

  // 7. Toggle itself fails: the switch is rolled back and the engine is not
  //    touched.
  invImpl = async (command) => {
    if (command === "routing_group_toggle") throw new Error("write failed");
    throw new Error("unexpected " + command);
  };
  const onSwitch = { dataset: { id: "g2" }, checked: true, disabled: false };
  sandbox.__switch = onSwitch;
  const syncBefore = syncCalls();
  await evaluate("A.groupToggle(__switch)");
  assert.equal(sandbox.__switch.checked, false, "a failed toggle rolls the switch back");
  assert.equal(syncCalls(), syncBefore, "a failed toggle does not apply anything");

  // 8. Delete is stored, apply fails: the group is gone and the error remains.
  sandbox.S.routingGroupApplyError = null;
  sandbox.S.routingGroups = { groups: [saved], sources: [] };
  invImpl = async (command) => {
    if (command === "routing_group_delete") return { groups: [] };
    if (command === "gateway_sync") throw new Error("engine down");
    return {};
  };
  toasts.length = 0;
  await evaluate("A.groupDelete('g2')");
  assert.equal(sandbox.S.routingGroups.groups.length, 0, "a stored delete removes the group");
  assert.equal(sandbox.S.routingGroupApplyError, "engine down", "the delete apply error is kept");
  assert.match(lastToast().message, /Group deleted/, "the toast still says the group was deleted");
  assert.match(lastToast().message, /Could not write the gateway config/, "the toast names the config write step");

  // 9. A later successful sync (the Apply button) clears the pending error.
  invImpl = async (command) => command === "gateway_sync" ? { syncedAccounts: 2 } : {};
  const failure = await evaluate("applyRoutingGroups()");
  assert.equal(failure, null, "a successful apply returns no failure");
  assert.equal(sandbox.S.routingGroupApplyError, null, "a successful apply clears the error");
  assert(!evaluate("groupsCard()").includes("group-apply-error"), "the card no longer shows the error");

  assert(renders > 0, "the page re-renders after group actions");
  console.log("routing-groups-ui-check ok");
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
