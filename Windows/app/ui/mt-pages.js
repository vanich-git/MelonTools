// Melon Tools — page renderers (W6). Loaded before app.js; shared helpers
// live in mt-utils.js / mt-api.js and remain in the same classic-script global
// scope. This keeps page markup out of the action/state monolith.

function pageHead(kicker, title, subtitle) {
  return `<div class="page-head"><div class="kicker">${esc(kicker)}</div><h1>${esc(title)}</h1><div class="subtitle">${esc(subtitle)}</div></div>`;
}

// MARK: - Pages

function dashboardPage() {
  const accounts = Array.isArray(S.accounts) ? S.accounts : [];
  const ready = accounts.filter((a) => !a.blocked);
  const poolHourly = accounts.reduce((sum, a) => sum + (a.hourlyRemaining ?? 0), 0);
  const poolWeekly = accounts.reduce((sum, a) => sum + (a.weeklyRemaining ?? 0), 0);
  const status = S.status || {};
  const cards = dashboardVisibility(S.settings);
  const health = poolHealth(accounts, S.routing);
  const trends = quotaTrends(S.history, nowRef());
  const scheduleData = S.schedulerSummary || S.scheduler;
  const usage = usageSummary(scheduleData, S.bridge);
  const schedule = schedulerSummary(scheduleData, nowRef());

  return `
  ${pageHead("melon tools", t("dashTitle"), t("dashSub"))}
  ${dashboardCardToggles(S.settings)}
  <div class="grid2">
    <div class="card">
      <h2>${t("gateway")} <span class="hint">:${status.port || "—"}</span></h2>
      <div class="stack">
        <div class="row">
          <span class="dot ${status.running ? "ok" : "err"}"></span>
          <b>${status.running ? t("running") : t("stopped")}</b>
          <span class="pill">${t("reqs")}: ${status.requestsLastMinute ?? 0}</span>
          <span class="pill ${status.sidecarFound ? "ok" : "danger"}">${t("sidecar")}: ${status.sidecarFound ? t("found") : t("missing")}</span>
        </div>
        <div class="row">
          <button class="btn small" data-action="gatewayStart" ${S.busy.start ? "disabled" : ""}>${t("start")}</button>
          <button class="ghost small" data-action="gatewayStop" ${S.busy.stop ? "disabled" : ""}>${t("stop")}</button>
          <button class="ghost small" data-action="gatewaySync">${t("sync")}</button>
        </div>
      </div>
    </div>

    <div class="card">
      <h2>${t("poolSummary")} <span class="hint">${accounts.length} ${t("accountsCount")}</span></h2>
      <div class="stack">
        <div class="quota">
          <div class="top"><span class="name">${t("pool5h")}</span><span class="val">${Math.round(poolHourly)}%</span></div>
          <div class="bar"><i class="${quotaTint(poolHourly / Math.max(1, accounts.length))}" style="width:${Math.min(100, poolHourly / Math.max(1, accounts.length))}%"></i></div>
        </div>
        <div class="quota">
          <div class="top"><span class="name">${t("poolWeek")}</span><span class="val">${Math.round(poolWeekly)}%</span></div>
          <div class="bar"><i class="${quotaTint(poolWeekly / Math.max(1, accounts.length))}" style="width:${Math.min(100, poolWeekly / Math.max(1, accounts.length))}%"></i></div>
        </div>
        <div class="row">
          <span class="pill ${accounts.length && ready.length === accounts.length ? "ok" : "warn"}">
            ${accounts.length ? (ready.length === accounts.length ? t("allReady") : `${accounts.length - ready.length} ${t("blockedNow")}`) : "—"}
          </span>
        </div>
      </div>
    </div>
  </div>

  <div class="dash-grid">
    ${cards.pool ? dashboardPoolCard(health) : ""}
    ${cards.spend ? dashboardSpendCard(usage) : ""}
  </div>
  ${cards.trends ? dashboardTrendsCard(trends) : ""}
  ${cards.scheduler ? dashboardSchedulerCard(schedule) : ""}

  <div class="card">
    <h2>${t("quick")}</h2>
    <div class="row">
      <button class="btn small" data-action="refreshQuotas" ${S.busy.quotas ? "disabled" : ""}>${t("refreshQuotas")}</button>
      <button class="ghost small" data-action="importAuth">${t("importAuth")}</button>
      <button class="ghost small" data-action="checkApi" ${S.busy.check ? "disabled" : ""}>${t("check")}</button>
    </div>
    ${S.checkResult ? `<div class="footnote mono">${esc(S.checkResult)}</div>` : ""}
  </div>

  <div class="card">
    <h2>${t("recentCalls")}</h2>
    ${(S.calls && S.calls.length)
      ? `<table class="kv">${S.calls.map((call) => `<tr>
           <td>${esc(call.time || "")}</td>
           <td>${esc(call.method)} ${esc(call.path)} <span class="pill ${String(call.status).startsWith("2") ? "ok" : "warn"}">${esc(call.status)}</span> <span class="muted">${esc(call.duration || "")}</span></td>
         </tr>`).join("")}</table>`
      : `<div class="footnote">${t("noCalls")}</div>`}
  </div>

  ${!accounts.length ? `<div class="card"><div class="muted">${t("warnNoAccounts")}</div></div>` : ""}
  `;
}

function quotaBlock(title, percent, resetUnix, present) {
  const width = percent === null || percent === undefined ? 0 : Math.min(100, Math.max(0, percent));
  return `
  <div class="quota">
    <div class="top"><span class="name">${esc(title)}</span><span class="val">${round(percent)}</span></div>
    <div class="bar"><i class="${quotaTint(percent)}" style="width:${width}%"></i></div>
    <div class="bottom">
      <span>${present ? resetText(resetUnix) : t("onceReset")}</span>
    </div>
  </div>`;
}

function strategyOptions() {
  return [
    ["auto", "strategyAuto"],
    ["quotaHighFirst", "strategyQuotaHigh"],
    ["quotaLowFirst", "strategyQuotaLow"],
    ["planHighFirst", "strategyPlanHigh"],
    ["planLowFirst", "strategyPlanLow"],
    ["expirySoonFirst", "strategyExpiry"],
    ["custom", "strategyCustom"],
  ];
}

function subscriptionText(raw) {
  if (!raw) return "";
  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) return `${t("subscription")}: ${esc(raw)}`;
  const expired = date.getTime() < Date.now();
  const text = `${t("subscription")}: ${t("until")} ${date.toLocaleDateString()}`;
  return expired ? `${text} ⚠` : text;
}

function accountCard(account) {
  const resetsText = account.resetCreditsAvailable === null || account.resetCreditsAvailable === undefined
    ? t("resetsNone")
    : `${account.resetCreditsAvailable} ${t("available")}${account.resetCreditsNextExpiry ? " · " + resetText(account.resetCreditsNextExpiry) : ""}`;
  const models = account.modelAvailability || [];
  const modelsBlock = models.length
    ? `<details><summary class="footnote" style="cursor:pointer">${t("accountModels")} (${models.length})</summary>
         <div class="stack" style="margin-top:8px">
           ${models.map((m) => `<div class="row" style="gap:8px"><span class="pill ${m.available ? "ok" : ""}">${m.available ? t("availableShort") : t("unavailableShort")}</span><span class="mono" style="font-size:11px">${esc(m.model)}</span></div>`).join("")}
         </div>
       </details>`
    : "";
  return `
    <div class="card">
      <div class="account-head">
        <span class="email">${esc(account.email || account.displayName)}</span>
        ${account.planType ? `<span class="plan">${esc(account.planType)}</span>` : ""}
        ${account.preferredFirst ? `<span class="pill gold">${t("preferred")}</span>` : ""}
        ${account.isBackup ? `<span class="pill">${t("backup")}</span>` : ""}
        ${account.blocked
          ? `<span class="pill warn" title="${esc(blockText(account.blockInfo))}">${t("paused")}</span>`
          : `<span class="pill ok">${t("ready")}</span>`}
        <span class="spacer"></span>
        <button class="ghost small" title="${t("orderUp")}" data-action="movePriority" data-id="${esc(account.id)}" data-value="true">↑</button>
        <button class="ghost small" title="${t("orderDown")}" data-action="movePriority" data-id="${esc(account.id)}" data-value="false">↓</button>
      </div>

      <div class="stack">
        ${quotaBlock(t("fiveHour"), account.hourlyRemaining, account.hourlyResetAt, account.hourlyWindowPresent)}
        ${quotaBlock(t("week"), account.weeklyRemaining, account.weeklyResetAt, account.weeklyWindowPresent)}
        ${historyStrip(account.id)}

        ${account.blocked ? `<div class="footnote">⏸ ${esc(blockText(account.blockInfo))}</div>` : ""}
        <div class="row">
          ${account.subscriptionActiveUntil ? `<span class="footnote">${esc(subscriptionText(account.subscriptionActiveUntil))}</span>` : ""}
          <span class="footnote">${t("resetsAvailable")}: ${esc(resetsText)}</span>
        </div>
        <div class="footnote">${t("quotaAge")}: ${esc(ageText(account.quotaUpdatedAt))} · ${t(account.quotaSource === "gateway" ? "quotaLive" : "quotaUsage")}${account.quotaError ? " · " + esc(account.quotaError) : ""}</div>
        ${modelsBlock}

        <div class="row">
          <label class="field">${t("reserveHourly")}
            <input class="small" type="number" id="res-h-${esc(account.id)}" value="${account.hourlyReservePercent ?? ""}" min="0" max="100">
          </label>
          <label class="field">${t("reserveWeekly")}
            <input class="small" type="number" id="res-w-${esc(account.id)}" value="${account.weeklyReservePercent ?? ""}" min="0" max="100">
          </label>
          <label class="field">${t("preferred")}
            <input type="checkbox" ${account.preferredFirst ? "checked" : ""} data-action="setRole" data-role="preferred" data-id="${esc(account.id)}" data-value='${account.isBackup ? "true" : "false"}' data-on="change">
          </label>
          <label class="field">${t("backup")}
            <input type="checkbox" ${account.isBackup ? "checked" : ""} data-action="setRole" data-role="backup" data-id="${esc(account.id)}" data-value='${account.preferredFirst ? "true" : "false"}' data-on="change">
          </label>
          <button class="ghost small" data-action="saveReserves" data-id="${esc(account.id)}">${t("save")}</button>
          <button class="ghost small" data-action="poolOpenAccount" data-id="${esc(account.id)}">${t("models")}</button>
        </div>
        <div class="footnote">${esc(t("reserveExact"))}</div>

        <div class="row">
          <button class="btn small" data-action="switchAccount" data-id="${esc(account.id)}">${t("makeCurrent")}</button>
          <button class="ghost small" data-action="refreshQuota" data-id="${esc(account.id)}">${t("refreshQuota")}</button>
          <button class="ghost small" data-action="refreshLogin" data-id="${esc(account.id)}">${t("refreshLogin")}</button>
          <span class="spacer"></span>
          <button class="ghost small danger" data-action="deleteAccount" data-id="${esc(account.id)}">${t("remove")}</button>
        </div>
      </div>
    </div>`;
}

function accountsPage() {
  const accounts = S.accounts || [];
  const status = S.status || {};
  const routing = S.routing || { strategy: "auto", orderedIds: [], blockedIds: [] };
  const orderedIds = routing.orderedIds && routing.orderedIds.length ? routing.orderedIds : accounts.map((a) => a.id);
  const byId = new Map(accounts.map((a) => [a.id, a]));
  const ordered = orderedIds.filter((id) => byId.has(id));
  // A newly imported account may not be present in a stale routing snapshot.
  for (const account of accounts) {
    if (!ordered.includes(account.id)) ordered.push(account.id);
  }
  const cards = ordered
    .map((id) => accountCard(byId.get(id)))
    .join("");

  const deviceLogin = S.deviceLogin;
  const deviceCard = `
    <div class="card">
      <h2>${t("addAccount")}</h2>
      <div class="stack">
        ${deviceLogin && !deviceLogin.done
          ? `<div class="row">
               <span class="muted">${t("deviceCode")}:</span>
               <b class="mono" style="font-size:16px">${esc(deviceLogin.userCode)}</b>
               <button class="ghost small" data-action="copy" data-text='${esc(deviceLogin.userCode)}'>${t("copy")}</button>
               <button class="btn small" data-action="deviceOpen">${t("deviceOpen")}</button>
             </div>
             <div class="footnote">${t("deviceWaiting")}</div>`
          : `<div class="row">
               <button class="btn small" data-action="deviceStart" ${S.busy.device ? "disabled" : ""}>${t("addAccount")}</button>
               <span class="footnote">${t("addAccountHint")}</span>
             </div>`}
      </div>
    </div>`;

  const strategy = strategyOptions();
  const routingCard = `
    <div class="card">
      <h2>${t("routing")}</h2>
      <div class="row">
        <label class="field">${t("strategy")}
          <select id="routing-strategy" data-action="setStrategy" data-on="change">
            ${strategy.map(([value, key]) => `<option value="${value}" ${routing.strategy === value ? "selected" : ""}>${t(key)}</option>`).join("")}
          </select>
        </label>
        <button class="ghost small" data-action="resetOrder">${t("resetOrder")}</button>
        <span class="spacer"></span>
        <span class="footnote">${t("preferred")} → ${t("ready")} → ${t("paused")}</span>
      </div>
    </div>`;

  return `
  ${pageHead("codex", t("accounts"), t("accountsSub"))}
  ${poolPauseBanner()}
  <div class="row">
    <button class="btn" data-action="importAuth">${t("importAuth")}</button>
    <button class="ghost small" data-action="importJsonPick">${t("importJson")}</button>
    <input type="file" id="accounts-json-file" accept=".json,application/json" hidden data-action="importJsonFile" data-on="change">
    <span class="footnote">${t("importHint")}</span>
  </div>
  ${deviceCard}
  ${routingCard}
  <div class="accounts">${cards || `<div class="card"><div class="muted">${t("warnNoAccounts")}</div></div>`}</div>

  <div class="card">
    <h2>${t("gateway")} <span class="hint">:${status.port || "—"}</span></h2>
    <div class="row">
      <span class="dot ${status.running ? "ok" : "err"}"></span>
      <b>${status.running ? t("running") : t("stopped")}</b>
      <span class="pill">${t("reqs")}: ${status.requestsLastMinute ?? 0}</span>
      <span class="spacer"></span>
      <button class="btn small" data-action="gatewayStart">${t("start")}</button>
      <button class="ghost small" data-action="gatewayStop">${t("stop")}</button>
    </div>
  </div>
  ${poolModal()}`;
}

function apiPage() {
  const status = S.status || {};
  const settings = S.settings || {};
  const route = S.route;
  const bridge = S.bridge;
  const base = `http://127.0.0.1:${settings.port || status.port || 18317}/v1`;
  const routeState = !route || !route.provider
    ? `<span class="pill warn">${t("routeInactive")}</span>`
    : route.ours
      ? `<span class="pill ok">${t("routeActive")}</span>`
      : `<span class="pill danger">${t("routeOther")}: ${esc(route.provider)}</span>`;
  const bridgeState = bridge && bridge.attached
    ? `<span class="pill ok">${t("bridgeOn")}</span><span class="pill">${t("port")}: ${esc(bridge.debugPort ?? "—")}</span>${bridge.model ? `<span class="pill gold">${esc(bridge.model)}</span>` : ""}`
    : `<span class="pill warn">${t("bridgeOff")}</span><span class="footnote">${t("bridgeHint")}${bridge && bridge.reason ? " · " + esc(bridge.reason) : ""}</span>`;
  return `
  ${pageHead("codex", t("api"), t("apiSub"))}
  <div class="card">
    <h2>${t("gateway")}</h2>
    <div class="stack">
      <div class="row">
        <span class="dot ${status.running ? "ok" : "err"}"></span>
        <b>${status.running ? t("running") : t("stopped")}</b>
        <span class="pill">${t("reqs")}: ${status.requestsLastMinute ?? 0}</span>
        <span class="spacer"></span>
        <button class="btn small" data-action="gatewayStart">${t("start")}</button>
        <button class="ghost small" data-action="gatewayStop">${t("stop")}</button>
      </div>
      <table class="kv">
        <tr><td>${t("endpoint")}</td><td>${esc(base)}</td></tr>
        <tr><td>${t("apiKey")}</td><td>${esc(settings.apiKey || "—")} <button class="ghost small" data-action="copy" data-text='${esc(settings.apiKey || "")}'>${t("copy")}</button></td></tr>
        <tr><td>${t("logFile")}</td><td>${esc(status.logPath || "—")}</td></tr>
        <tr><td>${t("dataDir")}</td><td>${esc(status.dataDir || "—")}</td></tr>
      </table>
    </div>
  </div>

  <div class="card">
    <h2>${t("codexRoute")}</h2>
    <div class="stack">
      <div class="row">${routeState}</div>
      <div class="row">${bridgeState}</div>
      <table class="kv">
        <tr><td>config.toml</td><td>${esc((route && route.configPath) || "—")}</td></tr>
        <tr><td>${t("catalog")}</td><td>${route && route.catalogExists ? "✓ " + esc(route.catalogPath || "") : "—"}</td></tr>
      </table>
      <div class="row">
        <button class="btn small" data-action="codexRouteApply" ${S.busy.route ? "disabled" : ""}>${t("routeApply")}</button>
        <button class="ghost small" data-action="codexRouteRemove">${t("routeRemove")}</button>
        ${bridge && bridge.attached ? "" : `<button class="ghost small" data-action="bridgeLaunchCodex" ${S.busy.launch ? "disabled" : ""}>${t("bridgeRestart")}</button>`}
      </div>
    </div>
  </div>

  <div class="card">
    <h2>${t("endpointsTitle")}</h2>
    <table class="kv">
      <tr><td>OpenAI-compatible</td><td>${esc(base)}/chat/completions · /responses · /models</td></tr>
      <tr><td>${t("apiKey")}</td><td>Authorization: Bearer ${esc(settings.apiKey || "…")}</td></tr>
    </table>
  </div>

  <div class="card">
    <h2>${t("checkTitle")} <span class="hint">${t("checkHint")}</span></h2>
    <div class="row">
      <button class="btn small" data-action="checkApi" ${S.busy.check ? "disabled" : ""}>${t("check")}</button>
    </div>
    ${S.checkResult ? `<div class="footnote mono">${esc(S.checkResult)}</div>` : ""}
  </div>`;
}

function claudeQuotaTile(title, percent, resetIso) {
  const width = percent === null || percent === undefined ? 0 : Math.min(100, Math.max(0, percent));
  return `
  <div class="quota">
    <div class="top"><span class="name">${esc(title)}</span><span class="val">${round(percent)}</span></div>
    <div class="bar"><i class="${quotaTint(percent)}" style="width:${width}%"></i></div>
    <div class="bottom"><span>${claudeResetText(resetIso)}</span></div>
  </div>`;
}

function claudeCard(settings) {
  const u = S.claude;
  const login = S.claudeLogin;
  const connected = !!(u && u.connected);
  const pillClass = login ? "warn" : connected ? "ok" : u && u.error ? "danger" : "";
  const pillText = login ? t("claudeConnecting") : connected ? t("claudeConnected") : u && u.error ? t("error") : t("claudeNotConnected");
  const actions = login
    ? `<button class="btn small" disabled>${t("claudeConnecting")}</button>
       <button class="ghost small" data-action="claudeCancel">${t("claudeCancel")}</button>`
    : `${connected ? "" : `<button class="btn small" data-action="claudeConnect" ${S.busy.claudeConnect ? "disabled" : ""}>${t("claudeConnect")}</button>`}
       <button class="ghost small" data-action="claudeRefreshUsage" ${S.busy.claudeUsage ? "disabled" : ""}>${t("refresh")}</button>
       ${connected ? `<button class="ghost small" data-action="claudeDisconnect" ${S.busy.claudeDisconnect ? "disabled" : ""}>${t("claudeDisconnect")}</button>` : ""}`;

  return `
  <div class="card">
    <h2>${t("claude")} <span class="pill ${pillClass}">${pillText}</span></h2>
    <div class="stack">
      <div class="row">
        <span class="muted">${esc((u && u.email) || "—")}</span>
        ${u && u.plan ? `<span class="pill gold">${esc(u.plan)}</span>` : ""}
        <span class="pill">${t("models")}: ${u && u.modelCount !== null && u.modelCount !== undefined ? u.modelCount : "—"}</span>
      </div>
      <div class="grid2">
        ${claudeQuotaTile(t("fiveHour"), u ? u.fiveHourPercent : null, u ? u.fiveHourReset : null)}
        ${claudeQuotaTile(t("week"), u ? u.weeklyPercent : null, u ? u.weeklyReset : null)}
      </div>
      ${historyStrip("claude")}
      ${u && u.error ? `<div class="footnote">${esc(u.error)}</div>` : ""}
      ${u && u.lastQos ? `<div class="footnote" style="margin-top:0">${u.lastQos.timedOut
        ? `${esc(t("lastSwitch"))}: ${esc(u.lastQos.auth || "—")} · ${esc(u.lastQos.model || "—")} · ${u.lastQos.cooldownSeconds || 0} ${esc(t("sec"))}`
        : `${esc(t("firstToken"))}: ${u.lastQos.ttftMs || 0} ms · ${esc(u.lastQos.model || "—")}`}</div>` : ""}
      ${u && u.updatedAt ? `<div class="footnote">${t("quotaAge")}: ${esc(claudeAgeText(u.updatedAt))}</div>` : ""}
      <div class="row">${actions}</div>

      <label class="field">${t("claudeKey")}
        <input type="password" id="claude-key" value="${esc(settings.claudeApiKey || "")}" placeholder="sk-ant-…">
      </label>
      <div class="row">
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" id="claude-enabled" ${settings.claudeEnabled ? "checked" : ""} data-action="providerToggleChanged" data-on="change">
          <span>${t("sourceEnabled")}</span>
        </label>
        <button class="btn small" data-action="claudeSaveKeys">${t("save")}</button>
      </div>
      <div class="footnote">${t("claudeHint")}</div>
    </div>
  </div>`;
}

// Why the account is quarantined: a first-token timeout (504 from the QoS
// watchdog) and a Google quota window look identical in the badge alone.
function cooldownReason(cooldown) {
  if (!cooldown) return "";
  let key = "";
  if (cooldown.http_status === 504) key = "waitingFirstToken";
  else
    switch (cooldown.reason) {
      case "quota":
      case "credential_quota":
        key = "quotaExhausted";
        break;
      case "cloudflare_challenge":
        key = "cloudflareChallenge";
        break;
      case "unauthorized":
      case "invalid_grant":
        key = "signInAgain";
        break;
      case "payment_required":
        key = "paymentRequired";
        break;
      case "model_not_supported":
        key = "modelNotSupported";
        break;
      case "transient_error":
        key = "upstreamError";
        break;
      default:
        key = "";
    }
  return key ? " · " + esc(t(key)) : "";
}

function antigravityQuotaRow(label, window) {
  if (!window || typeof window.remaining !== "number") return "";
  const percent = Math.max(0, Math.min(100, Math.round(window.remaining * 100)));
  const color = percent > 50 ? "ok" : percent > 20 ? "warn" : "danger";
  const reset = window.resetAt ? new Date(window.resetAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "—";
  return `<div class="row" style="gap:8px;align-items:center">
    <span class="muted" style="width:92px;font-size:10px">${esc(label)}</span>
    <div class="quota-track" style="flex:1;max-width:220px"><div class="quota-fill ${color}" style="width:${percent}%"></div></div>
    <span class="mono" style="font-size:10px;font-weight:600">${percent}%</span>
    <span class="footnote" style="margin:0">${esc(t("reset"))} ${esc(reset)}</span>
  </div>`;
}

function antigravityCard() {
  const u = S.antigravity;
  const login = S.antigravityLogin;
  const accounts = (u && Array.isArray(u.accounts)) ? u.accounts : [];
  const connected = accounts.length > 0;
  const pillClass = login ? "warn" : connected ? "ok" : u && u.error ? "danger" : "";
  const pillText = login
    ? t("antigravityConnecting")
    : connected
      ? fmt(t("accountsInPool"), { n: accounts.length })
      : u && u.error ? t("error") : t("antigravityNotConnected");
  const actions = login
    ? `<button class="btn small" disabled>${t("antigravityConnecting")}</button>
       <button class="ghost small" data-action="antigravityCancel">${t("antigravityCancel")}</button>`
    : `<button class="btn small" data-action="antigravityConnect" ${S.busy.antigravityConnect ? "disabled" : ""}>${t("addGoogleAccount")}</button>
       <button class="ghost small" data-action="antigravityRefresh" ${S.busy.antigravityUsage ? "disabled" : ""}>${t("refresh")}</button>
       ${connected ? `<button class="ghost small" data-action="antigravityDisconnect" ${S.busy.antigravityDisconnect ? "disabled" : ""}>${t("disconnectAll")}</button>` : ""}`;

  const rows = accounts.map((account) => {
    const cooldown = (account.cooldowns || [])[0];
    // Only a first-token cooldown can be released by the probe; a quota or
    // sign-in cooldown stays with the engine, so the button would only fail.
    const probeable = (account.cooldowns || []).some((item) => item.http_status === 504);
    const paused = !!account.disabled;
    const until = cooldown && cooldown.retry_at
      ? new Date(cooldown.retry_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
      : "—";
    return `<div class="account-row">
      <div class="row" style="gap:8px;align-items:center">
        <span class="pill ${paused ? "" : cooldown ? "warn" : "ok"}">${paused ? esc(t("paused")) : cooldown ? esc(t("quarantined")) : esc(t("antigravityConnected"))}</span>
        <span class="mono" style="font-size:11px;font-weight:600">${esc(account.email || account.name)}</span>
        ${account.projectId ? `<span class="pill gold">${esc(account.projectId)}</span>` : ""}
        <span class="footnote" style="margin:0">${fmt(t("modelsInAccount"), { n: (account.models || []).length })}</span>
        ${account.priority ? `<span class="pill gold">P${account.priority}</span>` : ""}
        <span style="flex:1"></span>
        <button class="ghost small" title="${esc(t("raisePriority"))}" data-action="antigravityPriority" data-id="${esc(account.name)}" data-value="${account.priority + 1}">↑</button>
        <button class="ghost small" title="${esc(t("lowerPriority"))}" data-action="antigravityPriority" data-id="${esc(account.name)}" data-value="${account.priority - 1}">↓</button>
        <button class="ghost small" data-action="antigravityPause" data-id="${esc(account.name)}">${paused ? esc(t("resumeAccount")) : esc(t("pauseAccount"))}</button>
        ${probeable ? `<button class="ghost small" data-action="antigravityProbe" data-id="${esc(account.name)}">${esc(t("probe"))}</button>` : ""}
        <button class="ghost small" data-action="antigravityRemove" data-id="${esc(account.name)}">${esc(t("removeAccount"))}</button>
      </div>
      ${cooldown ? `<div class="footnote" style="margin:2px 0 0;color:var(--warn)">${esc(t("quarantinedUntil"))} ${esc(until)}${cooldownReason(cooldown)}</div>` : ""}
      ${antigravityQuotaRow(t("geminiPool"), account.gemini)}
      ${antigravityQuotaRow(t("claudePool"), account.claude)}
      ${!account.gemini && !account.claude && account.quotaError ? `<div class="footnote" style="margin-top:2px">${esc(account.quotaError)}</div>` : ""}
    </div>`;
  }).join("");

  const catalogOnly = (u && Array.isArray(u.catalogOnly)) ? u.catalogOnly : [];
  const unavailable = catalogOnly.length
    ? `<div class="footnote" style="margin-top:10px">${esc(t("catalogOnlyTitle"))}</div>
       ${catalogOnly.map((model) => `<div class="row" style="gap:6px;opacity:.65">
          <span>🔒</span><span class="mono" style="font-size:10px">${esc(model.displayName)}</span>
          <span class="footnote" style="margin:0">${esc(model.id)}</span>
       </div>`).join("")}
       <div class="footnote">${esc(t("catalogOnlyHint"))}</div>`
    : "";

  return `
  <div class="card">
    <h2>${t("antigravity")} <span class="pill ${pillClass}">${pillText}</span></h2>
    <div class="stack">
      ${accounts.length ? rows : `<div class="footnote">${t("antigravityHint")}</div>`}
      ${u && u.error ? `<div class="footnote">${esc(u.error)}</div>` : ""}
      ${unavailable}
      <div class="row">${actions}</div>
      <div class="footnote">${t("antigravityQosScope")}</div>
      <div class="footnote">${t("antigravityWeeklyHint")}</div>
    </div>
  </div>`;
}

// Read-only diagnostics: every value comes from an existing IPC call, and
// rejected calls are printed verbatim instead of being summarized.
function diagCell(value) {
  const text = value && value.text !== undefined && value.text !== null && value.text !== ""
    ? String(value.text)
    : "—";
  const cls = value && value.cls ? ` ${value.cls}` : "";
  return `<td><span class="pill${cls}">${esc(text)}</span></td>`;
}

function diagnosticsCard() {
  const diag = S.diag;
  return `
  <div class="card">
    <h2>${t("diagTitle")} <span class="hint">${t("diagHint")}</span></h2>
    <div class="row">
      <button class="btn small" data-action="diagRun" ${S.busy.diag ? "disabled" : ""}>${t("diagRun")}</button>
      <button class="ghost small" data-action="supportBundle" ${S.busy.support ? "disabled" : ""}>${t("supportBundle")}</button>
      <span class="footnote" style="margin-top:0">${diag ? `${t("diagAt")}: ${esc(ageText(diag.at / 1000))}` : t("diagIdle")}</span>
    </div>
    ${diag ? `
      <table class="diag">
        <thead><tr>
          <th>${t("diagProvider")}</th>
          <th>${t("gateway")}</th>
          <th>${t("diagAuth")}</th>
          <th>${t("models")}</th>
          <th>${t("diagQuota")}</th>
        </tr></thead>
        <tbody>
          ${diag.rows.map((row) => `<tr>
            <td>${esc(row.name)}</td>
            ${diagCell(row.reach)}
            ${diagCell(row.auth)}
            ${diagCell(row.models)}
            ${diagCell(row.quota)}
          </tr>`).join("")}
        </tbody>
      </table>
      ${diag.errors.length ? `<div class="stack" style="margin-top:10px">
        ${diag.errors.map((item) => `<div class="footnote mono" style="margin-top:0;white-space:pre-wrap">${esc(item.command)}: ${esc(item.message)}</div>`).join("")}
      </div>` : ""}` : ""}
  </div>`;
}

function providerMetric(label, value, cls = "") {
  const text = value === null || value === undefined || value === "" ? "—" : String(value);
  return `<div class="stat ${cls}"><span class="value">${esc(text)}</span><span class="label">${esc(label)}</span></div>`;
}

function providerRatio(part, whole) {
  const value = finiteNumber(part);
  const total = finiteNumber(whole);
  if (value === null || total === null || total <= 0) return null;
  return Math.min(1, Math.max(0, value / total));
}

function providerMeterMetric(label, value, caption, part, whole, tint, valueClass = "") {
  const ratio = providerRatio(part, whole);
  const percent = ratio === null ? null : Math.round(ratio * 1000) / 10;
  const meter = percent === null
    ? '<div class="provider-meter-placeholder" aria-hidden="true"></div>'
    : `<div class="provider-meter" role="meter" aria-label="${esc(label)}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${percent}"><i class="${tint}" style="width:${percent}%"></i></div>`;
  return `<div class="stat provider-stat ${valueClass}">
    <span class="label">${esc(label)}</span>
    <span class="value">${esc(String(value ?? "—"))}</span>
    ${meter}
    <span class="provider-caption">${esc(caption || "")}</span>
  </div>`;
}

function providerKeyPill(configured) {
  return `<span class="pill ${configured ? "ok" : ""}">${configured ? t("keyConfigured") : t("noKey")}</span>`;
}

function providerModelCount(provider) {
  const rows = S.settings && Array.isArray(S.settings[`${provider}Models`])
    ? S.settings[`${provider}Models`]
    : null;
  return rows ? rows.length : 0;
}

function sessionProviderSpend(provider) {
  const session = S.bridge && S.bridge.session;
  const cost = session && session.cost;
  const stats = cost && cost.providers && cost.providers[provider];
  return finiteNumber(stats && stats.usd);
}

function openRouterCard(settings) {
  const p = S.providers;
  const configured = !!(settings.openrouterKey || "").trim();
  const creditsTotal = finiteNumber(p && p.totalCredits);
  const creditsSpent = finiteNumber(p && p.totalUsage);
  const reportedCreditsRemaining = finiteNumber(p && p.remaining);
  const calculatedCreditsRemaining = creditsTotal !== null && creditsSpent !== null
    ? Math.max(0, creditsTotal - creditsSpent)
    : null;
  const creditsRemaining = reportedCreditsRemaining !== null
    ? Math.max(0, reportedCreditsRemaining)
    : calculatedCreditsRemaining;
  const keyLimit = finiteNumber(p && p.limit);
  const keyUsage = finiteNumber(p && p.usage);
  const reportedKeyRemaining = finiteNumber(p && p.limitRemaining);
  const calculatedKeyRemaining = keyLimit !== null && keyUsage !== null
    ? Math.max(0, keyLimit - keyUsage)
    : null;
  const keyRemaining = reportedKeyRemaining !== null
    ? Math.max(0, reportedKeyRemaining)
    : calculatedKeyRemaining;
  return `
  <div class="card provider-card">
    <h2>${t("openrouter")} ${providerKeyPill(configured)}</h2>
    <div class="stat-grid">
      ${providerMeterMetric(t("available"), formatMoney(creditsRemaining), t("balance"), null, null, "green")}
      ${providerMeterMetric(
        t("spend"),
        formatMoney(creditsSpent),
        creditsTotal === null ? t("lifetime") : `${t("lifetime")} · ${t("totalCredits").toLowerCase()} ${formatMoney(creditsTotal)}`,
        null,
        null,
        "gold",
        "gold"
      )}
      ${providerMeterMetric(
        t("keyRemaining"),
        formatMoney(keyRemaining),
        keyLimit === null ? t("keyLimit") : `${t("keyLimit")} ${formatMoney(keyLimit)}`,
        keyRemaining,
        keyLimit,
        "blue"
      )}
    </div>
    <div class="stack" style="margin-top:12px">
      <label class="field">${t("orKey")}
        <input type="password" id="or-key" value="${esc(settings.openrouterKey || "")}" placeholder="sk-or-v1-…">
      </label>
      <div class="row">
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" id="or-enabled" ${settings.openrouterEnabled ? "checked" : ""} data-action="providerToggleChanged" data-on="change">
          <span>${t("sourceEnabled")}</span>
        </label>
        <span class="spacer"></span>
        <button class="btn small" data-action="saveKeys">${t("save")}</button>
        <button class="ghost small" data-action="openrouterRefresh" ${S.busy.openrouter ? "disabled" : ""}>${t("refresh")}</button>
      </div>
      ${historyStrip("openrouter")}
    </div>
  </div>`;
}

function openCodeCard(settings) {
  const configured = !!(settings.opencodeKey || "").trim();
  const count = S.models ? S.models.filter((m) => String(m.id || "").startsWith("opencode/")).length : null;
  return `
  <div class="card provider-card">
    <h2>${t("opencode")} ${providerKeyPill(configured)}</h2>
    <div class="stat-grid">
      ${providerMetric(t("modelsAvailable"), count === null ? "—" : count)}
      ${providerMetric(t("sessionSpend"), formatMoney(sessionProviderSpend("opencode")))}
    </div>
    <div class="stack" style="margin-top:12px">
      <label class="field">${t("ocKey")}
        <input type="password" id="oc-key" value="${esc(settings.opencodeKey || "")}" placeholder="oc_sk_…">
      </label>
      <div class="row">
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" id="oc-enabled" ${settings.opencodeEnabled ? "checked" : ""} data-action="providerToggleChanged" data-on="change">
          <span>${t("sourceEnabled")}</span>
        </label>
        <span class="spacer"></span>
        <button class="btn small" data-action="saveKeys">${t("save")}</button>
      </div>
      <div class="footnote">${t("ocHint")}</div>
    </div>
  </div>`;
}

function deepInfraCard(settings) {
  const configured = !!(settings.deepinfraKey || "").trim();
  const error = S.providerModelsError.deepinfra;
  return `
  <div class="card provider-card">
    <h2>${t("deepinfra")} ${providerKeyPill(configured)}</h2>
    <div class="stat-grid">
      ${providerMetric(t("modelsAvailable"), providerModelCount("deepinfra"))}
      ${providerMetric(t("sessionSpend"), formatMoney(sessionProviderSpend("deepinfra")))}
    </div>
    <div class="stack" style="margin-top:12px">
      <label class="field">${t("diKey")}
        <input type="password" id="di-key" value="${esc(settings.deepinfraKey || "")}" placeholder="di_…">
      </label>
      <div class="row">
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" id="di-enabled" ${settings.deepinfraEnabled ? "checked" : ""} data-action="providerToggleChanged" data-on="change">
          <span>${t("sourceEnabled")}</span>
        </label>
        <span class="spacer"></span>
        <button class="btn small" data-action="saveKeys">${t("save")}</button>
        <button class="ghost small" data-action="loadProviderModels" data-id="deepinfra" ${S.busy["models-deepinfra"] ? "disabled" : ""}>${t("loadModels")}</button>
      </div>
      ${error ? `<div class="footnote mono">${esc(error)}</div>` : ""}
      <div class="footnote">${t("diHint")}</div>
    </div>
  </div>`;
}

function vercelCard(settings) {
  const configured = !!(settings.vercelKey || "").trim();
  const v = S.vercel;
  const error = S.providerModelsError.vercel || (v && v.error);
  const balance = v ? finiteNumber(v.balance) : null;
  return `
  <div class="card provider-card">
    <h2>${t("vercel")} ${providerKeyPill(configured)}</h2>
    <div class="stat-grid">
      ${providerMetric(t("teamBalance"), balance === null ? "—" : formatMoney(balance), balance === null ? "" : "ok")}
      ${providerMetric(t("lifetimeSpend"), v ? formatMoney(v.totalUsed) : "—")}
      ${providerMetric(t("modelsAvailable"), providerModelCount("vercel"))}
      ${providerMetric(t("sessionSpend"), formatMoney(sessionProviderSpend("vercel")))}
    </div>
    <div class="stack" style="margin-top:12px">
      <label class="field">${t("vcKey")}
        <input type="password" id="vc-key" value="${esc(settings.vercelKey || "")}" placeholder="vck_…">
      </label>
      <div class="row">
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" id="vc-enabled" ${settings.vercelEnabled ? "checked" : ""} data-action="providerToggleChanged" data-on="change">
          <span>${t("sourceEnabled")}</span>
        </label>
        <span class="spacer"></span>
        <button class="btn small" data-action="saveKeys">${t("save")}</button>
        <button class="ghost small" data-action="vercelRefresh" ${S.busy.vercel ? "disabled" : ""}>${t("refresh")}</button>
        <button class="ghost small" data-action="loadProviderModels" data-id="vercel" ${S.busy["models-vercel"] ? "disabled" : ""}>${t("loadModels")}</button>
      </div>
      ${error ? `<div class="footnote mono">${esc(error)}</div>` : ""}
      <div class="footnote">${t("vcHint")}</div>
    </div>
  </div>`;
}

// MARK: - Z.ai provider

function zaiCard(settings) {
  const configured = !!(settings.zaiKey || "").trim();
  const error = S.providerModelsError.zai;
  return `
  <div class="card provider-card">
    <h2>${t("zai")} ${providerKeyPill(configured)}</h2>
    <div class="stat-grid">
      ${providerMetric(t("modelsAvailable"), providerModelCount("zai"))}
      ${providerMetric(t("sessionSpend"), formatMoney(sessionProviderSpend("zai")))}
    </div>
    <div class="stack" style="margin-top:12px">
      <label class="field">${t("zaiKey")}
        <input type="password" id="zai-key" value="${esc(settings.zaiKey || "")}" placeholder="id.secret">
      </label>
      <div class="row">
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" id="zai-enabled" ${settings.zaiEnabled ? "checked" : ""} data-action="providerToggleChanged" data-on="change">
          <span>${t("sourceEnabled")}</span>
        </label>
        <span class="spacer"></span>
        <button class="btn small" data-action="saveKeys">${t("save")}</button>
        <button class="ghost small" data-action="loadProviderModels" data-id="zai" ${S.busy["models-zai"] ? "disabled" : ""}>${t("loadModels")}</button>
      </div>
      ${error ? `<div class="footnote mono">${esc(error)}</div>` : ""}
      <div class="footnote">${t("zaiHint")}</div>
    </div>
  </div>`;
}

// MARK: - Codex model pool

function poolFilteredModels() {
  const pool = S.pool;
  const models = (pool && pool.models) || [];
  const query = String(S.poolQuery || "").trim().toLowerCase();
  if (!query) return models;
  return models.filter((model) => {
    const haystack = `${model.slug || ""} ${model.display || ""}`.toLowerCase();
    return haystack.includes(query);
  });
}

function poolContextText(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return "";
  return n >= 1000 ? `${Math.round(n / 1000)}k` : String(n);
}

// Global mode row: the whole row flips the model for every account. The
// checkbox is a visual tri-state (all / some / none) driven by selectedCount.
function poolRowGlobal(model, accountCount) {
  const slug = String(model.slug || "");
  const selected = model.selectedCount || 0;
  const total = accountCount || 0;
  const all = total > 0 && selected >= total;
  const stateClass = all ? "on" : selected > 0 ? "mixed" : "";
  const context = poolContextText(model.contextLength);
  return `<div class="pool-row" role="checkbox" aria-checked="${all ? "true" : selected > 0 ? "mixed" : "false"}"
      data-action="poolToggleGlobal"
      data-id="${esc(slug)}"
      data-value='${all ? "false" : "true"}'
      ${S.busy["pool-toggle-" + slug] ? 'style="opacity:0.5"' : ""}>
    <span class="pool-check ${stateClass}"></span>
    <span class="pool-name">${esc(model.display || slug)}</span>
    <span class="mono pool-slug">${esc(slug)}</span>
    ${context ? `<span class="footnote">${esc(context)}</span>` : ""}
    <span class="spacer"></span>
    <span class="footnote">${esc(fmt(t("poolAccounts"), { n: selected, total }))}</span>
  </div>`;
}

// Account mode row: a plain checkbox bound to S.poolDraft; the availability
// pill mirrors the per-account probe when the backend reported it.
function poolRowAccount(model, account, draft) {
  const slug = String(model.slug || "");
  const context = poolContextText(model.contextLength);
  const availability = account && Array.isArray(account.modelAvailability)
    ? account.modelAvailability.find((item) => item && item.model === slug)
    : null;
  return `<label class="pool-row pool-row-static">
    <input type="checkbox" ${draft.has(slug) ? "checked" : ""} data-action="poolToggleAccount" data-id="${esc(slug)}" data-on="change">
    <span class="pool-name">${esc(model.display || slug)}</span>
    <span class="mono pool-slug">${esc(slug)}</span>
    ${context ? `<span class="footnote">${esc(context)}</span>` : ""}
    <span class="spacer"></span>
    ${availability ? `<span class="pill ${availability.available ? "ok" : ""}">${esc(availability.available ? t("availableShort") : t("poolUnavailable"))}</span>` : ""}
  </label>`;
}

function poolCountText() {
  const pool = S.pool;
  if (!pool) return t("loading");
  if (S.poolModal && S.poolModal.mode === "account") {
    return fmt(t("poolAccountSelected"), { n: (S.poolDraft || []).length, total: (pool.models || []).length });
  }
  return fmt(t("poolInPool"), { n: pool.selectedCount, total: (pool.models || []).length });
}

function poolListRows() {
  const pool = S.pool;
  if (!pool) return `<div class="muted">${esc(t("loading"))}</div>`;
  const models = poolFilteredModels();
  if (!models.length) return `<div class="footnote">${esc(t("noCalls"))}</div>`;
  if (S.poolModal && S.poolModal.mode === "account") {
    const account = (S.accounts || []).find((a) => a.id === S.poolModal.accountId);
    const draft = new Set(S.poolDraft || []);
    return models.map((model) => poolRowAccount(model, account, draft)).join("");
  }
  return models.map((model) => poolRowGlobal(model, pool.accountCount || 0)).join("");
}

// The search input keeps focus across typing, so search and the account
// toggles patch the modal fragments in place instead of re-rendering.
function poolModalFooterRefresh() {
  const draftEmpty = !(S.poolDraft || []).length;
  const warning = document.getElementById("pool-atleast");
  if (warning) warning.hidden = !draftEmpty;
  const save = document.getElementById("pool-save");
  if (save) save.disabled = draftEmpty;
}

function poolModalRefresh() {
  const list = document.getElementById("pool-list");
  if (list) list.innerHTML = poolListRows();
  const count = document.getElementById("pool-count");
  if (count) count.textContent = poolCountText();
  poolModalFooterRefresh();
}

function poolModal() {
  const modal = S.poolModal;
  if (!modal) return "";
  const account = modal.mode === "account"
    ? (S.accounts || []).find((a) => a.id === modal.accountId)
    : null;
  const title = modal.mode === "account"
    ? `${t("models")} · ${account ? account.email || account.displayName : modal.accountId}`
    : t("poolTitle");
  const draftEmpty = modal.mode === "account" && !(S.poolDraft || []).length;
  return `<div class="modal" id="pool-modal"><div class="modal-card pool-modal-card">
    <div class="modal-head">
      <h2>${esc(title)}</h2>
      <button type="button" class="onboarding-close" title="${esc(t("poolCloseLabel"))}" aria-label="${esc(t("poolCloseLabel"))}" data-action="poolClose">×</button>
    </div>
    <div class="subtitle" style="margin-bottom:10px">${esc(t("poolSubtitle"))}</div>
    <div class="row">
      <input type="text" id="pool-search" placeholder="${esc(t("modelsSearch"))}" value="${esc(S.poolQuery || "")}" data-action="poolSearch" data-on="input">
      <button class="ghost small" data-action="poolRefresh" ${S.busy["pool-refresh"] ? "disabled" : ""}>${t("loadModels")}</button>
      ${modal.mode === "account" ? `<button class="ghost small" data-action="poolSelectAll">${t("poolAll")}</button>
      <button class="ghost small" data-action="poolClearAll">${t("poolClear")}</button>` : ""}
      <span class="spacer"></span>
      <span class="footnote" id="pool-count">${esc(poolCountText())}</span>
    </div>
    ${S.poolError ? `<div class="footnote" style="color:var(--danger)">${esc(S.poolError)}</div>` : ""}
    <div class="pool-list" id="pool-list">${poolListRows()}</div>
    ${modal.mode === "account" ? `
    <div class="row" style="justify-content:flex-end;margin-top:12px">
      <span class="footnote" id="pool-atleast" style="color:var(--warn)" ${draftEmpty ? "" : "hidden"}>${esc(t("poolAtLeastOne"))}</span>
      <span class="spacer"></span>
      <button class="ghost" data-action="poolClose">${t("cancel")}</button>
      <button class="btn" id="pool-save" data-action="poolSaveAccount" ${draftEmpty || S.busy["pool-save-" + modal.accountId] ? "disabled" : ""}>${t("save")}</button>
    </div>
    <div class="footnote">${esc(t("poolNewOff"))} ${esc(t("poolRelaunch"))}</div>` : `
    <div class="row" style="justify-content:flex-end;margin-top:12px">
      <button class="ghost" data-action="poolClose">${t("cancel")}</button>
      <button class="btn" data-action="poolApply" ${S.busy["pool-apply"] ? "disabled" : ""}>${t("apply")}</button>
    </div>
    <div class="footnote">${esc(t("poolNewOff"))} ${esc(t("poolRelaunch"))}</div>`}
  </div></div>`;
}

// The pool card heads the providers page: one glance at how many of the
// shared OpenAI models are live, one button into the global picker.
function codexPoolCard() {
  const pool = S.pool;
  const models = (pool && pool.models) || [];
  return `
  <div class="card">
    <h2>${t("poolTitle")} ${pool ? `<span class="hint">${esc(fmt(t("poolInPool"), { n: pool.selectedCount, total: models.length }))}</span>` : ""}</h2>
    <div class="row">
      <span class="footnote">${t("poolSubtitle")}</span>
      <span class="spacer"></span>
      <button class="ghost small" data-action="poolOpen">${t("models")}</button>
    </div>
  </div>`;
}

function providersPage() {
  const settings = S.settings || {};
  const models = S.models || [];
  const query = String(S.modelsQuery || "").trim().toLowerCase();
  const filtered = query
    ? models.filter((m) => {
        // Ids and display names are both searchable; the list stays deduped
        // upstream in modelsLoad.
        const haystack = `${m.id || ""} ${m.displayName || m.display_name || ""}`.toLowerCase();
        return haystack.includes(query);
      })
    : models;

  return `
  ${pageHead("codex", t("providers"), t("providersSub"))}
  ${poolPauseBanner()}
  ${codexPoolCard()}
  ${openRouterCard(settings)}
  ${openCodeCard(settings)}
  ${deepInfraCard(settings)}
  ${vercelCard(settings)}
  ${zaiCard(settings)}
  ${claudeCard(settings)}
  ${antigravityCard()}
  ${diagnosticsCard()}

  <div class="card">
    <h2>${t("models")} <span class="hint">${filtered.length} ${t("modelsCount")}</span></h2>
    <div class="row">
      <input type="text" id="models-search" placeholder="${t("modelsSearch")}" value="${esc(S.modelsQuery || "")}" data-action="modelsSearch" data-on="input">
      <button class="ghost small" data-action="modelsLoad">${t("refresh")}</button>
    </div>
    <div style="max-height:420px;overflow:auto;margin-top:10px">
      ${filtered.slice(0, 400).map((m) => {
        const id = String(m.id || "");
        // Antigravity membership wins over the claude- prefix: it serves
        // claude-*/gemini-*/gpt-oss ids, so prefix alone would mislabel them.
        const provider = S.antigravityIds && S.antigravityIds.has(id)
          ? "Antigravity"
          : id.startsWith("opencode/") ? "OpenCode"
          : id.startsWith("openrouter/") ? "OpenRouter"
          : id.startsWith("deepinfra/") ? "DeepInfra"
          : id.startsWith("vercel/") ? "Vercel"
          : id.startsWith("zai/") ? "Z.ai"
          : id.startsWith("claude-") ? "Claude" : "OpenAI";
        return `<div class="row" style="padding:3px 0;gap:8px">
          <span class="pill ${provider === "OpenAI" ? "gold" : ""}">${provider}</span>
          <span class="mono" style="font-size:11px">${esc(id)}</span>
        </div>`;
      }).join("") || `<div class="footnote">${t("noCalls")}</div>`}
    </div>
  </div>
  ${poolModal()}`;
}

function donatePage() {
  const address = "TXtXMdkwKt2Nnxwo7ST9h4otFp3WYWjpfw";
  return `
  ${pageHead("melon tools", t("donate"), t("donateSub"))}
  <div class="card">
    <h2>USDT · TRC20</h2>
    <div class="row" style="align-items:flex-start;gap:24px">
      <canvas id="donate-qr" width="220" height="220" style="background:#fff;border-radius:12px;padding:8px"></canvas>
      <div class="stack">
        <table class="kv">
          <tr><td>${t("donateAddress")}</td><td>${esc(address)} <button class="ghost small" data-action="copy" data-text='${address}'>${t("copy")}</button></td></tr>
        </table>
        <div class="footnote">${t("donateScan")}</div>
        <div class="footnote">${t("donateNote")}</div>
      </div>
    </div>
  </div>`;
}

function renderDonateQr() {
  const canvas = document.getElementById("donate-qr");
  if (!canvas || typeof qrcode === "undefined") return;
  const address = "TXtXMdkwKt2Nnxwo7ST9h4otFp3WYWjpfw";
  const qr = qrcode(0, "M");
  qr.addData(address);
  qr.make();
  const count = qr.getModuleCount();
  const size = canvas.width / count;
  const context = canvas.getContext("2d");
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = "#1A1A1C";
  for (let row = 0; row < count; row++) {
    for (let col = 0; col < count; col++) {
      if (qr.isDark(row, col)) {
        context.fillRect(col * size, row * size, Math.ceil(size), Math.ceil(size));
      }
    }
  }
}

function settingsPage() {
  const settings = S.settings || {};
  const info = S.info || {};
  const proxyUrlDraft = S.proxyUrlDraft !== null && S.proxyUrlDraft !== undefined
    ? String(S.proxyUrlDraft)
    : String(settings.proxyUrl || "");
  const proxyUrlDirty = proxyUrlDraft.trim() !== String(settings.proxyUrl || "").trim();
  return `
  ${pageHead("melon tools", t("settings"), t("settingsSub"))}
  <div class="card">
    <h2>${t("general")}</h2>
    <div class="stack">
      <div class="row">
        <label class="field">${t("language")}
          <select id="set-lang">
            <option value="ru" ${S.lang === "ru" ? "selected" : ""}>Русский</option>
            <option value="en" ${S.lang === "en" ? "selected" : ""}>English</option>
          </select>
        </label>
        <label class="field">${t("port")}
          <input class="small" type="number" id="set-port" value="${settings.port ?? 18317}" min="1024" max="65535">
        </label>
        <label class="field">${t("quotaInterval")}
          <input class="small" type="number" id="set-interval" value="${settings.quotaInterval ?? 300}" min="60" step="60">
        </label>
      </div>
      <div class="row">
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" ${S.autostart ? "checked" : ""} data-action="autostartToggle" data-on="change">
          <span>${t("autostart")}</span>
        </label>
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" ${settings.notifications !== false ? "checked" : ""} data-action="notifyToggle" data-on="change">
          <span>${t("notifications")}</span>
        </label>
      </div>
      <div class="row">
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" ${settings.notifyLowQuota !== false ? "checked" : ""} data-action="notifyDetailToggle" data-id="notifyLowQuota" data-on="change">
          <span>${t("notifyLowQuota")}</span>
        </label>
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" ${settings.notifyScheduler !== false ? "checked" : ""} data-action="notifyDetailToggle" data-id="notifyScheduler" data-on="change">
          <span>${t("notifyScheduler")}</span>
        </label>
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" ${settings.notifyQuotaReset !== false ? "checked" : ""} data-action="notifyDetailToggle" data-id="notifyQuotaReset" data-on="change">
          <span>${t("notifyQuotaReset")}</span>
        </label>
      </div>
      <div class="footnote" style="margin-top:0">${t("notificationsHint")}</div>
      <div class="row">
        <button class="btn small" data-action="applySettings">${t("apply")}</button>
        <span class="footnote">${t("autoRefresh")}</span>
      </div>
    </div>
  </div>

  <div class="card">
    <h2>${t("networkProxy")}</h2>
    <div class="stack">
      <label class="field" style="flex-direction:row;align-items:center;gap:6px">
        <input type="checkbox" id="set-proxy-enabled" ${settings.proxyEnabled ? "checked" : ""}>
        <span>${t("useProxy")}</span>
      </label>
      <div class="row" style="align-items:flex-end">
        <label class="field" style="flex:1">${t("proxyUrl")}
          <input id="set-proxy-url" class="mono" placeholder="socks5h://127.0.0.1:1080" value="${esc(proxyUrlDraft)}" data-action="proxyUrlChanged" data-on="input">
        </label>
        <button class="proxy-save" id="proxy-save" data-action="saveProxyUrl" title="${t("saveProxyUrl")}" aria-label="${t("saveProxyUrl")}" ${proxyUrlDirty ? "" : "hidden"}>✓</button>
        <label class="field" style="flex:1">${t("proxyBypass")}
          <input id="set-proxy-bypass" class="mono" value="${esc(settings.proxyBypass || "127.0.0.1,localhost")}">
        </label>
      </div>
      <div class="footnote" style="margin-top:0">${t("proxyHint")}</div>
    </div>
  </div>

  <div class="card">
    <h2>${t("qosCard")}</h2>
    <div class="stack">
      <label class="field">${t("firstTokenTimeout")}
        <input class="small" type="number" id="set-stream-timeout" min="0" max="300" step="15" value="${settings.streamBootstrapTimeoutSeconds ?? 60}">
      </label>
      <div class="footnote" style="margin-top:0">${t("qosHint")}</div>
    </div>
  </div>

  ${dashboardCardToggles(settings)}

  <div class="card">
    <h2>${t("backupCard")}</h2>
    <div class="stack">
      <div class="footnote" style="margin-top:0">${t("backupCardSub")}</div>
      <div class="row" style="align-items:flex-end">
        <label class="field">${t("backupPassword")}
          <input type="password" id="backup-password" autocomplete="new-password">
        </label>
        <button class="btn small" data-action="backupExport">${t("backupExport")}</button>
        <button class="btn small" data-action="backupImportPick">${t("backupImport")}</button>
        <input type="file" id="backup-file" accept=".melon,.json,application/json" hidden data-action="backupImportFile" data-on="change">
      </div>
      <div class="footnote">${t("backupLast")}: ${S.backupLast ? esc(new Date(S.backupLast * 1000).toLocaleString()) : esc(t("backupNone"))}</div>
    </div>
  </div>

  <div class="card">
    <h2>${t("about")}</h2>
    <table class="kv">
      <tr><td>${t("version")}</td><td>${esc(info.version || "—")}</td></tr>
      <tr><td>${t("platform")}</td><td>${esc(info.platform || "—")}</td></tr>
      <tr><td>${t("dataDir")}</td><td>${esc(info.dataDir || "—")}</td></tr>
      <tr><td>${t("codexHome")}</td><td>${esc(info.codexHome || "—")}</td></tr>
    </table>
  </div>`;
}

function composerPage() {
  const bridge = S.bridge;
  const attached = bridge && bridge.attached;
  return `
  ${pageHead("codex", t("composer"), t("composerHint"))}
  <div class="card">
    <h2>${t("bridge")}</h2>
    <div class="stack">
      <div class="row">
        ${attached
          ? `<span class="pill ok">${t("bridgeOn")}</span>
             <span class="pill">${t("port")}: ${esc(bridge.debugPort ?? "—")}</span>
             ${bridge.model ? `<span class="pill gold">${esc(bridge.model)}</span>` : ""}`
          : `<span class="pill warn">${t("bridgeOff")}</span>
             <span class="footnote">${t("bridgeHint")}${bridge && bridge.reason ? " · " + esc(bridge.reason) : ""}</span>`}
      </div>
      <div class="row">
        <button class="ghost small" data-action="bridgeLaunchCodex" ${S.busy.launch ? "disabled" : ""}>${t("bridgeRestart")}</button>
        <button class="ghost small" data-action="refreshStatus">${t("refresh")}</button>
      </div>
      <table class="kv">
        <tr><td>${t("session")}</td><td>${esc(bridge && bridge.threadId ? bridge.threadId : "—")}</td></tr>
        <tr><td>${t("api")}</td><td>${t("composerHint")}</td></tr>
      </table>
    </div>
  </div>`;
}

function instancesPage() {
  const instances = S.instancesData || [];
  const accounts = S.accounts || [];
  return `
  ${pageHead("codex", t("instances"), t("instanceHint"))}
  <div class="card">
    <div class="row">
      <input type="text" id="instance-name" placeholder="${t("instanceNew")}">
      <button class="btn small" data-action="instanceCreate">${t("instanceCreate")}</button>
      <span class="footnote">${t("instanceHint")}</span>
    </div>
  </div>
  <div class="accounts">
    ${instances.map((instance) => `
      <div class="card">
        <div class="account-head">
          <span class="email">${esc(instance.name)}</span>
          <span class="pill ${instance.exists ? "ok" : "warn"}">${instance.exists ? t("found") : t("missing")}</span>
        </div>
        <div class="stack">
          <div class="footnote mono">${esc(instance.homePath || "")}</div>
          <div class="row">
            <label class="field">${t("instanceBind")}
              <select data-action="instanceBind" data-id="${esc(instance.id)}" data-on="change">
                <option value="">${t("instanceNone")}</option>
                ${accounts.map((a) => `<option value="${esc(a.id)}" ${instance.accountId === a.id ? "selected" : ""}>${esc(a.email || a.displayName)}</option>`).join("")}
              </select>
            </label>
            <button class="btn small" data-action="instanceLaunch" data-id="${esc(instance.id)}">${t("instanceLaunch")}</button>
            <span class="spacer"></span>
            <button class="ghost small danger" data-action="instanceDelete" data-id="${esc(instance.id)}">${t("instanceDelete")}</button>
          </div>
        </div>
      </div>`).join("") || `<div class="card"><div class="muted">${t("noCalls")}</div></div>`}
  </div>`;
}

// Scheduled tasks: result bodies are capped server-side (64 KiB); the viewer
// caps again so a huge answer cannot stall the DOM.
const RESULT_VIEW_CAP = 20000;

function boundedText(text) {
  const value = String(text || "");
  return value.length > RESULT_VIEW_CAP ? `${value.slice(0, RESULT_VIEW_CAP)}\n…` : value;
}

function schedulerNextText(unixTs) {
  if (!unixTs) return "—";
  const secs = unixTs - nowRef();
  if (secs <= 0) return t("schedulerDue");
  const mins = Math.ceil(secs / 60);
  if (mins < 60) return fmt(t("schedulerMinutesShort"), { n: mins });
  const hours = Math.floor(mins / 60);
  return `${hours} ${unit("h", "ч")} ${mins % 60} ${unit("min", "мин")}`;
}

function schedulerGroupLabel(id) {
  switch (id) {
    case "claude": return t("sgClaude");
    case "opencode": return t("sgOpenCode");
    case "openrouter": return t("sgOpenRouter");
    case "deepinfra": return t("sgDeepInfra");
    case "vercel": return t("sgVercel");
    case "zai": return t("sgZai");
    default: return t("sgGateway");
  }
}

// MARK: - Scheduler queue (live running/queued state)

const SCHEDULER_QUEUE_MS = 2500;
let queuePollTimer = null;
let queuePollBusy = false;

function schedulerQueuedIds(queue) {
  const source = queue === undefined ? S.queue : queue;
  return source && Array.isArray(source.queued) ? source.queued : [];
}

// A snapshot is "busy" while a run is active or requests wait. The `cancelling`
// flag alone is not: the backend keeps it set until the next run starts.
function schedulerQueueActive(queue) {
  if (!queue || typeof queue !== "object") return false;
  return !!queue.running || schedulerQueuedIds(queue).length > 0;
}

function schedulerIsQueued(id) {
  return schedulerQueuedIds().indexOf(id) >= 0;
}

function schedulerTaskName(data, id) {
  const task = ((data && data.tasks) || []).find((item) => item.id === id);
  return (task && task.name) || id;
}

// Compact running/queued strip above the task list, with "Cancel current".
function schedulerQueueBar() {
  const queue = S.queue;
  if (!schedulerQueueActive(queue)) return "";
  const running = queue.running || null;
  const queued = schedulerQueuedIds(queue);
  const cancelling = !!queue.cancelling && !!running;
  return `<div class="card" id="scheduler-queue">
    <div class="row">
      ${running
        ? `<span class="pill gold">${t("schedulerRunning")}</span>
           <span class="muted">${esc(schedulerTaskName(S.schedulerSummary || S.scheduler, running))}</span>`
        : ""}
      ${queued.length ? `<span class="pill">${fmt(t("schedulerQueuedCount"), { n: queued.length })}</span>` : ""}
      <span class="spacer"></span>
      ${cancelling
        ? `<span class="footnote" style="margin:0">${t("schedulerCancelling")}</span>`
        : `<button class="ghost small danger" data-action="schedulerCancel" ${S.busy["sched-cancel"] ? "disabled" : ""}>${t("schedulerCancelCurrent")}</button>`}
    </div>
  </div>`;
}

// Quiet list reload: used when a watched batch ends, so the cards pick up the
// new status/result without a toast or a spinner.
async function schedulerListQuiet() {
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
    S.schedulerError = null;
  } catch (error) {
    S.schedulerError = errorText(error);
  }
  if (S.section === "scheduler") render();
}

async function schedulerQueuePoll() {
  if (queuePollBusy) return;
  queuePollBusy = true;
  let queue = null;
  try {
    queue = await inv("scheduler_queue");
  } catch (error) {
    // Transient read failure: the last snapshot stays on screen.
    queue = null;
  } finally {
    queuePollBusy = false;
  }
  if (!queue || typeof queue !== "object") return;
  // The page owns the snapshot: a late answer after leaving must not leave a
  // stale "running" marker behind.
  if (S.section !== "scheduler") return;
  const wasActive = schedulerQueueActive(S.queue);
  S.queue = queue;
  // The batch ended: reload the list so the rows show the fresh statuses.
  if (wasActive && !schedulerQueueActive(queue)) {
    schedulerListQuiet();
    return;
  }
  render();
}

// Polling runs only while the scheduler page is on screen. render() is the
// single place the section changes, so it starts and stops the timer.
function schedulerQueueSync() {
  if (S.section !== "scheduler") {
    if (queuePollTimer) {
      clearInterval(queuePollTimer);
      queuePollTimer = null;
    }
    // Off the page the snapshot cannot be kept fresh, and a stale
    // "running" pill on the dashboard would be a lie.
    S.queue = null;
    return;
  }
  if (queuePollTimer) return;
  schedulerQueuePoll();
  queuePollTimer = setInterval(() => {
    if (S.section !== "scheduler") {
      clearInterval(queuePollTimer);
      queuePollTimer = null;
      return;
    }
    schedulerQueuePoll();
  }, SCHEDULER_QUEUE_MS);
}

function schedulerStatusPill(task) {
  const id = task && task.id;
  // Live state first: `scheduler_queue` reports the active run and the
  // waiting requests before the persisted `lastStatus` does.
  if (id && S.queue) {
    if (S.queue.running === id) return `<span class="pill gold">${t("schedulerRunning")}</span>`;
    if (schedulerIsQueued(id)) return `<span class="pill">${t("schedulerQueued")}</span>`;
  }
  switch ((task && task.lastStatus) || "") {
    case "running": return `<span class="pill gold">${t("schedulerRunning")}</span>`;
    case "ok": return `<span class="pill ok">${t("schedulerOk")}</span>`;
    case "error": return `<span class="pill danger">${t("schedulerError")}</span>`;
    case "cancelled": return `<span class="pill warn">${t("schedulerCancelled")}</span>`;
    case "skipped": return `<span class="pill">${t("schedulerSkipped")}</span>`;
    default: return `<span class="pill">${t("schedulerNever")}</span>`;
  }
}

// Built-in task templates. The prompt keeps `{{variable}}` placeholders until
// the user fills the fields and saves; the backend never sees the placeholders.
const SCHEDULER_TEMPLATES = [
  {
    id: "morning-digest", nameKey: "schedulerTplMorning", descKey: "schedulerTplMorningDesc",
    prompt: "Give me a short morning digest for {{repo}} on branch {{branch}}.\nSummarize the latest commits, open work and anything that needs attention today.\nKeep it under 200 words.",
    variables: ["repo", "branch"], scheduleKind: "cron", cronExpression: "0 9 * * 1-5", intervalMinutes: 60,
  },
  {
    id: "pr-review", nameKey: "schedulerTplPR", descKey: "schedulerTplPRDesc",
    prompt: "Review the open pull requests in {{repo}} for branch {{branch}}.\nList failing checks, unresolved comments and the riskiest changes with file paths.\nFinish with the top three issues to fix first.",
    variables: ["repo", "branch"], scheduleKind: "cron", cronExpression: "0 18 * * 1-5", intervalMinutes: 60,
  },
  {
    id: "weekly-repo-summary", nameKey: "schedulerTplWeekly", descKey: "schedulerTplWeeklyDesc",
    prompt: "Write a weekly summary for {{repo}} at {{path}}.\nCover merged changes, active branches, open risks and the next steps.\nUse no more than 250 words.",
    variables: ["repo", "path"], scheduleKind: "cron", cronExpression: "0 10 * * 1", intervalMinutes: 60,
  },
  {
    id: "log-check", nameKey: "schedulerTplLogs", descKey: "schedulerTplLogsDesc",
    prompt: "Check the recent logs under {{path}} for errors and warnings.\nGroup the findings by severity, point to the likely cause and suggest a fix.\nIf everything is clean, say so in one line.",
    variables: ["path"], scheduleKind: "cron", cronExpression: "0 */6 * * *", intervalMinutes: 360,
  },
  {
    id: "daily-spend", nameKey: "schedulerTplSpend", descKey: "schedulerTplSpendDesc",
    prompt: "Review today's model spend for {{repo}}.\nSummarize token usage, the most expensive models and any unusual spikes.\nFinish with one short recommendation.",
    variables: ["repo"], scheduleKind: "cron", cronExpression: "0 21 * * *", intervalMinutes: 1440,
  },
];

function schedulerTemplate(id) {
  return SCHEDULER_TEMPLATES.find((item) => item.id === id) || null;
}

function schedulerVariableLabel(variable) {
  if (variable === "repo") return t("schedulerRepo");
  if (variable === "branch") return t("schedulerBranch");
  if (variable === "path") return t("schedulerPath");
  return variable;
}

function schedulerSystemZone() {
  const offset = -new Date().getTimezoneOffset();
  const sign = offset >= 0 ? "+" : "-";
  const abs = Math.abs(offset);
  return `System (${sign}${String(Math.floor(abs / 60)).padStart(2, "0")}:${String(abs % 60).padStart(2, "0")})`;
}

function schedulerZoneOptions(selected) {
  const zones = ["", "UTC", "+03:00", "+02:00", "+01:00", "-05:00", "-08:00", "+05:30", "+08:00", "+10:00"];
  return zones.map((value) => {
    const label = value === "" ? schedulerSystemZone() : value;
    return `<option value="${esc(value)}" ${value === (selected || "") ? "selected" : ""}>${esc(label)}</option>`;
  }).join("");
}

function schedulerPage() {
  const data = S.scheduler;
  const tasks = (data && data.tasks) || [];
  const path = (data && data.path) || "";
  const head = pageHead("melon tools", t("scheduler"), t("schedulerSub"));
  // Tasks run through the local gateway: a stopped service makes every task
  // fail, so say it before the list instead of after a failed run.
  const stopped = S.status && S.status.running === false;
  const banner = stopped
    ? `<div class="card"><div class="row"><span class="pill warn">${t("gateway")}</span>
        <span class="muted">${t("schedulerGatewayOff")}</span></div></div>`
    : "";

  if (S.schedulerError) {
    return `${head}
      <div class="card">
        <div class="row"><span class="pill danger">${t("error")}</span>
          <span class="mono" style="font-size:11px">${esc(S.schedulerError)}</span></div>
        <div class="footnote">${t("schedulerGatewayOff")}</div>
        <div class="row" style="margin-top:10px">
          <button class="ghost small" data-action="schedulerLoad">${t("refresh")}</button>
        </div>
      </div>
      ${schedulerModal()}`;
  }
  if (!data) {
    return `${head}${banner}<div class="card"><div class="muted">${t("loading")}</div></div>${schedulerModal()}`;
  }
  return `${head}
    ${banner}
    ${schedulerQueueBar()}
    <div class="footnote" style="margin-top:0">${t("schedulerTrayHint")}</div>
    <div class="row">
      <button class="btn small" data-action="schedulerEdit">${t("schedulerAdd")}</button>
      <button class="ghost small" data-action="schedulerLoad">${t("refresh")}</button>
      <span class="spacer"></span>
      ${path ? `<span class="footnote mono" style="margin:0">${esc(path)}</span>` : ""}
    </div>
    ${tasks.length
      ? `<div class="accounts">${tasks.map((task) => schedulerCard(task, data)).join("")}</div>`
      : `<div class="card"><div class="muted">${t("schedulerEmpty")}</div></div>`}
    ${schedulerHistoryCard(data)}
    ${schedulerModal()}`;
}

function schedulerCard(task, data) {
  const open = S.schedulerOpen === task.id;
  return `<div class="card">
    <div class="account-head">
      <span class="email">${esc(task.name)}</span>
      ${schedulerStatusPill(task)}
      <span class="spacer"></span>
      <label class="row" style="gap:6px;font-size:11px;color:var(--text2)">
        <input type="checkbox" ${task.enabled ? "checked" : ""} data-action="schedulerToggle" data-id="${esc(task.id)}" data-on="change">
        <span>${t("schedulerEnabled")}</span>
      </label>
    </div>
    <div class="task-meta">
      <span>${t("schedulerModel")}: <span class="val">${esc(task.model || "—")}</span></span>
      ${task.reasoningEffort ? `<span class="pill gold">${esc(task.reasoningEffort)}</span>` : ""}
      <span>${task.scheduleKind === "cron"
        ? `${t("schedulerScheduleCron")}: <span class="mono">${esc(task.cronExpression || "—")}</span>`
        : fmt(t("schedulerEvery"), { n: task.intervalMinutes || 0 })}</span>
      ${task.timeZone ? `<span>${t("schedulerTimeZone")}: <span class="mono">${esc(task.timeZone)}</span></span>` : ""}
      <span>${t("schedulerNext")}: <span class="val">${task.enabled ? esc(schedulerNextText(task.nextRunAt)) : "—"}</span></span>
      <span>${t("schedulerLast")}: <span class="val">${task.lastRunAt ? esc(ageText(task.lastRunAt)) : t("never")}</span></span>
      ${task.lastDurationMs != null ? `<span>${t("schedulerDuration")}: ${Math.round(task.lastDurationMs / 100) / 10} ${unit("s", "с")}</span>` : ""}
      ${task.lastTokens != null ? `<span>${t("schedulerTokens")}: ${task.lastTokens}</span>` : ""}
      <span>${t("schedulerDailyLimit")}: <span class="val">${(task.dailyTokenLimit || 0) > 0 ? Number(task.dailyTokenLimit) : esc(t("schedulerDailyLimitNone"))}</span></span>
    </div>
    ${task.lastError ? `<div class="footnote mono" style="color:var(--danger);white-space:pre-wrap;max-height:140px;overflow:auto">${esc(boundedText(task.lastError))}</div>` : ""}
    <div class="row" style="margin-top:12px">
      <button class="ghost small" data-action="schedulerRunNow" data-id="${esc(task.id)}" ${S.busy["sched-run-" + task.id] || schedulerIsQueued(task.id) ? "disabled" : ""}>${t("schedulerRunNow")}</button>
      <button class="ghost small" data-action="schedulerEdit" data-id="${esc(task.id)}">${t("schedulerEdit")}</button>
      <button class="ghost small" data-action="schedulerToggleResult" data-id="${esc(task.id)}">${open ? t("schedulerClose") : t("schedulerResult")}</button>
      <span class="spacer"></span>
      <button class="ghost small danger" data-action="schedulerDelete" data-id="${esc(task.id)}">${t("schedulerDelete")}</button>
    </div>
    ${open ? schedulerDetails(task, data) : ""}
  </div>`;
}

function schedulerDetails(task, data) {
  const history = (data.history || [])
    .filter((entry) => entry.taskId === task.id)
    .slice(0, 20);
  const latest = history[0];
  const latestResult = latest ? (S.schedulerResults || {})[latest.id] : null;
  const resultText = latestResult
    ? (latestResult.result || latestResult.error || "")
    : (latest && latest.result ? latest.result : "");
  return `<div class="result-view">${esc(boundedText(resultText || t("schedulerNoResult")))}</div>
    ${latest && !latestResult && !latest.result
      ? `<div class="row" style="margin-top:8px"><button class="ghost small" data-action="schedulerResultLoad" data-id="${esc(latest.id)}">${t("schedulerResult")}</button></div>`
      : ""}
    ${history.length
      ? `<div class="footnote" style="margin-top:10px">${t("schedulerHistory")}</div>
        ${history.map((entry) => {
          const cached = (S.schedulerResults || {})[entry.id] || (entry.result !== undefined ? entry : null);
          return `<div class="footnote mono" style="margin-top:2px">
          ${esc(new Date(entry.at * 1000).toLocaleString())} · ${esc(entry.status)}${entry.tokens != null ? ` · ${entry.tokens} ${t("schedulerTokens")}` : ""}
          ${cached
            ? ` · ${esc(boundedText(String(cached.result || cached.error || "")).slice(0, 240))}`
            : ` · <button class="ghost small" data-action="schedulerResultLoad" data-id="${esc(entry.id)}">${t("schedulerResult")}</button>`}
        </div>`;
        }).join("")}`
      : ""}`;
}

function schedulerHistoryCard(data) {
  const history = (data && data.history) || [];
  if (!history.length) return "";
  const tasks = (data && data.tasks) || [];
  const name = (id) => {
    const task = tasks.find((item) => item.id === id);
    return task ? task.name : id;
  };
  return `<div class="card">
    <h2>${t("schedulerHistory")} <span class="hint">${history.length}${S.schedulerHistoryMore ? "+" : ""}</span></h2>
    <div class="stack">
      ${history.slice(0, 50).map((entry) => {
        const cached = (S.schedulerResults || {})[entry.id] || (entry.result !== undefined ? entry : null);
        return `<div class="row" style="align-items:flex-start;gap:8px">
          <span class="mono footnote" style="min-width:150px">${esc(new Date(entry.at * 1000).toLocaleString())}</span>
          <span class="pill ${entry.status === "ok" ? "ok" : entry.status === "error" ? "danger" : ""}">${esc(entry.status)}</span>
          <span class="muted">${esc(name(entry.taskId))}</span>
          ${entry.tokens != null ? `<span class="pill">${entry.tokens} ${t("schedulerTokens")}</span>` : ""}
          <span class="spacer"></span>
          ${cached
            ? `<span class="mono footnote" style="max-width:45%;white-space:pre-wrap">${esc(boundedText(String(cached.result || cached.error || "")).slice(0, 240))}</span>`
            : `<button class="ghost small" data-action="schedulerResultLoad" data-id="${esc(entry.id)}">${t("schedulerResult")}</button>`}
        </div>`;
      }).join("")}
      ${S.schedulerHistoryMore
        ? `<div class="row"><button class="ghost small" data-action="schedulerHistoryMore">${t("schedulerHistoryMore")}</button></div>`
        : ""}
    </div>
  </div>`;
}

function schedulerModal() {
  const form = S.schedulerForm;
  if (!form) return "";
  const selected = form.model || "";
  const covered = new Set();
  const groups = (S.schedulerModels && S.schedulerModels.groups) || [];
  const options = groups.map((group) => `<optgroup label="${esc(schedulerGroupLabel(group.id))}">${(group.ids || [])
    .map((id) => {
      covered.add(id);
      return `<option value="${esc(id)}" ${id === selected ? "selected" : ""}>${esc(id)}</option>`;
    })
    .join("")}</optgroup>`);
  // A saved model missing from the current gateway list must stay selectable:
  // the gateway may be stopped or the pool may have changed since the save.
  if (selected && !covered.has(selected)) {
    options.push(`<optgroup label="${esc(t("schedulerModel"))}"><option value="${esc(selected)}" selected>${esc(selected)}</option></optgroup>`);
  }
  return `<div class="modal" id="scheduler-modal"><div class="modal-card">
    <h2>${form.id ? t("schedulerEditTitle") : t("schedulerAddTitle")}</h2>
    <div class="stack">
      ${!form.id ? `<label class="field">${t("schedulerTemplate")}<select id="sched-template" data-action="schedulerTemplateApply" data-on="change">
        <option value="">${t("schedulerTemplateNone")}</option>
        ${SCHEDULER_TEMPLATES.map((item) => `<option value="${esc(item.id)}" ${form.templateId === item.id ? "selected" : ""}>${esc(t(item.nameKey))}</option>`).join("")}
      </select></label>` : ""}
      <label class="field">${t("schedulerName")}<input type="text" id="sched-name" value="${esc(form.name || "")}"></label>
      ${form.templateId && form.variables ? `<div class="row" style="align-items:flex-end">${Object.keys(form.variables).map((variable) => `
        <label class="field">${esc(schedulerVariableLabel(variable))}<input type="text" id="sched-var-${esc(variable)}" value="${esc(form.variables[variable] || "")}" data-action="schedulerVarInput" data-id="${esc(variable)}" data-on="input"></label>`).join("")}</div>
        <div class="footnote" style="margin-top:0">${t("schedulerVariables")}: ${Object.keys(form.variables).map((variable) => `{{${esc(variable)}}}`).join(" · ")}</div>` : ""}
      <label class="field">${t("schedulerPrompt")}<textarea id="sched-prompt">${esc(form.prompt || "")}</textarea></label>
      <label class="field">${t("schedulerWorkingDirectory")}<input type="text" id="sched-workdir" class="mono" value="${esc(form.workingDirectory || "")}" placeholder="C:\\Projects\\repo"></label>
      <label class="field" style="flex-direction:row;align-items:center;gap:6px">
        <input type="checkbox" id="sched-git-context" ${form.includeGitContext ? "checked" : ""}>
        <span>${t("schedulerGitContext")}</span>
      </label>
      <div class="row">
        <label class="field">${t("schedulerMaxTokens")}<input class="small" type="number" id="sched-max-tokens" min="0" max="32768" value="${form.maxTokens || 0}"></label>
        <label class="field">${t("schedulerRetries")}<input class="small" type="number" id="sched-retries" min="0" max="10" value="${form.retryLimit || 0}"></label>
        <label class="field">${t("schedulerRetryDelay")}<input class="small" type="number" id="sched-retry-delay" min="1" max="1440" value="${form.retryDelayMinutes || 5}"></label>
        <label class="field">${t("schedulerDailyTokenLimit")}<input class="small" type="number" id="sched-daily-limit" min="0" max="1000000" step="1" value="${form.dailyTokenLimit || 0}"></label>
      </div>
      <label class="field">${t("schedulerModel")}<select id="sched-model">${options.join("") || `<option value="">${t("schedulerModelsFailed")}</option>`}</select></label>
      <label class="field">${t("schedulerEffort")}<select id="sched-effort">
        <option value="" ${!form.reasoningEffort ? "selected" : ""}>${t("schedulerEffortDefault")}</option>
        ${["low", "medium", "high", "xhigh", "max"].map((value) => `<option value="${value}" ${form.reasoningEffort === value ? "selected" : ""}>${value}</option>`).join("")}
      </select></label>
      <label class="field">${t("schedulerScheduleType")}<select id="sched-schedule-kind" data-action="schedulerKindChanged" data-on="change">
        <option value="interval" ${(form.scheduleKind || "interval") === "interval" ? "selected" : ""}>${t("schedulerScheduleInterval")}</option>
        <option value="cron" ${form.scheduleKind === "cron" ? "selected" : ""}>${t("schedulerScheduleCron")}</option>
      </select></label>
      <div id="sched-interval-row" style="${(form.scheduleKind || "interval") === "cron" ? "display:none" : ""}">
        <label class="field">${t("schedulerInterval")}<input class="small" type="number" id="sched-interval" min="1" step="1" value="${form.intervalMinutes || 60}"></label>
      </div>
      <div id="sched-cron-row" style="${form.scheduleKind === "cron" ? "" : "display:none"}">
        <label class="field">${t("schedulerCron")}<input type="text" id="sched-cron" class="mono" value="${esc(form.cronExpression || "")}" placeholder="0 9 * * 1-5"></label>
        <div class="footnote" style="margin-top:0">${t("schedulerCronHint")} · ${t("schedulerCronExamples")}</div>
      </div>
      <label class="field">${t("schedulerTimeZone")}<select id="sched-timezone">${schedulerZoneOptions(form.timeZone || "")}</select></label>
      <label class="field" style="flex-direction:row;align-items:center;gap:6px">
        <input type="checkbox" id="sched-enabled" ${form.enabled !== false ? "checked" : ""}><span>${t("schedulerEnabled")}</span>
      </label>
      <div class="footnote" style="margin-top:0">${t("schedulerTrayHint")}</div>
      <div class="footnote" style="margin-top:0">${S.schedulerModelsError ? esc(S.schedulerModelsError) : t("schedulerModelHint")}</div>
      <div class="row" style="justify-content:flex-end">
        <button class="ghost" data-action="schedulerFormClose">${t("cancel")}</button>
        <button class="btn" data-action="schedulerFormSave" ${S.busy["sched-save"] ? "disabled" : ""}>${t("save")}</button>
      </div>
    </div>
  </div></div>`;
}

// MARK: - Refresh guard (M3)

const FORM_TAGS = ["INPUT", "TEXTAREA", "SELECT"];

