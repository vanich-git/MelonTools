// Melon Tools - native plugin store (Windows).
// The backend owns discovery, checksums and loading; this file only renders
// the catalog and forwards explicit user actions.

const PLUGIN_PICKS = [
  "codex-token-usage", "jshandler", "github-copilot", "cursor-agent",
  "deepseek-cpa", "model-router", "prompt-rules", "pii-filter",
];

const PLUGIN_FILTERS = [
  { id: "all", label: "pluginAll" },
  { id: "updates", label: "pluginUpdates" },
  { id: "providers", label: "pluginProviders", tag: "Provider" },
  { id: "interceptors", label: "pluginInterceptors", tag: "Interceptor" },
  { id: "scheduling", label: "pluginScheduling", tag: "Scheduler" },
  { id: "usage", label: "pluginUsage", tag: "Usage" },
  { id: "dashboards", label: "pluginDashboards", tag: "Dashboard" },
];

function pluginState() {
  if (!S.plugins) {
    S.plugins = {
      loaded: false,
      loading: false,
      prefs: null,
      catalog: [],
      installed: [],
      sources: [],
      sourceErrors: [],
      tab: "discover",
      filter: "all",
      query: "",
      detail: null,
      consent: null,
      removeId: null,
      hostConfirm: null,
      hostBusy: false,
      config: null,
      installing: null,
      removing: null,
      error: null,
      restartNeeded: false,
    };
  }
  return S.plugins;
}

function pluginLogo(url, name) {
  const initial = String(name || "?").trim().slice(0, 1).toUpperCase() || "?";
  const image = url
    ? `<img src="${esc(url)}" alt="" loading="lazy" referrerpolicy="no-referrer">`
    : "";
  return `<span class="plugin-logo">${image}<span>${esc(initial)}</span></span>`;
}

function pluginSourceLabel(entry) {
  const url = String((entry && (entry.source_url || entry.sourceURL)) || "");
  const id = String((entry && (entry.source_id || entry.sourceID)) || "");
  const name = String((entry && (entry.source_name || entry.sourceName)) || "");
  if (url.toLowerCase().includes("vanich-git/melontools")) return t("pluginRegistry");
  if (id === "official") return S.lang === "en" ? "Official" : "Официальный";
  return name || url;
}

function pluginTags(entry) {
  return Array.isArray(entry && entry.tags) ? entry.tags.map(String) : [];
}

function pluginTagLabel(tag) {
  const map = {
    Provider: "pluginProviders", Interceptor: "pluginInterceptors",
    Scheduler: "pluginScheduling", Usage: "pluginUsage", Dashboard: "pluginDashboards",
  };
  return map[tag] ? t(map[tag]) : tag;
}

function pluginCatalog() {
  return (pluginState().catalog || []).filter((entry) => entry && entry.id);
}

function pluginInstalled() {
  return (pluginState().installed || []).filter((entry) => entry && entry.id);
}

function pluginFind(id) {
  return pluginCatalog().find((entry) => entry.id === id)
    || pluginInstalled().find((entry) => entry.id === id)
    || null;
}

function pluginInstalledFind(id) {
  return pluginInstalled().find((entry) => entry.id === id) || null;
}

function pluginIsInstalled(entry) {
  return !!(entry && (entry.installed || pluginInstalledFind(entry.id)));
}

// The engine can only download from a publisher whose store credential is in
// the gateway config. Melon has no screen for that credential, so an entry
// that needs it can never install here. Matches the macOS installBlocker rule.
function pluginInstallBlocker(entry) {
  if (!entry || pluginIsInstalled(entry)) return "";
  if (entry.auth_required && !entry.auth_configured) return t("pluginAuthBlocker");
  return "";
}

function pluginStatus(entry) {
  if (entry && entry.update_available) return { cls: "warn", text: t("pluginUpdate") };
  if (entry && entry.effective_enabled) return { cls: "ok", text: t("pluginActive") };
  if (pluginIsInstalled(entry)) return { cls: "", text: t("pluginDisabled") };
  if (entry && entry.registered) return { cls: "warn", text: t("pluginNotLoaded") };
  return { cls: "", text: t("pluginAvailable") };
}

function pluginMatches(entry, filter) {
  if (filter === "all") return true;
  if (filter === "updates") return !!entry.update_available;
  const spec = PLUGIN_FILTERS.find((item) => item.id === filter);
  if (!spec || !spec.tag) return true;
  return pluginTags(entry).some((tag) => tag.toLowerCase() === spec.tag.toLowerCase());
}

function pluginSearchMatch(entry, query) {
  if (!query) return true;
  const haystack = [
    entry.id, entry.name, entry.description, entry.author,
    pluginTags(entry).join(" "), pluginSourceLabel(entry),
  ].join(" ").toLowerCase();
  return haystack.includes(query.toLowerCase());
}

function pluginFiltered() {
  const st = pluginState();
  return pluginCatalog().filter((entry) => pluginMatches(entry, st.filter) && pluginSearchMatch(entry, st.query));
}

function pluginCard(entry) {
  const installed = pluginIsInstalled(entry);
  const status = pluginStatus(entry);
  const tags = pluginTags(entry).slice(0, 4);
  const source = pluginSourceLabel(entry);
  const version = entry.version ? `v${entry.version}` : "";
  const blocker = pluginInstallBlocker(entry);
  return `<div class="card plugin-card">
    <div class="plugin-card-head">
      ${pluginLogo(entry.logo, entry.name || entry.id)}
      <div class="plugin-card-title">
        <div class="plugin-name">${esc(entry.name || entry.id)}</div>
        <div class="plugin-id mono">${esc(entry.id)}${version ? ` · ${esc(version)}` : ""}</div>
      </div>
      <span class="pill ${status.cls}">${esc(status.text)}</span>
    </div>
    <p class="plugin-desc">${esc(entry.description || "")}</p>
    <div class="plugin-tags">
      ${tags.map((tag) => `<span class="plugin-tag">${esc(pluginTagLabel(tag))}</span>`).join("")}
      ${source ? `<span class="plugin-source">${esc(source)}</span>` : ""}
    </div>
    ${blocker ? `<div class="footnote plugin-blocker">${esc(blocker)}</div>` : ""}
    <div class="plugin-card-actions">
      ${installed
        ? `<button class="btn small" data-action="pluginConfigure" data-id="${esc(entry.id)}">${esc(t("pluginConfigure"))}</button>`
        : `<button class="btn small" data-action="pluginInstall" data-id="${esc(entry.id)}" ${blocker || pluginState().installing ? "disabled" : ""} title="${esc(blocker)}">${esc(entry.update_available ? t("pluginUpdate") : t("pluginInstall"))}</button>`}
      ${entry.update_available && installed
        ? `<button class="ghost small" data-action="pluginInstall" data-id="${esc(entry.id)}" ${pluginState().installing ? "disabled" : ""}>${esc(t("pluginUpdate"))}</button>`
        : ""}
      <button class="ghost small" data-action="pluginDetails" data-id="${esc(entry.id)}">${esc(t("pluginDetails"))}</button>
    </div>
  </div>`;
}

function pluginResultsMarkup() {
  const entries = pluginFiltered();
  if (!entries.length) {
    return `<div class="empty-state plugin-empty"><b>${esc(t("pluginNoPlugins"))}</b><p>${esc(pluginState().query || "")}</p></div>`;
  }
  return `<div class="plugin-grid">${entries.map(pluginCard).join("")}</div>`;
}

function pluginPicksMarkup() {
  const st = pluginState();
  if (st.query || st.filter !== "all") return "";
  const picks = PLUGIN_PICKS
    .map((id) => pluginCatalog().find((entry) => entry.id === id))
    .filter(Boolean);
  if (!picks.length) return "";
  return `<section class="plugin-picks">
    <div class="plugin-section-title">
      <div><h2>${esc(t("pluginMelonPicks"))}</h2><div class="footnote">${esc(t("pluginMelonPicksHint"))}</div></div>
    </div>
    <div class="plugin-grid">${picks.map(pluginCard).join("")}</div>
  </section>`;
}

function pluginInstalledCard(entry) {
  const status = pluginStatus(entry);
  const version = entry.version ? `v${entry.version}` : "";
  return `<div class="card plugin-installed-row">
    ${pluginLogo(entry.logo, entry.name || entry.id)}
    <div class="plugin-card-title">
      <div class="plugin-name">${esc(entry.name || entry.id)}</div>
      <div class="plugin-id mono">${esc(entry.id)}${version ? ` · ${esc(version)}` : ""}</div>
      <div class="plugin-tags">${pluginTags(entry).slice(0, 3).map((tag) => `<span class="plugin-tag">${esc(pluginTagLabel(tag))}</span>`).join("")}</div>
    </div>
    <span class="pill ${status.cls}">${esc(status.text)}</span>
    <label class="plugin-switch" title="${esc(t("pluginEnable"))}">
      <input type="checkbox" data-action="pluginToggle" data-id="${esc(entry.id)}" data-on="change" ${entry.enabled ? "checked" : ""}>
    </label>
    <button class="ghost small" data-action="pluginConfigure" data-id="${esc(entry.id)}">${esc(t("pluginConfigure"))}</button>
    <button class="ghost small danger" data-action="pluginRemove" data-id="${esc(entry.id)}">${esc(t("pluginRemove"))}</button>
  </div>`;
}

function pluginInstalledMarkup() {
  const entries = pluginInstalled();
  if (!entries.length) {
    return `<div class="empty-state plugin-empty"><b>${esc(t("pluginNoInstalled"))}</b><p>${esc(t("pluginMelonPicksHint"))}</p></div>`;
  }
  return `<div class="stack plugin-installed-list">${entries.map(pluginInstalledCard).join("")}</div>`;
}

function pluginHostCard() {
  const st = pluginState();
  const prefs = st.prefs || {};
  const on = !!prefs.hostEnabled;
  const total = pluginInstalled().length;
  const active = pluginInstalled().filter((entry) => entry.effective_enabled).length;
  const updates = pluginCatalog().filter((entry) => entry.update_available).length;
  const gatewayOn = !!(S.status && S.status.running);
  return `<div class="card plugin-host-card">
    <div class="plugin-card-head">
      <span class="plugin-host-icon">${on ? "◆" : "◇"}</span>
      <div class="plugin-card-title">
        <div class="plugin-name">${esc(t("pluginHost"))}</div>
        <div class="plugin-sub">${on ? esc(t("pluginHostOn")) : esc(t("pluginHostOff"))} · ${esc(gatewayOn ? t("running") : t("stopped"))}</div>
      </div>
      <span class="spacer"></span>
      <span class="pill ${on ? "ok" : ""}">${esc(on ? t("pluginActive") : t("pluginSafeMode"))}</span>
      ${on
        ? `<button class="ghost small" data-action="pluginDisableHost">${esc(t("pluginSafeMode"))}</button>`
        : `<button class="btn small" data-action="pluginEnableHost">${esc(t("pluginTurnOn"))}</button>`}
    </div>
    <p class="plugin-desc">${esc(t("pluginHostHint"))}</p>
    <div class="plugin-host-metrics">
      <span><b>${total}</b> ${esc(t("pluginInstalled"))}</span>
      <span><b>${active}</b> ${esc(t("pluginActive"))}</span>
      <span><b>${updates}</b> ${esc(t("pluginUpdates"))}</span>
      <span class="spacer"></span>
      <button class="ghost small" data-action="pluginOpenFolder">${esc(t("pluginOpenFolder"))}</button>
    </div>
    <div class="plugin-paths">
      <div><span>${esc(t("pluginFolder"))}</span><code>${esc(prefs.pluginsDir || "")}</code></div>
      <div><span>${esc(t("pluginRegistry"))}</span><code>${esc(prefs.registryUrl || "")}</code></div>
    </div>
    <div class="footnote">${esc(t("pluginManagedByEngine"))}</div>
  </div>`;
}

function pluginConfigField(field, index, values) {
  const name = String(field.name || "");
  const type = String(field.type || "string");
  const current = values && Object.prototype.hasOwnProperty.call(values, name)
    ? values[name]
    : field.default;
  const id = `plugin-cfg-${index}`;
  const label = `<label class="field plugin-field" for="${id}"><span>${esc(name)}</span>`;
  const hint = field.description ? `<small>${esc(field.description)}</small>` : "";
  if (type === "boolean") {
    return `${label}<input id="${id}" type="checkbox" data-plugin-field="${esc(name)}" data-plugin-type="boolean" ${current ? "checked" : ""}></label>${hint}`;
  }
  if (type === "enum") {
    const choices = Array.isArray(field.enum_values) ? field.enum_values.map(String) : [];
    const selected = current == null ? "" : String(current);
    return `${label}<select id="${id}" data-plugin-field="${esc(name)}" data-plugin-type="enum">${choices.map((choice) => `<option value="${esc(choice)}" ${choice === selected ? "selected" : ""}>${esc(choice)}</option>`).join("")}</select></label>${hint}`;
  }
  if (type === "array" || type === "object") {
    let text = "";
    try { text = current == null ? "" : JSON.stringify(current, null, 2); } catch (_) { text = ""; }
    return `${label}<textarea id="${id}" rows="4" data-plugin-field="${esc(name)}" data-plugin-type="${esc(type)}" spellcheck="false">${esc(text)}</textarea></label>${hint}`;
  }
  const numeric = type === "integer" || type === "number";
  return `${label}<input id="${id}" type="${numeric ? "number" : "text"}" ${type === "integer" ? 'step="1"' : (type === "number" ? 'step="any"' : "")} value="${esc(current == null ? "" : String(current))}" data-plugin-field="${esc(name)}" data-plugin-type="${esc(type)}"></label>${hint}`;
}

function pluginDetailsModal() {
  const st = pluginState();
  const entry = st.detail ? pluginFind(st.detail) : null;
  if (!entry) return "";
  const installed = pluginIsInstalled(entry);
  const status = pluginStatus(entry);
  const blocker = pluginInstallBlocker(entry);
  const platforms = Array.isArray(entry.platforms)
    ? entry.platforms.map((p) => `${p.goos || ""} ${p.goarch || ""}`.trim()).filter(Boolean)
    : [];
  return `<div class="modal-backdrop"><div class="modal-card wide plugin-modal" role="dialog" aria-modal="true" aria-label="${esc(t("pluginDetails"))}">
    <div class="card-header-row">
      <div class="plugin-card-head">${pluginLogo(entry.logo, entry.name || entry.id)}
        <div class="plugin-card-title"><h3>${esc(entry.name || entry.id)}</h3><div class="plugin-id mono">${esc(entry.id)}</div></div>
      </div>
      <button class="ghost small" data-action="pluginClose" aria-label="${esc(t("close"))}">✕</button>
    </div>
    <div class="stack plugin-detail-body">
      <div class="row"><span class="pill ${status.cls}">${esc(status.text)}</span>${entry.version ? `<span class="pill">v${esc(entry.version)}</span>` : ""}${entry.installed_version ? `<span class="pill">${esc(t("pluginVersionInstalled"))}: ${esc(entry.installed_version)}</span>` : ""}</div>
      <p>${esc(entry.description || "")}</p>
      <div class="plugin-kv">
        <div><span>${esc(t("pluginAuthor"))}</span><b>${esc(entry.author || "n/a")}</b></div>
        <div><span>${esc(t("pluginSource"))}</span><b>${esc(pluginSourceLabel(entry))}</b></div>
        <div><span>${esc(t("pluginLicense"))}</span><b>${esc(entry.license || "n/a")}</b></div>
        <div><span>${esc(t("pluginPlatforms"))}</span><b>${esc(platforms.join(", ") || "n/a")}</b></div>
      </div>
      <div class="plugin-tags">${pluginTags(entry).map((tag) => `<span class="plugin-tag">${esc(pluginTagLabel(tag))}</span>`).join("")}</div>
      ${blocker ? `<div class="footnote plugin-blocker">${esc(blocker)}</div>` : ""}
      <div class="row plugin-modal-actions">
        ${installed
          ? `<button class="btn small" data-action="pluginConfigure" data-id="${esc(entry.id)}">${esc(t("pluginConfigure"))}</button>`
          : `<button class="btn small" data-action="pluginInstall" data-id="${esc(entry.id)}" ${blocker ? "disabled" : ""} title="${esc(blocker)}">${esc(t("pluginInstall"))}</button>`}
        ${entry.homepage ? `<button class="ghost small" data-action="pluginOpenUrl" data-id="${esc(entry.homepage)}">${esc(t("pluginHomepage"))}</button>` : ""}
        <span class="spacer"></span>
        <button class="ghost small" data-action="pluginClose">${esc(t("pluginClose"))}</button>
      </div>
    </div>
  </div></div>`;
}

function pluginConsentModal() {
  const st = pluginState();
  const entry = st.consent ? pluginFind(st.consent) : null;
  if (!entry) return "";
  const blocker = pluginInstallBlocker(entry);
  return `<div class="modal-backdrop"><div class="modal-card plugin-modal" role="dialog" aria-modal="true" aria-label="${esc(t("pluginConsentTitle"))}">
    <div class="card-header-row"><h3>${esc(t("pluginConsentTitle"))}</h3><button class="ghost small" data-action="pluginClose" aria-label="${esc(t("close"))}">✕</button></div>
    <div class="stack plugin-detail-body">
      <div class="plugin-card-head">${pluginLogo(entry.logo, entry.name || entry.id)}
        <div class="plugin-card-title"><div class="plugin-name">${esc(entry.name || entry.id)}</div><div class="plugin-id mono">${esc(entry.id)}${entry.version ? ` · v${esc(entry.version)}` : ""}</div></div>
      </div>
      <div class="plugin-warning"><b>${esc(t("pluginNativeWarning"))}</b><p>${esc(t("pluginConsentBody"))}</p></div>
      ${blocker ? `<div class="footnote plugin-blocker">${esc(blocker)}</div>` : ""}
      <div class="footnote">${esc(t("pluginInstallSource"))}: ${esc(pluginSourceLabel(entry))}</div>
      <label class="row plugin-consent-check"><input id="plugin-consent-check" type="checkbox"> <span>${esc(t("pluginConsentTrust"))}</span></label>
      ${st.error ? `<div class="footnote" style="color:var(--danger)">${esc(st.error)}</div>` : ""}
      <div class="row plugin-modal-actions">
        <span class="spacer"></span>
        <button class="ghost" data-action="pluginClose">${esc(t("pluginCancel"))}</button>
        <button class="btn" data-action="pluginConfirmInstall" ${blocker || st.installing ? "disabled" : ""}>${esc(st.installing ? t("pluginInstalling") : t("pluginConsentInstall"))}</button>
      </div>
    </div>
  </div></div>`;
}

function pluginRemoveModal() {
  const st = pluginState();
  if (!st.removeId) return "";
  const entry = pluginFind(st.removeId);
  return `<div class="modal-backdrop"><div class="modal-card plugin-modal" role="dialog" aria-modal="true" aria-label="${esc(t("pluginRemoveTitle"))}">
    <div class="card-header-row"><h3>${esc(t("pluginRemoveTitle"))}</h3><button class="ghost small" data-action="pluginClose" aria-label="${esc(t("close"))}">✕</button></div>
    <div class="stack plugin-detail-body">
      <p><b>${esc((entry && (entry.name || entry.id)) || st.removeId)}</b></p>
      <p class="footnote">${esc(t("pluginRemoveBody"))}</p>
      ${st.error ? `<div class="footnote" style="color:var(--danger)">${esc(st.error)}</div>` : ""}
      <div class="row plugin-modal-actions"><span class="spacer"></span>
        <button class="ghost" data-action="pluginClose">${esc(t("pluginCancel"))}</button>
        <button class="btn danger" data-action="pluginConfirmRemove" ${st.removing ? "disabled" : ""}>${esc(t("pluginConfirm"))}</button>
      </div>
    </div>
  </div></div>`;
}

function pluginHostModal() {
  const st = pluginState();
  if (!st.hostConfirm) return "";
  const enable = st.hostConfirm === "enable";
  return `<div class="modal-backdrop"><div class="modal-card plugin-modal" role="dialog" aria-modal="true" aria-label="${esc(t(enable ? "pluginEnableHostTitle" : "pluginDisableHostTitle"))}">
    <div class="card-header-row"><h3>${esc(t(enable ? "pluginEnableHostTitle" : "pluginDisableHostTitle"))}</h3><button class="ghost small" data-action="pluginClose" aria-label="${esc(t("close"))}">✕</button></div>
    <div class="stack plugin-detail-body">
      <p>${esc(t(enable ? "pluginEnableHostBody" : "pluginDisableHostBody"))}</p>
      ${st.error ? `<div class="footnote" style="color:var(--danger)">${esc(st.error)}</div>` : ""}
      <div class="row plugin-modal-actions"><span class="spacer"></span>
        <button class="ghost" data-action="pluginClose">${esc(t("pluginCancel"))}</button>
        <button class="btn ${enable ? "" : "danger"}" data-action="pluginConfirmHost" ${st.hostBusy ? "disabled" : ""}>${esc(enable ? t("pluginTurnOn") : t("pluginSafeMode"))}</button>
      </div>
    </div>
  </div></div>`;
}

function pluginConfigModal() {
  const st = pluginState();
  const cfg = st.config;
  if (!cfg) return "";
  const entry = pluginInstalledFind(cfg.id) || pluginFind(cfg.id);
  const fields = Array.isArray(cfg.fields) ? cfg.fields : [];
  return `<div class="modal-backdrop"><div class="modal-card wide plugin-modal" role="dialog" aria-modal="true" aria-label="${esc(t("pluginConfig"))}">
    <div class="card-header-row">
      <div class="plugin-card-head">${pluginLogo(entry && entry.logo, (entry && (entry.name || entry.id)) || cfg.id)}
        <div class="plugin-card-title"><h3>${esc((entry && (entry.name || entry.id)) || cfg.id)}</h3><div class="plugin-id mono">${esc(cfg.id)}</div></div>
      </div>
      <button class="ghost small" data-action="pluginClose" aria-label="${esc(t("close"))}">✕</button>
    </div>
    ${cfg.loading ? `<div class="empty-state plugin-empty"><b>${esc(t("pluginConfig"))}</b><p>${esc(t("pluginSaving"))}</p></div>` : `
    <div class="stack plugin-detail-body">
      <label class="row plugin-consent-check"><input id="plugin-config-enabled" type="checkbox" ${cfg.enabled ? "checked" : ""}> <span><b>${esc(t("pluginEnable"))}</b><br><small>${esc(t("pluginEnableHint"))}</small></span></label>
      ${fields.length ? fields.map((field, index) => pluginConfigField(field, index, cfg.values || {})).join("") : `
        <div class="footnote">${esc(t("pluginConfigEmpty"))}</div>
        <label class="field plugin-field"><span>JSON</span><textarea id="plugin-config-raw" rows="10" spellcheck="false">${esc(cfg.raw || "{}")}</textarea></label>`}
      ${cfg.error ? `<div class="footnote" style="color:var(--danger)">${esc(cfg.error)}</div>` : ""}
      <div class="footnote">${esc(t("pluginConfigHint"))}</div>
      <div class="row plugin-modal-actions"><span class="spacer"></span>
        <button class="ghost" data-action="pluginClose">${esc(t("pluginCancel"))}</button>
        <button class="btn" data-action="pluginSaveConfig" ${cfg.saving ? "disabled" : ""}>${esc(cfg.saving ? t("pluginSaving") : t("pluginSave"))}</button>
      </div>
    </div>`}
  </div></div>`;
}

function pluginsPage() {
  const st = pluginState();
  const gatewayOn = !!(S.status && S.status.running);
  const tabs = `
    <div class="segmented plugin-tabs">
      <button class="${st.tab === "discover" ? "active" : ""}" data-action="pluginTab" data-id="discover">${esc(t("pluginDiscover"))}</button>
      <button class="${st.tab === "installed" ? "active" : ""}" data-action="pluginTab" data-id="installed">${esc(t("pluginInstalled"))} ${pluginInstalled().length ? `<span class="badge">${pluginInstalled().length}</span>` : ""}</button>
    </div>`;
  const filters = `<div class="preset-pills-row plugin-filters">${PLUGIN_FILTERS.map((filter) => `<button class="pill-btn ${st.filter === filter.id ? "active" : ""}" data-action="pluginFilter" data-id="${filter.id}">${esc(t(filter.label))}</button>`).join("")}</div>`;
  const toolbar = `<div class="row plugin-toolbar">
    <div class="search-field"><svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="10.5" cy="10.5" r="6.5"></circle><path d="m15.5 15.5 4 4"></path></svg><input id="plugin-search" placeholder="${esc(t("pluginSearch"))}" value="${esc(st.query)}" data-action="pluginSearch" data-on="input"></div>
    <span class="spacer"></span>
    ${st.loading ? `<span class="footnote">${esc(t("pluginSaving"))}</span>` : ""}
    <button class="ghost small" data-action="pluginReload">${esc(t("pluginRetry"))}</button>
  </div>`;
  let content = "";
  if (st.tab === "discover") {
    content = `${filters}<div id="plugin-results">${pluginPicksMarkup()}<div class="plugin-section-title"><h2>${esc(t("pluginAllPlugins"))}</h2><span class="footnote">${pluginCatalog().length}</span></div>${pluginResultsMarkup()}</div>`;
  } else {
    content = pluginInstalledMarkup();
  }
  const banner = st.error && !st.consent && !st.removeId && !st.hostConfirm
    ? `<div class="card plugin-banner danger"><b>${esc(t("pluginError"))}</b><span>${esc(st.error)}</span><button class="ghost small" data-action="pluginReload">${esc(t("pluginRetry"))}</button></div>`
    : "";
  const restart = st.restartNeeded
    ? `<div class="card plugin-banner warn"><b>${esc(t("pluginRestartNeeded"))}</b><span class="spacer"></span><button class="btn small" data-action="pluginRestart">${esc(t("pluginRestart"))}</button></div>`
    : "";
  const offline = !gatewayOn
    ? `<div class="card plugin-banner"><b>${esc(t("pluginGatewayOff"))}</b><span>${esc(t("pluginGatewayOffBody"))}</span><span class="spacer"></span><button class="btn small" data-action="gatewayStart">${esc(t("pluginTurnOn"))}</button></div>`
    : "";
  const sourceErrors = st.sourceErrors && st.sourceErrors.length
    ? `<div class="footnote plugin-source-errors"><b>${esc(t("pluginSourceErrors"))}</b>${st.sourceErrors
        .map((error) => {
          const name = error.source_name || error.source_url || error.source_id || "";
          const message = error.message || "";
          return `<div>${esc(name)}${message ? `: ${esc(message)}` : ""}</div>`;
        })
        .join("")}</div>`
    : "";
  return `
  ${pageHead("melon tools", t("plugins"), t("pluginsSub"))}
  ${banner}${restart}${offline}
  ${pluginHostCard()}
  ${sourceErrors}
  ${tabs}
  ${toolbar}
  ${content}
  ${pluginDetailsModal()}
  ${pluginConsentModal()}
  ${pluginRemoveModal()}
  ${pluginHostModal()}
  ${pluginConfigModal()}`;
}

function pluginDemoData() {
  const mk = (id, name, description, tags, extra = {}) => Object.assign({
    id, name, description, tags, version: "1.0.0", author: "Melon", installed: false,
    enabled: false, effective_enabled: false, registered: false, update_available: false,
    source_id: "official", source_name: "Official",
    source_url: "https://raw.githubusercontent.com/router-for-me/CLIProxyAPI-Plugins-Store/main/registry.json",
  }, extra);
  return [
    mk("jshandler", "JS Handler", "Custom JavaScript request and response hooks.", ["Interceptor"]),
    mk("codex-token-usage", "Codex Token Usage", "Tracks token usage for Codex requests.", ["Usage"]),
    mk("github-copilot", "GitHub Copilot", "Adds GitHub Copilot as a provider.", ["Provider"]),
    mk("model-router", "Model Router", "Routes model aliases by rules.", ["Scheduler"]),
  ];
}

Object.assign(A, {
  async pluginLoad() {
    const st = pluginState();
    if (st.loading) return;
    st.loading = true;
    st.error = null;
    if (S.section === "plugins") render();
    try {
      if (typeof IS_TAURI !== "undefined" && !IS_TAURI) {
        st.prefs = { hostEnabled: false, registryUrl: "https://raw.githubusercontent.com/vanich-git/MelonTools/main/registry/registry.json", pluginsDir: "%APPDATA%\\MelonTools\\gateway\\plugins" };
        st.catalog = pluginDemoData();
        st.installed = [];
        st.sources = [];
        st.sourceErrors = [];
      } else {
        const [prefs, store, installed] = await Promise.all([
          inv("plugins_prefs"),
          inv("plugins_store"),
          inv("plugins_installed"),
        ]);
        st.prefs = prefs || null;
        const seen = new Set();
        st.catalog = ((store && store.plugins) || []).filter((entry) => {
          if (!entry || !entry.id || seen.has(entry.id)) return false;
          seen.add(entry.id);
          return true;
        });
        st.installed = (installed && installed.plugins) || [];
        st.sources = (store && store.sources) || [];
        st.sourceErrors = (store && store.source_errors) || [];
        if (installed && typeof installed.plugins_enabled === "boolean" && st.prefs) {
          st.prefs.hostEnabled = installed.plugins_enabled;
        }
        st.restartNeeded = !!(S.status && S.status.running)
          && st.installed.some((entry) => entry.registered === false && entry.configured);
      }
      st.loaded = true;
    } catch (error) {
      st.error = errorText(error);
    } finally {
      st.loading = false;
      if (S.section === "plugins") render();
    }
  },

  pluginTab(tab) {
    pluginState().tab = tab === "installed" ? "installed" : "discover";
    render();
  },

  pluginFilter(filter) {
    pluginState().filter = filter || "all";
    render();
  },

  pluginSearch(value) {
    const st = pluginState();
    st.query = value || "";
    const results = document.getElementById("plugin-results");
    if (results) {
      results.innerHTML = `${pluginPicksMarkup()}<div class="plugin-section-title"><h2>${esc(t("pluginAllPlugins"))}</h2><span class="footnote">${pluginCatalog().length}</span></div>${pluginResultsMarkup()}`;
    }
  },

  pluginReload() {
    return A.pluginLoad();
  },

  pluginDetails(id) {
    const st = pluginState();
    st.detail = id;
    st.consent = null;
    st.removeId = null;
    st.hostConfirm = null;
    st.config = null;
    st.error = null;
    render();
  },

  pluginInstall(id) {
    const st = pluginState();
    st.consent = id;
    st.detail = null;
    st.removeId = null;
    st.hostConfirm = null;
    st.config = null;
    st.error = null;
    render();
  },

  async pluginConfirmInstall() {
    const st = pluginState();
    const entry = pluginFind(st.consent);
    const check = document.getElementById("plugin-consent-check");
    if (!entry) return;
    // The button is disabled for a blocked entry, but keep the guard here so a
    // stale render or a keyboard path cannot start a download that will fail.
    const blocker = pluginInstallBlocker(entry);
    if (blocker) {
      st.error = blocker;
      render();
      return;
    }
    if (!check || !check.checked) {
      st.error = t("pluginConsentTrust");
      render();
      return;
    }
    st.installing = entry.id;
    st.error = null;
    render();
    try {
      if (!st.prefs || !st.prefs.hostEnabled) {
        st.prefs = await inv("plugins_set_host", { enabled: true });
      }
      const result = await inv("plugins_install", {
        id: entry.id,
        source: entry.source_id || null,
        version: entry.update_available ? entry.version : null,
      });
      st.consent = null;
      st.detail = null;
      st.restartNeeded = !!(result && (result.restart_required || result.requires_restart));
      toast(t("pluginInstalledToast"));
      await A.pluginLoad();
    } catch (error) {
      st.error = errorText(error);
      render();
    } finally {
      st.installing = null;
      render();
    }
  },

  async pluginToggle(id) {
    const st = pluginState();
    const input = document.querySelector(`[data-action="pluginToggle"][data-id="${CSS.escape(id)}"]`);
    const enabled = !!(input && input.checked);
    try {
      await inv("plugins_set_enabled", { id, enabled });
    } catch (error) {
      // The click already flipped the checkbox, so a rejected PATCH would leave
      // the switch showing a state the engine never accepted. Revert it and
      // drop focus (render() skips repaints while a form field is focused).
      if (input) {
        input.checked = !enabled;
        if (input === document.activeElement) input.blur();
      }
      st.error = errorText(error);
      render();
      return;
    }
    const entry = pluginInstalledFind(id);
    if (entry) {
      entry.enabled = enabled;
      entry.effective_enabled = enabled;
    }
    toast(t(enabled ? "pluginEnabledToast" : "pluginDisabledToast"));
    await A.pluginLoad();
  },

  pluginRemove(id) {
    const st = pluginState();
    st.removeId = id;
    st.detail = null;
    st.consent = null;
    st.hostConfirm = null;
    st.config = null;
    st.error = null;
    render();
  },

  async pluginConfirmRemove() {
    const st = pluginState();
    if (!st.removeId) return;
    st.removing = st.removeId;
    st.error = null;
    render();
    try {
      await inv("plugins_remove", { id: st.removeId });
      st.removeId = null;
      toast(t("pluginRemovedToast"));
      await A.pluginLoad();
    } catch (error) {
      st.error = errorText(error);
      render();
    } finally {
      st.removing = null;
      render();
    }
  },

  pluginEnableHost() {
    const st = pluginState();
    st.hostConfirm = "enable";
    st.detail = null;
    st.consent = null;
    st.removeId = null;
    st.config = null;
    st.error = null;
    render();
  },

  pluginDisableHost() {
    const st = pluginState();
    st.hostConfirm = "disable";
    st.detail = null;
    st.consent = null;
    st.removeId = null;
    st.config = null;
    st.error = null;
    render();
  },

  async pluginConfirmHost() {
    const st = pluginState();
    const enable = st.hostConfirm === "enable";
    st.hostBusy = true;
    st.error = null;
    render();
    try {
      st.prefs = await inv("plugins_set_host", { enabled: enable });
      st.hostConfirm = null;
      await A.pluginLoad();
      toast(t(enable ? "pluginHostOn" : "pluginSafeMode"));
    } catch (error) {
      st.error = errorText(error);
      render();
    } finally {
      st.hostBusy = false;
      render();
    }
  },

  pluginRestart() {
    return inv("plugins_restart")
      .then(() => {
        pluginState().restartNeeded = false;
        toast(t("pluginRestarted"));
        return A.pluginLoad();
      })
      .catch((error) => {
        pluginState().error = errorText(error);
        render();
      });
  },

  pluginOpenFolder() {
    const dir = (pluginState().prefs || {}).pluginsDir;
    if (dir) inv("reveal_path", { path: dir }).catch((error) => toast(errorText(error), true));
  },

  pluginOpenUrl(url) {
    if (url) inv("open_url", { url }).catch((error) => toast(errorText(error), true));
  },

  pluginClose() {
    const st = pluginState();
    st.detail = null;
    st.consent = null;
    st.removeId = null;
    st.hostConfirm = null;
    st.config = null;
    st.error = null;
    render();
  },

  async pluginConfigure(id) {
    const st = pluginState();
    const entry = pluginInstalledFind(id) || pluginFind(id);
    st.detail = null;
    st.consent = null;
    st.config = {
      id,
      fields: (entry && entry.config_fields) || [],
      values: {},
      raw: "{}",
      enabled: !!(entry && entry.enabled),
      loading: true,
      saving: false,
      error: null,
    };
    render();
    try {
      const values = await inv("plugins_config", { id });
      st.config.values = values && typeof values === "object" && !Array.isArray(values) ? values : {};
      st.config.raw = JSON.stringify(st.config.values, null, 2);
      st.config.loading = false;
    } catch (error) {
      st.config.loading = false;
      st.config.error = errorText(error);
    }
    render();
  },

  async pluginSaveConfig() {
    const st = pluginState();
    const cfg = st.config;
    if (!cfg || cfg.saving) return;
    cfg.error = null;
    let payload = {};
    try {
      if (cfg.fields && cfg.fields.length) {
        payload = Object.assign({}, cfg.values || {});
        for (let index = 0; index < cfg.fields.length; index += 1) {
          const field = cfg.fields[index];
          const name = String(field.name || "");
          const node = document.getElementById(`plugin-cfg-${index}`);
          if (!node) continue;
          const type = String(field.type || "string");
          if (type === "boolean") {
            payload[name] = !!node.checked;
          } else if (type === "integer") {
            if (String(node.value).trim() === "") throw new Error(`${name}: ${t("pluginNumber")}`);
            const value = Number(node.value);
            if (!Number.isInteger(value)) throw new Error(`${name}: ${t("pluginNumber")}`);
            payload[name] = value;
          } else if (type === "number") {
            const value = Number(node.value);
            if (!Number.isFinite(value)) throw new Error(`${name}: ${t("pluginNumber")}`);
            payload[name] = value;
          } else if (type === "array" || type === "object") {
            const value = JSON.parse(node.value);
            const wanted = type === "array" ? Array.isArray(value) : (value && typeof value === "object" && !Array.isArray(value));
            if (!wanted) throw new Error(`${name}: ${t("pluginJson")}`);
            payload[name] = value;
          } else {
            payload[name] = node.value;
          }
        }
      } else {
        const raw = document.getElementById("plugin-config-raw");
        const value = JSON.parse(raw ? raw.value : "{}");
        if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(t("pluginJson"));
        payload = value;
      }
    } catch (error) {
      cfg.error = String(error && error.message ? error.message : error);
      render();
      return;
    }
    cfg.saving = true;
    render();
    try {
      const enabledNode = document.getElementById("plugin-config-enabled");
      const enabled = enabledNode ? !!enabledNode.checked : cfg.enabled;
      await inv("plugins_save_config", { id: cfg.id, config: payload, enabled });
      st.config = null;
      toast(t("pluginSavedToast"));
      await A.pluginLoad();
    } catch (error) {
      cfg.saving = false;
      cfg.error = errorText(error);
      render();
    }
  },
});
