// Melon Tools — user actions (W6). Loaded before app.js; helpers and page
// renderers are global classic-script bindings available when a method runs.

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
              && !id.startsWith("vercel/")).length
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
    const claude = document.getElementById("claude-enabled");
    S.settings = {
      ...S.settings,
      ...(openrouter ? { openrouterEnabled: openrouter.checked } : {}),
      ...(opencode ? { opencodeEnabled: opencode.checked } : {}),
      ...(deepinfra ? { deepinfraEnabled: deepinfra.checked } : {}),
      ...(vercel ? { vercelEnabled: vercel.checked } : {}),
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
      const counts = result.result || {};
      toast(fmt(t("importJsonDone"), {
        n: counts.imported ?? 0,
        added: counts.added ?? 0,
        updated: counts.updated ?? 0,
        skipped: counts.skipped ?? 0,
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
    const openrouterEnabledNode = document.getElementById("or-enabled");
    const opencodeEnabledNode = document.getElementById("oc-enabled");
    const deepinfraEnabledNode = document.getElementById("di-enabled");
    const vercelEnabledNode = document.getElementById("vc-enabled");
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
    const previous = {
      openrouter: S.settings.openrouterKey || "",
      deepinfra: S.settings.deepinfraKey || "",
      vercel: S.settings.vercelKey || "",
    };
    run("keys", async () => {
      S.settings = await inv("settings_set", {
        settings: {
          ...S.settings,
          openrouterKey,
          opencodeKey,
          deepinfraKey,
          vercelKey,
          openrouterEnabled,
          opencodeEnabled,
          deepinfraEnabled,
          vercelEnabled,
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
      toast(t("done"));
    });
  },

  loadProviderModels(provider) {
    const prefix = provider === "deepinfra" ? "di" : "vc";
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
    const lang = langNode ? langNode.value : S.lang;
    const port = parseInt(portNode ? portNode.value : "", 10);
    const quotaInterval = parseInt(intervalNode ? intervalNode.value : "", 10);
    const proxyEnabled = proxyEnabledNode ? proxyEnabledNode.checked : !!(S.settings && S.settings.proxyEnabled);
    const proxyUrl = proxyUrlNode ? proxyUrlNode.value.trim() : ((S.settings && S.settings.proxyUrl) || "");
    const proxyBypass = proxyBypassNode ? proxyBypassNode.value.trim() : ((S.settings && S.settings.proxyBypass) || "127.0.0.1,localhost");
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
        },
      });
      S.lang = lang;
      toast(t("done"));
      await A.refreshStatus();
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
