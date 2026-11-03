// Melon Tools — narrow Tauri IPC bridge (W9).
//
// tauri.conf.json sets `withGlobalTauri: false`, so `window.__TAURI__` is not
// injected. The renderer reaches the runtime only through
// window.__TAURI_INTERNALS__.invoke, wrapped here behind a command whitelist.
// An injected script that gains DOM access still cannot call arbitrary
// commands: anything outside the list fails closed.
//
// Outside Tauri (plain browser preview) `available` is false and app.js falls
// back to its demo mock — this file must never throw in that case.
(function () {
  "use strict";

  // Every command the UI is allowed to invoke, plus the two event-plugin
  // commands used by window.melon.listen for tray events.
  var COMMANDS = [
    "app_info",
    "support_bundle",
    "settings_get",
    "settings_set",
    "vault_list",
    "quota_history",
    "quota_refresh",
    "reset_activate",
    "gateway_status",
    "gateway_start",
    "gateway_stop",
    "gateway_sync",
    "gateway_check",
    "gateway_models",
    "gateway_recent_calls",
    "switch_account",
    "import_current_auth",
    "import_json_accounts",
    "account_refresh_tokens",
    "save_reserves",
    "delete_account",
    "device_login_start",
    "device_login_poll",
    "routing_state",
    "set_routing_strategy",
    "move_priority",
    "reset_priority",
    "set_account_role",
    "codex_route_status",
    "catalog_sync",
    "codex_route_apply",
    "codex_route_remove",
    "codex_app_status",
    "codex_app_set_path",
    "codex_app_forget_path",
    "codex_app_open",
    "codex_pool_models",
    "codex_models_refresh",
    "save_account_models",
    "set_pool_model",
    "apply_codex_models",
    "bridge_status",
    "bridge_launch_codex",
    "scheduler_list",
    "scheduler_save",
    "scheduler_delete",
    "scheduler_run_now",
    "scheduler_cancel",
    "scheduler_queue",
    "scheduler_models",
    "scheduler_summary",
    "scheduler_tasks",
    "scheduler_history",
    "scheduler_result",
    "backup_export",
    "backup_import",
    "backup_last",
    "instances_list",
    "instance_create",
    "instance_delete",
    "instance_bind",
    "instance_launch",
    "autostart_get",
    "autostart_set",
    "update_check",
    "update_apply",
    "openrouter_refresh",
    "vercel_refresh",
    "provider_models_load",
    "claude_login_start",
    "claude_login_status",
    "claude_login_cancel",
    "claude_credentials",
    "claude_models",
    "claude_usage",
    "claude_disconnect",
    "antigravity_login_start",
    "antigravity_login_status",
    "antigravity_login_cancel",
    "antigravity_credentials",
    "antigravity_models",
    "antigravity_metrics",
    "antigravity_account_action",
    "antigravity_disconnect",
    "open_url",
    "island_snapshot",
    "island_resize",
    "island_reposition",
    "island_open_main",
    "island_toggle_api",
    "island_run_next",
    "plugin:event|listen",
    "plugin:event|unlisten",
    "plugin:dialog|open",
  ];

  var allowed = Object.create(null);
  for (var i = 0; i < COMMANDS.length; i += 1) allowed[COMMANDS[i]] = true;

  var internals = window.__TAURI_INTERNALS__;
  var available = !!(internals && typeof internals.invoke === "function");

  function invoke(cmd, args) {
    if (!Object.prototype.hasOwnProperty.call(allowed, cmd)) {
      return Promise.reject(new Error("melon bridge: command not allowed: " + cmd));
    }
    if (!available) {
      return Promise.reject(new Error("melon bridge: not running inside Tauri"));
    }
    try {
      return Promise.resolve(internals.invoke(cmd, args || {}));
    } catch (error) {
      return Promise.reject(error);
    }
  }

  // Event subscription without window.__TAURI__: the runtime registers a
  // callback id via transformCallback and the event plugin drives it.
  // Returns a promise for an unlisten function, like @tauri-apps/api does.
  function listen(event, handler) {
    if (!available || typeof internals.transformCallback !== "function") {
      return Promise.reject(new Error("melon bridge: event API unavailable"));
    }
    var callbackId = internals.transformCallback(handler);
    return invoke("plugin:event|listen", {
      event: event,
      target: { kind: "Any", label: "" },
      handler: callbackId,
    }).then(function (eventId) {
      return function unlisten() {
        var id = eventId === undefined || eventId === null ? callbackId : eventId;
        return invoke("plugin:event|unlisten", { event: event, eventId: id })
          .catch(function () {
            // The page is going away; a dropped unlisten is not an error.
          });
      };
    });
  }

  window.melon = {
    available: available,
    commands: COMMANDS.slice(),
    invoke: invoke,
    listen: listen,
  };
})();
