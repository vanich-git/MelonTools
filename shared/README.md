# Shared cross-platform contracts

- `composer-chips.js` is the canonical injected composer script for macOS and
  Windows. `scripts/sync-composer.sh` copies it into both app resource
  directories; CI runs `--check` so the copies cannot drift. Windows embeds
  the shared file directly; macOS loads the synced bundle resource.
- `fixtures/quota-signals.json` is consumed by both `CodexLiveQuotaTests`
  (Swift) and `quota::tests::shared_quota_fixture_matches_both_platforms`
  (Rust).
- `fixtures/routing.json` is consumed by `CodexRoutingTests` and the gateway
  priority test; it pins descending priority and the plan-rank table.
