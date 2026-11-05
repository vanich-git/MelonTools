// Melon Tools — user actions (W6). Loaded before app.js; helpers and page
// renderers are global classic-script bindings available when a method runs.

/// The stored Hugging Face token lives in the backend (DPAPI on Windows), so
/// the UI only knows the `__stored__` marker. Send `null` in that case and let
/// the Rust side use the stored secret.
function hfTokenArg() {
  const token = S && S.localAi ? S.localAi.hfToken : "";
  return token && token !== "__stored__" ? token : null;
}

/// Replaces the Console rows in place instead of rebuilding the whole page.
/// A reader who scrolled up keeps the exact position; a reader who is at the
/// bottom follows new output.
function updateRuntimeLogBox() {
  const box = document.getElementById("local-ai-logs");
  if (!box) return false;
  const distance = box.scrollHeight - box.scrollTop - box.clientHeight;
  const wasAtBottom = distance <= 24;
  const previousTop = box.scrollTop;
  const logs = S.localAi.logs || [];
  box.innerHTML = logs.length === 0
    ? '<span class="muted">No logs recorded yet.</span>'
    : logs.map((line) => `<div>${esc(line)}</div>`).join("");
  box.scrollTop = wasAtBottom ? box.scrollHeight : previousTop;
  return true;
}

/// Loads the newest 500 lines of `llama-server.log` and refreshes the Console.
async function loadRuntimeLogs() {
  try {
    const logs = await window.api.localAi.runtimeLogs(500);
    const next = Array.isArray(logs) ? logs : [];
    S.localAi.logs = next;
    S.localAi.logsSignature = JSON.stringify(next);
    updateRuntimeLogBox();
  } catch (e) {
    // The backend logs section keeps its last good content on a read error.
  }
}

const A = {
  go(section) {
    S.section = section;
    sectionLoads(section);
    render();
  },

  // Both actions go through dismissOnboarding(): the flag is written, the
  // node is dropped and the page scroll comes back. Only the two navigation
  // actions re-render the page.
  onboardingGo(section) {
    dismissOnboarding();
    S.section = section;
    sectionLoads(section);
    render();
  },

  onboardingDone() {
    dismissOnboarding();
  },

  async onboardingHealthRefresh() {
    const read = async (fn) => {
      try { await fn(); } catch { /* keep the last snapshot */ }
    };
    await read(async () => { S.status = await inv("gateway_status"); });
    await read(async () => { S.schedulerSummary = await inv("scheduler_summary").catch(() => inv("scheduler_list")); });
    await read(async () => { S.schedulerModels = await inv("scheduler_models"); });
    await read(async () => {
      const result = await inv("backup_last");
      S.backupLast = result && result.createdAt ? result.createdAt : null;
      S.backupLastLoaded = true;
    });
    const node = document.getElementById("onboarding-health");
    if (node) node.innerHTML = onboardingHealthRows();
  },

  async onboardingDemoTask() {
    try {
      if (!S.schedulerModels) S.schedulerModels = await inv("scheduler_models");
      const model = ((S.schedulerModels && S.schedulerModels.ids) || [])[0] || "";
      if (!model) {
        toast(t("schedulerModelsFailed"), true);
        return;
      }
      const task = {
        id: "",
        name: t("onboardingDemoName"),
        prompt: t("onboardingDemoPrompt"),
        model,
        reasoningEffort: null,
        scheduleKind: "interval",
        cronExpression: null,
        timeZone: null,
        workingDirectory: null,
        includeGitContext: false,
        maxTokens: null,
        retryLimit: 0,
        retryDelayMinutes: 5,
        dailyTokenLimit: null,
        intervalMinutes: 60,
        enabled: false,
      };
      S.scheduler = await inv("scheduler_save", { task });
      toast(t("onboardingDemoCreated"));
      await A.onboardingHealthRefresh();
    } catch (error) {
      toast(String(error && error.message ? error.message : error), true);
    }
  },

  async copy(text) {
    try {
      await navigator.clipboard.writeText(text);
      toast(t("copied"));
    } catch {
      toast(text);
    }
  },

  async refreshStatus() {
    // The welcome dialog freezes background work on purpose: a full vault
    // read and page re-render every 5 s is what made the tour stutter.
    if (onboardingVisible()) return;
    const timeout = 5000;
    const jobs = [
      invTimed("gateway_status", {}, timeout),
      invTimed("bridge_status", {}, timeout),
    ];
    const wantAccounts = IS_TAURI && (S.section === "dashboard" || S.section === "accounts");
    if (wantAccounts) jobs.push(invTimed("vault_list", {}, timeout));
    if (S.section === "dashboard") jobs.push(invTimed("scheduler_summary", {}, timeout).catch(() => invTimed("scheduler_list", {}, timeout)));

    const results = await Promise.allSettled(jobs);
    const failures = results.filter((result) => result.status === "rejected");
    let index = 0;
    const status = results[index++];
    const bridge = results[index++];
    if (status.status === "fulfilled") S.status = status.value;
    if (bridge.status === "fulfilled") S.bridge = bridge.value;
    if (wantAccounts) {
      const accounts = results[index++];
      // Keep the last snapshot on a transient read failure.
      if (accounts.status === "fulfilled") S.accounts = accounts.value;
    }
    if (S.section === "dashboard") {
      const scheduler = results[index++];
      if (scheduler.status === "fulfilled") {
        S.schedulerSummary = scheduler.value;
      }
    }
    S.statusFailures = failures.length ? S.statusFailures + 1 : 0;
    S.statusError = failures.length ? errorText(failures[0].reason) : null;
    renderFooter();
    if (S.section !== "dashboard" && S.section !== "api" && S.section !== "accounts") return;
    if (editsInProgress()) {
      // Status-only update done; the full render resumes after the field
      // loses focus (see the focusout hook in the boot section).
      S.renderDeferred = true;
      return;
    }
    S.renderDeferred = false;
    render();
  },

  async refreshAccounts() {
    S.accounts = await inv("vault_list");
  },

  async historyLoad() {
    try {
      const raw = await inv("quota_history");
      const samples = Array.isArray(raw)
        ? raw
        : Array.isArray(raw && raw.samples) ? raw.samples : [];
      S.history = samples.filter((sample) => sample && typeof sample.key === "string");
    } catch {
      // History is decorative: keep the previous samples on a failed read.
    }
  },

  async loadAll() {
    try {
      const [info, settings] = await Promise.all([
        inv("app_info"),
        S.settings ? Promise.resolve(S.settings) : inv("settings_get"),
      ]);
      S.info = info;
      S.settings = settings;
      S.lang = (S.settings && S.settings.lang) === "en" ? "en" : "ru";
      const settled = await Promise.allSettled([
        inv("vault_list"),
        inv("quota_history"),
        inv("gateway_status"),
        inv("codex_route_status"),
        inv("bridge_status"),
        inv("routing_state"),
        inv("gateway_recent_calls", { limit: 8 }),
        inv("autostart_get"),
        inv("scheduler_summary").catch(() => inv("scheduler_list")),
      ]);
      const value = (index, fallback) => settled[index].status === "fulfilled"
        ? settled[index].value
        : fallback;
      S.accounts = value(0, []);
      const history = value(1, []);
      const samples = Array.isArray(history)
        ? history
        : Array.isArray(history && history.samples) ? history.samples : [];
      S.history = samples.filter((sample) => sample && typeof sample.key === "string");
      S.status = value(2, S.status);
      S.route = value(3, S.route);
      S.bridge = value(4, S.bridge);
      S.routing = value(5, S.routing);
      S.calls = value(6, []);
      S.autostart = value(7, false);
      S.schedulerSummary = value(8, S.schedulerSummary);
    } catch (error) {
      toast(errorText(error), true);
    }
    render();
    const health = document.getElementById("onboarding-health");
    if (health && onboardingVisible()) health.innerHTML = onboardingHealthRows();
  },

  gatewayStart() {
    run("start", async () => {
      const result = await inv("gateway_start");
      toast(result === "adopted" ? `${t("gateway")}: adopted` : `${t("gateway")}: ${t("running")}`);
      await A.refreshStatus();
    });
  },

  gatewayStop() {
    run("stop", async () => {
      await inv("gateway_stop");
      toast(`${t("gateway")}: ${t("stopped")}`);
      await A.refreshStatus();
    });
  },

  gatewaySync() {
    run("sync", async () => {
      const result = await inv("gateway_sync");
      toast(`${t("sync")}: ${result.syncedAccounts}`);
    });
  },

  checkApi() {
    run("check", async () => {
      S.checkResult = await inv("gateway_check");
      toast(t("done"));
    });
  },

  // Read-only connectivity/auth/model check. Every probe is independent, so a
  supportBundle() {
    return run("support", async () => {
      const bundle = await inv("support_bundle");
      await A.copy(JSON.stringify(bundle, null, 2));
    });
  },

  // stopped gateway or one failing provider does not hide the other results.
  diagRun() {
    return run("diag", async () => {
      const checks = [
        ["settings", "settings_get", () => inv("settings_get")],
        ["accounts", "vault_list", () => inv("vault_list")],
        ["gatewayStatus", "gateway_status", () => inv("gateway_status")],
        ["gatewayCheck", "gateway_check", () => inv("gateway_check")],
        ["gatewayModels", "gateway_models", () => inv("gateway_models")],
        ["claudeCredentials", "claude_credentials", () => inv("claude_credentials")],
        ["claudeModels", "claude_models", () => inv("claude_models")],
        ["claudeUsage", "claude_usage", () => inv("claude_usage")],
        ["antigravityCredentials", "antigravity_credentials", () => inv("antigravity_credentials")],
        ["antigravityModels", "antigravity_models", () => inv("antigravity_models")],
        ["antigravityMetrics", "antigravity_metrics", () => inv("antigravity_metrics")],
        // A missing key is a normal unconfigured state, not a diagnostics
        // failure. Only probe Vercel when the user actually saved a key.
        ["vercelMetrics", "vercel_refresh", async () => {
          const settings = S.settings || await inv("settings_get");
          if (!String(settings.vercelKey || "").trim()) return null;
          return inv("vercel_refresh");
        }],
      ];
      const settled = await Promise.allSettled(checks.map(([, , call]) => call()));
      const data = {};
      const errors = [];
      checks.forEach(([key, command], index) => {
        const result = settled[index];
        if (result.status === "fulfilled") data[key] = result.value;
        else errors.push({ command, message: errorText(result.reason) });
      });

      const has = (key) => Object.prototype.hasOwnProperty.call(data, key);
      const settings = data.settings || {};
      const accounts = Array.isArray(data.accounts) ? data.accounts : [];
      const gateway = data.gatewayStatus || null;
      const running = !!(gateway && gateway.running);
      const port = (gateway && gateway.port) || settings.port || "—";

      const gatewayIds = [];
      const seenIds = new Set();
      for (const model of Array.isArray(data.gatewayModels) ? data.gatewayModels : []) {
        const id = String((model && model.id) || "");
        if (seenIds.has(id)) continue;
        seenIds.add(id);
        gatewayIds.push(id);
      }
      const countPrefix = (prefix) => gatewayIds.filter((id) => id.startsWith(prefix)).length;

      const claudeModels = data.claudeModels && Array.isArray(data.claudeModels.models)
        ? data.claudeModels.models
        : null;
      const antigravityModels = data.antigravityModels && Array.isArray(data.antigravityModels.models)
        ? data.antigravityModels.models
        : null;
      const claudeCredentials = data.claudeCredentials && Array.isArray(data.claudeCredentials.credentials)
        ? data.claudeCredentials.credentials.length
        : null;
      const antigravityCredentials = data.antigravityCredentials && Array.isArray(data.antigravityCredentials.credentials)
        ? data.antigravityCredentials.credentials.length
        : null;

      const keyAuth = (value) => value && String(value).trim()
        ? { text: t("diagKeySet"), cls: "ok" }
        : { text: t("diagKeyMissing"), cls: "warn" };
      const countCell = (count) => ({
        text: count === null || count === undefined ? "—" : String(count),
        cls: count === null || count === undefined ? "" : count > 0 ? "ok" : "warn",
      });
      const quotaCell = (iso) => {
        const ts = Date.parse(iso || "");
        return Number.isNaN(ts) ? { text: "—", cls: "" } : { text: claudeAgeText(iso), cls: "ok" };
      };

      const reach = {
        text: running
          ? `${t("running")} · :${port}${has("gatewayCheck") ? " · " + t("diagApiOk") : ""}`
          : t("stopped"),
        cls: running ? "ok" : "danger",
      };
      const viaGateway = {
        text: running ? t("diagUp") : t("diagDown"),
        cls: running ? "ok" : "danger",
      };
      const codexQuota = accounts.reduce((latest, account) => Math.max(latest, Number(account.quotaUpdatedAt) || 0), 0);

      const rows = [
        {
          name: t("gateway"), reach,
          auth: { text: "—", cls: "" },
          models: countCell(has("gatewayModels") ? gatewayIds.length : null),
          quota: { text: "—", cls: "" },
        },
        {
          name: t("diagCodex"), reach: viaGateway,
          auth: { text: `${accounts.length} ${t("accountsCount")}`, cls: accounts.length ? "ok" : "warn" },
          models: countCell(has("gatewayModels")
            ? gatewayIds.filter((id) => !id.startsWith("opencode/")
              && !id.startsWith("openrouter/")
              && !id.startsWith("deepinfra/")
              && !id.startsWith("vercel/")
              && !id.startsWith("zai/")).length
            : null),
          quota: codexQuota ? { text: ageText(codexQuota), cls: "ok" } : { text: "—", cls: "" },
        },
        {
          name: t("openrouter"), reach: viaGateway,
          auth: keyAuth(settings.openrouterKey),
          models: countCell(has("gatewayModels") ? countPrefix("openrouter/") : null),
          quota: { text: "—", cls: "" },
        },
        {
          name: t("opencode"), reach: viaGateway,
          auth: keyAuth(settings.opencodeKey),
          models: countCell(has("gatewayModels") ? countPrefix("opencode/") : null),
          quota: { text: "—", cls: "" },
        },
        {
          name: t("deepinfra"), reach: viaGateway,
          auth: keyAuth(settings.deepinfraKey),
          models: countCell(has("gatewayModels") ? countPrefix("deepinfra/") : null),
          // DeepInfra exposes no per-key balance endpoint.
          quota: { text: "—", cls: "" },
        },
        {
          name: t("vercel"), reach: viaGateway,
          auth: keyAuth(settings.vercelKey),
          models: countCell(has("gatewayModels") ? countPrefix("vercel/") : null),
          quota: has("vercelMetrics")
            ? quotaCell(data.vercelMetrics && data.vercelMetrics.updatedAt)
            : { text: "—", cls: "" },
        },
        {
          name: t("zai"), reach: viaGateway,
          auth: keyAuth(settings.zaiKey),
          models: countCell(has("gatewayModels") ? countPrefix("zai/") : null),
          quota: { text: "—", cls: "" },
        },
        {
          name: t("claude"), reach: viaGateway,
          auth: countCell(claudeCredentials),
          models: countCell(claudeModels ? claudeModels.length : null),
          quota: has("claudeUsage") ? quotaCell(data.claudeUsage && data.claudeUsage.updatedAt) : { text: "—", cls: "" },
        },
        {
          name: t("antigravity"), reach: viaGateway,
          auth: countCell(antigravityCredentials),
          models: countCell(antigravityModels ? antigravityModels.length : null),
          quota: has("antigravityMetrics") ? quotaCell(data.antigravityMetrics && data.antigravityMetrics.updatedAt) : { text: "—", cls: "" },
        },
      ];

      S.diag = { at: Date.now(), rows, errors };
    });
  },

  codexRouteApply() {
    run("route", async () => {
      const result = await inv("codex_route_apply");
      S.route = result.route;
      toast(`${t("routeApply")}: ok · models +${result.catalogCustom}`);
    });
  },

  providerToggleChanged() {
    const openrouter = document.getElementById("or-enabled");
    const opencode = document.getElementById("oc-enabled");
    const deepinfra = document.getElementById("di-enabled");
    const vercel = document.getElementById("vc-enabled");
    const zai = document.getElementById("zai-enabled");
    const claude = document.getElementById("claude-enabled");
    S.settings = {
      ...S.settings,
      ...(openrouter ? { openrouterEnabled: openrouter.checked } : {}),
      ...(opencode ? { opencodeEnabled: opencode.checked } : {}),
      ...(deepinfra ? { deepinfraEnabled: deepinfra.checked } : {}),
      ...(vercel ? { vercelEnabled: vercel.checked } : {}),
      ...(zai ? { zaiEnabled: zai.checked } : {}),
      ...(claude ? { claudeEnabled: claude.checked } : {}),
    };
    inv("settings_set", { settings: S.settings })
      .then((settings) => { S.settings = settings; })
      .catch((error) => toast(errorText(error), true));
  },

  codexRouteRemove() {
    run("route", async () => {
      S.route = await inv("codex_route_remove");
      toast(t("done"));
    });
  },

  async bridgeLaunchCodex() {
    if (!window.confirm(t("bridgeRestartConfirm"))) return;
    run("launch", async () => {
      const result = await inv("bridge_launch_codex");
      toast(`${t("bridgeRestarted")}: ${result}`);
      setTimeout(() => A.refreshStatus(), 8000);
    });
  },

  refreshQuotas() {
    S.lastQuotaRefreshAt = Date.now();
    run("quotas", async () => {
      const result = await inv("quota_refresh");
      S.accounts = result.accounts;
      await A.historyLoad();
      if (result.errors && result.errors.length) toast(result.errors.join("\n"), true);
      else toast(`${t("refreshQuotas")}: ${t("done")}`);
    });
  },

  refreshQuota(id) {
    run("quotas", async () => {
      const result = await inv("quota_refresh", { id });
      S.accounts = result.accounts;
      await A.historyLoad();
      if (result.errors && result.errors.length) toast(result.errors.join("\n"), true);
    });
  },

  resetActivate(id) {
    const account = (S.accounts || []).find((a) => a.id === id);
    const name = account ? account.email || account.displayName : id;
    if (!window.confirm(fmt(t("resetConfirm"), { name }))) return;
    run("reset-" + id, async () => {
      let result;
      try {
        result = await inv("reset_activate", { id });
      } catch (error) {
        const code = errorText(error);
        if (code === "reset_in_progress") throw new Error(t("resetAlreadyRunning"));
        if (code === "no_credit") throw new Error(t("resetNoCredit"));
        throw error;
      }
      S.accounts = result.accounts;
      S.routing = await inv("routing_state").catch(() => S.routing);
      await A.historyLoad();
      const key = {
        reset: "resetActivated",
        nothing_to_reset: "resetNothingToReset",
        no_credit: "resetNoCredit",
        already_redeemed: "resetAlreadyRedeemed",
      }[result.outcome] || "resetActivated";
      const details = result.errors && result.errors.length
        ? " · " + result.errors.join("; ")
        : "";
      toast(t(key) + details);
    });
  },

  refreshLogin(id) {
    run("login-" + id, async () => {
      S.accounts = await inv("account_refresh_tokens", { id });
      toast(t("done"));
    });
  },

  switchAccount(id) {
    run("switch-" + id, async () => {
      const result = await inv("switch_account", { id });
      toast(`${t("makeCurrent")}: ${result.authPath}`);
      await A.refreshAccounts();
    });
  },

  async importAuth() {
    run("import", async () => {
      const result = await inv("import_current_auth");
      S.accounts = result.accounts;
      toast(`${t("importAuth")}: ${result.result}`);
    });
  },

  importJsonPick() {
    const input = document.getElementById("accounts-json-file");
    if (input) input.click();
  },

  importJsonFile(input) {
    const file = input && input.files ? input.files[0] : null;
    if (!file) return;
    run("import-json", async () => {
      const content = await file.text();
      const result = await inv("import_json_accounts", { content });
      S.accounts = result.accounts;
      // Provider files change outside the Codex vault: drop the cached cards
      // so the Connections page reads the freshly imported auth files.
      S.models = null;
      S.pool = null;
      S.claude = null;
      S.antigravity = null;
      S.lastClaudeUsageAt = 0;
      S.lastAntigravityAt = 0;
      const counts = result.result || {};
      toast(fmt(t("importJsonDone"), {
        n: counts.imported ?? 0,
        added: counts.added ?? 0,
        updated: counts.updated ?? 0,
        skipped: counts.skipped ?? 0,
        claude: counts.claude ?? 0,
        antigravity: counts.antigravity ?? 0,
      }));
    });
    input.value = "";
  },

  liftPoolPause() {
    const state = poolPauseState();
    if (!state || !state.liftable) return;
    if (!window.confirm(t("poolPauseConfirm"))) return;
    const targets = state.blocks
      .filter((block) => block.liftable)
      .map((block) => ({ block, windows: poolPauseWindows(block) }));
    run("poolPause", async () => {
      for (const { block, windows } of targets) {
        const account = block.account;
        await inv("save_reserves", {
          id: account.id,
          hourly: windows.has("hourly") ? null : (account.hourlyReservePercent ?? null),
          weekly: windows.has("weekly") ? null : (account.weeklyReservePercent ?? null),
        });
      }
      await inv("gateway_sync");
      await inv("quota_refresh");
      S.accounts = await inv("vault_list");
      S.routing = await inv("routing_state");
      toast(t("done"));
    });
  },

  saveReserves(id) {
    // Read before run(): its first render rebuilds the page from old state.
    const hourlyNode = document.getElementById("res-h-" + id);
    const weeklyNode = document.getElementById("res-w-" + id);
    const hourly = parseInt(hourlyNode ? hourlyNode.value : "", 10);
    const weekly = parseInt(weeklyNode ? weeklyNode.value : "", 10);
    run("reserves-" + id, async () => {
      S.accounts = await inv("save_reserves", {
        id,
        hourly: Number.isFinite(hourly) ? hourly : null,
        weekly: Number.isFinite(weekly) ? weekly : null,
      });
      toast(t("done"));
    });
  },

  async deleteAccount(id) {
    const account = (S.accounts || []).find((a) => a.id === id);
    const name = account ? account.email || account.displayName : id;
    if (!window.confirm(fmt(t("confirmDelete"), { name }))) return;
    run("delete-" + id, async () => {
      S.accounts = await inv("delete_account", { id });
      toast(t("done"));
    });
  },

  saveKeys() {
    // Read fields before run() rebuilds the page. Falling back to the saved
    // value keeps a partial rerender from blanking a key the user did not edit.
    const openrouterNode = document.getElementById("or-key");
    const opencodeNode = document.getElementById("oc-key");
    const deepinfraNode = document.getElementById("di-key");
    const vercelNode = document.getElementById("vc-key");
    const zaiNode = document.getElementById("zai-key");
    const openrouterEnabledNode = document.getElementById("or-enabled");
    const opencodeEnabledNode = document.getElementById("oc-enabled");
    const deepinfraEnabledNode = document.getElementById("di-enabled");
    const vercelEnabledNode = document.getElementById("vc-enabled");
    const zaiEnabledNode = document.getElementById("zai-enabled");
    const openrouterKey = openrouterNode
      ? openrouterNode.value.trim()
      : (S.settings.openrouterKey || "");
    const opencodeKey = opencodeNode
      ? opencodeNode.value.trim()
      : (S.settings.opencodeKey || "");
    const deepinfraKey = deepinfraNode
      ? deepinfraNode.value.trim()
      : (S.settings.deepinfraKey || "");
    const vercelKey = vercelNode
      ? vercelNode.value.trim()
      : (S.settings.vercelKey || "");
    const zaiKey = zaiNode
      ? zaiNode.value.trim()
      : (S.settings.zaiKey || "");
    const openrouterEnabled = openrouterEnabledNode
      ? openrouterEnabledNode.checked
      : !!S.settings.openrouterEnabled;
    const opencodeEnabled = opencodeEnabledNode
      ? opencodeEnabledNode.checked
      : !!S.settings.opencodeEnabled;
    const deepinfraEnabled = deepinfraEnabledNode
      ? deepinfraEnabledNode.checked
      : !!S.settings.deepinfraEnabled;
    const vercelEnabled = vercelEnabledNode
      ? vercelEnabledNode.checked
      : !!S.settings.vercelEnabled;
    const zaiEnabled = zaiEnabledNode
      ? zaiEnabledNode.checked
      : !!S.settings.zaiEnabled;
    const previous = {
      openrouter: S.settings.openrouterKey || "",
      deepinfra: S.settings.deepinfraKey || "",
      vercel: S.settings.vercelKey || "",
      zai: S.settings.zaiKey || "",
    };
    run("keys", async () => {
      S.settings = await inv("settings_set", {
        settings: {
          ...S.settings,
          openrouterKey,
          opencodeKey,
          deepinfraKey,
          vercelKey,
          zaiKey,
          openrouterEnabled,
          opencodeEnabled,
          deepinfraEnabled,
          vercelEnabled,
          zaiEnabled,
        },
      });
      // Metrics and cached model lists belong to the key they were fetched
      // with; never leave the previous key's numbers on screen.
      if (openrouterKey !== previous.openrouter) S.providers = null;
      if (deepinfraKey !== previous.deepinfra) {
        S.providerModelsError.deepinfra = null;
      }
      if (vercelKey !== previous.vercel) {
        S.providerModelsError.vercel = null;
        S.vercel = null;
        S.vercelLoaded = false;
      }
      if (zaiKey !== previous.zai) {
        S.providerModelsError.zai = null;
      }
      toast(t("done"));
    });
  },

  loadProviderModels(provider) {
    const prefix = provider === "deepinfra" ? "di" : provider === "vercel" ? "vc" : provider;
    const keyNode = document.getElementById(prefix + "-key");
    const field = provider + "Key";
    const modelsField = provider + "Models";
    const key = keyNode ? keyNode.value.trim() : (S.settings[field] || "");
    if (!key) {
      toast(t("keyRequired"), true);
      return;
    }
    run("models-" + provider, async () => {
      S.providerModelsError[provider] = null;
      try {
        // The Rust loader reads the key from the saved settings.
        S.settings = await inv("settings_set", {
          settings: { ...S.settings, [field]: key },
        });
        const result = await inv("provider_models_load", { provider });
        const models = Array.isArray(result.models) ? result.models : [];
        S.settings = await inv("settings_set", {
          settings: { ...S.settings, [modelsField]: models },
        });
        if (provider === "vercel") {
          S.vercelLoaded = false;
          S.vercel = null;
        }
        toast(`${t("models")}: ${result.count === undefined ? models.length : result.count}`);
      } catch (error) {
        S.providerModelsError[provider] = errorText(error);
        throw error;
      }
    });
  },

  openrouterRefresh() {
    run("openrouter", async () => {
      S.providers = await inv("openrouter_refresh");
      await A.historyLoad();
    });
  },

  vercelLoad() {
    S.vercelLoaded = true;
    return inv("vercel_refresh").then((value) => {
      S.vercel = value;
      if (S.section === "providers") render();
    }).catch((error) => {
      S.vercel = { error: errorText(error) };
      if (S.section === "providers") render();
    });
  },

  vercelRefresh() {
    const node = document.getElementById("vc-key");
    const key = node ? node.value.trim() : (S.settings.vercelKey || "");
    if (!key) {
      toast(t("keyRequired"), true);
      return;
    }
    run("vercel", async () => {
      if (key !== (S.settings.vercelKey || "")) {
        S.settings = await inv("settings_set", {
          settings: { ...S.settings, vercelKey: key },
        });
        S.providerModelsError.vercel = null;
        S.vercel = null;
      }
      S.vercelLoaded = true;
      S.vercel = await inv("vercel_refresh");
      toast(t("done"));
    });
  },

  claudeUsageLoad() {
    S.lastClaudeUsageAt = Date.now();
    return inv("claude_usage").then(async (usage) => {
      S.claude = usage;
      await A.historyLoad();
    });
  },

  claudeRefreshUsage() {
    run("claudeUsage", async () => {
      await A.claudeUsageLoad();
    });
  },

  claudeConnect() {
    run("claudeConnect", async () => {
      const session = await inv("claude_login_start");
      if (!session || !session.url || !session.state) throw new Error(t("claudeLoginError"));
      S.claudeLogin = { state: session.state, startedAt: Date.now(), done: false };
      render();
      inv("open_url", { url: session.url }).catch(() => {});
      clearInterval(A._claudeTimer);
      A._claudeTimer = setInterval(async () => {
        if (!S.claudeLogin) {
          clearInterval(A._claudeTimer);
          return;
        }
        // C-F9: the poll must not run forever — 10 minutes, then an honest error.
        if (Date.now() - S.claudeLogin.startedAt >= LOGIN_TIMEOUT_MS) {
          clearInterval(A._claudeTimer);
          S.claudeLogin = null;
          toast(t("loginTimeout"), true);
          render();
          return;
        }
        try {
          const result = await inv("claude_login_status", { stateToken: S.claudeLogin.state });
          if (!S.claudeLogin) return;
          if (result.status === "ok") {
            clearInterval(A._claudeTimer);
            S.claudeLogin = null;
            toast(t("done"));
            await A.claudeUsageLoad().catch(() => {});
            A.modelsLoad();
          } else if (result.status === "error") {
            clearInterval(A._claudeTimer);
            S.claudeLogin = null;
            toast(t("claudeLoginError"), true);
          }
          render();
        } catch (error) {
          clearInterval(A._claudeTimer);
          S.claudeLogin = null;
          toast(String(error), true);
          render();
        }
      }, 2000);
    });
  },

  claudeCancel() {
    const login = S.claudeLogin;
    if (!login) return;
    clearInterval(A._claudeTimer);
    S.claudeLogin = null;
    render();
    inv("claude_login_cancel", { stateToken: login.state }).catch(() => {});
  },

  claudeDisconnect() {
    // Destructive: the engine-written auth files are deleted, so the account
    // must be reconnected. Same confirmation pattern as account deletion.
    if (!window.confirm(t("confirmClaudeDisconnect"))) return;
    run("claudeDisconnect", async () => {
      const result = await inv("claude_disconnect");
      S.claude = null;
      S.lastClaudeUsageAt = 0;
      toast(`${t("claudeDisconnected")} (${(result && result.removed) || 0})`);
      await A.claudeUsageLoad().catch(() => {});
      A.modelsLoad();
    });
  },

  claudeSaveKeys() {
    // Read fields before run() rebuilds the page.
    const enabledNode = document.getElementById("claude-enabled");
    const keyNode = document.getElementById("claude-key");
    const claudeEnabled = enabledNode ? enabledNode.checked : !!S.settings.claudeEnabled;
    const claudeApiKey = keyNode ? keyNode.value.trim() : "";
    run("claudeKeys", async () => {
      S.settings = await inv("settings_set", { settings: { ...S.settings, claudeEnabled, claudeApiKey } });
      toast(t("done"));
      A.claudeUsageLoad().catch(() => {});
    });
  },

  antigravityUsageLoad() {
    S.lastAntigravityAt = Date.now();
    return inv("antigravity_metrics").then((metrics) => {
      S.antigravity = metrics;
    });
  },

  antigravityRefresh() {
    run("antigravityUsage", async () => {
      await A.antigravityUsageLoad();
    });
  },

  antigravityConnect() {
    run("antigravityConnect", async () => {
      const session = await inv("antigravity_login_start");
      if (!session || !session.url || !session.state) throw new Error(t("antigravityLoginError"));
      S.antigravityLogin = { state: session.state, startedAt: Date.now(), done: false };
      render();
      inv("open_url", { url: session.url }).catch(() => {});
      clearInterval(A._antigravityTimer);
      A._antigravityTimer = setInterval(async () => {
        if (!S.antigravityLogin) {
          clearInterval(A._antigravityTimer);
          return;
        }
        // C-F9: the poll must not run forever — 10 minutes, then an honest error.
        if (Date.now() - S.antigravityLogin.startedAt >= LOGIN_TIMEOUT_MS) {
          clearInterval(A._antigravityTimer);
          S.antigravityLogin = null;
          toast(t("loginTimeout"), true);
          render();
          return;
        }
        try {
          const result = await inv("antigravity_login_status", { stateToken: S.antigravityLogin.state });
          if (!S.antigravityLogin) return;
          if (result.status === "ok") {
            clearInterval(A._antigravityTimer);
            S.antigravityLogin = null;
            toast(t("done"));
            await A.antigravityUsageLoad().catch(() => {});
            A.modelsLoad();
          } else if (result.status === "error") {
            clearInterval(A._antigravityTimer);
            S.antigravityLogin = null;
            toast(t("antigravityLoginError"), true);
          }
          render();
        } catch (error) {
          clearInterval(A._antigravityTimer);
          S.antigravityLogin = null;
          toast(String(error), true);
          render();
        }
      }, 2000);
    });
  },

  antigravityCancel() {
    const login = S.antigravityLogin;
    if (!login) return;
    clearInterval(A._antigravityTimer);
    S.antigravityLogin = null;
    render();
    inv("antigravity_login_cancel", { stateToken: login.state }).catch(() => {});
  },

  antigravityPriority(name, priority) {
    const account = ((S.antigravity && S.antigravity.accounts) || []).find((item) => item.name === name);
    if (!account) return;
    run("antigravityPriority", async () => {
      const result = await inv("antigravity_account_action", {
        action: "priority",
        name,
        value: Number.isFinite(priority) ? priority : account.priority + 1,
      });
      if (!result || !result.ok) throw new Error(t("error"));
      await A.antigravityUsageLoad();
      render();
    });
  },

  antigravityPause(name) {
    const account = ((S.antigravity && S.antigravity.accounts) || []).find((item) => item.name === name);
    if (!account) return;
    run("antigravityPause", async () => {
      const result = await inv("antigravity_account_action", {
        action: account.disabled ? "resume" : "pause",
        name,
        authIndex: account.authIndex,
      });
      if (!result || !result.ok) throw new Error(t("error"));
      toast(t("done"));
      await A.antigravityUsageLoad();
      render();
    });
  },

  antigravityRemove(name) {
    if (!window.confirm(t("confirmAntigravityRemove"))) return;
    run("antigravityRemove", async () => {
      const result = await inv("antigravity_account_action", { action: "remove", name });
      if (!result || !result.ok) throw new Error(t("error"));
      S.models = null;
      toast(t("done"));
      await A.antigravityUsageLoad();
      A.modelsLoad();
      render();
    });
  },

  antigravityProbe(name) {
    const account = ((S.antigravity && S.antigravity.accounts) || []).find((item) => item.name === name);
    if (!account) return;
    // One timeout can quarantine several models of the same account: release
    // every first-token cooldown, or the account stays quarantined after a
    // successful probe.
    const models = (account.cooldowns || [])
      .filter((item) => item.http_status === 504)
      .map((item) => item.model_key)
      .filter(Boolean);
    run("antigravityProbe", async () => {
      const result = await inv("antigravity_account_action", {
        action: "probe",
        name,
        authIndex: account.authIndex,
        models,
      });
      toast(result && result.ok ? t("done") : t("error"), !(result && result.ok));
      await A.antigravityUsageLoad();
      render();
    });
  },

  antigravityDisconnect() {
    // Destructive: the engine-written auth files are deleted, so the account
    // must be reconnected. Same confirmation pattern as Claude.
    if (!window.confirm(t("confirmAntigravityDisconnect"))) return;
    run("antigravityDisconnect", async () => {
      const result = await inv("antigravity_disconnect");
      S.antigravity = null;
      S.lastAntigravityAt = 0;
      toast(`${t("antigravityDisconnected")} (${(result && result.removed) || 0})`);
      await A.antigravityUsageLoad().catch(() => {});
      A.modelsLoad();
    });
  },

  async backupLastLoad() {
    if (S.backupLastLoaded) return;
    S.backupLastLoaded = true;
    try {
      const result = await inv("backup_last");
      S.backupLast = result && result.createdAt ? result.createdAt : null;
      if (S.section === "settings") render();
    } catch {
      // Keep the card usable even if the state file cannot be read.
    }
  },

  backupExport() {
    const passwordNode = document.getElementById("backup-password");
    const password = passwordNode ? passwordNode.value : "";
    if (!password) {
      toast(t("backupPasswordRequired"), true);
      return;
    }
    run("backup-export", async () => {
      const result = await inv("backup_export", { password });
      S.backupLast = result && result.createdAt ? result.createdAt : null;
      S.backupLastLoaded = true;
      toast(fmt(t("backupExported"), {
        path: result.path || "",
        bytes: result.bytes || 0,
      }));
    });
  },

  backupImportPick() {
    const input = document.getElementById("backup-file");
    if (input) input.click();
  },

  backupImportFile(input) {
    const file = input && input.files ? input.files[0] : null;
    if (input) input.value = "";
    if (!file) return;
    const passwordNode = document.getElementById("backup-password");
    const password = passwordNode ? passwordNode.value : "";
    if (!password) {
      toast(t("backupPasswordRequired"), true);
      return;
    }
    if (!window.confirm(t("backupImportConfirm"))) return;
    run("backup-import", async () => {
      const content = await file.text();
      // Stop the engine before replacing vault/auth files: Windows cannot
      // rename over files the gateway still has open, and a running engine
      // would keep stale credentials. Always try to start it again.
      try {
        await inv("gateway_stop");
      } catch {
        // It may already be stopped; the import remains safe.
      }
      let summary;
      try {
        summary = await inv("backup_import", { content, password });
      } finally {
        try {
          await inv("gateway_start");
        } catch {
          toast(t("backupImportRestartFailed"), true);
        }
      }
      let message = fmt(t("backupImported"), {
        tasks: summary.schedulerTasks || 0,
        accounts: summary.accounts || 0,
        auths: summary.authFiles || 0,
        settings: summary.settingsKeys || 0,
      });
      if (summary.modelSourcesIncluded) message += t("backupImportModels");
      toast(message);
      S.backupLast = Math.floor(Date.now() / 1000);
      S.backupLastLoaded = true;
      try {
        S.settings = await inv("settings_get");
        S.lang = (S.settings && S.settings.lang) === "en" ? "en" : "ru";
        await A.refreshStatus();
      } catch {
        // The import itself succeeded; the next refresh will resync state.
      }
    });
  },

  applySettings() {
    // Read fields before run() rebuilds the page.
    const langNode = document.getElementById("set-lang");
    const portNode = document.getElementById("set-port");
    const intervalNode = document.getElementById("set-interval");
    const proxyEnabledNode = document.getElementById("set-proxy-enabled");
    const proxyUrlNode = document.getElementById("set-proxy-url");
    const proxyBypassNode = document.getElementById("set-proxy-bypass");
    const streamTimeoutNode = document.getElementById("set-stream-timeout");
    const lang = langNode ? langNode.value : S.lang;
    const port = parseInt(portNode ? portNode.value : "", 10);
    const quotaInterval = parseInt(intervalNode ? intervalNode.value : "", 10);
    const proxyEnabled = proxyEnabledNode ? proxyEnabledNode.checked : !!(S.settings && S.settings.proxyEnabled);
    const proxyUrl = proxyUrlNode ? proxyUrlNode.value.trim() : ((S.settings && S.settings.proxyUrl) || "");
    const proxyBypass = proxyBypassNode ? proxyBypassNode.value.trim() : ((S.settings && S.settings.proxyBypass) || "127.0.0.1,localhost");
    const parsedTimeout = parseInt(streamTimeoutNode ? streamTimeoutNode.value : "", 10);
    const streamBootstrapTimeoutSeconds = Number.isFinite(parsedTimeout)
      ? Math.max(0, Math.min(300, parsedTimeout))
      : ((S.settings && S.settings.streamBootstrapTimeoutSeconds) ?? 60);
    run("settings", async () => {
      S.settings = await inv("settings_set", {
        settings: {
          ...S.settings,
          lang,
          port: Number.isFinite(port) ? port : S.settings.port,
          quotaInterval: Number.isFinite(quotaInterval) ? quotaInterval : S.settings.quotaInterval,
          proxyEnabled,
          proxyUrl,
          proxyBypass,
          streamBootstrapTimeoutSeconds,
        },
      });
      S.proxyUrlDraft = null;
      S.lang = lang;
      toast(t("done"));
      await A.refreshStatus();
    });
  },

  proxyUrlChanged(value) {
    S.proxyUrlDraft = value;
    const button = document.getElementById("proxy-save");
    if (!button) return;
    const saved = String((S.settings && S.settings.proxyUrl) || "").trim();
    button.hidden = String(value || "").trim() === saved;
  },

  saveProxyUrl() {
    const node = document.getElementById("set-proxy-url");
    const value = (node ? node.value : (S.proxyUrlDraft || "")).trim();
    const saved = String((S.settings && S.settings.proxyUrl) || "").trim();
    if (value === saved) {
      S.proxyUrlDraft = null;
      const button = document.getElementById("proxy-save");
      if (button) button.hidden = true;
      return;
    }
    run("proxy-save", async () => {
      S.settings = await inv("settings_set", {
        settings: { ...S.settings, proxyUrl: value },
      });
      S.proxyUrlDraft = null;
      const button = document.getElementById("proxy-save");
      if (button) button.hidden = true;
      if (node) node.value = value;
      toast(t("proxySaved"));
    });
  },

  setStrategy(value) {
    run("routing", async () => {
      S.routing = await inv("set_routing_strategy", { strategy: value });
      if (S.routing.accounts) S.accounts = S.routing.accounts;
      toast(t("done"));
    });
  },

  movePriority(id, up) {
    run("order", async () => {
      S.routing = await inv("move_priority", { id, up });
      if (S.routing.accounts) S.accounts = S.routing.accounts;
      // Moving a card is what the manual order is: the planner follows the
      // list only in custom mode, and the switch happens silently otherwise.
      toast(t("orderCustom"));
    });
  },

  resetOrder() {
    run("order", async () => {
      S.routing = await inv("reset_priority");
      if (S.routing.accounts) S.accounts = S.routing.accounts;
      toast(t("done"));
    });
  },

  setRole(id, preferred, backup) {
    run("role-" + id, async () => {
      S.routing = await inv("set_account_role", { id, preferred, backup });
      if (S.routing.accounts) S.accounts = S.routing.accounts;
    });
  },

  deviceStart() {
    run("device", async () => {
      const session = await inv("device_login_start");
      S.deviceLogin = { ...session, done: false };
      A.deviceOpen();
      const interval = Math.max(3, session.interval || 5) * 1000;
      const startedAt = Date.now();
      clearInterval(A._deviceTimer);
      A._deviceTimer = setInterval(async () => {
        if (Date.now() - startedAt > 10 * 60 * 1000) {
          clearInterval(A._deviceTimer);
          S.deviceLogin = null;
          toast(t("deviceTimeout"), true);
          render();
          return;
        }
        try {
          const result = await inv("device_login_poll", {
            deviceAuthId: session.deviceAuthId,
            userCode: session.userCode,
          });
          if (result.done) {
            clearInterval(A._deviceTimer);
            S.accounts = result.accounts;
            S.deviceLogin = null;
            toast(`${t("addAccount")}: ${result.result}`);
            render();
          }
        } catch (error) {
          clearInterval(A._deviceTimer);
          toast(String(error), true);
        }
      }, interval);
    });
  },

  deviceOpen() {
    if (S.deviceLogin && S.deviceLogin.verificationURL) {
      inv("open_url", { url: S.deviceLogin.verificationURL }).catch(() => {});
    }
  },

  modelsLoad() {
    run("models", async () => {
      let rawModels = [];
      try {
        rawModels = (await inv("gateway_models")) || [];
        S.modelsError = null;
      } catch (error) {
        S.models = [];
        S.modelsError = String(error && error.message ? error.message : error);
        return;
      }
      // Dedupe the gateway list by id first; the provider lists below reuse the
      // same set so a model served by two sources renders once.
      const models = [];
      const seen = new Set();
      for (const model of rawModels) {
        const id = String((model && model.id) || "");
        if (seen.has(id)) continue;
        seen.add(id);
        models.push(model);
      }
      // Claude ids are served by the gateway too, but a direct fetch keeps the
      // list fresh right after a login, before the next gateway sync.
      try {
        const claude = await inv("claude_models");
        for (const model of (claude && claude.models) || []) {
          const id = String(model.id);
          if (!seen.has(id)) {
            seen.add(id);
            models.push({ id: model.id, owned_by: "claude", displayName: model.displayName });
          }
        }
      } catch (error) {
        // Gateway down or no Claude account — the base list stays valid.
      }
      // Antigravity ids drive the row tag by membership (not by prefix), since
      // it overlaps the claude-*/gemini-*/gpt-oss id space.
      try {
        const ag = await inv("antigravity_models");
        const ids = new Set();
        for (const model of (ag && ag.models) || []) {
          const id = String(model.id);
          ids.add(id);
          if (!seen.has(id)) {
            seen.add(id);
            models.push({ id, owned_by: "antigravity", displayName: model.displayName });
          }
        }
        S.antigravityIds = ids;
      } catch (error) {
        // Gateway down or no Antigravity account — the base list stays valid.
      }
      S.models = models;
      // Keep Codex's catalog in step after a provider login/disconnect.
      if (IS_TAURI) inv("catalog_sync").catch(() => {});
    });
  },

  modelsSearch(value) {
    S.modelsQuery = value;
    render();
    setTimeout(() => {
      const input = document.getElementById("models-search");
      if (input) {
        input.focus();
        input.setSelectionRange(input.value.length, input.value.length);
      }
    }, 0);
  },

  // MARK: - Codex model pool

  async poolLoad() {
    try {
      S.pool = await inv("codex_pool_models");
      S.poolError = null;
    } catch (error) {
      S.pool = null;
      S.poolError = String(error);
    }
    render();
  },

  async poolRefresh() {
    await run("pool-refresh", async () => {
      S.pool = await inv("codex_models_refresh");
      S.poolError = null;
      poolModalRefresh();
    });
  },

  async poolOpen() {
    S.poolModal = { mode: "pool" };
    S.poolQuery = "";
    S.poolError = null;
    if (!S.pool) await A.poolLoad();
    render();
  },

  async poolOpenAccount(id) {
    S.poolModal = { mode: "account", accountId: id };
    S.poolQuery = "";
    S.poolError = null;
    if (!S.pool) await A.poolLoad();
    const account = (S.accounts || []).find((a) => a.id === id);
    const selected = account ? account.selectedModels : null;
    // null = every visible pool model is on for this account.
    S.poolDraft = selected
      ? selected.slice()
      : ((S.pool && S.pool.models) || []).map((m) => m.slug);
    render();
  },

  poolClose() {
    S.poolModal = null;
    S.poolQuery = "";
    S.poolError = null;
    S.poolDraft = null;
    render();
  },

  poolSearch(value) {
    S.poolQuery = value;
    poolModalRefresh();
  },

  poolToggleGlobal(slug, enabled) {
    run("pool-toggle-" + slug, async () => {
      const result = await inv("set_pool_model", { slug, enabled });
      S.pool = result.pool;
      S.accounts = result.accounts;
      if (result.catalogError) toast(result.catalogError, true);
      // The modal list patches in place: the search field may hold focus.
      poolModalRefresh();
    });
  },

  poolToggleAccount(slug) {
    const draft = new Set(S.poolDraft || []);
    if (draft.has(slug)) draft.delete(slug);
    else draft.add(slug);
    S.poolDraft = Array.from(draft);
    poolModalRefresh();
  },

  // Both buttons act on the filtered list, so a search narrows what
  // select-all/clear touch. Clearing is allowed; Save blocks an empty draft.
  poolSelectAll() {
    S.poolDraft = poolFilteredModels().map((m) => m.slug);
    poolModalRefresh();
  },

  poolClearAll() {
    S.poolDraft = [];
    poolModalRefresh();
  },

  poolSaveAccount() {
    const modal = S.poolModal;
    if (!modal || modal.mode !== "account") return;
    const selected = (S.poolDraft || []).slice();
    if (!selected.length) return;
    run("pool-save-" + modal.accountId, async () => {
      const result = await inv("save_account_models", { id: modal.accountId, selected });
      S.accounts = result.accounts;
      S.pool = result.pool;
      if (result.catalogError) toast(result.catalogError, true);
      A.poolClose();
    });
  },

  async poolApply() {
    await run("pool-apply", async () => {
      const result = await inv("apply_codex_models");
      S.pool = result.pool;
      S.accounts = result.accounts;
      if (result.catalogError) toast(result.catalogError, true);
      else toast(t("done"));
      poolModalRefresh();
    });
  },

  instancesLoad() {
    run("instances", async () => {
      S.instancesData = await inv("instances_list");
    });
  },

  instanceCreate() {
    const input = document.getElementById("instance-name");
    const name = input ? input.value.trim() : "";
    if (!name) return;
    run("instance-create", async () => {
      S.instancesData = await inv("instance_create", { name });
      toast(t("done"));
    });
  },

  async instanceDelete(id) {
    // The confirmation must name the instance, like account deletion.
    const instance = (S.instancesData || []).find((item) => item.id === id);
    const name = (instance && instance.name) || id;
    if (!window.confirm(fmt(t("confirmDeleteInstance"), { name }))) return;
    run("instance-delete", async () => {
      S.instancesData = await inv("instance_delete", { id });
    });
  },

  instanceBind(id, accountId) {
    run("instance-bind", async () => {
      S.instancesData = await inv("instance_bind", { id, accountId: accountId || null });
    });
  },

  instanceLaunch(id) {
    run("instance-launch", async () => {
      const home = await inv("instance_launch", { id });
      toast(`${t("instanceLaunch")}: ${home}`);
    });
  },

  schedulerLoad() {
    run("scheduler", async () => {
      try {
        const [tasks, history] = await Promise.all([
          inv("scheduler_tasks"),
          inv("scheduler_history", { page: 1, limit: 50 }).catch(() => null),
        ]);
        S.scheduler = {
          path: (S.schedulerSummary && S.schedulerSummary.path) || "",
          tasks: Array.isArray(tasks) ? tasks : [],
          history: history && Array.isArray(history.items) ? history.items : [],
        };
        S.schedulerHistoryPage = 1;
        S.schedulerHistoryMore = !!(history && history.hasMore);
        S.schedulerResults = {};
        S.schedulerError = null;
      } catch (error) {
        // Older backend: keep the page usable with the compatibility command.
        try {
          S.scheduler = await inv("scheduler_list");
          S.schedulerHistoryMore = false;
          S.schedulerError = null;
        } catch (fallbackError) {
          S.schedulerError = errorText(fallbackError || error);
        }
      }
    });
  },

  schedulerModelsLoad() {
    run("sched-models", async () => {
      try {
        S.schedulerModels = await inv("scheduler_models");
        S.schedulerModelsError = null;
      } catch (error) {
        S.schedulerModels = null;
        S.schedulerModelsError = errorText(error);
      }
    });
  },

  schedulerToggleResult(id) {
    S.schedulerOpen = S.schedulerOpen === id ? null : id;
    render();
  },

  schedulerResultLoad(id) {
    run("scheduler-result-" + id, async () => {
      const entry = await inv("scheduler_result", { id });
      S.schedulerResults = { ...(S.schedulerResults || {}), [id]: entry };
    });
  },

  schedulerHistoryMore() {
    run("scheduler-history-more", async () => {
      const next = (S.schedulerHistoryPage || 1) + 1;
      const page = await inv("scheduler_history", { page: next, limit: 50 });
      if (!page || !Array.isArray(page.items)) return;
      S.scheduler = {
        ...(S.scheduler || {}),
        history: [...((S.scheduler && S.scheduler.history) || []), ...page.items],
      };
      S.schedulerHistoryPage = next;
      S.schedulerHistoryMore = !!page.hasMore;
    });
  },

  schedulerEdit(id) {
    const task = id ? ((S.scheduler && S.scheduler.tasks) || []).find((item) => item.id === id) : null;
    S.schedulerForm = task
      ? {
        id: task.id,
        name: task.name,
        prompt: task.prompt,
        model: task.model,
        reasoningEffort: task.reasoningEffort || "",
        intervalMinutes: task.intervalMinutes,
        scheduleKind: task.scheduleKind || "interval",
        cronExpression: task.cronExpression || "",
        timeZone: task.timeZone || "",
        workingDirectory: task.workingDirectory || "",
        includeGitContext: !!task.includeGitContext,
        maxTokens: task.maxTokens || 0,
        retryLimit: task.retryLimit || 0,
        retryDelayMinutes: task.retryDelayMinutes || 5,
        dailyTokenLimit: task.dailyTokenLimit || 0,
        enabled: task.enabled,
      }
      : {
        id: "", name: "", prompt: "", model: "", reasoningEffort: "", intervalMinutes: 60,
        scheduleKind: "interval", cronExpression: "", timeZone: "",
        workingDirectory: "", includeGitContext: false, maxTokens: 0,
        retryLimit: 0, retryDelayMinutes: 5, dailyTokenLimit: 0, enabled: true,
        templateId: "", variables: null,
      };
    render();
    if (!S.schedulerModels) A.schedulerModelsLoad();
  },

  schedulerTemplateApply(id) {
    if (!S.schedulerForm) return;
    const template = schedulerTemplate(id);
    if (!template) {
      S.schedulerForm = {
        ...S.schedulerForm,
        templateId: "",
        variables: null,
      };
      render();
      return;
    }
    S.schedulerForm = {
      ...S.schedulerForm,
      templateId: template.id,
      name: t(template.nameKey),
      prompt: template.prompt,
      scheduleKind: template.scheduleKind,
      cronExpression: template.cronExpression || "",
      intervalMinutes: template.intervalMinutes,
      timeZone: S.schedulerForm.timeZone || "",
      variables: Object.fromEntries(template.variables.map((variable) => [variable, ""])),
    };
    render();
  },

  schedulerVarInput(variable, value) {
    if (!S.schedulerForm || !S.schedulerForm.variables) return;
    if (!(variable in S.schedulerForm.variables)) return;
    S.schedulerForm.variables[variable] = value;
  },

  schedulerKindChanged(kind) {
    if (S.schedulerForm) S.schedulerForm.scheduleKind = kind === "cron" ? "cron" : "interval";
    const interval = document.getElementById("sched-interval-row");
    const cron = document.getElementById("sched-cron-row");
    if (interval) interval.style.display = kind === "cron" ? "none" : "";
    if (cron) cron.style.display = kind === "cron" ? "" : "none";
  },

  schedulerFormClose() {
    S.schedulerForm = null;
    S.schedulerModelsError = null;
    render();
  },

  schedulerFormSave() {
    const form = S.schedulerForm || {};
    const value = (id) => {
      const node = document.getElementById(id);
      return node && typeof node.value === "string" ? node.value : "";
    };
    // Read the fields before run(): its first render rebuilds the modal.
    const name = value("sched-name").trim();
    let prompt = value("sched-prompt").trim();
    const model = value("sched-model").trim();
    const reasoningEffort = value("sched-effort").trim();
    const scheduleKind = value("sched-schedule-kind") === "cron" ? "cron" : "interval";
    const cronExpression = value("sched-cron").trim().replace(/\s+/g, " ");
    const timeZone = value("sched-timezone").trim();
    const intervalMinutes = parseInt(value("sched-interval"), 10) || 60;
    const workingDirectory = value("sched-workdir").trim();
    const gitNode = document.getElementById("sched-git-context");
    const includeGitContext = !!(gitNode && gitNode.checked);
    const maxTokens = parseInt(value("sched-max-tokens"), 10) || 0;
    const retryLimit = parseInt(value("sched-retries"), 10) || 0;
    const retryDelayMinutes = parseInt(value("sched-retry-delay"), 10) || 5;
    // 0 means "no limit"; anything else must be a whole 1..1,000,000 value.
    // A cleared field is not a valid limit: the user has to type 0.
    const dailyLimitRaw = value("sched-daily-limit").trim();
    const dailyTokenLimit = dailyLimitRaw === "" ? NaN : Number(dailyLimitRaw);
    const enabledNode = document.getElementById("sched-enabled");
    const enabled = !!(enabledNode && enabledNode.checked);
    if (!name || !prompt || !model) {
      toast(t("schedulerRequired"), true);
      return;
    }
    if (scheduleKind === "interval" && (!Number.isFinite(intervalMinutes) || intervalMinutes < 1)) {
      toast(t("schedulerInterval"), true);
      return;
    }
    if (scheduleKind === "cron" && cronExpression.split(" ").filter(Boolean).length !== 5) {
      toast(t("schedulerCronInvalid"), true);
      return;
    }
    if (!Number.isInteger(dailyTokenLimit) || dailyTokenLimit < 0 || dailyTokenLimit > 1000000) {
      toast(t("schedulerDailyLimitInvalid"), true);
      return;
    }
    // A template is rendered in the renderer: the backend stores the final
    // prompt and never needs to know about {{placeholders}}.
    if (!form.id && form.templateId) {
      const template = schedulerTemplate(form.templateId);
      if (template) {
        for (const variable of template.variables) {
          const raw = (form.variables && form.variables[variable]) || "";
          const replacement = raw.trim();
          if (!replacement) {
            toast(t("schedulerVariableRequired"), true);
            return;
          }
          prompt = prompt.split(`{{${variable}}}`).join(replacement);
        }
      }
    }
    const task = {
      id: form.id || "",
      name,
      prompt,
      model,
      reasoningEffort: reasoningEffort || null,
      scheduleKind,
      cronExpression: scheduleKind === "cron" ? cronExpression : null,
      timeZone: timeZone || null,
      workingDirectory: workingDirectory || null,
      includeGitContext,
      maxTokens: maxTokens > 0 ? maxTokens : null,
      retryLimit,
      retryDelayMinutes,
      dailyTokenLimit: dailyTokenLimit > 0 ? dailyTokenLimit : null,
      intervalMinutes,
      enabled,
    };
    run("sched-save", async () => {
      S.scheduler = await inv("scheduler_save", { task });
      S.schedulerError = null;
      S.schedulerForm = null;
      toast(t("done"));
    });
  },

  schedulerToggle(id, enabled) {
    const task = ((S.scheduler && S.scheduler.tasks) || []).find((item) => item.id === id);
    if (!task) return;
    run("sched-toggle-" + id, async () => {
      S.scheduler = await inv("scheduler_save", { task: { ...task, enabled } });
      S.schedulerError = null;
      toast(t("done"));
    });
  },

  schedulerRunNow(id) {
    run("sched-run-" + id, async () => {
      const name = schedulerTaskName(S.scheduler, id);
      const result = await inv("scheduler_run_now", { id });
      // A busy scheduler queues the request instead of starting it right away:
      // the snapshot goes to the queue bar, the task list stays untouched.
      if (result && result.status === "queued") {
        S.queue = result;
        toast(fmt(t("schedulerRunQueued"), { name }));
        schedulerQueuePoll();
        return;
      }
      S.scheduler = result;
      S.schedulerError = null;
      S.schedulerOpen = id;
      toast(t("done"));
    });
  },

  // Dashboard/tray entry point: one serial run of the earliest due/enabled
  // task. The scheduler page opens so the result is visible immediately.
  schedulerRunNext() {
    run("sched-run-next", async () => {
      if (!S.scheduler) {
        S.scheduler = await inv("scheduler_list");
      }
      const task = schedulerNextTask(S.scheduler);
      if (!task) {
        toast(t("dashNoTasks"));
        return;
      }
      S.section = "scheduler";
      S.busy["sched-run-" + task.id] = true;
      try {
        const result = await inv("scheduler_run_now", { id: task.id });
        if (result && result.status === "queued") {
          S.queue = result;
          toast(fmt(t("schedulerRunQueued"), { name: task.name }));
          schedulerQueuePoll();
          return;
        }
        S.scheduler = result;
        S.schedulerError = null;
        S.schedulerOpen = task.id;
        toast(fmt(t("dashRunNextDone"), { name: task.name }));
      } finally {
        S.busy["sched-run-" + task.id] = false;
      }
    });
  },

  // Stops the active run and drops every waiting request. The command answers
  // with `{status:"cancelling"|"idle"}` plus the new queue contents.
  schedulerCancel() {
    run("sched-cancel", async () => {
      const wasActive = schedulerQueueActive(S.queue);
      const result = await inv("scheduler_cancel");
      const snapshot = result && typeof result === "object" ? result : null;
      if (snapshot) {
        S.queue = {
          queued: Array.isArray(snapshot.queued) ? snapshot.queued : [],
          running: snapshot.running || null,
          cancelling: snapshot.status === "cancelling" || !!snapshot.cancelling,
        };
      }
      const cancelled = S.queue
        ? !!S.queue.cancelling || !!S.queue.running || schedulerQueuedIds(S.queue).length > 0
        : wasActive;
      toast(t(cancelled ? "schedulerCancelDone" : "schedulerCancelIdle"));
      schedulerQueuePoll();
      schedulerListQuiet();
    });
  },

  schedulerDelete(id) {
    const task = ((S.scheduler && S.scheduler.tasks) || []).find((item) => item.id === id);
    const name = (task && task.name) || id;
    if (!window.confirm(fmt(t("confirmDeleteTask"), { name }))) return;
    run("sched-delete-" + id, async () => {
      S.scheduler = await inv("scheduler_delete", { id });
      if (S.schedulerOpen === id) S.schedulerOpen = null;
      toast(t("done"));
    });
  },

  autostartToggle(enabled) {
    run("autostart", async () => {
      S.autostart = await inv("autostart_set", { enabled });
      toast(t("done"));
    });
  },

  notifyToggle(enabled) {
    run("notify", async () => {
      S.settings = await inv("settings_set", {
        settings: { ...S.settings, notifications: enabled },
      });
    });
  },

  notifyDetailToggle(key, enabled) {
    if (["notifyLowQuota", "notifyScheduler", "notifyQuotaReset"].indexOf(key) < 0) return;
    run("notify-detail", async () => {
      S.settings = await inv("settings_set", {
        settings: { ...S.settings, [key]: enabled },
      });
    });
  },

  islandToggle(enabled) {
    S.settings = { ...(S.settings || {}), islandVisible: enabled };
    render();
    run("island", async () => {
      S.settings = await inv("settings_set", { settings: { ...S.settings } });
    });
  },

  islandAutoCollapse(seconds) {
    if ([0, 5, 10, 15, 20].indexOf(seconds) < 0) return;
    S.settings = { ...(S.settings || {}), islandAutoCollapseSeconds: seconds };
    render();
    run("island-timer", async () => {
      S.settings = await inv("settings_set", { settings: { ...S.settings } });
    });
  },

  // Persisted per-card visibility. The optimistic update keeps the checkbox
  // responsive; a failed save surfaces as a toast.
  dashboardCardToggle(setting, enabled) {
    if (DASHBOARD_CARD_SETTINGS.indexOf(setting) < 0) return;
    S.settings = { ...(S.settings || {}), [setting]: enabled };
    render();
    run("dashboard-cards", async () => {
      S.settings = await inv("settings_set", { settings: { ...S.settings } });
    });
  },

  // MARK: Updater

  /// Two states of the sidebar control: quiet «Проверить обновление», and the
  /// gold CTA «Обновить» as soon as a newer release is known.
  updateButton() {
    const button = document.getElementById("update-btn");
    const label = document.getElementById("update-label");
    if (!button || !label) return;
    const newer = !!(S.update && S.update.newer);
    button.classList.toggle("primary", newer);
    label.textContent = newer ? t("update") : t("updateCheck");
  },

  async updateOpen() {
    const modal = document.getElementById("update-modal");
    const title = document.getElementById("update-title");
    const sub = document.getElementById("update-sub");
    const notes = document.getElementById("update-notes");
    const apply = document.getElementById("update-apply");
    const cancel = document.getElementById("update-cancel");
    modal.hidden = false;
    A._updateApplying = false;
    if (cancel) cancel.disabled = false;
    title.textContent = t("updateChecking");
    sub.textContent = "";
    notes.textContent = "";
    notes.style.display = "none";
    apply.style.display = "none";
    try {
      const result = await inv("update_check", { force: true });
      S.update = result;
      if (result.newer) {
        title.textContent = fmt(t("updateAvailable"), { v: result.version });
        sub.textContent = `${(S.info && S.info.version) || ""} → ${result.version}`;
        notes.textContent = result.notes || "";
        notes.style.display = "block";
        apply.style.display = "";
      } else {
        title.textContent = fmt(t("updateUpToDate"), { v: result.version });
      }
      A.updateButton();
    } catch (error) {
      title.textContent = t("updateFailed");
      sub.textContent = String(error && error.message ? error.message : error);
    }
  },

  // MARK: - Local AI Actions

  async localAiLoad() {
    try {
      const [hw, models, rt, dls, migration, install, registry] = await Promise.all([
        window.api.localAi.hardwareInfo().catch(() => null),
        window.api.localAi.modelsList().catch(() => []),
        window.api.localAi.runtimeStatus().catch(() => null),
        window.api.localAi.downloadsList().catch(() => []),
        window.api.localAi.migrationReport().catch(() => null),
        window.api.localAi.runtimeInstallStatus().catch(() => null),
        window.api.localAi.registryHealth().catch(() => null),
      ]);
      if (hw) S.localAi.hardware = hw;
      if (models) S.localAi.models = models;
      if (registry) S.localAi.registry = registry;
      if (rt) S.localAi.runtime = rt;
      if (migration) S.localAi.migration = migration;
      if (install) S.localAi.install = install;
      if (dls) {
        S.localAi.downloads = dls;
        S.localAi.activeDownloadCount = dls.filter(isDownloadActive).length;
      }
      // The token never touches localStorage: the backend keeps it encrypted
      // (DPAPI on Windows) and the UI only learns whether one is stored.
      if (!S.localAi.hfToken) {
        try {
          const stored = await window.api.localAi.hfTokenStatus();
          S.localAi.hfToken = stored ? "__stored__" : "";
        } catch {}
      }
      render();
    } catch (e) {
      console.error("localAiLoad failed", e);
    }
  },

  async localAiPoll() {
    if (S.section !== "local_ai") return;
    // A hung engine can make the status+metrics round trip outlast the 2 s
    // interval. One in-flight poll keeps requests from stacking.
    if (A._localAiPollBusy) return;
    A._localAiPollBusy = true;
    try {
      const [rt, dls, install] = await Promise.all([
        window.api.localAi.runtimeStatus().catch(() => null),
        window.api.localAi.downloadsList().catch(() => null),
        window.api.localAi.runtimeInstallStatus().catch(() => null),
      ]);
      let changed = false;
      if (rt && JSON.stringify(rt) !== JSON.stringify(S.localAi.runtime)) {
        S.localAi.runtime = rt;
        changed = true;
      }
      if (install && JSON.stringify(install) !== JSON.stringify(S.localAi.install)) {
        S.localAi.install = install;
        changed = true;
      }
      if (dls) {
        const activeCount = dls.filter(isDownloadActive).length;
        if (activeCount !== S.localAi.activeDownloadCount || JSON.stringify(dls) !== JSON.stringify(S.localAi.downloads)) {
          // Transition-driven refresh: the model list is re-read exactly when
          // the last active transfer finished, not on a guessed timer.
          const hadActive = (S.localAi.downloads || []).some(isDownloadActive);
          const hasActive = activeCount > 0;
          if (hadActive && !hasActive) {
            const models = await window.api.localAi.modelsList().catch(() => null);
            if (models) S.localAi.models = models;
          }
          S.localAi.downloads = dls;
          S.localAi.activeDownloadCount = activeCount;
          changed = true;
        }
      }
      // Metrics are loopback-only and unnecessary on other tabs: poll them
      // only while the Runtime tab is visible and the engine is running.
      if (rt && rt.isRunning && S.localAi.tab === "runtime") {
        try {
          const metrics = await window.api.localAi.runtimeMetrics();
          if (JSON.stringify(metrics) !== JSON.stringify(S.localAi.metrics) || S.localAi.metricsError) {
            S.localAi.metrics = metrics;
            S.localAi.metricsError = null;
            changed = true;
          }
        } catch (e) {
          const message = errorText(e);
          if (message !== S.localAi.metricsError) {
            S.localAi.metricsError = message;
            changed = true;
          }
        }
      } else if (S.localAi.metrics || S.localAi.metricsError) {
        S.localAi.metrics = null;
        S.localAi.metricsError = null;
        changed = true;
      }
      // The Console is the tail of the engine log. It is refreshed in place so
      // that a full re-render cannot reset a reader's scroll position.
      if (S.localAi.tab === "runtime") {
        try {
          const logs = await window.api.localAi.runtimeLogs(500);
          const signature = JSON.stringify(logs);
          if (signature !== S.localAi.logsSignature) {
            S.localAi.logs = Array.isArray(logs) ? logs : [];
            S.localAi.logsSignature = signature;
            updateRuntimeLogBox();
          }
        } catch (e) {
          // Keep the last good console when the engine log cannot be read.
        }
      }
      if (changed) {
        render();
      }
    } catch (e) {
      // silent
    } finally {
      A._localAiPollBusy = false;
    }
  },

  localAiTab(tab) {
    S.localAi.tab = tab;
    if (tab === "runtime") {
      // Show the tail immediately instead of waiting up to a poll interval.
      loadRuntimeLogs();
    }
    if (tab === "catalog" && (!S.localAi.catalogResults || S.localAi.catalogResults.length === 0)) {
      A.localAiHfPreset("Qwen2.5-Coder");
    } else {
      render();
    }
  },

  localAiSearch(query) {
    S.localAi.searchQuery = query;
    render();
  },

  async localAiImport() {
    try {
      const selected = await inv("plugin:dialog|open", {
        options: {
          multiple: false,
          directory: false,
          filters: [{ name: "GGUF Model", extensions: ["gguf"] }],
        },
      });
      const filePath = Array.isArray(selected) ? selected[0] : selected;
      if (!filePath) return;
      toast(t("loading"));
      await window.api.localAi.importFile(filePath);
      const models = await window.api.localAi.modelsList();
      S.localAi.models = models;
      toast(t("localAiImportSuccess") || "Модель импортирована");
      render();
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  async localAiStart(id) {
    if (!id) return;
    try {
      toast(t("localAiStarting"));
      await window.api.localAi.startModel(id);
      const rt = await window.api.localAi.runtimeStatus();
      S.localAi.runtime = rt;
      render();
      toast(t("localAiStarted"));
    } catch (e) {
      toast(errorText(e), true);
      const rt = await window.api.localAi.runtimeStatus().catch(() => null);
      if (rt) S.localAi.runtime = rt;
      render();
    }
  },

  async localAiStop() {
    try {
      await window.api.localAi.stopRuntime();
      const rt = await window.api.localAi.runtimeStatus();
      S.localAi.runtime = rt;
      S.localAi.metrics = null;
      S.localAi.metricsError = null;
      render();
      toast(t("localAiStopped"));
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  async localAiRuntimeCatalogOpen() {
    S.localAi.runtimeCatalogOpen = true;
    if (S.localAi.runtimeCatalog) {
      render();
      return;
    }
    await A.localAiRuntimeCatalogLoad();
  },

  async localAiRuntimeCatalogLoad() {
    if (S.localAi.runtimeCatalogLoading) return;
    S.localAi.runtimeCatalogLoading = true;
    S.localAi.runtimeCatalogError = null;
    render();
    try {
      const releases = await window.api.localAi.runtimeCatalog();
      S.localAi.runtimeCatalog = Array.isArray(releases) ? releases : [];
    } catch (e) {
      S.localAi.runtimeCatalogError = errorText(e);
    } finally {
      S.localAi.runtimeCatalogLoading = false;
      render();
    }
  },

  async localAiRuntimeCatalogRefresh() {
    await A.localAiRuntimeCatalogLoad();
  },

  localAiRuntimeCatalogClose() {
    S.localAi.runtimeCatalogOpen = false;
    render();
  },

  /// Picks a release asset and starts the existing installer. The catalog
  /// modal closes so the Runtime card owns the single progress display.
  async localAiRuntimeCatalogInstall(tag, variantId) {
    const release = (S.localAi.runtimeCatalog || []).find((item) => item.tag === tag);
    const variant = release && (release.variants || []).find((item) => item.id === variantId);
    if (!variant) {
      toast(t("localAiRuntimeCatalogError"), true);
      return;
    }
    const install = S.localAi.install || {};
    if (["downloading", "verifying", "extracting", "validating", "publishing"].includes(install.stage)) {
      toast(t("localAiRuntimeCatalogInstalling"), true);
      return;
    }
    try {
      await window.api.localAi.runtimeInstall(variant.url, variant.sha256);
      const status = await window.api.localAi.runtimeInstallStatus().catch(() => null);
      if (status) S.localAi.install = status;
      S.localAi.runtimeCatalogOpen = false;
      toast(fmt(t("localAiRuntimeCatalogStarted"), {
        tag: release.tag,
        variant: localAiRuntimeVariantLabel(variant),
      }));
      render();
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  async localAiInstallRuntime() {
    const urlInput = document.getElementById("local-ai-runtime-url");
    const shaInput = document.getElementById("local-ai-runtime-sha");
    const url = urlInput ? urlInput.value.trim() : "";
    const sha256 = shaInput ? shaInput.value.trim() : "";
    if (!url || !/^[0-9a-fA-F]{64}$/.test(sha256)) {
      toast(t("localAiRuntimeInstallInvalid"), true);
      return;
    }
    try {
      await window.api.localAi.runtimeInstall(url, sha256);
      const install = await window.api.localAi.runtimeInstallStatus().catch(() => null);
      if (install) S.localAi.install = install;
      toast(t("localAiRuntimeInstallStarted"));
      render();
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  async localAiCancelRuntimeInstall() {
    try {
      await window.api.localAi.runtimeInstallCancel();
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  /// The archive is never executed during install. Selecting the validated
  /// binary is an explicit user action and only possible with the engine
  /// stopped, so a running model cannot switch under an active request.
  async localAiUseInstalledRuntime() {
    const install = S.localAi.install;
    const rt = S.localAi.runtime;
    if (!install || !install.binaryPath) return;
    if (rt && rt.isRunning) {
      toast(t("localAiRuntimeStopFirst"), true);
      return;
    }
    try {
      await window.api.localAi.setBinaryPath(install.binaryPath);
      if (S.localAi.hardware) S.localAi.hardware.binaryPath = install.binaryPath;
      const status = await window.api.localAi.runtimeStatus().catch(() => null);
      if (status) S.localAi.runtime = status;
      toast(t("saved"));
      render();
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  async localAiStartRuntime() {
    const models = S.localAi.models || [];
    if (models.length === 0) {
      toast(t("localAiNoModels"), true);
      return;
    }
    await A.localAiStart(models[0].id);
  },

  async localAiStopRuntime() {
    await A.localAiStop();
  },

  async localAiRestartRuntime() {
    const cur = S.localAi.runtime && S.localAi.runtime.currentModel;
    if (!cur) return;
    await A.localAiStop();
    await A.localAiStart(cur.id);
  },

  /// Copies the exact value a client must send as `model`.
  async localAiCopyId(id) {
    try {
      await navigator.clipboard.writeText(id);
      toast(t("localAiCopied"));
    } catch {
      toast(t("localAiCopyFailed"), true);
    }
  },

  async localAiOpenFolder(id) {
    let dir = (S.localAi.hardware && S.localAi.hardware.modelsDir) || "";
    if (id) {
      const m = (S.localAi.models || []).find((x) => x.id === id);
      if (m && m.filePath) {
        dir = m.filePath;
      }
    }
    if (dir) {
      try {
        await inv("open_url", { url: dir });
      } catch (e) {
        toast(dir);
      }
    }
  },

  async localAiDelete(id) {
    if (!id) return;
    const m = (S.localAi.models || []).find((x) => x.id === id);
    const name = m ? (m.displayName || m.name || m.id) : id;
    if (!confirm(fmt(t("localAiDeleteConfirm"), { name }))) return;
    try {
      await window.api.localAi.deleteModel(id);
      S.localAi.models = (S.localAi.models || []).filter((x) => x.id !== id);
      const rt = await window.api.localAi.runtimeStatus().catch(() => null);
      if (rt) S.localAi.runtime = rt;
      render();
      toast(t("localAiDeleted") || "Модель удалена");
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  async localAiSettingsModal(id) {
    const model = (S.localAi.models || []).find((m) => m.id === id);
    if (!model) return;
    S.localAi.editingModel = JSON.parse(JSON.stringify(model));
    S.localAi.estimate = null;
    render();

    const s = S.localAi.editingModel.userSettings || {};
    try {
      // The backend reads the real layer/head geometry from the installed
      // GGUF header; a hard-coded `totalLayers: 32` used to distort the KV
      // estimate for every model that is not a 32-layer 4096-hidden llama.
      const est = await window.api.localAi.estimateMemory({
        weightsSize: model.fileSize || 0,
        contextLength: s.contextLength || 4096,
        kvCacheType: s.kvCacheType || "f16",
        batchSize: s.batchSize || 512,
        modelId: model.id,
      });
      S.localAi.estimate = est;
      render();
    } catch {}
  },

  localAiSettingsClose() {
    S.localAi.editingModel = null;
    S.localAi.estimate = null;
    render();
  },

  localAiSystemPromptInput(value) {
    if (!S.localAi.editingModel) return;
    if (!S.localAi.editingModel.userSettings) S.localAi.editingModel.userSettings = {};
    // Kept in state so a re-render (profile change, memory estimate) does not
    // drop what the user typed but has not saved yet.
    S.localAi.editingModel.userSettings.systemPrompt = value;
  },

  localAiProfileChange(profile) {
    if (!S.localAi.editingModel) return;
    if (!S.localAi.editingModel.userSettings) S.localAi.editingModel.userSettings = {};
    const s = S.localAi.editingModel.userSettings;
    s.profile = profile;
    // The preset ids are the Rust enum values (`performance`, `balanced`,
    // `memory_saver`); `auto` leaves the engine's own defaults in place.
    if (profile === "performance") {
      s.gpuOffloadLayers = 999;
      s.contextLength = 4096;
      s.flashAttention = true;
      s.kvCacheType = "f16";
    } else if (profile === "balanced") {
      s.gpuOffloadLayers = 999;
      s.contextLength = 16384;
      s.flashAttention = true;
      s.kvCacheType = "f16";
    } else if (profile === "memory_saver") {
      s.gpuOffloadLayers = 0;
      s.contextLength = 2048;
      s.flashAttention = false;
      s.kvCacheType = "q4_0";
    }
    render();
  },

  async localAiSettingsSave() {
    return A.localAiSettingsPersist(false);
  },

  /// Saves the patch and immediately restarts the model, because the engine
  /// only reads context/KV/offload/threads from `models.ini` at launch.
  async localAiSettingsSaveRestart() {
    return A.localAiSettingsPersist(true);
  },

  async localAiSettingsPersist(restart) {
    const m = S.localAi.editingModel;
    if (!m) return;
    const value = (id) => {
      const el = document.getElementById(id);
      return el ? el.value : null;
    };
    const checked = (id) => {
      const el = document.getElementById(id);
      return el ? !!el.checked : null;
    };
    const stored = m.userSettings || {};

    // A patch, not a full object: fields without an input (top-k, repeat
    // penalty, batch size, …) keep their stored value instead of being reset
    // to constants. `numberOrNull` keeps a deliberate 0.
    const settings = {
      profile: value("local-ai-setting-profile") || stored.profile || "auto",
      contextLength: numberOrNull(value("local-ai-setting-context")),
      maxOutputTokens: numberOrNull(value("local-ai-setting-max-tokens")),
      gpuOffloadLayers: numberOrNull(value("local-ai-setting-gpu-layers")),
      cpuThreads: numberOrNull(value("local-ai-setting-threads")),
      kvCacheType: value("local-ai-setting-kv-cache") || stored.kvCacheType || "f16",
      flashAttention: checked("local-ai-setting-flash-attn"),
      temperature: numberOrNull(value("local-ai-setting-temp")),
      topP: numberOrNull(value("local-ai-setting-topp")),
    };
    const seed = numberOrNull(value("local-ai-setting-seed"));
    if (seed != null) settings.seed = Math.trunc(seed);
    const reasoning = checked("local-ai-setting-reasoning");
    if (reasoning != null) settings.reasoningEnabled = reasoning;
    // Sent even when empty: an empty field means "use the model's own
    // template", which clears a previously saved override.
    const templateEl = document.getElementById("local-ai-setting-chat-template");
    if (templateEl) settings.chatTemplate = templateEl.value.trim();
    // Same for the prompt: an empty field clears it so the relay stops adding
    // one to that model's requests.
    const promptEl = document.getElementById("local-ai-setting-system-prompt");
    if (promptEl) settings.systemPrompt = promptEl.value.trim();

    // Missing inputs are `null`, which means "not edited" — not "zero".
    Object.keys(settings).forEach((key) => {
      if (settings[key] === null) delete settings[key];
    });

    try {
      const updated = await window.api.localAi.saveSettings(m.id, settings);
      const idx = (S.localAi.models || []).findIndex((x) => x.id === m.id);
      if (idx !== -1) {
        S.localAi.models[idx] = updated;
      }
      if (restart) {
        // Saved settings are pending until the engine relaunches with the
        // rewritten preset. Surface a failed restart instead of leaving the
        // old engine silently serving stale knobs.
        try {
          await window.api.localAi.startModel(m.id);
        } catch (e) {
          toast(errorText(e), true);
        }
        const [models, rt] = await Promise.all([
          window.api.localAi.modelsList().catch(() => null),
          window.api.localAi.runtimeStatus().catch(() => null),
        ]);
        if (models) S.localAi.models = models;
        if (rt) S.localAi.runtime = rt;
      }
      S.localAi.editingModel = null;
      S.localAi.estimate = null;
      // A successful save closes the dialog; a toast here only duplicated the
      // close and lingered over the list.
      render();
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  /// Explicit recovery from a damaged `models.json`: the backend keeps a copy
  /// and only then starts an empty registry.
  async localAiRegistryRecover() {
    try {
      S.localAi.registry = await window.api.localAi.registryRecover();
      const models = await window.api.localAi.modelsList().catch(() => null);
      if (models) S.localAi.models = models;
      toast(t("localAiRegistryRecovered"));
      render();
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  localAiTestModal(id) {
    const m = (S.localAi.models || []).find((x) => x.id === id);
    const name = m ? (m.displayName || m.name || m.id) : id;
    S.localAi.testModal = {
      modelId: id,
      modelName: name,
      prompt: "Why is the sky blue? Answer in 2 sentences.",
      response: "",
      tokensPerSec: null,
      generating: false,
    };
    render();
  },

  localAiTestClose() {
    S.localAi.testModal = null;
    render();
  },

  localAiTestPromptInput(val) {
    if (S.localAi.testModal) {
      S.localAi.testModal.prompt = val;
    }
  },

  async localAiTestSend() {
    const tm = S.localAi.testModal;
    if (!tm || tm.generating) return;
    const promptInput = document.getElementById("local-ai-test-prompt-input");
    const prompt = promptInput ? promptInput.value.trim() : (tm.prompt || "").trim();
    if (!prompt) return;

    const rt = S.localAi.runtime;
    if (!rt || !rt.isRunning || !rt.currentModel || rt.currentModel.id !== tm.modelId) {
      toast(t("localAiStarting"));
      await window.api.localAi.startModel(tm.modelId);
      const newRt = await window.api.localAi.runtimeStatus();
      S.localAi.runtime = newRt;
    }

    tm.generating = true;
    tm.response = "";
    tm.tokensPerSec = null;
    tm.truncated = false;
    render();

    const startTime = performance.now();
    let tokenCount = 0;

    try {
      const rtNow = S.localAi.runtime || {};
      const port = rtNow.port || 18318;
      // The engine is started with a per-launch UUID token, so a fixed string
      // here would always answer 401.
      const token = rtNow.internalToken || "";
      const resp = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${token}`,
        },
        body: JSON.stringify({
          model: tm.modelId,
          messages: [{ role: "user", content: prompt }],
          stream: true,
          temperature: 0.7,
          max_tokens: 1536,
        }),
      });

      if (!resp.ok) {
        throw new Error(`HTTP ${resp.status}: ${await resp.text()}`);
      }

      const reader = resp.body.getReader();
      const decoder = new TextDecoder("utf-8");
      let buffer = "";

      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop();

        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed.startsWith("data:")) continue;
          const dataStr = trimmed.slice(5).trim();
          if (dataStr === "[DONE]") break;
          try {
            const parsed = JSON.parse(dataStr);
            const choice = parsed.choices && parsed.choices[0];
            const deltaObj = (choice && choice.delta) || {};
            // Reasoning models stream their scratchpad in reasoning_content and
            // leave content null, which used to produce an empty box.
            const delta = deltaObj.content || deltaObj.reasoning_content || "";
            if (choice && choice.finish_reason === "length") {
              tm.truncated = true;
            }
            if (parsed.timings && parsed.timings.predicted_per_second) {
              tm.tokensPerSec = parsed.timings.predicted_per_second;
            }
            if (delta) {
              tm.response += delta;
              tokenCount++;
              const elapsedSec = (performance.now() - startTime) / 1000;
              if (elapsedSec > 0.5) {
                tm.tokensPerSec = tokenCount / elapsedSec;
              }
              const logBox = document.querySelector(".terminal-logs.mono");
              if (logBox) logBox.textContent = tm.response;
            }
          } catch {}
        }
      }
      const elapsedSec = (performance.now() - startTime) / 1000;
      if (elapsedSec > 0) {
        tm.tokensPerSec = tokenCount / elapsedSec;
      }
    } catch (e) {
      tm.response += `\n[Error: ${errorText(e)}]`;
    } finally {
      tm.generating = false;
      render();
    }
  },

  localAiHfSearchInput(val) {
    S.localAi.catalogQuery = val;
  },

  async localAiHfSearch() {
    const q = (S.localAi.catalogQuery || "").trim();
    if (!q) return;
    S.localAi.catalogLoading = true;
    render();
    try {
      const results = await window.api.localAi.hfSearch(q, 20, hfTokenArg());
      S.localAi.catalogResults = results || [];
      if (results && results.length > 0 && !S.localAi.selectedRepoId) {
        A.localAiSelectRepo(results[0].id);
      }
    } catch (e) {
      toast(errorText(e), true);
    } finally {
      S.localAi.catalogLoading = false;
      render();
    }
  },

  localAiHfPreset(query) {
    S.localAi.catalogQuery = query;
    A.localAiHfSearch();
  },

  async localAiSelectRepo(repoId) {
    S.localAi.selectedRepoId = repoId;
    S.localAi.repoDetailsLoading = true;
    S.localAi.repoDetails = null;
    render();
    try {
      const details = await window.api.localAi.hfModelDetails(repoId, hfTokenArg());
      S.localAi.repoDetails = details;
    } catch (e) {
      toast(errorText(e), true);
    } finally {
      S.localAi.repoDetailsLoading = false;
      render();
    }
  },

  async localAiDownloadQuant(repoId, filename, size, sha256, downloadUrl) {
    if (!repoId || !filename) return;
    // The backend already built (and percent-encoded) the resolve URL; only
    // fall back to a local one when an older payload has no `downloadUrl`.
    const url = downloadUrl || `https://huggingface.co/${repoId}/resolve/main/${filename}`;
    const quantMatch = filename.match(/(Q\d+_[A-Z0-9_]+|F16|F32|IQ\d+_[A-Z0-9_]+)/i);
    const quantization = quantMatch ? quantMatch[1].toUpperCase() : "GGUF";

    try {
      toast(t("localAiDownloadStarting") || "Запуск загрузки...");
      await window.api.localAi.downloadStart({
        repoId,
        filename,
        downloadUrl: url,
        quantization,
        token: hfTokenArg(),
        sha256: sha256 || null,
      });
      toast(t("localAiDownloadStarted") || "Загрузка добавлена");
      S.localAi.tab = "downloads";
      const dls = await window.api.localAi.downloadsList().catch(() => []);
      S.localAi.downloads = dls;
      S.localAi.activeDownloadCount = dls.filter(isDownloadActive).length;
      render();
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  async localAiCancelDownload(modelId) {
    if (!modelId) return;
    try {
      await window.api.localAi.downloadCancel(modelId);
      const dls = await window.api.localAi.downloadsList().catch(() => []);
      S.localAi.downloads = dls;
      S.localAi.activeDownloadCount = dls.filter(isDownloadActive).length;
      render();
      toast(t("localAiDownloadCancelled") || "Загрузка отменена");
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  /// Removes finished transfers in the backend, then re-reads the list. Only
  /// filtering the local array made the rows reappear on the next poll.
  async localAiClearDownloads() {
    try {
      await window.api.localAi.downloadsClear();
    } catch (e) {
      toast(errorText(e), true);
      return;
    }
    const dls = await window.api.localAi.downloadsList().catch(() => []);
    S.localAi.downloads = dls;
    S.localAi.activeDownloadCount = dls.filter(isDownloadActive).length;
    render();
  },

  async localAiPickModelsDir() {
    try {
      const selected = await inv("plugin:dialog|open", {
        options: {
          directory: true,
          multiple: false,
        },
      });
      const dirPath = Array.isArray(selected) ? selected[0] : selected;
      if (!dirPath) return;
      const input = document.getElementById("local-ai-models-dir");
      if (input) input.value = dirPath;
      toast(dirPath);
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  async localAiPickBinary() {
    try {
      const selected = await inv("plugin:dialog|open", {
        options: {
          directory: false,
          multiple: false,
          filters: [{ name: "Executable", extensions: ["exe", ""] }],
        },
      });
      const binPath = Array.isArray(selected) ? selected[0] : selected;
      if (!binPath) return;
      const input = document.getElementById("local-ai-bin-path");
      if (input) input.value = binPath;
      await A.localAiSaveBinary();
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  async localAiSaveBinary() {
    const input = document.getElementById("local-ai-bin-path");
    const path = input ? input.value.trim() : "";
    try {
      await window.api.localAi.setBinaryPath(path || null);
      if (S.localAi.hardware) S.localAi.hardware.binaryPath = path;
      toast(t("saved"));
      render();
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  async localAiSaveHfToken() {
    const input = document.getElementById("local-ai-hf-token");
    const token = input ? input.value.trim() : "";
    try {
      await window.api.localAi.hfTokenSet(token);
      S.localAi.hfToken = token ? "__stored__" : "";
      toast(t("saved"));
      render();
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  localAiHfTokenModal() {
    S.localAi.showHfTokenModal = true;
    render();
  },

  localAiHfTokenModalClose() {
    S.localAi.showHfTokenModal = false;
    render();
  },

  async localAiHfTokenModalSave() {
    const input = document.getElementById("modal-hf-token-input");
    const token = input ? input.value.trim() : "";
    try {
      await window.api.localAi.hfTokenSet(token);
      S.localAi.hfToken = token ? "__stored__" : "";
      S.localAi.showHfTokenModal = false;
      render();
      toast(t("saved"));
    } catch (e) {
      toast(errorText(e), true);
    }
  },

  localAiCopyLogs() {
    const logs = (S.localAi.logs || []).join("\n");
    if (typeof A.copy === "function") {
      A.copy(logs);
    } else if (navigator.clipboard) {
      navigator.clipboard.writeText(logs).then(() => toast(t("copied")));
    }
  },

  async localAiClearLogs() {
    try {
      await window.api.localAi.clearRuntimeLogs();
    } catch (e) {
      toast(errorText(e), true);
      return;
    }
    S.localAi.logs = [];
    S.localAi.logsSignature = "[]";
    updateRuntimeLogBox();
  },

  updateClose() {
    // While the swap runs the window must not be able to hide.
    if (A._updateApplying) return;
    const modal = document.getElementById("update-modal");
    if (modal) modal.hidden = true;
  },

  async updateApply() {
    if (!S.update || !S.update.newer) return;
    const sub = document.getElementById("update-sub");
    const apply = document.getElementById("update-apply");
    const cancel = document.getElementById("update-cancel");
    // Cancel disappears as soon as applying starts; it comes back only if
    // the swap fails and the window stays.
    A._updateApplying = true;
    if (cancel) cancel.disabled = true;
    apply.style.display = "none";
    sub.textContent = t("updateDownloading");
    try {
      await inv("update_apply", { url: S.update.assetURL, digest: S.update.digest });
      sub.textContent = t("updateInstalling");
    } catch (error) {
      sub.textContent = String(error && error.message ? error.message : error);
      A._updateApplying = false;
      if (cancel) cancel.disabled = false;
      apply.style.display = "";
    }
  },
};

window.A = A;
