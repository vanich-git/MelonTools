// Melon Tools — backend access (W6). The Tauri side goes through the
// narrow window.melon bridge (mt-bridge.js, W9); without Tauri a small
// mock answers with demo data so the design can be reviewed anywhere.

const IS_TAURI = !!(window.melon && window.melon.available);

// MARK: - Backend

async function inv(cmd, args = {}) {
  if (IS_TAURI) {
    return window.melon.invoke(cmd, args);
  }
  return mock(cmd, args);
}

// W5: one deadline per command, so a single hung IPC call cannot stall the
// whole status tick. The underlying call is not cancelled — only the caller
// stops waiting for it.
function invTimed(cmd, args = {}, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${cmd}: timeout`)), timeoutMs);
    inv(cmd, args).then(
      (value) => { clearTimeout(timer); resolve(value); },
      (error) => { clearTimeout(timer); reject(error); },
    );
  });
}

// Browser preview only: a fake Codex pool so the picker modal works without
// Tauri. selectedCount drifts as set_pool_model toggles slugs in the demo.
const DEMO_POOL_MODELS = [
  { slug: "gpt-6.1-sol", display: "GPT-6.1 Sol", contextLength: 400000, priority: 100, selectedCount: 2, accountCount: 2 },
  { slug: "gpt-5.5-codex", display: "GPT-5.5 Codex", contextLength: 272000, priority: 90, selectedCount: 1, accountCount: 2 },
  { slug: "gpt-4.1-codex-mini", display: "GPT-4.1 Codex Mini", contextLength: 200000, priority: 80, selectedCount: 0, accountCount: 2 },
];
const DEMO_AVAILABILITY = {
  "demo-1": [
    { model: "gpt-6.1-sol", available: true },
    { model: "gpt-5.5-codex", available: false },
  ],
};
function demoPoolSnapshot() {
  return {
    models: DEMO_POOL_MODELS.map((model) => Object.assign({}, model)),
    selectedCount: DEMO_POOL_MODELS.filter((model) => model.selectedCount > 0).length,
    accountCount: 2,
  };
}

// Browser preview data (used only outside Tauri).
function mock(cmd, args) {
  const nowSec = Date.now() / 1000;
  const demoAccounts = [
    {
      id: "demo-1", email: "account-1@example.invalid", displayName: "account-1@example.invalid", planType: "plus",
      current: true, subscriptionActiveUntil: "2026-11-18T05:54:42Z", blocked: false, blockInfo: null,
      hourlyRemaining: 100, weeklyRemaining: 85, hourlyResetAt: nowSec + 16698, weeklyResetAt: nowSec + 583541,
      hourlyWindowPresent: true, weeklyWindowPresent: true, quotaUpdatedAt: nowSec - 40,
      hourlyReservePercent: 5, weeklyReservePercent: null, preferredFirst: true, hasTokens: true,
      selectedModels: null,
    },
    {
      id: "demo-2", email: "account-2@example.invalid", displayName: "account-2@example.invalid", planType: "plus",
      subscriptionActiveUntil: "2026-11-13T13:01:27Z", blocked: true,
      blockInfo: { code: "hourly_reserve", remaining: 4, limit: 5 },
      hourlyRemaining: 4, weeklyRemaining: 85, hourlyResetAt: nowSec + 3600, weeklyResetAt: nowSec + 583000,
      hourlyWindowPresent: true, weeklyWindowPresent: true, quotaUpdatedAt: nowSec - 120,
      hourlyReservePercent: 5, weeklyReservePercent: null, preferredFirst: false, hasTokens: true,
      selectedModels: ["gpt-6.1-sol"],
    },
  ];
  const historySeries = (key, hourlyLatest, weeklyLatest) => Array.from({ length: 12 }, (_, index) => {
    const age = 11 - index;
    const drift = Math.min(age * 0.4, 6);
    return {
      key,
      provider: key === "claude" ? "claude" : key === "openrouter" ? "openrouter" : "codex",
      timestamp: nowSec - age * 300,
      hourlyLeft: Math.max(0, Math.min(100, hourlyLatest - drift)),
      weeklyLeft: Math.max(0, Math.min(100, weeklyLatest - drift * 0.3)),
    };
  });
  const historyMocks = [
    ...historySeries("demo-1", 100, 85),
    ...historySeries("demo-2", 4, 85),
    ...historySeries("claude", 72, 41),
    ...historySeries("openrouter", 60, 30),
  ];
  const mocks = {
    app_info: { name: "Melon Tools", version: "3.1.1", platform: "windows", dataDir: "C:\\Users\\you\\AppData\\Roaming\\MelonTools", codexHome: "C:\\Users\\you\\.codex" },
    settings_get: { port: 18317, apiKey: "sk-melon-demo-7f3c2a91", lang: S.lang, quotaInterval: 300, openrouterKey: "", opencodeKey: "", deepinfraKey: "", vercelKey: "", opencodeEnabled: true, openrouterEnabled: true, deepinfraEnabled: true, vercelEnabled: true, deepinfraModels: [], vercelModels: [], claudeEnabled: false, claudeApiKey: "", notifications: true, notifyLowQuota: true, notifyScheduler: true, notifyQuotaReset: true, dashboardShowPoolHealth: true, dashboardShowQuotaTrends: true, dashboardShowSpend: true, dashboardShowScheduler: true, quotaResetNotified: [], proxyEnabled: false, proxyUrl: "", proxyBypass: "127.0.0.1,localhost", codexExePath: "" },
    settings_set: (a) => a.settings,
    vault_list: () => demoAccounts.map((account) => Object.assign({}, account, { modelAvailability: DEMO_AVAILABILITY[account.id] || null })),
    codex_pool_models: () => demoPoolSnapshot(),
    codex_models_refresh: () => demoPoolSnapshot(),
    set_pool_model: (a) => {
      const model = DEMO_POOL_MODELS.find((item) => item.slug === a.slug);
      if (model) model.selectedCount = a.enabled ? model.accountCount : 0;
      return { pool: demoPoolSnapshot(), accounts: demoAccounts, catalogError: null };
    },
    save_account_models: (a) => {
      const account = demoAccounts.find((item) => item.id === a.id);
      if (!a.selected || !a.selected.length) return Promise.reject("хотя бы одна модель");
      if (account) account.selectedModels = a.selected.slice();
      return { accounts: demoAccounts, pool: demoPoolSnapshot(), catalogError: null };
    },
    apply_codex_models: () => ({ pool: demoPoolSnapshot(), accounts: demoAccounts, custom: 0 }),
    quota_history: historyMocks,
    quota_refresh: { accounts: demoAccounts, errors: [], syncedAccounts: 2 },
    gateway_status: { running: true, port: 18317, requestsLastMinute: 0, sidecarFound: true, dataDir: "…", logPath: "…\\gateway.log" },
    gateway_start: "started", gateway_stop: "stopped", gateway_sync: { syncedAccounts: 2 },
    gateway_check: '{"model":"gpt-6-luna","choices":[{"message":{"content":"Понг! 🏓"}}]}',
    switch_account: { authPath: "C:\\Users\\you\\.codex\\auth.json" },
    import_current_auth: { result: "added", accounts: demoAccounts },
    account_refresh_tokens: demoAccounts,
    save_reserves: demoAccounts,
    delete_account: demoAccounts,
    openrouter_refresh: { totalCredits: 30, totalUsage: 29.87, remaining: 0.13, label: "melon", usage: 0.09, limit: 1000, limitRemaining: 999.9, isFreeTier: false, status: "ok" },
    vercel_refresh: { balance: 42.5, totalUsed: 118.2, status: "ok", updatedAt: new Date().toISOString() },
    provider_models_load: (a) => a.provider === "deepinfra"
      ? { count: 2, models: [
          { id: "deepseek-ai/DeepSeek-V4", display: "DeepSeek V4", contextWindow: 131072, promptPerToken: 0.00000027, completionPerToken: 0.0000011, supportsImages: true },
          { id: "Qwen/Qwen3.5-235B", display: "Qwen 3.5 235B", contextWindow: 262144, promptPerToken: 0.0000002, completionPerToken: 0.0000008, supportsImages: false },
        ] }
      : { count: 2, models: [
          { id: "anthropic/claude-sonnet-4.6", display: "Claude Sonnet 4.6", contextWindow: 200000, promptPerToken: 0.000003, completionPerToken: 0.000015, supportsImages: true },
          { id: "openai/gpt-6.1", display: "GPT-6.1", contextWindow: 400000, promptPerToken: 0.000001, completionPerToken: 0.000004, supportsImages: true },
        ] },
    claude_login_start: { url: "https://example.invalid/oauth/authorize?state=demo-state", state: "demo-state" },
    claude_login_status: { status: "wait" },
    claude_login_cancel: { canceled: true },
    claude_credentials: { credentials: [{ name: "claude-demo.json", type: "claude", email: "demo@claude.invalid" }] },
    claude_models: { models: [{ id: "claude-opus-5-5", displayName: "Claude Opus 5.5" }, { id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5" }, { id: "claude-haiku-4-7", displayName: "Claude Haiku 4.7" }], count: 3 },
    claude_usage: { connected: true, email: "demo@claude.invalid", plan: "Pro", fiveHourPercent: 72, fiveHourReset: new Date(Date.now() + 2.5 * 3600 * 1000).toISOString(), weeklyPercent: 41, weeklyReset: new Date(Date.now() + 3.2 * 86400 * 1000).toISOString(), modelCount: 3, updatedAt: new Date().toISOString(), error: null, status: "ok" },
    claude_refresh: { ok: true },
    claude_disconnect: { removed: 1, remaining: 0 },
    antigravity_login_start: { url: "https://example.invalid/oauth/antigravity?state=ag-demo-state", state: "ag-demo-state" },
    antigravity_login_status: { status: "wait" },
    antigravity_login_cancel: { canceled: true },
    antigravity_credentials: { credentials: [{ name: "antigravity-demo@gmail.invalid", type: "antigravity", email: "demo@gmail.invalid" }] },
    antigravity_models: { models: [
      { id: "claude-opus-4-6-thinking", displayName: "Claude Opus 4.6 Thinking" },
      { id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6" },
      { id: "claude-opus-5-5-high", displayName: "Claude Opus 5.5 High" },
      { id: "claude-sonnet-5-5-high", displayName: "Claude Sonnet 5.5 High" },
      { id: "gemini-4-argon-high", displayName: "Gemini 4 Argon High" },
      { id: "gemini-3.8-flash-high", displayName: "Gemini 3.8 Flash High" },
      { id: "gemini-3-flash", displayName: "Gemini 3 Flash" },
      { id: "gemini-3.1-flash-image", displayName: "Gemini 3.1 Flash Image" },
      { id: "gpt-oss-120b-medium", displayName: "GPT-OSS 120B Medium" },
      { id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash Lite" },
      { id: "gemini-3.5-flash-lite", displayName: "Gemini 3.5 Flash Lite" },
    ], count: 11 },
    antigravity_metrics: { connected: true, email: "demo@gmail.invalid", projectId: "melon-demo-project", modelCount: 11, updatedAt: new Date().toISOString(), error: null, status: "ok" },
    antigravity_refresh: { ok: true },
    antigravity_disconnect: { removed: 1, remaining: 0 },
    codex_route_status: { configPath: "C:\\Users\\you\\.codex\\config.toml", provider: "melon_local_access", ours: true, catalogExists: true, catalogPath: "C:\\Users\\you\\.codex\\melon-model-catalog.json" },
    codex_route_apply: { route: { provider: "melon_local_access", ours: true, catalogExists: true }, catalogCustom: 32 },
    codex_route_remove: { provider: null, ours: false, catalogExists: true },
    codex_app_status: () => demoCodexStatus(),
    codex_app_set_path: (a) => {
      DEMO_CODEX_PATH = a.path;
      return demoCodexStatus();
    },
    codex_app_forget_path: () => {
      DEMO_CODEX_PATH = "";
      return demoCodexStatus();
    },
    codex_app_open: () => DEMO_CODEX_PATH
      ? { path: DEMO_CODEX_PATH, source: "manual", debugPort: 55660, restarted: false, elevated: false, route: { provider: "melon_local_access", ours: true, catalogExists: true } }
      : Promise.reject("codex_not_found"),
    "plugin:dialog|open": "C:\\Users\\you\\AppData\\Local\\Programs\\ChatGPT\\ChatGPT.exe",
    bridge_status: { attached: true, debugPort: 55660, model: "GPT-6.1 Sol", targets: 3, reason: null, session: { total: { total: 2730 }, cost: { total: 0.42, providers: { openai: { usd: 0.32 }, opencode: { usd: 0.10 }, deepinfra: { usd: 0.014 }, vercel: { usd: 0.021 } } } } },
    routing_state: { strategy: "auto", strategies: ["auto", "quotaHighFirst", "quotaLowFirst", "planHighFirst", "planLowFirst", "expirySoonFirst", "custom"], priorityOrder: [], orderedIds: ["demo-1", "demo-2"], blockedIds: ["demo-2"] },
    set_routing_strategy: (a) => ({ strategy: a.strategy, orderedIds: ["demo-1", "demo-2"], blockedIds: ["demo-2"], accounts: demoAccounts }),
    move_priority: { strategy: "custom", orderedIds: ["demo-2", "demo-1"], blockedIds: [], accounts: demoAccounts },
    reset_priority: { strategy: "auto", orderedIds: ["demo-1", "demo-2"], blockedIds: [], accounts: demoAccounts },
    set_account_role: { strategy: "auto", orderedIds: ["demo-1", "demo-2"], blockedIds: [], accounts: demoAccounts },
    device_login_start: { deviceAuthId: "demo", userCode: "AB12-CD34", interval: 30, verificationURL: "https://auth.openai.com/codex/device" },
    device_login_poll: { done: false },
    gateway_models: [{ id: "gpt-6.1-sol", owned_by: "openai" }, { id: "opencode/grok-4.7", owned_by: "opencode-go" }],
    gateway_recent_calls: [{ time: "19:19:41", status: "200", duration: "9.743s", method: "POST", path: "/v1/responses" }],
    scheduler_list: () => demoScheduler(),
    scheduler_save: (a) => {
      const demo = demoScheduler();
      const input = (a && a.task) || {};
      const now = nowSec;
      const task = {
        id: input.id || "demo-task-" + (demo.tasks.length + 1),
        name: input.name || "",
        prompt: input.prompt || "",
        model: input.model || "",
        reasoningEffort: input.reasoningEffort || null,
        scheduleKind: input.scheduleKind === "cron" ? "cron" : "interval",
        cronExpression: input.cronExpression || null,
        timeZone: input.timeZone || null,
        intervalMinutes: input.intervalMinutes || 60,
        enabled: input.enabled !== false,
        createdAt: now,
        nextRunAt: input.enabled === false ? null : now + (input.intervalMinutes || 60) * 60,
        lastRunAt: null, lastStatus: "never", lastError: null, lastResult: "", lastDurationMs: null, lastTokens: null,
        maxTokens: input.maxTokens || null,
        dailyTokenLimit: input.dailyTokenLimit || null,
        retryLimit: input.retryLimit || 0,
        retryDelayMinutes: input.retryDelayMinutes || 5,
      };
      const index = demo.tasks.findIndex((item) => item.id === task.id);
      if (index >= 0) demo.tasks[index] = { ...demo.tasks[index], ...task, createdAt: demo.tasks[index].createdAt };
      else demo.tasks.push(task);
      return demo;
    },
    scheduler_delete: (a) => {
      const demo = demoScheduler();
      demo.tasks = demo.tasks.filter((task) => task.id !== (a && a.id));
      demo.history = demo.history.filter((entry) => entry.taskId !== (a && a.id));
      return demo;
    },
    scheduler_run_now: (a) => demoRunNow(a && a.id),
    scheduler_queue: () => ({
      queued: DEMO_QUEUE.queued.slice(),
      running: DEMO_QUEUE.running,
      cancelling: DEMO_QUEUE.cancelling,
    }),
    scheduler_cancel: () => {
      DEMO_QUEUE.queued = [];
      if (DEMO_QUEUE.running) {
        DEMO_QUEUE.cancelling = true;
        return { status: "cancelling", queued: [], running: DEMO_QUEUE.running };
      }
      return { status: "idle", queued: [], running: null };
    },
    scheduler_models: { count: 5, ids: ["gpt-6.1-sol", "claude-opus-5-5", "opencode/grok-4.7", "deepinfra/deepseek-ai/DeepSeek-V4", "vercel/anthropic/claude-sonnet-4.6"], groups: [
      { id: "gateway", ids: ["gpt-6.1-sol"] },
      { id: "claude", ids: ["claude-opus-5-5"] },
      { id: "opencode", ids: ["opencode/grok-4.7"] },
      { id: "deepinfra", ids: ["deepinfra/deepseek-ai/DeepSeek-V4"] },
      { id: "vercel", ids: ["vercel/anthropic/claude-sonnet-4.6"] },
    ] },
    instances_list: [],
    instance_create: [],
    instance_delete: [],
    instance_bind: [],
    instance_launch: "C:\\Users\\you\\AppData\\Roaming\\MelonTools\\instances\\demo",
    autostart_get: false,
    autostart_set: true,
    backup_last: () => ({ createdAt: DEMO_BACKUP_LAST }),
    backup_export: (a) => {
      DEMO_BACKUP_LAST = Math.floor(Date.now() / 1000);
      return { path: "C:\\Users\\you\\Downloads\\MelonTools-backup-demo.melon", bytes: 20480, createdAt: DEMO_BACKUP_LAST };
    },
    backup_import: (a) => ({ schedulerTasks: 1, schedulerHistory: 3, accounts: 2, authFiles: 2, modelSourcesIncluded: true, settingsKeys: 14 }),
    update_check: { skipped: false, version: "1.4.8", tag: "v1.4.8", newer: false, notes: "", assetName: "", assetURL: "", digest: null },
    update_apply: { ok: true },
    open_url: null,
  };
  const entry = mocks[cmd];
  return Promise.resolve(typeof entry === "function" ? entry(args) : entry);
}

// Browser preview only: a mutable scheduler demo so the page actions work
// without Tauri (the real app answers from the Rust scheduler).
let DEMO_SCHEDULER = null;
let DEMO_BACKUP_LAST = null;
let DEMO_CODEX_PATH = "";
function demoCodexStatus() {
  return {
    found: true,
    source: DEMO_CODEX_PATH ? "manual" : "auto",
    path: DEMO_CODEX_PATH || "C:\\Users\\you\\AppData\\Local\\Programs\\ChatGPT\\ChatGPT.exe",
    savedPath: DEMO_CODEX_PATH,
    savedPathValid: true,
    running: true,
  };
}
// Browser preview only: one demo run at a time, later requests wait in the
// queue — the same shape the Rust scheduler reports through `scheduler_queue`.
const DEMO_RUN_MS = 4000;
let DEMO_QUEUE = { queued: [], running: null, cancelling: false };
function demoScheduler() {
  if (!DEMO_SCHEDULER) {
    const now = Date.now() / 1000;
    const task = {
      id: "demo-task-1", name: "Ночной отчёт", prompt: "Собери отчёт по изменениям за сутки.",
      model: "gpt-6.1-sol", reasoningEffort: null,
      scheduleKind: "cron", cronExpression: "0 9 * * 1-5", timeZone: null,
      intervalMinutes: 60, enabled: true, dailyTokenLimit: 150000,
      createdAt: now - 7200, nextRunAt: now + 1800, lastRunAt: now - 1800,
      lastStatus: "ok", lastError: null, lastResult: "Отчёт готов: 3 изменения, 2 предупреждения.",
      lastDurationMs: 4200, lastTokens: 1530,
    };
    DEMO_SCHEDULER = {
      path: "C:\\Users\\you\\AppData\\Roaming\\MelonTools\\scheduler.json",
      tasks: [task],
      history: [
        { taskId: task.id, at: now - 1800, status: "ok", model: task.model, durationMs: 4200, tokens: 1530, result: task.lastResult, error: null },
        { taskId: task.id, at: now - 3600, status: "ok", model: "opencode/grok-4.7", durationMs: 3100, tokens: 820, result: "ok", error: null },
        { taskId: task.id, at: now - 5400, status: "ok", model: "claude-opus-5-5", durationMs: 2800, tokens: 380, result: "ok", error: null },
      ],
    };
  }
  return DEMO_SCHEDULER;
}

function demoMarkRunning(id) {
  const task = demoScheduler().tasks.find((item) => item.id === id);
  if (task) task.lastStatus = "running";
}

// A started run resolves like the Rust command: after the batch finishes.
// A busy scheduler answers at once with `{status:"queued"}` instead.
function demoRunNow(id) {
  const demo = demoScheduler();
  if (!demo.tasks.some((task) => task.id === id)) return Promise.reject("задача не найдена");
  if (DEMO_QUEUE.running) {
    if (DEMO_QUEUE.queued.indexOf(id) < 0) DEMO_QUEUE.queued.push(id);
    return Promise.resolve({
      status: "queued", id, queued: DEMO_QUEUE.queued.slice(), running: DEMO_QUEUE.running,
    });
  }
  DEMO_QUEUE = { queued: [], running: id, cancelling: false };
  demoMarkRunning(id);
  return new Promise((resolve) => setTimeout(() => resolve(demoFinishRun(id)), DEMO_RUN_MS));
}

function demoFinishRun(id) {
  if (DEMO_QUEUE.running !== id) return null;
  const cancelled = DEMO_QUEUE.cancelling;
  const demo = demoScheduler();
  const task = demo.tasks.find((item) => item.id === id);
  if (task) {
    const at = Date.now() / 1000;
    task.lastRunAt = at;
    task.lastStatus = cancelled ? "cancelled" : "ok";
    task.lastError = cancelled ? "Cancelled by user" : null;
    task.lastDurationMs = cancelled ? null : DEMO_RUN_MS;
    task.lastTokens = cancelled ? null : 840;
    demo.history.unshift({
      taskId: id, at, status: task.lastStatus, model: task.model,
      durationMs: task.lastDurationMs, tokens: task.lastTokens,
      result: cancelled ? "" : "демо-результат", error: task.lastError,
    });
  }
  const next = cancelled ? null : DEMO_QUEUE.queued.shift();
  DEMO_QUEUE = { queued: DEMO_QUEUE.queued, running: next, cancelling: false };
  if (next) {
    demoMarkRunning(next);
    setTimeout(() => demoFinishRun(next), DEMO_RUN_MS);
  }
  return demo;
}
