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
