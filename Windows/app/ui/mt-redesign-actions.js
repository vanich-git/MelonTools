// Melon Tools — 3.0.0 Windows redesign actions.
// Loaded after app.js. Extends the 2.4.4 action table with the Codex app
// launch flow and replaces the periodic status render with a change-aware one.

// A compact fingerprint of data that the dashboard/API/accounts renderers use.
// The 5-second poll must not rebuild an unchanged page: that detaches buttons
// mid-click and resets the reader's scroll position.
function statusSignature() {
  const status = S.status || {};
  const bridge = S.bridge || {};
  const accounts = (S.accounts || []).map((account) => [
    account.id, account.current, account.blocked,
    account.hourlyRemaining, account.weeklyRemaining,
    account.hourlyResetAt, account.weeklyResetAt, account.quotaUpdatedAt,
    account.preferredFirst, account.isBackup, account.poolEnabled,
    account.resetCreditsAvailable, account.resetCreditsNextExpiry,
    account.displayName, account.email, account.planType, account.subscriptionActiveUntil,
    account.hourlyReservePercent, account.weeklyReservePercent,
    account.quotaSource, account.quotaError, account.modelAvailability, account.selectedModels,
    account.creditsBalance, account.unlimitedCredits, account.blockInfo,
  ]);
  return JSON.stringify([
    status.running, status.port, status.requestsLastMinute,
    status.sidecarFound, status.schemaError,
    bridge.attached, bridge.debugPort, bridge.reason, bridge.model,
    accounts,
    S.schedulerSummary && S.schedulerSummary.tasks,
    S.route && [S.route.provider, S.route.ours],
    S.codexApp && [
      S.codexApp.found, S.codexApp.running,
      S.codexApp.path, S.codexApp.savedPathValid,
    ],
    S.checkResult, S.checkPassed,
    S.routing && [S.routing.strategy, S.routing.orderedIds, S.routing.blockedIds],
  ]);
}

// Replace the old flat navigation with the macOS group order.
NAV.splice(0, NAV.length,
  { group: "overview", items: ["dashboard"] },
  { group: "schedulerGroup", items: ["scheduler"] },
  { group: "local_ai", items: ["local_ai"] },
  { group: "codex", items: ["accounts", "api", "providers", "composer", "instances"] },
  { group: "general", items: ["settings", "donate"] },
);

const baseRender = render;
const baseGo = A.go;
const baseOnboardingGo = A.onboardingGo;

// Preserve the scroll position across background refreshes. Navigation resets
// it explicitly in A.go below.
render = function renderWithScroll(force) {
  const detail = document.querySelector(".detail");
  const scrollTop = detail ? detail.scrollTop : 0;
  // The Console is its own scroller: a full render must not throw the reader
  // back to the first line, and a reader parked at the bottom keeps following
  // the newest output.
  const logBox = document.getElementById("local-ai-logs");
  const logTop = logBox ? logBox.scrollTop : 0;
  const logAtBottom = logBox
    ? logBox.scrollHeight - logBox.scrollTop - logBox.clientHeight <= 24
    : true;
  const hfScroll = ["hf-results", "hf-detail"].map(id => {
    const element = document.getElementById(id);
    return [id, element ? element.scrollTop : 0];
  });
  const hfInput = document.getElementById("hf-search");
  const hfFocus = hfInput && document.activeElement === hfInput
    ? [hfInput.selectionStart, hfInput.selectionEnd] : null;
  baseRender(force);
  for (const [id, top] of hfScroll) {
    const element = document.getElementById(id);
    if (element) element.scrollTop = top;
  }
  const nextHfInput = document.getElementById("hf-search");
  if (hfFocus && nextHfInput) {
    nextHfInput.focus();
    nextHfInput.setSelectionRange(hfFocus[0], hfFocus[1]);
  }
  if (detail) detail.scrollTop = scrollTop;
  const nextLog = document.getElementById("local-ai-logs");
  if (nextLog) nextLog.scrollTop = logAtBottom ? nextLog.scrollHeight : logTop;
  S.lastStatusSignature = statusSignature();
  const brand = document.getElementById("brand-sub");
  if (brand) brand.textContent = t("brandSub");
  if ((S.section === "api" || S.section === "accounts")
      && !S.codexApp && !S.codexAppError) {
    A.codexAppLoad();
  }
};

A.go = function go(section) {
  S.accountSettings = null;
  S.proxyUrlDraft = null;
  baseGo.call(A, section);
  const detail = document.querySelector(".detail");
  if (detail) detail.scrollTop = 0;
};

A.onboardingGo = function onboardingGo(section) {
  S.accountSettings = null;
  S.proxyUrlDraft = null;
  baseOnboardingGo.call(A, section);
  const detail = document.querySelector(".detail");
  if (detail) detail.scrollTop = 0;
};

Object.assign(A, {
  async refreshStatus() {
    if (onboardingVisible()) return;
    const timeout = 5000;
    const jobs = [
      invTimed("gateway_status", {}, timeout),
      invTimed("bridge_status", {}, timeout),
    ];
    const wantAccounts = IS_TAURI && (S.section === "dashboard" || S.section === "accounts");
    if (wantAccounts) jobs.push(invTimed("vault_list", {}, timeout), invTimed("routing_state", {}, timeout));
    if (S.section === "dashboard") {
      jobs.push(invTimed("scheduler_summary", {}, timeout).catch(() => invTimed("scheduler_list", {}, timeout)));
    }

    const results = await Promise.allSettled(jobs);
    const failures = results.filter((result) => result.status === "rejected");
    let index = 0;
    const status = results[index++];
    const bridge = results[index++];
    if (status.status === "fulfilled") S.status = status.value;
    if (bridge.status === "fulfilled") S.bridge = bridge.value;
    if (wantAccounts) {
      const accounts = results[index++];
      if (accounts.status === "fulfilled") S.accounts = accounts.value;
      const routing = results[index++];
      if (routing.status === "fulfilled") {
        S.routing = routing.value;
        if (routing.value.accounts) S.accounts = routing.value.accounts;
      }
    }
    if (S.section === "dashboard") {
      const scheduler = results[index++];
      if (scheduler.status === "fulfilled") S.schedulerSummary = scheduler.value;
    }
    S.statusFailures = failures.length ? S.statusFailures + 1 : 0;
    S.statusError = failures.length ? errorText(failures[0].reason) : null;
    renderFooter();
    if (S.section !== "dashboard" && S.section !== "api" && S.section !== "accounts") return;
    if (editsInProgress()) {
      S.renderDeferred = true;
      return;
    }
    // Leave an unchanged page alone; the footer already shows live status.
    if (statusSignature() === S.lastStatusSignature) {
      S.renderDeferred = false;
      return;
    }
    S.renderDeferred = false;
    render();
  },

  updateNotify() {
    if (!S.update || !S.update.newer) return;
    const version = String(S.update.version || "");
    if (!version || S.updateNotifiedVersion === version) return;
    S.updateNotifiedVersion = version;
    toast(fmt(t("updateAvailable"), { v: version }));
  },

  gatewayRestart() {
    run("start", async () => {
      await inv("gateway_stop");
      await inv("gateway_start");
      toast(`${t("gateway")}: ${t("running")}`);
      await A.refreshStatus();
    });
  },

  checkApi() {
    run("check", async () => {
      try {
        const raw = await inv("gateway_check");
        let model = "";
        try {
          const parsed = typeof raw === "string" ? JSON.parse(raw) : raw;
          if (parsed && parsed.model) model = ` · ${parsed.model}`;
        } catch { /* the gateway answered with plain text */ }
        // A passing gateway check only proves the Codex path works. The local
        // catalogue is a separate contract: a Ready model must be visible in
        // /v1/models, so check it in the same action instead of leaving the
        // user to notice the omission by hand.
        let localNote = "";
        let localOk = true;
        try {
          const [runtime, localModels, gateway] = await Promise.all([
            window.api.localAi.runtimeStatus(),
            window.api.localAi.modelsList(),
            inv("gateway_models"),
          ]);
          const alias = (id) => {
            const value = String(id || "");
            return value.startsWith("local/") ? value : `local/${value}`;
          };
          const ready = (localModels || [])
            .filter((entry) => entry.runtimeStatus === "ready")
            .map((entry) => alias(entry.id));
          const served = (gateway || [])
            .map((entry) => String((entry && entry.id) || ""))
            .filter((id) => id.startsWith("local/"));
          const missing = ready.filter((id) => !served.includes(id));
          const stale = served.filter((id) => !ready.includes(id));
          if (runtime && runtime.publicationError) {
            // The gateway can answer while the last publication attempt still
            // failed. The check must fail for the same reason the card shows.
            localOk = false;
            localNote = fmt(t("localAiCheckFailed"), { error: runtime.publicationError });
          } else if (runtime && runtime.error) {
            localOk = false;
            localNote = fmt(t("localAiCheckFailed"), { error: runtime.error });
          } else if (missing.length) {
            localOk = false;
            localNote = fmt(t("localAiCheckMissing"), { missing: missing.join(", ") });
          } else if (stale.length) {
            localOk = false;
            localNote = fmt(t("localAiCheckStale"), { models: stale.join(", ") });
          } else if (ready.length) {
            localNote = fmt(t("localAiCheckOk"), { models: ready.join(", ") });
          }
        } catch (error) {
          // Swallowing this used to turn "the app cannot read its own state"
          // into a green check. The gateway check above already covers a
          // stopped gateway; here the failure belongs to the local IPC path.
          localOk = false;
          localNote = fmt(t("localAiCheckFailed"), { error: errorText(error) });
        }
        S.checkResult = `${t("checkPassed")}${model}${localNote ? ` · ${localNote}` : ""}`;
        S.checkPassed = localOk;
        S.checkErrorDetail = localOk ? null : localNote;
        if (localOk) toast(t("done"));
        else toast(localNote, true);
      } catch (error) {
        S.checkResult = t("checkFailedHint");
        S.checkPassed = false;
        S.checkErrorDetail = errorText(error);
        toast(S.checkResult, true);
      }
    });
  },

  async codexAppLoad() {
    try {
      S.codexApp = await inv("codex_app_status");
      S.codexAppError = null;
    } catch (error) {
      S.codexAppError = errorText(error);
    }
    if (S.section === "api" || S.section === "accounts") render();
  },

  codexOpen() {
    return run("launch", async () => {
      S.launchError = null;
      S.launchModal = null;
      try {
        const result = await inv("codex_app_open");
        S.codexApp = await inv("codex_app_status");
        if (result && result.route) S.route = result.route;
        toast(t("codexOpened"));
      } catch (error) {
        S.launchError = errorText(error);
        S.launchModal = { at: Date.now() };
      }
    });
  },

  async codexPickPath() {
    // Picking the app from the launch dialog continues the launch.
    const launchAfterPick = !!S.launchModal;
    let selected;
    try {
      selected = await inv("plugin:dialog|open", {
        options: {
          multiple: false,
          directory: false,
          title: t("chooseAppPathTitle"),
          filters: [{ name: "ChatGPT", extensions: ["exe"] }],
        },
      });
    } catch (error) {
      toast(errorText(error), true);
      return;
    }
    const path = Array.isArray(selected) ? selected[0] : selected;
    if (!path) return;
    try {
      S.codexApp = await inv("codex_app_set_path", { path: String(path) });
      S.codexAppError = null;
      S.launchModal = null;
      S.launchError = null;
      toast(t("appPathSaved"));
    } catch (error) {
      const code = errorText(error);
      if (code === "codex_path_invalid") {
        S.launchError = code;
        S.launchModal = { at: Date.now() };
      } else {
        toast(code, true);
      }
    }
    render();
    if (launchAfterPick && S.codexApp && S.codexApp.found) await A.codexOpen();
  },

  async codexForgetPath() {
    try {
      S.codexApp = await inv("codex_app_forget_path");
      S.launchError = null;
      S.launchModal = null;
      toast(t("appPathForgotten"));
    } catch (error) {
      toast(errorText(error), true);
    }
    render();
  },

  codexDownload() {
    inv("open_url", { url: "https://chatgpt.com/download" })
      .catch((error) => toast(errorText(error), true));
  },

  launchClose() {
    S.launchModal = null;
    S.launchError = null;
    render();
  },

  accountSelect(id) {
    const selected = new Set(S.selectedAccounts || []);
    if (selected.has(id)) selected.delete(id); else selected.add(id);
    S.selectedAccounts = [...selected];
    render(true);
  },

  accountsSelectAll() {
    const ids = (S.accounts || []).map((account) => account.id);
    S.selectedAccounts = ids.every((id) => (S.selectedAccounts || []).includes(id)) ? [] : ids;
    render(true);
  },

  accountsRefreshSelected() {
    const ids = (S.selectedAccounts || []).filter((id) => S.accounts.some((account) => account.id === id));
    if (!ids.length) return;
    return run("quotas", async () => {
      const errors = [];
      for (const id of ids) {
        const result = await inv("quota_refresh", { id });
        S.accounts = result.accounts;
        errors.push(...(result.errors || []));
      }
      S.routing = await inv("routing_state");
      if (S.routing.accounts) S.accounts = S.routing.accounts;
      await A.historyLoad();
      toast(errors.length ? errors.join("\n") : t("done"), errors.length > 0);
    });
  },

  accountsDeleteSelected() {
    const ids = (S.selectedAccounts || []).filter((id) => S.accounts.some((account) => account.id === id));
    if (!ids.length || !window.confirm(fmt(t("accountDeleteSelectedConfirm"), { n: ids.length }))) return;
    return run("accounts-delete", async () => {
      for (const id of ids) {
        S.accounts = await inv("delete_account", { id });
        S.selectedAccounts = (S.selectedAccounts || []).filter((selected) => selected !== id);
      }
      S.routing = await inv("routing_state");
      if (S.routing.accounts) S.accounts = S.routing.accounts;
      toast(t("done"));
    });
  },

  accountSettingsOpen(id) {
    S.accountSettingsDraft = null;
    S.accountSettings = id;
    render();
    document.getElementById("account-pool-enabled")?.focus();
  },

  accountSettingsClose() {
    S.accountSettings = null;
    S.accountSettingsDraft = null;
    render();
  },

  accountSettingsDraftChange() {
    const account = (S.accounts || []).find((item) => item.id === S.accountSettings);
    if (!account) return null;
    const draft = { ...accountSettingsValues(account) };
    const node = (id) => document.getElementById(id);
    for (const [key, id] of [["poolEnabled", "account-pool-enabled"], ["hourlyEnabled", "account-res-h-enabled"], ["weeklyEnabled", "account-res-w-enabled"], ["preferred", "account-preferred"], ["backup", "account-backup"]]) {
      if (node(id)) draft[key] = node(id).checked;
    }
    for (const [key, suffix] of [["hourly", "h"], ["weekly", "w"]]) {
      if (node("account-res-" + suffix)) draft[key] = node("account-res-" + suffix).value;
      const row = node("account-res-" + suffix)?.closest(".account-limit-value");
      if (row) row.hidden = !draft[key + "Enabled"];
    }
    S.accountSettingsDraft = draft;
    return draft;
  },

  accountSettingsModels(id) {
    A.accountSettingsDraftChange();
    S.accountSettings = null;
    S.accountSettingsReturn = id;
    return A.poolOpenAccount(id);
  },

  poolClose() {
    S.poolModal = null;
    S.poolQuery = "";
    S.poolError = null;
    S.poolDraft = null;
    if (S.accountSettingsReturn) {
      S.accountSettings = S.accountSettingsReturn;
      S.accountSettingsReturn = null;
    }
    render();
  },

  accountSettingsSave(id) {
    // Capture edits before run() rebuilds the page; keep the draft on errors.
    const draft = A.accountSettingsDraftChange();
    if (!draft || draft.id !== id) return;
    const hourly = Number(draft.hourly), weekly = Number(draft.weekly);
    if ((draft.hourlyEnabled && (!Number.isInteger(hourly) || hourly < 1 || hourly > 100)) ||
        (draft.weeklyEnabled && (!Number.isInteger(weekly) || weekly < 1 || weekly > 100))) {
      toast(t("accountInvalidLimit"), true);
      return;
    }
    return run("account-settings-" + id, async () => {
      S.accounts = await inv("save_reserves", {
        id, hourly: draft.hourlyEnabled ? hourly : null,
        weekly: draft.weeklyEnabled ? weekly : null, poolEnabled: draft.poolEnabled,
      });
      S.routing = await inv("set_account_role", { id, preferred: draft.preferred, backup: draft.backup });
      if (S.routing.accounts) S.accounts = S.routing.accounts;
      S.accountSettings = null;
      S.accountSettingsDraft = null;
      toast(t("done"));
    });
  },

  async bridgeLaunchCodex() {
    if (!window.confirm(t("bridgeRestartConfirm"))) return;
    run("launch", async () => {
      try {
        await inv("bridge_launch_codex");
        toast(t("bridgeRestarted"));
        setTimeout(() => A.refreshStatus(), 8000);
      } catch (error) {
        const code = errorText(error);
        if (code === "codex_not_found" || code === "codex_path_invalid") {
          S.launchError = code;
          S.launchModal = { at: Date.now() };
        } else {
          toast(code, true);
        }
      }
    });
  },

  setLanguage(lang) {
    if (lang === S.lang) return;
    run("settings", async () => {
      S.settings = await inv("settings_set", {
        settings: { ...(S.settings || {}), lang },
      });
      S.lang = lang;
      render();
    });
  },
});

// The boot in app.js may have rendered before this layer loaded; refresh once
// so the macOS navigation and page renderers are visible immediately.
render();

// Hourly update check: keep the sidebar button in sync and toast once per
// version when a newer release appears while the app stays open.
if (IS_TAURI) {
  setInterval(() => {
    inv("update_check", { force: false })
      .then((result) => {
        if (result && !result.skipped) {
          S.update = result;
          A.updateButton();
          A.updateNotify();
        }
      })
      .catch(() => {});
  }, 3600 * 1000);
}
