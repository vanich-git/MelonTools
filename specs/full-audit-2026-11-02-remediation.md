# Аудит 5.0.0 — что исправлено

Источник: `specs/full-audit-2026-11-02.md`.
Рабочее дерево: `/Volumes/Z Slim/MelonTools`, ветка `main`, коммит `0a0ad1d` + локальные правки.
Версия поднята до **5.0.1** (build 51); DMG и Windows-артефакты собраны,
macOS-приложение установлено в `/Applications`.

## Исправлено

| ID | Что сделано | Проверка |
|---|---|---|
| W-1 | `antigravity_account_action` добавлен в whitelist `mt-bridge.js` (пауза, приоритет, удаление, probe Antigravity снова работают) | `node Windows/app/tools/ui-static-check.js` → `ok: 20 scripts, 88 whitelisted commands` |
| W-2 | В `release.yml` перед тестами добавлены `l10n_lint`, `node --check`, `sync-composer --check`, `ui-static-check`; добавлен `actions/setup-node` | YAML валиден (`yaml.safe_load`), шаги на месте |
| D-1 | `packaging/README.md`: таблица 5.0.0 теперь содержит DMG, setup и portable с реальными хешами; удалена фраза «macOS-only» | Хеши сверены с `shasum` и release notes |
| D-2 | `docs/SECURITY-MODEL.md` обновлён с 3.3.0 на 5.0.0 (2 места) | grep |
| S-1 (macOS) | `nextLiveQuotaDelay` учитывает `resetAt`: 1,5 с только если блокировка сбрасывается в ближайшие 5 минут (или трафик). Далёкий недельный блок больше не будит приложение 40 раз в минуту | `xcodebuild test` — 244 теста |
| S-1 (Windows) | `live_quota::tick` возвращает `fast`; цикл в `main.rs` спит 1,5 с только при близком сбросе, иначе 15 с. Остановленный движок — 15 с вместо busy-loop | `cargo check`, `cargo test` (224 passed), новый unit-тест `fast_guard_only_runs_when_a_block_resets_soon` |
| S-2 | `l10n_lint.py` пропускает AppleDouble `._*` и читает с `errors="replace"` | `python3 MacOS/scripts/l10n_lint.py` → `l10n ok: 803 keys, 753 L() call sites` |
| S-3 | Добавлен `Logger` (subsystem `dev.melontools.app`): Lifecycle (запуск/завершение), Gateway (остановка, отказ), Updater (доступно обновление, ошибка проверки, установка) | `xcodebuild test` |
| Q-2 | Удалены неиспользуемые команды `claude_refresh`, `antigravity_refresh` (Rust + mock в `mt-api.js`); whitelist и `generate_handler!` теперь совпадают | `ui-static-check`, grep |
| Q-3 | Удалён корневой дубликат логотипа `Яркий янтарный ломтик дыни с семечками.png` (тот же SHA-256, что `MacOS/Logo.png`) | `git status` |
| Q-6 | Комментарий в `UpdaterStore.swift` исправлен с «6 h / daily» на «1 h / hourly»; удалён неиспользуемый ключ локализации | `l10n_lint` |
| Q-7 | `gateway.pid` пишется через `SecureFile` (0600), как остальные файлы гейтвея | код |
| UI | Блок «В каталоге, но недоступно» в карточке Antigravity свёрнут в `DisclosureGroup` (по умолчанию закрыт), список — сетка в `ScrollView` с высотой 170 pt; удалён лишний абзац про недельное окно | `xcodebuild build` + тесты |

## UI-правка подробнее

`MacOS/app/MelonTools/Views/Codex/ModelSourcesView.swift`:

- новый `AntigravityCatalogOnlyBlock` с `@State private var expanded = false`;
- заголовок строки: замок + «Есть в каталоге, аккаунту недоступно» + число моделей;
- в раскрытом виде — пояснение и компактная сетка (2+ колонки) в скролле, поэтому карточка не растёт даже на 50 моделях;
- блок используется и в карточке провайдера, и в детальной странице Antigravity;
- удалён второй абзац «Движок не отдаёт недельное окно…» — он не относился к списку моделей и дублировал подсказку.

## Не исправлено (и почему)

| ID | Причина |
|---|---|
| S-4 (нотаризация/Authenticode) | Нет сертификатов Apple/Windows; вне репозитория |
| Q-1 (два слоя Windows UI, 2,7 тыс. строк мёртвого кода) | Требует визуального smoke и удаления 13 функций; риск сломать UI выше пользы в этой итерации. Рекомендация: отдельный PR с прогоном браузерного mock |
| Q-4 (`SWIFT_STRICT_CONCURRENCY`) | Крупный рефакторинг с проверкой каждого `@unchecked Sendable` |
| Q-5 (доступность) | Отдельная задача; текущие `aria`/`accessibilityLabel` не ломаются |
| S-1 (полный эффект) | Правка уменьшает частоту, но лог гейтвея всё ещё пишет каждый management-запрос. Чтобы убрать ~30 МБ/сутки полностью, нужен уровень логирования в движке (внешний Go-исходник) |

## Дополнительно найдено при исправлении

- **`cargo fmt --check` на HEAD падал**: `antigravity.rs:849` (`probe_account`)
  не был отформатирован после 5.0.0. Исправлено `cargo fmt --all`; теперь
  `cargo fmt --all -- --check` возвращает 0.
- `cargo clippy -- -D warnings` на macOS сообщает два `dead_code` в
  `bridge.rs` (`store_location_from_output`, `store_exe_paths`): они нужны
  только Windows-ветке и тестам. Это платформенная особенность, не регрессия;
  на `windows-2025` (CI) предупреждений нет. С `-A dead_code` clippy чист.

## Проверки после правок

```
xcodebuild … test (Debug)              → 244 tests, 0 failures, TEST SUCCEEDED
xcodebuild … build (Release)           → BUILD SUCCEEDED
node --check (все UI-скрипты)          → OK
node Windows/app/tools/ui-static-check.js → ok: 20 scripts, 88 commands
python3 MacOS/scripts/l10n_lint.py     → l10n ok: 803 keys, 753 call sites
python3 .github/scripts/docs_lint.py   → OK
yaml.safe_load (4 workflow)            → OK
cargo check --locked                   → OK (только platform dead_code warnings)
cargo test --locked                    → 224 passed, 0 failed
cargo fmt --all -- --check             → 0
cargo clippy -- -D warnings -A dead_code → OK
shasum -a 256 -c MelonTools-5.0.0.dmg.sha256 → OK
```

`cargo` собран из `~/.cargo/bin` (1.99.1); `CARGO_TARGET_DIR=/tmp/melon-target`
использован намеренно, чтобы target не попадал на exFAT-том (см. S-2).

## Что осталось на следующий шаг

1. Собрать Release и установить, проверить карточку Antigravity глазами (свёрнутый блок, раскрытие, скролл).
2. Прогнать `cargo clippy -- -D warnings` и `cargo test` на Windows-раннере (локально — только `cargo check`).
3. Отдельным PR: убрать перекрытые функции `mt-pages.js`/`app.js` (Q-1) после браузерного smoke.
