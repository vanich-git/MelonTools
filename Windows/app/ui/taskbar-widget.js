// Reuse the island's cached, non-secret snapshot. This window never changes routing.
(function () {
  "use strict";
  var api = window.melon;
  var active = true, pending = false, lang = "ru";
  var button = document.getElementById("widget");
  var strings = {
    ru: { open: "Открыть Melon Tools", running: "API вкл.", stopped: "API выкл.", unavailable: "Нет связи", hour: "5ч", week: "7д", accounts: "Аккаунтов", quota: "Остаток квот пула" },
    en: { open: "Open Melon Tools", running: "API on", stopped: "API off", unavailable: "Unavailable", hour: "5h", week: "7d", accounts: "Accounts", quota: "Pool quota remaining" }
  };
  function text(id, value) { document.getElementById(id).textContent = value; }
  function percent(value) { return typeof value === "number" && Number.isFinite(value) ? Math.round(Math.max(0, value)) + "%" : "—"; }
  function render(snapshot) {
    lang = snapshot.lang === "en" ? "en" : "ru";
    var tr = strings[lang], codex = snapshot.codex || {}, running = !!(snapshot.gateway && snapshot.gateway.running);
    document.documentElement.lang = lang;
    text("api-status", running ? tr.running : tr.stopped);
    document.getElementById("api-dot").className = running ? "running" : "";
    text("hour-label", tr.hour); text("week-label", tr.week);
    text("hour-value", percent(codex.hourly)); text("week-value", percent(codex.weekly));
    // Values are pooled percentage points, like the existing island, not averages.
    var title = "Melon Tools · " + (running ? tr.running : tr.stopped) + "\n" + tr.quota + ": " + tr.hour + " " + percent(codex.hourly) + " / " + tr.week + " " + percent(codex.weekly) + "\n" + tr.accounts + ": " + (codex.accounts || 0) + "\n" + tr.open;
    button.title = title; button.setAttribute("aria-label", title);
  }
  async function refresh() {
    if (!active || pending || !api || !api.available) return;
    pending = true;
    try { render(await api.invoke("island_snapshot")); }
    catch (_) {
      var tr = strings[lang]; text("api-status", tr.unavailable);
      text("hour-value", "—"); text("week-value", "—");
      document.getElementById("api-dot").className = "failed";
      button.title = "Melon Tools · " + tr.unavailable + "\n" + tr.open;
      button.setAttribute("aria-label", button.title);
    } finally { pending = false; }
  }
  button.addEventListener("click", async function () {
    if (!api || !api.available) return;
    try { await api.invoke("island_open_main"); }
    catch (_) { text("api-status", strings[lang].unavailable); }
  });
  if (api && api.available && typeof api.listen === "function") {
    api.listen("taskbar-widget-visibility", function (event) {
      active = event.payload === true;
      if (active) refresh();
    }).catch(function () {});
  }
  refresh();
  setInterval(refresh, 3000);
})();
