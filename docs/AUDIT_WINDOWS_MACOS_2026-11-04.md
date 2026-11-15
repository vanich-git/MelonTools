# Аудит Windows и macOS — MelonTools 6.0.0

Дата: 2026-11-04. Основа: `8a7828d` плюс существовавшие до аудита локальные изменения и новые файлы. Аудит относится к **рабочему дереву**, не только к HEAD.

## Вердикт

**К стабильному публичному релизу текущий snapshot не готов.** Существенный набор тестов зелёный, но есть воспроизводимые релизные блокеры, дефекты ограничения расходов, подмены/потери данных и зависания планировщика. Это не означает, что приложение не работает вообще; это означает, что «всё работает стабильно и правильно» сейчас утверждать нельзя.

Исходный код, настройки, установленные приложения, токены и реальные профили не менялись. Добавлен только этот отчёт. Дополнительные probes выполнялись в временной копии и изолированных каталогах.

Приоритеты: **P1** — до стабильного релиза (сборка, расходы, данные, вечное зависание); **P2** — существенная функциональная проблема; **P3** — эксплуатационное улучшение. «Код» означает проверенную цепочку вызовов без исполнения live-сценария; «воспроизведено» — изолированный эксперимент.

## 1. Результаты проверок

| Проверка | Результат | Граница вывода |
|---|---|---|
| macOS Debug `xcodebuild test` | **342 теста, 7 skipped, 0 failures** | Локальный runtime уже присутствовал |
| macOS Release, `ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO` | **BUILD SUCCEEDED**, обе архитектуры | Не установка нового DMG |
| Bundled llama-server `--version` | arm64 и x86_64 выполняются, build 12099 | Intel slice под трансляцией, без загрузки модели |
| Runtime quick checks | **6 passed, 0 failed** | Не полный install/download |
| Windows `cargo test --locked`, исходное дерево | **FAIL**, lock требует обновления | Настоящий release blocker |
| Rust tests в временной копии с пересчитанным lock | **306 passed, 0 failed** | Исполнение на macOS, не Windows |
| Windows-target `cargo xwin check --tests` в временной копии | **PASS** | Компиляция, не запуск exe |
| `cargo fmt --check` | **FAIL** | CI gate, не runtime bug |
| Windows-target Clippy `-D warnings` | **FAIL** | Doc comment в production-коде |
| Localization lint | **PASS**, 1209 keys / 1135 call sites | Не визуальная проверка переводов |
| JS syntax, UI static guard, composer sync | **PASS**, 22 scripts / 124 commands | Не WebView2 integration |
| Island Chromium fixtures | compact / expanded / reenter **PASS** | Mock IPC |
| Main Windows UI Chromium smoke | **28 комбинаций RU/EN**, 0 JS errors/rejections | Browser preview, mock backend |
| Docs/manifest lint | **FAIL**, версии 6.0.0 / 5.5.8 расходятся | Distribution gate |
| Embedded Windows gateway verification | **PASS** | Существующий binary resource |
| Release checksums | Только static manifest checks **PASS** | Новые артефакты не передавались, это НЕ верификация 6.0.0 |
| Дополнительные Rust probes | **3 воспроизведения подтверждены** | Models collision, HTTP cancel, daily budget |
| Swift Process/pipe и APFS probes | **2 дефекта подтверждены** | Изолированные fixture-каталоги |

Логи во временном каталоге: [macOS tests](</private/tmp/melontools-audit-macos-20261104.log>), [Release](</private/tmp/melontools-audit-macos-release-20261104.log>), [Rust](</private/tmp/melontools-audit-rust-scratch-20261104.log>), [Windows-target](</private/tmp/melontools-audit-win-cross-final-20261104.log>), [Clippy](</private/tmp/melontools-audit-clippy-20261104.log>), [3 regression probes](</private/tmp/melontools-audit-repros-confirmed-20261104.log>). Системный tmp может очищаться.

## 2. Релизные блокеры

### REL-01 — P1 — macOS clean checkout не генерирует Xcode-проект

**Воспроизведено.** [project.yml:30–36](<../MacOS/app/project.yml#L30-L36>) требует Resources/runtime; [.gitignore:20–22](<../.gitignore#L20-L22>) исключает папку из Git. [CI:28–30](<../.github/workflows/ci.yml#L28-L30>) и [Release:83–85](<../.github/workflows/release.yml#L83-L85>) вызывают XcodeGen раньше загрузки runtime. Загрузка внутри [build.sh:39–44](<../MacOS/build.sh#L39-L44>) происходит слишком поздно.

В копии без ignored runtime: exit 1, `Target "MelonTools" has a missing source directory .../Resources/runtime`.

**Исправление:** fetch/verify runtime до первой генерации проекта в обоих pipelines; smoke чистого checkout. Не маскировать отсутствие runtime пустой папкой.

### REL-02 — P1 — Windows Cargo.lock не синхронизирован

**Воспроизведено.** [Cargo.toml](<../Windows/app/src-tauri/Cargo.toml#L1-L6>) — 6.0.0 с новой ZIP-зависимостью, [Cargo.lock:2142–2143](<../Windows/app/src-tauri/Cargo.lock#L2142-L2143>) — 5.5.8. Пересчёт lock в scratch изменяет 75 additions / 2 deletions: дело не только в версии.

`cargo test --locked` → exit 101, `cannot update the lock file ... because --locked was passed`. [CI](<../.github/workflows/ci.yml#L128-L132>) и [Release](<../.github/workflows/release.yml#L233-L236>) используют locked.

**Исправление:** обновить и включить lock в тот же snapshot, затем locked test/check/clippy на Windows.

### REL-03 — P1 — Distribution и quality gates красные

**Воспроизведено.** Приложение — 6.0.0, release notes/Homebrew/winget/lock — 5.5.8. [Winget](<../packaging/winget/vanich-git.MelonTools.installer.yaml#L1-L12>) скачивает 5.5.8. Docs lint сообщает mismatch/ошибку URL.

[local_runtime.rs:402–408](<../Windows/app/src-tauri/src/local_ai/local_runtime.rs#L402-L408>) ломает Clippy `-D warnings` (`empty_line_after_doc_comments`), форматирование также не проходит. Это CI blockers, не свидетельство падений runtime.

**Исправление:** синхронизировать metadata, версии и реальные хеши после сборки, исправить fmt/doc comment; получить зелёные [CI gates](<../.github/workflows/ci.yml#L125-L132>).

### REL-04 — P2 — Developer ID/notarization не учитывает новый macOS runtime

**Код.** [sign-macos.sh:113–124](<../packaging/sign-macos.sh#L113-L124>) обходит MacOS, Resources/bin, Frameworks, PlugIns, но не Resources/runtime. Локальные llama-server/dylib имеют ad-hoc signatures без TeamIdentifier.

**Риск:** signed/notarized ветка не подготовлена к новым nested Mach-O. Реальная отправка Apple не выполнялась, отказ notarization не выдаётся за наблюдавшийся факт.

**Исправление:** подписать runtime binaries/dylibs до bundle, согласовать SHA-256 manifest с изменёнными после codesign байтами; проверить signed DMG, staple и запуск на чистом Mac.

## 3. Дефекты корректности, данных и расходов

### CORE-01 — P1 — Обе ОС: дневной token budget выводится из обрезаемой истории

macOS: [trimHistory/tokensUsedToday](<../MacOS/app/MelonTools/Scheduler/SchedulerModels.swift#L625-L674>), [budget check](<../MacOS/app/MelonTools/Scheduler/SchedulerStore.swift#L515-L545>). Windows: [trim_history](<../Windows/app/src-tauri/src/scheduler.rs#L353-L370>), [tokens_used_today](<../Windows/app/src-tauri/src/scheduler.rs#L708-L728>).

На задачу остаётся 20 записей, глобально 200. После 60 запусков × 2000 tokens реальный расход 120000, после trim учитывается 40000, лимит 100000 не срабатывает. Если лимит достигнут раньше, blocked-записи без tokens тоже могут вытеснить расход из истории.

**Доказательство:** production-функции Windows вызваны дополнительным Rust probe; 120000 → 40000 подтверждено. В macOS идентичная цепочка проверена по коду.

**Исправление:** независимый durable usage ledger/counter по задаче и дню; history — только UI. Тесты >20 runs, >200 общих записей, skipped runs, day rollover.

### CORE-02 — P1 — macOS: большой Git-контекст навсегда блокирует планировщик

**Воспроизведено.** [SchedulerRunner:374–390](<../MacOS/app/MelonTools/Scheduler/SchedulerRunner.swift#L374-L390>) делает waitUntilExit до чтения Pipe. Git ждёт освобождения буфера, приложение — git. prefix(12000) применяется слишком поздно. [Task.detached](<../MacOS/app/MelonTools/Scheduler/SchedulerRunner.swift#L177-L186>) не наследует отмену; process timeout отсутствует.

Fixture: 1800 untracked-файлов, stdout 198000 байт; тот же Swift Process/pipe-порядок заблокирован >4 с и остановлен внешним watchdog. Серийная очередь в приложении остаётся занята.

**Исправление:** drain stdout во время работы, ограничить сохраняемый объём, timeout и process cancellation.

### CORE-03 — P1 — Windows: одинаковый basename подменяет веса моделей

**Воспроизведено.** [import:779–803](<../Windows/app/src-tauri/src/local_ai/local_models.rs#L779-L803>) создаёт уникальный model ID, но копирует в общий models/basename. [HF publish](<../Windows/app/src-tauri/src/local_ai/model_downloads.rs#L460-L499>) использует ту же схему. [delete](<../Windows/app/src-tauri/src/local_ai/local_models.rs#L726-L749>) не проверяет ссылки других записей.

Probe: два различных валидных GGUF с одинаковым именем → разные IDs, одинаковые files, байты A заменены B. Удаление B оставляет запись A без файла. Финальная проверка использовала канонический tmp-путь; первая неудачная попытка удаления на macOS была из-за symlink /tmp в fixture.

**Исправление:** отдельная managed-папка на модель/источник, shared-reference checks, транзакция публикации файла и реестра.

### CORE-04 — P1 — macOS: Work/work используют общий CODEX_HOME

**Воспроизведено на case-insensitive APFS.** [homePath](<../MacOS/app/MelonTools/Views/Codex/CodexInstancesView.swift#L207-L211>) зависит от имени, [duplicate check](<../MacOS/app/MelonTools/Views/Codex/CodexInstancesView.swift#L239-L256>) регистрозависим, [delete](<../MacOS/app/MelonTools/Views/Codex/CodexInstancesView.swift#L268-L272>) удаляет home. Временный fixture подтвердил samefile и удаление Work через work. Auth тоже будет общим.

**Исправление:** папка по UUID, имя только display; миграция существующих коллизий без удаления общего каталога.

### CORE-05 — P2 — macOS: ошибка vault может удалить gateway-копии токенов

**Код.** [load](<../MacOS/app/MelonTools/Codex/CodexStore.swift#L401-L428>) при новой схеме/corrupt vault не заполняет accounts. На первом старте массив пуст. [Автозапуск](<../MacOS/app/MelonTools/MelonToolsApp.swift#L84-L93>) всё равно передаёт его в gateway, [start](<../MacOS/app/MelonTools/Codex/CodexGatewayService.swift#L615-L659>) вызывает sync, [prune](<../MacOS/app/MelonTools/Codex/CodexGatewayService.swift#L503-L512>) удаляет все owned auth-файлы вне пустого desired.

В gateway могут находиться самые свежие rotated refresh-токены. Vault не обязательно теряется, но после восстановления может потребоваться login.

**Исправление:** отделить load failure/read-only от успешно загруженного пустого vault; запретить destructive sync/prune при failure.

### CORE-06 — P2 — Windows: Cancel не прерывает выполняющийся запрос

**Воспроизведено.** [cancel](<../Windows/app/src-tauri/src/scheduler.rs#L1247-L1277>) выставляет флаг, [execute](<../Windows/app/src-tauri/src/scheduler.rs#L1588-L1615>) не читает его и ждёт HTTP до 300 с. Flag проверяется после run.

Изолированный loopback probe выставил CANCEL во время HTTP; через 900 мс execute вернул ok и usage=100. Запрос продолжает расходовать токены после Cancel.

**Исправление:** cancellation-aware send/body read, tokio::select!, distinct cancelled без retry; тест до headers и во время body.

### CORE-07 — P2 — Windows: Local AI переживает обновление приложения

**Код; Windows live-сценарий не запускался.** [spawn](<../Windows/app/src-tauri/src/local_ai/local_runtime.rs#L1690-L1712>) без Job Object; [update_apply](<../Windows/app/src-tauri/src/main.rs#L1415-L1421>) завершает app без runtime.stop. Остановка только в [tray quit](<../Windows/app/src-tauri/src/main.rs#L1816-L1826>). Global exit-handler нет, kill-on-close реализован только для gateway.

Остаются RAM, порт и локальный API; следующий запуск может поднять второй engine.

**Исправление:** Job Object для обоих движков и общий lifecycle cleanup. Проверки upgrade, crash и logoff.

### CORE-08 — P2 — Windows: crash detection Local AI зависит от вкладки

**Код.** [get_status](<../Windows/app/src-tauri/src/local_ai/local_runtime.rs#L1483-L1491>) делает settle/reap, [IPC](<../Windows/app/src-tauri/src/local_ai/commands.rs#L71-L79>) синхронизирует gateway. [UI poll](<../Windows/app/ui/app.js#L532-L549>) активен только в Local AI; независимого native watcher нет.

На другой странице crash оставляет Ready и мёртвый маршрут до следующего status-вызова. В трее WebView может троттлить таймеры.

**Исправление:** Rust supervisor, обновление registry/routes без renderer.

### CORE-09 — P2 — macOS: Resume начинает загрузку заново, restart не восстанавливает очередь

**Код.** [resume](<../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L224-L260>) вызывает startDownload с [новым UUID/каталогом](<../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L172-L176>); старые [part/sidecar](<../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L479-L489>) не переиспользуются. [items/jobs](<../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L100-L117>) только в памяти. [downloadJournal](<../MacOS/app/MelonTools/LocalAI/LocalPaths.swift#L40>) объявлен, но больше нигде не используется.

Следствие: повторный многогигабайтный трафик, скрытые part-файлы, незавершённые загрузки не возвращаются в UI после quit/crash.

**Исправление:** durable journal + reuse job/path/sidecar; real Range/ETag и crash-resume tests.

### CORE-10 — P2 — Обе ОС: corrupt Local AI registry молча становится пустым

**Код.** macOS [catch](<../MacOS/app/MelonTools/LocalAI/LocalModelStore.swift#L764-L795>) присваивает []; Windows [load_registry](<../Windows/app/src-tauri/src/local_ai/local_models.rs#L623-L631>) возвращает default. Нет quarantine/read-only/видимой причины. Следующий import/save может затереть старые настройки/записи. Сами GGUF при load error не удаляются.

**Исправление:** fail-safe load-state, backup corrupt file, видимая ошибка, запрет overwrite до решения пользователя.

### CORE-11 — P2 — Обе ОС: Local AI обходит явный app proxy

**Код.** macOS [HF](<../MacOS/app/MelonTools/LocalAI/HuggingFaceService.swift#L179>), [downloads](<../MacOS/app/MelonTools/LocalAI/LocalDownloadManager.swift#L108-L112>), [catalog](<../MacOS/app/MelonTools/LocalAI/RuntimeCatalog.swift#L56>) не используют [NetworkProxy](<../MacOS/app/MelonTools/Core/NetworkProxy.swift#L36-L46>).

Windows [HF](<../Windows/app/src-tauri/src/local_ai/huggingface.rs#L111-L116>), [downloads](<../Windows/app/src-tauri/src/local_ai/model_downloads.rs#L286>) и runtime clients не применяют [proxy::apply](<../Windows/app/src-tauri/src/proxy.rs#L23-L58>).

System/environment proxy может работать независимо, но явная настройка приложения не соблюдается. В proxy-only сети Local AI может не работать при работоспособном Codex/gateway.

**Исправление:** общая фабрика external clients, loopback direct; проверка через тестовый proxy.

### CORE-12 — P2 — macOS: nil resetAt включает бессрочный быстрый polling

**Код.** [resetSoon(nil)](<../MacOS/app/MelonTools/Codex/CodexStore.swift#L1131-L1143>) = true; [blockState](<../MacOS/app/MelonTools/Codex/CodexStore.swift#L1315-L1337>) допускает nil. [Tick](<../MacOS/app/MelonTools/Codex/CodexStore.swift#L1176-L1186>) запрашивает management API каждые 1.5 с даже без трафика, пока блок жив.

**Исправление:** неизвестный reset не считать близким, обычная cadence/backoff. Точное влияние на CPU/батарею не измерялось.

### CORE-13 — P2 — Windows: сохранённые engine-настройки не обозначены pending

**Код.** [Save](<../Windows/app/ui/mt-actions.js#L2363-L2373>) закрывает диалог; [backend](<../Windows/app/src-tauri/src/local_ai/commands.rs#L40-L45>) только обновляет registry. Context/KV/offload/threads применяются через [preset при старте](<../Windows/app/src-tauri/src/local_ai/local_runtime.rs#L1388-L1417>).

**Исправление:** applied/pending индикация и Restart рядом с Save. Здесь НЕ утверждается, что Save сразу переписывает gateway YAML: handler его не синхронизирует.

## 4. Что улучшить для стабильной эксплуатации

- **MainActor latency macOS.** [Backup export/import](<../MacOS/app/MelonTools/Views/SettingsView.swift#L438-L507>) синхронно делает crypto/I/O; [PBKDF2](<../MacOS/app/MelonTools/Core/BackupService.swift#L620-L642>) — 600k rounds. [Scheduler save](<../MacOS/app/MelonTools/Scheduler/SchedulerStore.swift#L285-L295>) пишет всю history, потенциально ~12.8 MB текста. [Orphan cleanup](<../MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift#L736-L763>) делает Thread.sleep(1). Нужны background work, сериализация writes, progress/cancel; точный пользовательский latency не замерен.
- **Windows engine log rotation.** [Append-only log](<../Windows/app/src-tauri/src/local_ai/local_runtime.rs#L1680-L1688>) без лимита. Ограничение tail на чтении не ограничивает диск. Нужны size/count cap и soak-test.
- **Native UI E2E.** Chromium/mock smoke не доказывает WebView2 IPC/DPAPI/NSIS. Добавить keyboard/focus/dialogs, DPI 125/150/200%, tray/background. macOS [LocalAIUITests](<../MacOS/app/MelonToolsTests/LocalAIUITests.swift#L6-L11>) прямо pure-logic, не interaction tests.
- **Release acceptance.** Clean install, upgrade/rollback с активной моделью, interrupted downloads, full disk, detached storage, corrupt/newer-schema data, sleep/wake/logoff, длительная работа в трее.
- **Полнота snapshot.** Новый LocalAI-код и тесты ещё untracked; включить до тега. Тесты локального дерева не равны тестам опубликованного commit.

## 5. Безопасность и ограничения

Рассмотрены core services, scheduler/cron/persistence, Codex routing/auth/quotas, OAuth, backup, updater, CDP restrictions, GGUF bounds, archive path/link guards, LocalAI lifecycle/storage/downloads и основные views. Не найден подтверждённый P0 в проверенном собственном коде; это НЕ security certification и не полный аудит upstream/transitive dependencies.

[Security model](<SECURITY-MODEL.md#L21-L32>) уже описывает plaintext macOS vault под 0600 и отсутствие полноценной publisher authenticity у неподписанных releases. SHA-256/HTTPS не заменяют Developer ID/Authenticode.

Не проверены: нативный новый Windows exe/installer/DPAPI/WebView2, signed/notarized DMG/Gatekeeper, чистая macOS 14 и физический Intel Mac, реальная inference с моделью, многогигабайтный HF pause/resume, платные provider calls, длительный soak и полная VoiceOver-проверка. Семь skipped macOS tests включают opt-in engine/network E2E; старые отчёты не засчитывались за текущий прогон.

## 6. Порядок исправления / release gate

1. REL-01/02/03: чистая воспроизводимая сборка и зелёный CI; REL-04 до обещания notarized delivery.
2. CORE-01/03/04/05/10: расходы и данные, migration/recovery без потерь, regression tests.
3. CORE-02/06: отменяемый планировщик, bounded subprocesses, независающая очередь.
4. CORE-07/08/09/11/13: независимый от UI lifecycle, durable downloads, proxy, applied settings.
5. CORE-12, main-thread latency, rotation, native E2E и soak.

**Готовность:** все P1 закрыты regression-тестами, metadata и CI зелёные, Windows проверен нативно, macOS DMG прошёл чистую установку/upgrade, после exit/crash нет orphaned engines и ложных Ready/routes. До этого статус: работающая разработка 6.0.0 с существенными незакрытыми рисками, не подтверждённый stable release.
