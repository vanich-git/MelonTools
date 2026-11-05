# Полный аудит Melon Tools 5.0.0 — macOS и Windows

**Дата:** 2026-11-02
**HEAD:** `0a0ad1d` «Redesign the macOS and Windows interfaces for 5.0.0»
**Тег:** `v5.0.0`
**Рабочее дерево:** `/Volumes/Z Slim/MelonTools` (exFAT)
**Окружение проверки:** macOS 27.0, Xcode 27.1, Swift 6.4, XcodeGen 2.46.0, Node 25.9.0, Python 3.9/3.12. Rust-тулчейна нет, Windows-машины нет.

---

## 1. Краткий вывод

Приложение зрелое. Это не прототип: 244 macOS-теста проходят, Release-сборка
собирается, CI покрывает macOS, Windows, упаковку, движок, доки и безопасность,
а код содержит продуманные решения (атомарные записи `0600`, allowlist хостов
обновлений, Job Object для движка на Windows, CSP и whitelist IPC в UI).

Тем не менее **5.0.0 вышла с регрессией и красным CI**:

1. **Windows: четыре действия Antigravity не работают.** UI вызывает
   `antigravity_account_action`, но команды нет в whitelist моста — IPC
   отклоняется до Tauri. Это пауза/возобновление, приоритет, удаление и probe
   аккаунта. Ровно эту ошибку ловит `ui-static-check.js`, то есть проверка на
   HEAD красная.
2. **Главный ресурсный риск — 1,5-секундный фоновый цикл.** При аккаунте,
   заблокированном по квоте (а это типичное состояние), приложение
   круглосуточно опрашивает management API гейтвея: **40 запросов в минуту**,
   ~76 мс каждый, **~30 МБ лога в сутки**. Лог ротируется только перезапуском
   движка, то есть раз в сутки рвётся активный трафик.
3. **Документация 5.0.0 противоречит релизу.** `packaging/README.md` называет
   5.0.0 «macOS-only» и публикует неверный SHA-256 DMG, а `docs/SECURITY-MODEL.md`
   до сих пор описывает 3.3.0.
4. **Разработка на exFAT ломает инструменты.** `l10n_lint.py` падает на
   AppleDouble-файлах `._*`, `doctor.sh` показывает 3 FAIL, `cargo`/`tauri-build`
   на таком томе ранее падал (зафиксировано в прошлом аудите), а атомарная
   запись файла через rename здесь возвращает `ENOTSUP` (воспроизведено при
   подготовке этого отчёта).

По совокупности: **продукт — «хорошо», процесс релиза — «требует починки»**.
Ни одной проблемы с потерей данных или утечкой секретов в этом аудите не
найдено; найденные дефекты — функциональные, ресурсные и процессные.

---

## 2. Что проверено и каким результатом

| Проверка | Команда | Результат |
|---|---|---|
| macOS-тесты | `xcodebuild … test` | **244 теста, 0 падений**, 3,1 с |
| macOS Release | `xcodebuild … -configuration Release build` | **BUILD SUCCEEDED** |
| JS-синтаксис | `node --check` для всех UI/composer | OK |
| UI-статический гейт | `node Windows/app/tools/ui-static-check.js` | **FAIL**: `inv("antigravity_account_action")` нет в whitelist (4 вызова) |
| Локализация | `python3 MacOS/scripts/l10n_lint.py` | **падает**: `UnicodeDecodeError` на `._*.swift` (exFAT) |
| Локализация вручную (без `._*`) | свой скрипт | 804 ключа, 754 call site, 0 дублей, 0 пропусков |
| Синхронизация composer | `./scripts/sync-composer.sh --check` | OK |
| Доки и манифесты | `python3 .github/scripts/docs_lint.py` | OK, версия 5.0.0 |
| Контрольные суммы | `python3 scripts/verify_release_checksums.py` | OK (статически; артефакты не сверялись) |
| Встроенный движок Windows | `python3 Windows/scripts/verify-engine.py` | OK: 24 253 914 сжато / 74 483 200 распаковано |
| `doctor.sh` | `./scripts/doctor.sh` | **3 FAIL**: exFAT-том, AppleDouble, права `+x` |
| Секреты в git | `git grep` по ключам/токенам | чисто |
| Артефакты | `shasum -a 256` DMG/EXE | совпадают с Cask, winget и release notes |
| Запущенное приложение | `ps`, `lsof`, `gateway.log` | RSS 82 МБ + 63 МБ, CPU ~0,9 %, порт только `127.0.0.1:18317` |

Не проверялось (и почему) — см. раздел 8.

---

## 3. P0 — исправить до следующего релиза

### W-1. Windows: действия Antigravity не работают (регрессия 5.0.0)

**Где:** `Windows/app/ui/mt-actions.js:908,923,938,959`;
`Windows/app/ui/mt-bridge.js:16-104`.

**Что происходит.** Мост `window.melon.invoke` пропускает только команды из
массива `COMMANDS`. В 5.0.0 UI начал вызывать `antigravity_account_action`, но
в whitelist его не добавили. Вызов отклоняется строкой
`melon bridge: command not allowed` ещё до Tauri, поэтому не работают:

- пауза/возобновление аккаунта (`antigravityPause`);
- приоритет (`antigravityPriority`);
- удаление (`antigravityRemove`);
- probe после таймаута (`antigravityProbe`).

Rust-команда при этом зарегистрирована и рабочая (`main.rs:1582`,
`generate_handler![…]` содержит её). То есть это чисто рассинхрон UI ↔ мост.

**Почему не поймали.** `ui-static-check.js` как раз проверяет это
(`Windows/app/tools/ui-static-check.js:41-48`) и **падает**. Значит, релизный
тег прошёл мимо красного CI либо проверка не запускалась на этом коммите.
В `release.yml` этого шага нет — там только `cargo test`.

**Исправление:** добавить `"antigravity_account_action",` в `COMMANDS`
(`mt-bridge.js`), рядом с остальными `antigravity_*`. Усилие: **S**.
Проверка: `node Windows/app/tools/ui-static-check.js` → `ok`.

### W-2. Красный CI на main блокирует доверие к релизу

**Где:** `.github/workflows/ci.yml:60` (шаг `ui-static-check`),
`.github/workflows/release.yml` (этого шага нет).

**Проблема.** Пока W-1 не исправлен, job `macos` падает на шаге статической
проверки UI. При этом релизный workflow собирает и публикует артефакты без
этой проверки, поэтому баг доехал до пользователей.

**Исправление:** (а) починить W-1; (б) добавить в `release.yml` перед сборкой
те же гейты, что в CI: `ui-static-check.js`, `l10n_lint.py`, `node --check`.
Усилие: **S**.

### D-1. `packaging/README.md` описывает несуществующий релиз

**Где:** `packaging/README.md:21-31`.

**Что не так:**

| Утверждение | Факт |
|---|---|
| «Release artifacts for 5.0.0» — только DMG | В релизе есть и Windows: `MelonTools-5.0.0-portable.exe` (38 МБ, хеш `97b66b6d…`), `Windows/README.md` описывает 5.0.0, winget указывает 5.0.0 |
| SHA-256 DMG `9dd337d5…` | Реальный файл и Cask/release notes: `436732a5…` |
| «5.0.0 is a macOS-only redesign release; the Windows artifacts stay at 4.0.1» | Windows-артефакты 5.0.0 существуют, release notes 5.0.0 перечисляют Windows-установщик и portable |

**Почему важно.** Это документ, по которому проверяют скачанный файл. Неверный
хеш и «macOS-only» прямо противоречат релизу и вводят пользователя в
заблуждение. `verify_release_checksums.py` этого не ловит, потому что сверяет
только Cask/winget, а не таблицу в README.

**Исправление:** обновить таблицу (DMG + setup + portable + legacy alias) и
хеши из release notes; убрать фразу про macOS-only. Усилие: **S**.
Дополнительно: расширить `docs_lint.py`, чтобы он сверял таблицу
`packaging/README.md` с `SHA256SUMS`/соседними `.sha256` — тогда расхождение
не повторится.

### D-2. `docs/SECURITY-MODEL.md` устарел на две мажорные версии

**Где:** `docs/SECURITY-MODEL.md:4` («covers the 3.3.0 builds»), `:18`.

Документ описывает модель доверия, на которую ссылаются README и FAQ. Сейчас
он говорит о 3.3.0, хотя текущая версия 5.0.0 и с тех пор менялись гейтвей,
обновления и UI. Формулировки по существу (DPAPI, 0600, loopback) в целом
остаются верными, но версия и раздел про подпись устарели.

**Исправление:** обновить версию и раздел «Signing», добавить запись о
проверке SHA-256 движка и о том, что macOS-хранилище не шифруется. Усилие: **S**.

---

## 4. P1 — стабильность, батарея, ресурсы

### S-1. Фоновый цикл 1,5 с не учитывает длительную блокировку квоты

**Где (macOS):** `MacOS/app/MelonTools/Codex/CodexStore.swift:1127-1145`
(`nextLiveQuotaDelay`), `:1162` (`liveQuotaTick`);
**где (Windows):** `Windows/app/src-tauri/src/main.rs:2030-2040`
(безусловный `sleep(1500ms)`), `live_quota.rs:50`.

**Факт с живого приложения.** В логе гейтвея ровно **40 запросов в минуту**:

```
23:06  43   23:07  41   23:08  40   23:09  40   23:10  40   23:11  39   23:12  41
GET /v0/management/auth-files  200  76ms  127.0.0.1
```

Лог: 1,9 МБ за 1,5 часа → **~30 МБ в сутки**. Ротация — 32 МБ
(`CodexGatewayService.swift:678`), и она делается **перезапуском движка**
(`respawnForLogRotation`), потому что дочерний процесс держит fd. То есть при
активном использовании раз в сутки гейтвей перезапускается и рвёт текущие
стримы.

**Причина.** У 4 из 5 аккаунтов в vault `quotaBlock != nil` (weekly 0–2 %), а
`nextLiveQuotaDelay()` возвращает 1,5 с при **любом** заблокированном аккаунте
(`CodexStore.swift:1133`). Пока недельный лимит не сбросится (дни), приложение
не спит. macOS хотя бы имеет 15-секундный idle-путь; Windows опрашивает
безусловно каждые 1,5 с, ещё и читая vault.

**Что сделать:**

1. Учитывать `resetAt` блокировки: если сброс дальше N минут, опрашивать
   management API раз в 60–120 с, а не 1,5 с. Быстрый путь оставить только
   при активном трафике (`requestsLastMinute > 0`) и near-reserve.
2. Не писать в `gateway.log` каждый health/management-запрос (или вынести
   management в отдельный лог с уровнем warn).
3. Ротацию лога делать через `SIGHUP`/copy-truncate, если движок это умеет,
   иначе — не в момент трафика и с явным баннером «сервис перезапускается».

**Эффект:** −95 % фоновых запросов, −30 МБ/сутки лога, отсутствие
ежедневного разрыва стримов. Усилие: **M**.

### S-2. exFAT-том ломает локальные инструменты и сборку

**Где:** `MacOS/scripts/l10n_lint.py:66-70`, `scripts/doctor.sh`,
весь worktree на `/Volumes/Z Slim`.

**Факты.**

- `l10n_lint.py` обходит `APP.rglob("*.swift")` и читает файлы как UTF-8.
  AppleDouble `._L10n.swift` — бинарный, скрипт падает с `UnicodeDecodeError`.
  В CI этого нет (там APFS-раннер), поэтому проверка «зелёная» в CI и
  «красная» у разработчика.
- `doctor.sh` даёт 3 FAIL: exFAT, 20+ `._*` в worktree, `._*.pack` в
  `.git/objects`, плюс все файлы с `+x` из-за exFAT.
- В прошлом аудите зафиксировано: `cargo`/`tauri-build` падает на
  `._default.toml`. Сейчас Rust-тулчейна нет, поэтому воспроизвести не смог,
  но причина та же и не устранена.
- Атомарная запись файла (temp + rename) на этом томе вернула
  `ENOTSUP: operation not supported on socket` при попытке записать этот
  отчёт; запись пришлось делать напрямую. То есть exFAT ломает не только
  сборку, но и обычные write-пути инструментов.

**Что сделать (минимально):**

1. В `l10n_lint.py` пропускать `path.name.startswith("._")` и читать с
   `errors="replace"` (или `strict=False`).
2. Проверить аналогичные обходы в `docs_lint.py` и `verify_release_checksums.py`
   на `._*`.
3. В README/AGENTS явно: «не запускайте cargo/xcodebuild с target на exFAT;
   используйте APFS-каталог для `target/` и `DerivedData`».
4. `git config core.filemode false` на exFAT-клоне, чтобы `doctor.sh` не
   ругался на права.

**Эффект:** воспроизводимость локальных проверок. Усилие: **S**.

### S-3. Логирование приложения почти отсутствует

**Факт:** в 21 688 строках Swift — **0** `print` и **1** `Logger`
(`ProviderUsage.swift:662`). Диагностика идёт через `gateway.log` (движок),
`auditLog` в памяти и support bundle. Для настольного приложения, которое
само обновляется и держит фоновые циклы, это мало: при «не работает обновление»
или «не подключается аккаунт» в system log нет ни одной записи.

**Что сделать:** один `Logger(subsystem: "dev.melontools.app", category:)` на
модуль (startup, gateway, updater, scheduler, auth) + `OSSignposter` уже есть
для старта. Не логировать токены/тела. Усилие: **M**.

### S-4. Подпись и нотаризация

**Факт:** `codesign -dv` — `Signature=adhoc`, `spctl` — `rejected`; Windows exe
без Authenticode. Это осознанное ограничение (нет сертификатов), но для
«стабильной установки» это главный барьер: Gatekeeper и SmartScreen пугают
пользователей, а автообновление macOS заменяет бандл без проверки подписи
Apple (только SHA-256 из того же GitHub-релиза).

**Что сделать:** сертификат Apple Developer + notarization; Authenticode для
Windows. Пока их нет — оставить как есть, но в отчёте о релизе явно писать,
что это ожидаемо (сейчас так и сделано). Усилие: **L** (внешняя зависимость).

---

## 5. P2 — качество, поддерживаемость, паритет

### Q-1. Windows UI — два слоя рендеринга, ~2,7 тыс. строк мёртвого кода

**Где:** `Windows/app/ui/mt-redesign.js` (2 211 строк) загружается последним и
переопределяет **15 функций** из `mt-pages.js` и `app.js`:

```
accountCard, accountsPage, apiPage, composerPage, dashboardPage, donatePage,
instancesPage, quotaBlock, settingsPage, strategyOptions, subscriptionText,
dashboardPoolCard, dashboardSchedulerCard, dashboardSpendCard, dashboardTrendsCard
```

Старые реализации остаются в бандле и никогда не вызываются. Любая правка
`mt-pages.js`/`app.js` в этих местах **не видна** — это мина для следующего
разработчика (и для агента).

**Что сделать:** либо удалить перекрытые функции из `mt-pages.js`/`app.js`,
либо (предпочтительно) перенести содержимое `mt-redesign.js` в основные файлы
и оставить один слой. Усилие: **M**, риск средний — нужен визуальный smoke.

### Q-2. 87 Tauri-команд, из них 3 не в whitelist и 2 не используются

**Факт:** зарегистрировано 87, в whitelist 87, но `antigravity_account_action`,
`antigravity_refresh`, `claude_refresh` в whitelist отсутствуют (первая нужна
UI, две другие — мёртвые: refresh-кнопки вызывают `claude_usage` и
`antigravity_metrics`).

**Что сделать:** добавить первую; для двух оставшихся решить — использовать в
UI (обновление токенов) или удалить из Rust, чтобы список команд совпадал с
реальностью. Усилие: **S**.

### Q-3. Репозиторий и рабочее дерево замусорены

**Факты:**

- 10 ГБ worktree: `Windows/app/src-tauri/target` 6,4 ГБ, `Windows/dist` 1,3 ГБ,
  `MacOS/build` 764 МБ, `MacOS/_sources` 373 МБ, 10 DMG по 52 МБ, 7 exe по 38 МБ.
- `.git` 328 МБ, внутри `._*.pack` (AppleDouble) — git их игнорирует, но это
  лишние байты и риск «non-monotonic index».
- 4 копии одного логотипа по 640 КБ в git (`MacOS/Logo.png`,
  `Windows/app/ui/logo.png`, `MacOS/app/Resources/Logo.png`,
  `Яркий янтарный ломтик дыни с семечками.png` — **один и тот же SHA-256**),
  плюс корневой PNG — случайный артефакт 5.0.0.
- Отслеживается 208 файлов — это хорошо; мусор в основном не в git.

**Что сделать:** удалить корневой дубликат и один из логотипов (оставить один
источник + копию в бандле), вынести сборку в APFS, добавить `target/`,
`dist/`, `_sources/`, `build/` в явные инструкции по очистке. Усилие: **S**.

### Q-4. Swift Concurrency в режиме `minimal`

**Где:** `MacOS/app/project.yml:19` — `SWIFT_STRICT_CONCURRENCY: minimal`.

На 21 тыс. строк есть 6 `@unchecked Sendable`, `Task.detached`, ручные
`NSLock`, таймеры и `usleep` в quit-пути. Компилятор при `minimal` не проверяет
гонки. Для приложения, которое держит фоновые циклы, это скрытый риск.

**Что сделать:** включить `targeted` для новых файлов и постепенно
`complete`; начать с `CodexGatewayService`, `ComposerBridge`, `CDPSession`,
`LoopbackServer`. Усилие: **M–L**.

### Q-5. Доступность

**Факты:** 10 `accessibilityLabel` на 21 тыс. строк Swift; 13 `aria-*` в
Windows UI. Кастомные индикаторы (кружки квоты, чипы, `role="checkbox"` у
строки пула) частично размечены, но клавиатурная навигация и озвучивание
прогрессов неполные.

**Что сделать:** `accessibilityValue` для процентов и `accessibilityLabel` для
иконочных кнопок; в Windows — `aria-live` для тостов уже есть, добавить
`aria-label` на иконочные кнопки. Усилие: **M**, эффект — доступность и
качество.

### Q-6. Документация рассинхронизирована

Помимо P0:

- `docs/SECURITY-MODEL.md` — 3.3.0 (см. D-2).
- `MacOS/RELEASE_NOTES.md` 5.0.0 говорит «routing, quota and scheduler
  behaviour is unchanged», хотя diff 4.0.0→5.0.0 менял `antigravity.rs` и
  `gateway.rs`.
- Комментарий в `UpdaterStore.swift:83` говорит про «6 h» и «daily throttle»,
  а код — 1 час (`periodicCheckInterval = 3600`).
- `MacOS/AGENTS.md` — локальная заметка, в git не входит (правильно), но
  содержит машинные пути.

**Что сделать:** пройтись по докрингу один раз, привязать версии к
`project.yml`/`Cargo.toml` в `docs_lint`. Усилие: **S**.

### Q-7. Мелкие замечания (не блокеры)

- `gateway.pid` пишется с правами `0644` (`CodexGatewayService.swift:1320`), хотя
  остальные файлы — `0600`. PID не секрет, но единообразие лучше.
- `usleep(150_000)` в `ComposerBridge.shutdownForQuit` и `usleep(100_000)` в
  `stopSync` блокируют main при выходе — до 2,5 с. Приемлемо, но лучше
  асинхронно.
- `LoopbackServer` не проверяет заголовок `Host` — для OAuth с PKCE это не
  критично, но добавить одну строку дёшево.
- `SecureFile.write` не делает `fsync` каталога — при отключении питания
  возможна потеря последнего файла (настройки/ключ). Мелочь для десктопа.

---

## 6. Что доделать (функционально)

1. **Antigravity на Windows** — после W-1 проверить весь сценарий: pause →
   quota перестаёт учитываться → resume → probe снимает кулдауны. Сейчас это
   единственная известная функциональная дыра паритета.
2. **Кнопки «Обновить» у Claude/Antigravity** — они вызывают `*_usage`, а не
   `*_refresh`; если задумано обновлять токены, подключить `claude_refresh` /
   `antigravity_refresh`, иначе удалить команды.
3. **Runtime-smoke UI.** Статический чек поймал W-1, но не поймал бы, например,
   неверный аргумент. Дешёвый вариант: прогонять UI в браузере с mock (он уже
   есть в `mt-api.js`) и проверять, что каждая кнопка вызывает известную
   команду — это следующий шаг после `ui-static-check`.
4. **Нотаризация/Authenticode** — как только появятся сертификаты; до этого
   оставить честное предупреждение в релизе.
5. **Ротация лога без рестарта** — если движок поддерживает reopen по сигналу;
   иначе хотя бы не ротировать при `requestsLastMinute > 0` (сейчас проверка
   есть) и показывать баннер.

---

## 7. План по приоритетам

| # | Задача | Усилие | Эффект |
|---|---|---|---|
| 1 | W-1: whitelist + W-2: гейты в release | S | Возвращает 4 функции Antigravity и зелёный CI |
| 2 | D-1/D-2: packaging/README и SECURITY-MODEL | S | Честные хеши и модель безопасности |
| 3 | S-2: фильтр `._*` в l10n_lint + инструкции по exFAT | S | Воспроизводимость локальных проверок |
| 4 | S-1: адаптивный live-quota по `resetAt` + тише лог | M | −95 % фоновых запросов, батарея, нет ежедневного рестарта |
| 5 | Q-1: один слой Windows UI | M | Убирает 2,7 тыс. строк мёртвого кода и класс «правка не туда» |
| 6 | S-3: структурное логирование | M | Диагностика без воспроизведения |
| 7 | Q-4: strict concurrency targeted | M | Меньше скрытых гонок |
| 8 | Q-5: доступность | M | Качество |
| 9 | Подпись/нотаризация | L | Снятие предупреждений ОС |

Порядок 1–3 можно сделать одним PR за час: это 20 строк кода и два документа.

---

## 8. Ограничения этого аудита

- **Windows runtime не проверялся**: нет Windows-машины. Выводы по Windows
  сделаны по исходникам, `ui-static-check`, `verify-engine.py` и CI-конфигу;
  поведение трея, тостов, установщика и обновления требует VM.
- **`cargo test`/`cargo clippy` не запускались**: Rust-тулчейн в окружении
  отсутствует (`cargo: MISSING`). По CI-конфигу они выполняются на
  `windows-2025` с `-D warnings`; локально подтвердить нельзя.
- **GUI не открывался**: Computer Use в профиле выключен. Оценка UI — по коду
  и запущенному процессу (RSS/CPU/порт/лог), без визуального smoke.
- **Сеть GitHub не проверялась**: живые ассеты релиза и CI-статус тега не
  запрашивались. Хеши сверены с локальными файлами и манифестами.
- Исходный отчёт — снимок коммита `0a0ad1d`. Находки исправлены отдельным
  набором правок; статус каждой — в
  `specs/full-audit-2026-11-02-remediation.md`.

---

## Приложение A. Как воспроизвести ключевые находки

```bash
cd "/Volumes/Z Slim/MelonTools"

# W-1 / W-2
node Windows/app/tools/ui-static-check.js          # FAIL: antigravity_account_action

# D-1
shasum -a 256 MacOS/MelonTools-5.0.0.dmg           # 436732a5…, а в packaging/README 9dd337d5…

# S-1
awk -F'[][]' '{print $2}' "$HOME/Library/Application Support/MelonTools/gateway/gateway.log" \
  | cut -c1-16 | uniq -c | tail            # ~40 записей в минуту

# S-2
./scripts/doctor.sh                        # 3 FAIL
python3 MacOS/scripts/l10n_lint.py         # UnicodeDecodeError на ._*

# Тесты и сборка
xcodebuild -project MacOS/app/MelonTools.xcodeproj -scheme MelonTools \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/MelonTools" CODE_SIGNING_ALLOWED=NO test
```

## Приложение B. Положительные стороны (чтобы не потерять при рефакторинге)

- 244 macOS-теста и разбиение сложной логики на чистые helper'ы
  (`QuotaNotificationPolicy`, `CodexRoutingPlanner`, geometry-парсеры) —
  это то, что позволяет безопасно менять код.
- Атомарная запись секретов (`SecureFile`), `0600`/`0700`, DPAPI на Windows.
- Allowlist хостов обновлений и SHA-256 перед установкой; отказ от `/tmp` для
  лога обновления.
- Job Object с `KILL_ON_JOB_CLOSE` для движка на Windows — зомби-процессов не
  будет.
- CSP `default-src 'self'`, `withGlobalTauri: false` и whitelist IPC — XSS-
  цепочка закрыта осознанно.
- CI: тесты, clippy `-D warnings`, `cargo fmt --check`, actionlint, CodeQL
  (JS + Swift), cargo-audit, govulncheck, проверка движка и манифестов.
