# Spec: gateway config writes — idempotency, coalescing, guards, 401 retry

## SPEC

### Objective

Убрать шторм hot-reload `config.yaml` и связанные с ним транзиентные 401 в
локальном шлюзе Melon Tools на macOS и Windows, не меняя формат конфига и не
затрагивая работу движка.

Восемь пунктов плана:

1. **P0 Идемпотентность.** Писать `config.yaml` только когда изменилось
   *намерение приложения* (сгенерированный YAML), а не содержимое файла на
   диске: движок сам переписывает файл (`persistConfigAsync` хеширует
   `remote-management.secret-key`), поэтому сравнение с диском не работает.
2. **P0 Coalescing.** Серии записей в пределах короткого окна объединять в одну
   (macOS `DispatchWorkItem` 350 мс, Windows generation + `spawn` 350 мс);
   перед spawn шлюза — принудительный flush.
3. **P0 Guard от неполного конфига.** macOS: не писать, пока
   `ModelSourcesStore` не загрузился (битый `model-sources.json` больше не
   может выкинуть всех провайдеров). Windows: не писать конфиг с пустым
   `api_key`/`management_secret`.
4. **P1 Сужение триггера Windows.** `main.rs` пишет конфиг после любого
   изменения `Settings`; оставить вызов, но он становится no-op благодаря (1),
   а health-watchdog и `local_ai` используют coalesced-путь.
5. **P1 Ретрай 401.** `checkAPI` (macOS) и `check_api` (Windows): один повтор
   через ~1.5 с при HTTP 401 — окно reload больше не выглядит как «ключ
   недействителен».
6. **P1 Audit-лог причин.** Каждая запись/пропуск пишется в audit-лог с
   причиной (`start`, `routing`, `catalog`, `model-sources`, ...).
7. **P2 Тесты.** Юнит-тесты идемпотентности, guard и coalescing на обеих
   платформах.
8. **P2 Движок.** Проверить, нужен ли апдейт пина CLIProxyAPI ради graceful
   reload; зафиксировать доказательство.

### Scope

- `MacOS/app/MelonTools/Codex/CodexGatewayService.swift`
- `MacOS/app/MelonTools/Codex/ModelSources.swift`
- `MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift` (только вызовы записи)
- `MacOS/app/MelonToolsTests/CodexGatewayEngineTests.swift` (тесты)
- `Windows/app/src-tauri/src/gateway.rs`
- `Windows/app/src-tauri/src/main.rs`
- `Windows/app/src-tauri/src/local_ai/commands.rs` (только вызов записи)

### Out of scope

- Формат `config.yaml`, набор провайдеров, роутинг, каталог моделей.
- Патчи Go-движка и замена вендорного бинарника.
- Повторная авторизация Codex-аккаунтов, квоты OpenCode Go.
- Коммит, пуш, релиз.

### Current state

- `HEAD` = `ab26028cb0b5efaf2c96aeb0ded20f3912d81e68`, ветка
  `feature/local-ai-6.0.0`, 94 изменённых файла (работа пользователя над
  Local AI 6.0.0); правки спеки не должны их затрагивать.
- Движок уже умеет пропускать reload при совпадении SHA-256 файла
  (`config_reload.go:76`), но после каждого reload вызывает
  `persistConfigAsync` (`config_reload.go:91`), который переписывает
  `config.yaml` (bcrypt-хеш management secret) — файл на диске перестаёт
  совпадать с намерением приложения.
- Логи `gateway.log` 2026-11-06 показывают 16 reload/час и серии по 4–6
  подряд; каждый reload пересобирает клиентов, в окне — 401.
- `ModelSourcesStore.init` вызывает `load()` синхронно, но `load()`
  молча выходит при нечитаемом файле, оставляя `sources = []` — запись
  конфига в этот момент удаляет всех провайдеров из `api-keys`.

### Assumptions

- Сравнение по последнему сгенерированному YAML допустимо: единственный
  писатель со стороны приложения — `writeConfig`/`write_config`.
- 350 мс достаточно, чтобы схлопнуть серию событий UI, и незаметно для
  пользователя.
- Один лишний reload после старта приложения приемлем.

### Acceptance criteria

- **AC1 macOS idempotency:** повторный `writeConfig` с тем же состоянием не
  трогает файл и пишет в audit-лог `skipped ... unchanged`.
- **AC2 macOS coalescing:** несколько `scheduleConfigWrite` в окне дают одну
  запись; `flushConfigWrite` пишет немедленно.
- **AC3 macOS guard:** при `ModelSourcesStore.isLoaded == false` запись
  пропускается с логом; битый store не декодируется и оставляет `isLoaded`
  false.
- **AC4 Windows idempotency:** `write_config` с идентичным YAML не меняет
  mtime/содержимое и возвращает «не изменено»; с изменённым — атомарно
  заменяет.
- **AC5 Windows coalescing/trigger:** `schedule_write_config` схлопывает
  серию; вызов из `apply_settings` остаётся, но не пишет без изменений.
- **AC6 401 retry:** обе проверки повторяют запрос один раз при 401 и
  возвращают успех, если повтор успешен; число попыток ограничено.
- **AC7 Audit:** каждая запись/пропуск имеет причину в логе (macOS
  `auditLog`, Windows `log::info!`).
- **AC8 Tests:** новые тесты проходят на macOS (`xcodebuild test`) и Windows
  (`cargo test`, если тулчейн доступен; иначе — документированная
  статическая проверка).
- **AC9 Engine:** апдейт пина обоснован или отклонён с доказательством
  (сравнение upstream-коммитов `internal/watcher/config_reload.go`).
- **AC10 No regression:** `xcodebuild build` macOS и `cargo check`/`cargo
  test` Windows не ломаются; формат конфига не меняется.

### Check plan

Required:

- `xcodebuild -project MacOS/app/MelonTools.xcodeproj -scheme MelonTools
  -configuration Debug -derivedDataPath "$HOME/Library/Developer/MelonTools"
  test -only-testing:MelonToolsTests/CodexGatewayEngineTests`
- `xcodebuild ... build` (полная сборка приложения).
- `cargo test` в `Windows/app/src-tauri` (если окружение позволяет).
- `git diff --stat` и ручная проверка, что формат YAML не изменился.

Advisory:

- `bash -n` для затронутых скриптов (не меняются).
- Повторный `grep` по вызовам записи, чтобы не осталось прямых обходов.

## EVIDENCE

### DISCOVER

- Движок уже дебаунсит и пропускает идентичный файл:
  `MacOS/_sources/CLIProxyAPI/internal/watcher/config_reload.go:76` —
  `config file content unchanged (hash match), skipping reload`; после
  успешного reload `:91` вызывает `persistConfigAsync()`, который
  нормализует файл (`internal/store/gitstore.go:2006` `PersistConfig`,
  bcrypt для `secret-key`). Отсюда вывод: сравнение с диском невозможно,
  нужно сравнивать с последним записанным намерением в памяти.
- `config.yaml` (6730 Б) содержит `remote-management.secret-key` в bcrypt,
  `access`, `routing`, `api-keys.openai-compatibility` — приложение пишет
  plaintext, движок хеш; файл «мигает» на каждом reload.
- `gateway.log`, 2026-11-06: 35 строк `config file changed`; пик — 12 в
  10:47, затем 3 в 10:52 и 1 в 10:53. Шторм совпадает с сериями 401 в чате.
- Прямые писатели конфига до правок: macOS `writeConfig` (9 вызовов),
  `ModelSources.apply`, `LocalInferenceService` (3 вызова); Windows
  `write_config` из `apply_settings` (`main.rs:183`), catalog-refresh
  (`main.rs:1729`), `local_ai/commands.rs:224`, `start()`.
- `ModelSourcesStore.load()` молча возвращался при нечитаемом файле,
  оставляя `sources = []` — запись в этот момент удаляла всех провайдеров
  из `api-keys` (совпадает с логом `provider removed: opencode`,
  `opencode-go` в 10:52:23).
- Апдейт движка (п.8): последний upstream-коммит, затрагивающий
  `internal/watcher`/`sdk/cliproxy` после пина `1f917e77`, —
  `aa4130e` «fix(gemini): keep truncated HTTP 200 streams out of credential
  cooldown and failover» (gemini/cooldown, не reload). Коммит, меняющий
  `config_reload.go`, — `1631875b` от 2026-10-15, старше пина. Наш патч
  `0003-config-startup-reconcile.patch` добавляет reconcile на старте
  (`events.go`) и тест `config_startup_race_test.go`; graceful reload в
  апстриме не появился. Вывод: апдейт пина не нужен.

### BUILD

macOS (`CodexGatewayService.swift`):

- `lastWrittenConfig` (:88), `configWriteWork`, `configWriteDebounce = 0.35`.
- `writeConfig(reason:)` (:368): guard `ModelSourcesStore.shared.isLoaded`
  (:372, лог `config write skipped (\(reason)): model sources store is not
  loaded`), затем `Self.configNeedsWrite(proposed:lastWritten:fileExists:)`
  (:420) — при совпадении лог `config write skipped (\(reason)): unchanged`
  и выход без записи; иначе `SecureFile.write`, `lastWrittenConfig = yaml`,
  `auditLog("config written (\(reason))")` (:429–431).
- `configNeedsWrite` (:436): `!fileExists || proposed != lastWritten`
  (`lastWritten == nil` → запись).
- `scheduleConfigWrite(reason:)` (:443) — отмена предыдущего work item и
  `asyncAfter(0.35)`; `flushConfigWrite(reason:)` (:460) — отмена и
  немедленная запись. Перед spawn шлюза — `flushConfigWrite(reason:
  "start")` (:745), при adopt — `writeConfig(reason: "adopted running
  gateway")`.
- Причины на всех вызовах: `api key rotated`, `stream bootstrap timeout`,
  `network proxy settings`, `proxy changed`, `catalog overlay refreshed`,
  `adopted running gateway`, `start`, `routing order`, `model sources
  applied`, `local ai routes`.
- `sendWithAuthRetry` (:1238): один повтор через 1.5 с только при
  `HTTPURLResponse.statusCode == 401`; используется для `GET /v1/models`
  (:1261) и chat-пробы (:1295) — максимум 2 запроса.

macOS guard (`ModelSources.swift`):

- `private(set) var isLoaded = false` (:198); `load()` ставит `true` при
  отсутствии файла (первый запуск, :203), при успешном `Persisted` (:216) и
  `PersistedKeys` (:232); при существующем, но нечитаемом файле остаётся
  `false`, `sources` пуст.
- `apply()` → `flushConfigWrite(reason: "model sources applied")`.
- `LocalInferenceService.PublicationHooks.live` → `flushConfigWrite(reason:
  "local ai routes")`, поэтому все три прежних прямых вызова (205, 302,
  354) идут через coalesced-путь с flush.

Windows (`gateway.rs`):

- `write_config` (:117): guard пустых `api_key`/`management_secret` до
  создания каталогов; запись через `write_config_if_changed`.
- `last_written_config()` (:149) — `Mutex<HashMap<PathBuf, String>>`;
  `config_needs_write` (:156) — чистая функция; `write_config_if_changed`
  (:165) — сравнение с намерением, `tmp`+`rename`, обновление карты, лог
  `[gateway] config.yaml written (N bytes)`; мьютекс не удерживается во
  время файловых операций.
- `schedule_write_config` (:190) — generation counter `AtomicU64` + `spawn`
  + 350 мс, устаревшая генерация выходит без записи.
- `check_api` (:1360) → `check_api_once` (:1377); повтор только при
  `(401, _)`, второй результат возвращается как есть (максимум 2 запроса).
  `GET /v1/models` теперь проверяет статус до парсинга (раньше 401 давал
  ошибку JSON вместо кода).
- `main.rs`: `apply_settings` оставляет `write_config` (становится no-op без
  изменений, комментарий на месте); catalog-refresh переведён на
  `schedule_write_config`.
- Исторический BUILD оставлял `local_ai/commands.rs:224` на `write_config`, но независимое Local AI ревью установило конфликт: пропущенный reload не восстанавливается, если повтор той же генерации подавлен. По явному решению пользователя Repair 2 задачи `specs/local-ai-api-publication.md` перевёл этот hook на `write_config_forced`; macOS live publication использует `flushConfigWrite(force: true)`. Обычные настройки/каталог сохраняют идемпотентность и coalescing. Повторы публикации намеренно выполняют реальную замену файла; регрессии проверяют add/remove на временном файле. После неудачной атомарной замены возвращается ошибка без in-place truncation.

Тесты:

- macOS `CodexGatewayEngineTests`: `testConfigWriteIsSkippedForAnUnchanged
  Generation` (4 случая `configNeedsWrite`), `testModelSourcesStoreTreatsA
  MissingFileAsLoaded`, `testModelSourcesStoreReadsAValidFile`,
  `testModelSourcesStoreLeavesAnUnreadableFileUnloaded` — 4 из 4 прошли,
  весь класс 6/6.
- Windows `gateway::tests`: `config_write_is_skipped_for_an_unchanged
  generation`, `config_write_replaces_the_file_only_on_change`,
  `write_config_refuses_an_empty_gateway_key` — 3 из 3 прошли.

Проверки:

- `xcodebuild ... build` — `** BUILD SUCCEEDED **`, exit 0.
- `xcodebuild ... test -only-testing:MelonToolsTests/CodexGatewayEngineTests`
  — `** TEST SUCCEEDED **`, 6 тестов, 0 падений.
- `cargo check` — exit 0, только два предсуществующих warning
  (`taskbar_widget::start/reposition` never used).
- `cargo test` — `430 passed; 0 failed; 1 ignored` (72.29 s).
- `git diff --stat` по затронутым файлам: 6 файлов, `905 insertions(+),
  120 deletions(-)` (включая ранее существовавшие незакоммиченные правки
  этих файлов; формат YAML не менялся — новые строки только вокруг записи).

Отклонение от AC7: на Windows нет crate `log` (grep по `src` подтверждает,
что принятый способ — `eprintln!`), поэтому причина записи логируется через
`eprintln!("[gateway] config.yaml written ...")` и
`eprintln!("[gateway] config write failed: ...")`. Добавление зависимости
ради одной строки противоречит минимальному диффу.

Не выполнено в этой фазе: живой прогон приложения с новым бинарником не
делался (приложение пользователя не перезапускалось), поэтому эффект на
`gateway.log` подтверждён кодом и юнит-тестами, но не end-to-end логом.

### REPAIR-2 (после ревью и нового требования о виджете)

Правки:

- macOS `CodexGatewayService.swift`: `applyStreamBootstrapTimeout`,
  `applyNetworkSettings`, `refreshProxyIfNeeded`, `refreshCatalogIfNeeded`
  переведены на `scheduleConfigWrite`; `applyRouting` отменяет отложенную
  запись при ошибке `syncAccounts`; `writeConfig` перечитывает
  `ModelSourcesStore` перед отказом; `stopSync()` делает
  `try? flushConfigWrite("app termination")`.
- Windows `gateway.rs`: `write_config_if_changed_with` держит guard на всю
  операцию, `into_inner()` при отравлении, 3 попытки `rename` (50/100 мс) и
  фолбэк на запись на месте.
- Windows `main.rs`: `RunEvent::Exit` сохраняет текущий конфиг перед
  `gateway::stop`.
- Windows `taskbar_widget.rs`: `native::is_shell_overlay` — меню Пуск, поиск,
  центр уведомлений, Task View и `WS_EX_TRANSPARENT`-слои больше не считаются
  окном, покрывающим панель задач (виджет исчезал при клике на «Пуск»).

Проверки REPAIR-2:

- `xcodebuild ... test -only-testing:MelonToolsTests/CodexGatewayEngineTests`
  — `** TEST SUCCEEDED **`, `Executed 6 tests, with 0 failures`.
- `cargo test` — `432 passed; 0 failed; 1 ignored` (99.15 s).
- `cargo test config_write` — 2 passed.
- `cargo check --target x86_64-pc-windows-msvc` (через
  `CARGO_TARGET_DIR=/tmp/melontools-wincheck` и
  `PATH=/opt/homebrew/opt/llvm/bin` для `llvm-rc`) — `Finished dev profile`,
  exit 0: Windows-ветки, включая `taskbar_widget` и `RunEvent::Exit`,
  компилируются.

## REVIEW

Изолированный ревьюер (субагент, не автор правок) трижды не завершился:
`f5ab46ae` (~30 мин) и `50a70610` (~11 мин) прерваны без отчёта;
`b99c1a93` (код передан инлайном, без чтения рабочего дерева) выдал отчёт и
сразу после него упал. Изоляция соблюдена в главном — ревьюер не правил код и
не видел незакоммиченных файлов пользователя, — но она неполна: он оценивал
присланные сниппеты, а не полный diff. Ниже — его находки со статусом каждой и
отдельный контрольный проход автора.

### Находки и решения

| # | Уровень | Находка | Решение |
|---|---------|---------|---------|
| R1 | MAJOR | Дебаунс 350 мс теряет последнюю запись при выходе: flush нет ни в macOS `applicationWillTerminate`, ни в Windows `RunEvent::Exit` | Исправлено: `stopSync()` → `try? flushConfigWrite("app termination")`; `RunEvent::Exit` → `gateway::write_config(&state.settings())` перед `gateway::stop` |
| R2 | MAJOR | Swift: отказ `writeConfig` при `!isLoaded` не перепланируется — запись теряется до перезапуска приложения | Исправлено: перед guard — повторный `ModelSourcesStore.shared.load()`; битый файл по-прежнему даёт видимую ошибку `ConfigError.modelSourcesUnavailable` |
| R3 | MAJOR | Swift: `applyRouting` планирует запись до `syncAccounts`; при ошибке sync work item не отменяется и через 350 мс пишет routing, которого нет в auth-файлах | Исправлено: `configWriteWork?.cancel()` в `catch`; текст ошибки исправлен на «Routing failed» |
| R4 | MAJOR | Swift: прямые `writeConfig` (`applyStreamBootstrapTimeout`, `applyNetworkSettings`, `refreshProxyIfNeeded`, `refreshCatalogIfNeeded`) обходят дебаунс — серия изменений снова даёт шторм | Исправлено: все четыре переведены на `scheduleConfigWrite`; `flushConfigWrite` остался только у старта, ротации ключа, применении model sources и выхода |
| R5 | MAJOR | Rust: `fs::rename` поверх открытого файла → sharing violation; ошибка только логируется, `last_written` не обновляется, запись теряется | Исправлено: 3 попытки (50/100 мс) и фолбэк на запись на месте; ошибка возвращается, только если не удалось и это |
| R6 | MINOR | Rust: отравленный мьютекс навсегда блокирует записи (`map_err("lock poisoned")`) | Исправлено: `unwrap_or_else(\|p\| p.into_inner())` |
| R7 | MINOR | Rust: generation отменяет только спящие задачи; прошедшая проверку задача может записать старый снимок после новой | Принято: generation перепроверяется после задержки; окно гонки требует задержки >350 мс и не теряет данные — следующая запись восстановит актуальное поколение |
| R8 | MINOR | Swift: `cancel()` не прерывает уже выполняющийся work item | Принято: итоговое состояние корректно — последний писатель пишет актуальный YAML |
| R9 | MINOR | Rust: блокирующие `fs::write/rename` под мьютексом внутри `async_runtime::spawn` занимают воркер Tokio | Принято: файл ~6.5 КБ; вынос в `spawn_blocking` потребовал бы сделать синхронный `write_config` асинхронным ради микросекунд |
| R10 | MINOR | Ретрай 401 не отличает «ключ неверен» от «движок ещё в reload»; 1.5 с может не покрыть hot-reload | Принято: ровно два запроса, второй сохраняет код/тело; повторный 401 практически всегда означает реальный отказ |
| R11 | блокер UX (сообщение пользователя) | Виджет в панели задач Windows исчезал при клике на «Пуск» / внутри меню: полноэкранный XAML-хост меню считался окном, покрывающим панель задач, и `reposition` скрывал виджет | Исправлено: `native::is_shell_overlay` игнорирует меню Пуск, поиск, центр уведомлений, Task View, overflow-остров и `WS_EX_TRANSPARENT`-слои |

### Контрольный проход автора (после REPAIR-2)

Проверено по diff:
- macOS: все точки записи конфига идут через `writeConfig` (единственный путь);
  `scheduleConfigWrite` больше не мёртвый код; `flushConfigWrite` вызывается из
  `start()` (до `syncAccounts`/`spawn`), `rotateAPIKey`, `ModelSources.apply`
  и `stopSync`.
- macOS: `writeConfig` бросает при неразобранном store; `rotateAPIKey` откатывает
  ключ в `catch`; `applyRouting` отменяет запись при ошибке sync.
- Windows: `write_config_with` → `write_config_if_changed_with` — единственный
  путь записи; guard мьютекса удерживается на всю операцию; `write_config_forced`
  используется только для явной публикации Local AI.
- Windows: `taskbar_widget::native::is_shell_overlay` исключает меню Пуск, поиск,
  центр уведомлений, Task View и click-through слои из проверки «foreground
  покрывает панель задач».

Найдено и исправлено контрольным проходом и второй итерацией:
1. `write_config` не имел вызова `scheduleConfigWrite` (AC2 не выполнялось) — исправлено.
2. `writeConfig` при `!isLoaded` молча пропускал запись → рассинхрон ключа — исправлено.
3. `write_config_if_changed` отпускал мьютекс между проверкой и записью — исправлено.
4. Виджет панели задач исчезал при открытии Пуск (`XamlExplorerHostIslandWindow`
   на весь экран считался «покрытием») — исправлено (R11).
5. Последняя отложенная запись терялась при выходе — исправлено (R1).
6. Прямые записи обходили дебаунс — исправлено (R4).
7. Sharing violation при rename теряла запись — исправлено (R5).
8. Отравленный мьютекс блокировал записи до рестарта — исправлено (R6).
9. Ошибка sync в `applyRouting` оставляла запись в очереди — исправлено (R3).
10. `ModelSourcesStore` не перечитывался после единственной неудачной попытки — исправлено (R2).

Не исправлено осознанно: R7–R10 (обоснования в таблице).

### Остаточные ограничения

- Живой end-to-end прогон с новым бинарником не делался: приложение
  пользователя не перезапускалось; эффект подтверждён кодом, юнит-тестами и
  сборкой обеих платформ (macOS `xcodebuild`, Windows
  `cargo check --target x86_64-pc-windows-msvc`), но не логом работающего
  шлюза.
- Коалесинг не покрыт тестом: `configPath` — instance computed от
  `CodexStore.supportDir` без override, тест записал бы реальный пользовательский
  `config.yaml`, а DI путей выходит за минимальный диф. Покрыты чистая функция
  `configNeedsWrite` и оба Windows-пути записи.
- `DispatchWorkItem` в `scheduleConfigWrite` не обнуляется после выполнения —
  безвредно для синглтона (NIT).

## LOOP

- Repairs: 10 (REPAIR-1: coalescing в `applyRouting`, отказ при `!isLoaded`,
  guard мьютекса в `write_config_if_changed`; REPAIR-2: R1–R6 и R11 по ревью и
  новому требованию о виджете)
- Baseline: `ab26028cb0b5efaf2c96aeb0ded20f3912d81e68`
- Phase: DISCOVER → SPEC → BUILD → REVIEW → REPAIR → PASS
