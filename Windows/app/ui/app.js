// Melon Tools for Windows — UI (vanilla JS, no build step).
// Shared i18n/state/utils/backend live in mt-i18n.js, mt-state.js,
// mt-utils.js and mt-api.js (loaded before this file); Tauri IPC goes through
// the narrow window.melon bridge in mt-bridge.js (W9).


// OAuth polls give up after 10 minutes instead of polling forever.
const LOGIN_TIMEOUT_MS = 10 * 60 * 1000;

// MARK: - Formatting


// Quota history: `key` is an account id or a provider id; samples carry
// timestamp (Unix seconds) and hourlyLeft/weeklyLeft shares (0…100).
function historySamples(key, field) {
  return (S.history || [])
    .filter((sample) => sample && sample.key === key)
    .map((sample) => Number(sample[field]))
    .filter((value) => Number.isFinite(value));
}

function sparkline(key, field, label) {
  const values = historySamples(key, field);
  if (!values.length) {
    return `<span class="spark-empty">${esc(label)}: —</span>`;
  }
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = max - min || 1;
  const points = values.map((value, index) => {
    const x = values.length === 1 ? 50 : (index / (values.length - 1)) * 100;
    const y = 22 - ((value - min) / span) * 20;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");
  const title = `${label}: ${Math.round(values[0])}% → ${Math.round(values[values.length - 1])}%`;
  return `<span class="spark" title="${esc(title)}"><svg viewBox="0 0 100 24" preserveAspectRatio="none" role="img" aria-label="${esc(title)}"><polyline points="${points}"></polyline></svg></span>`;
}

function historyStrip(key) {
  const samples = (S.history || []).filter((sample) => sample && sample.key === key);
  if (!samples.length) return "";
  return `<div class="spark-row" title="${esc(t("historyHint"))}">
    <span class="spark-label">${esc(t("history"))}</span>
    ${sparkline(key, "hourlyLeft", t("fiveHour"))}<span class="spark-name">${esc(t("fiveHour"))}</span>
    ${sparkline(key, "weeklyLeft", t("week"))}<span class="spark-name">${esc(t("week"))}</span>
  </div>`;
}

// MARK: - Dashboard 2.0 helpers

const HOUR_SECONDS = 3600;
const DAY_SECONDS = 86400;
const DASHBOARD_CARD_SETTINGS = [
  "dashboardShowPoolHealth",
  "dashboardShowQuotaTrends",
  "dashboardShowSpend",
  "dashboardShowScheduler",
];


function formatTokens(value) {
  const number = finiteNumber(value);
  if (number === null) return "—";
  return Math.round(number).toLocaleString(S.lang === "en" ? "en-US" : "ru-RU");
}

function formatMoney(value) {
  const number = finiteNumber(value);
  return number === null ? "—" : `$${number.toFixed(2)}`;
}

// Counts partition the pool: an account with a quota error is "error" even if
// it also carries a block reason. Averages use only numeric readings.
function poolHealth(accounts, routing) {
  const list = Array.isArray(accounts) ? accounts : [];
  const blockedIds = new Set(((routing && routing.blockedIds) || []).map(String));
  let usable = 0;
  let paused = 0;
  let errors = 0;
  let hourlySum = 0;
  let hourlyCount = 0;
  let weeklySum = 0;
  let weeklyCount = 0;
  for (const account of list) {
    if (!account) continue;
    // Match macOS: usable + paused = total; errors is an overlapping signal.
    if (account.quotaError || account.needsRelogin) errors += 1;
    if (account.blocked || account.blockInfo || blockedIds.has(String(account.id))) paused += 1;
    else usable += 1;
    const hourly = finiteNumber(account.hourlyRemaining);
    if (hourly !== null) { hourlySum += hourly; hourlyCount += 1; }
    const weekly = finiteNumber(account.weeklyRemaining);
    if (weekly !== null) { weeklySum += weekly; weeklyCount += 1; }
  }
  return {
    total: list.length,
    usable,
    paused,
    errors,
    averageHourly: hourlyCount ? hourlySum / hourlyCount : null,
    averageWeekly: weeklyCount ? weeklySum / weeklyCount : null,
  };
}

// One series of bucket means. `field` is hourlyLeft or weeklyLeft; samples
// outside the window are ignored instead of being clamped into an edge slot.
function quotaTrend(history, field, windowSeconds, bucketSeconds, nowSeconds) {
  const buckets = Math.max(1, Math.round(windowSeconds / bucketSeconds));
  const sums = new Array(buckets).fill(0);
  const counts = new Array(buckets).fill(0);
  const cutoff = nowSeconds - windowSeconds;
  for (const sample of Array.isArray(history) ? history : []) {
    const timestamp = finiteNumber(sample && sample.timestamp);
    const value = finiteNumber(sample && sample[field]);
    if (timestamp === null || value === null) continue;
    if (timestamp < cutoff || timestamp > nowSeconds + bucketSeconds) continue;
    const index = Math.min(buckets - 1, Math.max(0, Math.floor((timestamp - cutoff) / bucketSeconds)));
    sums[index] += value;
    counts[index] += 1;
  }
  const points = [];
  let total = 0;
  let totalCount = 0;
  for (let index = 0; index < buckets; index += 1) {
    if (!counts[index]) continue;
    const value = sums[index] / counts[index];
    points.push({ index, value });
    total += sums[index];
    totalCount += counts[index];
  }
  return {
    points,
    buckets,
    average: totalCount ? total / totalCount : null,
    latest: points.length ? points[points.length - 1].value : null,
    count: totalCount,
  };
}

function quotaTrends(history, nowSeconds) {
  const now = finiteNumber(nowSeconds) ?? nowRef();
  return {
    hourly: quotaTrend(history, "hourlyLeft", 24 * HOUR_SECONDS, HOUR_SECONDS, now),
    weekly: quotaTrend(history, "weeklyLeft", 7 * DAY_SECONDS, DAY_SECONDS, now),
  };
}

function trendChart(trend, label) {
  if (!trend || !trend.points.length) {
    return `<div class="trend"><div class="trend-head"><span>${esc(label)}</span><span class="val">—</span></div>
      <div class="trend-empty">${esc(t("dashTrendEmpty"))}</div></div>`;
  }
  const points = trend.points.map((point) => {
    const x = trend.buckets <= 1 ? 50 : (point.index / (trend.buckets - 1)) * 100;
    const y = 30 - (Math.max(0, Math.min(100, point.value)) / 100) * 28;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");
  const latest = trend.latest === null ? "—" : `${Math.round(trend.latest)}%`;
  const average = trend.average === null ? "—" : `${Math.round(trend.average)}%`;
  return `<div class="trend" title="${esc(t("dashTrendHint"))}">
    <div class="trend-head"><span>${esc(label)}</span><span class="val">${latest}</span></div>
    <svg class="trend-svg" viewBox="0 0 100 32" preserveAspectRatio="none" role="img" aria-label="${esc(label)}">
      <line x1="0" y1="16" x2="100" y2="16" class="trend-grid"></line>
      <polyline points="${points}"></polyline>
    </svg>
    <div class="trend-foot"><span>${trend.count} ${esc(t("dashSamples"))}</span><span>${esc(t("dashAvg"))}: ${average}</span></div>
  </div>`;
}

function providerOfModel(model) {
  const id = String(model || "");
  if (id.startsWith("opencode/")) return "opencode";
  if (id.startsWith("openrouter/")) return "openrouter";
  if (id.startsWith("deepinfra/")) return "deepinfra";
  if (id.startsWith("vercel/")) return "vercel";
  if (id.startsWith("claude-")) return "claude";
  return "gateway";
}

function providerName(provider) {
  switch (provider) {
    case "gateway": return t("sgGateway");
    case "claude": return t("sgClaude");
    case "opencode": return t("sgOpenCode");
    case "openrouter": return t("sgOpenRouter");
    case "deepinfra": return t("sgDeepInfra");
    case "vercel": return t("sgVercel");
    default: return String(provider || "—");
  }
}

// Windows has no provider price table: the scheduler history contributes
// tokens/turns, the optional bridge session contributes priced spend. A row
// without a USD value renders "—" instead of a fabricated number.
function usageSummary(scheduler, bridge) {
  const rows = new Map();
  const rowFor = (provider) => {
    if (!rows.has(provider)) rows.set(provider, { provider, tokens: 0, usd: null, priced: false, turns: 0 });
    return rows.get(provider);
  };
  for (const entry of (scheduler && scheduler.history) || []) {
    if (!entry) continue;
    const row = rowFor(providerOfModel(entry.model));
    const tokens = finiteNumber(entry.tokens);
    if (tokens !== null) row.tokens += tokens;
    row.turns += 1;
    const usd = finiteNumber(entry.usd !== undefined ? entry.usd : entry.cost);
    if (usd !== null) {
      row.usd = (row.usd || 0) + usd;
      row.priced = true;
    }
  }
  const session = bridge && bridge.session;
  const cost = session && session.cost;
  const providers = (cost && cost.providers) || {};
  for (const [provider, stats] of Object.entries(providers)) {
    const row = rowFor(provider === "openai" ? "gateway" : provider);
    const usd = finiteNumber(stats && stats.usd);
    if (usd !== null) {
      row.usd = (row.usd || 0) + usd;
      row.priced = true;
    }
  }
  const list = [...rows.values()].sort((left, right) =>
    right.tokens - left.tokens || (right.usd || 0) - (left.usd || 0));
  const totalTokens = list.reduce((sum, row) => sum + row.tokens, 0);
  const bridgeTokens = finiteNumber(
    session && session.total && (session.total.total !== undefined ? session.total.total : session.total.tokens)
  );
  return {
    rows: list.slice(0, 3),
    totalTokens,
    sessionSpend: finiteNumber(cost && (cost.total !== undefined ? cost.total : cost.usd)),
    sessionTokens: bridgeTokens !== null ? bridgeTokens : (totalTokens || null),
  };
}

// The tray and dashboard "Run next" share this pick: due tasks first because
// they have the earliest nextRunAt, disabled tasks never qualify.
function schedulerNextTask(data, nowSeconds) {
  const now = finiteNumber(nowSeconds) ?? nowRef();
  const tasks = ((data && data.tasks) || []).filter((task) =>
    task && task.enabled && finiteNumber(task.nextRunAt) !== null);
  tasks.sort((left, right) => Number(left.nextRunAt) - Number(right.nextRunAt));
  return tasks[0] || null;
}

function schedulerSummary(data, nowSeconds) {
  const now = finiteNumber(nowSeconds) ?? nowRef();
  const tasks = ((data && data.tasks) || []).filter(Boolean);
  const enabled = tasks.filter((task) => task.enabled);
  const due = enabled.filter((task) =>
    finiteNumber(task.nextRunAt) !== null && Number(task.nextRunAt) <= now);
  const last = tasks
    .filter((task) => finiteNumber(task.lastRunAt) !== null)
    .sort((left, right) => Number(right.lastRunAt) - Number(left.lastRunAt))[0] || null;
  return { due: due.length, next: schedulerNextTask(data, now), last };
}

function dashboardVisibility(settings) {
  const value = settings || {};
  return {
    pool: value.dashboardShowPoolHealth !== false,
    trends: value.dashboardShowQuotaTrends !== false,
    spend: value.dashboardShowSpend !== false,
    scheduler: value.dashboardShowScheduler !== false,
  };
}

function dashboardCardToggles(settings) {
  const value = settings || {};
  const cards = [
    ["dashboardShowPoolHealth", "dashCardPool"],
    ["dashboardShowQuotaTrends", "dashCardTrends"],
    ["dashboardShowSpend", "dashCardSpend"],
    ["dashboardShowScheduler", "dashCardScheduler"],
  ];
  return `<div class="card dashboard-toggle-card" data-dashboard-toggles>
    <div class="row">
      <span class="spark-label">${esc(t("dashCards"))}</span>
      ${cards.map(([setting, key]) => `<label class="card-toggle">
        <input type="checkbox" ${value[setting] !== false ? "checked" : ""} data-action="dashboardCardToggle" data-id="${setting}" data-on="change">
        <span>${esc(t(key))}</span>
      </label>`).join("")}
    </div>
  </div>`;
}

function dashboardPoolCard(health) {
  const stat = (label, value, cls) => `<div class="stat ${cls || ""}">
    <span class="value">${value}</span><span class="label">${esc(label)}</span></div>`;
  return `<div class="card" data-dashboard-card="pool-health">
    <h2>${t("dashPoolHealth")} <span class="hint">${health.total} ${t("accountsCount")}</span></h2>
    <div class="stat-grid">
      ${stat(t("dashTotal"), health.total, "")}
      ${stat(t("dashUsable"), health.usable, "ok")}
      ${stat(t("dashPaused"), health.paused, "warn")}
      ${stat(t("dashErrors"), health.errors, "danger")}
      ${stat(t("dashAvgFive"), health.averageHourly === null ? "—" : `${Math.round(health.averageHourly)}%`, "")}
      ${stat(t("dashAvgWeek"), health.averageWeekly === null ? "—" : `${Math.round(health.averageWeekly)}%`, "")}
    </div>
  </div>`;
}

function dashboardTrendsCard(trends) {
  return `<div class="card" data-dashboard-card="quota-trends">
    <h2>${t("dashQuotaTrends")} <span class="hint">${t("dashTrendHint")}</span></h2>
    <div class="trend-grid">
      ${trendChart(trends.hourly, t("dashLast24h"))}
      ${trendChart(trends.weekly, t("dashLast7d"))}
    </div>
  </div>`;
}

function dashboardSpendCard(usage) {
  const rows = usage.rows.map((row) => `<tr>
    <td>${esc(providerName(row.provider))}</td>
    <td>${formatTokens(row.tokens)}</td>
    <td>${row.priced && row.usd !== null ? formatMoney(row.usd) : "—"}</td>
    <td>${row.turns}</td>
  </tr>`).join("");
  return `<div class="card" data-dashboard-card="spend">
    <h2>${t("dashSpend")}</h2>
    <div class="usage-totals">
      <div class="stat"><span class="value">${formatMoney(usage.sessionSpend)}</span><span class="label">${esc(t("dashSessionSpend"))}</span></div>
      <div class="stat"><span class="value">${formatTokens(usage.sessionTokens)}</span><span class="label">${esc(t("dashSessionTokens"))}</span></div>
    </div>
    ${usage.rows.length ? `<div class="usage-title">${esc(t("dashTopProviders"))}</div>
      <table class="usage">
        <thead><tr><th>${t("dashProvider")}</th><th>${t("dashTokens")}</th><th>${t("dashSpendShort")}</th><th>${t("dashTurns")}</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>` : `<div class="footnote">${t("dashNoUsage")}</div>`}
  </div>`;
}

function dashboardSchedulerCard(summary) {
  const next = summary.next;
  const last = summary.last;
  return `<div class="card" data-dashboard-card="scheduler">
    <h2>${t("dashScheduler")}</h2>
    <div class="stat-grid">
      <div class="stat ${summary.due ? "warn" : ""}"><span class="value">${summary.due}</span><span class="label">${esc(t("dashDue"))}</span></div>
      <div class="stat"><span class="value">${next ? esc(schedulerNextText(next.nextRunAt)) : "—"}</span><span class="label">${esc(t("dashNextRun"))}</span></div>
      <div class="stat"><span class="value">${last ? esc(ageText(last.lastRunAt)) : "—"}</span><span class="label">${esc(t("dashLastRun"))}</span></div>
    </div>
    <div class="row" style="margin-top:12px">
      <button class="btn small" data-action="schedulerRunNext" ${next && !S.busy["sched-run-next"] ? "" : "disabled"}>${t("dashRunNext")}</button>
      <button class="ghost small" data-action="go" data-id="scheduler">${t("dashOpenScheduler")}</button>
      ${last ? schedulerStatusPill(last) : ""}
      ${last ? `<span class="footnote" style="margin:0">${esc(last.name || "")}</span>` : `<span class="footnote" style="margin:0">${t("dashNoTasks")}</span>`}
    </div>
  </div>`;
}

function percentLabel(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return "—";
  return Number.isInteger(number) ? String(number) : number.toFixed(1);
}

function blockText(info) {
  if (!info) return "";
  const stopped = info.blockedAt !== null && info.blockedAt !== undefined;
  switch (info.code) {
    case "hourly_exhausted": return stopped
      ? fmt(t("bHourlyExhaustedStopped"), { r: percentLabel(info.remaining) })
      : t("bHourly");
    case "weekly_exhausted": return stopped
      ? fmt(t("bWeeklyExhaustedStopped"), { r: percentLabel(info.remaining) })
      : t("bWeekly");
    case "hourly_reserve": return fmt(t(stopped ? "bHourlyStopped" : "bHourlyReserve"), { r: percentLabel(info.remaining), l: info.limit });
    case "weekly_reserve": return fmt(t(stopped ? "bWeeklyStopped" : "bWeeklyReserve"), { r: percentLabel(info.remaining), l: info.limit });
    default: return info.code;
  }
}

// Pool-pause preflight: the vault has accounts, but every one is paused by
// a quota window or by the routing planner.
function poolPauseBlock(account) {
  const info = (account && account.blockInfo) || {};
  const code = String(info.code || "");
  const remaining = info.remaining === null || info.remaining === undefined ? NaN : Number(info.remaining);
  const limit = info.limit === null || info.limit === undefined ? NaN : Number(info.limit);
  let window = null;
  if (code === "hourly_reserve" || code === "hourly_exhausted") window = "hourly";
  else if (code === "weekly_reserve" || code === "weekly_exhausted") window = "weekly";
  const reset = window === "hourly"
    ? account.hourlyResetAt
    : window === "weekly"
      ? account.weeklyResetAt
      : null;
  const exhausted = code === "hourly_exhausted" || code === "weekly_exhausted" ||
    (Number.isFinite(remaining) && remaining <= 0);
  const liftable = code.endsWith("_reserve") && Number.isFinite(remaining) && remaining > 0 &&
    Number.isFinite(limit) && limit > 0;
  return { account, window, reset, exhausted, liftable, code, remaining, limit };
}

function poolPauseResetTime(unixTs, weekly) {
  if (!Number.isFinite(unixTs)) return "—";
  const date = new Date(unixTs * 1000);
  if (Number.isNaN(date.getTime())) return "—";
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  if (!weekly) return `${hours}:${minutes}`;
  const day = String(date.getDate()).padStart(2, "0");
  const month = String(date.getMonth() + 1).padStart(2, "0");
  return `${day}.${month} ${hours}:${minutes}`;
}

function poolPauseState() {
  const accounts = S.accounts || [];
  if (!accounts.length) return null;
  const blockedIds = new Set(((S.routing && S.routing.blockedIds) || []).map(String));
  const paused = accounts.filter((account) => account &&
    (account.blocked || account.blockInfo || blockedIds.has(String(account.id))));
  if (paused.length !== accounts.length) return null;

  const blocks = paused.map(poolPauseBlock);
  const allHourly = blocks.every((block) => block.code === "hourly_reserve");
  const allWeekly = blocks.every((block) => block.code === "weekly_reserve");
  const allExhausted = blocks.every((block) => block.exhausted);
  let kind = "mixed";
  if (allExhausted) kind = "exhausted";
  else if (allHourly) kind = "hourly";
  else if (allWeekly) kind = "weekly";

  const relevant = kind === "hourly"
    ? blocks.filter((block) => block.window === "hourly")
    : kind === "weekly"
      ? blocks.filter((block) => block.window === "weekly")
      : blocks;
  const timed = relevant.filter((block) => Number.isFinite(block.reset));
  const nearest = timed.length
    ? timed.reduce((left, right) => (right.reset < left.reset ? right : left))
    : null;
  const weeklyTime = kind === "weekly" || (kind === "mixed" && nearest && nearest.window === "weekly");
  const time = poolPauseResetTime(nearest ? nearest.reset : null, weeklyTime);
  let message = fmt(t("poolPauseMixed"), { time });
  if (kind === "hourly") message = fmt(t("poolPauseHourly"), { time });
  else if (kind === "weekly") message = fmt(t("poolPauseWeekly"), { time });
  else if (kind === "exhausted") message = fmt(t("poolPauseExhausted"), { time });

  return { kind, message, blocks, liftable: blocks.some((block) => block.liftable) };
}

function poolPauseWindows(block) {
  const windows = new Set();
  if (block.window && block.code.endsWith("_reserve")) windows.add(block.window);
  const account = block.account;
  const hourlyReserve = Number(account.hourlyReservePercent);
  const weeklyReserve = Number(account.weeklyReservePercent);
  const hourlyRemaining = Number(account.hourlyRemaining);
  const weeklyRemaining = Number(account.weeklyRemaining);
  if (Number.isFinite(hourlyReserve) && hourlyReserve > 0 &&
      Number.isFinite(hourlyRemaining) && hourlyRemaining > 0 && hourlyRemaining <= hourlyReserve) {
    windows.add("hourly");
  }
  if (Number.isFinite(weeklyReserve) && weeklyReserve > 0 &&
      Number.isFinite(weeklyRemaining) && weeklyRemaining > 0 && weeklyRemaining <= weeklyReserve) {
    windows.add("weekly");
  }
  return windows;
}

function poolPauseBanner() {
  const state = poolPauseState();
  if (!state) return "";
  return `<div class="card pool-pause" id="pool-pause-banner" data-kind="${esc(state.kind)}">
    <div class="row">
      <span class="pill warn">${esc(t("paused"))}</span>
      <span>${esc(state.message)}</span>
      <span class="spacer"></span>
      ${state.liftable
        ? `<button class="btn small" id="pool-pause-lift" data-action="liftPoolPause" ${S.busy.poolPause ? "disabled" : ""}>${esc(t("poolPauseLift"))}</button>`
        : ""}
    </div>
  </div>`;
}

function toast(message, isError = false) {
  const node = document.getElementById("toast");
  node.setAttribute("role", "status");
  node.setAttribute("aria-live", "polite");
  node.textContent = message;
  node.className = isError ? "show error" : "show";
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => (node.className = ""), 4200);
}

async function run(action, fn) {
  if (S.busy[action]) return;
  S.busy[action] = true;
  try {
    render();
    await fn();
  } catch (error) {
    toast(String(error && error.message ? error.message : error), true);
  } finally {
    S.busy[action] = false;
    render();
  }
}

// MARK: - Icons

const ICONS = {
  dashboard: '<svg viewBox="0 0 24 24"><path d="M4 13h7V4H4v9Zm0 7h7v-5H4v5Zm9 0h7V11h-7v9Zm0-16v5h7V4h-7Z"/></svg>',
  accounts: '<svg viewBox="0 0 24 24"><path d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm-7 8a7 7 0 0 1 14 0"/></svg>',
  api: '<svg viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h10"/></svg>',
  providers: '<svg viewBox="0 0 24 24"><path d="M12 3 3 8l9 5 9-5-9-5ZM3 14l9 5 9-5"/></svg>',
  composer: '<svg viewBox="0 0 24 24"><path d="M4 5h16v10H8l-4 4V5Z"/></svg>',
  instances: '<svg viewBox="0 0 24 24"><path d="M4 6h16v12H4z"/><path d="M8 10h8M8 14h5"/></svg>',
  scheduler: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/></svg>',
  donate: '<svg viewBox="0 0 24 24"><path d="M12 20s-7-4.5-9-9a5 5 0 0 1 9-3 5 5 0 0 1 9 3c-2 4.5-9 9-9 9Z"/></svg>',
  settings: '<svg viewBox="0 0 24 24"><path d="M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z"/><path d="M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.3 1a7 7 0 0 0-1.7-1L14.5 3h-5l-.4 2.6a7 7 0 0 0-1.7 1l-2.3-1-2 3.4L5 11a7 7 0 0 0 0 2l-2 1.5 2 3.4 2.3-1a7 7 0 0 0 1.7 1l.4 2.6h5l.4-2.6a7 7 0 0 0 1.7-1l2.3 1 2-3.4-2-1.5c.1-.3.1-.7.1-1Z"/></svg>',
};

const NAV = [
  { group: "codex", items: ["dashboard", "accounts", "api", "providers", "composer", "instances"] },
  { group: "general", items: ["scheduler", "settings", "donate"] },
];

// MARK: - Render

function render() {
  document.documentElement.lang = S.lang || "ru";
  // The queue poll lives and dies with the scheduler page: it starts on entry
  // and is cleared on exit, before any DOM work.
  schedulerQueueSync();
  // Polling must not wipe an input the user is editing. User actions move
  // focus to their button first, so navigation and save operations still
  // render normally.
  if (typeof editsInProgress === "function" && editsInProgress()) return;
  renderNav();
  renderFooter();
  const main = document.getElementById("main");
  const pages = {
    dashboard: dashboardPage,
    accounts: accountsPage,
    api: apiPage,
    providers: providersPage,
    composer: composerPage,
    instances: instancesPage,
    scheduler: schedulerPage,
    donate: donatePage,
    settings: settingsPage,
  };
  main.innerHTML = (pages[S.section] || dashboardPage)();
  if (S.section === "donate") renderDonateQr();
}

/// Data-fetch side of navigation. `render()` itself must stay pure: a status
/// poll or any local action re-renders many times per minute, and each old
/// render triggered scheduler/models/pool/provider IPC and another render.
function sectionLoads(section) {
  if (section === "scheduler" && !S.scheduler && !S.schedulerError) A.schedulerLoad();
  if (section === "providers" && !S.models && !S.modelsError) A.modelsLoad();
  // The Codex pool snapshot backs the pool card and both picker modes.
  if ((section === "accounts" || section === "providers") && !S.pool && !S.poolError) A.poolLoad();
  if (section === "providers" && IS_TAURI && !S.vercelLoaded
      && String((S.settings && S.settings.vercelKey) || "").trim()) {
    A.vercelLoad();
  }
  if (section === "providers" && IS_TAURI && !S.claude && !S.claudeLogin) {
    A.claudeUsageLoad().then(() => {
      if (S.section === "providers") render();
    }).catch(() => {});
  }
  if (section === "providers" && IS_TAURI && !S.antigravity && !S.antigravityLogin) {
    A.antigravityUsageLoad().then(() => {
      if (S.section === "providers") render();
    }).catch(() => {});
  }
  if (section === "instances" && !S.instancesData) A.instancesLoad();
  if (section === "settings" && !S.backupLastLoaded) A.backupLastLoad();
}

function renderNav() {
  const nav = document.getElementById("nav");
  let html = "";
  for (const group of NAV) {
    html += `<div class="nav-group"><div class="nav-caption">${esc(t(group.group))}</div>`;
    for (const item of group.items) {
      const active = S.section === item ? " active" : "";
      html += `<button class="nav-row${active}" data-action="go" data-id="${item}">${ICONS[item]}<span>${esc(t(item))}</span></button>`;
    }
    html += "</div>";
  }
  nav.innerHTML = html;
}

function renderFooter() {
  const dot = document.getElementById("gw-dot");
  const label = document.getElementById("gw-label");
  const status = S.status;
  const running = status && status.running;
  dot.className = "dot " + (running ? "ok" : "err");
  const schemaError = S.status && S.status.schemaError;
  if (S.statusError || schemaError) {
    // A dead backend used to keep the last "running" text forever.
    dot.className = "dot err";
    const detail = String(S.statusError || schemaError).slice(0, 80);
    label.textContent = `${t("stale")} · ${detail}`;
  } else {
    label.textContent = running ? `${t("running")} · :${status.port}` : t("stopped");
  }
  document.getElementById("ver").textContent = S.info ? `v${S.info.version}` : "";
  const updateLabel = document.getElementById("update-label");
  if (updateLabel) A.updateButton();
  const cancel = document.getElementById("update-cancel");
  if (cancel) {
    cancel.textContent = t("updateCancel");
    // C-F8: once the swap started the modal must stay put — keep Cancel off.
    cancel.disabled = !!A._updateApplying;
  }
  const apply = document.getElementById("update-apply");
  if (apply) apply.textContent = t("updateApply");
}

function isFormField(node) {
  return !!node && FORM_TAGS.indexOf(node.tagName) >= 0;
}

// The 5 s status tick re-renders whole pages, which would wipe what the user
// is typing. The full render runs only when no field is focused and no edit
// is pending; the footer status update always runs.
function editsInProgress() {
  // The edited element can be removed by another render without a focusout
  // event — then there is nothing left to protect and the flag must not
  // stall future updates.
  if (S.dirtyInput && S.dirtyField && !S.dirtyField.isConnected) {
    S.dirtyInput = false;
    S.dirtyField = null;
  }
  if (isFormField(document.activeElement)) return true;
  return !!S.dirtyInput;
}


// MARK: - Delegated UI actions (W3)
//
// Templates never put JS in an attribute. Every control carries
// data-action (plus data-id/data-value), so an account id or path can never
// break out of an onclick string. One listener per event type dispatches to
// the same A.* methods the inline handlers used.

function actionArgs(action, el) {
  switch (action) {
    case "setRole":
      return el.dataset.role === "backup"
        ? [el.dataset.id, el.dataset.value === "true", !!el.checked]
        : [el.dataset.id, !!el.checked, el.dataset.value === "true"];
    case "movePriority":
    case "poolToggleGlobal":
      return [el.dataset.id, el.dataset.value === "true"];
    case "notifyDetailToggle":
    case "dashboardCardToggle":
    case "schedulerToggle":
      return [el.dataset.id, !!el.checked];
    case "notifyToggle":
    case "autostartToggle":
      return [!!el.checked];
    case "backupImportFile":
    case "importJsonFile":
      return [el];
    case "instanceBind":
    case "schedulerVarInput":
      return [el.dataset.id, el.value];
    case "setStrategy":
    case "schedulerKindChanged":
    case "schedulerTemplateApply":
    case "poolSearch":
    case "modelsSearch":
      return [el.value];
    case "copy":
      return [el.dataset.text || ""];
    default:
      return el.dataset.id === undefined ? [] : [el.dataset.id];
  }
}

function dispatchAction(el) {
  const action = el.dataset.action;
  const fn = action && A[action];
  if (typeof fn !== "function") {
    // A stale event after a navigation must not throw.
    return;
  }
  try {
    const result = fn.apply(A, actionArgs(action, el));
    if (result && typeof result.catch === "function") result.catch((error) => toast(errorText(error), true));
  } catch (error) {
    toast(errorText(error), true);
  }
}

document.addEventListener("click", (event) => {
  const el = event.target.closest("[data-action]");
  if (!el || el.dataset.on) return;
  dispatchAction(el);
});
document.addEventListener("change", (event) => {
  const el = event.target.closest('[data-action][data-on="change"]');
  if (el) dispatchAction(el);
});
document.addEventListener("input", (event) => {
  const el = event.target.closest('[data-action][data-on="input"]');
  if (el) dispatchAction(el);
});

// Tray events arrive as `tray-action`: navigation and run-next are owned by the
// renderer, gateway pause/resume only asks for a status refresh.
function handleTrayAction(payload) {
  const action = payload && payload.action;
  if (action === "navigate") {
    S.section = payload.section || "dashboard";
    render();
    return;
  }
  if (action === "run-next") {
    A.schedulerRunNext();
    return;
  }
  if (action === "refresh") {
    A.refreshStatus();
  }
}

window.__mt = {
  S,
  A,
  handleTrayAction,
  poolHealth,
  quotaTrend,
  quotaTrends,
  trendChart,
  usageSummary,
  schedulerNextTask,
  schedulerSummary,
  dashboardPage,
  dashboardVisibility,
};

// MARK: - Edit tracking (M3)

// Typing marks the current field dirty so the periodic refreshStatus does
// not re-render the page under the user's hands.
function markFieldDirty(event) {
  if (!isFormField(event.target)) return;
  S.dirtyInput = true;
  S.dirtyField = event.target;
}
document.addEventListener("input", markFieldDirty, true);
document.addEventListener("change", markFieldDirty, true);

// Focus left every field: the deferred full update runs now instead of
// waiting for the next 5 s tick.
document.addEventListener("focusout", (event) => {
  if (isFormField(event.relatedTarget)) return; // moved to another field
  S.dirtyInput = false;
  S.dirtyField = null;
  if (!S.renderDeferred) return;
  S.renderDeferred = false;
  clearTimeout(S._renderResumeTimer);
  // Small delay so a click (mousedown → focusout → mouseup → click) lands on
  // the current DOM before it is re-rendered.
  S._renderResumeTimer = setTimeout(() => A.refreshStatus(), 350);
}, true);

// MARK: - Onboarding

// The modal is injected here instead of index.html so the web UI stays one
// script plus one stylesheet. The flag is written on any dismissal, so the
// tour is shown exactly once per webview profile.
//
// The buttons do not carry inline onclick attributes: inline handlers are
// compiled by the webview under the page script policy, and in the Windows
// webview they were not running at all, which left the welcome window with
// dead buttons and no way out. Every action is a data-onboarding attribute
// handled by one delegated listener registered from this script.
const ONBOARDING_KEY = "onboardingDone";

// Session memory. A dismissal must stick for this launch even when
// localStorage throws, and the tour must be injected at most once.
let onboardingDismissed = false;
let onboardingShown = false;

// Body scroll lock taken while the modal covers the page, restored on close.
let onboardingScrollLocked = false;
let onboardingPrevOverflow = "";

function onboardingSeen() {
  if (onboardingDismissed) return true;
  try {
    return window.localStorage.getItem(ONBOARDING_KEY) === "1";
  } catch {
    // Storage unavailable (hardened webview): the in-memory flag set on
    // dismissal still stops the tour from reopening during this launch.
    return false;
  }
}

function markOnboardingSeen() {
  onboardingDismissed = true;
  try {
    window.localStorage.setItem(ONBOARDING_KEY, "1");
  } catch {
    // Same as above — the UI keeps working when storage is unavailable.
  }
}

function lockOnboardingScroll() {
  if (onboardingScrollLocked) return;
  onboardingScrollLocked = true;
  onboardingPrevOverflow = document.body.style.overflow;
  document.body.style.overflow = "hidden";
}

function unlockOnboardingScroll() {
  if (!onboardingScrollLocked) return;
  onboardingScrollLocked = false;
  document.body.style.overflow = onboardingPrevOverflow;
  onboardingPrevOverflow = "";
}

// Single close path: remember the dismissal, drop the node, give the page
// its scroll back. Reusable from the buttons, Esc and the backdrop.
function dismissOnboarding() {
  markOnboardingSeen();
  const modal = document.getElementById("onboarding-modal");
  if (modal) {
    modal.classList.remove("is-open");
    if (typeof modal.close === "function" && modal.open) {
      try {
        modal.close();
      } catch {
        // Already closed by the UA; removing the node still finishes the job.
      }
    }
    if (modal.parentNode) modal.parentNode.removeChild(modal);
  }
  unlockOnboardingScroll();
}

// The dialog is the only onboarding surface that may receive actions.
function onboardingVisible() {
  const modal = document.getElementById("onboarding-modal");
  return !!modal && modal.classList.contains("is-open");
}

function handleOnboardingAction(name) {
  if (!name) return;
  if (["accounts", "providers", "api", "scheduler", "settings"].includes(name)) {
    A.onboardingGo(name);
  } else if (name === "health") {
    A.onboardingHealthRefresh();
  } else if (name === "demo") {
    A.onboardingDemoTask();
  } else {
    // "done" and "close" only close — no render.
    A.onboardingDone();
  }
}

// Capture-phase listener on the document, not on the modal node. It fires
// before any page handler, keeps working after the health block rewrites its
// rows, and cannot be blocked by a page layer above the dialog.
document.addEventListener("click", (event) => {
  const modal = document.getElementById("onboarding-modal");
  if (!modal || !modal.classList.contains("is-open")) return;
  const target = event.target;
  if (target === modal) {
    event.preventDefault();
    dismissOnboarding();
    return;
  }
  const action = target && target.closest ? target.closest("[data-onboarding]") : null;
  if (!action || !modal.contains(action)) return;
  event.preventDefault();
  handleOnboardingAction(action.getAttribute("data-onboarding"));
}, true);

// Esc closes the tour. Registered once on the document, so it keeps working
// after the modal node is removed and recreated.
document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape" && event.key !== "Esc") return;
  if (!onboardingVisible()) return;
  event.preventDefault();
  dismissOnboarding();
});

// Compact PASS/WARN/FAIL rows for onboarding 2.0. Reads only the snapshots
// loaded at boot; "Run health check" refreshes them without re-rendering the
// modal underneath the user.
function onboardingHealthRows() {
  const gateway = !!(S.status && S.status.running);
  const accounts = Array.isArray(S.accounts) ? S.accounts.length : 0;
  const models = ((S.schedulerModels && S.schedulerModels.ids) || []).length;
  const tasks = ((S.schedulerSummary || S.scheduler) && Array.isArray((S.schedulerSummary || S.scheduler).tasks)) ? (S.schedulerSummary || S.scheduler).tasks : [];
  const next = tasks
    .filter((task) => task && task.enabled && task.nextRunAt)
    .map((task) => task.nextRunAt)
    .sort((a, b) => a - b)[0];
  const backup = S.backupLast ? new Date(S.backupLast * 1000).toLocaleString() : "";
  const row = (state, title, detail, action, actionKey) => `
    <div class="row" style="align-items:center;gap:8px;padding:7px 0;border-top:1px solid var(--border)">
      <span class="pill ${state === "ok" ? "ok" : state === "warn" ? "warn" : "danger"}">${esc(t(state === "ok" ? "onboardingPass" : state === "warn" ? "onboardingWarn" : "onboardingFail"))}</span>
      <div style="flex:1;min-width:0">
        <strong>${esc(title)}</strong>
        <div class="footnote" style="margin:0">${esc(detail)}</div>
      </div>
      <button type="button" class="ghost small" data-onboarding="${action}">${esc(t(actionKey))}</button>
    </div>`;
  return [
    row(gateway ? "ok" : "fail", t("onboardingGateway"), gateway ? t("onboardingGatewayOn") : t("onboardingGatewayOff"), "api", "onboardingOpen"),
    row(accounts > 0 ? "ok" : "fail", t("onboardingAccount"), accounts > 0 ? fmt(t("onboardingAccountsCount"), { n: accounts }) : t("onboardingNoAccounts"), "accounts", "onboardingOpen"),
    row(models > 0 ? "ok" : "warn", t("onboardingModels"), models > 0 ? fmt(t("onboardingModelsCount"), { n: models }) : t("onboardingNoModels"), "providers", "onboardingOpen"),
    row(tasks.length > 0 ? "ok" : "warn", t("onboardingScheduler"), tasks.length > 0
      ? (next ? fmt(t("onboardingNextRun"), { time: new Date(next * 1000).toLocaleString() }) : fmt(t("onboardingTasksCount"), { n: tasks.length }))
      : t("onboardingNoTasks"), "scheduler", "onboardingOpen"),
    row(backup ? "ok" : "warn", t("onboardingBackup"), backup ? fmt(t("onboardingBackupAt"), { time: backup }) : t("onboardingNoBackup"), "settings", "onboardingOpen"),
  ].join("");
}

function showOnboarding() {
  // Once per launch, and never again after a dismissal — even when
  // localStorage is unavailable and the flag cannot be read back.
  if (onboardingShown) return;
  onboardingShown = true;
  if (onboardingSeen()) return;

  // A native <dialog> is placed in the browser top layer by showModal().
  // Nothing in the page can cover it, and the page behind it is inert.
  // The fallback path keeps the same markup for old WebView2 runtimes.
  let modal = document.getElementById("onboarding-modal");
  if (!modal) {
    modal = document.createElement("dialog");
    modal.id = "onboarding-modal";
    modal.className = "modal onboarding-dialog";
    modal.setAttribute("aria-labelledby", "onboarding-title");
    document.body.appendChild(modal);
  }
  const steps = [
    ["1", "onboardingStep1"],
    ["2", "onboardingStep2"],
    ["3", "onboardingStep3"],
  ];
  modal.innerHTML = `
    <div class="modal-card onboarding-card">
      <div class="modal-head onboarding-head">
        <div>
          <div class="kicker">melon tools</div>
          <h2 id="onboarding-title">${esc(t("onboardingTitle"))}</h2>
        </div>
        <button type="button" class="onboarding-close" data-onboarding="close"
          title="${esc(t("onboardingClose"))}" aria-label="${esc(t("onboardingClose"))}">×</button>
      </div>
      <div class="onboarding-scroll">
        <div class="subtitle">${esc(t("onboardingWelcome"))}</div>
        <div class="stack" style="margin:14px 0">
          ${steps.map(([number, key]) => `<div class="row" style="align-items:flex-start;gap:10px">
            <span class="pill gold">${number}</span>
            <span>${esc(t(key))}</span>
          </div>`).join("")}
        </div>
        <div class="card" style="margin:14px 0;padding:12px">
          <div class="row" style="align-items:center">
            <strong>${esc(t("onboardingHealth"))}</strong>
            <span class="footnote" style="margin:0;flex:1">${esc(t("onboardingHealthSub"))}</span>
          </div>
          <div id="onboarding-health">${onboardingHealthRows()}</div>
          <div class="row" style="margin-top:10px">
            <button type="button" class="ghost small" data-onboarding="health">${esc(t("onboardingRunHealth"))}</button>
            <button type="button" class="ghost small" data-onboarding="demo">${esc(t("onboardingDemoTask"))}</button>
          </div>
        </div>
        <div class="footnote" style="color:var(--warn);border-top:1px solid var(--border);padding-top:10px;margin-bottom:12px">
          ${esc(t("onboardingDisclaimer"))}
        </div>
      </div>
      <div class="onboarding-actions">
        <button type="button" class="ghost small" data-onboarding="accounts">${esc(t("onboardingAccounts"))}</button>
        <button type="button" class="ghost small" data-onboarding="providers">${esc(t("onboardingProviders"))}</button>
        <button type="button" class="btn small" data-onboarding="done">${esc(t("onboardingDone"))}</button>
      </div>
    </div>`;
  modal.classList.add("is-open");
  try {
    if (typeof modal.showModal === "function") {
      modal.showModal();
    } else {
      modal.setAttribute("open", "");
      modal.setAttribute("role", "dialog");
      modal.setAttribute("aria-modal", "true");
    }
  } catch {
    // A WebView2 build without <dialog> support still gets the fixed
    // overlay; the capture-phase handler keeps its buttons alive.
    modal.setAttribute("open", "");
    modal.setAttribute("role", "dialog");
    modal.setAttribute("aria-modal", "true");
  }
  lockOnboardingScroll();
}

// MARK: - Boot

// W5: poll status with exponential backoff after failures; a dead backend
// must not be hit every 5 s forever. Success resets the delay to 5 s.
async function statusPoll() {
  if (!onboardingVisible()) await A.refreshStatus();
  const delay = Math.min(30000, 5000 * Math.pow(2, Math.min(S.statusFailures, 3)));
  setTimeout(statusPoll, delay);
}

(async function boot() {
  if (window.melon && typeof window.melon.listen === "function") {
    try {
      window.melon.listen("tray-action", (event) => {
        handleTrayAction(event && event.payload);
      }).catch(() => {});
    } catch {
      // Older webview without the event API: tray navigation degrades to
      // opening the window only.
    }
  }
  // Resolve language and show the welcome dialog before slower status probes.
  // The rest of the boot reads are independent and run in parallel below.
  try {
    S.settings = await inv("settings_get");
    S.lang = (S.settings && S.settings.lang) === "en" ? "en" : "ru";
    if (S.settings && S.settings.schemaError) toast(S.settings.schemaError, true);
  } catch {
    // Use the default language and keep booting if settings are unavailable.
  }
  showOnboarding();
  await A.loadAll();
  sectionLoads(S.section);
  // Update check at launch: turn the sidebar control gold and show a toast
  // when a newer release exists.
  if (IS_TAURI) {
    inv("update_check", { force: true })
      .then((result) => {
        if (result && !result.skipped) {
          S.update = result;
          A.updateButton();
          A.updateNotify();
        }
      })
      .catch(() => {});
  }
  statusPoll();
  // Adaptive quota refresh: the configured interval when idle, ~30 s while
  // the gateway is actually serving — a fixed cadence lets accounts burn
  // through a small reserve between checks.
  setInterval(() => {
    if (!IS_TAURI) return;
    if (onboardingVisible()) return;
    const now = Date.now();
    const interval = ((S.settings && S.settings.quotaInterval) || 300) * 1000;
    // Codex quota refresh and its notifications run in Rust so tray mode is
    // reliable; only provider-specific usage remains a WebView concern.
    // Claude usage: same configured cadence, floored at 180 s per the spec.
    const claudeDue = now - (S.lastClaudeUsageAt || 0) >= Math.max(180000, interval);
    if (claudeDue && !S.claudeLogin && (S.claude ? S.claude.connected : !!(S.settings && S.settings.claudeEnabled))) {
      A.claudeUsageLoad().then(() => {
        if (S.section === "providers" && !S.claudeLogin) render();
      }).catch(() => {});
    }
    // Antigravity metrics: same ≥180 s cadence, but only once we know the
    // provider is connected. The first probe discovers the state; after that
    // a disconnected provider costs no IPC, and errors back off exponentially.
    const agDue = now - (S.lastAntigravityAt || 0) >= Math.max(180000, interval);
    const agKnown = S.antigravity !== null && S.antigravity !== undefined;
    const agConnected = agKnown && S.antigravity.connected === true;
    if (agDue && !S.antigravityLogin && (!agKnown || agConnected) && now >= (S.antigravityBackoffUntil || 0)) {
      A.antigravityUsageLoad().then(() => {
        S.antigravityFailures = 0;
        S.antigravityBackoffUntil = 0;
        if (S.section === "providers" && !S.antigravityLogin) render();
      }).catch(() => {
        S.antigravityFailures = Math.min(4, (S.antigravityFailures || 0) + 1);
        S.antigravityBackoffUntil = Date.now() + Math.min(300000, 30000 * Math.pow(2, S.antigravityFailures));
      });
    }
  }, 30000);
  if (S.section === "providers" && IS_TAURI) {
    A.openrouterRefresh();
  }
})();
