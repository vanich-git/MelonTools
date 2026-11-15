# Melon Tools 6.0.0 — аудит Local AI и UI/UX

**Дата:** 4 ноября 2026. Проверена текущая рабочая копия, включая незакоммиченные изменения. Исходники, настройки моделей, Keychain и пользовательские файлы в ходе аудита не менялись. Этот документ — отчёт, не исправления.

## Вердикт

**Local AI пока нельзя считать стабилизированным.** На macOS базовый запрос к одной уже установленной модели может работать, но есть риски потери файлов, crash-loop на повреждённом GGUF, неверные статусы/метрики и гонки Start/Stop. На Windows обнаружен deadlock статуса и независимые несовместимости UI ↔ Rust, делающие основные сценарии неработоспособными.

P1 — блокер стабильного релиза/риск данных/зависание основной функции; P2 — существенная ошибка поведения/диагностики/производительности; P3 — локальная полировка. Общесистемный P0 не установлен. Windows deadlock — P1 release blocker, а не доказанная авария всей ОС.

## Что проверено и что нет

- macOS: `xcodebuild test` — **285 тестов, 1 skipped, 0 failures**, exit 0. Пропущен сетевой runtime install E2E.
- Windows host: `cargo test --bin melontools` — **269 passed**, exit 0. `cargo check --target x86_64-pc-windows-msvc --tests` — exit 0. Это не native Windows execution.
- Windows UI: static-check — **22 scripts, 121 whitelisted commands**; `node --check` — успешно.
- Изолированный router на отдельном временном порту: `/health` 200, `/models` показывает `unloaded`, детей 0; `/metrics` без model query — 400. Модель не загружалась. Процесс завершён, временный каталог очищен.
- GGUF текущей модели: прочитаны только metadata, без inference и загрузки весов.
- Изолированные harness: malformed GGUF, пути Foundation/APFS, tar links, redirect Authorization; Node VM воспроизвёл потерю SHA в реальном Windows API shim.
- **Computer Use выключен в профиле:** драйвер отказал. Новый GUI-прогон не выполнен, отказ не обходился shell/AppleScript. Скриншоты предыдущих ходов не являются текущей проверкой.
- Полный текст **ТЗ 6.0.0 не найден**. Architecture/runtime/HF docs — заявленные контракты, не замена ТЗ. Полное соответствие ТЗ не подтверждено.
- Не запускались тяжёлые inference/длительный soak, новые сетевые загрузки runtime/моделей, перенос пользовательских данных, native Windows/Intel. FPS/frame time/GPU footprint текущего UI не измерялись.

## 1. macOS — движок и интеграция

### M1 — P1. Start проверяет router, а не готовность выбранной модели

[LocalInferenceService.swift:248–267](../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L248-L267), [459–466](../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L459-L466), [ModelSources.swift:338–367](../MacOS/app/MelonTools/Codex/ModelSources.swift#L338-L367).

После `/health` все существующие модели получают `ready`. Нет `/models/load` и ожидания `loaded` конкретной модели. Проверено на установленном b12099: `/health → 200 {status:ok}`, одновременно `/models → unloaded`, детей процесса 0. UI «ACTIVE / Ready» и gateway advertisement могут предшествовать реальной загрузке/ошибке несовместимой модели.

**Исправить:** разделить router running / model available / loading / loaded / generating / sleeping. По явному Start загружать конкретную модель и ждать её статус, а не помечать все файлы готовыми.

### M2 — P1. Гонки Start/Stop, игнорирование отмены и смерти процесса

[LocalInferenceService.swift:161–170](../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L161-L170), [295–323](../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L295-L323), [539–550](../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L539-L550).

MainActor не делает async-функцию атомарной. `healthCheckTask` нигде не присваивается, `waitForHealth` не проверяет cancellation, sleep errors подавляются. Старый Start после Stop может позже вызвать глобальный stop и остановить новый процесс. Нет terminationHandler/постоянного health monitoring: после аварии остаются stale running/ready и gateway routes.

**Исправить:** сериализованный lifecycle + generation/operation owner, сохранённая launch Task, проверка process identity и cancellation на всех await, termination handler, нормализация реестра и gateway при аварии. Сценарии: Start A→Stop→Start B, Cancel при загрузке, crash parent/child.

### M3 — P1. Удаление работающей модели не выгружает её и не обновляет preset/routes

[LocalModelsView.swift:145–160](../MacOS/app/MelonTools/Views/LocalAI/LocalModelsView.swift#L145-L160), [LocalModelStore.swift:586–621](../MacOS/app/MelonTools/LocalAI/LocalModelStore.swift#L586-L621).

Delete сразу удаляет файлы/registry. На macOS unlink не освобождает загруженные mmap-страницы, router продолжает держать модель/старый preset; повторная загрузка из удалённого файла падает.

**Исправить:** drain/cancel запросов → unload → обновление preset/catalog → transactional delete; блокировать повторные операции.

### M4 — P2. Метрики не работают по текущему URL

[LocalInferenceService.swift:472–517](../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L472-L517).

Приложение опрашивает `/metrics`, router требует `?model=<id>`. Воспроизведён HTTP 400 `model name is missing from the request`; код молча возвращает nil.

**Исправить:** корректный encoded query и парсер labelled metrics, stale/error state; не грузить sleeping/unloaded модель фоновым мониторингом.

### M5 — P2. Console Output пустая, файл лога не ограничен

[LocalInferenceService.swift:58–67](../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L58-L67), [225–235](../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L225-L235), [LocalRuntimeView.swift:219–246](../MacOS/app/MelonTools/Views/LocalAI/LocalRuntimeView.swift#L219-L246).

stdout/stderr пишутся в append-файл. `logLines` нигде не наполняется: Clear есть, append/tail/pipe нет. UI и Copy Logs не получают реальную диагностику. Ротации/лимита файла нет.

**Исправить:** bounded ring buffer/tail, redaction, ротация, batched UI updates, чёткая семантика Clear.

### M6 — P2. Sampling/output настройки сохраняются, но не применяются как defaults

[LocalModelSettingsSheet.swift:520–546](../MacOS/app/MelonTools/Views/LocalAI/LocalModelSettingsSheet.swift#L520-L546), [LocalInferenceService.swift:434–454](../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L434-L454), [LocalModelTestSheet.swift:606–611](../MacOS/app/MelonTools/Views/LocalAI/LocalModelTestSheet.swift#L606-L611).

Preset не содержит maxOutputTokens/temperature/topP/topK/repeatPenalty/seed; gateway defaults не добавляет. Test передаёт только temperature и жёсткие 1536 output tokens. Многие поля интерфейса не влияют на inference, если клиент сам их не передал.

**Исправить:** контракт `request > model defaults > runtime defaults`; реализовать defaults или явно ограничить назначение полей UI.

### M7 — P2. Save без изменений/для другой модели обрывает все запросы

[LocalModelSettingsSheet.swift:543–546](../MacOS/app/MelonTools/Views/LocalAI/LocalModelSettingsSheet.swift#L543-L546), [LocalInferenceService.swift:366–371](../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L366-L371).

Любой Save вызывает глобальный stop/start. Перезапуск не согласован с активными запросами, ошибка подавлена try?, sheet закрывается.

**Исправить:** diff/hot-apply sampling, отдельное Apply engine settings с предупреждением/drain, показать applied revision и restart error.

### M8 — P2. Внешний custom binary может показываться как Bundled/Verified

[LocalInferenceService.swift:77–115](../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L77-L115), [LocalAISettingsTab.swift:113–134](../MacOS/app/MelonTools/Views/LocalAI/LocalAISettingsTab.swift#L113-L134).

Executable берётся из custom path, но provenance/version/digest label — из другого active RuntimeStore manifest.

**Исправить:** единый ResolvedRuntime (URL+provenance+manifest+digest именно выбранного файла), не выдавать unrelated manifest за проверку external executable.

### M9 — P2. Persisted ready не нормализуется при новом запуске

[LocalModelStore.swift:489–547](../MacOS/app/MelonTools/LocalAI/LocalModelStore.swift#L489-L547), [ModelSources.swift:343](../MacOS/app/MelonTools/Codex/ModelSources.swift#L343).

Наличие файла оставляет ready/loading/generating из старого registry, даже когда router не запущен. Возможны stale catalog/routes после crash или clean quit (stopSync не записывает installed).

**Исправить:** runtime states не считать durable; при bootstrap нормализовать и сверять с живым process/model state.

## 2. Память и контекст

### R1 — P1/P2. Оценка памяти не архитектурная; прежний совет про 16,8 ГБ не доказан

[LocalHardwareService.swift:239–290](../MacOS/app/MelonTools/LocalAI/LocalHardwareService.swift#L239-L290), [LocalModelSettingsSheet.swift:413–422](../MacOS/app/MelonTools/Views/LocalAI/LocalModelSettingsSheet.swift#L413-L422).

Embedding эвристически выбирается по размеру файла; реальные KV-heads/key/value length/GQA/hybrid/SSM/sliding layers не учитываются, gpuLayers игнорируется. Compute buffers и OS reserve входят в totalRequired. Intel-ветка больших weights стоит раньше проверки превышения RAM.

Из текущего Qwen3.5-2B GGUF: embedding=2048, layers=24, KV heads=2, key/value length=256, full attention interval=4, присутствуют SSM параметры. Код выбирает embedding=4096 и считает все 24 слоя обычным attention. Это не точная оценка этой модели.

**Исправление предыдущего ответа:** вычитать только weights из UI total и считать остаток KV было неверно; там ещё OS reserve/compute, сама KV-эвристика неверна для hybrid модели. Невозможность 68 903 контекста на этом Mac не установлена. Нужно отдельно измерить actual allocations/footprint/latency безопасным preset. Не увеличивать контекст вслепую и не запрещать по этому числу.

**Исправить:** сохранять GGUF KV/hybrid metadata, учитывать backend/slots/offload, выдавать диапазон и confidence, калибровать runtime allocations; отдельно weights/KV/SSM/compute/reserve/free budget.

### R2 — P2. Клиентский context округляется вверх до 8000

[CodexModelCatalog.swift:533–546](../MacOS/app/MelonTools/Codex/CodexModelCatalog.swift#L533-L546): `max(context,8000)` при реальных 2048/4096 рекламирует большее окно; auto_compact threshold тоже становится неверным.

**Исправить:** фактический configured/effective per-slot context, без округления вверх, отдельно native max/reserved output. Structured overflow error; не молча обрезать историю пользователя. Сторонний клиент не обязан читать Codex catalog.

### R3 — P2. Настройка Parallel=1 не отправляется, остаётся default auto

[LocalInferenceService.swift:212–215](../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L212-L215), [runtime-help.txt:468–469](../MacOS/build/runtime-help.txt#L468-L469). Флаг добавляется только при >1; закреплённый runtime default -1 (auto).

**Исправить:** всегда передавать validated parallel; тестировать actual properties/per-slot context и одновременные запросы.

## 3. Модели, загрузки, хранилище, runtime

### F1 — P1. Коллизии basename портят .part, перезаписывают файлы и API-id

[LocalDownloadManager.swift:96–115](../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L96-L115), [325–374](../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L325-L374), [LocalModelStore.swift:159–165](../MacOS/app/MelonTools/LocalAI/LocalModelStore.swift#L159-L165).

Дедупликация по repo+name, пути по одному name. Разные repo одновременно пишут в один .part; последовательная загрузка удаляет прежний final и заменяет registry id. Async import может дать разные id на один final. APFS case-insensitive collision не учтён.

**Исправить:** unique storage namespace + repo/revision/digest identity, reservation пути, no overwrite и единый registration pipeline.

### F2 — P1. До успеха copy/move удаляется старая модель

[LocalModelStore.swift:159–164](../MacOS/app/MelonTools/LocalAI/LocalModelStore.swift#L159-L164), [629–635](../MacOS/app/MelonTools/LocalAI/LocalModelStore.swift#L629-L635), [LocalDownloadManager.swift:363–408](../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L363-L408).

remove target → copy/move. При disk full/обрыве источника теряется старый файл. Download catch дополнительно удаляет .part при неуспешной финализации.

**Исправить:** staging на целевом томе, verify, atomic publish/replace, registry commit последним, rollback; сохранять resumable source.

### F3 — P1. Change Storage меняет корень без переноса/проверки

[LocalModelStore.swift:83–112](../MacOS/app/MelonTools/LocalAI/LocalModelStore.swift#L83-L112), [LocalAISettingsTab.swift:405–415](../MacOS/app/MelonTools/Views/LocalAI/LocalAISettingsTab.swift#L405-L415).

Все относительные files начинают указывать на новый каталог. Модели «пропадают» либо привязываются к чужим одноимённым файлам, которые затем можно удалить. Недоступный внешний том ведёт к silent fallback во внутренний models.

**Исправить:** раздельные операции migrate/connect, progress/checksums/rollback, volume identity/offline state, запрет destructive действий на непроверенном корне.

### F4 — P1. Split GGUF не проверяется на полноту; download каждого shard — отдельная модель

[LocalModelStore.swift:272–360](../MacOS/app/MelonTools/LocalAI/LocalModelStore.swift#L272-L360), [LocalDownloadManager.swift:370–404](../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L370-L404). Набор [1,3] из 3 принимается; отдельный shard отмечается installed; complete download может дать несколько карточек.

**Исправить:** grouped transaction 1...N, согласованность total/index, digest всех частей, одна запись/суммарный размер, регистрация только полного набора.

### F5 — P1. Malformed GGUF вызывает trap/OOM, возможен crash-loop старта

[GgufMetadata.swift:143–150](../MacOS/app/MelonTools/LocalAI/GgufMetadata.swift#L143-L150), [214–240](../MacOS/app/MelonTools/LocalAI/GgufMetadata.swift#L214-L240), [LocalModelStore.swift:516](../MacOS/app/MelonTools/LocalAI/LocalModelStore.swift#L516).

Unchecked UInt64→Int/array multiply и чтение skip в Data. Изолированный harness из исходника: length UInt64.max → exit 133; skip 200MB tiny-файла даёт крупную аллокацию. try? trap не ловит; registered file парсится вновь при запуске.

**Исправить:** checked arithmetic/conversions, file bounds/metadata budget, seek вместо alloc, strict malformed rejection, fuzz fixtures и safe startup quarantine.

### F6 — P1/P2. Непроверенные пути HF: обычный subdirectory ломает загрузку, .. может выйти за каталог

[LocalDownloadManager.swift:115](../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L115), [325–326](../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L325-L326), [HuggingFaceService.swift:248](../MacOS/app/MelonTools/LocalAI/HuggingFaceService.swift#L248).

`sub/model.gguf` требует несуществующую директорию, FileHandle падает после items.append → вечное Downloading. Traversal через недоверенный filename локально не запрещён; эксплуатация зависит от API input. `#`/`?` в имени превращаются в fragment/query URL.

**Исправить:** internal path id+safe basename, canonical containment, поддержка subdirectories, URLComponents/encoding без force unwrap, rollback item creation.

### F7 — P2. Resume/Cancel/recovery не являются устойчивой state machine

[LocalDownloadManager.swift:77–175](../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L77-L175), [233–270](../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L233-L270), [302–413](../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L302-L413).

После рестарта теряется validator, .part возобновляется без If-Range; без SHA возможна склейка ревизий. Проверка диска считает полный размер, не остаток. 416 полного .part не финализируется. Completion не проверяет paused/cancelled generation/state. Item опубликован до FileHandle — при ошибке stuck active.

**Исправить:** durable sidecar, identity/validator/offset, Content-Range start validation, state/generation guards, идемпотентный cancel, recoverable error, source/destination space check.

### F8 — P2. Hash/copy/metadata блокируют MainActor; нет throttle progress

[LocalDownloadManager.swift:350–366](../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L350-L366), [442–481](../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L442-L481), [LocalModelStore.swift:489–543](../MacOS/app/MelonTools/LocalAI/LocalModelStore.swift#L489-L543).

Многогигабайтный SHA и cross-volume move синхронны на main, registry metadata тоже; UI получает Published mutation на каждый network chunk. Это блокирует обработку кликов/Cancel; точная длительность не измерялась.

**Исправить:** worker I/O с cooperative cancel, chunked hash/copy, прогресс 4–10Hz, короткий publish на main, Instruments на больших файлах.

### F9 — P2. Backup миграции может быть поздним и неполным; нет GC

[LocalAIMigration.swift:25–85](../MacOS/app/MelonTools/LocalAI/LocalAIMigration.swift#L25-L85) инициализирует shared store до backup, repair registry может записать новое состояние. Marker ставится при отдельных ошибках copy. После crash hidden staging/.part остаются без startup GC.

**Исправить:** backup до shared-init, verified manifest/checksums, marker только после успеха, restore test, age+ownership GC без удаления active operations.

### F10 — P2/P3. Невидимый runtime и ложный успех Keychain

- `.metal-custom` проходит validID, но reload пропускает все hidden dirs: [RuntimePackageInstaller.swift:13–16](../MacOS/app/MelonTools/LocalAI/RuntimePackageInstaller.swift#L13-L16), [RuntimeStore.swift:347–349](../MacOS/app/MelonTools/LocalAI/RuntimeStore.swift#L347-L349). Запретить dot/reserved IDs.
- Старый HF token удаляется до SecItemAdd, Bool игнорируется, UI показывает Saved/configured=true: [LocalKeychainHelper.swift:10–23](../MacOS/app/MelonTools/LocalAI/LocalKeychainHelper.swift#L10-L23), [LocalModelStore.swift:120–127](../MacOS/app/MelonTools/LocalAI/LocalModelStore.swift#L120-L127). Использовать atomic update и возвращать OSStatus в UI.
- Таблица GGUF file_type 36–40 не соответствует закреплённому llama.h; часть новых форматов подписана неверно. Downloaded/native context может расходиться с userSettings 8192. Сверить enum/единый workingContext, fixtures на новые форматы.

## 4. UI/UX и плавность

### U1 — P2. Popover-select не имеет полноценного keyboard/AX picker-контракта

[MTMenuButton.swift:130–249](../MacOS/app/MelonTools/Design/MTMenuButton.swift#L130-L249), [MTSearchableSelect.swift:56–111](../MacOS/app/MelonTools/Design/MTSearchableSelect.swift#L56-L111).

Выделение нарисовано, но нет highlighted-vs-selected focus model, ArrowUp/Down/Home/End/Return/type-ahead обычного select, AX selected/expanded/value состояния. Есть Esc. Фиксированная ширина+lineLimit(1) может обрезать длинный текст. Это кодовые пробелы, не сегодняшнее визуальное воспроизведение.

**Исправить:** один reusable picker с клавиатурой/VoiceOver/focus restore/scroll-to-selected, динамической шириной в пределах экрана; tests mouse/outside/Esc/sheet/scroll/light/dark/RU/EN.

### U2 — P2. HF поисковые гонки исправлены лишь частично; ошибки теряются

[HuggingFaceCatalogView.swift:43–62](../MacOS/app/MelonTools/Views/LocalAI/HuggingFaceCatalogView.swift#L43-L62), [473–534](../MacOS/app/MelonTools/Views/LocalAI/HuggingFaceCatalogView.swift#L473-L534), [183–199](../MacOS/app/MelonTools/Views/LocalAI/HuggingFaceCatalogView.swift#L183-L199).

Generation guard только в success, не catch. Clear не инвалидирует запрос. LoadMore читает новый текст поля, а не identity показанного поиска. Search error записан в общий errorMessage, но при selectedRepo=nil right pane его не показывает.

**Исправить:** отменяемые tasks, immutable query/sort/cursor, generation во всех completion, separate inline errors и сохранение session drafts.

### U3 — P2. Test Model не проверяет публичный путь и имеет ошибочную статистику/отмену

[LocalModelTestSheet.swift:458–520](../MacOS/app/MelonTools/Views/LocalAI/LocalModelTestSheet.swift#L458-L520), [589–675](../MacOS/app/MelonTools/Views/LocalAI/LocalModelTestSheet.swift#L589-L675).

Тесты идут напрямую в router, обходят gateway/Responses/auth/catalog. Error body теряется до HTTP N. Tool probe Task не сохраняется/не отменяется onDisappear, isBusy его не включает. SSE chunks считаются токенами; reasoning при пустом answer копируется в answer и рисуется дважды.

**Исправить:** engine test отдельно от gateway E2E; Chat/Responses stream/nonstream/tools/cancel, sanitized structured errors, одна task ownership, usage/timings counters, раздельный reasoning/output.

### U4 — P2. Стриминг постоянно перепарсивает весь Markdown и отбирает scroll

[MarkdownText.swift:14–18](../MacOS/app/MelonTools/Views/LocalAI/MarkdownText.swift#L14-L18), [LocalModelTestSheet.swift:349–403](../MacOS/app/MelonTools/Views/LocalAI/LocalModelTestSheet.swift#L349-L403), [640–666](../MacOS/app/MelonTools/Views/LocalAI/LocalModelTestSheet.swift#L640-L666).

При каждом chunk полный accumulated text reparsed на main, IDs по offset, scroll-to-bottom при любом изменении. Суммарная работа растёт квадратично с длиной ответа; конкретный frame time не измерен.

**Исправить:** batching 30–100ms, cache завершённых блоков/incremental tail либо plain stream+final markdown; follow only near bottom, reduce motion support, Instruments.

### U5 — P3. Заявления о покрытии UI были сильнее фактических тестов

[ComponentLayoutTests.swift:20–51](../MacOS/app/MelonToolsTests/ComponentLayoutTests.swift#L20-L51) измеряет только fittingSize закрытого control. Не проверяется число/выбор options, popover, click, keyboard, светлая тема или edge clipping. Это НЕ snapshot/interaction tests и не гарантия «артефактов нет».

В [LocalModelsView.swift:8–44](../MacOS/app/MelonTools/Views/LocalAI/LocalModelsView.swift#L8-L44) есть FocusState, но обещанный Cmd-F отсутствует (в HF есть). Переключение Local AI tabs пересоздаёт screen state: [LocalAIView.swift:117–130](../MacOS/app/MelonTools/Views/LocalAI/LocalAIView.swift#L117-L130).

**Исправить:** component gallery + настоящие UI interaction/snapshot tests, единая keyboard/focus политика, сохранение query/selection/draft через view model.

## 5. Windows — подтверждённые несовместимости и блокеры

### W1 — P1 release blocker. get_status deadlock

[local_runtime.rs:1075–1107](../Windows/app/src-tauri/src/local_ai/local_runtime.rs#L1075-L1107) удерживает inner.lock и вызывает binary_path, снова захватывающий тот же non-reentrant Mutex: [962–963](../Windows/app/src-tauri/src/local_ai/local_runtime.rs#L962-L963). RuntimeStatus на входе/поллинге зависает; Start/Stop/metrics/delete ждут тот же lock.

**Исправить:** snapshot/drop lock до binary lookup либо helper с borrowed inner; regression timeout test в отдельном процессе. Подтверждено статически, native runtime не запускался.

### W2 — P1. HF UI ждёт file.name, backend отдаёт rfilename

[huggingface.rs:20–31](../Windows/app/src-tauri/src/local_ai/huggingface.rs#L20-L31) vs [mt-pages.js:1923–1935](../Windows/app/ui/mt-pages.js#L1923-L1935). Имя/data-file пустое, action возвращается до Download.

**Исправить:** единый DTO/adapter и UI tests на реальных serialized Rust fixtures, не на несовпадающем demo mock.

### W3 — P1. Settings profile enum несовместим, значения сбрасываются

[mt-actions.js:2280–2293](../Windows/app/ui/mt-actions.js#L2280-L2293) отправляет auto/speed/quality/low_memory/custom, Rust принимает Auto/Balanced/Performance/Memory Saver/Custom: [local_models.rs:50–58](../Windows/app/src-tauri/src/local_ai/local_models.rs#L50-L58). Save отклоняется. topK/repeatPenalty/batchSize жёстко перезаписаны, chatTemplate/reasoning/seed отсутствуют; truthiness меняет temperature=0 на 0.7.

**Исправить:** единый enum и validated patch/full settings с сохранением не редактируемых полей, числовая валидация без `||` для нуля.

### W4 — P1. DownloadStatus wire case не совпадает с UI

[model_downloads.rs:18–26](../Windows/app/src-tauri/src/local_ai/model_downloads.rs#L18-L26) сериализует Downloading/Completed/Failed, UI ждёт lowercase: [mt-pages.js:1974–2006](../Windows/app/ui/mt-pages.js#L1974-L2006). Cancel/active count/refresh/стили/clear finished неверны.

**Исправить:** единый wire enum, serialized contract tests и transition-based refresh.

### W5 — P1. SHA потерян в shim, сохранённый токен не применяется к download

[mt-api.js:712–713](../Windows/app/ui/mt-api.js#L712-L713) принимает 5 аргументов, caller передаёт SHA шестым: [mt-actions.js:2490–2497](../Windows/app/ui/mt-actions.js#L2490-L2497). Node VM подтвердил `shaPresent=false`. [commands.rs:162–174](../Windows/app/src-tauri/src/local_ai/commands.rs#L162-L174) не делает resolve_hf_token, хотя search/details делают. Resume без If-Range, GGUF проверка до installed неполна.

**Исправить:** полный typed request, передать SHA, resolve token на backend, durable validators, строгая GGUF/size/digest verification до atomic publish.

### W6 — P1. currentModel отсутствует в payload; Start/Stop не обновляют gateway

Rust отдаёт modelId, [mt-pages.js:1771](../Windows/app/ui/mt-pages.js#L1771) ждёт currentModel.id. Start остаётся вместо Stop, Restart/test ведут себя неверно. [commands.rs:72–85](../Windows/app/src-tauri/src/local_ai/commands.rs#L72-L85) не синхронизируют gateway config/catalog после переходов; gateway включает только registry Ready: [gateway.rs:268–286](../Windows/app/src-tauri/src/gateway.rs#L268-L286).

**Исправить:** один runtime DTO/state machine, lifecycle-triggered route/catalog sync и нормализация transient states.

### W7 — P1/P2. KV-formula занижена в 2048 раз относительно собственной модели; UI читает другие имена полей

[hardware.rs:123–130](../Windows/app/src-tauri/src/local_ai/hardware.rs#L123-L130) использует context/2048 вместо масштаба на tokens. UI читает modelWeightsBytes/kvCacheBytes/totalBytes/fitsInMemory, Rust отдаёт weightsSize/kvCacheSize/totalRequired/recommendation: [mt-pages.js:2414–2421](../Windows/app/ui/mt-pages.js#L2414-L2421).

**Исправить:** общий DTO и архитектурная оценка. macOS эвристику не считать точным эталоном (см. R1).

## Что признано корректным / не подтверждено как дефект

- Авто-bootstrap/warm-up локальной модели в текущем macOS startup отсутствуют; в idle-процессах llama-server не найден.
- Runtime installer использует staging, digest до распаковки, отбрасывает absolute/.., symlink/hardlink; скачанный код для validation не запускается. Обход archive validation в этом аудите не найден.
- При published LFS SHA macOS корректно считает digest; проблемы в lifecycle/коллизиях, не алгоритме SHA.
- Cross-origin URLSession redirect в отдельном тесте не передал Authorization; обычная redirect-утечка HF token не установлена.
- Прежний RSS probe одной модели на 15 циклах не показал циклический рост/остаточные child/fd. Это ограниченная положительная проверка, не доказательство отсутствия утечек за часы.

## Контракты/ТЗ: матрица

| Область | Статус |
|---|---|
| Нет автозапуска модели | Подтверждено текущим macOS startup/idle process |
| Единый gateway | Есть, но lifecycle/catalog consistency с дефектами |
| Честные Loading/Loaded/Ready/Sleeping | Не обеспечено abstraction macOS router |
| Pause/Resume/Cancel/restart recovery | Частично, state machine не доказана |
| Уникальные IDs/файлы | Не во всех путях |
| Split GGUF | Парсер есть, completeness/grouped download нет |
| Безопасный import/storage relocation | Не обеспечено |
| Runtime archive/hash | Основной путь реализован, edge cases есть |
| Метрики/логи | macOS data path сломан |
| Memory-aware config | Недостоверно macOS; formula/DTO сломаны Windows |
| Windows UI/backend parity | Не выполнено по базовым DTO/enum |
| UI плавность/нет артефактов | Не подтверждено: CU off, profiler/UI tests не выполнены |
| Полное соответствие ТЗ 6.0.0 | Не оценено: полного ТЗ нет |

## Порядок стабилизации и release gate

1. **Защита данных:** unique names/paths, no overwrite, atomic import/publish, path containment, bounds/fuzz GGUF, storage migration, split completeness.
2. **Windows blockers:** mutex + DTO/enum, settings, HF download integrity/token, state→gateway sync; fixtures сериализованные backend, не demo.
3. **Lifecycle:** generation/cancel/process identity/termination cleanup, реальный load/unload, gateway/preset/catalog consistency, no stale Ready.
4. **Настройки/диагностика:** request/defaults precedence, фактический context/per-slot budget, metrics query/labels, bounded logs.
5. **UX/performance:** off-main I/O, throttle, incremental rendering/auto-follow, picker keyboard/AX, search identity/errors, shared drafts.
6. **Memory advisor:** GGUF hybrid/GQA/slots/backend + confidence и runtime calibration.

Обязательные регрессии перед «стабильно»:
- Import A/foo+B/foo, case collision, две HF foo одновременно; disk full/volume detach/restart copy — без потери/подмены.
- Split 1/3, 1+3/3, complete 3/3; malformed GGUF lengths/arrays — без crash-loop.
- Start→Stop до health; Start A→B; Cancel test при загрузке; crash parent/child; повторный start; 20–50 циклов + 1–2h soak с footprint/fd/pid.
- Public gateway Chat/Responses, stream/nonstream/tools/auth/cancel/proxy direct; понятный context overflow.
- Actual per-slot context/parallel 1/2/4, idle unload без reload от metrics.
- Память Qwen35 при безопасных изолированных preset: actual allocation/latency; большой контекст только после согласования RAM-budget.
- UI mouse/keyboard/VoiceOver, RU/EN, light/dark, min window, edge screen, scroll/sheet/popover, hover/selected/disabled/Esc/outside/focus restore; streaming+download одновременно.
- Native Windows install/start/stop/settings/HF/cancel; cross-check не замена.

## Артефакты

- macOS log: `/tmp/melon-audit-xctest-20261104.log`; xcresult: `/tmp/melon-audit-xctest-20261104`.
- Windows tests: `/tmp/melon-audit-cargo-20261104.log`; cross: `/tmp/melon-audit-cross-20261104.log`.
- Подробный независимый файловый аудит: [AUDIT_LOCAL_AI_STORAGE_2026-11-04.md](AUDIT_LOCAL_AI_STORAGE_2026-11-04.md). Временные harness находятся в `/tmp/melon-audit`.

**Найденные дефекты этим аудитом не исправлены. Готовность приложения и отсутствие артефактов не объявляются.**
