# Исправления аудита Windows/macOS 2026-11-04

Проверено 2026-11-05 на текущем рабочем дереве `feature/local-ai-6.0.0`. Существовавшие изменения сохранены. [Исходный аудит](AUDIT_WINDOWS_MACOS_2026-11-04.md) не переписывался. Commit/tag/publish и установка приложений не выполнялись.

## Итог

Подтверждённые дефекты кода исправлены, добавлены регрессии. Это **не сертификация стабильного релиза**: Windows-тесты исполнялись на macOS; Windows-target проверен компилятором, но не запускался нативно. Реальные Developer ID/notarization, Authenticode, WebView2/DPAPI/DPI и clean install/upgrade/soak — отдельные acceptance gates. Неизвестные хеши 6.0.0 не выдумывались.

## Матрица

| Пункт | Исправление | Регрессии / границы |
|---|---|---|
| REL-01 | Pinned universal runtime fetch/verify до первого XcodeGen в CI/package/release | Clean-checkout fixture без ignored runtime; runtime script tests |
| REL-02 | Cargo.lock согласован с 6.0.0/dependencies; fmt и production/test Clippy blockers устранены без отключения lint | locked tests, Windows-target check и Clippy -D warnings |
| REL-03 | Двухфазный release: build создаёт draft и staging из реальных assets; promotion сверяет committed metadata с draft downloads/aliases/sidecars/SHA256SUMS. Нет circular требования будущих hashes до build | 16 Python regression tests; live Homebrew/winget пока честно 5.5.8, не 6.0.0 |
| REL-04 | Все nested Mach-O включая runtime подписываются до bundle; runtime manifest обновляется после codesign; notary Accepted, deep verify и staple обязательны в signed path | Script tests/ad-hoc sequence; реальная Developer ID требует credentials |
| CORE-01 | Обе ОС: independent durable scheduler-usage.json task/day ledger, migration до trim; corrupt/newer/impossible fail-closed; write failure не возвращает бюджет; backup max-merge. Windows требует поле days и canonical day keys; macOS отвергает future counters до prune | >20 runs, >200 entries, skipped, rollover, migration, corruption/incomplete JSON/future, write/retry, restore tests |
| CORE-02 | macOS drain stdout во время git, bounded memory, timeout/kill, cancellation detached work | Большой вывод, timeout и cancel |
| CORE-03 | Windows per-model managed namespace; serialized registry changes; delete trash/rollback; publish previous revision backup до registry commit; split validate-before-publish. Colliding download slug не заменяет другую repo/file; failed import publish очищает staging | Same-basename byte isolation, shared refs, injected registry failures, by-reference source, split rollback, worker claim, slug collision, failed rename |
| CORE-04 | macOS UUID CODEX_HOME; case-insensitive duplicate check; collision migration сохраняет legacy history. Ошибка копирования auth удаляет созданный пустой home, чтобы повторная миграция не блокировалась | Work/work, idempotent migration, unreadable-auth retry, path escape и owned-only delete |
| CORE-05 | macOS failed/read-only vault запрещает destructive prune; original corrupt vault остаётся на диске плюс backup, в том числе для следующего запуска | Auth prune gate и original-survives-next-launch |
| CORE-06 | Windows cancellation-aware HTTP send/body с distinct cancelled без retry; Git-контекст тоже async, bounded, с kill-on-drop; общий deadline включает подготовку запроса | Delayed headers/body, already-cancelled, full stdout/stderr pipes, cancelled child reap |
| CORE-07 | Windows global exit cleanup и kill-on-close Job Object; engine принадлежит приложению, а не renderer/tray handler | Windows-target compilation, проверка exit/assign failure paths; kernel crash/logoff/updater требуют нативного Windows |
| CORE-08 | Windows native supervisor reap/reconcile без renderer; /health не считается моделью: /models/load + wait loaded; idle unload снимает Ready/routes. macOS reconciliation защищён generation и обновляет gateway config | Router HTTP/parser, lifecycle, stale status tests; real-model/native soak отдельно |
| CORE-09 | macOS durable job/item UUID journal, part+sidecar Range/If-Range, split/crash recovery, exact downloadJobID receipt; copy→registry commit→delete staged, rollback; dynamic injected roots; enqueue/resume fail closed при journal error | Pause/restart, 200/206, ETag, crash publish, wrong same-basename revision, unwritable journal, injected sink |
| CORE-10 | Обе ОС: visible read-only registry error, original+backup; corrupt/newer не заменяется пустым каталогом через import/delete/status. Windows повторная порча сохраняет отдельную revision | Preserved-bytes, newer schema, retry/explicit recovery и repeated-corruption tests |
| CORE-11 | HF/runtime/catalog/download external clients используют app proxy; loopback health/metrics/relay explicit direct | Recording proxy и config/policy tests обеих ОС |
| CORE-12 | macOS nil reset не near reset: idle 15 s, fast только traffic/known near-overdue | Cadence tests |
| CORE-13 | Windows applied settings snapshot; pending badge и явный Restart / Save & Restart | Payload и UI static guards; WebView2 interaction отдельно |

## Дополнительные дефекты, найденные при перепроверке

- Windows: синхронный Git-контекст выполнялся до cancellation/deadline. Теперь subprocess async; stdout и stderr drain параллельно, сохраняется bounded prefix, timeout/cancel убивает child. Регрессии проверяют большие оба pipe и reap после отмены.
- Usage ledger: Windows больше не трактует `{}`/missing `days` как нулевой расход, отвергает неканоническую дату и пустой task ID. macOS future counter отвергается до prune и остаётся byte-identical на диске.
- Windows registry quarantine: разные повреждённые revisions получают отдельные numbered backups; повторное чтение одинаковых байтов не переписывает rescue, включая read-only backup. Новые backups создаются `create_new` и синхронизируются до разрешения recovery.
- Windows imports/downloads: cleanup staged bytes при failed rename; download-ID collision между разными repo/file — явная ошибка без подмены записи.
- Windows runtime: ошибки записи preset/открытия engine log после `Starting` публикуют `Failed`, а superseded generation не перезаписывает новый запуск.
- macOS shared CODEX_HOME migration: после ошибки auth copy созданный пустой destination удаляется; после исправления доступа миграцию можно безопасно повторить.
- CI Clippy теперь включает test targets; локальный Windows cross-build helper использует `--locked` так же, как CI/release.

## Эксплуатационные пункты

- Большой macOS scheduler snapshot сериализуется и пишется вне MainActor, очередь coalesced, quit/backup flush. Маленький budget ledger коммитится синхронно ради корректности учёта.
- Backup PBKDF2/encryption/decryption off-main, busy/cancel UI. Decrypt отделён от короткого commit+store reload на MainActor, чтобы quota timer не затёр восстановленный vault. Scheduler restore запрещён при active run, новый dispatch/writes приостановлен.
- Orphan probe/ожидание вне MainActor, bounded process probe, Task.sleep вместо UI Thread.sleep.
- Engine log не прекращается после cap: bounded in-session rotation сохраняет актуальные diagnostics с redaction.
- Добавлены [release acceptance matrix](RELEASE_ACCEPTANCE.md), macOS native artifact runner и Windows artifact verifier; Chromium/mock не считается native PASS.

## Проверки

| Проверка | Результат | Граница |
|---|---|---|
| macOS Debug xcodebuild test | **418 tests, 7 skipped, 0 failures** | 6 real-model E2E + 1 network install opt-in пропущены |
| macOS Release arm64+x86_64 | **BUILD SUCCEEDED**; lipo: x86_64 arm64 | Не clean install и не Developer ID |
| macOS свежий bundle, native-acceptance | **8 passed, 0 failed, 1 skipped, 3 manual** | Ad-hoc copy в /tmp, 37 nested Mach-O verified; без установки/launch |
| Rust cargo test --locked | **377 passed, 0 failed** | Исполнено на macOS |
| cargo clippy --locked --all-targets -- -D warnings | **PASS** | Host macOS; includes tests |
| Windows-target cargo xwin check --tests --locked | **PASS** | Не запуск exe |
| Windows-target Clippy --tests -D warnings | **PASS** | Не native runtime |
| Windows Release cargo xwin build --release --locked | **PASS**, PE32+ GUI x86-64 | Cross-link, не installer/native launch/Authenticode |
| cargo fmt --check | **PASS** | |
| Release metadata Python regressions | **16 passed** | Synthetic fixture не реальный release hash |
| Runtime script regressions / clean-checkout smoke | **27 passed / 6 passed** | Sandbox rebuild, не signed native install |
| Localization | **1221 keys / 1142 sites, PASS** | Не visual review |
| JS syntax / UI static / composer sync | **PASS**, 22 scripts / 126 commands | Не WebView2 |
| Island Chromium compact/expanded/reenter | Предыдущий mock smoke; в этом прогоне не повторялся | Не native evidence |
| Docs lint / actionlint / shellcheck / diff whitespace | **PASS** | GitHub CI не запускался |
| Embedded Windows gateway checksum | **PASS** | Существующий binary resource |

Логи текущего прогона: [/tmp/melon-audit-fix-macos-tests-20261105.log](/tmp/melon-audit-fix-macos-tests-20261105.log), [/tmp/melon-audit-fix-macos-release-20261105.log](/tmp/melon-audit-fix-macos-release-20261105.log), [/tmp/melon-audit-fix-rust-tests-20261105.log](/tmp/melon-audit-fix-rust-tests-20261105.log), [/tmp/melon-audit-fix-clippy-20261105.log](/tmp/melon-audit-fix-clippy-20261105.log), [/tmp/melon-audit-fix-windows-clippy-20261105.log](/tmp/melon-audit-fix-windows-clippy-20261105.log), [/tmp/melon-audit-fix-windows-build-20261105.log](/tmp/melon-audit-fix-windows-build-20261105.log), [/tmp/melon-audit-fix-macos-acceptance-20261105.txt](/tmp/melon-audit-fix-macos-acceptance-20261105.txt). Xcode results: `/tmp/MelonToolsAuditFix20261105/Logs/Test/`. Временные логи не заменяют переносимую CI/native evidence с SHA артефактов.

Предупреждения не скрывались: Rust host cache на внешнем томе не поддерживает hard links (Cargo копирует файлы); cross-link выдаёт LNK4099 из-за отсутствующих Microsoft CRT PDB; обе сборки завершились успешно. macOS Release имеет существующие Swift concurrency/unused-capture warnings (включая предупреждения о будущем Swift 6 mode); сборка не warning-free, Swift 6 migration не выполнялась. `actionlint` запускался с явным списком пяти настоящих YAML: auto-discovery также захватывает AppleDouble `._*.yml` внешнего тома.

## Незакрытая native/release приёмка

1. Собрать полный набор реальных 6.0.0 DMG/setup/portable/legacy и SHA, затем stage/promote. Homebrew/winget до этого остаются на опубликованной **5.5.8**; strict release 6.0.0 намеренно не зелёный.
2. Нативный Windows запуск (WebView2, Job Object crash/logoff/updater, DPAPI/DPI), macOS clean install/upgrade/rollback, реальные engine/model E2E и sleep/wake/tray soak.
3. Реальные Developer ID/notarization/stapling и Authenticode — с credentials владельца. Ad-hoc не publisher authenticity.
4. Hard crash ровно между provider response и durable spend write либо физическая невозможность записи может потерять учёт последней операции после перезапуска. В живом процессе write failures fail-closed с сохранением spend в памяти. Это не hard transactional spending ceiling; pre-dispatch reservation не реализована.
5. Новый код/тесты частично untracked ещё до задачи: перед tag включить их в проверяемый commit. Рабочее дерево не равно опубликованному snapshot.
