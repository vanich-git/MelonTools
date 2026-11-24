# Плагины в Melon Tools: аудит Magpie и план внедрения

Дата: 2026-11-24. Платформа проверки: macOS, Apple Silicon.
Проверено: репозиторий `yetone/magpie` (main, коммит `95e6a41`), репозиторий
`magpie-community/plugins` (коммит `e77dec9`), установленное приложение
`/Applications/magpie.app` 0.1.4750, вендоренный CLIProxyAPI в
`MacOS/_sources/CLIProxyAPI` (коммит `1f917e77`), код Melon Tools в этом
репозитории (коммит `f8a967b`).

## 1. Короткий ответ

1. Magpie не имеет одной универсальной системы плагинов. У него два слоя:
   встроенные плагины на Go (`plugins/`, `internal/pluginrt`, `plugins.yml`) и
   внешние плагины на Bun/OpenCode API (npm или GitHub, `internal/plugin`).
   Страницы плагинов - это отдельный третий механизм: HTML в песочнице iframe с
   мостом `postMessage`.
2. Внешняя экосистема Magpie большая: 127 записей в реестре и 110 пакетов
   в самом репозитории. У 51 записи есть провайдеры, 24 записи - это
   middleware, 29 агентских плагинов, 15 страниц, 8 инструментов. 115 записей
   помечены как community, 11 заменяют встроенные плагины.
3. В Melon Tools уже лежит готовая платформа плагинов, которую никто не
   включил: CLIProxyAPI. В её официальном магазине 191 плагин. По тегам (они
   пересекаются): 45 Provider, 27 Interceptor, 30 Scheduler, 33 Usage, 25
   Dashboard.
   Есть API магазина, установка, проверка checksums, включение, настройки,
   квоты и HTML-дашборды.
4. Главный блокер не в UI. macOS-движок Melon собран с `CGO_ENABLED=0`, поэтому
   `dlopen` отключён и **ни один плагин не загружается**. Плагин скачивается,
   но не загружается с ошибкой `standard dynamic library plugin loading requires cgo`.
   Это проверено на живом движке.
5. Я собрал движок с `CGO_ENABLED=1` для arm64 и x86_64, склеил `lipo` в
   universal, установил и загрузил два плагина, проверил включение,
   выключение и чтение/запись конфигурации. Всё работает. Значит правильный
   путь: не писать второй runtime, а включить существующий и сделать ему
   нормальный магазин в Melon.
6. Рекомендация: MVP на нативных плагинах CLIProxyAPI, примерно 3 недели на
   macOS. Затем кураторский реестр Melon и, если понадобится, отдельный
   JS/HTML-слой для страниц и агентов. Не начинать с клона Bun-хоста Magpie.

## 2. Что именно проверено

### 2.1. Magpie

- Исходники: `internal/plugin` (Bun-хост, установка, npm, GitHub, dist),
  `internal/pluginrt` (встроенные плагины), `internal/gui/assets/plugins.js`
  (страница Plugins), `pluginpages.js`, `plugininstalled.js`, `pagebridge.js`.
- Документация: `docs/subsystems/plugin-runtime.md`,
  `docs/subsystems/provider-plugins.md`, `docs/library.md`, `docs/reference.md`.
- Установленное приложение: версия 0.1.4750, `LSUIElement=1`, URL-схема
  `magpie`, минимальная macOS 12.0. В бинаре есть строки `Plugins`,
  `Installed`, `/api/plugins/registry`, `/api/plugin-panels`, то есть UI
  магазина уже поставлен.
- Пользовательский конфиг: `~/.config/magpie/plugins.yml` содержит
  `preset: all`, `settled: 1`; community-плагинов не установлено.
  `~/.config/magpie/settings.json` не содержит ключей плагинов.
- Реестр community: 127 записей; в репозитории 110 пакетов.

### 2.2. CLIProxyAPI внутри Melon

- В исходниках есть `internal/pluginstore`, `internal/pluginhost`,
  `sdk/pluginapi`, `sdk/pluginstore`, management API.
- Проверки шли на временном контуре внутри проекта, артефакты удалены.
- Живой магазин: `GET /v8/management/plugins/store` вернул 191 плагин,
  источник `official`, без ошибок.
- Установлен `jshandler` 1.1.0, файл
  `plugins/darwin/arm64/jshandler-v1.1.0.dylib`, плагин загрузился и
  зарегистрировался.
- Установлен `codex-token-usage` 0.1.45, плагин зарегистрировался и отдал
  menu `Token Usage` с HTML-дашбордом.
- Проверены `PATCH /v0/management/plugins/<id>/enabled`,
  `GET/PUT /v0/management/plugins/<id>/config`; выключение и включение
  работают, конфигурация сохраняется.
- Проверена сборка cgo: arm64 и x86_64 по отдельности, затем `lipo`.
  Универсальный бинарь 131 MB, зависит только от системных библиотек.

### 2.3. Melon Tools

- `MacOS/build.sh:36` собирает движок с `CGO_ENABLED=0`.
- `Windows/scripts/build-engine.sh:50` тоже собирает с `CGO_ENABLED=0`.
- `CodexGatewayService` пишет `config.yaml` без секции `plugins`.
- В `MTSection` нет раздела Plugins, в `NAV` Windows тоже нет.
- В приложении нет клиента магазина, нет формы настроек плагинов, нет
  страниц плагинов и нет модели разрешений.

## 3. Как устроены плагины в Magpie

### 3.1. Два слоя, не один

| Слой | Где живёт | Кто пишет | Зачем |
| --- | --- | --- | --- |
| Встроенные плагины | `plugins/`, `internal/pluginrt` | команда Magpie | Разобрать монолит на включаемые части: сессии, провайдеры, маршрутизация, окно |
| Внешние плагины | `~/.config/magpie/plugins`, npm/GitHub | сообщество | Провайдеры подписок, middleware, агенты, инструменты |
| Страницы плагинов | iframe внутри окна | сообщество | Свои экраны: usage, квоты, календарь, калькуляторы |

Встроенный runtime устроен как граф сервисов: у плагина есть `Manifest` с
`Requires` и `Provides`, `Apply`, `Parts`, настройки. Он не импортирует
плагины и не даёт им импортировать друг друга; общение только через
сервисы. `plugins.yml` хранит пресет (`all` или `essentials`) и точечные
выключения. Это способ разложить функции самого приложения, а не способ
дать сообществу писать расширения.

Внешний runtime это отдельный Bun-процесс. Он запускает плагины, написанные
под API OpenCode v1, и отдаёт им провайдеров, запросы, авторизацию, usage,
хуки. Именно этот слой дал сообществу 127 плагинов.

### 3.2. Формат внешнего плагина

Плагин это npm-пакет. В `package.json` есть блок `magpie`:

- `api` или диапазон совместимости;
- `name`, `icon`, `summary`;
- `page` для HTML-страницы;
- `panels`, `actions` для частей интерфейса;
- `permissions`;
- `options` для настроек;
- `agent` для интеграции с агентом;
- `gateway` для провайдера;
- `middleware`, `hooks`.

Точка входа экспортирует функции. Bun умеет TypeScript без сборки, поэтому
автору не нужен отдельный билд-пайплайн. Это сильно снижает порог входа.

Установка:

- `bun add` с отключёнными install-скриптами;
- npm, GitHub, локальный путь;
- если npm не отдал пакет или версию, запасной путь через `dist`-ветку
  community-репозитория и tar-архив с проверкой sha512;
- semver, обновления, откат при неудачной установке;
- проверка, что пакет действительно экспортирует плагин, иначе установка
  отменяется.

### 3.3. Магазин и сообщество

Реестр `magpie-community/plugins` это `registry.json` с массивом `plugins`.
У записи есть `package`, `name`, `icon`, `providers`, `community`, `summary`
на английском и китайском, `kind`, `replaces`. Реестр тянется с GitHub,
кэшируется на 6 часов, есть встроенная копия на случай офлайна.

Страница Plugins:

- вкладки `Built-in`, `Discover`, `Installed`;
- поиск по реестру и по npm;
- карточки с иконкой, автором, описанием, категорией;
- экран плагина с README, настройками, источником, версией;
- кнопки Install, Update, Remove, Enable/Disable;
- проверка обновлений;
- deep link `magpie://plugin?name=...`;
- отдельный GitHub topic `magpie-plugin` для неотревьюенных плагинов.

Сообщество держится не на магии, а на четырёх вещах:

1. Понятный формат и шаблон, без сборки.
2. Реестр с ревью и CI, а не свалка ссылок.
3. Витрина внутри приложения, где установка это одна кнопка.
4. Документация, примеры и быстрый цикл публикации: PR, merge, dist-ветка,
   npm.

`replaces` позволяет community-плагину заменить встроенный провайдер, не
ломая остальное. Это сильный механизм, которого у Melon сейчас нет.

### 3.4. Страницы плагинов

Страница это HTML, который живёт в sandboxed iframe с
`sandbox="allow-scripts"`, уникальным origin и CSP без `connect-src`.
Внутри нет доступа к окну приложения. Мост даёт только объявленные
возможности: тема, настройки, чтение данных, копирование картинки, открытие
другого плагина. Разрешения перечислены в манифесте и проверяются хостом.

Это правильная модель для Melon, если делать свои страницы. Но это не
первый шаг: сначала нужен работающий магазин провайдеров и middleware.

### 3.5. Безопасность

- Внешний Bun-плагин не в песочнице. Он может читать файлы, ходить в сеть,
  видеть секреты. Защита это ревью и доверие к автору.
- Страница в песочнице, но код плагина, который её обслуживает, всё равно
  доверенный.
- Install-скрипты отключены.
- Установка из npm и dist проверяет целостность.
- Неотревьюенные плагины отделены от курируемого каталога.
- Автообновление есть, но его можно отключить.

Для Melon это означает: нативные плагины CLIProxyAPI нельзя ставить
молча. Нужен экран согласия, источник, автор, лицензия и предупреждение,
что код выполняется в процессе шлюза с доступом к конфигу и токенам.

## 4. Что уже есть в Melon Tools

### 4.1. Платформа плагинов CLIProxyAPI

Это не сторонняя идея, а часть движка, который Melon уже поставляет:

- `plugins.enabled`, `plugins.dir`, `plugins.store-sources`,
  `plugins.configs.<id>` в `config.yaml`;
- загрузка `.dylib` на macOS, `.dll` на Windows, `.so` на Linux через C ABI;
- `sdk/pluginapi` с возможностями: провайдер, исполнитель, авторизация,
  планировщик, маршрутизатор, переводчик запросов, interceptor, usage,
  quota, management API, command line;
- магазин с 191 плагином;
- management API для списка, установки, удаления, включения, конфигурации,
  квот;
- проверка `checksums.txt` при установке;
- метаданные плагина: имя, версия, автор, репозиторий, логотип, поля
  настроек с типами, enum и описанием;
- HTML-ресурсы и menu для дашбордов.

По функциональности это ближе к Magpie, чем кажется: провайдеры подписок
(GitHub Copilot, Cursor, Kiro, OpenCode Go, MiniMax, DeepSeek, GLM),
middleware (privacy filter, model fallback, системные промпты),
маршрутизация, usage, квоты. 191 плагин - это уже готовая экосистема.

### 4.2. Блокер: движок собран без cgo

`MacOS/_sources/CLIProxyAPI/internal/pluginhost/loader_unix.go` имеет
build-тег `cgo && (linux || darwin || freebsd)`. При `CGO_ENABLED=0`
собирается `loader_unsupported.go`, который возвращает ошибку на любой
плагин.

Проверка на живом движке Melon:

```
pluginhost: failed to load plugin jshandler ...
standard dynamic library plugin loading requires cgo on this platform
```

То есть магазин можно открыть, плагин можно скачать, но он не заработает.
Это P0. Без него весь раздел Plugins будет декоративным.

Решение проверено:

```
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 go build ... -o cliproxyapi-arm64
CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 go build ... -o cliproxyapi-amd64
lipo -create -output cliproxyapi cliproxyapi-arm64 cliproxyapi-amd64
```

Обе сборки прошли, `file` показывает универсальный бинарь, `otool` показывает только
системные библиотеки. После запуска cgo-движка `jshandler` загрузился и
зарегистрировался.

Что нужно поменять:

- `MacOS/build.sh`: собирать два cgo-слайса и склеивать `lipo`, а не два
  статических слайса.
- `Windows/scripts/build-engine.sh` и `Windows/app/resources/engine-provenance.json`:
  Windows-загрузчик использует `syscall`, cgo там не обязателен, но
  проверить установку и загрузку плагина на Windows отдельным тестом.
- CI: на macOS-раннере должны быть Xcode command line tools и обе
  архитектуры. Добавить smoke-тест: запустить движок с тестовым плагином и
  проверить `registered: true`.
- Если позже включат hardened runtime и нотаризацию, понадобится
  `com.apple.security.cs.disable-library-validation`, иначе подписанное
  приложение не загрузит сторонний `.dylib`.

### 4.3. Чего нет в Melon

- Отдельного пункта Plugins и экрана магазина.
- Клиента management API и моделей ошибок.
- Формы настроек по `config_fields`.
- Связи плагинов с разделом Providers и с каталогом моделей Codex.
- Кураторского слоя: какие плагины рекомендованы, какие опасные, какие переведены.
- Своего реестра community-плагинов.
- Песочницы для HTML-страниц плагинов.
- Тестов на установку, включение, откат и падение плагина.

## 5. Рекомендуемая архитектура

### 5.1. Принцип

Не строить второй runtime. Использовать тот, что уже внутри CLIProxyAPI.
Melon даёт удобный интерфейс, кураторство и связку с моделями, а установку,
загрузку и жизненный цикл делает движок.

```
SwiftUI (macOS) / Tauri UI (Windows)
        |
        v
PluginStoreClient  -->  GET  /v8/management/plugins/store
        |               POST /v8/management/plugins/store/<id>/install
        |               GET  /v8/management/plugins
        |               DELETE /v8/management/plugins/<id>
        |               PATCH /v0/management/plugins/<id>/enabled
        |               GET/PUT /v0/management/plugins/<id>/config
        v
CodexGatewayService  -->  CLIProxyAPI (cgo)
                              |
                              +--> plugin host -> .dylib / .dll
                              +--> provider / interceptor / router
                              +--> management resource (HTML dashboard)
```

Приложение не загружает `.dylib` само. Это делает шлюз. Падение плагина
роняет шлюз, но не UI; `CodexGatewayService` уже умеет перезапускать движок
и показывать ошибку.

### 5.2. Конфигурация

Добавить в `CodexGatewayService` генерацию блока:

```yaml
plugins:
  enabled: true
  dir: "/Users/<user>/Library/Application Support/MelonTools/gateway/plugins"
```

Правила:

- `dir` только абсолютный. Движок запускается без `currentDirectoryURL`,
  поэтому относительный `plugins` попадёт в непредсказуемый каталог.
- Каталог `0700`, как остальные данные шлюза.
- `enabled: true` писать только после первого согласия пользователя, а не
  всем при запуске. До этого магазин работает, но плагины не грузятся.
- После установки первого плагина перезапустить шлюз. Management API умеет
  ставить плагин на лету, но загрузка нового `.dylib` требует рестарта.
- `plugins.configs.<id>` не писать вручную: для этого есть
  `PUT /v0/management/plugins/<id>/config`, и движок сам перезагрузит
  конфиг.

### 5.3. Клиент магазина

Новый слой на macOS:

- `MacOS/app/MelonTools/Plugins/PluginModels.swift`: `PluginStoreEntry`,
  `PluginInstalledEntry`, `PluginConfigField`, `PluginMenu`, `PluginError`.
- `MacOS/app/MelonTools/Plugins/PluginStoreClient.swift`: актор, bearer
  `managementSecret`, таймауты, декодирование обоих ответов, кэш магазина
  на 5 минут.
- `MacOS/app/MelonTools/Plugins/PluginStore.swift`: `ObservableObject`,
  состояние загрузки, установленные, обновления, ошибки, установка,
  включение, удаление, сохранение настроек.
- `MacOS/app/MelonTools/Plugins/PluginCatalogOverlay.swift`: кураторские
  названия, переводы, категории, предупреждения для топовых плагинов.

Важно: store API и lifecycle API живут на разных версиях. Магазин это
`/v8/management/plugins/store`, а включение и конфиг только в
`/v0/management/plugins/<id>/...`. Это не опечатка, это проверено на живом
движке.

### 5.4. Экран Plugins

Отдельный пункт в sidebar, как просил пользователь:

- `MTSection.plugins`, иконка `puzzlepiece.extension`, акцент `violet`.
- Новая группа `Extend` после `Models`: `[.plugins]`. Позже туда же можно
  добавить MCP или темы.
- На Windows: новая группа `extend` в `NAV` после `models`, страница
  `plugins` в `render()`.

Макет:

- Заголовок `Плагины`, подзаголовок про расширения от сообщества.
- Поиск, фильтры по тегам: `Провайдеры`, `Маршрутизация`, `Аналитика`,
  `Безопасность`, `Инструменты`.
- Сегменты `Обзор` и `Установленные` с счетчиком.
- Сетка карточек 2 колонки: иконка, имя, автор, версия, теги, короткое
  описание, состояние, кнопка.
- `Melon Picks` сверху: 10-15 плагинов, которые реально проверены.
- Экран плагина: полное описание, автор, лицензия, репозиторий, источник,
  версия, теги, `config_fields`, кнопки Install/Update/Remove, тумблер
  Enabled, ссылка на dashboard, если plugin menu есть.
- Экран согласия перед установкой: что код нативный, где выполняется, какие
  права получает, кто автор, откуда скачано.
- Состояния: загрузка, офлайн, шлюз выключен, плагины отключены, плагин не
  загрузился, нужен рестарт, ошибка checksum.

Не показывать 191 плагин плоским списком без категорий. Пользователю нужны
10 понятных рекомендаций и поиск, а не каталог ради каталога.

### 5.5. Связка с провайдерами и моделями

Это самый важный интеграционный кусок. Плагин-провайдер регистрирует
модели внутри шлюза, но Melon строит свои списки из `ModelSources` и
`CodexModelCatalog`. Без связки модели плагина не появятся в picker.

Нужно:

- `PluginProviderCatalog`: после загрузки плагинов читать
  `GET /v1/models` (или management credentials models) и собирать модели,
  которые принадлежат плагинам.
- Синтетический `ModelSource.Kind.plugin`: только для каталога, без записи
  в `api-keys`.
- `ModelSourcesStore.gatewayYAML()` должен пропускать `.plugin`, иначе
  получится петля: Melon напишет провайдера, который смотрит на собственный
  шлюз.
- `CodexModelCatalog.sync` должен включать модели плагинов, чтобы они были
  в `melon-model-catalog.json` и в picker.
- В `Providers` добавить read-only блок `Plugin providers` со ссылкой
  `Управлять в Plugins`.
- При выключении плагина убирать его модели из каталога и из picker.

Без этого «плагин установлен» не равно «плагином можно пользоваться».

### 5.6. Кураторство и сообщество

MVP:

- Показывать источник `CLIProxyAPI Official` честно, не выдавать за Melon.
- `Melon Picks` с ручным списком и переводами.
- Ссылка `Стать автором` на документацию и шаблон.
- Кнопка `Сообщить о проблеме` на репозиторий плагина.

Следующий шаг:

- Репозиторий `melon-tools/plugins` с `registry.json` той же схемы.
- Добавить его как `plugins.store-sources` в конфиг.
- CI: собрать плагин, проверить ABI, checksums, лицензию, отсутствие
  секретов, наличие README и иконки.
- Ревью: один поддерживающий, чек-лист, правило «никаких install-скриптов».
- Шаблоны: provider, interceptor, scheduler, management page.
- Автору не нужно писать на Go только из-за Melon: он может писать на C,
  Rust или любом языке с C ABI, но порог всё равно выше, чем у JS.

#### 5.6.1. Минимальный контракт автора

Плагин это динамическая библиотека, которая экспортирует C-функцию:

```c
int cliproxy_plugin_init(const cliproxy_host_api* host, cliproxy_plugin_api* plugin);
```

Хост передаёт таблицу `host` и получает таблицу `plugin` с `call`,
`free_buffer` и `shutdown`. Дальше обмен идёт JSON-конвертами:
`{"ok": true, "result": ...}` или `{"ok": false, "error": ...}`. Это
ABI, нейтральный к языку, поэтому подойдут Go, C, Rust или любой язык с C ABI.

Сборка Go-плагина:

```bash
go build -buildmode=c-shared -o \
  plugins/darwin/$(go env GOARCH)/example-provider.dylib .
```

Релиз на GitHub:

```
example-provider_1.0.0_darwin_arm64.zip
example-provider_1.0.0_darwin_amd64.zip
example-provider_1.0.0_windows_amd64.zip
checksums.txt
```

`checksums.txt` обязателен: движок проверяет по нему архив перед установкой.
Запись в `registry.json`:

```json
{
  "id": "example-provider",
  "name": "Example Provider",
  "description": "Adds Example as an OpenAI-compatible provider.",
  "author": "your-name",
  "version": "1.0.0",
  "repository": "https://github.com/you/example-provider",
  "license": "MIT",
  "tags": ["Provider"]
}
```

Шаблоны и примеры уже есть в
`MacOS/_sources/CLIProxyAPI/examples/plugin/` (Go, C, Rust). Melon не требует
своего SDK для MVP: автор делает плагин под CLIProxyAPI, а Melon показывает
его в магазине.

Если через 2-3 месяца окажется, что главный запрос сообщества это «своя
страница» или «свой агент», тогда делаем отдельный JS/HTML-слой. Не раньше:
сначала нужно исчерпать 191 готовый плагин.

### 5.7. Безопасность

- Нативный плагин это доверенный код в процессе шлюза. Он видит конфиг,
  токены и может ходить в сеть. Это надо писать на экране установки.
- Установка только по кнопке, без автообновления по умолчанию.
- Показывать автора, репозиторий, лицензию, версию, checksum.
- Хранить хеш установленного файла в `plugins-state.json` и проверять при
  запуске; при расхождении не грузить и предлагать переустановку.
- `Safe Mode`: кнопка «Отключить все плагины» пишет `plugins.enabled: false`,
  перезапускает шлюз и оставляет UI доступным.
- Не встраивать HTML-дашборды плагинов в MVP. Они не в песочнице, могут
  обращаться к management API и тянуть сеть. Для них нужен отдельный
  WebView с прокси и запретом навигации, это фаза 2.
- Не логировать значения `config_fields`: там могут быть ключи.

## 6. План по фазам

Оценка для одного опытного разработчика, без дизайнера и без Windows-порта
в первом релизе.

| Фаза | Что делаем | Результат | Срок |
| --- | --- | --- | --- |
| 0 | cgo-движок | универсальный бинарь, плагин грузится, smoke-тест в CI | 2-3 дня |
| 1 | клиент API и конфиг | магазин читается, установка/удаление/включение работают | 4-5 дней |
| 2 | экран Plugins | Обзор, Установленные, карточки, детали, поиск | 6-8 дней |
| 3 | настройки и жизненный цикл | формы по `config_fields`, рестарт, ошибки, Safe Mode | 4-5 дней |
| 4 | модели и кураторство | Plugin providers в picker, Melon Picks, переводы | 5-7 дней |
| 5 | Windows | тот же API и экран на Tauri | 6-8 дней |
| 6 | свой реестр | `melon-tools/plugins`, CI, шаблоны, ревью | 5-7 дней |
| 7 | JS/HTML-слой | песочница, page API, агентские плагины | 4-6 недель |

MVP macOS: фазы 0-4, около 3 недель. Windows: плюс 1,5 недели. Свой реестр:
плюс неделя. Полный слой страниц: отдельный проект на 4-6 недель, не
блокирует запуск.

### 6.1. Критерии приемки MVP

1. Чистая установка Melon на Apple Silicon: раздел Plugins открывается,
   магазин отдаёт 191 плагин, поиск и фильтры работают.
2. Установка `github-copilot` или `cursor`: плагин скачивается, checksum
   сходится, шлюз перезапускается, плагин `registered: true`.
3. Модели установленного провайдера видны в Providers и в picker Codex,
   запрос через них проходит.
4. Выключение плагина убирает его модели; включение возвращает.
5. Настройки плагина сохраняются, переживают перезапуск приложения и
   перезапуск шлюза.
6. Remove удаляет файл и запись, не ломает конфиг.
7. Падение шлюза из-за плагина: UI показывает ошибку, предлагает Safe Mode,
   после Safe Mode шлюз поднимается без плагинов.
8. Офлайн: установленные плагины работают, магазин показывает кэш и
   понятную ошибку.
9. Windows: тот же сценарий на x64.
10. В логах нет токенов и значений секретных полей.

### 6.2. Что делать в первую очередь

1. Перевести `MacOS/build.sh` на cgo и добавить smoke-тест загрузки
   плагина. Без этого остальное бессмысленно.
2. Добавить `plugins` в генерацию `config.yaml` и `PluginStoreClient`.
3. Собрать экран Plugins на реальном API, без моков.
4. Связать модели плагинов с `ModelSources` и `CodexModelCatalog`.
5. Добавить Melon Picks и экран согласия.
6. Повторить на Windows.

## 7. Чего не делать в MVP

- Не писать свой Bun-хост и не тащить Bun в бандл. Это отдельный проект.
- Не копировать код Magpie. Лицензия MIT позволяет, но архитектурно это
  другой runtime, и поддержка будет чужая.
- Не включать `plugins.enabled` по умолчанию у всех.
- Не делать автообновление без согласия.
- Не встраивать сторонние HTML-дашборды без песочницы и авторизации.
- Не показывать все 191 плагина без кураторства и переводов.
- Не пытаться сразу сделать агентские плагины и tools. Это следующий слой.

## 8. Риски

| Риск | Почему важно | Что делаем |
| --- | --- | --- |
| Нативный код роняет шлюз | Плагин в процессе, а не в песочнице | Safe Mode, рестарт, установка только по кнопке, кураторство |
| cgo ломает сборку/CI | Движок перестанет собираться на Intel или в CI | Два слайса, lipo, smoke-тест на обеих архитектурах |
| ABI/версия движка | Плагины собираются под конкретный ABI | Зафиксировать версию движка, тестовый плагин в CI, не обновлять движок без прогона магазина |
| Китайские метаданные | 191 плагин в основном на китайском | Melon Picks с переводами, фильтр по языку, не переводить всё машинно |
| Качество плагинов | 191 плагин разного уровня | Кураторский список, предупреждения, ссылка на репозиторий, отзывы |
| Нотаризация | Сторонние dylib не загрузятся в hardened runtime | Добавить entitlement или не включать hardened runtime до решения |
| Модели не видны | Плагин работает, но picker пуст | Синтетический источник и PluginProviderCatalog в MVP |
| Дашборды без auth | HTML может дергать management API | Не встраивать в MVP, потом отдельный прокси |

## 9. Решения, которые нужны от пользователя

1. **База.** Согласен ли ты, что MVP это нативные плагины CLIProxyAPI, а не
   свой JS-runtime? Я рекомендую да: 191 готовый плагин против нуля.
2. **Бренд.** Показывать магазин как `CLIProxyAPI Official` внутри Melon или
   как `Melon Plugins` с пометкой источника? Я рекомендую второе, но
   честно с источником.
3. **Кураторство.** Делать `Melon Picks` на 10-15 плагинов сразу или
   показывать всё с сортировкой? Я рекомендую Picks.
4. **Windows.** Выпускать macOS и Windows вместе или сначала macOS, потом
   Windows? Я рекомендую сначала macOS, Windows следующим релизом.
5. **Свой реестр.** Запускать `melon-tools/plugins` сразу или сначала
   посмотреть, чего не хватает в 191 плагине? Я рекомендую сначала
   посмотреть.

## 10. Источники

Magpie:

- https://github.com/yetone/magpie
- https://github.com/yetone/magpie/blob/main/docs/subsystems/plugin-runtime.md
- https://github.com/yetone/magpie/blob/main/docs/subsystems/provider-plugins.md
- https://github.com/magpie-community/plugins
- https://github.com/magpie-community/plugins/blob/main/registry.json

CLIProxyAPI:

- `MacOS/_sources/CLIProxyAPI/docs/management-api-v8.md`
- `MacOS/_sources/CLIProxyAPI/internal/api/server_management_v8.go`
- `MacOS/_sources/CLIProxyAPI/internal/api/handlers/management/plugin_store.go`
- `MacOS/_sources/CLIProxyAPI/internal/pluginhost/loader_unix.go`
- `MacOS/_sources/CLIProxyAPI/internal/pluginhost/loader_unsupported.go`
- https://github.com/router-for-me/CLIProxyAPI
- https://github.com/router-for-me/CLIProxyAPI-Plugins-Store

Melon Tools:

- `MacOS/build.sh`
- `MacOS/app/MelonTools/Codex/CodexGatewayService.swift`
- `MacOS/app/MelonTools/Codex/ModelSources.swift`
- `MacOS/app/MelonTools/Codex/CodexModelCatalog.swift`
- `MacOS/app/MelonTools/Views/MainView.swift`
- `Windows/app/src-tauri/src/gateway.rs`
- `Windows/app/src-tauri/src/codex_models.rs`
- `Windows/app/ui/app.js`
- `Windows/app/ui/mt-pages.js`
