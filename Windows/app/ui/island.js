// Melon HUD — the always-on-top island at the top of the screen.
//
// One snapshot command returns everything the card shows; the window itself
// resizes through `island_resize` when the pointer opens or leaves it.
(function () {
  "use strict";

  var api = window.melon;
  var mode = window.__melonMode === "expanded" ? "expanded" : "compact";
  var expanded = mode === "expanded";
  if (expanded) document.body.classList.add("island-open");
  var snap = null;
  var lang = "ru";
  var active = true;
  var inFlight = false;
  var iconsReady = false;
  var lastApiIcon = "";

  var ICONS = {
    open:
      '<svg viewBox="0 0 16 16"><rect x="2.6" y="3.6" width="10.8" height="8.8" rx="2" stroke="currentColor" fill="none" stroke-width="1.4"/><path d="M2.6 6.4h10.8" stroke="currentColor" stroke-width="1.4"/></svg>',
    pause:
      '<svg viewBox="0 0 16 16"><rect x="4.4" y="3.4" width="2.3" height="9.2" rx="1" fill="currentColor"/><rect x="9.3" y="3.4" width="2.3" height="9.2" rx="1" fill="currentColor"/></svg>',
    play:
      '<svg viewBox="0 0 16 16"><path d="M5 3.4l7.1 4.6L5 12.6z" fill="currentColor"/></svg>',
    run:
      '<svg viewBox="0 0 16 16"><path d="M4.2 3.5l6 4.5-6 4.5z" fill="currentColor"/><rect x="11.1" y="3.5" width="1.9" height="9" rx=".95" fill="currentColor"/></svg>',
    clock:
      '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="5.4" stroke="currentColor" fill="none" stroke-width="1.3"/><path d="M8 4.8v3.4l2.2 1.3" stroke="currentColor" fill="none" stroke-width="1.3" stroke-linecap="round"/></svg>'
  };

  var STRINGS = {
    ru: {
      pool: "Пул Codex",
      accounts: "Аккаунтов в пуле: %d",
      week: "Неделя",
      providers: "Провайдеры",
      connected: "Подключено",
      scheduler: "Планировщик",
      noTasks: "Нет задач",
      nextRun: "Следующий",
      runningNow: "Выполняется",
      running: "работает",
      stopped: "остановлен",
      open: "Открыть",
      pause: "Пауза",
      start: "Старт",
      run: "Запустить",
      unit: "5 ч",
      hourShort: "5ч",
      weekShort: "7д",
      minute: "мин",
      hour: "ч",
      now: "сейчас",
      collapse: "Свернуть"
    },
    en: {
      pool: "Codex pool",
      accounts: "Accounts in pool: %d",
      week: "Week",
      providers: "Providers",
      connected: "Connected",
      scheduler: "Scheduler",
      noTasks: "No tasks",
      nextRun: "Next run",
      runningNow: "Running now",
      running: "running",
      stopped: "stopped",
      open: "Open",
      pause: "Pause",
      start: "Start",
      run: "Run",
      unit: "5 h",
      hourShort: "5h",
      weekShort: "7d",
      minute: "min",
      hour: "h",
      now: "now",
      collapse: "Collapse"
    }
  };

  function $(id) {
    return document.getElementById(id);
  }

  function pct(value) {
    return value === null || value === undefined ? "—" : Math.round(value) + "%";
  }

  function relative(timestamp) {
    if (!timestamp) return "";
    var seconds = timestamp - Date.now() / 1000;
    var tr = STRINGS[lang];
    if (seconds <= 0) return tr.now;
    var minutes = Math.round(seconds / 60);
    if (minutes < 60) return minutes + " " + tr.minute;
    var hours = Math.floor(minutes / 60);
    var rest = minutes % 60;
    return rest ? hours + " " + tr.hour + " " + rest + " " + tr.minute : hours + " " + tr.hour;
  }

  function render() {
    if (!snap) return;
    lang = snap.lang === "en" ? "en" : "ru";
    var tr = STRINGS[lang];
    var gateway = snap.gateway || {};
    var codex = snap.codex || {};
    var antigravity = snap.antigravity || {};
    var scheduler = snap.scheduler || {};

    var dotClass = "dot" + (gateway.running ? " ok" : "");
    $("compact-dot").className = dotClass;
    $("head-dot").className = dotClass;

    $("compact-hour-label").textContent = tr.hourShort;
    $("compact-week-label").textContent = tr.weekShort;
    $("compact-hourly").textContent = pct(codex.hourly);
    $("compact-weekly").textContent = pct(codex.weekly);
    $("compact-accounts").textContent = codex.accounts || 0;
    var due = scheduler.due || 0;

    $("head-state").textContent = gateway.running ? tr.running : tr.stopped;
    $("head-state").className = "state" + (gateway.running ? " ok" : "");
    $("head-port").textContent = "· " + (gateway.port || 18317);

    $("pool-title").textContent = tr.pool;
    $("pool-accounts").textContent = tr.accounts.replace("%d", codex.accounts || 0);
    $("pool-quota").textContent = pct(codex.hourly);
    $("pool-unit").textContent = tr.unit;
    $("pool-week").textContent = tr.week + " " + pct(codex.weekly);

    var total = codex.max || 0;
    var fraction = total > 0 && codex.hourly !== null ? Math.min(Math.max(codex.hourly / total, 0), 1) : 0;
    var meter = $("pool-meter");
    meter.style.width = (fraction * 100).toFixed(1) + "%";
    meter.className =
      "meter-fill" + (codex.hourly !== null && codex.hourly < 15 ? " danger" : codex.hourly !== null && codex.hourly < 40 ? " warn" : "");

    $("antigravity-count").textContent = antigravity.accounts || 0;
    $("antigravity-detail").textContent = antigravity.accounts ? tr.connected : "—";
    $("providers-title").textContent = tr.providers;
    $("providers-count").textContent = snap.providers || 0;
    $("providers-detail").textContent = tr.connected;

    $("schedule-title").textContent = tr.scheduler;
    var status = $("schedule-state");
    status.className = "schedule-state";
    if (scheduler.running) {
      status.textContent = tr.runningNow;
      status.className = "schedule-state running";
    } else if (scheduler.nextRunAt) {
      status.textContent = tr.nextRun + " · " + relative(scheduler.nextRunAt);
    } else {
      status.textContent = tr.noTasks;
    }

    if (!iconsReady) {
      $("open-icon").innerHTML = ICONS.open;
      $("run-icon").innerHTML = ICONS.run;
      $("schedule-icon").innerHTML = ICONS.clock;
      iconsReady = true;
    }
    $("open-label").textContent = tr.open;
    $("run-label").textContent = tr.run;
    $("api-label").textContent = gateway.running ? tr.pause : tr.start;
    var apiIcon = gateway.running ? "pause" : "play";
    if (apiIcon !== lastApiIcon) {
      $("api-icon").innerHTML = ICONS[apiIcon];
      lastApiIcon = apiIcon;
    }
    document.documentElement.lang = lang;

    var runButton = document.querySelector('[data-act="run"]');
    if (runButton) {
      runButton.disabled = !gateway.running || due === 0 || !!scheduler.running;
    }
    var apiButton = document.querySelector('[data-act="api"]');
    if (apiButton) apiButton.disabled = false;
    var closeButton = $("close-panel");
    if (closeButton) {
      closeButton.title = tr.collapse;
      closeButton.setAttribute("aria-label", tr.collapse);
    }
  }

  var autoCollapseTimer = null;
  var autoCollapseMs = 15000;

  function stopAutoCollapse() {
    if (autoCollapseTimer) {
      window.clearTimeout(autoCollapseTimer);
      autoCollapseTimer = null;
    }
  }

  function collapsePanel() {
    stopAutoCollapse();
    if (api && api.available) {
      api.invoke("island_collapse").catch(function () {
        // The panel is already closing.
      });
    }
  }

  function scheduleAutoCollapse() {
    stopAutoCollapse();
    if (autoCollapseMs <= 0) return;
    autoCollapseTimer = window.setTimeout(collapsePanel, autoCollapseMs);
  }

  function applyAutoCollapseSetting(seconds) {
    var next = Number(seconds);
    if ([0, 5, 10, 15, 20].indexOf(next) < 0) next = 15;
    if (next === autoCollapseMs) return;
    var pending = !!autoCollapseTimer;
    autoCollapseMs = next * 1000;
    if (pending) {
      if (autoCollapseMs > 0) scheduleAutoCollapse();
      else stopAutoCollapse();
    }
  }

  function refresh() {
    if (!api || !api.available || !active || inFlight) return;
    inFlight = true;
    api
      .invoke("island_snapshot")
      .then(function (data) {
        snap = data;
        applyAutoCollapseSetting(data.islandAutoCollapseSeconds);
        render();
      })
      .catch(function () {
        // The backend is restarting; keep the last snapshot on screen.
      })
      .finally(function () {
        inFlight = false;
      });
  }

  function bind() {
    if (!api || !api.available) return;
    var island = $("island");
    if (mode === "expanded") {
      document.body.classList.add("island-open");
      island.addEventListener("mouseenter", stopAutoCollapse);
      island.addEventListener("mouseleave", scheduleAutoCollapse);
      document.addEventListener("keydown", function (event) {
        if (event.key === "Escape") collapsePanel();
      });
    } else {
      // The compact window never resizes itself. Clicking asks Rust to show
      // the already-built 420x242 panel window, so a WebView2 resize failure
      // can no longer leave an empty compact strip behind.
      island.addEventListener("click", function (event) {
        if (event.target.closest("[data-act]")) return;
        if (api && api.available) {
          api.invoke("island_expand").catch(function () {});
        }
      });
    }

    Array.prototype.forEach.call(document.querySelectorAll("[data-act]"), function (button) {
      button.addEventListener("click", function (event) {
        event.stopPropagation();
        var action = button.getAttribute("data-act");
        button.disabled = true;
        var done = function () {
          button.disabled = false;
          refresh();
        };
        if (action === "open") {
          api.invoke("island_open_main").then(done, done);
        } else if (action === "api") {
          api.invoke("island_toggle_api").then(done, done);
        } else if (action === "run") {
          api.invoke("island_run_next").then(done, done);
        } else if (action === "close") {
          api.invoke("island_collapse").then(done, done);
        }
      });
    });
  }

  if (api && api.available && api.listen) {
    api
      .listen("island-visibility", function (event) {
        active = !!event.payload;
        if (active) refresh();
      })
      .catch(function () {
        // The event API is optional; polling still works without it.
      });
  }

  bind();
  if (!api || !api.available) {
    // Browser preview: keep the layout readable without the Tauri backend.
    snap = {
      lang: "ru",
      gateway: { running: true, port: 18317 },
      codex: { accounts: 5, hourly: 500, weekly: 9, max: 500 },
      antigravity: { accounts: 2 },
      scheduler: { due: 0, nextRunAt: null, running: null },
      providers: 4
    };
    render();
    return;
  }
  refresh();
  window.setInterval(refresh, 2500);
  // Windows can move the island to another monitor or change its DPI without
  // resizing it; re-centre periodically so it does not drift off-screen.
  window.setInterval(function () {
    if (active) {
      api.invoke("island_reposition").catch(function () {});
    }
  }, 15000);
})();
