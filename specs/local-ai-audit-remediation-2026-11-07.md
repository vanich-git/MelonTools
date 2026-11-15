# SPEC — закрытие всех находок аудита Local AI (macOS + Windows)

Задача: исправить **все** пункты со статусом «Открыто» / «Частично» / «не исправлено»
в `AUDIT-LOCAL-AI-2026-11-07.md`, не ломая уже исправленное и не выходя за область
Local AI. Режим: SpecLoop, запись — этот файл.

## Текущее поведение (проблема)

Отчёт фиксирует 17 открытых пунктов в Rust/Tauri и 21 в Swift/Xcode. Часть из них —
утечки памяти и ресурсов (релей, кэши), часть — некорректная остановка (процесс-группа,
busy-wait, отсутствие таймаута), часть — неверные отказы (статусы, Keychain, HTTP).

## Желаемое поведение

1. Ни один пункт отчёта не остаётся в состоянии «Открыто».
2. Правки минимальны, в стиле файла, без изменения публичных контрактов, кроме тех,
   где это и есть суть исправления (например `findAvailablePort`).
3. Поведение, уже описанное как исправленное, сохраняется.
4. Сборки и тесты зелёные: `xcodebuild build`, `xcodebuild test` (LocalAICoreTests),
   `cargo test --lib`, `cargo fmt --check`, `cargo xwin check`.

## Область и ограничения

- Трогаем только `Windows/app/src-tauri/src/**` и `MacOS/app/MelonTools/**`.
- Не коммитим, не пушим, не собираем DMG/инсталлятор, не трогаем
  `/Applications/Melon Tools.app`.
- Не добавляем новых зависимостей.
- Не меняем UI-строки без необходимости; новые строки — через существующие механизмы
  локализации, где они есть.

## Пункты и критерии приёмки

Обозначения: **W** — Windows/Rust, **M** — macOS/Swift. ID стабильны и используются
в отчёте и в ответах исполнителей.

### W1. Релей: тело запроса копируется целиком (`body.clone()`)
- Файл: `local_ai/system_prompt_proxy.rs`.
- Критерий: на пути проксирования нет полной копии `Vec<u8>` размером до 64 МиБ;
  тело передаётся по владению либо пишется потоком. Тесты релея проходят.

### W2. Релей: поток на соединение без ограничения параллелизма
- Критерий: число одновременно обслуживаемых соединений ограничено (семафор/счётчик),
  сверх лимита — немедленный `503` с `Connection: close`, без выделения 64 МиБ.
  Лимит — константа с комментарием; 600-секундные таймауты сохраняются для генерации.

### W3. Релей: сбой `bind` молча отключает системный промпт
- Критерий: ошибка `bind` возвращается вызывающему/логируется на уровне `error!`
  и видна в существующей диагностике (не только `tracing::debug`).

### W4. Rust: кэш аватаров HF без вытеснения
- Файл: `local_ai/huggingface.rs`.
- Критерий: у кэша есть верхняя граница (LRU или «не более N»), при переполнении
  старые записи удаляются; поведение при отсутствии файла не меняется.

### W5. `terminate_engine` блокирует поток tokio до 3 с
- Критерий: ожидание завершения не занимает async-воркер: либо `spawn_blocking`,
  либо короткие `try_wait` с `tokio::time::sleep`, либо вызов вынесен в блокирующий
  контекст. Функция остаётся синхронной там, где это требуется сигнатурой.

### W6. `block_on(runtime.stop())` на выходе без таймаута
- Критерий: выход ограничен по времени (например 5 с); по истечении — принудительный
  `taskkill`/`killpg` и запись в лог, приложение не висит.

### W7. `restarts >= 3` не сбрасывается и не виден
- Критерий: счётчик сбрасывается после устойчивого здоровья (N успешных тиков),
  состояние «watchdog выключен» видно в существующем статусе/логе, а не только в памяти.

### W8. Тик супервизора может запустить шлюз при выходе
- Критерий: после начала выхода тик не стартует шлюз (флаг `shutting_down`/проверка
  под тем же замком, что и остановка).

### W9. Двойной `gateway::stop`
- Критерий: повторный вызов идемпотентен и не запускает `taskkill /IM` второй раз
  (флаг/ранний выход, если процесс уже остановлен).

### W10. `detect_hardware` под замком жизненного цикла
- Критерий: длинная (до 8 с) детекция выполняется вне удерживаемого замка; результат
  публикуется после повторной проверки ревизии.

### W11. `fetch_router_models`: `401/403` выглядит как таймаут
- Критерий: ошибка авторизации возвращается отдельным вариантом и попадает в сообщение
  пользователю («ключ движка не совпадает»), без дополнительных проб (риск бана).

### W12. Ранний `Err` после `begin_lifecycle` оставляет статус
- Критерий: любой выход с ошибкой после `begin_lifecycle` переводит модель в
  `failed`/`error` (через существующий `fail_launch`/`settle`), без «вечного loading».

### W13. TOCTOU выбора порта
- Критерий: занятый порт не приводит к 180-секундному таймауту: при ошибке `bind`
  (по коду выхода/строке в логе) выполняется повтор с другим портом, ограниченное
  число попыток; либо порт резервируется и передаётся движку.

### W14. `validate_install_url` принимает `http`
- Критерий: для установки runtime разрешён только `https` (и, при необходимости,
  `file` для локального пути, если это уже поддерживается); `http` отклоняется с
  понятным сообщением.

### W15. `set_custom_binary_path` не останавливает работающий движок
- Критерий: при смене пути с запущенным движком он сначала штатно останавливается,
  затем путь проверяется и сохраняется; при ошибке проверки движок не остаётся
  в подвешенном состоянии.

### W16. `reap_orphan_engine` — no-op на Windows
- Критерий: на Windows осиротевший `llama-server` находится по pid-файлу с проверкой
  имени образа и завершается `taskkill /T /F`; при несовпадении pid процесс не трогается.

### W17. `router_error_message` теряет HTTP-статус
- Критерий: при непустом теле ошибки статус тоже присутствует в итоговой строке
  (например `HTTP 400: <текст>`), при пустом — как сейчас.

### M1. Релей: нет лимита параллельных соединений
- Критерий: одновременно обслуживается не более N соединений; сверх лимита — `503`,
  без потока и буферов на соединение.

### M2. Релей: нет таймаута upstream и `takeHead(limit: .max)` для ответа
- Критерий: на upstream-сокет ставятся `SO_RCVTIMEO`/`SO_SNDTIMEO` (те же 600 с, что
  у клиента), голова ответа ограничена `maxHead`, при превышении — `502`/закрытие.

### M3. Релей: тройное копирование тела и реестр на каждый POST
- Критерий: `modelId` и `merge` работают с `[UInt8]` без `Data(...)`-копий; системный
  промпт не перечитывает и не декодирует весь реестр на каждый запрос (кэш с
  инвалидацией по mtime/уведомлению).

### M4. `gatewayYAML()` — мёртвый код
- Критерий: метод удалён (вместе с неиспользуемыми помощниками), сборка не ломается.

### M5. `start()` релея: check-then-act
- Критерий: `bind` и присвоение `boundPort` происходят под одним замком/сериализованы,
  второй параллельный вызов не создаёт второго слушателя.

### M6. `ByteCountFormatter` на каждый вызов
- Критерий: форматтер создаётся один раз (static/let), поведение форматирования то же.

### M7. Нет process group и сверки поколений
- Критерий: дочерний router получает собственную группу (`setpgid` после запуска),
  `SIGTERM`/`SIGKILL` уходят группе (`kill(-pid, …)`) с fallback на pid; остановка
  проверяет `processGeneration` и не затирает статус нового запуска.

### M8. «Жатва» убивает любой процесс с тем же путём
- Критерий: перед `kill` проверяются `ppid` (осиротевший/наш) и аргументы
  (`--port`/`--host`), либо процесс находится по pid-файлу; чужие `llama-server`
  не затрагиваются.

### M9. `stopSync()` — busy-wait до 3 с на главном потоке
- Критерий: нет busy-wait; худшее время ожидания сокращено (например 1 с + `SIGKILL`),
  либо выход переведён на `applicationShouldTerminate` → `.terminateLater`.

### M10. `checkHealth` принимает любой `200`
- Критерий: здоровьем считается только ответ с `status == "ok"/"ready"` (или
  документированным полем router'а); иначе false, токен никуда не отправляется.

### M11. `routerStatesSnapshot` не отличает ошибку от пустого ответа
- Критерий: ошибка возвращается как `nil`/`Result`, вызывающий не сбрасывает
  `loading → installed` при неудачном опросе.

### M12. `downloadURL` без проверки; `saveSidecar`/`readJournal` через `try?`
- Критерий: URL обязан быть `https` с непустым хостом (локальные адреса — только если
  уже поддерживались); ошибки записи сайдкара и журнала логируются и не теряются молча.

### M13. `RuntimePackageInstaller`: `waitUntilExit()` без таймаута; `Data(contentsOf)` без лимита
- Критерий: установка прерывается по таймауту (процесс `terminate()`, затем `SIGKILL`),
  `runtime.json` читается с ограничением размера (например 1 МиБ) и понятной ошибкой.

### M14. `saveStorageLocation` (`try?`) + молчаливый `loadCustomPath`
- Критерий: ошибка сохранения возвращается в UI/логируется; при неудачном чтении
  пользователь видит, что путь сброшен, а не «сохранено».

### M15. Одна резервная копия без `fsync`; `updateModelStatus` игнорирует `saveRegistry`
- Критерий: резервные копии не перезаписывают друг друга (метка времени), запись
  синхронизируется (`fsync`/`.atomic`), ошибка сохранения статуса логируется.

### M16. Keychain: любой `OSStatus` → `nil`
- Критерий: `errSecItemNotFound` = «токена нет», прочие статусы = ошибка с кодом,
  которую видит пользователь.

### M17. HF: ошибки без кодов, повторов и таймаутов
- Критерий: в `NSError` есть HTTP-код и тело (ограниченно), таймаут запроса задан,
  для `429/5xx` — один повтор с задержкой (без циклов).

### M18. Аватары: утечка `requests`, кэш без вытеснения, отрицательное кэширование
- Критерий: запись `requests[key]` удаляется по завершении; кэш ограничен по числу
  записей; `nil` кэшируется только для окончательного «нет аватара» (404), не для
  `429/5xx`/сетевой ошибки.

### M19. `LocalModelSettings.validate()` и пути
- Критерий: настройки проверяются перед сохранением/запуском (контекст, batch, потоки,
  GPU-слои, temperature/topP/topK, KV-тип); пути с `..` нормализуются, каталог и
  нечитаемый файл отклоняются с сообщением.

### M20. Синхронные Keychain/реестр на MainActor
- Критерий: чтение/запись реестра и Keychain не блокируют MainActor на заметное время
  (вынос в фоновую очередь/actor с сохранением порядка записи).

### M21. `LocalDownloadsView`: ошибка обрезана, `journalError` не показан
- Критерий: полный текст ошибки доступен (tooltip/разворот), `journalError` виден.

## План проверок

Обязательные (required):
- `xcodebuild -project MacOS/app/MelonTools.xcodeproj -scheme MelonTools build`
- `xcodebuild … test -only-testing:MelonToolsTests/LocalAICoreTests`
- `cargo test --manifest-path Windows/app/src-tauri/Cargo.toml --lib`
- `cargo fmt --manifest-path … --check`
- `cargo xwin check` (Windows target, как в прошлом аудите)

Опциональные: точечные тесты новых функций, `swift test` не используется.

## Критерии готовности

- Все ID выше — `PASS` с указанием файла и строк.
- Обязательные проверки зелёные на текущем дереве.
- Отчёт обновлён: ни одного «Открыто» из списка; добавлен раздел с вторым проходом.
- Нет новых предупреждений компилятора, кроме существовавших до правок.

## Допущения

- `router /health` возвращает `{"status":"ok"}` (подтверждено документом
  `docs/RSS_ROUTER_B12099.md`); если нет — M10 откатывается на проверку JSON-поля
  `status` с любым непустым значением.
- Лимит соединений релея выбирается 32 (macOS) и 32 (Windows) — достаточно для
  локального UI и защищает от исчерпания.
- `https` для установки runtime — существующие источники уже `https`.

## EVIDENCE

### Ревизия и область

- Базовая ревизия: `b8556ff` (`Localize Local AI publication errors and create the preset
  directory on first run`), грязное рабочее дерево; посторонние правки не откатывались.
- До правок: 17 Windows (W1–W17) + 21 macOS (M1–M21) = **38 открытых пунктов**.
- Источник требований: `AUDIT-LOCAL-AI-2026-11-07.md` (2.1–2.3, 4.2.1–4.2.3, раздел 5).
- Правки только в `Windows/app/src-tauri/src/**` и `MacOS/app/MelonTools/**`; новых
  зависимостей нет; коммитов и пушей нет; DMG/инсталлятор не пересобирались.

### Windows (W1–W17)

| ID | Итог | Где | Чем подтверждено |
|---|---|---|---|
| W1 | PASS | `local_ai/system_prompt_proxy.rs:366` | `mem::take(&mut request.body)` — передача по владению, `clone()` на пути нет; сборка + тесты релея |
| W2 | PASS | `local_ai/system_prompt_proxy.rs:30,48,253–257` | `ACTIVE_CONNECTIONS` + `ConnectionSlot`, 32 слота, `503` + `Connection: close`; тесты релея |
| W3 | PASS | `local_ai/system_prompt_proxy.rs:69–135` | `LAST_ERROR`/`last_error()` → `PublicationState.prompt_relay_error` (`local_ai/commands.rs`) |
| W4 | PASS | `local_ai/huggingface.rs:125–184` | LRU 512 + `AvatarLookup`; тест `failed_avatar_lookups_are_not_cached` |
| W5 | PASS | `local_ai/local_runtime.rs:1465` | `terminate_engine_async` — `try_wait` без сна потока |
| W6 | PASS | `main.rs:114–160` | `stop_runtime_bounded` — `timeout(5 s)`; `runtime_stop_attempted` |
| W7 | PASS | `main.rs:92,1815–1819` | `healthy_streak` сбрасывает `restarts` после 20 тиков (`WATCHDOG_RESET_AFTER_TICKS`), `disabled_reason` |
| W8 | PASS | `main.rs:126,1840,2624` | `begin_shutdown()`; `shutting_down` перечитывается сразу после `gateway::start` в тике и в рестарте |
| W9 | PASS | `gateway.rs` (`Gateway.stopped`, `mark_running`) | идемпотентный `stop` → `Ok("already stopped")` |
| W10 | PASS | `local_ai/hardware.rs:653` | `detect_hardware_async` до `lifecycle.lock()` |
| W11 | PASS | `local_ai/local_runtime.rs:1639` | `RouterFetchError::{Unauthorized,Http,Network,Malformed}` + латч `router_key_rejected`; тест `router_error_message` |
| W12 | PASS | `local_ai/local_runtime.rs:2743` | 13 путей `fail_launch_error` с проверкой поколения; тесты `fail_launch` |
| W13 | PASS | `local_ai/local_runtime.rs:1368` | `ENGINE_PORT_ATTEMPTS = 3`, повтор при `bind` |
| W14 | PASS | `local_ai/local_runtime.rs:1063` | `validate_install_url` — только `https` |
| W15 | PASS | `local_ai/local_runtime.rs:2208` | `async fn set_custom_binary_path` — остановка, проверка, запись |
| W16 | PASS | `local_ai/local_runtime.rs:1485` | `tasklist /FI "PID eq …"` → `taskkill /PID … /T /F` |
| W17 | PASS | `local_ai/local_runtime.rs:105` | `router_error_message(body, status)` |

### macOS (M1–M21)

| ID | Итог | Где | Чем подтверждено |
|---|---|---|---|
| M1 | PASS | `LocalAI/SystemPromptProxy.swift:28,352` | 32 слота, `503` без потока |
| M2 | PASS | `LocalAI/SystemPromptProxy.swift:488` | `SO_RCVTIMEO`/`SO_SNDTIMEO` на upstream, `takeHead(limit: maxHead)` → `502` |
| M3 | PASS | `LocalAI/SystemPromptProxy.swift:217–278` | `[UInt8]` без `Data(...)`-копий, `promptSnapshot` по mtime/размеру |
| M4 | PASS | `LocalAI/LocalInferenceService.swift` | мёртвый `gatewayYAML()` удалён вместе с `MARK: - Gateway Integration`; в этом файле вхождений 0 (одноимённые `gatewayYAML` в `Codex/` — другой код) |
| M5 | PASS | `LocalAI/SystemPromptProxy.swift` (`start`) | `bind` и `boundPort` под одним замком |
| M6 | PASS | `LocalAI/LocalHardwareService.swift:537` | `static let byteFormatter` |
| M7 | PASS | `LocalAI/LocalInferenceService.swift:563,778` | `setpgid` + `kill(-pid, …)`, `terminateProcess(expectedGeneration:)` |
| M8 | PASS | `LocalAI/LocalInferenceService.swift` (`reapOrphanedEngines`), `MelonToolsApp.swift:141` | `ps -axo pid=,ppid=,command=`, только осиротевшие, путь + `--host 127.0.0.1` + порт 18318…18348 |
| M9 | PASS | `LocalAI/LocalInferenceService.swift` (`stopSync`) | SIGTERM группе + 10×50 мс, SIGKILL + 4×50 мс |
| M10 | PASS | `LocalAI/LocalInferenceService.swift:965` | HTTP 200 **и** `status == "ok"\|"ready"` |
| M11 | PASS | `LocalAI/LocalInferenceService.swift:823` | `routerStatesSnapshot() -> [String: RouterModelStatus]?`, `nil` при ошибке |
| M12 | PASS | `LocalAI/LocalDownloadManager.swift:1128` | `isSecureDownloadURL`, ошибки журнала/сайдкара возвращаются и логируются |
| M13 | PASS | `LocalAI/RuntimePackageInstaller.swift:9,191,194` | таймаут 120 с + 2 с, вывод ≤ 4 МиБ, манифест ≤ 1 МиБ, `Cancel` |
| M14 | PASS | `LocalAI/LocalModelStore.swift:257` | бросающий `saveStorageLocation`, откат `connectModelsDirectory`, миграция до удаления копий |
| M15 | PASS | `LocalAI/LocalModelStore.swift:1089` | `registry.corrupt-<ISO8601>.json` + `fsync`, `saveRegistryInBackground` с поколением |
| M16 | PASS | `LocalAI/LocalKeychainHelper.swift:57` | `KeychainError` + `loadHuggingFaceTokenResult()` |
| M17 | PASS | `LocalAI/HuggingFaceService.swift:130` | `HubReply` (код + тело ≤ 512 байт), `requestTimeout = 30`, один повтор |
| M18 | PASS | `LocalAI/HFAvatarService.swift:38,107` | `actor`, 200 записей / 7 дней, `Outcome`, `requests` очищается |
| M19 | PASS | `LocalAI/LocalModel.swift:113,331` | `LocalModelSettings.validate()`, `fileURLs` без `..`/каталогов/симлинков |
| M20 | PASS | `LocalAI/LocalModelStore.swift`, `LocalKeychainHelper.swift` | запись реестра на `registryIOQueue` с поколением, Keychain вне MainActor |
| M21 | PASS | `Views/LocalAI/LocalDownloadsView.swift:33` | баннер `journalError` + текст ошибки в строке |

### Обязательные проверки (финальное дерево)

| Проверка | Результат |
|---|---|
| `cargo fmt --manifest-path Windows/app/src-tauri/Cargo.toml --check` | чисто |
| `cargo test --manifest-path Windows/app/src-tauri/Cargo.toml` | **492 passed, 0 failed, 1 ignored** (131,59 с), exit 0 |
| `cargo xwin check --target x86_64-pc-windows-msvc` | exit 0, новых предупреждений нет |
| `xcodebuild … build` (Debug) | `** BUILD SUCCEEDED **`, exit 0 |
| `xcodebuild … test -only-testing:MelonToolsTests/LocalAICoreTests` | **38 passed, 0 failed**, `** TEST SUCCEEDED **`, exit 0 |
| `git diff --check` по изменённому коду | чисто; отчёт и этот файл — новые, трейлинг-пробелов нет. Глобально — только предсуществующий `MacOS/patches/0001-stream-bootstrap-qos.patch` |

### Что не проверялось

- Реальная нагрузка и профилирование памяти — ни на Windows, ни на macOS.
- Запуск Windows-сборки на Windows: только типовая проверка `x86_64-pc-windows-msvc`
  и прогон тестов на macOS-host.
- Сетевые сбои вживую (ENOSPC, `429`, обрыв тела) — по коду и тестам.
- Подпись и нотаризация; DMG/инсталлятор/portable-архив не пересобирались.

## REVIEW

Ревьюер — основная сессия (self-review), независимого ревьюера в этом раунде нет:
субагенты находились на глубине 1 и не могли порождать своих детей, поэтому их REVIEW
был self-review плюс независимый runtime-харнесс (`xcrun swiftc -frontend -parse`,
изолированные `/tmp/m7harness/*`). Это ограничение зафиксировано честно.

Проверено против критериев SPEC:

- Каждый ID имеет `PASS` с файлом и символом; критерии W1–W17/M1–M21 прочитаны построчно
  и сверены с кодом, а не с отчётами исполнителей.
- Публичные контракты не расширены без нужды: `stop()` сохранён (B), `loadHuggingFaceToken()`
  оставлен обёрткой (F), `findAvailablePort` не менял сигнатуру.
- Регрессии: полный набор Rust-тестов (492) и Swift-тестов (38) зелёный; сборки обеих
  платформ успешны; новых предупреждений нет (`transition_if_current` помечен
  `cfg_attr(not(test), allow(dead_code))`, остальные warning'и существовали до правок).
- Отчёт приведён в соответствие: ни одной строки «Открыто»/«не исправлено», раздел 5
  переписан как сводка закрытия, добавлен 3.3, обновлены 0, 6.

Замечания ревью (приняты как осознанные компромиссы, не дефекты):

1. W13 — повтор при `bind` вместо bind-then-pass: окно TOCTOU сужено, не устранено.
2. W14 — `file://` отклоняется; единственный штатный источник и так `https`.
3. W6/W16 — на Windows нет переносимого способа убить чужой процесс вне job object:
   громкий лог + добивание при следующем запуске.
4. M8 — router'ы живого стороннего родителя не добиваются осознанно.
5. M20 — холодное чтение реестра при инициализации остаётся синхронным (однократно).
6. M21 — UI-правка минимальна (баннер + текст ошибки), полноценный экран журнала не делался.

## LOOP

- Раунд 1 — SPEC (этот файл) → BUILD: 8 субагентов по группам (B — W1/W2/W11/W12/W14/W15,
  C — W6–W10, A — W5/W13/W17 и релей, D — M4/M7–M11, E — M12/M13/M21, F — M14–M16/M19/M20,
  G — M1–M3/M5/M6, H — M17/M18) + закрытие W4 в основной сессии.
- Раунд 1 — обязательные проверки выявили 6 дефектов сборки/тестов, все отремонтированы:
  1. `cargo fmt --check` падал на новых тестах B → `cargo fmt`.
  2. `E0433`: `Ordering` не импортирован в `#[cfg(test)] mod tests` → добавлен импорт.
  3. `E0063`: в инициализаторе `AppState` не хватало `shutting_down` и
     `runtime_stop_attempted` → добавлены.
  4. Дважды `future is not Send`: `MutexGuard` жил через `discard_child().await` →
     извлечён синхронный `publish_ready`, замок отпускается до `await`.
  5. Новое предупреждение `transition_if_current is never used` → атрибут
     `cfg_attr(not(test), allow(dead_code))` + пояснение.
  6. Аватары: ошибки `429`/`5xx`/сети кэшировались как «нет аватара» → `AvatarLookup`,
     ошибки не кэшируются, тест `failed_avatar_lookups_are_not_cached`.
- Раунд 2 — повторные обязательные проверки: всё зелёное (см. EVIDENCE).
- Счётчик ремонтов: **6** (раунд 1), раунд 2 — без ремонтов.
- Итог: PASS, все 38 пунктов закрыты.
