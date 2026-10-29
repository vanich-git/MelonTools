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
    account.preferredFirst, account.isBackup,
    account.blockInfo && account.blockInfo.code,
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
  ]);
}

// Replace the old flat navigation with the macOS group order.
NAV.splice(0, NAV.length,
  { group: "overview", items: ["dashboard"] },
  { group: "schedulerGroup", items: ["scheduler"] },
  { group: "codex", items: ["accounts", "api", "providers", "composer", "instances"] },
  { group: "general", items: ["settings", "donate"] },
);

const baseRender = render;
const baseGo = A.go;
const baseOnboardingGo = A.onboardingGo;

// Preserve the scroll position across background refreshes. Navigation resets
// it explicitly in A.go below.
render = function renderWithScroll() {
  const detail = document.querySelector(".detail");
  const scrollTop = detail ? detail.scrollTop : 0;
  baseRender();
  if (detail) detail.scrollTop = scrollTop;
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
  baseGo.call(A, section);
  const detail = document.querySelector(".detail");
  if (detail) detail.scrollTop = 0;
};

A.onboardingGo = function onboardingGo(section) {
  S.accountSettings = null;
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
    if (wantAccounts) jobs.push(invTimed("vault_list", {}, timeout));
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
        S.checkResult = `${t("checkPassed")}${model}`;
        S.checkPassed = true;
        S.checkErrorDetail = null;
        toast(t("done"));
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

  accountSettingsOpen(id) {
    S.accountSettings = id;
    render();
  },

  accountSettingsClose() {
    S.accountSettings = null;
    render();
  },

  accountSettingsModels(id) {
    S.accountSettings = null;
    render();
    A.poolOpenAccount(id);
  },

  accountSettingsSave(id) {
    // Read before run(): the first render rebuilds the account page.
    const hourlyNode = document.getElementById("account-res-h");
    const weeklyNode = document.getElementById("account-res-w");
    const preferredNode = document.getElementById("account-preferred");
    const backupNode = document.getElementById("account-backup");
    const hourly = parseInt(hourlyNode ? hourlyNode.value : "", 10);
    const weekly = parseInt(weeklyNode ? weeklyNode.value : "", 10);
    const preferred = !!(preferredNode && preferredNode.checked);
    const backup = !!(backupNode && backupNode.checked);
    run("account-settings-" + id, async () => {
      S.accounts = await inv("save_reserves", {
        id,
        hourly: Number.isFinite(hourly) ? hourly : null,
        weekly: Number.isFinite(weekly) ? weekly : null,
      });
      S.routing = await inv("set_account_role", { id, preferred, backup });
      if (S.routing.accounts) S.accounts = S.routing.accounts;
      S.accountSettings = null;
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
