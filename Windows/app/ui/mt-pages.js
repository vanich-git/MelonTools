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
  ${cards.antigravity ? dashboardAntigravityCard(S.antigravity) : ""}
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
  const error = S.providerModelsError.opencode;
  return `
  <div class="card provider-card">
    <h2>${t("opencode")} ${providerKeyPill(configured)}</h2>
    <div class="stat-grid">
      ${providerMetric(t("modelsAvailable"), providerModelCount("opencode"))}
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
        <button class="ghost small" data-action="loadProviderModels" data-id="opencode" ${S.busy["models-opencode"] ? "disabled" : ""}>${t("loadModels")}</button>
      </div>
      ${error ? `<div class="footnote mono">${esc(error)}</div>` : ""}
      <div class="footnote">${t("ocHint")}</div>
    </div>
  </div>`;
}

function commandCodeCard(settings) {
  const configured = !!(settings.commandcodeKey || "").trim();
  const error = S.providerModelsError.commandcode;
  const rows = Array.isArray(settings.commandcodeModels) ? settings.commandcodeModels : [];
  const anthropic = rows.filter((row) => row && row.anthropicOnly === true).length;
  return `
  <div class="card provider-card">
    <h2>${t("commandcode")} ${providerKeyPill(configured)}</h2>
    <div class="stat-grid">
      ${providerMetric(t("modelsAvailable"), providerModelCount("commandcode"))}
      ${providerMetric(t("ccAnthropicModels"), rows.length ? anthropic : "—")}
      ${providerMetric(t("sessionSpend"), formatMoney(sessionProviderSpend("commandcode")))}
    </div>
    <div class="stack" style="margin-top:12px">
      <label class="field">${t("ccKey")}
        <input type="password" id="cc-key" value="${esc(settings.commandcodeKey || "")}" placeholder="cmd_…">
      </label>
      <div class="row">
        <label class="field" style="flex-direction:row;align-items:center;gap:6px">
          <input type="checkbox" id="cc-enabled" ${settings.commandcodeEnabled ? "checked" : ""} data-action="providerToggleChanged" data-on="change">
          <span>${t("sourceEnabled")}</span>
        </label>
        <span class="spacer"></span>
        <button class="btn small" data-action="saveKeys">${t("save")}</button>
        <button class="ghost small" data-action="loadProviderModels" data-id="commandcode" ${S.busy["models-commandcode"] ? "disabled" : ""}>${t("loadModels")}</button>
      </div>
      ${error ? `<div class="footnote mono">${esc(error)}</div>` : ""}
      <div class="footnote">${t("ccHint")}</div>
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
  ${commandCodeCard(settings)}
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
          : id.startsWith("commandcode/") ? "CommandCode"
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
    case "commandcode": return t("sgCommandCode");
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

// MARK: - Local AI (GGUF / llama-server)

function localAiEngineBadge() {
  const rt = S.localAi.runtime;
  if (!rt) {
    return `<span class="pill">${t("localAiStatusStopped")}</span>`;
  }
  if (rt.isRunning) {
    const model = (S.localAi.models || []).find((m) => m.id === rt.modelId);
    const modelName = model ? model.displayName || model.id : rt.modelId || "";
    return `<span class="pill ok"><span class="dot ok"></span> ${t("localAiStatusRunning")}${modelName ? `: ${esc(modelName)}` : ""}</span>`;
  }
  if (rt.isStarting) {
    return `<span class="pill warn"><span class="dot warn"></span> ${t("localAiStatusLoading")}</span>`;
  }
  if (rt.error) {
    return `<span class="pill danger"><span class="dot err"></span> ${t("localAiStatusFailed")}</span>`;
  }
  return `<span class="pill">${t("localAiStatusStopped")}</span>`;
}

function localAiSubtabs() {
  const current = S.localAi.tab || "models";
  const tabs = [
    { id: "models", label: t("localAiModels"), icon: "cpu" },
    { id: "catalog", label: t("localAiCatalog"), icon: "cube" },
    { id: "downloads", label: t("localAiDownloads"), icon: "download", badge: S.localAi.activeDownloadCount || 0 },
    { id: "runtime", label: t("localAiRuntime"), icon: "terminal" },
    { id: "settings", label: t("localAiSettings"), icon: "gear" },
  ];

  return `
  <div class="subtabs-bar">
    <div class="subtabs-list">
      ${tabs.map((tab) => `
        <button class="subtab-btn ${current === tab.id ? "active" : ""}" data-action="localAiTab" data-id="${tab.id}">
          <span>${esc(tab.label)}</span>
          ${tab.badge ? `<span class="badge">${tab.badge}</span>` : ""}
        </button>
      `).join("")}
    </div>
    <div class="subtabs-status">
      ${localAiEngineBadge()}
    </div>
  </div>`;
}

/// True when the running engine was launched with older `userSettings` than
/// the registry now holds. Restarting the model rewrites `models.ini` and
/// clears it; until then the card shows "Restart required".
function localAiPendingChanges(model) {
  const rt = S.localAi.runtime;
  if (!rt || !rt.isRunning || !rt.appliedSettings) return false;
  if (!rt.currentModel || rt.currentModel.id !== model.id) return false;
  return JSON.stringify(rt.appliedSettings) !== JSON.stringify(model.userSettings || {});
}

function localAiRegistryBanner() {
  const health = S.localAi.registry;
  if (!health || !health.readOnly) return "";
  return `
    <div class="card local-ai-registry-error">
      <div class="card-header-row">
        <h3>${esc(t("localAiRegistryError"))}</h3>
        <button class="btn small danger" data-action="localAiRegistryRecover">${esc(t("localAiRegistryRecover"))}</button>
      </div>
      <div class="footnote">${esc(health.error || "")}</div>
      ${health.backupPath ? `<div class="mono hint">${esc(health.backupPath)}</div>` : ""}
    </div>`;
}

// SF-Symbols-style glyphs for the Local AI cards. The shell icon set (ICONS)
// only carries navigation glyphs; these buttons need the Mac vocabulary.
const LOCAL_AI_ICONS = {
  search: '<circle cx="11" cy="11" r="7"/><path d="m16.4 16.4 4.1 4.1"/>',
  drive: '<rect x="3" y="5.5" width="18" height="13" rx="2"/><path d="M3 13.5h18"/>',
  download: '<path d="M12 3v11"/><path d="m8 10.5 4 4 4-4"/><path d="M4 19.5h16"/>',
  play: '<path d="M7 4.6 19 12 7 19.4Z" fill="currentColor" stroke="none"/>',
  stop: '<rect x="6.5" y="6.5" width="11" height="11" rx="1.6" fill="currentColor" stroke="none"/>',
  sparkles: '<path d="M11.5 3.5 13.3 8l4.5 1.8-4.5 1.8-1.8 4.5-1.8-4.5L5.2 9.8 9.7 8Z"/><path d="m18.3 15.4.9 2.2 2.2.9-2.2.9-.9 2.2-.9-2.2-2.2-.9 2.2-.9Z"/>',
  gear: '<circle cx="12" cy="12" r="3.3"/><path d="M19.3 14a7.6 7.6 0 0 0 0-4l2-1.6-2-3.4-2.4 1a7.6 7.6 0 0 0-3.4-2L13.1 2h-2.2l-.4 3.4a7.6 7.6 0 0 0-3.4 2l-2.4-1-2 3.4 2 1.6a7.6 7.6 0 0 0 0 4l-2 1.6 2 3.4 2.4-1a7.6 7.6 0 0 0 3.4 2l.4 3.4h2.2l.4-3.4a7.6 7.6 0 0 0 3.4-2l2.4 1 2-3.4Z"/>',
  ellipsis: '<circle cx="5.4" cy="12" r="1.7" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.7" fill="currentColor" stroke="none"/><circle cx="18.6" cy="12" r="1.7" fill="currentColor" stroke="none"/>',
  copy: '<rect x="9" y="9" width="11.5" height="11.5" rx="2"/><path d="M15 9V6.2A2.2 2.2 0 0 0 12.8 4H6.2A2.2 2.2 0 0 0 4 6.2v6.6A2.2 2.2 0 0 0 6.2 15H9"/>',
  folder: '<path d="M3 6.8A1.8 1.8 0 0 1 4.8 5h4l2 2.4h6.4A1.8 1.8 0 0 1 19 9.2v8A1.8 1.8 0 0 1 17.2 19H4.8A1.8 1.8 0 0 1 3 17.2Z"/>',
  trash: '<path d="M4 7h16"/><path d="M9.5 7V5.4A1.4 1.4 0 0 1 10.9 4h2.2a1.4 1.4 0 0 1 1.4 1.4V7"/><path d="m6.5 7 .9 12.2A1.4 1.4 0 0 0 8.8 20.5h6.4a1.4 1.4 0 0 0 1.4-1.3L17.5 7"/>',
  archive: '<rect x="3.5" y="4.5" width="17" height="4.5" rx="1.2"/><path d="M5.5 9v9.3A1.7 1.7 0 0 0 7.2 20h9.6a1.7 1.7 0 0 0 1.7-1.7V9"/><path d="M10 13h4"/>',
  book: '<path d="M4.5 5.4A2.4 2.4 0 0 1 6.9 3h12.6v14.4H6.9a2.4 2.4 0 0 0-2.4 2.4Z"/><path d="M4.5 19.8a2.4 2.4 0 0 1 2.4-2.4h12.6V21H6.9a2.4 2.4 0 0 1-2.4-1.2Z"/>',
  layers: '<path d="M12 3 3.5 7.6 12 12.2l8.5-4.6L12 3Z"/><path d="m3.5 12.4 8.5 4.6 8.5-4.6"/>',
  cpu: '<rect x="7.5" y="7.5" width="9" height="9" rx="1.4"/><path d="M10 2.5v3M14 2.5v3M10 18.5v3M14 18.5v3M2.5 10h3M2.5 14h3M18.5 10h3M18.5 14h3"/>',
  wrench: '<path d="M16.2 4.2a4.6 4.6 0 0 0-5 6.6L4.6 18.3a1.9 1.9 0 0 0 2.7 2.7l7.5-6.7a4.6 4.6 0 0 0 5.8-5.7l-2.7 2.3-2.6-2.6Z"/>',
  photo: '<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="9" cy="10" r="1.7"/><path d="m4 18.5 5.2-5 3.8 3.6 2.8-2.4L20 18"/>',
  x: '<path d="m6 6 12 12M18 6 6 18"/>',
  cube: '<path d="M12 2.8 20.6 7.4v9.2L12 21.2 3.4 16.6V7.4Z"/><path d="M3.4 7.4 12 12l8.6-4.6"/><path d="M12 12v9.2"/>',
  sidebar: '<rect x="3" y="4.5" width="18" height="15" rx="2"/><path d="M14.5 4.5v15"/>',
  key: '<circle cx="8.2" cy="15.8" r="4.2"/><path d="m11.3 12.7 8.2-8.2"/><path d="m16.4 7.6 2.2 2.2"/><path d="m19 5 1.6 1.6"/>',
  heart: '<path d="M12 20.2s-7.4-4.4-7.4-9.4a4.2 4.2 0 0 1 7.4-2.6 4.2 4.2 0 0 1 7.4 2.6c0 5-7.4 9.4-7.4 9.4Z"/>',
  retry: '<path d="M20.5 12a8.5 8.5 0 1 1-2.6-6.1"/><path d="M20.5 4v5h-5"/>',
  memory: '<rect x="3" y="7" width="18" height="10" rx="2"/><path d="M7 17v3M12 17v3M17 17v3"/><path d="M7 11h.01M12 11h.01M17 11h.01"/>',
  chip: '<rect x="7" y="7" width="10" height="10" rx="2"/><path d="M10 3v4M14 3v4M10 17v4M14 17v4M3 10h4M3 14h4M17 10h4M17 14h4"/>',
  downloadCircle: '<circle cx="12" cy="12" r="9"/><path d="M12 7.5v8"/><path d="m8.6 12.2 3.4 3.4 3.4-3.4"/>',
};

function localAiIcon(name, size) {
  const glyph = LOCAL_AI_ICONS[name] || "";
  const px = size || 13;
  return `<svg class="local-ai-icon" width="${px}" height="${px}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${glyph}</svg>`;
}

/// Metadata chip of the Mac card: glyph plus value, no border.
function localAiBadge(icon, text) {
  return `<span class="meta-badge">${localAiIcon(icon)}${esc(text)}</span>`;
}

function localAiModelsTab() {
  const models = S.localAi.models || [];
  const totalBytes = models.reduce((acc, m) => acc + (m.fileSize || 0), 0);
  // macOS prints this header as `%.1f GB total`, unlike the two-decimal sizes.
  const totalDiskStr = formatBytes(totalBytes, 1);
  const searching = (S.localAi.searchQuery || "").length > 0;

  return `
  <div class="local-ai-content">
    <div class="local-ai-toolbar">
      <div class="search-field">
        ${localAiIcon("search", 13)}
        <input type="text" placeholder="${esc(t("localAiSearchPlaceholder"))}" value="${esc(S.localAi.searchQuery || "")}" data-action="localAiSearch" data-on="input" aria-label="${esc(t("localAiSearchPlaceholder"))}">
        <button class="search-clear" data-action="localAiClearSearch" title="${esc(t("localAiClearSearch"))}" aria-label="${esc(t("localAiClearSearch"))}" ${searching ? "" : "hidden"}>${localAiIcon("x", 12)}</button>
      </div>
      <span class="spacer"></span>
      <span class="meta-label">${localAiIcon("drive", 12)}${esc(fmt(t("localAiTotalDisk"), { size: totalDiskStr }))}</span>
      <button class="btn small" data-action="localAiImport">${localAiIcon("download", 12)}${esc(t("localAiImport"))}</button>
    </div>

    ${localAiRegistryBanner()}

    <div id="local-ai-model-list">${localAiModelListMarkup()}</div>
  </div>`;
}

/// Body of the Модели tab below the toolbar. Kept separate so typing in the
/// search field can repaint just this block: a full render() would tear the
/// focused input out from under the caret on every keystroke.
function localAiModelListMarkup() {
  const models = S.localAi.models || [];
  const q = (S.localAi.searchQuery || "").trim().toLowerCase();
  const filtered = q
    ? models.filter((m) => {
        const name = (m.displayName || m.name || "").toLowerCase();
        const id = (m.id || "").toLowerCase();
        const quant = (m.quantization || "").toLowerCase();
        return name.includes(q) || id.includes(q) || quant.includes(q);
      })
    : models;

  if (filtered.length === 0) {
    return `
      <div class="card empty-state">
        <div class="empty-icon">${localAiIcon("cpu", 44)}</div>
        <h3>${esc(models.length === 0 ? t("localAiNoModels") : t("localAiNoMatches"))}</h3>
        <p class="muted">${esc(models.length === 0 ? t("localAiNoModelsHint") : t("localAiSearchPlaceholder"))}</p>
        <div class="row" style="justify-content:center;margin-top:16px;gap:8px">
          ${models.length === 0
            ? `<button class="btn" data-action="localAiImport">${localAiIcon("download", 12)}${esc(t("localAiImport"))}</button>
               <button class="ghost" data-action="localAiTab" data-id="catalog">${esc(t("localAiBrowseHf"))}</button>`
            : `<button class="ghost" data-action="localAiClearSearch">${esc(t("localAiClearSearch"))}</button>`}
        </div>
      </div>`;
  }
  return `<div class="local-ai-model-list">${filtered.map((m) => localAiModelCard(m)).join("")}</div>`;
}

function localAiModelCard(model) {
  const rt = S.localAi.runtime;
  const isRunningThis = !!(rt && rt.isRunning && rt.currentModel && rt.currentModel.id === model.id);
  // A launch takes up to a minute while the engine maps weights; without this
  // the Start button looked dead for the whole wait.
  const isStartingThis = !!(rt && rt.isStarting && rt.startingModelId === model.id);
  const isBusy = !!(rt && rt.isStarting);
  const startError = (rt && rt.failedModelId === model.id) ? rt.error : null;
  const userSettings = model.userSettings || {};
  const ctx = userSettings.contextLength || 4096;
  const sizeStr = formatBytes(model.fileSize || 0);
  const capabilities = model.capabilities || [];
  const badges = [
    localAiBadge("archive", model.quantization || "GGUF"),
    localAiBadge("drive", sizeStr),
    localAiBadge("book", `${ctx} ctx`),
  ];
  if (model.backend) badges.push(localAiBadge("layers", String(model.backend)));
  if (model.architecture) badges.push(localAiBadge("cpu", model.architecture));
  if (capabilities.includes("tools")) badges.push(localAiBadge("wrench", "Tools"));
  if (capabilities.includes("vision")) badges.push(localAiBadge("photo", "Vision"));

  return `
  <div class="card local-ai-card ${isRunningThis ? "active-model" : isStartingThis ? "starting-model" : ""}">
    <div class="card-header-row">
      <div class="card-title-group">
        <div class="row" style="gap:6px;align-items:center">
          <h3 class="model-name">${esc(model.displayName || model.name || model.id)}</h3>
          ${isRunningThis ? `<span class="pill ok">${esc(t("localAiActive"))}</span>` : ""}
          ${localAiPendingChanges(model) ? `<span class="pill warn">${esc(t("localAiPending"))}</span>` : ""}
        </div>
        <div class="mono hint">${esc(model.id)}</div>
      </div>
      <div class="card-actions">
        ${isStartingThis ? `
          <span class="pill warn"><span class="spinner-dot"></span>${esc(t("localAiStarting"))}</span>
        ` : isRunningThis ? `
          <button class="btn small" data-action="localAiStop" title="${esc(t("localAiStop"))}">
            ${localAiIcon("stop", 11)}${esc(t("localAiStop"))}
          </button>
        ` : `
          <button class="btn small ok-btn" data-action="localAiStart" data-id="${esc(model.id)}" ${isBusy ? "disabled" : ""}>
            ${localAiIcon("play", 11)}${esc(t("localAiStart"))}
          </button>
        `}
        <button class="icon-btn" data-action="localAiTestModal" data-id="${esc(model.id)}" title="${esc(t("localAiTest"))}" aria-label="${esc(t("localAiTest"))}">
          ${localAiIcon("sparkles", 15)}
        </button>
        <button class="icon-btn" data-action="localAiSettingsModal" data-id="${esc(model.id)}" title="${esc(t("localAiConfigure"))}" aria-label="${esc(t("localAiConfigure"))}">
          ${localAiIcon("gear", 15)}
        </button>
        <details class="local-ai-menu">
          <summary class="icon-btn" title="${esc(t("localAiMore"))}" aria-label="${esc(t("localAiMore"))}">${localAiIcon("ellipsis", 15)}</summary>
          <div class="local-ai-menu-panel">
            <button class="local-ai-menu-item" data-action="localAiCopyId" data-id="${esc(model.id)}">
              ${localAiIcon("copy", 13)}${esc(t("localAiCopyId"))}
            </button>
            <button class="local-ai-menu-item" data-action="localAiOpenFolder" data-id="${esc(model.id)}">
              ${localAiIcon("folder", 13)}${esc(t("localAiOpenFolder"))}
            </button>
            <div class="local-ai-menu-sep"></div>
            <button class="local-ai-menu-item danger" data-action="localAiDelete" data-id="${esc(model.id)}">
              ${localAiIcon("trash", 13)}${esc(t("localAiDeleteModel"))}
            </button>
          </div>
        </details>
      </div>
    </div>
    <div class="card-meta-row">
      ${badges.join("")}
    </div>
    ${isStartingThis ? `
      <div class="progress-bar-wrap">
        <div class="progress-bar-fill indeterminate"></div>
      </div>
    ` : ""}
    ${startError ? `
      <div class="start-error">
        <span class="start-error-icon">!</span>
        <span class="start-error-text">${esc(startError)}</span>
      </div>
    ` : ""}
  </div>`;
}

/// Recommendation badge of a catalog file: the colour dot plus the wording the
/// Mac build shows, driven by the backend's real memory estimate.
function localAiCompatBadge(file) {
  const rec = (file && file.estimation && file.estimation.recommendation) || "";
  const key = LOCAL_AI_RECOMMENDATION_KEYS[rec];
  if (!key) return "";
  const tint = LOCAL_AI_RECOMMENDATION_TINT[rec] || "muted";
  return `<span class="compat-badge ${tint}"><span class="compat-dot"></span>${esc(t(key))}</span>`;
}

function localAiCatalogTab() {
  const presets = ["Qwen2.5-Coder", "Llama-3.2", "DeepSeek-R1-Distill", "Mistral", "Gemma-2", "Phi-3.5"];
  const results = S.localAi.catalogResults || [];
  const selectedRepo = S.localAi.repoDetails;
  const isSearching = S.localAi.catalogLoading;
  const isDetailsLoading = S.localAi.repoDetailsLoading;
  const query = S.localAi.catalogQuery || "";
  const hasSearched = !!(S.localAi.catalogSearched || results.length > 0);

  return `
  <div class="local-ai-content">
    <div class="local-ai-toolbar">
      <div class="search-field" style="max-width:none;flex:1 1 auto">
        ${localAiIcon("search", 13)}
        <input type="text" placeholder="${esc(t("localAiHfSearchPlaceholder"))}" value="${esc(query)}" data-action="localAiHfSearchInput" data-on="input" aria-label="${esc(t("localAiHfSearchPlaceholder"))}">
        ${isSearching ? `<span class="spinner-dot" style="margin:0"></span>` : ""}
        <button class="search-clear" data-action="localAiHfClear" title="${esc(t("localAiClearSearch"))}" aria-label="${esc(t("localAiClearSearch"))}" ${query ? "" : "hidden"}>${localAiIcon("x", 12)}</button>
      </div>
      <button class="btn small" data-action="localAiHfSearch" ${isSearching ? "disabled" : ""}>${esc(t("localAiSearchAction"))}</button>
      <button class="icon-btn" data-action="localAiHfTokenModal" title="${esc(t("localAiHfToken"))}" aria-label="${esc(t("localAiHfToken"))}">
        ${localAiIcon("key", 15)}
      </button>
    </div>

    <div class="preset-pills-row">
      ${presets.map((p) => `
        <button class="pill-btn ${query === p ? "active" : ""}" data-action="localAiHfPreset" data-query="${esc(p)}">
          ${esc(p)}
        </button>
      `).join("")}
    </div>

    <div class="split-pane">
      <div class="split-pane-left">
        ${isSearching ? `
          <div class="loading-state">${esc(t("loading"))}</div>
        ` : results.length === 0 ? `
          <div class="empty-state">
            <div class="empty-icon">${localAiIcon("cube", 40)}</div>
            <p class="muted">${esc(hasSearched ? t("localAiHfEmptyAfterSearch") : t("localAiHfEmptyTitle"))}</p>
          </div>
        ` : `
          <div class="repo-list">
            ${results.map((repo) => {
              const isSelected = S.localAi.selectedRepoId === repo.id;
              return `
                <div class="repo-item ${isSelected ? "selected" : ""}" data-action="localAiSelectRepo" data-id="${esc(repo.id)}">
                  <div class="repo-name">${esc(repo.displayName || repo.id)}</div>
                  <div class="mono hint">${esc(repo.id)}</div>
                  <div class="repo-stats">
                    ${repo.downloads != null ? `<span>${localAiIcon("download", 11)}${repo.downloads.toLocaleString()}</span>` : ""}
                    ${repo.likes != null ? `<span>${localAiIcon("heart", 11)}${repo.likes.toLocaleString()}</span>` : ""}
                  </div>
                </div>
              `;
            }).join("")}
          </div>
        `}
      </div>

      <div class="split-pane-right">
        ${isDetailsLoading ? `
          <div class="loading-state">${esc(t("localAiFilesLoading"))}</div>
        ` : !selectedRepo ? `
          <div class="empty-state">
            <div class="empty-icon">${localAiIcon("sidebar", 40)}</div>
            <p class="muted">${esc(t("localAiSelectRepo"))}</p>
          </div>
        ` : `
          <div class="repo-details">
            <div class="repo-details-header">
              <div class="repo-details-title">
                <h3>${esc(selectedRepo.displayName || selectedRepo.id)}</h3>
                <div class="mono hint">${esc(selectedRepo.id)}</div>
              </div>
              <a href="${esc(selectedRepo.url || `https://huggingface.co/${selectedRepo.id}`)}" target="_blank" rel="noopener noreferrer" class="link-btn">
                ${esc(t("localAiOpenHf"))} ↗
              </a>
            </div>

            <div class="files-header">
              <h4>${esc(t("localAiFiles"))}</h4>
            </div>

            <div class="gguf-files-list">
              ${(selectedRepo.ggufFiles || []).length === 0 ? `
                <div class="muted">${esc(t("localAiNoFiles"))}</div>
              ` : (selectedRepo.ggufFiles || []).map((file) => {
                const isDl = (S.localAi.downloads || []).some((d) => d.filename === file.name && isDownloadActive(d));
                return `
                  <div class="gguf-file-row">
                    <div class="file-info">
                      <div class="file-name mono">${esc(file.name)}</div>
                      <div class="file-meta">
                        <span class="meta-badge">${localAiIcon("archive", 11)}${esc(file.quantization || t("localAiUnknown"))}</span>
                        <span class="hint">${formatBytes(file.size || 0)}</span>
                        ${localAiCompatBadge(file)}
                      </div>
                    </div>
                    <div class="file-action">
                      <button class="btn small" data-action="localAiDownloadQuant" data-repo="${esc(selectedRepo.id)}" data-file="${esc(file.name)}" data-url="${esc(file.downloadUrl || "")}" data-size="${file.size || 0}" data-sha="${esc(file.sha256 || "")}" ${isDl ? "disabled" : ""}>
                        ${isDl ? esc(t("localAiDownloading")) : esc(t("localAiDownload"))}
                      </button>
                    </div>
                  </div>
                `;
              }).join("")}
            </div>
          </div>
        `}
      </div>
    </div>
  </div>`;
}

function localAiDownloadsTab() {
  const downloads = S.localAi.downloads || [];

  return `
  <div class="local-ai-content">
    <div class="local-ai-toolbar">
      <h3 class="toolbar-title">${esc(t("localAiDownloadsTitle"))}</h3>
      <span class="spacer"></span>
      ${downloads.length === 0 ? "" : `
        <button class="ghost small" data-action="localAiClearDownloads">
          ${esc(t("localAiClearCompleted"))}
        </button>
      `}
    </div>

    ${downloads.length === 0 ? `
      <div class="card empty-state">
        <div class="empty-icon">${localAiIcon("downloadCircle", 44)}</div>
        <h3>${esc(t("localAiNoDownloads"))}</h3>
        <p class="muted">${esc(t("localAiNoDownloadsHint"))}</p>
      </div>
    ` : `
      <div class="downloads-list">
        ${downloads.map((dl) => {
          const isDone = dl.status === "completed";
          const isErr = dl.status === "failed";
          const isCanceled = dl.status === "canceled";
          const isDownloading = isDownloadActive(dl);
          const pct = Math.round((dl.progress || 0) * 100);
          // A server may omit the total (chunked body), so the bar switches to
          // an indeterminate sweep instead of freezing at 0% / "0 B".
          const hasTotal = (dl.totalBytes || 0) > 0;

          return `
            <div class="card download-card ${isDone ? "done" : isErr ? "err" : ""}">
              <div class="card-header-row">
                <div>
                  <div class="download-name mono">${esc(dl.filename || dl.modelId)}</div>
                  <div class="hint">${esc(dl.repoId || "")}</div>
                </div>
                <div class="card-actions">
                  ${isDownloading ? `
                    <button class="ghost small danger" data-action="localAiCancelDownload" data-id="${esc(dl.modelId)}">
                      ${esc(t("localAiCancel"))}
                    </button>
                  ` : `
                    <span class="pill ${isDone ? "ok" : isErr ? "danger" : ""}">${isDone ? esc(t("localAiCompleted")) : isErr ? esc(t("localAiStatusFailed")) : isCanceled ? esc(t("localAiCanceled")) : esc(dl.status)}</span>
                  `}
                </div>
              </div>
              <div class="progress-bar-wrap">
                ${hasTotal
                  ? `<div class="progress-bar-fill" style="width: ${pct}%"></div>`
                  : `<div class="progress-bar-fill indeterminate"></div>`}
              </div>
              <div class="download-meta-row">
                <span>${hasTotal
                  ? `${pct}% (${formatBytes(dl.bytesDownloaded || 0)} / ${formatBytes(dl.totalBytes)})`
                  : formatBytes(dl.bytesDownloaded || 0)}</span>
                <span class="spacer"></span>
                ${dl.speedFormatted ? `<span>${esc(dl.speedFormatted)}</span>` : ""}
                ${dl.etaSeconds != null && dl.etaSeconds > 0 ? `<span>${esc(t("localAiEta"))}: ${Math.round(dl.etaSeconds)}s</span>` : ""}
                ${dl.error ? `<span class="danger-text">${esc(dl.error)}</span>` : ""}
              </div>
            </div>
          `;
        }).join("")}
      </div>
    `}
  </div>`;
}

function localAiInstallStageLabel(stage) {
  const labels = {
    idle: "localAiStageIdle",
    downloading: "localAiStageDownloading",
    verifying: "localAiStageVerifying",
    extracting: "localAiStageExtracting",
    validating: "localAiStageValidating",
    publishing: "localAiStagePublishing",
    done: "localAiStageDone",
    failed: "localAiStageFailed",
    cancelled: "localAiStageCancelled",
  };
  return t(labels[stage] || "localAiStageIdle");
}

function localAiMetricsCard() {
  const rt = S.localAi.runtime || {};
  if (!rt.isRunning) return "";
  const metrics = S.localAi.metrics || {};
  const rate = (value) => (typeof value === "number" && Number.isFinite(value) ? `${value.toFixed(1)} tok/s` : "—");
  const count = (value) => (typeof value === "number" && Number.isFinite(value) ? String(value) : "—");

  return `
    <div class="card">
      <div class="card-header-row">
        <h2>${esc(t("localAiLiveMetrics"))}</h2>
        <span class="pill ok">${esc(t("localAiLive"))}</span>
      </div>
      <div class="stat-grid" style="margin-top:12px">
        <div class="metric"><div class="val">${rate(metrics.generatedTokensPerSecond)}</div><div class="lbl">${esc(t("localAiGeneration"))}</div></div>
        <div class="metric"><div class="val">${rate(metrics.promptTokensPerSecond)}</div><div class="lbl">${esc(t("localAiPromptSpeed"))}</div></div>
        <div class="metric"><div class="val">${count(metrics.generatedTokensTotal)}</div><div class="lbl">${esc(t("localAiGeneratedTokens"))}</div></div>
        <div class="metric"><div class="val">${count(metrics.promptTokensTotal)}</div><div class="lbl">${esc(t("localAiPromptTokens"))}</div></div>
      </div>
      <div class="row" style="margin-top:10px">
        <span class="muted">${esc(t("localAiRequestsProcessing"))}:</span> <b>${count(metrics.requestsProcessing)}</b>
        <span class="muted">${esc(t("localAiRequestsDeferred"))}:</span> <b>${count(metrics.requestsDeferred)}</b>
      </div>
      ${S.localAi.metricsError
        ? `<div class="footnote" style="color:var(--danger)">${esc(t("localAiMetricsUnavailable"))}: ${esc(S.localAi.metricsError)}</div>`
        : `<div class="footnote">${esc(t("localAiMetricsHint"))}</div>`}
    </div>`;
}

function localAiRuntimeInstallBody() {
  const install = S.localAi.install || { stage: "idle" };
  const active = ["downloading", "verifying", "extracting", "validating", "publishing"].includes(install.stage);
  const done = install.stage === "done";
  const progress = Math.max(0, Math.min(1, Number(install.progress) || 0));
  const pct = Math.round(progress * 100);
  const bytes = typeof install.bytesDownloaded === "number" ? install.bytesDownloaded : 0;
  const total = typeof install.totalBytes === "number" ? install.totalBytes : 0;
  const speed = typeof install.speedBytesPerSec === "number" ? install.speedBytesPerSec : 0;
  const rt = S.localAi.runtime || {};

  return `
    <div class="install-body">
      <div class="row">
        <span class="muted">${esc(t("localAiRuntimeCardTitle"))}</span>
        <span class="spacer"></span>
        <span class="pill ${done ? "ok" : active ? "warn" : ""}">${esc(localAiInstallStageLabel(install.stage))}</span>
      </div>
      <div class="footnote">${esc(t("localAiRuntimeCatalogCardHint"))}</div>
      <div class="row" style="margin-top:10px">
        <button class="btn small" data-action="localAiRuntimeCatalogOpen">${esc(t("localAiRuntimeBrowse"))}</button>
      </div>
      ${active ? `
        <div class="progress-bar-wrap" style="margin-top:12px">
          ${total > 0
            ? `<div class="progress-bar-fill" style="width: ${pct}%"></div>`
            : `<div class="progress-bar-fill indeterminate"></div>`}
        </div>
        <div class="row">
          <span class="muted mono">${formatBytes(bytes)}${total > 0 ? ` / ${formatBytes(total)}` : ""}</span>
          <span class="spacer"></span>
          <span class="muted mono">${formatBytes(speed)}/s</span>
          <button class="ghost small" data-action="localAiCancelRuntimeInstall">${esc(t("cancel"))}</button>
        </div>
      ` : ""}
      ${done && install.binaryPath ? `
        <div class="row" style="margin-top:10px">
          <span class="muted">${esc(t("localAiRuntimeInstalled"))}:</span>
          <span class="mono" style="font-size:11px;word-break:break-all">${esc(install.binaryPath)}</span>
        </div>
        <div class="row">
          <button class="btn small" data-action="localAiUseInstalledRuntime" ${rt.isRunning ? "disabled" : ""}>${esc(t("localAiRuntimeUse"))}</button>
          ${rt.isRunning ? `<span class="footnote" style="margin:0">${esc(t("localAiRuntimeStopFirst"))}</span>` : ""}
        </div>
      ` : ""}
      ${install.error ? `<div class="footnote" style="color:var(--danger);margin-top:8px">${esc(install.error)}</div>` : ""}
      <div class="divider" style="margin:14px 0"></div>
      <div class="muted" style="font-size:12px;font-weight:600">${esc(t("localAiRuntimeManualTitle"))}</div>
      <div class="footnote">${esc(t("localAiRuntimeInstallHint"))}</div>
      <div class="stack" style="margin-top:10px">
        <label class="field">${esc(t("localAiRuntimeUrl"))}
          <input type="text" id="local-ai-runtime-url" class="mono" placeholder="https://example.com/llama-server.zip" ${active ? "disabled" : ""}>
        </label>
        <label class="field">${esc(t("localAiRuntimeSha"))}
          <input type="text" id="local-ai-runtime-sha" class="mono" placeholder="64 hex characters" autocomplete="off" spellcheck="false" ${active ? "disabled" : ""}>
        </label>
        <div class="footnote">${esc(t("localAiRuntimeShaHint"))}</div>
        <div class="row" style="gap:8px">
          <button class="btn small" data-action="localAiInstallRuntime" ${active ? "disabled" : ""}>${esc(t("localAiRuntimeInstallStart"))}</button>
        </div>
      </div>
    </div>`;
}

function localAiRuntimeVariantLabel(variant) {
  if (variant.id === "cpu") return t("localAiRuntimeVariantCpu");
  if (variant.id === "vulkan") return t("localAiRuntimeVariantVulkan");
  return variant.label || variant.id;
}

function localAiRuntimeReleaseRow(release, installing) {
  const published = release.publishedAt ? new Date(release.publishedAt) : null;
  const publishedText = published && !Number.isNaN(published.getTime())
    ? published.toLocaleDateString(S.lang === "en" ? "en-US" : "ru-RU")
    : "";
  const variants = release.variants || [];

  return `
    <div style="border:1px solid var(--border);border-radius:8px;padding:10px 12px">
      <div class="row">
        <b class="mono">${esc(release.tag)}</b>
        ${release.title && release.title !== release.tag ? `<span class="muted">${esc(release.title)}</span>` : ""}
        <span class="spacer"></span>
        ${publishedText ? `<span class="muted" style="font-size:11px">${esc(publishedText)}</span>` : ""}
      </div>
      <div class="row" style="gap:8px;margin-top:8px;flex-wrap:wrap">
        ${variants.map((variant) => `
          <div class="row" style="gap:8px;border:1px solid var(--border);border-radius:8px;padding:6px 8px">
            <span>${esc(localAiRuntimeVariantLabel(variant))}</span>
            <span class="mono muted">${esc(formatBytes(variant.sizeBytes))}</span>
            <button class="btn small" data-action="localAiRuntimeCatalogInstall" data-tag="${esc(release.tag)}" data-variant="${esc(variant.id)}" ${installing ? "disabled" : ""}>${esc(t("localAiRuntimeInstallFromCatalog"))}</button>
          </div>`).join("")}
      </div>
    </div>`;
}

function localAiRuntimeCatalogMarkup() {
  if (!S.localAi.runtimeCatalogOpen) return "";

  const loading = !!S.localAi.runtimeCatalogLoading;
  const error = S.localAi.runtimeCatalogError;
  const releases = S.localAi.runtimeCatalog || [];
  const install = S.localAi.install || { stage: "idle" };
  const installing = ["downloading", "verifying", "extracting", "validating", "publishing"].includes(install.stage);

  return `
    <div class="modal-backdrop">
      <div class="modal-card wide" id="local-ai-runtime-catalog">
        <div class="card-header-row">
          <div>
            <h3>${esc(t("localAiRuntimeCatalog"))}</h3>
            <div class="modal-sub">${esc(t("localAiRuntimeCatalogHint"))}</div>
          </div>
          <div class="row" style="gap:6px">
            <button class="ghost small" data-action="localAiRuntimeCatalogRefresh" ${loading ? "disabled" : ""}>${esc(t("refresh"))}</button>
            <button class="ghost small" data-action="localAiRuntimeCatalogClose">✕</button>
          </div>
        </div>
        ${installing ? `<div class="footnote" style="color:var(--warn);margin-top:10px">${esc(t("localAiRuntimeCatalogInstalling"))}</div>` : ""}
        ${loading ? `<div class="footnote" style="margin-top:12px">${esc(t("localAiRuntimeCatalogLoading"))}</div>` : ""}
        ${error ? `<div class="footnote" style="color:var(--danger);margin-top:12px">${esc(t("localAiRuntimeCatalogError"))}: ${esc(error)}</div>` : ""}
        ${!loading && !error && releases.length === 0 ? `<div class="footnote" style="margin-top:12px">${esc(t("localAiRuntimeCatalogEmpty"))}</div>` : ""}
        <div class="stack" style="margin-top:12px">
          ${releases.map((release) => localAiRuntimeReleaseRow(release, installing)).join("")}
        </div>
      </div>
    </div>`;
}

function localAiMigrationBanner() {
  const report = S.localAi.migration;
  if (!report || !report.error) return "";
  return `
    <div class="card pool-pause">
      <div class="row">
        <span class="pill danger">${esc(t("localAiMigrationError"))}</span>
        <span class="muted" style="word-break:break-word">${esc(report.error)}</span>
      </div>
      ${report.backupDir ? `<div class="footnote mono">${esc(t("localAiMigrationBackup"))}: ${esc(report.backupDir)}</div>` : ""}
      <div class="footnote">${esc(t("localAiMigrationHint"))}</div>
    </div>`;
}

function localAiRuntimeTab() {
  const hw = S.localAi.hardware || {};
  const rt = S.localAi.runtime || {};
  const logs = S.localAi.logs || [];
  const activeModel = (S.localAi.models || []).find((m) => m.id === rt.modelId);
  const modelName = activeModel ? activeModel.displayName || activeModel.id : rt.modelId;

  // Status wording and dot colour, in the Mac vocabulary.
  let statusText = t("localAiEngineStopped");
  let statusTone = "";
  if (rt.isRunning) {
    statusText = t("localAiEngineReady");
    statusTone = "ok";
  } else if (rt.isStarting) {
    statusText = t("localAiEngineStarting");
    statusTone = "warn";
  } else if (rt.isStopping) {
    statusText = t("localAiEngineStopping");
    statusTone = "warn";
  } else if (rt.error) {
    statusText = `${t("localAiEngineErrorPrefix")}: ${rt.error}`;
    statusTone = "err";
  }

  const ram = formatBytes(hw.totalRam || 0);
  const vram = hw.gpuRecommendedMaxWorkingSetSize;
  const driver = hw.gpuDriver || "";
  const platform = [driver, hw.osVersion].filter(Boolean).join(" · ");

  return `
  <div class="local-ai-content">
    <div class="card runtime-status-card">
      <div class="runtime-status-row">
        <div class="runtime-status-box">
          <div class="stat-label">${esc(t("localAiEngineStatus"))}</div>
          <div class="runtime-status-value">
            <span class="status-dot ${statusTone}"></span>
            <span>${esc(statusText)}</span>
          </div>
          ${rt.isRunning && rt.port ? `<div class="mono hint">127.0.0.1:${esc(String(rt.port))}</div>` : ""}
        </div>

        <div class="runtime-divider"></div>

        <div class="runtime-status-box">
          <div class="stat-label">${esc(t("localAiActiveModel"))}</div>
          <div class="runtime-status-value ${modelName ? "" : "muted"}">
            <span>${modelName ? esc(modelName) : esc(t("localAiNoneLoaded"))}</span>
          </div>
        </div>

        <span class="spacer"></span>

        <div class="runtime-hw">
          <div class="runtime-hw-line">
            ${localAiIcon("cpu", 12)}<span>${esc(fmt(t("localAiCoresLabel"), { cpu: hw.cpuModel || "CPU", n: hw.cpuCores || 0 }))}</span>
          </div>
          <div class="runtime-hw-line">
            ${localAiIcon("memory", 12)}<span>${esc(vram ? fmt(t("localAiRamGpuLabel"), { ram, gpu: formatBytes(vram) }) : fmt(t("localAiRamOnlyLabel"), { ram }))}</span>
          </div>
          ${platform ? `<div class="runtime-hw-line">${localAiIcon("chip", 12)}<span>${esc(platform)}</span></div>` : ""}
        </div>

        ${(rt.isRunning || rt.isStarting) ? `
          <button class="btn small" data-action="localAiStopRuntime">
            ${localAiIcon("stop", 11)}${esc(t("localAiStopEngine"))}
          </button>
        ` : ""}
      </div>
    </div>

    ${localAiMetricsCard()}

    <div class="card console-card">
      <div class="card-header-row">
        <h2>${esc(t("localAiConsoleTitle"))}</h2>
        <div class="card-actions">
          <button class="ghost small" data-action="localAiCopyLogs">${esc(t("localAiCopyLogs"))}</button>
          <button class="ghost small" data-action="localAiClearLogs">${esc(t("localAiClearLogs"))}</button>
        </div>
      </div>
      <div class="terminal-logs mono" id="local-ai-logs">
        ${logs.length === 0 ? `<span class="muted">${esc(t("localAiConsoleEmpty"))}</span>` : logs.map((line) => `<div>${esc(line)}</div>`).join("")}
      </div>
    </div>
  </div>`;
}

function localAiSettingsTab() {
  const hw = S.localAi.hardware || {};
  const rt = S.localAi.runtime || {};
  // The engine path resolves from the live runtime status, so a runtime that
  // was already installed before this launch still reads as present.
  const binaryPath = rt.binaryPath || hw.binaryPath || "";
  const modelsDir = hw.modelsDir || "";
  const freeDisk = hw.modelsDiskFreeSpace || 0;
  const install = S.localAi.install || { stage: "idle" };
  const totalModelsSize = (S.localAi.models || []).reduce((acc, m) => acc + (m.fileSize || 0), 0);
  const engineReady = Boolean(binaryPath) || install.stage === "done";

  return `
  <div class="local-ai-content">
    <div class="card">
      <div class="card-header-row">
        <h2>${esc(t("localAiStorageLocation"))}</h2>
      </div>
      <div class="stack" style="margin-top:10px">
        <div class="field-label">${esc(t("localAiModelsDirectory"))}</div>
        <div class="row">
          <input type="text" id="local-ai-models-dir" class="mono" value="${esc(modelsDir)}" readonly>
          <button class="btn small" data-action="localAiOpenModelsFolder">${esc(t("localAiOpenModelsFolder"))}</button>
        </div>
        <div class="stat-line">
          <span>${esc(t("localAiFreeDiskSpace"))} <b>${formatBytes(freeDisk)}</b></span>
          <span>${esc(t("localAiTotalModelsSize"))} <b>${formatBytes(totalModelsSize)}</b></span>
        </div>
      </div>
    </div>

    <div class="card">
      <div class="card-header-row">
        <h2>${esc(t("localAiEngineBinaryTitle"))}</h2>
      </div>
      <div class="stack" style="margin-top:10px">
        <div class="field-label">${esc(t("localAiLlamaServerPath"))}</div>
        <div class="row">
          <input type="text" id="local-ai-bin-path" class="mono" value="${esc(binaryPath)}" placeholder="${esc(t("localAiBinaryAuto"))}">
          <button class="btn small" data-action="localAiPickBinary">${esc(t("localAiBrowse"))}</button>
          <button class="ghost small" data-action="localAiSaveBinary">${esc(t("save"))}</button>
        </div>

        <table class="runtime-table">
          <thead>
            <tr>
              <th>${esc(t("localAiRuntimeColumn"))}</th>
              <th>${esc(t("localAiVersionColumn"))}</th>
              <th>${esc(t("localAiIntegrityColumn"))}</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>${engineReady ? esc(t("localAiRuntimeBundled")) : `<span class="muted">${esc(t("localAiRuntimeNotInstalled"))}</span>`}</td>
              <td class="mono">—</td>
              <td>${engineReady
                ? `<span class="ok-text">${esc(t("localAiVerified"))}</span>`
                : `<span class="muted">${esc(t("localAiNotVerified"))}</span>`}</td>
            </tr>
          </tbody>
        </table>
        <div class="footnote">${esc(t("localAiEngineBinaryHint"))}</div>

        <div class="divider" style="margin:6px 0"></div>
        ${localAiRuntimeInstallBody()}
      </div>
    </div>

    <div class="card">
      <div class="card-header-row">
        <h2>${esc(t("localAiHfToken"))}</h2>
      </div>
      <div class="stack" style="margin-top:10px">
        <div class="row">
          <input type="password" id="local-ai-hf-token" value="${esc(S.localAi.hfToken || "")}" placeholder="hf_...">
          <button class="btn small" data-action="localAiSaveHfToken">${esc(t("localAiSaveToken"))}</button>
        </div>
        <div class="footnote">${esc(t("localAiHfTokenHint"))}</div>
      </div>
    </div>
  </div>`;
}

/// Rust serializes `CompatibilityRecommendation` as a title-case English
/// label. Printing it raw left the Russian dialog half-translated, so each
/// value maps to a key (and to the tint its severity deserves).
const LOCAL_AI_RECOMMENDATION_KEYS = {
  "Recommended": "localAiRecRecommended",
  "Fits with limitations": "localAiRecFitsWithLimitations",
  "High memory usage": "localAiRecHighMemory",
  "Insufficient memory": "localAiRecInsufficient",
  "Unsupported architecture": "localAiRecUnsupported",
  "Unknown compatibility": "localAiRecUnknown",
};

const LOCAL_AI_RECOMMENDATION_TINT = {
  "Recommended": "ok",
  "Fits with limitations": "warn",
  "High memory usage": "warn",
  "Insufficient memory": "danger",
  "Unsupported architecture": "danger",
  "Unknown compatibility": "",
};

/// Live memory card for the settings dialog. It is re-rendered in place after
/// a profile change or a context/KV edit, so the numbers describe the values on
/// screen instead of the ones the dialog opened with.
function localAiEstimateMarkup() {
  const est = S.localAi.estimate;
  const error = S.localAi.estimateError;
  const pending = !!S.localAi.estimating;
  const header = `<h4>${esc(t("localAiMemoryEstimate"))}</h4>`;

  if (!est) {
    const note = error
      ? fmt(t("localAiEstimateFailed"), { error })
      : pending
        ? t("localAiEstimating")
        : t("localAiEstimateHint");
    return `<div class="card" id="local-ai-estimate" style="background:rgba(255,255,255,0.02);padding:12px;margin-top:8px">
      ${header}
      <div class="footnote" style="margin:8px 0 0">${esc(note)}</div>
    </div>`;
  }

  const cell = (label, bytes, cls) => `<div class="stat ${cls || ""}">
    <span class="value">${formatBytes(bytes || 0)}</span>
    <span class="label">${esc(label)}</span></div>`;
  const recommendation = est.recommendation || "Unknown compatibility";
  const recommendationKey = LOCAL_AI_RECOMMENDATION_KEYS[recommendation];
  const tint = LOCAL_AI_RECOMMENDATION_TINT[recommendation] || "";
  const totalTint = est.fitsInMemory ? "ok" : "danger";

  return `<div class="card" id="local-ai-estimate" style="background:rgba(255,255,255,0.02);padding:12px;margin-top:8px">
    <div class="row" style="justify-content:space-between;align-items:center;gap:8px">
      ${header}
      <span class="${tint ? tint + "-text" : "footnote"}" style="font-weight:600">${esc(recommendationKey ? t(recommendationKey) : recommendation)}</span>
    </div>
    <div class="stat-grid" style="margin-top:8px">
      ${cell(t("localAiWeightsSize"), est.weightsBytes)}
      ${cell(t("localAiKvSize"), est.kvCacheBytes)}
      ${cell(t("localAiComputeBuffers"), est.computeBuffersBytes)}
      ${cell(t("localAiOsReserve"), est.osReserveBytes)}
      ${cell(t("localAiTotalRequired"), est.totalBytes, totalTint)}
      ${cell(t("localAiTotalRam"), est.availableBytes)}
    </div>
    ${est.warning ? `<div class="footnote warn-text" style="margin:8px 0 0">${esc(est.warning)}</div>` : ""}
    <div class="footnote" style="margin:8px 0 0">${esc(est.confidence === "heuristic" ? t("localAiEstimateHeuristic") : t("localAiEstimateMetadata"))}</div>
  </div>`;
}

/// Repaints the memory card in place. A full render would rebuild the dialog
/// and drop the caret while the user edits the context length, and the status
/// guard would skip it entirely while any field keeps the focus.
function paintLocalAiEstimate() {
  const host = document.getElementById("local-ai-estimate");
  if (!host) return;
  host.outerHTML = localAiEstimateMarkup();
}

function localAiSettingsModalMarkup() {
  const model = S.localAi.editingModel;
  if (!model) return "";

  const s = model.userSettings || {};
  // Older registries used PascalCase/spaced labels (`Performance`,
  // `Memory Saver`) and short ids (`speed`, `quality`, `low_memory`); map them
  // onto the enum values the select is built from.
  const PROFILE_VALUES = {
    auto: "auto",
    performance: "performance",
    speed: "performance",
    balanced: "balanced",
    quality: "balanced",
    memory_saver: "memory_saver",
    low_memory: "memory_saver",
    custom: "custom",
  };
  // Labels were not always lowercase (`Memory Saver`, `Performance`), so the
  // lookup normalises case and separators before giving up.
  const rawProfile = String(s.profile || "").trim().toLowerCase().replace(/[\s-]+/g, "_");
  const storedProfile = PROFILE_VALUES[rawProfile] || "auto";
  // A stored label can be stale — an older build wrote `performance` with a
  // 4096-token context. Trust the numbers the fields are about to show, and
  // fall back to the label only for registries that predate those fields.
  const profile = s.contextLength == null || storedProfile === "custom"
    ? storedProfile
    : localAiProfileForSettings({
        contextLength: s.contextLength,
        gpuOffloadLayers: s.gpuOffloadLayers,
        kvCacheType: s.kvCacheType,
        flashAttention: s.flashAttention,
      }, storedProfile);
  // One caption per preset: the select alone does not tell the user what
  // "Max speed" changes, and the macOS sheet answers that right under the chips.
  const PROFILE_HINT_KEYS = {
    auto: "localAiProfileHintAuto",
    performance: "localAiProfileHintSpeed",
    balanced: "localAiProfileHintQuality",
    memory_saver: "localAiProfileHintLowMem",
    custom: "localAiProfileHintCustom",
  };
  const profileHintKey = PROFILE_HINT_KEYS[profile] || PROFILE_HINT_KEYS.auto;
  const contextLength = s.contextLength || 4096;
  const maxTokens = s.maxOutputTokens || 4096;
  const gpuLayers = s.gpuOffloadLayers != null ? s.gpuOffloadLayers : 999;
  const cpuThreads = s.cpuThreads || 4;
  const flashAttention = !!s.flashAttention;
  const kvCacheType = s.kvCacheType || "f16";
  const temperature = s.temperature != null ? s.temperature : 0.7;
  const topP = s.topP != null ? s.topP : 0.9;
  // Seed, reasoning and the chat template are real settings the dialog never
  // exposed, so a save used to drop them back to their defaults.
  const seed = s.seed != null ? s.seed : "";
  const reasoning = !!(s.reasoningEnabled != null ? s.reasoningEnabled : s.reasoning);
  const chatTemplate = s.chatTemplate || "";
  // Applied to served requests by the relay between the gateway and the
  // engine, so it belongs above the engine knobs.
  const systemPrompt = s.systemPrompt || "";
  // Context/KV/offload/threads are read from `models.ini` at launch, so a
  // running model needs an explicit restart next to Save.
  const rt = S.localAi.runtime;
  const runningThis = !!(rt && rt.isRunning && rt.currentModel && rt.currentModel.id === model.id);

  return `
  <div class="modal-backdrop">
    <div class="modal-card wide" id="local-ai-settings-card">
      <div class="card-header-row">
        <div>
          <h3>${esc(model.displayName || model.name || model.id)}</h3>
          <div class="mono hint">${esc(model.id)}</div>
        </div>
        <button class="ghost small" data-action="localAiSettingsClose">✕</button>
      </div>

      <div class="stack" style="margin-top:16px">
        <label class="field">${esc(t("localAiSystemPrompt"))}
          <textarea id="local-ai-setting-system-prompt" data-action="localAiSystemPromptInput" data-on="input" rows="3" placeholder="You are a helpful assistant.">${esc(systemPrompt)}</textarea>
          <div class="footnote">${esc(t("localAiSystemPromptHint"))}</div>
        </label>

        <label class="field">${esc(t("localAiProfile"))}
          <select id="local-ai-setting-profile" data-action="localAiProfileChange" data-on="change">
            <option value="auto" ${profile === "auto" ? "selected" : ""}>${esc(t("localAiProfileAuto"))}</option>
            <option value="performance" ${profile === "performance" ? "selected" : ""}>${esc(t("localAiProfileSpeed"))}</option>
            <option value="balanced" ${profile === "balanced" ? "selected" : ""}>${esc(t("localAiProfileQuality"))}</option>
            <option value="memory_saver" ${profile === "memory_saver" ? "selected" : ""}>${esc(t("localAiProfileLowMem"))}</option>
            <option value="custom" ${profile === "custom" ? "selected" : ""}>${esc(t("localAiProfileCustom"))}</option>
          </select>
          <div class="footnote">${esc(t(profileHintKey))}</div>
        </label>

        <div class="grid2">
          <label class="field">${esc(t("localAiContext"))}
            <input type="number" id="local-ai-setting-context" value="${contextLength}" step="512" min="512" max="131072" data-action="localAiEstimateInput" data-on="input">
          </label>
          <label class="field">Max Tokens
            <input type="number" id="local-ai-setting-max-tokens" value="${maxTokens}" step="256" min="128" max="32768">
          </label>
        </div>

        <div class="grid2">
          <label class="field">${esc(t("localAiGpuLayers"))} (-ngl)
            <input type="number" id="local-ai-setting-gpu-layers" value="${gpuLayers}" min="0" max="999">
          </label>
          <label class="field">${esc(t("localAiThreads"))}
            <input type="number" id="local-ai-setting-threads" value="${cpuThreads}" min="1" max="128">
          </label>
        </div>

        <div class="grid2">
          <label class="field">${esc(t("localAiKvCache"))}
            <select id="local-ai-setting-kv-cache" data-action="localAiEstimateInput" data-on="input">
              ${[
                ["f32", "f32 · 32-bit"],
                ["f16", "f16 · " + t("localAiKvFull")],
                ["bf16", "bf16 · 16-bit"],
                ["q8_0", "q8_0 · " + t("localAiKvBalanced")],
                ["q5_1", "q5_1 · 5-bit"],
                ["q5_0", "q5_0 · 5-bit"],
                ["q4_1", "q4_1 · 4-bit"],
                ["q4_0", "q4_0 · " + t("localAiKvLow")],
                ["iq4_nl", "iq4_nl · 4-bit"],
              ].map(([value, label]) => `<option value="${value}" ${kvCacheType === value ? "selected" : ""}>${esc(label)}</option>`).join("")}
            </select>
          </label>
          <label class="field" style="flex-direction:row;align-items:center;gap:8px;margin-top:20px">
            <input type="checkbox" id="local-ai-setting-flash-attn" ${flashAttention ? "checked" : ""}>
            <span>${esc(t("localAiFlashAttn"))}</span>
          </label>
        </div>

        <div class="grid2">
          <label class="field">${esc(t("localAiTemperature"))}
            <input type="number" id="local-ai-setting-temp" value="${temperature}" step="0.05" min="0" max="2">
          </label>
          <label class="field">${esc(t("localAiTopP"))}
            <input type="number" id="local-ai-setting-topp" value="${topP}" step="0.05" min="0" max="1">
          </label>
        </div>

        <div class="grid2">
          <label class="field">${esc(t("localAiSeed"))}
            <input type="number" id="local-ai-setting-seed" value="${seed}" step="1" placeholder="${esc(t("localAiSeedAuto"))}">
          </label>
          <label class="field" style="flex-direction:row;align-items:center;gap:8px;margin-top:20px">
            <input type="checkbox" id="local-ai-setting-reasoning" ${reasoning ? "checked" : ""}>
            <span>${esc(t("localAiReasoning"))}</span>
          </label>
        </div>

        <label class="field">${esc(t("localAiChatTemplate"))}
          <input type="text" id="local-ai-setting-chat-template" class="mono" value="${esc(chatTemplate)}" placeholder="auto">
        </label>

        ${runningThis ? `<div class="footnote warn-text">${esc(t("localAiPendingHint"))}</div>` : ""}

        ${localAiEstimateMarkup()}

        <div class="row" style="justify-content:flex-end;margin-top:16px;gap:8px">
          <button class="ghost" data-action="localAiSettingsClose">${esc(t("localAiClose"))}</button>
          ${runningThis ? `<button class="btn" data-action="localAiSettingsSaveRestart">${esc(t("localAiSaveRestart"))}</button>` : ""}
          <button class="btn" data-action="localAiSettingsSave">${esc(t("localAiSave"))}</button>
        </div>
      </div>
    </div>
  </div>`;
}

function localAiTestModalMarkup() {
  const m = S.localAi.testModal;
  if (!m) return "";

  return `
  <div class="modal-backdrop">
    <div class="modal-card wide">
      <div class="card-header-row">
        <div>
          <h3>${esc(t("localAiTest"))}: ${esc(m.modelName || m.modelId)}</h3>
          <div class="mono hint">${esc(m.modelId)}</div>
        </div>
        <button class="ghost small" data-action="localAiTestClose">✕</button>
      </div>

      <div class="stack" style="margin-top:16px">
        <label class="field">${esc(t("localAiTestPrompt"))}
          <textarea id="local-ai-test-prompt-input" rows="3" placeholder="Why is the sky blue?">${esc(m.prompt || "")}</textarea>
        </label>
        <div class="row" style="justify-content:flex-end;gap:8px;align-items:center">
          ${m.generating ? `<span class="pill warn"><span class="spinner-dot"></span>${esc(t("localAiGenerating"))}</span>` : ""}
          ${m.tokensPerSec ? `<span class="pill ok">${m.tokensPerSec.toFixed(1)} tok/s</span>` : ""}
          <span class="spacer"></span>
          <button class="btn small" data-action="localAiTestSend" ${m.generating ? "disabled" : ""}>
            ${m.generating ? esc(t("localAiGenerating")) : esc(t("localAiSend"))}
          </button>
        </div>

        <div class="field" style="margin-top:8px">
          <div class="row">
            <span class="muted">${esc(t("localAiResponse"))}</span>
            <span class="spacer"></span>
          </div>
          <div class="terminal-logs mono" style="min-height:140px;max-height:280px;margin-top:6px;white-space:pre-wrap">${
            m.response
              ? renderMarkdown(m.response)
              : `<span class="muted">${esc(m.generating ? t("localAiWaitingFirstToken") : t("localAiNoResponseYet"))}</span>`
          }</div>
          ${m.truncated ? `<div class="footnote" style="color:var(--warn);margin-top:6px">${esc(t("localAiTruncated"))}</div>` : ""}
        </div>

        <div class="row" style="justify-content:flex-end;margin-top:12px">
          <button class="ghost" data-action="localAiTestClose">${esc(t("localAiClose"))}</button>
        </div>
      </div>
    </div>
  </div>`;
}

function localAiHfTokenModalMarkup() {
  if (!S.localAi.showHfTokenModal) return "";

  return `
  <div class="modal-backdrop">
    <div class="modal-card">
      <div class="card-header-row">
        <h3>${esc(t("localAiHfToken"))}</h3>
        <button class="ghost small" data-action="localAiHfTokenModalClose">✕</button>
      </div>
      <div class="stack" style="margin-top:16px">
        <div class="footnote">${esc(t("localAiHfTokenHint"))}</div>
        <label class="field">Token
          <input type="password" id="modal-hf-token-input" value="${esc(S.localAi.hfToken || "")}" placeholder="hf_...">
        </label>
        <div class="row" style="justify-content:flex-end;margin-top:12px;gap:8px">
          <button class="ghost" data-action="localAiHfTokenModalClose">${esc(t("cancel"))}</button>
          <button class="btn" data-action="localAiHfTokenModalSave">${esc(t("save"))}</button>
        </div>
      </div>
    </div>
  </div>`;
}

function localAiPage() {
  const tab = S.localAi.tab || "models";
  let content = "";
  if (tab === "models") content = localAiModelsTab();
  else if (tab === "catalog") content = localAiCatalogTab();
  else if (tab === "downloads") content = localAiDownloadsTab();
  else if (tab === "runtime") content = localAiRuntimeTab();
  else if (tab === "settings") content = localAiSettingsTab();

  return `
  ${pageHead("melon tools", t("localAi"), t("localAiSub"))}
  ${localAiMigrationBanner()}
  ${localAiSubtabs()}
  ${content}
  ${localAiSettingsModalMarkup()}
  ${localAiTestModalMarkup()}
  ${localAiHfTokenModalMarkup()}
  ${localAiRuntimeCatalogMarkup()}
  `;
}

// MARK: - Refresh guard (M3)

const FORM_TAGS = ["INPUT", "TEXTAREA", "SELECT"];

