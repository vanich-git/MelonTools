# Аудит Local AI: память, остановка, отказы (macOS и Windows)

Дата: 2026-11-07. Ревизия: рабочее дерево `/Volumes/Z Slim/MelonTools` (не коммичено).
Область: всё, что относится к локальным моделям в двух приложениях Melon Tools.

---

## 0. Главное

1. **Это две независимые реализации, а не одна.** Windows-приложение — Tauri/Rust
   (`Windows/app/src-tauri`, ~17 500 строк `local_ai`), macOS-приложение — Swift/Xcode
   (`MacOS/app/MelonTools/LocalAI`, 8 499 строк). Общего кода у них нет: только формат
   данных и порты. Любой вывод ниже относится к конкретной реализации, и переносить его
   на вторую нельзя.
2. **Windows (Rust): движок раньше не убивал своих детей.** На Windows остановка
   вызывала `Child::kill()` — завершался только router, а `llama-server` с загруженной
   моделью продолжал держать гигабайты RAM и порт. На Unix `SIGKILL` уходил одному pid.
   Исправлено: `taskkill /T /F` на Windows, `killpg` на Unix, плюс pid-файл и «жатва»
   осиротевшего движка при следующем старте.
3. **Windows: остановка не разрывала релей системного промпта.** После Stop релей
   продолжал держать upstream-порт и отвечал `502` вместо честного `503`. Исправлено.
4. **Windows: релей мог съесть память на мусорном запросе.** Не было лимита на строку
   статуса и заголовки, а превышение тела молча обрезало запрос. Теперь `413` и жёсткие
   лимиты `64 КиБ` на голову, `64 МиБ` на тело.
5. **Windows: проверка API могла забанить ключ.** `check_api` повторял запрос после
   `401`; движок бан­ит адрес и ключ после пяти `401` на 30 минут. Повтор убран,
   осталась одна попытка.
6. **Windows: `local_ai_set_binary_path` не проверял путь.** Можно было записать в
   настройки каталог или не-PE файл, получить невнятную ошибку запуска и «залипшее»
   состояние. Теперь проверка `is_file()` + `validate_pe_x64`, запись на диск до
   изменения состояния, ошибки пробрасываются в UI.
7. **Windows: путь к модели не проверялся на выход из каталога.** `load_model` принимал
   `../` и каталоги. Теперь `canonicalize` + обязательное вхождение в каталог моделей.
8. **macOS (Swift): нашлась критическая потеря данных.** При переносе каталога моделей
   с удалением исходника (`migrateModelsDirectory(deleteSource: true)`) приложение
   удаляло файлы *всех* моделей, включая те, что пользователь подключил ссылкой из
   другого места: `fileURLs(in:)` пропускает абсолютные пути насквозь, а фильтр был
   только «не `/dev/`». Исправлено: удаляются только относительные записи реестра,
   лежащие строго внутри каталога моделей.
9. **macOS (Swift): два гарантированных падения (trap) исправлены.** `Int(Double.nan)`
   при разборе `/metrics` (движок или чужой сервис на переиспользованном порту может
   отдать `nan`/`inf`) и `UInt64(...)` в оценке памяти при абсурдном значении контекста
   из реестра. Оба пути теперь насыщают значение вместо падения.
10. **macOS (Swift): остановка движка не гасила релей системного промпта.** `stop()`
    существовал, но не вызывался ниоткуда: слушающий сокет и `upstreamPort` жили до
    выхода из приложения, а опубликованный в конфиге шлюза порт отвечал `502` на
    остановленный движок. Теперь `stop()`/`stopSync()` вызывают `SystemPromptProxy.stop()`
    и сбрасывают upstream в `0`.
11. **Открытых дефектов не осталось.** Всё, что перечислено в первом выпуске отчёта,
    исправлено; сводка по идентификаторам — раздел 5. За рамками остались только
    осознанные компромиссы (повтор при `bind` вместо передачи сокета, https-only runtime,
    невозможность убить чужой процесс на Windows, отказ добивать router'ы живого
    стороннего родителя) — см. 5.3.
12. **Проверки:** Windows — `cargo xwin check` exit 0, `cargo test` **492 passed /
    0 failed / 1 ignored**, `cargo fmt --check` чисто. macOS — `xcodebuild build` и
    `xcodebuild test -only-testing:MelonToolsTests/LocalAICoreTests`
    (**38 passed / 0 failed**). Артефакты не пересобирались, в GitHub ничего не
    отправлялось.

---

## 1. Методика и границы

Что читалось построчно: весь `Windows/app/src-tauri/src/local_ai/` (17 514 строк),
`gateway.rs`, `main.rs`, `engine_job.rs`, `paths.rs`, `proxy.rs`; весь
`MacOS/app/MelonTools/LocalAI/` (8 499 строк), `MelonToolsApp.swift` в части завершения.

Что **не** проверялось: UI-слой за пределами вызовов (вёрстка, локализация), Go-движок
`cliproxyapi` (патчится отдельно, `MacOS/patches/`), сам `llama.cpp`, установленное
`/Applications/Melon Tools.app` (не трогалось), поведение под реальной нагрузкой на
Windows (нет VM/Wine на этой машине).

Терминология портов (одинаковая в обеих реализациях):
- **18317** — Go-шлюз `cliproxyapi` (management, ключ из настроек приложения);
- **18318** — router `llama-server` (свой ключ, файл `runtime_token.txt`);
- **третий порт** — HTTP-релей системного промпта, публикуется вместо 18318.

Путать ключи нельзя: ключ 18317 не подходит к 18318, и наоборот. Это уже приводило
к «0 моделей» в каталоге.

---

## 2. Windows: Tauri/Rust

### 2.1 Память

| Находка | Где | Severity | Состояние |
|---|---|---|---|
| Диагностика публикации читала **весь** `gateway.log` в строку; watchdog ротирует его на 32 МиБ, за долгую сессию файл больше | `local_ai/commands.rs:765` | Средне | исправлено: окно 64 КиБ от конца через `seek`, первый обрезанный фрагмент отбрасывается |
| `fetch_runtime_metrics` создавал новый `reqwest::Client` на каждый вызов (пул соединений, TLS-контекст) | `local_ai/local_runtime.rs:383` | Низко | исправлено: общий `OnceLock<Client>`, `no_proxy`, connect 1 с, timeout 3 с |
| Тело запроса релея копировалось целиком (`body.clone()`) при каждом проксировании, лимит 64 МиБ | `local_ai/system_prompt_proxy.rs:339` | Высоко | исправлено: `std::mem::take(&mut request.body)` передаёт тело по владению, копии `Vec<u8>` на пути нет |
| Релей: поток на соединение, таймауты 600 с, без ограничения числа соединений | `system_prompt_proxy.rs:48,253` | Средне | исправлено: `ACTIVE_CONNECTIONS` + `ConnectionSlot` (32 слота); сверх лимита — `503` + `Connection: close` |
| Кэш аватаров Hugging Face без вытеснения и с отрицательным кэшированием `429`/`5xx` | `local_ai/huggingface.rs:126,203-251` | Низко | исправлено: LRU на 512 записей (`AvatarCache`); ошибки сети/`429`/`5xx` в кэш не попадают (`AvatarLookup::Failed`) |
| `MAX_HEAD` не было: чтение головы росло до размера мусора в сокете | `system_prompt_proxy.rs:33,612,625` | Высоко | исправлено: 64 КиБ на строку статуса и на голову, при превышении — `413`/закрытие |
| `read_chunked` не ограничивал суммарный размер до сложения | `system_prompt_proxy.rs:359` | Высоко | исправлено: `size > MAX_BODY \|\| len + size > MAX_BODY` → `TooLarge` |

### 2.2 Остановка и завершение

| Находка | Где | Severity | Состояние |
|---|---|---|---|
| **Дети движка не убивались.** `child.kill()` завершал router, а `llama-server` модели оставался с RAM и портом | `local_runtime.rs:1357` | **Критично** | исправлено: Windows `taskkill /PID <pid> /T /F` + `child.kill()`; Unix `killpg(SIGKILL)` |
| Нет ожидания фактического завершения: `kill(); wait();` мог вернуться раньше | `local_runtime.rs:1357` | Средне | исправлено: цикл `try_wait` до 3 с, затем повторный `kill` |
| При аварии движка не оставалось следов для «жатвы»: pid нигде не сохранялся | `local_runtime.rs:1335-1354` | Высоко | исправлено: `engine.pid` пишется при старте, удаляется при штатной остановке |
| Осиротевший после краха движок никто не добивал (Windows: job object помогает только если процесс-хозяин умер штатно; Unix: ничего) | `local_runtime.rs:1485` | Высоко | исправлено: `reap_orphan_engine()` в `LocalRuntimeManager::new`; на Windows образ сверяется через `tasklist /FI "PID eq …"`, затем `taskkill /PID … /T /F`; на Unix — `ps -o command=` и `killpg`. В тестах отключено, чтобы `cargo test` не убил движок работающего приложения |
| Unix-потомки не попадали в отдельную группу → `killpg` нечего было убивать | `local_runtime.rs:2723` | Высоко | исправлено: `cmd.process_group(0)` |
| После Stop/падения релей продолжал слать на мёртвый порт (`502` вместо `503`) | `local_runtime.rs:1703` | Средне | исправлено: `set_upstream(0)` в `settle`, `stop_locked`, `discard_child`, `fail_launch`, `unpublished` |
| Watchdog мог автостартовать шлюз после ручной остановки: проверка `user_stopped` шла до 15-секундного health-проба | `main.rs:1783` | Средне | исправлено: флаг перечитывается непосредственно перед `gateway::start` |
| `terminate_engine` ждёт до 3 с через `std::thread::sleep` внутри async-пути, блокируя поток tokio | `local_runtime.rs:1410` | Средне | исправлено: `terminate_engine_async` ждёт `try_wait` без сна потока; синхронный вариант остался только для не-async контекста |
| `block_on(runtime.stop())` на `RunEvent::Exit` без таймаута: зависший движок держит выход | `main.rs:114,143` | Средне | исправлено: `stop_runtime_bounded` — `tokio::time::timeout(5 s)`; повтор на выходе не выполняется (`runtime_stop_attempted`) |
| Двойной `gateway::stop` (Exit и tray quit) может дважды пройти по `taskkill /IM` fallback'у | `gateway.rs:1300`, `main.rs:1866` | Низко | исправлено: `Gateway.stopped` + `mark_running()`; повторный `stop` возвращает `Ok("already stopped")` и не запускает `taskkill /IM` |
| Счётчик `restarts >= 3` не сбрасывается и не виден в UI: после трёх рестартов watchdog молча выключается до перезапуска приложения | `main.rs:67-86,1783` | Средне | исправлено: `healthy_streak` сбрасывает `restarts` после 20 здоровых тиков; причина отключения пишется в `disabled_reason` и в лог |
| Тик супервизора может запустить шлюз в момент выхода приложения | `main.rs:2459-2486` | Низко | исправлено: `shutting_down` выставляется `begin_shutdown()` до первой остановки и перечитывается непосредственно перед `gateway::start` |
| `detect_hardware` (до 8 с PowerShell) вызывается под замком жизненного цикла | `local_ai/hardware.rs:395,560` | Средне | исправлено: `detect_hardware_async` вызывается до `lifecycle.lock()` в `load_model` |

### 2.3 Отказы (rejection)

| Находка | Где | Severity | Состояние |
|---|---|---|---|
| `check_api` повторял запрос после `401`, а движок банит адрес/ключ после пяти `401` на 30 минут | `gateway.rs:1906` | Высоко | исправлено: одна попытка, без повтора |
| Пустой список моделей от `/v1/models` давал невнятный успех | `gateway.rs:1967` | Средне | исправлено: `Err((0, "the engine returned an empty model list…"))` |
| Каталог API считался достоверным при любом 2xx, даже без массива `data` | `local_ai/commands.rs:2628` | Средне | исправлено: `verified = true` только при реальном массиве; иначе «каталог без списка моделей» |
| `set_custom_binary_path` принимал каталог/не-PE, писал настройку и только потом падал на запуске | `local_runtime.rs:1980` | Высоко | исправлено: `is_file()`, `validate_pe_x64` (Windows), запись до мутации, `Result` в UI (`commands.rs:2720`) |
| `load_model` принимал `../`, абсолютный путь и каталог | `local_runtime.rs:2567` | Высоко | исправлено: `canonicalize` каталога моделей и пути, `starts_with`, `is_file()` |
| `find_available_port` возвращал `0`/паниковал при отсутствии порта | `local_runtime.rs:2252` | Средне | исправлено: `Result<u16, String>` с понятным текстом |
| Настройки модели не проверяли `cpu_threads`, `gpu_offload_layers`, `kv_cache_type`, переводы строк в шаблоне | `local_models.rs:203` | Средне | исправлено: границы 1..=1024, allowlist из 9 KV-типов, шаблон — одна строка |
| Ошибка скачивания сообщала только «Download failed» | `model_downloads.rs:377` | Средне | исправлено: код + подсказка (401/403, 404, 429, 416) + тело до 300 символов |
| Сброс `.part` при неудачной проверке Range терял причину | `model_downloads.rs:340` | Низко | исправлено: причина в сообщении |
| Имя файла модели не ограничивалось по длине (лимит ФС ~255 байт) | `model_downloads.rs:655` | Низко | исправлено: 200 символов |
| Причина падения движка — только код выхода | `local_runtime.rs:1703` | Средне | исправлено: хвост `llama-server.log` (12 строк, ≤2000 символов) в тексте ошибки |
| `router_error_message` теряет HTTP-статус | `local_runtime.rs:105` | Низко | исправлено: `router_error_message(body, status)` — статус в тексте; `401/403` → `RouterFetchError::Unauthorized` |
| Сбой `bind` релея молча отключает системный промпт | `system_prompt_proxy.rs:32` | Средне | исправлено: `LAST_ERROR` + `last_error()`; текст попадает в `PublicationState.prompt_relay_error` и в диагностику публикации |
| `fetch_router_models` возвращает `None` на `401/403`: неверный токен выглядит как таймаут загрузки на 180 с | `local_runtime.rs:1635-1730` | Средне | исправлено: `RouterFetchError::{Unauthorized,Http,Network,Malformed}` различает коды; латч `router_key_rejected` останавливает опрос. Повторных проб нет: движок банит адрес после пяти `401` |
| После `begin_lifecycle` ранний `Err` в `load_model` оставляет статус не переведённым | `local_runtime.rs:2567` | Средне | исправлено: 13 путей отказа переводят статус через `fail_launch_error` под проверкой поколения |
| `find_available_port` освобождает порт и только потом его занимает (TOCTOU) | `local_runtime.rs:2252` | Низко | исправлено: `ENGINE_PORT_ATTEMPTS = 3` — при ошибке `bind` запуск повторяется на следующем порту вместо 180-секундного таймаута |
| Мьютексы с `unwrap()` могли паниковать при отравлении | `local_runtime.rs:1980+` | Низко | исправлено: `unwrap_or_else(\|e\| e.into_inner())` |

---

## 3. Что именно изменено (файлы)

### 3.1 Windows (Rust/Tauri)

- `Windows/app/src-tauri/src/local_ai/local_runtime.rs` — pid-файл, `terminate_engine`,
  `reap_orphan_engine`, `process_group(0)`, `settle` (хвост лога + `set_upstream(0)`),
  `set_custom_binary_path`, `find_available_port`, канонизация пути модели, общий
  `router_client`, `wrap`-устойчивые замки.
- `Windows/app/src-tauri/src/local_ai/system_prompt_proxy.rs` — `MAX_HEAD`, `ReadFailure`,
  `413`, лимиты `read_chunked`/`take_line`/`take_head`.
- `Windows/app/src-tauri/src/local_ai/commands.rs` — диагностика с окном 64 КиБ, строгий
  `verified`, проброс ошибки `set_binary_path`.
- `Windows/app/src-tauri/src/gateway.rs` — `check_api` без повтора, пустой список как отказ.
- `Windows/app/src-tauri/src/local_ai/local_models.rs` — `validate()`.
- `Windows/app/src-tauri/src/local_ai/model_downloads.rs` — подсказки по HTTP, причина
  сброса, лимит имени.
- `Windows/app/src-tauri/src/main.rs` — повторная проверка `user_stopped`.
- `Windows/app/src-tauri/Cargo.toml` — `[target.'cfg(unix)'.dependencies] libc = "0.2"`
  (обновляет `Cargo.lock`; сборки идут с `--locked`).

### 3.2 macOS (Swift)

- `MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift` — `parseMetrics`/`counter`
  без trap на `nan`/`inf`; `clamp` не пропускает `nan` в пресет; `releaseModelFiles`
  останавливает движок, если выгрузка модели не удалась, а `unloadModelFromRouter`
  проверяет `2xx` и реальное исчезновение модели из `/models`; `stop()`/`stopSync()`
  гасят релей; порядок `ensureCurrent` перед остановкой в `start`; «жатва» осиротевших
  детей `reapOrphanedEngines(binary:)` / `reapOrphanedEnginesSync(binary:)`.
- `MacOS/app/MelonTools/LocalAI/SystemPromptProxy.swift` — `maxHead` 64 КиБ / `maxBody`
  64 МиБ, `413` вместо молчаливого усечения, `RequestRead`/`BodyRead`, `takeLine`/
  `takeHead` с лимитами, `writeAll` повторяет `write` на `EINTR`, `merge` нормализует
  query-строку.
- `MacOS/app/MelonTools/LocalAI/LocalModelStore.swift` — `removeOwnedCopies` удаляет
  только относительные записи, лежащие внутри каталога моделей.
- `MacOS/app/MelonTools/LocalAI/LocalHardwareService.swift` — `clampedBytes`,
  ограничения `layers`/`totalTokens`/`batch`.
- `MacOS/app/MelonTools/Views/LocalAI/LocalModelSettingsSheet.swift` — верхняя граница
  (`4 194 304`) числового поля, чтобы абсурдный контекст не доходил до оценки памяти и INI.
- `MacOS/app/MelonTools/MelonToolsApp.swift` — при выходе гасятся загрузки и установка
  runtime (`.download-`/`.install-` больше не висят до суток).
- `MacOS/app/MelonTools/MelonToolsTests/LocalAICoreTests.swift` — два теста на
  экранирование INI (`testPresetFlattensNewlinesInChatTemplate`,
  `testPresetSanitisesSectionName`).

### 3.3 Второй проход (ремедиация 2026-11-07)

Разбивка по идентификаторам — в 5.1–5.2; здесь — по файлам.

- `local_ai/system_prompt_proxy.rs` — `mem::take` вместо `body.clone()`,
  `ACTIVE_CONNECTIONS`/`ConnectionSlot`, `LAST_ERROR`/`last_error()`, лимит на голову
  ответа upstream.
- `local_ai/local_runtime.rs` — `RouterFetchError` + латч `router_key_rejected`,
  `terminate_engine_async`, `detect_hardware_async` до `lifecycle.lock()`,
  `ENGINE_PORT_ATTEMPTS`, `publish_ready` (запись `Ready` и переход статуса под одним
  замком), 13 путей `fail_launch_error`, `router_error_message(body, status)`,
  `reap_orphan_engine` через `tasklist`/`taskkill`, https-only `validate_install_url`,
  async `set_custom_binary_path`.
- `local_ai/huggingface.rs` — LRU-кэш аватаров на 512 записей, `AvatarLookup`
  (ошибки сети/`429`/`5xx` не кэшируются).
- `local_ai/hardware.rs` — `detect_hardware_async`.
- `local_ai/commands.rs` — `prompt_relay_error` в состоянии публикации и тесты к нему.
- `main.rs` — `shutting_down`, `runtime_stop_attempted`, `stop_runtime_bounded`, сброс
  `restarts` по `healthy_streak`, `begin_shutdown()`.
- `gateway.rs` — `Gateway.stopped`/`mark_running()`, идемпотентный `stop`.
- `MacOS/…/LocalInferenceService.swift` — `setpgid`/`killpg`, сверка поколений,
  «жатва» по `ps -axo pid=,ppid=,command=`, таймауты и `checkHealth` со `status`,
  `routerStatesSnapshot() -> [String: RouterModelStatus]?`.
- `MacOS/…/SystemPromptProxy.swift` — лимит соединений и `503`, таймауты upstream,
  `takeHead(limit:)` для ответа, один проход по JSON, кэш реестра промптов.
- `MacOS/…/LocalKeychainHelper.swift` — `KeychainError`, `loadHuggingFaceTokenResult()`.
- `MacOS/…/HuggingFaceService.swift` — `HubReply`, таймаут 30 с, один повтор.
- `MacOS/…/HFAvatarService.swift` — `actor` с вытеснением, `Outcome`.
- `MacOS/…/LocalModelStore.swift` — бросающие `saveStorageLocation`/
  `migrateModelsDirectory`, `registry.corrupt-<ISO8601>.json`, `saveRegistryInBackground`,
  безопасные `fileURLs`; `LocalModel.swift` — `LocalModelSettings.validate()`.
- `MacOS/…/RuntimePackageInstaller.swift` — таймауты и лимиты вывода/манифеста.
- `MacOS/…/LocalDownloadsView.swift` — баннер `journalError`, текст ошибки в строке.
- `MacOS/app/MelonTools/MelonToolsTests/LocalAICoreTests.swift` — набор остался 38 тестов,
  все зелёные.


---

## 4. macOS: Swift

> Раздел заполняется по результатам построчного разбора `MacOS/app/MelonTools/LocalAI/`
> и `MelonToolsApp.swift`. macOS-приложение не использует Rust-код Windows-версии.

### 4.1 Что уже видно

Состояние на момент аудита; что из этого исправлено — таблицы 4.2 и раздел 5.

- Остановка (`LocalInferenceService.stop`, `:545`) посылает `SIGTERM` только router'у;
  через 3 с — `SIGKILL` тоже только router'у (`:567` `stopSync`, `:780`
  `terminateProcess`). Дети router'а при `SIGTERM` завершаются сами (проверено
  документом `docs/RSS_ROUTER_B12099.md`, раздел «Методика»: после `SIGTERM` проверялось
  отсутствие parent/child и свободность порта), но при `SIGKILL` router'а они остаются.
- `reapOrphanedEngines` (`:1037`, вызов из `MelonToolsApp.swift:141`) ищет процессы по
  `pgrep -f <путь к бинарнику>` и добивает их `SIGTERM` → `SIGKILL`. Это закрывает
  последствия краха, но только при следующем запуске приложения.
- `applicationWillTerminate` (`MelonToolsApp.swift:151`) вызывает `stopSync()` — выход
  не оставляет router'а.

### 4.2 Находки

Разбор шёл тремя параллельными проходами (загрузки и установка runtime; реестр,
железо, Hugging Face и Keychain; служба вывода и релей) по ревизиям файлов на момент
13:08–13:10. Номера строк ниже — на момент аудита; после второго прохода часть из них сместилась, актуальные ориентиры — в 5.2. Уровни:
**Критично** — потеря данных или падение; **Высоко** — утечка/зависание/неверная
остановка; **Средне** — заметный дефект с обходным путём; **Низко** — косметика и
редкие гонки.

#### 4.2.1 Память и ресурсы

| Где | Уровень | Находка | Состояние |
|---|---|---|---|
| `LocalInferenceService.swift:1502–1545` | Высоко | `Double("nan")`/`Double("inf")` из `/metrics` проходили в `Int(...)` — trap и падение приложения без диагностики. Достаточно чужого сервиса на переиспользованном порту 18318. | **Исправлено**: `value.isFinite, >= 0, <= 9e15` при разборе, `counter(_:)` насыщает вместо `Int(_:)`. |
| `LocalHardwareService.swift:116–300` | Высоко | `UInt64(kvBytes)` и ещё 10 конверсий `Double → UInt64` без проверки: `nan`/`inf`/переполнение — trap прямо в `body` панели. `totalTokens` брался из реестра без границ. | **Исправлено**: `clampedBytes`, `layers ≤ 4096`, `totalTokens ≤ 4 194 304`, `batch ≤ 65 536`. |
| `SystemPromptProxy.swift:251–273` | Высоко | На каждый `accept` — `DispatchQueue.global().async { handle(client) }` без семафора. Порт релея публикуется в конфиг шлюза, поэтому любой локальный процесс может открыть N соединений и держать их до 600 с: поток + 16 КиБ буфер + до 64 МиБ тела на соединение, вплоть до OOM. | **Исправлено**: `maxConnections = 32` + `reserveConnection()`/`releaseConnection()`; сверх лимита — фиксированный `503` без потока и буферов. |
| `SystemPromptProxy.swift:281–284, 484–500` | Средне | Таймауты `SO_RCVTIMEO`/`SO_SNDTIMEO` ставятся только клиентскому сокету. Зависший router, принявший соединение и замолчавший, вешает обработчик навсегда. `takeHead` для ответа вызывается с `limit: .max` (`:672`) — ответ не ограничен, в отличие от запроса. | **Исправлено**: те же 600 с выставляются upstream-сокету; `takeHead(limit: maxHead)` — 64 КиБ, при превышении `502`. |
| `SystemPromptProxy.swift:281–330` | Низко | Тело копируется трижды (`request.body` → `Data(body)` в `modelId` → `Data(body)` в `merge` → `[UInt8](rewritten)`), а `systemPrompt(for:)` перечитывает и декодирует весь реестр на каждый POST. | **Исправлено**: `modelId`/`merge` работают с `[UInt8]` без `Data(...)`-копий; `promptSnapshot` кэширует декодированный реестр и перечитывает его только при смене mtime/размера. |
| `LocalInferenceService.swift:1635–1662` (`gatewayYAML`) | Низко | Метод не вызывается ниоткуда (живой путь — `ModelCatalogOverlay`/`ModelSourcesStore`), но публикует порт router'а в обход релея и подставляет `internalToken`/`model.id`/`displayName` в YAML без экранирования. | **Исправлено**: `gatewayYAML()` удалён вместе с блоком `MARK: - Gateway Integration`; `grep -rn gatewayYAML MacOS/app` пуст. |
| `SystemPromptProxy.swift:53–85` | Низко | `start()` проверяет `boundPort` под локом, а `bindEphemeral()` выполняет вне лока — check-then-act: два параллельных вызова создадут двух слушателей, первый утечёт. Сейчас вызывается только с MainActor. | **Исправлено**: `bind` и присвоение `boundPort` под одним замком; второй вызов видит уже поднятый слушатель. |
| `LocalHardwareService.swift:521–526` | Низко | `ByteCountFormatter` создаётся на каждый вызов `formatBytes` (в теле панели — десятки раз). | **Исправлено**: `static let byteFormatter` — один экземпляр на процесс. |

#### 4.2.2 Остановка и завершение

| Где | Уровень | Находка | Состояние |
|---|---|---|---|
| `LocalInferenceService.swift:929–950` + `:609–624` | Высоко | `unloadModelFromRouter` вызывался через `try?` без проверки статуса, после чего вызывающий удалял файлы модели. При неудачной выгрузке router продолжал отдавать уже удалённую (mapped) модель, память не освобождалась, повторный импорт того же пути падал — ровно тот сценарий, который комментарий `:601–607` объявляет предотвращённым. | **Исправлено**: проверка `2xx` + опрос `/models` до 2 с; при неудаче `releaseModelFiles` останавливает движок. |
| `LocalInferenceService.swift:650–670` | Высоко | `stopWithoutBumpingGeneration()` стоял **до** `try ensureCurrent(operation)`. Отмена в Swift кооперативная, поэтому вытеснённый запуск успевал снести движок, только что поднятый более новым запуском, и лишь потом падал с `CancellationError`. | **Исправлено**: проверка до остановки и повторная после. |
| `LocalInferenceService.swift:545–570` | Средне | `SystemPromptProxy.stop()` не вызывался ниоткуда: после Stop слушающий сокет и `upstreamPort` жили до выхода, `publishedPort` продолжал отдавать порт релея, шлюз видел живой сокет с `502` вместо закрытого порта. При рестарте `setUpstream` вызывался до спавна — релей в окне запуска пересылал на порт без слушателя. | **Исправлено**: `stop()`/`stopSync()` гасят релей, `upstreamPort = 0`. `setUpstream` до спавна оставлен осознанно: порт релея стабилен, окно закрывается первым же запросом. |
| `LocalInferenceService.swift:785–830` | Средне | Ни `stopWithoutBumpingGeneration()`, ни `terminateProcess()` не сверяют `generation`/`processGeneration`; `process = nil` ставится до ожидания, статус `.stopped` выставляется безусловно и может затереть `.starting` нового запуска. Процесс-группа не создаётся (`setpgid`/`killpg` нет), `SIGTERM`/`SIGKILL` бьют только router. | **Исправлено**: `setpgid(pid, pid)` после `run()`; `signalEngine` шлёт `kill(-pid, …)` с fallback на `kill(pid, …)`; `terminateProcess(expectedGeneration:)` сверяет поколение до и после каждого `await`. |
| `LocalInferenceService.swift:1084–1135` | Средне | `pgrep -f <путь к бинарнику>` + `kill` всем найденным, кроме `getpid()`: нет проверки родителя, порта и `--host`. Убивается **любой** `llama-server`, запущенный из того же пути, включая процесс пользователя из другого инструмента. Вызывается и на каждом старте (`MelonToolsApp.swift:141`). | **Исправлено**: разбор `ps -axo pid=,ppid=,command=`; добиваются только осиротевшие (`ppid == 1` или мёртвый родитель) с совпадением пути, `--host 127.0.0.1` и порта из 18318…18348; чужие живые родители не трогаются. |
| `LocalInferenceService.swift:571–600` | Средне | `stopSync()` ждёт завершения busy-wait'ом `usleep(100_000)` до 3 с **на главном потоке**; при медленном `SIGTERM` приложение выглядит зависшим, а на logout/shutdown macOS может убить его раньше. | **Исправлено**: busy-wait убран: SIGTERM группе + 10×50 мс, затем SIGKILL + 4×50 мс (≤ 0,7 с); на пути выхода ~0,2 с. |
| `LocalInferenceService.swift:487–518` | Средне | При занятости всего диапазона 18318…18348 `findAvailablePort` молча возвращал занятый `start`; router падал на `bind`, и через 60 с пользователь видел «движок не поднялся» вместо «порт занят». | **Исправлено**: `Int?` + `EngineFailure.portUnavailable`, статус модели возвращается в `.installed`. |
| `MelonToolsApp.swift:151–186` | Средне | `applicationWillTerminate` не вызывал `LocalDownloadManager.shared.shutdown()` и `RuntimeStore.shared.cancelInstall()`: незавершённые загрузки и распаковки оставляли `.download-`/`.install-` мусор, который `LocalAIMigration` чистит только через 24 ч. | **Исправлено**: оба вызова добавлены перед `stopSync()`. |
| `LocalInferenceService.swift:847–875` | Низко | `checkHealth` считает признаком живого router'а любой `200` с JSON без поля `status`. Посторонний сервис на порту будет принят за движок, после чего ему отправят `/models/load` с `Bearer internalToken` — утечка токена чужому процессу. | **Исправлено**: `checkHealth` требует HTTP 200 **и** JSON `status == "ok"` или `"ready"`; иначе порт считается занятым чужим сервисом. |
| `LocalInferenceService.swift:954–992` | Низко | `routerStatesSnapshot` возвращает `[:]` и при ошибке запроса, поэтому пустой ответ `/models` неотличим от «ничего не загружено»; на 5-секундном тике это может сбросить `loading` → `installed` у реально загружающейся модели. | **Исправлено**: `routerStatesSnapshot() async -> [String: RouterModelStatus]?` — `nil` при ошибке/не-200/неразборе, `[:]` только для валидного пустого ответа; вызывающие не сбрасывают `loading` на `nil`. |

#### 4.2.3 Отказы и валидация

| Где | Уровень | Находка | Состояние |
|---|---|---|---|
| `LocalModelStore.swift:321–352` | **Критично** | `removeOwnedCopies` удалял `model.fileURLs(in: root)` для каждой модели, а `LocalModel.fileURLs` (`LocalModel.swift:256–270`) пропускает абсолютные пути насквозь. `migrateModelsDirectory(deleteSource: true)` удалял пользовательский GGUF, подключённый ссылкой из другого каталога. | **Исправлено**: удаляются только относительные записи, чей `standardizedFileURL` лежит под `root`. |
| `LocalDownloadManager.swift` (`handleResponse`) | Высоко | Не-`2xx` ответ проходил дальше и его тело писалось в `.part`; в конце пользователь получал «файл не GGUF» вместо «сервер ответил 403». | **Исправлено**: явная проверка `2xx` до ветки `416`, сообщение с кодом. |
| `LocalDownloadManager.swift` (`cancelDownload`) | Высоко | Отмена удаляла весь каталог задания, включая уже проверенные `.completed` части, если живых строк не осталось. | **Исправлено**: каталог удаляется только когда в нём нет ни активных, ни завершённых частей. |
| `LocalDownloadManager.swift` (`downloadURL`, `saveSidecar`) | Средне | URL загрузки не проверяется по схеме/хосту; `saveSidecar` пишет через `try?` и молча теряет состояние докачки. | **Исправлено**: `isSecureDownloadURL` требует `https` и непустой хост; `saveSidecar`/`readJournal` возвращают и логируют ошибку (`Logger`, category `LocalDownloads`). |
| `RuntimePackageInstaller.swift:168–190` | Средне | `run()` вызывает `waitUntilExit()` без таймаута: зависший `tar` на битом архиве вешает установку навсегда, `Cancel` не действует. `Data(contentsOf: runtime.json)` (`:68–69`) читается без ограничения размера. | **Исправлено**: `commandTimeout = 120` с + `terminationGrace = 2` с (`terminate()` → `SIGKILL`), `maximumOutputBytes = 4 МиБ`, `maximumManifestBytes = 1 МиБ`; `Cancel` прерывает установку. |
| `LocalModelStore.swift:138–175` | Средне | `saveStorageLocation` пишет через `try?`, а `loadCustomPath` при ошибке молча возвращается к внутреннему каталогу: пользователь видит «настройка сохранена», модель ищется не там. | **Исправлено**: `saveStorageLocation` бросает ошибку; `connectModelsDirectory` откатывает смену при неудаче; `migrateModelsDirectory` падает до `removeOwnedCopies`. |
| `LocalModelStore.swift:979–991` | Средне | При повреждении реестра делается ровно одна резервная копия `.unbacked`, без `fsync`; второй случай перезаписывает её. `updateModelStatus` (`:1010–1024`) игнорирует результат `saveRegistry()`. | **Исправлено**: копия `registry.corrupt-<ISO8601>.json` на каждый случай + `fsync`; запись — на `registryIOQueue` с проверкой поколения (`saveRegistryInBackground`), `updateModelStatus` сообщает об ошибке. |
| `LocalKeychainHelper.swift:41–56` | Низко | Любой `OSStatus`, включая `errSecInteractionNotAllowed`/`errSecAuthFailed`, превращается в `nil` → `LocalModelStore.swift:75–77` показывает «токен не настроен» вместо «Keychain заблокирован». | **Исправлено**: `KeychainError` + `loadHuggingFaceTokenResult()`: `errSecItemNotFound` = «токена нет», прочие статусы = ошибка с кодом; старый API сохранён обёрткой. |
| `HuggingFaceService.swift:184–190, 240–252` | Низко | Все HTTP-ошибки схлопываются в один `NSError` «status code N», без повторов и явных таймаутов; `NetworkProxy.swift:60–68` добавляет только текст. | **Исправлено**: `HubReply` несёт HTTP-код и тело (до 512 байт), `requestTimeout = 30` с, один повтор на транзиентную ошибку (`isTransient`). |
| `HFAvatarService.swift:45, 65–106` | Низко | `requests[key]` никогда не удаляется, кэш на диске растёт без вытеснения, `store(nil)` кэширует отсутствие аватара на 7 дней в том числе для `429`/`5xx`/сетевой ошибки. | **Исправлено**: `actor` с `maximumEntries = 200` и `lifetime = 7 дней`, `evictOldest`; `Outcome` различает «нет аватара» и «ошибка» — `429`/`5xx`/сеть не кэшируются, `requests` очищается. |
| `LocalInferenceService.swift:1351–1359` | Низко | `clamp` = `min(max(v, lower), upper)`; для `nan` оба сравнения ложны, и в пресет попадало `temperature = nan`. | **Исправлено**: `guard value.isFinite`. |
| `SystemPromptProxy.swift:101–118` | Низко | `isRewritable` срезает `?query`, а `merge` проверял `path.hasSuffix("/chat/completions")` по сырому target: при `POST /v1/chat/completions?x=1` системный промпт молча не применялся. | **Исправлено**: `merge` нормализует путь так же. |
| `SystemPromptProxy.swift:573–583` | Низко | `writeAll` возвращал `false` при `written <= 0` без обработки `EINTR`: прерванный сигналом `write` обрывал ответ на середине. | **Исправлено**: `if written < 0, errno == EINTR { continue }`. |
| `LocalModel.swift:237–270` | Низко | `fileExists`/`fileURLs`/`primaryFileURL` принимают абсолютные пути, `..`, каталоги и симлинки; `LocalModelSettings` не имеет `validate()`. | **Исправлено**: `LocalModelSettings.validate()` (контекст, batch, потоки, GPU-слои, temperature/topP/topK, KV-тип) вызывается перед сохранением и запуском; `fileURLs` отбрасывает `..`, каталоги и симлинки. Связанные модели по-прежнему поддержаны. |
| `LocalModelStore.swift:68–88, 905–915` | Низко | Синхронные чтение/запись реестра и обращения к Keychain выполняются на MainActor. | **Исправлено**: запись реестра — на `registryIOQueue` с проверкой поколения; Keychain читается вне MainActor (`Task.detached`), UI получает результат через `await`. |

### 4.3 Что сделано правильно

Чтобы список не читался как «всё плохо»: ниже — решения, которые выдержали разбор и
менять их не нужно.

**Остановка и поколения.**
- Дисциплина поколений: `ensureCurrent` после каждого `await`, сверка `process === p` и
  `operation == processGeneration` — поздний ответ не перетирает состояние нового запуска.
- Эскалация `SIGTERM → 3 с → SIGKILL` есть в обоих путях (`stopSync` и `terminateProcess`),
  плюс «жатва» осиротевших детей в ветке `SIGKILL` и при старте приложения.
- `stopSync()` действительно вызывается из `applicationWillTerminate`, а `AppRuntime.isTesting`
  не даёт тестам убивать живой движок.
- `process = nil` до ожидания — осознанно: `handleProcessTermination` молчит на
  запрошенную остановку и сообщает `.failed` только о неожиданном выходе.

**Релей системного промпта.**
- `maxHead` 64 КиБ / `maxBody` 64 МиБ, `413 Payload Too Large` вместо молчаливого
  усечения, `RequestRead`/`BodyRead` с явными `.tooLarge`/`.incomplete`.
- `Content-Length` не дренируется — соединение закрывается; hop-by-hop заголовки
  вырезаются, `Host`/`Content-Length`/`Connection: close` пересчитываются.
- `SO_NOSIGPIPE` на обоих сокетах, `defer close` на клиенте и upstream, потоковая
  передача тела по 16 КиБ.

**Пресет и INI.**
- `iniBare`/`iniValue` экранируют `[`/`]`/`\r`/`\n`/NUL, allowlist `allowedKvCacheTypes`,
  верхние границы `ctx-size`/`batch-size`/`n-gpu-layers`/`threads`/`top-k`/`n-predict`.
  Покрыто двумя тестами.
- `temperature = nan` больше не проходит (см. 4.2.3).

**Логи.**
- Кольцо 2000 строк, `pendingPartial` 64 КиБ, ротация 4 МиБ, `redact()` токенов,
  `reset()` закрывает прежний `fileHandle`.

**Загрузки и установка.**
- `RuntimePackageInstaller` отвергает абсолютные пути и `..` в членах tar, распаковывает
  в scratch-каталог `.extract-UUID`, проверяет `arm64e` и статус — zip-slip закрыт.
- `AtomicFileOps.sha256Hex` — потоковый, с проверкой `Task.isCancelled`.
- `isSafeFileName`, `ownedNamespaceDirectory` и проверка `downloadURL` не дают выйти из
  каталога загрузок.
- `LocalDownloadManager.shutdown()` корректно закрывает журнал, отменяет задачи,
  закрывает хэндлы и инвалидирует сессию.

**Хранилище и железо.**
- `GgufMetadata` читает только заголовок с бюджетами (64 МиБ / 8 МиБ / 1M KV) — файл
  модели целиком в память не поднимается.
- Атомарная запись реестра с откатом в памяти и блокировкой записи при повреждении.
- `LocalHardwareService` не запускает `Process`/`Pipe`, обновляется по событиям, а не
  таймером, и честно отдаёт `confidence`/`assumptions` вместо ложной точности.
- Keychain: `SecItemUpdate`, и только на `errSecItemNotFound` — `SecItemAdd`;
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

**Память в целом.**
- `[weak self]` во всех долгоживущих задачах, `URLSession` закеширован
  (`NetworkProxy.directSession`), таймеров и наблюдателей `NotificationCenter` в
  `LocalInferenceService` нет вовсе — циклических ссылок и «вечных» подписок не найдено.

---

## 5. Второй проход: находки закрыты

Раздел переписан после ремедиации 2026-11-07. Исходный список (25 пунктов: 3 высоких,
14 средних, 8 низких) закрыт полностью, как и все строки «Открыто» в таблицах 2.1–2.3
и 4.2. Где именно — в этих таблицах; ниже сводка по идентификаторам, компромиссы и
границы проверки.

### 5.1 Windows (W1–W17)

| ID | Находка | Исправление |
|---|---|---|
| W1 | Тело запроса релея копировалось целиком | `std::mem::take(&mut request.body)` — передача по владению, без `clone()` (`system_prompt_proxy.rs:366`) |
| W2 | Поток на соединение без ограничения параллелизма | `ACTIVE_CONNECTIONS` + `ConnectionSlot` на 32 соединения; сверх лимита `503` + `Connection: close` (`:48,253`) |
| W3 | Сбой `bind` релея молча отключал системный промпт | `LAST_ERROR`/`last_error()`; текст уходит в `PublicationState.prompt_relay_error` и в диагностику (`:32–35,69–135`) |
| W4 | Кэш аватаров HF без вытеснения и с отрицательным кэшированием ошибок | LRU на 512 записей; `AvatarLookup::Failed` (`429`/`5xx`/сеть) не кэшируется (`huggingface.rs:125–184`) |
| W5 | `terminate_engine` блокировал поток tokio до 3 с | `terminate_engine_async`: `try_wait` без сна потока; синхронный вариант — только для не-async контекста (`local_runtime.rs:1465`) |
| W6 | `block_on(runtime.stop())` без таймаута держал выход | `stop_runtime_bounded`: `tokio::time::timeout(5 s)`; повтор на выходе подавляется `runtime_stop_attempted` (`main.rs:114–143`) |
| W7 | `restarts >= 3` не сбрасывался и был невидим | `healthy_streak` сбрасывает счётчик после 20 здоровых тиков; причина отключения — в `disabled_reason` и логе (`main.rs:87–95,1797–1819`) |
| W8 | Тик супервизора мог поднять шлюз во время выхода | `shutting_down` выставляется `begin_shutdown()` до первой остановки и перечитывается перед `gateway::start` (`main.rs:126,1840,2624`) |
| W9 | Двойной `gateway::stop` проходил по `taskkill /IM` дважды | `Gateway.stopped` + `mark_running()`; повторный `stop` — `Ok("already stopped")` (`gateway.rs`) |
| W10 | `detect_hardware` (до 8 с PowerShell) под замком жизненного цикла | `detect_hardware_async` вызывается до `lifecycle.lock()` (`hardware.rs:653`) |
| W11 | `401/403` выглядел как 180-секундный таймаут | `RouterFetchError::{Unauthorized,Http,Network,Malformed}`; латч `router_key_rejected` прекращает опрос. Новых проб нет — движок банит после пяти `401` (`local_runtime.rs:1635+`) |
| W12 | Ранний `Err` после `begin_lifecycle` оставлял статус модели | 13 путей перевода статуса через `fail_launch_error` с проверкой поколения (`local_runtime.rs`) |
| W13 | TOCTOU выбора порта | `ENGINE_PORT_ATTEMPTS = 3`: при ошибке `bind` запуск повторяется на следующем порту вместо 180-секундного таймаута |
| W14 | `validate_install_url` принимал `http` | Только `https`; `http`/`file` отклоняются с понятным сообщением |
| W15 | `set_custom_binary_path` не останавливал работающий движок | `async fn`: штатная остановка, затем проверка пути и запись настройки; при ошибке движок не остаётся в подвешенном состоянии |
| W16 | `reap_orphan_engine` — no-op на Windows | `tasklist /FI "PID eq …"` сверяет образ, затем `taskkill /PID … /T /F`; защита от переиспользования pid |
| W17 | `router_error_message` терял HTTP-статус | `router_error_message(body, status)`; `401/403` классифицируются отдельно (`local_runtime.rs:105`) |

### 5.2 macOS (M1–M21)

| ID | Находка | Исправление |
|---|---|---|
| M1 | Релей: поток на соединение без семафора | 32 слота, сверх — фиксированный `503` без потока и буферов (`SystemPromptProxy.swift:22,28,355`) |
| M2 | Нет таймаута upstream; `takeHead` ответа с `limit: .max` | `SO_RCVTIMEO`/`SO_SNDTIMEO` 600 с и на upstream; голова ответа 64 КиБ (`:22`) → `502` (`:488`) |
| M3 | Тройное копирование тела; реестр промптов на каждый POST | `[UInt8]` без `Data(...)`-копий; `promptSnapshot` с инвалидацией по mtime/размеру (`:217–278`) |
| M4 | Мёртвый `gatewayYAML()` | Удалён вместе с блоком `MARK: - Gateway Integration` |
| M5 | `start()` релея: check-then-act | `bind` и присвоение `boundPort` под одним замком |
| M6 | `ByteCountFormatter` на каждый вызов | `static let byteFormatter` (`LocalHardwareService.swift:537`) |
| M7 | Нет process group и сверки поколений | `setpgid` + `kill(-pid, …)` с fallback; `terminateProcess(expectedGeneration:)`, сверка до и после каждого `await` |
| M8 | Жатва по подстроке пути убивала чужой `llama-server` | Разбор `ps -axo pid=,ppid=,command=`; только осиротевшие, с проверкой пути, `--host 127.0.0.1` и порта 18318…18348 |
| M9 | `stopSync()` busy-wait до 3 с на главном потоке | SIGTERM группе + 10×50 мс, затем SIGKILL + 4×50 мс (≤ 0,7 с) |
| M10 | `checkHealth` принимал любой `200` за движок | HTTP 200 **и** JSON `status == "ok"\|"ready"` |
| M11 | `routerStatesSnapshot` не отличал ошибку от пустого ответа | Возвращает `nil` при ошибке, `[:]` — только для валидного пустого ответа; `loading` не сбрасывается |
| M12 | `downloadURL` без проверки; `saveSidecar`/`readJournal` через `try?` | `isSecureDownloadURL` (https + хост); ошибки возвращаются и логируются (`Logger`, `LocalDownloads`) |
| M13 | `waitUntilExit()` без таймаута; манифест без лимита | Таймаут 120 с + 2 с на `SIGKILL`, вывод ≤ 4 МиБ, `runtime.json` ≤ 1 МиБ, `Cancel` работает |
| M14 | `saveStorageLocation` через `try?` и молчаливый откат пути | Ошибка возвращается; `connectModelsDirectory` откатывает смену; миграция падает до удаления копий |
| M15 | Одна резервная копия без `fsync`; `updateModelStatus` игнорировал ошибку записи | Копия `registry.corrupt-<ISO8601>.json` + `fsync`; запись на `registryIOQueue` с проверкой поколения |
| M16 | Любой `OSStatus` → `nil` («токен не настроен») | `KeychainError` + `loadHuggingFaceTokenResult()`: `errSecItemNotFound` = «нет токена», прочее — ошибка с кодом |
| M17 | HF: ошибки без кода/тела, без таймаута и повтора | `HubReply` с кодом и телом (≤ 512 байт), `requestTimeout = 30` с, один повтор на транзиентную ошибку |
| M18 | Утечка `requests`, кэш без вытеснения, отрицательное кэширование `429`/`5xx` | `actor` на 200 записей и 7 дней с вытеснением; `Outcome` различает «нет аватара» и «ошибка»; `requests` очищается |
| M19 | Настройки и пути без проверки | `LocalModelSettings.validate()` перед сохранением/запуском; `fileURLs` отбрасывает `..`, каталоги и симлинки |
| M20 | Синхронные Keychain/реестр на MainActor | Запись реестра — на `registryIOQueue` с проверкой поколения; Keychain — вне MainActor |
| M21 | `LocalDownloadsView`: ошибка обрезана, `journalError` не показан | Баннер ошибки журнала и текст ошибки в строке загрузки (`LocalDownloadsView.swift:31–52,234–244`) |

### 5.3 Осознанные компромиссы

- **W13** — повтор при ошибке `bind`, а не bind-then-pass: окно TOCTOU сужено, но не
  устранено полностью. Полное устранение требует передачи готового сокета движку, чего
  `llama-server` не умеет.
- **W14** — установка runtime только по `https`; `file://` отклоняется, хотя локальный
  архив было бы удобно. Осознанно: единственный штатный источник — GitHub Releases.
- **W6/W16** — у Windows нет переносимого способа принудительно убить чужой процесс вне
  job object: при зависании пишется громкий лог, job object добивает при штатном выходе,
  `reap_orphan_engine` — при следующем запуске.
- **M8** — router'ы, у которых жив сторонний родитель, не добиваются: чужой процесс
  может быть нужен пользователю.
- **M20** — холодное чтение реестра при инициализации остаётся синхронным (однократно,
  иначе UI не получит список моделей); на MainActor ушла только повторяющаяся запись.
- **Логи** — в Tauri-дереве нет `log`/`tracing`, поэтому сообщения идут префиксным
  `eprintln!`; на macOS — `os.Logger(subsystem: "dev.melontools.app")`.

## 6. Проверки

Финальные проверки выполнялись на дереве после всех правок второго прохода.

| Проверка | Результат |
|---|---|
| `cargo fmt --manifest-path Windows/app/src-tauri/Cargo.toml --check` | чисто |
| `cargo test --manifest-path Windows/app/src-tauri/Cargo.toml` | **492 passed, 0 failed, 1 ignored** (131,6 с) |
| `cargo xwin check --target x86_64-pc-windows-msvc` | exit 0, без новых предупреждений |
| `xcodebuild … build` (Debug, derivedData вне репозитория) | `** BUILD SUCCEEDED **` |
| `xcodebuild … test -only-testing:MelonToolsTests/LocalAICoreTests` | **38 passed, 0 failed** — `** TEST SUCCEEDED **` |
| `git diff --check` по изменённому коду второго прохода | чисто; в отчёте и spec трейлинг-пробелов нет. Глобально `--check` ругается только на предсуществующий `MacOS/patches/0001-stream-bootstrap-qos.patch` (не трогался) |

Сборка артефактов не запускалась: DMG, Windows-инсталлятор и portable-архив в этом
проходе не пересобирались (по условию задачи), в GitHub ничего не отправлялось.

Ограничения проверки: реальная нагрузка не воспроизводилась (ни на Windows, ни на macOS);
выводы по памяти опираются на чтение кода и существующие тесты, а не на профилирование.
Сетевые сценарии (ENOSPC, `429`, обрыв на середине тела) проверены по коду, не вживую.
Подпись и нотаризация не проверялись. Windows-поведение подтверждено типовой проверкой
под `x86_64-pc-windows-msvc`, а не запуском на Windows.
