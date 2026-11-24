// Hugging Face catalog: pure presentation helpers shared by live and preview UI.
const HF_COPY = {
  recommended: ["Рекомендуемые", "Recommended"], downloads: ["Загрузки", "Downloads"], likes: ["Отметки нравится", "Likes"], updated: ["Недавно обновлённые", "Recently updated"],
  search: ["Поиск моделей в Hugging Face", "Search Hugging Face models"], popular: ["Популярное на Hugging Face", "Trending on Hugging Face"], results: ["Результаты Hugging Face", "Hugging Face results"],
  options: ["Варианты загрузки", "Download options"], device: ["Это устройство", "This device"], details: ["Подробности", "Details"], variant: ["Вариант GGUF", "GGUF variant"],
  compatible: ["Только подходящие варианты", "Only compatible variants"], estimate: ["Предварительная оценка для контекста 8192. Точный объём зависит от архитектуры и настроек.", "Preliminary estimate at 8192 context. Actual memory depends on architecture and settings."],
  noCompatible: ["Нет вариантов, подходящих по предварительной оценке. Отключите фильтр, чтобы увидеть все.", "No variants fit the preliminary estimate. Turn off the filter to see all."],
  readmeMissing: ["README недоступен. Откройте карточку модели на Hugging Face.", "README is unavailable. Open the model card on Hugging Face."],
  license: ["Лицензия", "License"], architecture: ["Архитектура", "Architecture"], parameters: ["Параметры", "Parameters"], format: ["Формат", "Format"], more: ["Загрузить ещё", "Load more"],
  split: ["Разбитый GGUF: загрузите весь набор через Hugging Face и импортируйте. Загрузка отдельной части здесь отключена.", "Split GGUF: download the full set from Hugging Face and import it. Individual shard downloads are disabled here."],
  folder: ["Этот файл находится в подпапке. Загрузите его с Hugging Face и импортируйте.", "This file is in a subfolder. Download it from Hugging Face and import it."],
  select: ["Выберите модель, чтобы увидеть описание и варианты загрузки", "Select a model to see details and download options"],
  unavailable: ["Размер неизвестен", "Size unknown"], updatedAt: ["Обновлено", "Updated"], matches: ["моделей", "models"],
};
function hfText(key) { const pair = HF_COPY[key]; return pair ? pair[S.lang === "ru" ? 0 : 1] : key; }
function hfRepositoryID(input) {
  let text = String(input || "").trim();
  if (/^https?:\/\//i.test(text)) {
    try { const url = new URL(text); if (url.hostname !== "huggingface.co") return null; text = url.pathname.slice(1); } catch (_) { return null; }
  }
  const match = /^([\w.-]+\/[\w.-]+)(?:\/(?:tree|blob|resolve)\/.*)?$/.exec(text.replace(/\/$/, ""));
  return match && !match[1].split("/").some(part => part === "." || part === "..") ? match[1] : null;
}
function hfName(repo) { return repo.displayName || String(repo.id || "").split("/").pop(); }

// Publisher avatars. The Hub exposes one avatar URL per owner, and a page of
// thirty rows usually contains a dozen distinct publishers, so the whole page
// is resolved in one backend call and the result is cached for a week. The
// initials tile stays as the placeholder until the image has loaded; a failed
// image falls back to it instead of showing a broken icon.
const HF_AVATAR_STORAGE = "melontools.hfAvatars";
const HF_AVATAR_TTL = 7 * 24 * 60 * 60 * 1000;
let hfAvatarEntries = null;
let hfAvatarPending = null;

function hfAvatarStore() {
  if (hfAvatarEntries) return hfAvatarEntries;
  hfAvatarEntries = {};
  try {
    const raw = JSON.parse(localStorage.getItem(HF_AVATAR_STORAGE) || "{}") || {};
    const now = Date.now();
    Object.keys(raw).forEach((owner) => {
      const entry = raw[owner];
      if (entry && typeof entry.url === "string" && now - Number(entry.at || 0) < HF_AVATAR_TTL) hfAvatarEntries[owner] = entry;
    });
  } catch (_) {
    hfAvatarEntries = {};
  }
  return hfAvatarEntries;
}

function hfAvatarSave() {
  try { localStorage.setItem(HF_AVATAR_STORAGE, JSON.stringify(hfAvatarEntries || {})); } catch (_) { /* storage full or disabled */ }
}

function hfAvatar(repo, large = false) {
  const author = repo.author || String(repo.id || "").split("/")[0];
  // Keep fallback avatars inside the app palette: teal, cyan, blue, violet.
  const hue = 175 + (Array.from(author).reduce((sum, c) => sum + c.charCodeAt(0), 0) % 95);
  const entry = hfAvatarStore()[author];
  if (entry) {
    return `<img class="hf-avatar image${large ? " large" : ""}" src="${esc(entry.url)}" alt="" loading="lazy" decoding="async" referrerpolicy="no-referrer" style="--avatar-hue:${hue}">`;
  }
  return `<span class="hf-avatar${large ? " large" : ""}" data-hf-avatar="${esc(author)}" style="--avatar-hue:${hue}" aria-hidden="true">${esc(author.slice(0, 2).toUpperCase())}</span>`;
}

/// Swaps the initials tiles of a rendered list for the resolved images without
/// a full re-render, so scroll position and focus survive.
function hfApplyAvatars(root) {
  const store = hfAvatarStore();
  root.querySelectorAll("[data-hf-avatar]").forEach((el) => {
    const entry = store[el.dataset.hfAvatar];
    if (!entry) return;
    const image = document.createElement("img");
    image.className = `${el.className} image`;
    image.src = entry.url;
    image.alt = "";
    image.loading = "lazy";
    image.decoding = "async";
    image.referrerPolicy = "no-referrer";
    const hue = el.style.getPropertyValue("--avatar-hue");
    if (hue) image.style.setProperty("--avatar-hue", hue);
    image.addEventListener("error", () => { image.replaceWith(el); });
    el.replaceWith(image);
  });
}

function hfLoadAvatars(root) {
  if (!root || root.querySelectorAll("[data-hf-avatar]").length === 0 || !IS_TAURI) return;
  const store = hfAvatarStore();
  const owners = Array.from(new Set(Array.from(root.querySelectorAll("[data-hf-avatar]")).map((el) => el.dataset.hfAvatar).filter((owner) => owner && !store[owner])));
  if (!owners.length) return;
  if (hfAvatarPending) {
    hfAvatarPending.then(() => { if (root.isConnected) hfLoadAvatars(root); }).catch(() => {});
    return;
  }
  hfAvatarPending = inv("local_ai_hf_avatars", { owners })
    .then((map) => {
      const now = Date.now();
      owners.forEach((owner) => {
        const url = map && map[owner];
        if (url) store[owner] = { url, at: now };
      });
      hfAvatarSave();
      hfApplyAvatars(root);
    })
    .catch(() => { /* offline: keep the initials */ })
    .then(() => { hfAvatarPending = null; });
}
function hfDate(value) {
  const date = new Date(value);
  return value && Number.isFinite(date.getTime()) ? date.toLocaleDateString(S.lang === "ru" ? "ru-RU" : "en-US", { year: "numeric", month: "short", day: "numeric" }) : "";
}
function hfStats(repo) {
  const locale = S.lang === "en" ? "en-US" : "ru-RU";
  return `<span>${localAiIcon("download", 11)} ${Number(repo.downloads || 0).toLocaleString(locale)}</span><span>${localAiIcon("heart", 11)} ${Number(repo.likes || 0).toLocaleString(locale)}</span>${hfDate(repo.lastModified) ? `<span>${esc(hfDate(repo.lastModified))}</span>` : ""}`;
}
function hfFits(file) { return file.size > 0 && !/-\d{5}-of-\d{5}\.gguf$/i.test(file.name || "") && ["Recommended", "Fits with limitations"].includes(file.estimation && file.estimation.recommendation); }
function hfDownloadIssue(file) {
  if (/-\d{5}-of-\d{5}\.gguf$/i.test(file.name)) return hfText("split");
  if (/[\\/]/.test(file.name)) return hfText("folder");
  return "";
}
function hfVariants(repo) { return (repo.ggufFiles || []).filter(file => !S.localAi.hfCompatibleOnly || hfFits(file)); }
function hfRecommendedFile(repo) {
  const files = hfVariants(repo);
  return files.find(file => file.quantization === "Q4_K_M" && hfFits(file) && !hfDownloadIssue(file) && !/mmproj/i.test(file.name))
    || files.find(file => hfFits(file) && !hfDownloadIssue(file) && !/mmproj/i.test(file.name));
}
function hfSelectedFile(repo) {
  const files = hfVariants(repo);
  return files.find(file => file.name === S.localAi.hfSelectedFile) || hfRecommendedFile(repo)
    || files.find(file => file.quantization === "Q4_K_M" && !hfDownloadIssue(file) && !/mmproj/i.test(file.name))
    || files.find(file => !hfDownloadIssue(file) && !/mmproj/i.test(file.name)) || files[0];
}
function hfCatalogResults() {
  const state = S.localAi, results = state.catalogResults || [];
  if (state.catalogLoading && !results.length) return `<div class="hf-empty" role="status"><span class="spinner-dot"></span>${esc(t("loading"))}</div>`;
  return `${state.catalogError ? `<div class="hf-error" role="alert">${esc(state.catalogError)}<button class="ghost small" data-action="localAiHfSearch">${esc(t("retry"))}</button></div>` : ""}
    <div class="hf-repo-list" aria-label="Hugging Face">${results.map(repo => `<button class="hf-repo ${state.selectedRepoId === repo.id ? "selected" : ""}" data-action="localAiSelectRepo" data-id="${esc(repo.id)}" aria-pressed="${state.selectedRepoId === repo.id}">
      ${hfAvatar(repo)}<span class="hf-repo-copy"><strong>${esc(hfName(repo))}</strong><span class="hf-repo-description">${esc(repo.description || repo.author || String(repo.id).split("/")[0])}</span><span class="repo-stats">${hfStats(repo)}</span></span></button>`).join("")}</div>
    ${!results.length && !state.catalogLoading && !state.catalogError ? `<div class="hf-empty">${esc(t("localAiHfEmptyAfterSearch"))}</div>` : ""}
    ${results.length && state.catalogHasMore ? `<button class="ghost hf-more" data-action="localAiHfMore" ${state.catalogLoadingMore ? "disabled" : ""}>${esc(state.catalogLoadingMore ? t("loading") : hfText("more"))}</button>` : ""}`;
}
function hfCatalogDetail() {
  const state = S.localAi, repo = state.repoDetails;
  if (state.repoDetailsLoading) return `<div class="hf-empty" role="status"><span class="spinner-dot"></span>${esc(t("localAiFilesLoading"))}</div>`;
  if (state.repoDetailsError) return `<div class="hf-empty hf-error" role="alert">${esc(state.repoDetailsError)}<button class="ghost small" data-action="localAiSelectRepo" data-id="${esc(state.selectedRepoId)}">${esc(t("retry"))}</button></div>`;
  if (!repo) return `<div class="hf-empty">${localAiIcon("sidebar", 28)}<p>${esc(hfText("select"))}</p></div>`;
  const file = hfSelectedFile(repo), files = hfVariants(repo), recommended = hfRecommendedFile(repo);
  const active = file && (state.downloads || []).some(dl => dl.repoId === repo.id && dl.filename === file.name && isDownloadActive(dl));
  const issue = file && hfDownloadIssue(file);
  const meta = [[hfText("format"), "GGUF"], [hfText("architecture"), repo.architecture], [hfText("parameters"), repo.parameters ? new Intl.NumberFormat(S.lang, { notation: "compact", maximumFractionDigits: 1 }).format(repo.parameters) : null], [hfText("license"), repo.license]].filter(pair => pair[1]);
  return `<div class="hf-detail-content"><header class="hf-detail-header">${hfAvatar(repo, true)}<div><h2>${esc(hfName(repo))}</h2><div class="hint mono">${esc(repo.id)}</div></div></header>
    <div class="hf-detail-meta"><div class="repo-stats">${hfStats(repo)}</div><a class="link-btn" href="https://huggingface.co/${esc(repo.id)}" target="_blank" rel="noopener noreferrer">${esc(t("localAiOpenHf"))} ↗</a></div>
    <section class="hf-section"><div class="hf-section-heading"><h3>${esc(hfText("options"))}</h3><span class="hint">${esc(hfText("device"))}</span></div><div class="hf-surface">
      <label class="hf-fit-filter"><input type="checkbox" data-action="localAiHfCompatible" data-on="change" ${state.hfCompatibleOnly ? "checked" : ""}>${esc(hfText("compatible"))}</label>
      ${file ? `<details class="hf-select hf-select-wide"><summary aria-label="${esc(hfText("variant"))}">
        <span class="hf-select-main"><strong class="mono">${esc(file.quantization || file.name)}</strong><span class="hf-select-size">${file.size ? formatBytes(file.size) : hfText("unavailable")}</span></span>
        ${recommended && recommended.name === file.name ? `<span class="hf-mini-badge">${esc(hfText("recommended"))}</span>` : ""}${localAiIcon("chevron", 11)}
      </summary><div class="local-ai-menu-panel hf-select-panel hf-variant-panel">${files.map(item => `<button class="local-ai-menu-item hf-variant-item ${item.name === file.name ? "selected" : ""}" value="${esc(item.name)}" data-action="localAiHfVariant">
        <span class="hf-variant-copy"><span class="hf-variant-quant mono">${esc(item.quantization || item.name)}</span><span class="hf-variant-file">${esc(item.name)}</span></span>
        <span class="hf-variant-meta">${item.size ? formatBytes(item.size) : hfText("unavailable")}${recommended && item.name === recommended.name ? `<span class="hf-mini-badge">${esc(hfText("recommended"))}</span>` : ""}${item.name === file.name ? localAiIcon("check", 12) : ""}</span>
      </button>`).join("")}</div></details>
      <div class="hf-file-name mono">${esc(file.name)}</div><div class="hf-download-row">${issue ? `<span class="hint">${esc(t("localAiUnknown"))}</span>` : localAiCompatBadge(file)}<button class="btn small" data-action="localAiDownloadQuant" data-repo="${esc(repo.id)}" data-file="${esc(file.name)}" data-url="${esc(file.downloadUrl || "")}" data-size="${Number(file.size) || 0}" data-sha="${esc(file.sha256 || "")}" ${active || issue ? "disabled" : ""}>${localAiIcon("download", 13)} ${esc(active ? t("localAiDownloading") : t("localAiDownload"))}${file.size ? ` · ${formatBytes(file.size)}` : ""}</button></div>${issue ? `<p class="hf-note">${esc(issue)}</p>` : ""}`
      : `<p class="muted">${esc((repo.ggufFiles || []).length ? hfText("noCompatible") : t("localAiNoFiles"))}</p>`}<p class="hf-note">${esc(hfText("estimate"))}</p>
    </div></section><section class="hf-section"><h3>${esc(hfText("details"))}</h3><div class="hf-surface">${repo.description ? `<p class="hf-description">${esc(repo.description)}</p>` : ""}<dl class="hf-metadata">${meta.map(([label, value]) => `<div><dt>${esc(label)}</dt><dd>${esc(value)}</dd></div>`).join("")}</dl>${(repo.tags || []).length ? `<div class="hf-tags">${repo.tags.filter(tag => !tag.includes(":" )).slice(0, 10).map(tag => `<span>${esc(tag)}</span>`).join("")}</div>` : ""}</div></section>
    <section class="hf-section"><h3>README</h3><div class="hf-surface hf-readme markdown-body">${repo.readme ? renderMarkdown(htmlToMarkdown(repo.readme.replace(/^---\s*\n[\s\S]*?\n---\s*\n/, ""))) : `<p class="muted">${esc(hfText("readmeMissing"))}</p>`}</div></section></div>`;
}
function hfRefreshCatalog() {
  const results = document.getElementById("hf-results"), detail = document.getElementById("hf-detail"), summary = document.getElementById("hf-search-summary");
  if (!results || !detail) return;
  const top = results.scrollTop, detailTop = detail.scrollTop;
  results.innerHTML = hfCatalogResults(); detail.innerHTML = hfCatalogDetail();
  results.scrollTop = top; detail.scrollTop = detailTop;
  if (summary) summary.textContent = S.localAi.catalogLoading ? t("loading") : (S.localAi.catalogQuery ? `${(S.localAi.catalogResults || []).length} ${hfText("matches")}` : hfText("popular"));
  hfLoadAvatars(results);
  hfLoadAvatars(detail);
}
