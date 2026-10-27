# Аудит улучшений Melon Tools 2.4.0 — 2026-10-27

## 1. Резюме

Приложение зрелое. Критические дефекты прошлого аудита в основном закрыты.
Главные возможности для улучшения сейчас — не «доделать фичи», а снизить
постоянную нагрузку фоновых циклов, убрать риск потери токенов и закрыть
XSS-цепочку в Windows UI.

Топ-5 по соотношению «эффект / усилие»:

1. **Windows:** убрать XSS-цепочку `inline onclick` → Tauri IPC.
2. **macOS:** починить «залипание» отложенного сохранения vault.
3. **Windows:** переделать цикл live-quota: сейчас он каждые 1,5 с делает HTTP,
   расшифровывает DPAPI-хранилище и пишет vault.
4. **Windows:** не отдавать ~12,8 МБ истории планировщика (плюс результаты
   задач) каждые 5 с.
5. **Обе платформы:** сделать live-quota адаптивной и публиковать изменения
   только при реальном изменении значений.

Отдельно: тег `v2.4.0` содержит Cask и winget с хешами 2.3.7 (REL-1).
Это уже ломает установку из тега. Подробности — в разделе 8.

## 2. Что проверено

| Проверка | Результат |
|---|---|
| `node --check` для `Windows/app/ui/app.js` и двух `composer-chips.js` | OK |
| `yaml.safe_load` для 3 workflow | OK |
| `python3 .github/scripts/docs_lint.py` | OK: 3 workflow, 3 winget-манифеста, версия 2.4.0 |
| `bash -n` для `MacOS/build.sh`, `fetch-sources.sh`, `Windows/build-windows.sh`, `sign-macos.sh` | OK |
| `xcodebuild ... test` | **не запустился**: `Could not launch "MelonToolsTests"` |
| `cargo test --locked` | **не запустился**: panic в `tauri-build` на файле `._default.toml` |
| `git status` / `git log` | работают, но печатают `non-monotonic index` из-за `._*.idx` в `.git/objects/pack` |
| Версии | macOS, Windows, winget, Cask, README — 2.4.0 |
| Хеши опубликованных ассетов | на HEAD совпадают с Cask и winget; в теге `v2.4.0` — хеши 2.3.7 (см. REL-1) |
| GitHub API | живые ассеты 2.4.0 и их digest; ссылки `latest/download/…2.3.7…` → 404 |
| Git-индекс | 318 файлов `._*` в `.git`; 84 из 152 tracked-файлов — mode `100755` |
| Размер DMG / приложения | 54 МБ / 156 МБ, из них 139 МБ — универсальный Go-движок |
| Размер Windows portable | 36 МБ, движок сжат в 24 МБ |

Тесты не выполнены. Причины — инфраструктурные, но важные для разработки:

- **macOS:** установленное приложение 2.4.0 было запущено. Тестовый host — это
  то же приложение с `CFBundleIdentifier = dev.melontools.app` и
  `LSMultipleInstancesProhibited = true`. LaunchServices не даёт запустить
  второй экземпляр. Нужно проверить после полного выхода из Melon Tools.
- **Windows:** репозиторий лежит на exFAT. macOS создаёт AppleDouble-файлы
  `._*`. `tauri-build` читает `._default.toml` как UTF-8 и падает. Нужен
  target-каталог на APFS или очистка `._*`.

## 3. P1 — сделать до следующего релиза

### M1. Отложенное сохранение vault «залипает» навсегда

**Где:** `MacOS/app/MelonTools/Codex/CodexStore.swift:579-597`, вызовы
`:1057`, `:1357`, `:1385`.

**Проблема:** `saveTask` не сбрасывается в `nil` после завершения задачи.
Первый вызов `save(immediately: false)` создаёт задачу. Через 2 с она
выполняет `flushSave()`, но `saveTask` остаётся непустым. Все последующие
отложенные сохранения выходят по `guard saveTask == nil`.

**Почему важно:** обновлённые OAuth-токены, ошибки квоты и live-quota
остаются только в памяти. При падении, force quit или потере питания
пользователь может потерять ротацию refresh-токена и получить разлогин.
Сейчас риск смягчён только `flushSave()` при штатном выходе
(`MelonToolsApp.swift:87`).

**Что сделать:** обнулять `saveTask` через `defer` внутри задачи. Добавить
тест: два отложенных сохранения подряд действительно пишут файл. Отдельно
снизить частоту записи live-quota до 30 с.

**Усилие:** S. **Эффект:** устранение класса потери данных.

### M2. Live-quota на macOS: 40 пробуждений в минуту, HTTP и постоянный App Nap

**Где:** `CodexStore.swift:944-1013` (цикл 1,5 с), `:1018-1057` (merge),
`CodexLiveQuota.swift:159-187` (HTTP GET), `CodexStore.swift:988-991`
(`beginActivity`).

**Проблема:** каждые 1,5 с:

- идёт HTTP GET `/v0/management/auth-files`;
- JSON разбирается и заново кодируется по каждому auth-файлу;
- `accounts[index].quota` присваивается **безусловно**, даже если значение
  не изменилось;
- `@Published accounts` инвалидирует все наблюдающие view;
- `beginActivity` не даёт системе свернуть приложение в App Nap.

**Почему важно:** это постоянный idle-цикл для утилиты в menu bar. Он
продолжается, пока запущен gateway, даже если запросов нет. На ноутбуке это
расход батареи и лишние перерисовки UI.

**Что сделать:**

1. Сравнивать новое чтение с текущим и присваивать только при изменении.
2. Держать 1,5 с только при активных запросах или подходе к резерву.
3. В покое — 10–30 с или событие от gateway.
4. `beginActivity` включать только на время активного enforcement.
5. Переиспользовать `URLSession` и декодировать напрямую в модель.
6. Писать live-quota в vault не чаще 30 с; немедленно — только при смене
   блокировки.

**Усилие:** M. **Эффект:** с 40 циклов/мин до 2–4; меньше CPU, батареи и
перерисовок. Оценка, не измерение.

### W1. Windows live-quota: HTTP-клиент, 3–4 чтения vault и запись каждые 5 с

**Где:** `Windows/app/src-tauri/src/main.rs:1668-1675` (цикл 1,5 с),
`live_quota.rs:30-61` и `:287-289` (`vault::accounts()` несколько раз),
`gateway.rs:503-507` (новый `reqwest::Client` на каждый тик),
`vault.rs:220-253` (DPAPI-расшифровка токенов), `:295-307` (шифрование и
запись), `:513-556` (`update_live_quota` пишет каждые ~5 с).

**Проблема:** один тик делает:

- новый HTTP-клиент и GET к management API;
- 3–4 полных чтения vault;
- DPAPI-расшифровку каждого токена каждого аккаунта;
- раз в ~5 с — обратное шифрование всех токенов и запись JSON.

**Почему важно:** приложение живёт в трее весь день. Один тик расшифровывает
3 ключа на аккаунт в каждом из трёх чтений vault: `9 × N` DPAPI-операций на
тик, то есть `360 × N` в минуту. При 10 аккаунтах это ~3 600 операций в
минуту и постоянные записи на диск. Это CPU, I/O и износ SSD.

**Что сделать:**

1. Один `reqwest::Client` в `OnceLock`.
2. Один снимок vault на тик; передавать его в `reconcile_and_apply` и
   `due_reset_probes`.
3. Кэш аккаунтов в памяти с инвалидацией по записи.
4. Писать `update_live_quota` не чаще 30–60 с и только при изменении полей.
5. Останавливать цикл, когда gateway не запущен.
6. Добавить замер длительности тика.

**Усилие:** M. **Эффект:** `360 × N` расшифровок/мин → только при записи
vault; ~12 записей/мин → 1–2. Оценка.

### W2. Планировщик отдаёт ~12,8 МБ истории каждые 5 с и вызывает полный re-render

**Где:** `scheduler.rs:29-34` (200 записей × 64 КБ), `:711-717`
(`view()`), `main.rs:940-943`, `app.js:3001-3007` (poll), `:4858-4860`
(interval), `:1358-1381` (`main.innerHTML`).

**Проблема:** dashboard каждые 5 с забирает все задачи и всю глобальную
историю с результатами. Затем весь `main` пересобирается через `innerHTML`.
Dirty-form guard спасает ввод, но не scroll, фокус и стоимость layout.

**Что сделать:**

- `scheduler_summary`: только counts, next run и статус.
- `scheduler_history(page, limit)` без тела результата.
- `scheduler_result(id)` по запросу.
- На dashboard обновлять только footer/status-фрагменты, не всю страницу.
- Хранить scroll и фокус при точечных обновлениях.

**Усилие:** M. **Эффект:** payload с мегабайт до килобайт; меньше GC и
layout thrash.

### W3. XSS в Windows UI превращается в доступ к Tauri IPC

**Где:** `app.js:450-455` (`esc`), `:1585-1625` и ещё ~80 `onclick`,
`backup.rs:471-479` (валидация только формы массива),
`tauri.conf.json:10` (`withGlobalTauri: true`), `:24`
(`script-src 'unsafe-inline'`).

**Проблема:** `esc()` кодирует `'` в `&#39;`. HTML-парсер декодирует
сущность обратно в `'` **до** разбора inline JS. Строка вида
`A.deleteAccount('${esc(account.id)}')` разрывается, если `account.id`
содержит кавычку. Импорт backup проверяет только то, что `accounts` — массив,
но не формат `id`. Дальше срабатывают `withGlobalTauri` и `unsafe-inline`:
внедрённый код получает доступ к `vault_list`, `settings_get`, удалению
аккаунтов и другим командам.

**Сценарий:** пользователь импортирует подготовленный backup. При открытии
страницы аккаунтов выполняется внедрённый JS. Это stored XSS с правами
приложения.

**Что сделать:**

1. Убрать inline `onclick`. Один делегированный обработчик + `data-action` и
   `data-id`.
2. Не подставлять данные в JS-строки. Для идентификаторов использовать
   `data-*` или `JSON.stringify`.
3. Валидировать `id` аккаунта при импорте: UUID или `[A-Za-z0-9._-]{1,64}`.
4. Убрать `unsafe-inline` из CSP. Вынести JS в файл (уже так) и оставить
   `script-src 'self'`.
5. Отключить `withGlobalTauri`, оставить узкий bridge.
6. Добавить тест с `id = "');alert(1);//"`.

**Усилие:** M–L. **Эффект:** закрытие пути «backup → XSS → IPC».

### M3. Composer на macOS читает и парсит до 32 МБ каждые 5 с

**Где:** `ComposerBridge.swift:140-146` (timer 5 с), `:376`, `:578`
(`refreshSession`), `ProviderUsage.swift:657-673` (точный thread),
`:689-705` (`tail` и `parseTail`).

**Проблема:** кэш ключуется по size+mtime. Пока Codex дописывает файл, кэш
промахивается на каждом тике. Читается весь хвост до 32 МБ, режется на
строки и парсится как JSONL. Для длинной сессии это регулярные всплески
CPU и I/O.

**Что сделать:** инкрементальный reader с byte offset и буфером хвоста.
Парсить только новые строки. При простое снизить частоту до 10–15 с.
Добавить метрику «время парсинга» в diagnostics.

**Усилие:** M. **Эффект:** убрать повторный разбор одного и того же файла.

### M4. Цена сессии считается линейным поиском по всем моделям

**Где:** `ModelSources.swift:280-303` (`priceRow`), `ProviderUsage.swift:161-184`
(`estimateSpend`).

**Проблема:** для каждого turn вызывается `priceRow`. Он делает три прохода
по всем источникам и моделям и аллоцирует `lowercased()` на каждое
сравнение. При 2 400 turn и сотнях моделей это заметно.

**Что сделать:** построить индекс `lowercased alias/id/display → row` при
изменении источников. Инвалидировать при `save()`/refresh. `priceRow` —
O(1).

**Усилие:** S. **Эффект:** убрать O(turns × models).

## 4. P2 — следующий minor

### M5. Локальные macOS-тесты не запускаются при работающем приложении

**Где:** `Info.plist:34`, `project.pbxproj:512` (`TEST_HOST` указывает на
`MelonTools.app`), `project.pbxproj:679` (тот же bundle id).

**Проблема:** `LSMultipleInstancesProhibited` защищает от второго экземпляра,
но, вероятно, блокирует и test host. CI не страдает: там приложение не
запущено. Локально `xcodebuild test` упал с `Could not launch`, когда
установленное приложение уже работало. Нужно подтвердить, закрыв приложение.

**Что сделать:** отдельный bundle id для Debug/Test host; или включать
`LSMultipleInstancesProhibited` только в Release; или заменить ключ на
runtime-lock, который пропускает XCTest. В README добавить «quit Melon Tools
перед тестами».

**Усилие:** S. **Эффект:** предсказуемый локальный прогон тестов.

### M6. macOS-приложение весит 156 МБ, из них 139 МБ — универсальный движок

**Где:** `MacOS/build.sh:20-33` (собираются arm64 и amd64, затем `lipo`).

**Проблема:** большинству пользователей нужен только один срез. Установленное
приложение занимает 156 МБ; DMG — 54 МБ.

**Что сделать:** отдельные DMG для arm64 и x86_64. Либо сжимать движок в
ресурсах и распаковывать при первом запуске, как уже сделано в Windows
(`cliproxyapi.exe.z`, 24 МБ). Второй вариант сохраняет один универсальный
дистрибутив.

**Усилие:** M. **Эффект:** примерно вдвое меньше установленный размер у
большинства пользователей.

### M7. Старт приложения делает тяжёлую работу до первого кадра

**Где:** `MelonToolsApp.swift:42-67`.

**Проблема:** на main actor последовательно выполняются `load()` vault,
`refresh()` pool, `syncCatalogIfNeeded()` (запись каталога), запуск трёх
таймеров и старт gateway. Окно появляется после этого.

**Что сделать:** показать окно, затем отложить каталог, composer и update
timer. Старт gateway — после первого кадра. Добавить signposts
(`os_signpost`) для измерения.

**Усилие:** S. **Эффект:** быстрее первый кадр; нужен замер до/после.

### W4. `render()` выполняет сетевые загрузки и вызывает сам себя

**Где:** `app.js:1383-1402`, `:1323-1335`.

**Проблема:** каждый вызов `render()` может запускать `schedulerLoad`,
`modelsLoad`, `poolLoad`, `vercelLoad`, `claudeUsageLoad` и
`antigravityUsageLoad`. `run()` вызывает `render()` до и после действия.
Загрузки снова вызывают `render()`.

**Что сделать:** сделать `render()` чистым. Загрузки — на навигацию, boot и
явные действия. Для повторного рендера после async-ответа использовать
точечный updater.

**Усилие:** S–M. **Эффект:** меньше лишних IPC и циклов.

### W5. Status poll последовательный, ошибки проглатываются

**Где:** `app.js:2990-3021`.

**Проблема:** четыре `await` идут последовательно. Внешний `catch` пустой.
При мёртвом backend footer показывает старый статус «работает».

**Что сделать:** `Promise.allSettled`, таймаут на команду, `lastError` в
footer, backoff после серии ошибок.

**Усилие:** S. **Эффект:** быстрее poll и честный статус.

### W6. `app.js` — монолит на 4 890 строк и 80 inline-обработчиков

**Где:** `Windows/app/ui/app.js`.

**Проблема:** состояние, рендер, действия, страницы, i18n и demo-режим в
одном файле. Любое изменение легко ломает соседнюю страницу. Inline
обработчики мешают CSP.

**Что сделать:** разбить на модули (`state`, `api`, `render`, `pages/*`,
`actions/*`), один делегированный listener, небольшие DOM-тесты. Это также
упростит W3.

**Усилие:** L. **Эффект:** снижение регрессий; не делать «большим взрывом»,
а постранично.

### M8. macOS: фиксированные 9–12 px шрифты и слабая поддержка Dynamic Type

**Где:** `MTTheme.swift:100-108`, `MTComponents.swift:43,136,158`,
`SchedulerView.swift:97,256,267,987` и другие.

**Проблема:** размеры заданы точками. При увеличении системного шрифта
интерфейс не масштабируется.

**Что сделать:** семантические стили (`.body`, `.caption`) или
`@ScaledMetric`, проверить VoiceOver и контраст. Это остаток прошлого
аудита (M-H10).

**Усилие:** M. **Эффект:** доступность без отдельной темы.

### M9. Нет защиты от дубликатов ключей в `L10n.ru`

**Где:** `Design/L10n.swift:30` (словарь-литерал на 695 ключей).

**Проблема:** два локальных crash-лога (`1.7.4` и `2.2.4`) показывают
`Dictionary.init(dictionaryLiteral:)` assertion в
`one-time initialization function for ru`. Сейчас дубликатов нет. Но
Swift не ловит их на компиляции, а краш происходит при первом обращении.

**Что сделать:** скрипт в CI, который извлекает ключи и падает на дубликатах.
Плюс тест «каждый `L("...")` есть в таблице».

**Усилие:** S. **Эффект:** защита от повторения краша.

### W7. Трей только на русском

**Где:** `main.rs:1520-1556`.

**Проблема:** при английском интерфейсе меню трея остаётся русским.

**Что сделать:** брать строки из `settings.lang` и пересобирать меню при
смене языка.

**Усилие:** S. **Эффект:** целостность RU/EN.

### W8. Antigravity usage poll не проверяет подключение

**Где:** `app.js:4864-4886`.

**Проблема:** таймер каждые 30 с проверяет `agDue`, но не проверяет, включён
ли провайдер. Комментарий «polling is harmless» неверен: это лишние IPC и
сетевые вызовы.

**Что сделать:** gate по `connected`/`enabled`, экспоненциальный backoff
после ошибок.

**Усилие:** S. **Эффект:** меньше фоновой работы.

### W9. CSP и `withGlobalTauri` всё ещё ослабляют границу

**Где:** `tauri.conf.json:10,24`.

**Проблема:** это часть W3. Даже после удаления inline-обработчиков
`withGlobalTauri` даёт внедрённому коду широкий доступ.

**Что сделать:** `withGlobalTauri: false`, `script-src 'self'`, узкий
`window.melon` bridge с белым списком команд.

**Усилие:** M. **Эффект:** резко снижает ценность любой XSS.

### X1. exFAT-репозиторий ломает `cargo test` и засоряет git

**Где:** том `/Volumes/Z Slim`; 7 688 файлов `._*`; 304 в
`.git/objects`; `Windows/app/src-tauri/target/.../._default.toml`.

**Проблема:** `tauri-build` читает все файлы в каталоге permissions,
включая AppleDouble, и падает на невалидном UTF-8. Git пытается читать
`._*.idx` и печатает `non-monotonic index` на каждую команду.

**Что сделать:**

1. Держать checkout на APFS. Это самое надёжное.
2. Или задать `CARGO_TARGET_DIR` на APFS.
3. Один раз выполнить `dot_clean .` и удалить `._*.idx` из
   `.git/objects/pack`.
4. Добавить `scripts/doctor.sh`, который проверяет том и чистит sidecar-файлы.
5. Сообщить upstream в `tauri-build`: пропускать dotfiles при чтении
   permissions.

**Усилие:** S. **Эффект:** локально снова работают тесты и git без шума.

### X2. Две реализации одной бизнес-логики расходятся

**Где:** Swift и Rust отдельно реализуют routing, quota parsing, catalog,
cron, composer payload. `MacOS/app/Resources/composer-chips.js` — 1 518
строк, `Windows/app/resources/composer-chips.js` — 1 150 строк.

**Проблема:** каждое правило нужно менять дважды. Ошибка 2.3.7 с инверсией
приоритетов — пример расхождения. Composer-скрипты уже разошлись.

**Что сделать:**

- Общие JSON-fixtures: порядок routing, разбор quota, схема catalog,
  next-run для cron, payload composer. Прогонять в XCTest и Rust-тестах.
- Один исходник `composer-chips.js`, который сборка копирует на обе
  платформы.
- Contract-тест на набор полей IPC.

**Усилие:** M. **Эффект:** меньше parity-багов.

## 5. P3 — поддержка и полировка

- **R1. Подпись и notarization.** macOS собирается ad-hoc
  (`project.yml:13-19`, `build.sh:56-59`), Windows — без Authenticode.
  README честно предупреждает. Это внешний блокер: нужны сертификаты.
  Перед включением hardened runtime добавить entitlement для Apple Events
  (REL-3).
- **R2. Ссылки на версию.** README и release notes используют
  `/releases/latest/download/MelonTools-2.4.0.*`. После 2.5.0 такие ссылки
  станут 404; для 2.3.7 они уже 404 (REL-10). Нужен стабильный alias-ассет
  или ссылка на страницу релиза.
- **R3. Скриншоты.** `assets/screenshots/*` показывают версию 1.4.1.
  Обновить или убрать номер.
- **R4. Локальная документация.** `MacOS/AGENTS.md` говорит «12 тестов»;
  сейчас тестов больше. `docs_lint` проверяет версии, но не такие факты
  (REL-15).
- **R5. CI-гигиена.** Node 20 EOL — обновить до 22/24. Добавить
  `cargo clippy`, `actionlint`, `shellcheck`, SBOM. Actions уже
  SHA-pinned — это хорошо. Дублируется в REL-8 и REL-13.
- **R6. `--deep` codesign.** `build.sh:58` использует устаревший `--deep`.
  Подписывать вложенный движок явно, затем app.
- **R7. Мёртвый код и таймеры.** Проверить `S._renderResumeTimer`,
  `schedulerAt`, per-page таймеры на утечки при переходе между страницами.
- **R8. Диагностика.** Добавить «экспорт redacted support bundle»: версии,
  статусы, размеры логов, конфиг без секретов. Это снизит стоимость
  поддержки.
- **R9. Карантин corrupt-файлов.** `CodexStore.swift:401-408` хранит
  `accounts.corrupt.<ts>.json` с токенами бессрочно. Ограничить возраст и
  показывать в UI.
- **R10. Backup KDF.** `BackupService.swift:122` — PBKDF2 210k итераций.
  Для архива со всеми токенами лучше Argon2id или хотя бы 600k + AAD на
  заголовок. Формат менять версионно.
- **R11. Instance auth.json.** `CodexInstancesView.swift:288-289` пишет файл
  через `data.write(.atomic)`, затем меняет права на 0600. Между этими
  шагами токен может быть читаем другим локальным пользователем. Использовать
  `SecureFile.write` и создавать каталог с 0700.
- **R12. CDP port TOCTOU.** `ComposerBridge.swift:842-867` сначала занимает
  свободный порт, затем закрывает сокет и передаёт номер Codex. Другой
  процесс может занять порт первым и получить данные bridge. Проверять
  `/json/version` и владельца процесса или повторять выбор порта.
- **R13. Quit-скрипт.** `ComposerBridge.swift:199-230` подставляет путь
  приложения в shell-скрипт. Если путь содержит кавычки или `$()`, будет
  инъекция. Передавать путь как `$1` и экранировать.

## 6. UX-возможности

Это не дефекты, а точки роста:

1. **Health Center.** Одна страница: gateway, порт, Codex route, debug port,
   chips, права. С кнопками «исправить».
2. **Repair action.** Один клик: backup config → пересоздать route/catalog →
   проверить `/v1/models`. Сейчас пользователь делает это вручную.
3. **Command palette.** Быстрый переход и действия с клавиатуры.
4. **Bulk actions.** «Обновить все», «Включить/выключить все модели»,
   групповое управление аккаунтами.
5. **Update UX.** Прогресс, отмена, канал stable/beta, откат.
6. **Dashboard.** Карточки фиксированы на 250 px
   (`DashboardView.swift:189`); длинные ошибки обрезаются. Сделать
   content-aware высоту или скролл.
7. **Portable-режим macOS.** Сейчас updater требует `/Applications`.
   Для portable-сборки можно отключить self-update и показать ссылку.

## 7. Что уже хорошо

- **Windows vault:** DPAPI v2, миграция, zeroization, escaped reserved
  prefixes (`dpapi.rs`).
- **macOS files:** `SecureFile.write` создаёт 0600 атомарно, fsync, rename,
  удаляет temp при ошибке (`SecureFile.swift:15-48`).
- **Backup import:** валидация до записи, снимок целей, rollback
  (`BackupService.swift:344-441`; `backup.rs:187-260`).
- **Loopback:** gateway слушает `127.0.0.1`, `allow-remote: false`, ключи и
  management secret — отдельные 0600-файлы; лог 0600 с ротацией.
- **CDP:** проверка loopback, порта и `app://-/`; email маскируются
  (`ComposerBridge.swift:744-755`, `:461-467`).
- **Cron:** парсер и policy покрывают ranges, lists, steps, names, Vixie
  day-OR и DST; тесты есть.
- **Release:** workflow проверяет версию тега, гоняет тесты, требует все
  8 ассетов и сверяет checksums; Cask/winget на HEAD совпадают с
  опубликованными хешами.
- **CI:** actions прибиты к SHA; `docs_lint` и JS syntax checks проходят.
- **Движок:** исходник pin-нут на `1f917e77` (v8.0.44),
  `GOTOOLCHAIN=go1.26.10`; извлечение проверяет SHA-256 и ключует кэш по
  payload.
- **Сборка:** `Cargo.lock` закоммичен, CI и release используют `--locked`,
  Rust toolchain закреплён.
- **Секреты:** secret scanning и push protection включены; Dependabot
  покрывает cargo и actions.
- **Паритет:** семантика моделей (`nil` = all), лимиты планировщика и
  конверт backup идентичны на обеих платформах.

## 8. Релизы, CI, упаковка и паритет

Проверено на `main` = `95cb561`; данные релиза — через GitHub API.
Ключевые утверждения ниже сверены с файлами в теге и на HEAD.

### REL-1. Тег v2.4.0 содержит манифесты с хешами 2.3.7

**Где:** `packaging/homebrew/Casks/melon-tools.rb:2-3`,
`packaging/winget/ivankuprin.MelonTools.installer.yaml:12` в теге `v2.4.0`
(коммит `4112c0c`).

**Проблема:** Cask объявляет `version "2.4.0"`, но `sha256` равен digest
DMG 2.3.7 (`3415474d…`). Winget объявляет URL на setup 2.4.0, но
`InstallerSha256` равен digest setup 2.3.7 (`D7D73CE0…`). Оба значения
исправлены только коммитом `95cb561` после тега.

**Почему важно:** checkout тега и установка по манифестам падают на
проверке хеша. Тег не является честным снимком релиза. Пересборка тега
повторяет ошибку.

**Что сделать:** генерировать Cask и winget из собранных артефактов в
publish job; коммитить манифесты **до** тега; добавить `sha256sum -c` и
сравнение манифеста с артефактом; на тегировании выполнять
`git diff --exit-code` для манифестов.

**Усилие:** M.

### REL-2. Движок Windows — непроверяемый blob на 24 МБ, CI его не собирает

**Где:** `engine.rs:22` (`ENGINE_VERSION`), `:34` (встроенный
`cliproxyapi.exe.z`), `:148-151` (тест сравнивает константу с собой),
`.github/workflows/release.yml:179-181`, `ci.yml` (шага Go нет),
`Windows/build-windows.sh:66-92`.

**Проблема:** версия движка — строка, которую никто не сверяет с
бинарником. CI использует закоммиченный blob и не пересобирает его.
Локальная сборка macOS делает `go get` + `go mod tidy`
(`fetch-sources.sh:17-18`), а дерево `_sources/CLIProxyAPI` грязное
(`M go.mod`, `M go.sum`). Сжатый blob: 24 244 153 байта, SHA-256
`8663b001…`; распакованный payload: 74 461 184 байта, SHA-256
`174c78a3…`. Ни один из хешей не опубликован.

**Почему важно:** самый большой бинарник продукта — наименее проверяемый.
Устаревший или уязвимый движок может уйти в релиз незаметно. macOS и
Windows могут работать на разных сборках. Извлечённый
`%APPDATA%\MelonTools\engine\cliproxyapi.exe` не подписан, поэтому
AppLocker может блокировать дочерний процесс.

**Что сделать:** собирать движок в CI из pin-коммита (`go1.26.10`);
публиковать SHA-256 payload в release notes и `docs/SECURITY-MODEL.md`;
падать при неожиданной смене хеша; подписывать извлечённый exe; хранить
patched `go.mod`/`go.sum`.

**Усилие:** L.

### REL-3. Включение hardened runtime сломает Codex Instances

**Где:** `TerminalLauncher.swift:10-12` (`NSAppleScript` → Terminal),
`packaging/sign-macos.sh:87` (`--options runtime`, без entitlements),
`MacOS/app/project.yml:9-19` (нет `CODE_SIGN_ENTITLEMENTS`), в
`MacOS/` нет `.entitlements`.

**Проблема:** hardened runtime блокирует Apple Events без
`com.apple.security.automation.apple-events`. Сейчас сборка ad-hoc, поэтому
дефект скрыт.

**Почему важно:** при появлении сертификатов кнопка «Launch» для
Codex → Instances начнёт падать с ошибкой доступа. Это произойдёт ровно
в момент, когда подпись перестанет быть блокером.

**Что сделать:** добавить `MelonTools.entitlements` с этим ключом,
прописать `CODE_SIGN_ENTITLEMENTS` в `project.yml`, передать
`--entitlements` в `sign-macos.sh`. Добавить smoke-тест Terminal на
подписанной сборке.

**Усилие:** S.

### REL-4. Релизные артефакты не собираются в CI

**Где:** `release.yml:55-77` (тест без `xcodegen generate`),
`ci.yml:27-29` (generate есть), `ci.yml` (нет сборки DMG/NSIS),
`MacOS/app/MelonTools.xcodeproj/project.pbxproj` (сгенерирован, но
закоммичен).

**Проблема:** release-тест может проверять устаревший проект, а артефакт
собирается из пересозданного. DMG и NSIS не проходят проверку на PR.
История: релиз 2.3.7 упал; 2.4.0 прошёл только после `034a045`.

**Что сделать:** `xcodegen generate` перед release-тестами; отдельный
non-publishing job `package` на `main`/PR, который собирает DMG и
NSIS, делает signing dry run; тег — только после зелёного CI.

**Усилие:** M.

### REL-5. Секреты подписи доступны всем шагам job, нет environment и защиты веток

**Где:** `release.yml:27-32` и `:143-145` (job-level `env`),
`sign-macos.sh:123-126,136-139` (пароль notary в argv),
`sign-windows.ps1:78-79` (пароль PFX в argv). `environments` в workflow
нет; GitHub `branches/main/protection` → 404, rulesets пусты.

**Проблема:** `brew install`, `cargo test`, `cargo build` и скрипты из
тега видят сертификаты и пароли. Без environment approval украденный
токен мейнтейнера позволяет тегировать произвольный код и получить
подпись.

**Что сделать:** environment `release` с обязательным reviewer;
секреты только на шагах подписи; `notarytool --keychain-profile`;
сертификат в store или Azure Trusted Signing; защитить `main` и `v*`.

**Усилие:** S.

### REL-6. Пересборка может перезаписать опубликованный релиз и переключить «latest»

**Где:** `release.yml:7-11` (любой существующий тег), `:350-357`
(create-or-update), нет `draft`, `make_latest` и запрета на замену
ассетов. Тело релиза (`:324-347`) не содержит таблицу хешей; живое тело
её содержит, значит, отредактировано вручную.

**Проблема:** пересборка старого тега может сделать его «latest» и
сломать все ссылки `/releases/latest/download/…`. Пересборка текущего
тега меняет байты и инвалидирует закоммиченные хеши.

**Что сделать:** публиковать draft + approval; для backfill
`make_latest: false`; запрещать замену ассетов в не-draft релизе;
генерировать тело с хешами в workflow.

**Усилие:** M.

### REL-7. Входные данные сборки не закреплены

**Где:** `release.yml:26` `macos-latest`, `:142` `windows-latest`,
`:56` `brew install xcodegen`, `:233` `choco install nsis -y`,
`:62` `go-version: "1.26"` при `build.sh:10` `go1.26.10`;
`ci.yml:47` Node 20 (EOL), `:90` `pip install pyyaml` без версии,
`:25` `brew install xcodegen`. `timeout-minutes` нет ни в одном job.

**Проблема:** повторная сборка тега даёт другие байты, хеши и манифесты
«плывут». Путь релиза зависит от latest-пакетов.

**Что сделать:** pin runners (`macos-15`, `windows-2025`), XcodeGen,
NSIS, Go `1.26.10`, Node 22/24, `pyyaml==6.0.2`; добавить таймауты.

**Усилие:** S/M.

### REL-8. Нет SBOM и provenance; CodeQL покрывает только JavaScript

**Где:** `security.yml:51-53` (`javascript-typescript`), в
`release.yml` нет `attest`/`sbom`. `MacOS/README.md:39-41` утверждает,
что `govulncheck` даёт 0 reachable issues, но workflow его не запускает.
`security.yml:11-15` выдаёт `security-events: write` всем job, включая
`cargo-audit`.

**Проблема:** потребитель не может проверить происхождение бинарников.
Rust, Swift и Go-движок не анализируются. Заявление об уязвимостях
стареет молча.

**Что сделать:** `actions/attest-build-provenance` на каждый артефакт;
CycloneDX SBOM (Rust + Go); CodeQL для Rust/Swift/Go; job
`govulncheck` на pin-коммите; сузить permissions по job.

**Усилие:** M.

### REL-9. У `docs_lint.py` четыре слепые зоны, которые допустили REL-1

**Где:** `docs_lint.py:87-92` (только JSON-parse `tauri.conf.json`),
`:140-150` (набор версий: `project.yml`, `Cargo.toml`, Cask, winget),
`:119-138` (только формат хеша). Нет `tauri.conf.json`, `Cargo.lock`,
`Info.plist`, README/RELEASE_NOTES. `packaging/README.md:159-170`
описывает bump-list без `tauri.conf.json` и обещает падение линта при
расхождении.

**Проблема:** версия Tauri (метаданные Windows) может разойтись с
Cargo без ошибки. Неверные хеши проходят. Документированный bump-list
оставляет репозиторий несогласованным.

**Что сделать:** добавить файлы в карту версий; сравнивать Cask/winget
с сгенерированным `SHA256SUMS`; проверять versioned-ссылки; обновить
bump-list.

**Усилие:** S.

### REL-10. Ссылки `latest/download` уже сломаны для прошлых релизов

**Проверено HTTP:** `MacOS/RELEASE_NOTES.md:44-46` →
`…/latest/download/MelonTools-2.3.7.dmg` = **404**; portable = **404**.
`README.md:6-7,57,61`, `Windows/README.md:5,12`,
`MacOS/README.md:458,483` используют `…/latest/download/MelonTools-2.4.0.*`.
Сегодня 200, после 2.5.0 — 404.

**Что сделать:** на главной — unversioned
`releases/latest/download/<stable-name>`; в release notes —
`releases/download/v<version>/…`; добавить проверку ссылок в docs-lint.

**Усилие:** S.

### REL-11. Установщик Windows не совпадает с `tauri.conf.json`, документация описывает третий путь

**Где:** `tauri.conf.json:27-35` (`nsis`, `currentUser`,
`languages: ["Russian", "English"]`), но релиз собирает
`Windows/installer/MelonTools.nsi`, где только
`MUI_LANGUAGE "English"` (`:71`). `Windows/README.md:103` советует
`cargo tauri build` — другой установщик и uninstaller.

**Проблема:** русские пользователи получают английский мастер. Сборка из
исходников и релиз дают разные установщики. Конфиг Tauri выглядит
авторитетным, но мёртв.

**Что сделать:** выбрать один pipeline. Либо `tauri build` и удалить
ручной NSIS, либо убрать Tauri bundle и документировать
`build-windows.sh`/`makensis`. Если NSIS остаётся — добавить русский.

**Усилие:** S/M.

### REL-12. Uninstall оставляет Codex на мёртвый порт; downgrade теряет выбор моделей

**Где:** `MelonTools.nsi:139-160` (не трогает
`%USERPROFILE%\.codex\config.toml`), `codex_route.rs:199-236`
(восстановление только пока приложение существует), macOS без
uninstaller. `schemaVersion`/`schema_version` в хранилищах нет
(проверено grep). `CodexModels.swift:29` — `selectedModels: [String]?`;
старая сборка перекодирует аккаунт без поля. В NSIS нет version guard.

**Проблема:** после удаления Codex ругается на мёртвый
`model_provider = melon_local_access`. Downgrade молча стирает выбор
моделей по аккаунтам. Нет контракта миграции.

**Что сделать:** восстанавливать route при uninstall или показывать
точную команду; добавить `schemaVersion` в vault/settings/scheduler;
предупреждать о downgrade в `.onInit`; документировать rollback.
Поведение uninstaller проверить на Windows VM.

**Усилие:** M.

### REL-13. CI не проверяет синтаксис composer-скриптов и shell

**Где:** `ci.yml:50` — `node --check` только для
`Windows/app/ui/app.js`. `MacOS/app/Resources/composer-chips.js`
(1 518 строк) и `Windows/app/resources/composer-chips.js` (1 150 строк)
не проверяются. Нет `bash -n`, `shellcheck`, `actionlint`,
`cargo fmt --check`, `clippy`.

**Проблема:** регрессии JS и shell доходят до тега. Ошибка 2.2.3
(`ReferenceError: status is not defined` в обоих composer-скриптах)
этим CI не ловится.

**Что сделать:** `node --check` для обоих composer-скриптов;
`bash -n` + `shellcheck` для `build.sh`, `fetch-sources.sh`,
`build-windows.sh`, `packaging/*.sh`; `actionlint`;
`cargo fmt --check`; `clippy -D warnings`.

**Усилие:** S.

### REL-14. Метаданные git повреждены AppleDouble; режимы и вес репозитория не управляются

**Проверено:** 318 файлов `._*` в `.git`; 84 из 152 tracked-файлов
имеют режим `100755`, включая Swift/Rust/Markdown, `release.yml`,
`Info.plist`, `project.pbxproj`. `MacOS/AGENTS.md` закоммичен, хотя
`.gitignore:19-21` называет его локальными заметками. Нет
`.gitattributes`; нет ignore для `*.p12`, `*.pfx`, `*.key`, `.env*`.
Blob движка — 24,2 МБ, 3 ревизии; крупнейший pack — 112,9 МБ;
`git count-objects` — 130,98 MiB. `AppIcon.icns` (2,2 МБ)
перегенерируется каждую сборку.

**Проблема:** git-операции шумят и хрупки на этом томе. Скрипты,
разбирающие вывод git, могут ошибаться. Сертификат можно случайно
закоммитить. Клоны медленные, сгенерированные бинарники дают конфликты.

**Что сделать:** `dot_clean .git` или удалить `._*`; убрать битые refs;
`git gc`; держать репозиторий на APFS; разово
`git update-index --chmod=-x` для не-скриптов; добавить `.gitattributes`,
secret-ignore и gitleaks; вынести движок в LFS или в проверяемый
build-артефакт; генерировать Xcode-проект в CI и не хранить его.

**Усилие:** S (очистка) / M (стратегия движка).

### REL-15. Документация противоречит сборке и UI

**Где и что:**
- `README.md:67` — «Go 1.22+»; `build.sh:10` и `fetch-sources.sh:17`
  требуют `go1.26.10`.
- `MacOS/README.md:446` — «Apple Silicon | arm64 build» как требование,
  хотя `:4` и `:197` говорят «universal»; `:468-470` собирает только
  `GOARCH=arm64`, а `build.sh:26-31` — arm64 + amd64 + `lipo`.
- `docs/FAQ.md:27,161` — порт «настраивается в Settings»;
  `MacOS/README.md:309` говорит, что поле порта удалено; в
  `SettingsView.swift` его нет (в Windows есть).
- `Windows/README.md:110` — движок «~23 МБ»; измерено 24,2 МБ сжатого
  и 74,5 МБ распакованного; `engine.rs:82` — 68 MB.
- `docs/SECURITY-MODEL.md:23-37` не упоминает macOS
  `gateway/gateway.log` и `gateway/auths/*.json`; `:39-49` не упоминает
  Windows `engine/` (74 МБ).

**Почему важно:** по рецепту macOS получается сборка, которая не
работает на Intel и использует не тот Go. Troubleshooting порта на macOS
невозможен. Модель безопасности занижает, где лежат идентификаторы и
движок.

**Что сделать:** исправить четыре утверждения, направить рецепт на
`build.sh`, добавить проверки этих значений в docs-lint.

**Усилие:** S.

### Паритет macOS ↔ Windows в 2.4.0

| Возможность | Вердикт |
|---|---|
| Модели по аккаунтам (`excluded_models`) | **Паритет.** `nil` = все модели, union-fallback одинаков. |
| Общий пул моделей и picker | **Паритет.** |
| Composer chips | **Частично.** В Windows нет live-refresh binding и статистики Claude/Antigravity; расхождение 1 518 vs 1 150 строк. |
| Планировщик (interval + cron + TZ + history) | **Паритет.** Лимиты 20/200/64 KiB одинаковы. |
| Уведомления | **Паритет покрытия.** Windows: отдельные low-quota/reset переключатели. Доставка toast из portable exe — **[VM]**. |
| Обновление | **Паритет потока.** macOS проверяет целостность, не издателя (задокументировано). |
| Диагностика | **Паритет.** Только read-only `/v1/models` и IPC. |
| Backup | **Паритет.** PBKDF2-210k + AES-256-GCM, переносимый конверт. |
| Локализация | **Частично.** 14 Rust-файлов возвращают русские ошибки в EN UI. |
| Codex Instances | **Паритет сегодня**, но macOS сломается при hardened runtime (REL-3). |
| Порт gateway в UI | **Пробел macOS.** Поля нет, документация обещает. |
| Установщик | **Пробел.** NSIS только English, `tauri.conf.json` обещает RU/EN. |
| Uninstall восстанавливает route | **Пробел на обеих платформах.** |

## 9. План

**Неделя 1 — релизная честность и P1**

1. REL-1 + REL-9: генерировать манифесты из артефактов, проверять хеши
   и версии.
2. REL-3: entitlement для Apple Events до первой подписи.
3. REL-5: environment `release`, секреты только на шагах подписи, защита
   `main` и тегов.
4. W3: убрать inline handlers, валидировать id, сузить CSP.
5. M1: починить `saveTask`, добавить тест.
6. W1: один HTTP-клиент, один снимок vault, запись 30–60 с.
7. W2: summary/history API для планировщика.

**Недели 2–4**

8. X1 + REL-14: APFS или `CARGO_TARGET_DIR`; очистка git и режимов.
9. M2: адаптивная live-quota и diff-publish.
10. M3: инкрементальный reader сессии.
11. W4–W6: чистый `render()`, параллельный poll, разбиение `app.js`.
12. M4: индекс цен; M5: отдельный test host bundle id.
13. REL-4 + REL-7: сборка артефактов в CI и pin входов.
14. REL-10 + REL-15: ссылки и документация.

**Далее**

15. REL-2: пересобрать движок и опубликовать хеш.
16. REL-6 + REL-8 + REL-11 + REL-12: draft-релиз, SBOM/provenance,
    один установщик, uninstall и schemaVersion.
17. M6: размер macOS-дистрибутива.
18. Доступность, RU/EN, диагностика, KDF.
19. Подпись, notarization, CI-линтеры.

## 10. Ограничения

- Аудит read-only. Исходный код, тесты, релизы и пользовательские данные не
  менялись.
- `xcodebuild test` и `cargo test` не выполнены по причинам выше. Нельзя
  утверждать, что suites зелёные на этой машине.
- Windows-поведение проверено статически. На Windows VM нужно проверить:
  трей, WebView2 throttling, toast из portable exe (AUMID), установку поверх
  запущенного приложения, uninstaller и оставшийся route, updater/rollback
  при заблокированном exe и не-ASCII пути, запуск извлечённого движка под
  Defender/AppLocker, `winget validate` и silent `/S`, язык установщика.
- Релизная часть сверена с GitHub API на момент аудита. Живые хеши 2.4.0
  совпадают с HEAD; в теге `v2.4.0` — хеши 2.3.7. Это исторический факт,
  а не текущее состояние `main`.
- Оценки выигрыша — расчётные, не профилирование. Для точных цифр нужны
  signposts/ETW и замер до/после.
- Проверенные исправления прошлого аудита: loopback SIGPIPE/lifecycle,
  CDP target/email, лог 0600/ротация. Остаточные риски перечислены в
  R11–R13.
