// Melon Tools — shared pure helpers (W6). No DOM access at load time and
// no state mutation: the static check loads this file standalone to prove
// that ids stay inert when they travel through data-* attributes (W3).

function fmt(text, values) {
  return text.replace(/\{(\w+)\}/g, (_, k) => (values[k] !== undefined ? values[k] : "{" + k + "}"));
}
function esc(value) {
  return String(value === null || value === undefined ? "" : value)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    // Ids and paths land inside single-quoted onclick attributes.
    .replace(/'/g, "&#39;");
}

// Tauri rejects with a string, but keep the message for Error-like values.
function errorText(error) {
  if (error === null || error === undefined) return String(error);
  if (typeof error === "string") return error;
  if (typeof error.message === "string") return error.message;
  try {
    return JSON.stringify(error);
  } catch {
    return String(error);
  }
}

// MARK: - Formatting

function nowRef() { return Date.now() / 1000; }

function round(value) {
  return value === null || value === undefined ? "—" : `${Math.round(value)}%`;
}

// Time units follow the UI language (same pattern as claudeResetText).
function unit(en, ru) {
  return S.lang === "en" ? en : ru;
}

function resetText(unixTs) {
  if (!unixTs) return t("onceReset");
  const secs = unixTs - nowRef();
  if (secs <= 0) return t("resetNow");
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${t("resetIn")} ${mins} ${unit("min", "мин")}`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${t("resetIn")} ${hours} ${unit("h", "ч")} ${mins % 60} ${unit("min", "мин")}`;
  const days = Math.floor(hours / 24);
  return `${t("resetIn")} ${days} ${unit("d", "дн")} ${hours % 24} ${unit("h", "ч")}`;
}

// «1 сброс», «2 сброса», «5 сбросов» — Russian plural rule; English has two forms.
function resetCountLabel(count) {
  const n = Math.max(0, Number(count) || 0);
  if (S.lang === "en") return n === 1 ? "1 reset" : `${n} resets`;
  const mod10 = n % 10;
  const mod100 = n % 100;
  let noun = "сбросов";
  if (mod10 === 1 && mod100 !== 11) noun = "сброс";
  else if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) noun = "сброса";
  return `${n} ${noun}`;
}

// Claude usage resets arrive as RFC-3339; render them relative like the
// account quota captions, in the current UI language.
function claudeResetText(iso) {
  if (!iso) return "—";
  const ts = Date.parse(iso);
  if (Number.isNaN(ts)) return esc(iso);
  const secs = (ts - Date.now()) / 1000;
  if (secs <= 0) return t("resetNow");
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${t("resetIn")} ${mins} ${unit("min", "мин")}`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${t("resetIn")} ${hours} ${unit("h", "ч")} ${mins % 60} ${unit("min", "мин")}`;
  const days = Math.floor(hours / 24);
  return `${t("resetIn")} ${days} ${unit("d", "дн")} ${hours % 24} ${unit("h", "ч")}`;
}

// RFC-3339 timestamp → "N с / N мин / N ч" since it (reuses ageText).
function claudeAgeText(iso) {
  const ts = Date.parse(iso);
  if (Number.isNaN(ts)) return "—";
  return ageText(ts / 1000);
}

function ageText(unixTs) {
  if (!unixTs) return t("never");
  const secs = nowRef() - unixTs;
  if (secs < 60) return `${Math.max(0, Math.floor(secs))} ${unit("s", "с")}`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins} ${unit("min", "мин")}`;
  return `${Math.floor(mins / 60)} ${unit("h", "ч")} ${mins % 60} ${unit("min", "мин")}`;
}

function quotaTint(percent) {
  if (percent === null || percent === undefined) return "";
  if (percent <= 5) return "danger";
  if (percent <= 25) return "warn";
  return "ok";
}

function finiteNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

/// Human byte size in the language the app is running in. The macOS build
/// prints `3,52 ГБ` for Russian and `3.52 GB` for English, so the unit names
/// and the decimal separator follow `S.lang` instead of staying ASCII-only.
function formatBytes(bytes, fixedDigits) {
  const n = Number(bytes);
  const ru = typeof S !== "undefined" && S && S.lang === "ru";
  const units = ru ? ["Б", "КБ", "МБ", "ГБ", "ТБ"] : ["B", "KB", "MB", "GB", "TB"];
  const separator = ru ? "," : ".";
  if (!Number.isFinite(n) || n <= 0) return "0 " + units[0];
  const steps = [1, 1024, 1048576, 1073741824, 1099511627776];
  let unit = steps.length - 1;
  while (unit > 0 && n < steps[unit]) unit -= 1;
  // Gigabytes and terabytes carry two decimals on macOS, megabytes one; a few
  // places (the "%.1f GB total" header) ask for a single decimal on purpose.
  const digits = typeof fixedDigits === "number" ? fixedDigits : unit >= 3 ? 2 : unit === 0 ? 0 : 1;
  const text = (n / steps[unit]).toFixed(digits).replace(".", separator);
  return text + " " + units[unit];
}

/// Download states come from Rust's `DownloadStatus` enum, which serializes as
/// lower snake case. Anything else (`downloading` vs `Downloading`) silently
/// disabled Cancel, the active count and the progress bar.
const DOWNLOAD_ACTIVE_STATES = ["queued", "downloading", "paused"];

function isDownloadActive(download) {
  return !!download && DOWNLOAD_ACTIVE_STATES.includes(download.status);
}

/// Parses a numeric input so that 0 survives. `Number(value) || fallback`
/// turned a deliberate 0 (temperature, top-p, seed) into the default.
function numberOrNull(value) {
  if (value === null || value === undefined) return null;
  const raw = String(value).trim();
  if (raw === "") return null;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : null;
}

/// Minimal Markdown renderer for model answers.
///
/// The test modal printed the raw text, so `### **Заголовок**` reached the user
/// as literal hashes and asterisks. Everything is escaped first, then a small
/// block parser adds structure — no HTML from the model ever reaches the DOM.
function renderMarkdown(source) {
  const text = String(source == null ? "" : source);
  const escapeHtml = (value) =>
    value
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");

  // Tokenize code and links before emphasis: Markdown markers in code or
  // URLs must stay literal. Raw HTML is never trusted, including model cards.
  const inline = (value) => {
    const tokens = [];
    const token = (html) => { const index = tokens.push(html) - 1; return `\u0000${index}\u0000`; };
    let out = String(value).replace(/\u0000/g, "");
    out = out.replace(/`([^`]+)`/g, (_, code) => token(`<code class="md-code">${escapeHtml(code)}</code>`));
    out = out.replace(/!?\[([^\]]+)\]\(([^\s)]+)(?:\s+"[^"]*")?\)/g, (whole, label, rawURL) => {
      // Images remain labelled text: no remote tracking pixels in model output.
      if (whole.startsWith("!")) return token(escapeHtml(label));
      let url;
      try { url = new URL(rawURL); } catch (_) { return token(escapeHtml(label)); }
      if (!["https:", "http:"].includes(url.protocol)) return token(escapeHtml(label));
      return token(`<a href="${escapeHtml(url.href)}" target="_blank" rel="noopener noreferrer">${escapeHtml(label)}</a>`);
    });
    out = escapeHtml(out);
    out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    out = out.replace(/(^|[^*])\*([^*]+)\*(?!\*)/g, "$1<em>$2</em>");
    return out.replace(/\u0000(\d+)\u0000/g, (_, index) => tokens[Number(index)] || "");
  };
  const tableCells = (line) => line.trim().replace(/^\|/, "").replace(/\|$/, "").split(/(?<!\\)\|/).map(cell => cell.trim().replace(/\\\|/g, "|"));
  const tableSeparator = (line) => {
    const cells = tableCells(line);
    return cells.length > 1 && cells.every(cell => /^:?-{3,}:?$/.test(cell));
  };

  const lines = text.split("\n");
  const html = [];
  let listType = null;
  let inCode = false;
  let codeBuffer = [];

  const closeList = () => {
    if (listType) {
      html.push(`</${listType}>`);
      listType = null;
    }
  };

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const trimmed = line.trim();

    if (trimmed.startsWith("```")) {
      if (inCode) {
        html.push(`<pre class="md-pre"><code>${escapeHtml(codeBuffer.join("\n"))}</code></pre>`);
        codeBuffer = [];
        inCode = false;
      } else {
        closeList();
        inCode = true;
      }
      continue;
    }
    if (inCode) {
      codeBuffer.push(line);
      continue;
    }

    if (trimmed.includes("|") && index + 1 < lines.length && tableSeparator(lines[index + 1])) {
      closeList();
      const headers = tableCells(line);
      html.push(`<div class="md-table-wrap"><table class="md-table"><thead><tr>${headers.map(cell => `<th>${inline(cell)}</th>`).join("")}</tr></thead><tbody>`);
      index += 1;
      while (index + 1 < lines.length && lines[index + 1].trim().includes("|") && lines[index + 1].trim()) {
        const cells = tableCells(lines[++index]);
        html.push(`<tr>${headers.map((_, column) => `<td>${inline(cells[column] || "")}</td>`).join("")}</tr>`);
      }
      html.push("</tbody></table></div>");
      continue;
    }

    if (!trimmed) {
      closeList();
      continue;
    }

    if (trimmed === "---" || trimmed === "***" || trimmed === "___") {
      closeList();
      html.push('<hr class="md-rule">');
      continue;
    }

    const heading = /^(#{1,6})\s+(.*)$/.exec(trimmed);
    if (heading) {
      closeList();
      const level = Math.min(heading[1].length + 2, 6);
      html.push(`<h${level} class="md-h">${inline(heading[2])}</h${level}>`);
      continue;
    }

    if (trimmed.startsWith(">")) {
      closeList();
      html.push(`<blockquote class="md-quote">${inline(trimmed.slice(1).trim())}</blockquote>`);
      continue;
    }

    const bullet = /^[-*•+]\s+(.*)$/.exec(trimmed);
    if (bullet) {
      if (listType !== "ul") {
        closeList();
        html.push('<ul class="md-list">');
        listType = "ul";
      }
      html.push(`<li>${inline(bullet[1])}</li>`);
      continue;
    }

    const numbered = /^(\d+[.)])\s+(.*)$/.exec(trimmed);
    if (numbered) {
      if (listType !== "ol") {
        closeList();
        html.push('<ol class="md-list">');
        listType = "ol";
      }
      html.push(`<li>${inline(numbered[2])}</li>`);
      continue;
    }

    closeList();
    html.push(`<p class="md-p">${inline(trimmed)}</p>`);
  }

  if (inCode && codeBuffer.length) {
    html.push(`<pre class="md-pre"><code>${escapeHtml(codeBuffer.join("\n"))}</code></pre>`);
  }
  closeList();
  return html.join("");
}
