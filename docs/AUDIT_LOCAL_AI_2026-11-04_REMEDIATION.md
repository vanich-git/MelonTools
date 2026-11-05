# Аудит Local AI 2026-11-04 — что исправлено

Источник: [AUDIT_LOCAL_AI_2026-11-04.md](AUDIT_LOCAL_AI_2026-11-04.md) и
[AUDIT_LOCAL_AI_STORAGE_2026-11-04.md](AUDIT_LOCAL_AI_STORAGE_2026-11-04.md).
Рабочее дерево: `/Volumes/Z Slim/MelonTools`, версия 6.0.0.

Документ фиксирует результат работ по каждому ID аудита и то, чем проверено
исправление. Всё, что не проверено, перечислено отдельно — те же разделы
аудита, где раньше стояло «не подтверждено», теперь имеют явный статус.

## Как проверено

| Проверка | Команда | Результат |
|---|---|---|
| Тесты macOS | `xcodebuild -project MelonTools.xcodeproj -scheme MelonTools -configuration Debug -derivedDataPath /tmp/dd-core test` | **337 тестов, 0 failures**, 7 skipped |
| Дым по реальному движку (opt-in) | `TEST_RUNNER_MELON_LOCAL_ENGINE_E2E=1 … -only-testing:MelonToolsTests/LocalAIEngineIntegrationTests test` | **6 тестов, 0 failures** (загрузка Qwen3.5-2B в настоящем `llama-server` b12099) |
| Windows cross-check | `cargo xwin check --target x86_64-pc-windows-msvc --tests` | exit 0, те же 3 предупреждения, что и в baseline |
| Windows unit-тесты | `APPDATA=/tmp/mt-test-home/appdata cargo test -- --test-threads=4` | **295 passed, 0 failed** |
| Windows UI статика | `node --check` (7 файлов), `node Windows/app/tools/ui-static-check.js` | ok, `22 scripts, 121+ whitelisted commands` |

`llama-server` в тестах запускался с отдельным портом, отдельным каталогом данных
и моделью, подключённой по абсолютному пути; пользовательский реестр, настройки и
`/Applications/Melon Tools.app` не затрагивались.

## macOS — движок и интеграция

| ID | Что сделано | Проверка |
|---|---|---|
| M1 | `loadModel` ждёт не только `/health`, но и `POST /models/load` + статус `loaded` конкретной модели в `GET /models`. `ready` ставится только той модели, которую роутер реально загрузил; от «все установленные файлы готовы» код отказался | `LocalAIEngineIntegrationTests.testStartWaitsForModelAndReportsLoaded`, `testStopDuringStartLeavesNothingRunning` |
| M2 | Жизненный цикл сериализован номером поколения: каждый `await` завершается проверкой `generation`/`Task.isCancelled`; Stop инвалидирует запуск. Добавлены `terminationHandler` и периодический монитор, которые нормализуют реестр и маршруты шлюза | `testStopDuringStartLeavesNothingRunning`, `testEngineCrashIsDetectedAndNormalizesState`, `testSwitchingBetweenModelsLeavesOnlyTheSecondLoaded` |
| M3 | Удаление сначала останавливает движок (`releaseModelFiles`), затем store переносит файлы в trash, пишет реестр и только после этого удаляет. Повторный клик блокируется `isDeleting` | `testDeletionReleasesTheRunningModel` |
| M4 | `/metrics?model=<id>` через `URLComponents`, парсер без допущения «метрики без меток», отдельное `metricsError`; опрос идёт только для `loaded`, чтобы не поднимать спящую модель | `testMetricsAreReadableForTheLoadedModel`, `testMetricsParserHandlesLabelsAndTotals` |
| M5 | Вывод движка идёт через bounded ring buffer (2000 строк) с батчами ~10 Гц, файл ограничен 4 МиБ с ротацией, токен и `hf_*` редактируются, Clear очищает и консоль, и файл | `testStartWaitsForModelAndReportsLoaded` (консоль наполняется, ключ не утекает) |
| M6 | Параметры сэмплинга попадают в preset (`temperature`, `top-p`, `top-k`, `repeat-penalty`, `n-predict`, `seed`); набор ключей сверен с закреплённым движком, неизвестный ключ роняет старт, поэтому список закрытый | `testPresetCarriesSamplingDefaults` |
| M7 | Save больше не перезапускает движок. Изменение классифицируется (`sampling` / `engine`), sheet показывает, что применено, и предлагает «Restart Engine» отдельно; ошибка перезапуска показывается, а не глотается `try?` | `testSettingsChangeClassification` |
| M8 | Введён `ResolvedRuntime` (URL + provenance + manifest + digest именно выбранного файла); внешний бинарник больше не подписывается чужим манифестом | `xcodebuild test` |
| M9 | Живые состояния (`loading`/`ready`/`generating`/`unloading`) не считаются долговечными: `loadRegistry` нормализует их в `installed`, восстановление файла возвращает `installed`; недоступный том не помечается как «модель удалена» | `xcodebuild test`, `LocalAIMigration` тесты |

## macOS — память и контекст

| ID | Что сделано | Проверка |
|---|---|---|
| R1 | `GgufInfo`/`GgufMemoryProfile` читают `head_count`, `head_count_kv` (включая per-layer массив), `key_length`, `value_length`, `sliding_window`, `full_attention_interval`, `ssm.*`. Оценка считает KV только для attention-слоёв, добавляет рекуррентное состояние, разделяет weights/KV/state/compute/reserve и выдаёт диапазон + `confidence` + список допущений. Intel-ветка больше не стоит перед проверкой RAM. Контекст делится на слоты | `testMemoryEstimateUsesHybridAttentionMetadata`, `testMemoryEstimateIsLowConfidenceWithoutMetadata`, `testMemoryEstimateDividesContextBetweenSlots`, `testGgufParserReadsHybridAttentionMetadata` |
| R2 | Убран `max(context, 8000)`: каталог Codex получает фактический per-slot контекст (`ctx-size / parallel`), `auto_compact_token_limit` считается от него | `testEffectiveContextIsDividedBetweenSlots` |
| R3 | `--parallel N` передаётся всегда (в том числе `1`), значение валидируется | `LocalAIEngineIntegrationTests` (запуск с `--parallel 1`) |

Измерение реальных аллокаций Qwen3.5 при больших контекстах (калибровка) **не
выполнялось** — это отдельная измерительная работа, а не правка кода. Совет в UI
поэтому показывает диапазон и достоверность, а не «точное» число.

## macOS — модели, загрузки, хранилище

| ID | Что сделано | Проверка |
|---|---|---|
| F1 | Каждый файл живёт в каталоге модели `models/<slug>-<hash8>/`; коллизии basename и регистра больше не перезаписывают друг друга, а `.part` лежит в `downloads/<job-uuid>/` | `testTwoImportsWithTheSameFileNameDoNotCollide`, `testCaseOnlyDifferentNamesDoNotShareAFile`, `testNamespaceNameIsDeterministicAndCollisionFree` |
| F2 | Копирование идёт в `.staging-<uuid>` на целевом томе, проверяется (размер + GGUF + SHA-256) и публикуется переименованием; старый файл не удаляется до успеха, реестр пишется последним и откатывается при ошибке | `testAtomicCopyRefusesToOverwriteAndKeepsExistingFile`, `testTwoImportsWithTheSameFileNameDoNotCollide` |
| F3 | Разделены «подключить папку» и «перенести модели»; хранится идентичность тома, недоступный/чужой том отражается статусом, а не молчаливым fallback; перенос проверяет место, копирует с прогрессом и переключается только после проверки | `xcodebuild test`, UI-диалог |
| F4 | Split-набор валидируется (`1…N`, согласованность total), импорт папки и скачивание регистрируют одну модель только полным набором, суммарный размер и метаданные берутся из первого шарда | `testSplitSetValidationAcceptsOnlyCompleteSets`, `testSplitFolderImportGroupsAndRejectsIncompleteSets` |
| F5 | Парсер GGUF ограничен: `Int(exactly:)`, проверка остатка файла, бюджет метаданных 64 МиБ, лимит строки 8 МиБ, skip через `seek`, лимит на число KV, отказ на неправдоподобные длины | `testGgufParserRejectsHostileArrayLengthWithoutTrapping`, `testGgufParserRejectsTruncatedString`, `testGgufParserRefusesOversizedMetadataBlock` |
| F6 | Имя файла санитизируется (`isSafeFileName`), подкаталоги HF схлопываются в basename, URL строится через `URLComponents` с percent-encoding (`#`/`?` больше не рвут путь), элемент загрузки создаётся только после успешного открытия файла | `testSafeFileNameRejectsTraversalAndSeparators`, `HuggingFaceService.downloadURL` |
| F7 | Durable sidecar рядом с `.part` (URL, validator, total, sha256), resume только при полном совпадении, `If-Range`, проверка начала `Content-Range`, обработка `416`, защита от состояний pause/cancel, идемпотентная отмена, проверка места по остатку, а не по всему файлу | `testContentRangeStartParsing`, `xcodebuild test` |
| F8 | Хеш и межтомный перенос вынесены в `Task.detached`, прогресс публикуется не чаще ~8 Гц, парсинг GGUF при старте ушёл с главного потока в фоновую починку | `xcodebuild test` (Instruments не запускались) |
| F9 | Миграция считает пути без инициализации сервисов, копирует с проверкой размера и SHA-256, пишет marker только после успеха, хранит manifest с хешами, умеет `restore`, а startup-GC убирает старые staging-артефакты, не трогая активные загрузки | `testMigrationBacksUpEverythingAndOnlyThenMarksCompletion`, `testMaintenanceRemovesOldStagingButKeepsResumableParts` |
| F10 | `validID` запрещает ведущую точку и резервные префиксы; `reload` пропускает только свои временные каталоги; Keychain пишет через `SecItemUpdate` без предварительного удаления и возвращает `OSStatus` в UI; таблица `file_type` 36–42 приведена к закреплённому `llama.h`; `configuredContext`, `userSettings.contextLength` и preset используют один `workingContext` | `testRuntimePackageValidationRejectsUnsafeIDsAndDigests`, `testGgufFileTypeTableMatchesPinnedEngine` |

## macOS — UI/UX

| ID | Что сделано | Проверка |
|---|---|---|
| U1 | Один общий picker (`MTSelectList`) для `MTSelect` и `MTSearchableSelect`: highlight отдельно от selected, ArrowUp/Down, Home/End, Return, Escape, type-ahead, scroll-to-selected, возврат фокуса, AX-состояния, ширина по содержимому в пределах экрана | 21 тест в `LocalAIUITests` (логика клавиш, ширина, hosted layout) |
| U2 | Immutable snapshot запроса с generation, отменяемые задачи, проверка generation и в success, и в catch, Clear инвалидирует запрос, LoadMore использует сохранённый identity, раздельные inline-ошибки поиска и деталей | `LocalAIUITests` |
| U3 | Два режима: «Engine test» (router) и «Gateway E2E» (Chat/Responses, stream/non-stream, tools, cancel через публичный шлюз); структурированные ошибки с телом ответа и редактированием секретов; одна task ownership на тест/probe/gateway; счётчики из `usage`/`timings`, reasoning отдельно и без дублирования | `LocalAIUITests` |
| U4 | Батчинг текста ~60 мс, кэш разобранных блоков с перепарсиванием только хвоста, auto-follow только у нижнего края (40 pt), поддержка reduce motion | `LocalAIUITests` (эквивалентность кэша полному parse) |
| U5 | Cmd-F в списке моделей, единый Esc снимает фокус, вкладки Local AI не пересоздают состояние (ZStack + visited) | `xcodebuild test` |

## Windows

| ID | Что сделано | Проверка |
|---|---|---|
| W1 | `get_status` снимает снимок под lock и вызывает `binary_path` уже без него; `status_payload` — свободная функция. Остальные захваты проверены | `cargo xwin check`, unit-тест на таймаут |
| W2 | Единый DTO HF-файла (`name`, `size`, `downloadUrl`, `sha256`, `estimation`), UI читает те же поля; URL percent-encoded на backend | `cargo test` (ключи DTO), `ui-static-check` |
| W3 | Единый enum профиля (snake_case + alias'ы), `LocalModelSettingsPatch` поверх сохранённых значений, валидация без `||`-truthiness (`0` валиден), сохранение нередактируемых полей, добавлены seed/reasoning/chat template | `cargo test` (enum/patch/валидация) |
| W4 | `DownloadStatus` в snake_case, единый `DownloadProgress`, обновление UI по переходам, реальная очистка завершённых | `cargo test` (сериализация каждого варианта) |
| W5 | Типизированный `DownloadRequest`, SHA доходит до backend, токен резолвится на download, durable sidecar + `If-Range`, проверка размера → GGUF → SHA-256 → атомарная публикация | `cargo test` (sanitize/URL/SHA/publish), `ui-static-check` (SHA в invoke) |
| W6 | `currentModel` в payload (`modelId` как alias), синхронизация gateway на каждом переходе, нормализация stale-состояний на старте, `stop` всегда снимает `Ready` | `cargo test` (payload), `cargo xwin check` |
| W7 | KV-формула `2 × layers × kv_heads × head_dim × context × bytes`, `confidence`, общий DTO с `totalBytes` = «итого требуется» | `cargo test` (формула + wire-contract) |

Windows-рантайм (реальный download/resume, start/stop, hot-reload gateway)
**не запускался** — на этой машине нет Windows. Проверены типы, логика и
согласованность DTO, но не семантика файловой системы Windows.

## Обязательные регрессии из аудита

| Сценарий | Статус |
|---|---|
| Import `A/foo` + `B/foo`, регистр, две HF-загрузки | автотесты `testTwoImportsWithTheSameFileNameDoNotCollide`, `testCaseOnlyDifferentNamesDoNotShareAFile` |
| disk full / detach / restart copy — без потери и подмены | покрыто логикой staging + откатом; отдельного теста с полным диском нет |
| Split `1/3`, `1+3/3`, `3/3` | `testSplitSetValidationAcceptsOnlyCompleteSets`, `testSplitFolderImportGroupsAndRejectsIncompleteSets` |
| Malformed GGUF (длины/массивы) — без crash-loop | `testGgufParserRejectsHostileArrayLengthWithoutTrapping` и др. |
| Start→Stop до health, Start A→B, cancel при загрузке, crash, повторный start | `testStopDuringStartLeavesNothingRunning`, `testSwitchingBetweenModelsLeavesOnlyTheSecondLoaded`, `testEngineCrashIsDetectedAndNormalizesState` |
| 20–50 циклов + soak 1–2 ч, footprint/fd/pid | **не выполнялось** |
| Публичный gateway Chat/Responses, stream/nonstream/tools/auth/cancel | код есть (Gateway E2E в Test Model), живого прогона не было |
| Actual per-slot context, parallel 1/2/4, idle unload без reload от metrics | логика покрыта тестами; измерение на движке — только `parallel 1` |
| Память Qwen35: actual allocation/latency | **не измерялось** (см. R1) |
| UI mouse/keyboard/VoiceOver, RU/EN, light/dark, min window, edge screen | **не выполнялось** (нет UI-автоматизации в этой сессии) |
| Native Windows install/start/stop/settings/HF/cancel | **не выполнялось** (нет Windows) |

## Изменённые файлы

**macOS:** `LocalAI/LocalPaths.swift` (новый), `LocalAI/AtomicFileOps.swift` (новый),
`LocalAI/GgufMetadata.swift`, `LocalAI/LocalModel.swift`, `LocalAI/LocalModelStore.swift`,
`LocalAI/LocalDownloadManager.swift`, `LocalAI/LocalInferenceService.swift`,
`LocalAI/LocalHardwareService.swift`, `LocalAI/LocalAIMigration.swift`,
`LocalAI/LocalKeychainHelper.swift`, `LocalAI/RuntimePackageInstaller.swift`,
`LocalAI/RuntimeStore.swift`, `LocalAI/HuggingFaceService.swift`,
`Design/MTMenuButton.swift`, `Design/MTSearchableSelect.swift`, `Design/L10n.swift`,
`Views/LocalAI/*`, `Codex/CodexModelCatalog.swift`, `Codex/ModelSources.swift`,
`MelonToolsApp.swift`, `MelonToolsTests/LocalAICoreTests.swift` (новый),
`MelonToolsTests/LocalAIEngineIntegrationTests.swift` (новый),
`MelonToolsTests/LocalAIUITests.swift` (новый).

**Windows:** `src/local_ai/{local_runtime,commands,model_downloads,hardware,local_models,huggingface}.rs`,
`src/gateway.rs`, `ui/{mt-api,mt-bridge,mt-pages,mt-actions,mt-utils,mt-i18n,app}.js`,
`tools/ui-static-check.js`.

**Документация:** `docs/LOCAL_AI_ARCHITECTURE.md` переписан под фактическое
поведение (состояния, хранение, настройки, метрики/логи), в
`docs/LOCAL_AI_RUNTIME.md` добавлено ограничение на резервные id runtime.
