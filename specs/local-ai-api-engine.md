# Local AI API engine — startup config reconciliation

## SPEC

- Phase: BUILD (2026-11-06).
- Parent spec: `specs/local-ai-api-publication.md`.
- Engine baseline: `1f917e77c4562623aa49e9804d999524151a2f96`.
- Owned paths: `MacOS/_sources/CLIProxyAPI/internal/watcher/**`, `MacOS/patches/0003-config-startup-reconcile.patch`, this spec.
- Scope: the gateway process only. App publication, model lifecycle and Connections remain parent-owned.

### Problem

The gateway answers HTTP before the file watcher is attached. `sdk/cliproxy/service_lifecycle.go` starts the server, sleeps 100 ms, then creates the watcher, calls `SetConfig`, `Start`, and logs `file watcher started ...` only afterwards. A config save that lands in that window is never applied, so a just-loaded local model stays absent from `/v1/models` until some later config change.

Atomic replacement itself is not the defect: on macOS, fsnotify re-adds the watch after `os.replace` and emits `Create`, and repeated atomic replaces plus in-place writes reload correctly once the watch is active. The defect is the gap before the watch exists.

## ROOT CAUSE

- `Watcher.SetConfig` stored the config but left `lastConfigHash` empty.
- `Watcher.start` installed the fsnotify watches and immediately loaded clients from the stored config. Nothing compared the stored bytes with the bytes now on disk.
- A write between the initial `config.LoadConfig` and `fsnotify.Add` produces no event for the new watch, so the stale config remains in force. HTTP is already reachable in that period, which is exactly when the app publishes its provider config.

## FIX

1. `Watcher.SetConfig` seeds `lastConfigHash` from `cloned.SourceHash`. SourceHash is the hash of the exact bytes the config was parsed from (`internal/config/config_load.go`), so it is a truthful "what the watcher applied" baseline.
2. After both watches are installed and `processEvents` is running, `Watcher.start` calls `reloadConfigIfChanged()` once before the initial full client load. The existing hash check applies the file only if it changed; otherwise it is a read and a debug log.
3. The reconciliation is skipped when there is no baseline hash (programmatic in-memory configs), preserving previous behaviour for callers that did not load from a file.

No event masks, debounce logic, public API or service lifecycle were changed. A duplicate client load occurs only on the race path: the reconciliation reloads the changed config, then the existing initial `reloadClients(true, nil, false)` performs the full auth scan.

## EVIDENCE

### Deterministic unit regression

`internal/watcher/config_startup_race_test.go`:

- `TestStartReconcilesConfigReplacedBeforeWatchInstalled` loads a config, calls `SetConfig`, atomically replaces the file, then calls `Start`. Before the fix: `pre-attach config write was lost: port=8300, want 9300`. After the fix: PASS, callback receives port 9300.
- `TestStartAppliesAtomicReplacementsAndInPlaceWrites` starts normally, then performs two atomic replacements and one in-place write; all three reload. PASS.
- Fixtures are canonical v8 (`config-version: 8`, `server.port`, `oauth.auth-dir`), matching app-generated configs; no legacy `auth_dir` placeholder is relied on.

```
cd MacOS/_sources/CLIProxyAPI
GOFLAGS=-mod=mod go test ./internal/watcher -count=1
# ok github.com/router-for-me/CLIProxyAPI/v8/internal/watcher 3.462s
```

### End-to-end gateway (isolated temp dirs, loopback only)

Existing `MacOS/build/cliproxyapi` (pre-fix) with the new explicit race flag, three runs: all red.

```
python3 scripts/test_local_ai_gateway.py --engine MacOS/build/cliproxyapi \
  --fixture /tmp/melon-local-ai-schema-probe.yaml --startup-race
# AssertionError: condition did not converge: None  (3/3)
```

Fixed engine built to `/tmp/melon-local-ai-engine-test`, three runs: all PASS.

```
python3 scripts/test_local_ai_gateway.py --engine /tmp/melon-local-ai-engine-test \
  --fixture /tmp/melon-local-ai-schema-probe.yaml --startup-race
# PASS ... cycle 1, cycle 2, real gateway publication gate  (3/3)
```

Default (watcher-log readiness) and `--start-published`: PASS.

Manual race harness with the fixed engine reproduced the intended ordering: `API server started` → `config file changed, reloading` (inside watcher start) → `config successfully reloaded` → `file watcher started`; the model alias was present in `/v1/models` afterwards.

### Full engine suite

```
cd MacOS/_sources/CLIProxyAPI
GOTOOLCHAIN=go1.26.10 GOFLAGS=-mod=mod go test ./... -count=1
# exit 0, every package ok (2026-11-06)
```

Log: `/tmp/melon-go-test-all-final.log`. Relevant packages: `internal/watcher` 3.462s, `sdk/cliproxy` 14.286s, `test` 0.649s. The run was repeated after the canonical fixture edit; no failures.

### Durable patch

`MacOS/patches/0003-config-startup-reconcile.patch` contains the two production edits and the regression test. Verified:

- `git apply --check` on pristine `HEAD` copies of the two files: PASS.
- Applied result byte-identical to the working tree.
- `MacOS/scripts/apply-engine-patches.sh`: all three patches reported already applied.

### Build

```
cd MacOS/_sources/CLIProxyAPI
GOTOOLCHAIN=go1.26.10 CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
  go build -trimpath -ldflags "-s -w" -o /tmp/melon-local-ai-engine-test ./cmd/server
```

## LIMITS

- The fix closes the window up to the moment the watch is installed. A write that lands after the reconciliation read but before `Add` is impossible by ordering (reconciliation runs after `Add`); a write after `Add` is delivered as an fsnotify event.
- Configurations loaded without `SourceHash` keep the old behaviour. The macOS app path always loads from a non-empty YAML file, so it has a baseline.
- Full `go test ./...` passed on the final tree (see above). The release artifact was not rebuilt, per parent instruction; native app fixtures remain parent-owned.
