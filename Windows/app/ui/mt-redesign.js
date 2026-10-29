// Melon Tools — 3.0.0 Windows redesign layer.
// Loaded after app.js: overrides page renderers and helpers with the macOS-parity
// design while keeping the modular state/actions/bridge from the 2.4.4 line.

Object.assign(S, {
  checkPassed: null,
  checkErrorDetail: null,
  codexApp: null,
  codexAppError: null,
  launchModal: null,
  launchError: null,
  accountSettings: null,
  popup: null,
});

Object.assign(DICT.ru, {
  "dashboard": "Обзор",
  "accounts": "Аккаунты",
  "api": "API-сервис",
  "providers": "Подключения",
  "donate": "Донат",
  "settings": "Настройки",
  "codex": "Codex",
  "general": "Приложение",
  "overview": "Обзор",
  "schedulerGroup": "Планировщик",
  "brandSub": "планировщик и Codex в одном месте",
  "codexPool": "Пул Codex",
  "open": "Открыть",
  "weeklyLeft": "Остаток недели: {n}%",
  "noAccountsYet": "Аккаунтов пока нет.",
  "composer": "Чипы композера",
  "instances": "Инстансы Codex",
  "dashTitle": "Обзор",
  "dashSub": "Планировщик и пул Codex в реальном времени.",
  "gateway": "Шлюз",
  "running": "работает",
  "stopped": "остановлен",
  "starting": "запускается…",
  "start": "Запустить",
  "stop": "Остановить",
  "restart": "Перезапустить",
  "check": "Проверить API",
  "refresh": "Обновить",
  "sync": "Синхронизировать с шлюзом",
  "port": "Порт",
  "reqs": "Запросы/мин",
  "sidecar": "движок",
  "found": "найден",
  "missing": "не найден",
  "poolSummary": "Пул аккаунтов",
  "accountsCount": "аккаунтов",
  "pool5h": "5ч (суммарно)",
  "poolWeek": "Неделя (суммарно)",
  "blockedNow": "на паузе",
  "allReady": "все готовы",
  "quick": "Быстрые действия",
  "refreshQuotas": "Обновить квоты",
  "importAuth": "Импортировать текущий вход Codex",
  "accountsSub": "Пул аккаунтов ChatGPT. Переключение меняет активный вход и сохраняет резервную копию.",
  "importHint": "Добавляет аккаунт, в который вы уже вошли в Codex.",
  "fiveHour": "5 ч",
  "week": "Неделя",
  "resetIn": "сброс",
  "resetNow": "сброс вот-вот",
  "onceReset": "при первом запросе",
  "reserveHourly": "Резерв 5ч, %",
  "reserveWeekly": "Резерв недели, %",
  "save": "Сохранить",
  "makeCurrent": "Сделать текущим",
  "refreshLogin": "Обновить логин",
  "refreshQuota": "Обновить квоту",
  "remove": "Удалить",
  "current": "текущий",
  "paused": "на паузе",
  "ready": "готов",
  "bHourly": "5-часовое окно исчерпано",
  "bWeekly": "недельное окно исчерпано",
  "bHourlyReserve": "осталось {r}% ≤ резерва {l}%",
  "bWeeklyReserve": "осталось {r}% ≤ резерва {l}%",
  "bHourlyStopped": "остановлено при {r}% (резерв {l}%)",
  "bWeeklyStopped": "остановлено при {r}% (резерв {l}%)",
  "bHourlyExhaustedStopped": "квота 5 ч исчерпана — остановлено при {r}%",
  "bWeeklyExhaustedStopped": "недельная квота исчерпана — остановлено при {r}%",
  "reserveExact": "Пауза срабатывает точно на этом значении. Запрос, уже начатый до паузы, может опустить остаток немного ниже.",
  "poolPauseHourly": "Все аккаунты на паузе по часовому резерву — сброс в {time}",
  "poolPauseWeekly": "Все аккаунты на паузе по недельному резерву — сброс в {time}",
  "poolPauseMixed": "Все аккаунты на паузе — ближайший сброс в {time}",
  "poolPauseExhausted": "Квота исчерпана — сброс в {time}",
  "poolPauseLift": "Снять паузу",
  "poolPauseConfirm": "Снять паузу по резерву? Квота может опуститься до 0%.",
  "quotaAge": "квота обновлена",
  "quotaLive": "live от шлюза",
  "quotaUsage": "данные OpenAI",
  "never": "никогда",
  "stale": "устарела",
  "history": "История",
  "historyHint": "Остаток квоты по последним обновлениям.",
  "apiSub": "Локальный OpenAI-совместимый сервис на пуле ваших аккаунтов Codex.",
  "endpoint": "Адрес",
  "apiKey": "Ключ",
  "copy": "Копировать",
  "copied": "Скопировано",
  "endpointsTitle": "Подключение клиентов",
  "checkTitle": "Проверка API",
  "checkHint": "",
  "checkResult": "Результат",
  "logFile": "Журнал",
  "dataDir": "Данные",
  "codexRoute": "Интеграция с Codex",
  "routeApply": "Настроить Codex",
  "routeRemove": "Убрать роутинг",
  "routeActive": "Codex работает через этот сервис",
  "routeInactive": "Маршрут не задан — приложение Codex обращается к OpenAI напрямую",
  "routeOther": "Активен внешний маршрут: {name}",
  "catalog": "Каталог моделей",
  "bridge": "Чипы в композере",
  "bridgeOn": "Подключено к Codex",
  "bridgeOff": "Нет связи с Codex",
  "bridgeHint": "Codex запущен без отладочного порта",
  "bridgeRestart": "Перезапустить Codex с чипами",
  "bridgeRestartConfirm": "Codex будет закрыт и открыт заново, чтобы подключить чипы. Несохранённый ввод может пропасть. Продолжить?",
  "bridgeRestarted": "Codex запущен заново",
  "apiControl": "Управление API",
  "startGateway": "Запустить сервис",
  "openCodex": "Открыть Codex",
  "launchCodex": "Запустить Codex",
  "configuration": "Параметры",
  "apiKeyHint": "Этот ключ используется как API-ключ OpenAI в других инструментах.",
  "clientHint": "Любой OpenAI-совместимый инструмент может обращаться к этому сервису. Запросы обслуживаются аккаунтами Codex и расходуют вашу подписку ChatGPT.",
  "routingMode": "Режим роутинга",
  "manage": "Управление",
  "checkPassed": "Проверка пройдена",
  "checkFailed": "Проверка не пройдена",
  "checkFailedHint": "Проверка не пройдена. Убедитесь, что сервис запущен, и повторите.",
  "accountSwitched": "Аккаунт переключён",
  "routeApplied": "Маршрут Codex настроен",
  "accountAdded": "Аккаунт добавлен",
  "accountUpdated": "Аккаунт обновлён",
  "instanceLaunched": "Инстанс запущен",
  "launchingCodex": "Запускаю Codex…",
  "launchNoteOn": "Роутинг включён — запросы Codex обслуживает пул аккаунтов.",
  "launchNoteOff": "Запуск подключает Codex к этому сервису, сохраняет прошлое подключение и открывает приложение заново.",
  "routeActiveShort": "Codex работает через этот сервис.",
  "routeNoneShort": "Маршрут не задан.",
  "routeOtherShort": "Внешний маршрут: {name}.",
  "technicalDetails": "Дополнительно",
  "serviceAddress": "Адрес сервиса",
  "serviceKey": "Ключ доступа",
  "appManagement": "Приложение Codex",
  "appManagementSub": "Путь к ChatGPT.exe для запуска и чипов композера.",
  "appFound": "Приложение найдено",
  "appNotFound": "Приложение не найдено",
  "appRunning": "запущено",
  "appNotRunning": "не запущено",
  "chooseAppPath": "Указать путь к ChatGPT.exe",
  "chooseAppPathTitle": "Выберите ChatGPT.exe",
  "changeAppPath": "Изменить путь",
  "forgetAppPath": "Сбросить путь",
  "appPathSaved": "Путь к приложению сохранён",
  "appPathForgotten": "Приложение ищется автоматически",
  "appPathStale": "Путь устарел",
  "codexNotFoundTitle": "Приложение Codex не найдено",
  "codexNotFoundBody": "Melon Tools не смог найти ChatGPT.exe. Укажите путь к приложению — дальше всё запустится автоматически.",
  "codexPathInvalidTitle": "Не удалось открыть приложение",
  "codexPathInvalidBody": "Выбранный файл не похож на ChatGPT.exe. Выберите файл ещё раз.",
  "codexLaunchFailedTitle": "Codex не запустился",
  "codexLaunchFailedBody": "Закройте Codex вручную и попробуйте снова. Если приложение установлено в защищённую папку, подтвердите запрос прав администратора.",
  "codexServiceFailedTitle": "Сервис не запустился",
  "codexServiceFailedBody": "Проверьте порт в настройках и попробуйте снова.",
  "codexRouteFailedTitle": "Не удалось подключить Codex",
  "codexRouteFailedBody": "Проверьте, что папка Codex доступна, и попробуйте снова.",
  "downloadCodex": "Скачать Codex",
  "retry": "Повторить",
  "cancel": "Отмена",
  "choose": "Выбрать",
  "codexOpened": "Codex открыт",
  "codexPathTechnical": "Путь",
  "codexSourceTechnical": "Источник",
  "codexDebugPort": "Порт чипов",
  "codexSourceManual": "выбран вручную",
  "codexSourceAuto": "найден автоматически",
  "codexSourceStore": "Store-версия",
  "codexSourceEnvironment": "переменная окружения",
  "codexHint": "Если приложение установлено в Microsoft Store, путь можно не указывать — Melon Tools найдёт его сам.",
  "providersSub": "Модели Codex: пул аккаунтов и подключённые провайдеры",
  "openrouter": "OpenRouter",
  "orKey": "Ключ OpenRouter",
  "totalCredits": "Куплено",
  "spend": "Потрачено",
  "remaining": "Остаток",
  "available": "доступно",
  "balance": "Баланс",
  "lifetime": "За всё время",
  "keyLimit": "Лимит ключа",
  "keyRemaining": "Остаток лимита ключа",
  "keySpend": "Расход ключа",
  "opencode": "OpenCode",
  "ocKey": "Ключ OpenCode (oc_sk_…)",
  "ocHint": "После сохранения ключей перезапустите шлюз — модели opencode/* и openrouter/* появятся в списке.",
  "deepinfra": "DeepInfra",
  "diKey": "Ключ DeepInfra",
  "loadModels": "Загрузить модели",
  "diHint": "Только чат-модели. У DeepInfra нет баланса ключа: карточка показывает число моделей и расход сессии. После загрузки перезапустите шлюз.",
  "vercel": "Vercel",
  "vcKey": "Ключ Vercel AI Gateway",
  "vcHint": "Ключ Vercel AI Gateway (AI_GATEWAY_API_KEY), не личный токен Vercel. Баланс и расход — общие для команды. После загрузки перезапустите шлюз.",
  "sessionSpend": "Расход сессии",
  "teamBalance": "Баланс команды",
  "lifetimeSpend": "Всего израсходовано",
  "keyConfigured": "ключ задан",
  "noKey": "ключ не задан",
  "keyRequired": "Сначала задайте ключ",
  "modelsAvailable": "Доступно моделей",
  "claude": "Claude",
  "claudeSub": "Anthropic Claude: вход по подписке через OAuth, опциональный API-ключ.",
  "claudeConnect": "Подключить",
  "claudeConnecting": "Ждём подтверждение…",
  "claudeCancel": "Отмена",
  "claudeDisconnect": "Отключить",
  "claudeConnected": "подключён",
  "claudeNotConnected": "не подключён",
  "claudeLoginError": "Не удалось войти в Claude",
  "claudeKey": "API-ключ Anthropic (резерв)",
  "claudeHint": "OAuth — подписка Claude (основной способ). API-ключ — резерв pay-as-you-go: блок появится в конфиге шлюза, только когда тумблер включён и ключ непуст.",
  "claudeDisconnected": "Claude отключён",
  "confirmClaudeDisconnect": "Отключить Claude? Аккаунт будет удалён из шлюза.",
  "antigravity": "Antigravity",
  "antigravitySub": "Google-аккаунт (Antigravity) через OAuth.",
  "antigravityConnect": "Подключить",
  "antigravityConnecting": "Ждём подтверждение…",
  "antigravityCancel": "Отмена",
  "antigravityDisconnect": "Отключить",
  "antigravityConnected": "подключён",
  "antigravityNotConnected": "не подключён",
  "antigravityLoginError": "Не удалось войти в Antigravity",
  "antigravityHint": "Вход через Google-аккаунт Antigravity (только OAuth). Квоты не отображаются — их API не предоставляет.",
  "antigravityDisconnected": "Antigravity отключён",
  "confirmAntigravityDisconnect": "Отключить Antigravity? Аккаунт будет удалён из шлюза.",
  "loginTimeout": "Вход не подтверждён за 10 минут — попробуйте снова",
  "projectId": "Проект",
  "settingsSub": "Внешний вид, язык, сервис и квоты.",
  "language": "Язык",
  "quotaInterval": "Автообновление квот",
  "apply": "Применить",
  "about": "О приложении",
  "version": "Версия",
  "platform": "Платформа",
  "appearance": "Внешний вид",
  "serviceSettings": "Настройки сервиса",
  "dashboardWidgets": "Виджеты обзора",
  "accent": "Акцент",
  "goldenMelon": "золотая дыня",
  "showPoolHealth": "Показывать состояние пула",
  "showQuotaTrends": "Показывать лимиты квот",
  "showSpend": "Показывать расход и топ провайдеров",
  "showScheduler": "Показывать сводку планировщика",
  "settingsPort": "Порт сервиса",
  "settingsPortHint": "Меняйте, только если порт занят другой программой.",
  "minutesShort": "{n} мин",
  "off": "Выкл",
  "oneMin": "1 мин",
  "fiveMin": "5 мин",
  "fifteenMin": "15 мин",
  "thirtyMin": "30 мин",
  "aboutSub": "Персональный пульт для планировщика и пула аккаунтов Codex.",
  "codexHome": "Папка Codex",
  "backupCard": "Резервная копия",
  "backupCardSub": "Шифрованная копия планировщика, настроек, аккаунтов и файлов входа, а также источников моделей. Логи и ключи шлюза не включаются. Пароль не сохраняется.",
  "backupPassword": "Пароль",
  "backupExport": "Экспорт",
  "backupImport": "Импорт",
  "backupLast": "Последняя копия",
  "backupNone": "Копий ещё нет",
  "backupPasswordRequired": "Введите пароль",
  "backupExported": "Резервная копия сохранена: {path} ({bytes} байт)",
  "backupImportConfirm": "Импортировать копию? Задачи планировщика, настройки, аккаунты и файлы входа будут заменены данными из копии.",
  "backupImported": "Импортировано: задач {tasks}, аккаунтов {accounts}, файлов входа {auths}, настроек {settings}",
  "backupImportModels": " · источники моделей включены",
  "backupImportRestartFailed": "Импорт завершён, но шлюз не перезапустился — запустите API-сервис вручную",
  "donateSub": "Поддержать Melon Tools переводом в USDT (TRC20)",
  "donateAddress": "Адрес кошелька",
  "copyAddress": "Копировать адрес",
  "donateThanks": "Спасибо, что поддерживаешь Melon Tools! 🍉",
  "donateNote": "Сеть TRON (TRC20). Спасибо за поддержку! 🍉",
  "warnNoAccounts": "Пул пуст — импортируйте текущий вход Codex или добавьте аккаунт в macOS-версии и скопируйте vault.",
  "loading": "Загрузка…",
  "error": "Ошибка",
  "done": "Готово",
  "confirmDelete": "Удалить аккаунт {name} из пула?",
  "confirmDeleteInstance": "Удалить инстанс {name}?",
  "okPill": "готов",
  "autoRefresh": "автообновление квот",
  "addAccount": "Добавить аккаунт",
  "addAccountHint": "Вход по коду: откроется страница OpenAI, введите код.",
  "deviceCode": "Код",
  "deviceWaiting": "Ждём подтверждение…",
  "deviceOpen": "Открыть страницу входа",
  "deviceTimeout": "Код входа истёк — начните вход заново",
  "subscription": "Подписка",
  "until": "до",
  "resetsAvailable": "Сбросы 5ч",
  "resetsNone": "нет",
  "accountModels": "Модели на аккаунте",
  "accountSettings": "Настройки аккаунта",
  "availableShort": "есть",
  "unavailableShort": "нет",
  "routing": "Роутинг",
  "accountRouting": "Роутинг аккаунтов",
  "strategy": "Стратегия",
  "strategyAuto": "Авто (рекомендуется)",
  "strategyQuotaHigh": "Сначала с большим остатком",
  "strategyQuotaLow": "Сначала с меньшим остатком",
  "strategyPlanHigh": "Сначала старший тариф",
  "strategyPlanLow": "Сначала младший тариф",
  "strategyExpiry": "Сначала с ближайшим сроком",
  "strategyCustom": "Вручную (свой порядок)",
  "orderUp": "Выше",
  "orderDown": "Ниже",
  "resetOrder": "Сбросить порядок",
  "strategyHintAuto": "Первым идёт аккаунт «Всегда первый», затем — с наибольшим остатком. Резервные — в конце.",
  "strategyHintQuotaHigh": "Первым используется аккаунт с наибольшим остатком квоты.",
  "strategyHintQuotaLow": "Первым используется аккаунт с наименьшим остатком — он расходуется до переключения.",
  "strategyHintPlanHigh": "Сначала используются тарифы старше.",
  "strategyHintPlanLow": "Сначала используются тарифы младше.",
  "strategyHintExpiry": "Первым используется аккаунт с ближайшим окончанием подписки.",
  "strategyHintCustom": "Порядок задаётся стрелками; лимиты и роль «Резерв» продолжают действовать.",
  "applyRouting": "Применить роутинг",
  "accountsInPool": "Аккаунтов в пуле: {n}",
  "orderCustom": "Включён ручной порядок — шлюз следует списку карточек",
  "preferred": "Первый",
  "backup": "Бэкап",
  "recentCalls": "Последние вызовы",
  "noCalls": "пока пусто",
  "scheduler": "Планировщик",
  "schedulerSub": "Задачи по расписанию: cron, интервалы и шаблоны. Работают, пока Melon Tools в трее.",
  "schedulerAdd": "Добавить задачу",
  "schedulerAddTitle": "Новая задача",
  "schedulerEditTitle": "Изменить задачу",
  "schedulerName": "Название",
  "schedulerPrompt": "Запрос",
  "schedulerModel": "Модель",
  "schedulerEffort": "Reasoning effort",
  "schedulerEffortDefault": "по умолчанию",
  "schedulerInterval": "Интервал, мин",
  "schedulerEnabled": "Включена",
  "schedulerRunNow": "Выполнить сейчас",
  "schedulerNext": "Следующий запуск",
  "schedulerLast": "Последний запуск",
  "schedulerStatus": "Статус",
  "schedulerResult": "Результат",
  "schedulerNoResult": "Результатов пока нет",
  "schedulerEmpty": "Задач пока нет — добавьте первую.",
  "schedulerDelete": "Удалить",
  "schedulerEdit": "Изменить",
  "schedulerRequired": "Заполните название, запрос и модель",
  "confirmDeleteTask": "Удалить задачу {name}?",
  "schedulerEvery": "каждые {n} мин",
  "schedulerDue": "вот-вот",
  "schedulerRunning": "выполняется…",
  "schedulerOk": "успех",
  "schedulerError": "ошибка",
  "schedulerNever": "не запускалась",
  "schedulerHistory": "История",
  "schedulerFile": "Файл",
  "schedulerClose": "Закрыть",
  "schedulerModelHint": "Модели шлюза из /v1/models.",
  "schedulerModelsFailed": "Список моделей недоступен — запустите шлюз и обновите.",
  "schedulerGatewayOff": "Шлюз не отвечает — выполнять задачи некуда. Запустите API-сервис и повторите.",
  "schedulerTokens": "токены",
  "schedulerDuration": "время",
  "schedulerMinutesShort": "{n} мин",
  "schedulerTemplate": "Шаблон",
  "schedulerTemplateNone": "Без шаблона",
  "schedulerFromTemplate": "Из шаблона",
  "schedulerWorkingDirectory": "Рабочая папка (необязательно)",
  "schedulerGitContext": "Добавлять git status, log и diff в запрос",
  "schedulerMaxTokens": "Max tokens (0 = по умолчанию)",
  "schedulerRetries": "Повторы",
  "schedulerRetryDelay": "Пауза повтора, мин",
  "schedulerScheduleType": "Тип расписания",
  "schedulerScheduleInterval": "Интервал",
  "schedulerScheduleCron": "Cron",
  "schedulerCron": "Cron-выражение",
  "schedulerCronHint": "Минута час день месяц день недели",
  "schedulerCronExamples": "*/15 * * * * · 0 9 * * 1-5 · 0 */6 * * * · 0 0 1 * *",
  "schedulerCronInvalid": "Проверьте cron-выражение: нужно 5 полей",
  "schedulerTimeZone": "Часовой пояс",
  "schedulerZoneSystem": "Системный",
  "schedulerVariables": "Переменные",
  "schedulerVariableRequired": "Заполните переменные шаблона",
  "schedulerTrayHint": "Закройте окно — Melon Tools останется в трее и продолжит выполнять задачи.",
  "schedulerRepo": "Репозиторий",
  "schedulerBranch": "Ветка",
  "schedulerPath": "Путь",
  "schedulerTplMorning": "Утренняя сводка",
  "schedulerTplMorningDesc": "Свежие изменения и открытые задачи каждое утро в будни.",
  "schedulerTplPR": "Проверка PR",
  "schedulerTplPRDesc": "Открытые PR, проверки и рискованные изменения перед концом рабочего дня.",
  "schedulerTplWeekly": "Недельная сводка репозитория",
  "schedulerTplWeeklyDesc": "Слитые изменения, активные ветки и риски за неделю.",
  "schedulerTplLogs": "Проверка логов",
  "schedulerTplLogsDesc": "Поиск ошибок и предупреждений в свежих логах каждые шесть часов.",
  "schedulerTplSpend": "Отчёт о расходе за день",
  "schedulerTplSpendDesc": "Расход токенов, дорогие модели и необычные всплески за день.",
  "schedulerQueued": "в очереди",
  "schedulerQueuedCount": "в очереди: {n}",
  "schedulerRunQueued": "{name} — в очереди, запустится после текущего",
  "schedulerCancelCurrent": "Отменить текущую",
  "schedulerCancelling": "отменяется…",
  "schedulerCancelDone": "Отмена запрошена — очередь очищена",
  "schedulerCancelIdle": "Активных запусков нет",
  "schedulerCancelled": "отменено",
  "schedulerSkipped": "пропущено",
  "schedulerDailyTokenLimit": "Дневной лимит токенов (0 = без лимита)",
  "schedulerDailyLimit": "Лимит токенов в день",
  "schedulerDailyLimitNone": "без лимита",
  "schedulerDailyLimitInvalid": "Дневной лимит: 0 или от 1 до 1 000 000",
  "sgGateway": "Шлюз",
  "sgClaude": "Claude",
  "sgOpenCode": "OpenCode",
  "sgOpenRouter": "OpenRouter",
  "sgDeepInfra": "DeepInfra",
  "sgVercel": "Vercel",
  "instancesLabel": "Инстансы",
  "instanceNew": "Имя нового инстанса",
  "instanceCreate": "Создать",
  "instanceLaunch": "Запустить Codex",
  "instanceBind": "Аккаунт",
  "instanceNone": "текущий логин",
  "instanceDelete": "Удалить",
  "instanceHint": "Отдельный CODEX_HOME со своим входом.",
  "instancesSub": "Параллельные сессии Codex CLI — у каждой собственный вход и аккаунт.",
  "instancesEmpty": "Инстансов нет",
  "instancesEmptyHint": "Создайте инстанс, чтобы запустить сессию Codex CLI под нужным аккаунтом.",
  "composerLabel": "Композер",
  "composerHint": "Живые чипы пула аккаунтов в строке ввода Codex.",
  "connected": "Подключено",
  "notConnected": "Нет связи",
  "checkNow": "Проверить сейчас",
  "howItWorks": "Как это работает",
  "status": "Статус",
  "composerHow1": "Melon Tools показывает живые чипы пула прямо в окне Codex: аккаунты, квоты 5 ч и недели, состояние аккаунтов.",
  "composerHow2": "Данные приходят из Melon Tools на этом компьютере. Когда приложение не запущено, чипы тускнеют и сохраняют последние значения.",
  "composerHow3": "Нажмите чип «Аккаунты», чтобы открыть детали. Если чипов нет, перезапустите Codex кнопкой выше.",
  "models": "Модели",
  "modelsSearch": "Поиск модели…",
  "modelsCount": "моделей",
  "sources": "Источники",
  "sourceEnabled": "включён",
  "poolTitle": "Модели Codex",
  "poolSubtitle": "Модели OpenAI из общего пула аккаунтов. В picker попадают модели, выбранные хотя бы на одном аккаунте.",
  "poolInPool": "В пуле: {n} из {total}",
  "poolAccountSelected": "Выбрано: {n} из {total}",
  "poolAccounts": "{n} из {total} аккаунтов",
  "poolAll": "Выбрать все",
  "poolClear": "Снять все",
  "poolCloseLabel": "Закрыть",
  "poolAtLeastOne": "Хотя бы одна модель должна остаться выбранной.",
  "poolRelaunch": "Перезапустите Codex, чтобы обновить список моделей.",
  "poolNewOff": "Новые модели выключены, пока вы их не выберете.",
  "poolUnavailable": "недоступна",
  "autostart": "Автозапуск с Windows",
  "session": "Сессия",
  "donateScan": "Отсканируйте код или вставьте адрес в любой кошелёк с поддержкой USDT TRC20.",
  "update": "Обновить",
  "updateCheck": "Проверить обновление",
  "updateChecking": "Проверяем обновления…",
  "updateAvailable": "Доступно обновление {v}",
  "updateUpToDate": "У вас последняя версия ({v})",
  "updateFailed": "Не удалось проверить обновления",
  "updateDownloading": "Скачиваем обновление…",
  "updateInstalling": "Устанавливаем… приложение перезапустится",
  "updateCancel": "Отмена",
  "updateApply": "Обновить",
  "onboardingTitle": "Добро пожаловать в Melon Tools",
  "onboardingWelcome": "Настройте приложение за три шага.",
  "onboardingStep1": "Добавьте или импортируйте аккаунт Codex.",
  "onboardingStep2": "Подключите источники: OpenRouter, OpenCode, DeepInfra, Vercel AI Gateway, Claude, Antigravity.",
  "onboardingStep3": "Запустите API-сервис и откройте Codex.",
  "onboardingDisclaimer": "Используйте только свои аккаунты. Соблюдайте условия провайдеров: за нарушение правил возможна блокировка аккаунта.",
  "onboardingAccounts": "Открыть аккаунты",
  "onboardingProviders": "Открыть подключения",
  "onboardingDone": "Готово",
  "onboardingClose": "Закрыть",
  "onboardingHealth": "Проверка окружения",
  "onboardingHealthSub": "Живой статус без отправки запросов.",
  "onboardingPass": "ОК",
  "onboardingWarn": "ВНИМ.",
  "onboardingFail": "ОШИБКА",
  "onboardingGateway": "API-сервис",
  "onboardingGatewayOn": "Шлюз запущен и доступен",
  "onboardingGatewayOff": "Шлюз не запущен",
  "onboardingAccount": "Аккаунт",
  "onboardingAccountsCount": "Аккаунтов: {n}",
  "onboardingNoAccounts": "Нет добавленных аккаунтов",
  "onboardingModels": "Модели",
  "onboardingModelsCount": "Доступно моделей: {n}",
  "onboardingNoModels": "Каталог моделей пуст",
  "onboardingScheduler": "Планировщик",
  "onboardingTasksCount": "Задач: {n}",
  "onboardingNextRun": "Ближайший запуск: {time}",
  "onboardingNoTasks": "Задач пока нет",
  "onboardingBackup": "Резервная копия",
  "onboardingBackupAt": "Последняя копия: {time}",
  "onboardingNoBackup": "Копий ещё нет",
  "onboardingOpen": "Открыть",
  "onboardingRunHealth": "Проверить",
  "onboardingDemoTask": "Создать демо-задачу",
  "onboardingDemoName": "Демо-задача",
  "onboardingDemoPrompt": "Кратко опиши состояние этого рабочего пространства.",
  "onboardingDemoCreated": "Демо-задача создана и выключена",
  "diagTitle": "Проверка подключений",
  "diagHint": "список моделей + короткий платный запрос",
  "diagRun": "Проверить подключения",
  "diagIdle": "Проверка ещё не запускалась.",
  "diagAt": "проверено",
  "diagProvider": "Провайдер",
  "diagAuth": "Авторизация",
  "diagQuota": "Последняя квота",
  "diagCodex": "Аккаунты Codex",
  "diagKeySet": "ключ есть",
  "diagKeyMissing": "ключа нет",
  "diagUp": "доступен",
  "diagDown": "недоступен",
  "diagApiOk": "API ok",
  "notifications": "Уведомления",
  "notifyLowQuota": "Низкая квота",
  "notifyScheduler": "Запуски планировщика",
  "notifyQuotaReset": "Сброс квоты",
  "notificationsHint": "Главный переключатель уведомлений; ниже — отдельные категории.",
  "dashCards": "Карточки дашборда",
  "dashCardPool": "Здоровье пула",
  "dashCardTrends": "Лимиты квот",
  "dashCardSpend": "Расход",
  "dashCardScheduler": "Планировщик",
  "dashPoolHealth": "Здоровье пула",
  "dashTotal": "Всего",
  "dashUsable": "Рабочие",
  "dashPaused": "На паузе",
  "dashErrors": "С ошибкой",
  "dashAvgFive": "Средний 5ч",
  "dashAvgWeek": "Средняя неделя",
  "dashQuotaTrends": "Лимиты квот",
  "dashLast24h": "24 часа · по часам",
  "dashLast7d": "7 дней · по дням",
  "dashTrendEmpty": "Данных пока нет",
  "dashTrendHint": "Суммарный остаток по аккаунтам Codex.",
  "dashSamplesCount": "Замеров: {n}",
  "dashOfMax": "из {n}%",
  "dashSpend": "Расход и провайдеры",
  "dashSessionSpend": "Расход сессии",
  "dashSessionTokens": "Токены сессии",
  "dashTopProviders": "Топ-3 провайдера по токенам",
  "dashProvider": "Провайдер",
  "dashTokens": "Токены",
  "dashTurns": "Ходы",
  "dashSpendShort": "Расход",
  "dashNoUsage": "Нет данных об использовании — выполните задачу в планировщике.",
  "dashScheduler": "Планировщик",
  "dashDue": "Готовы к запуску",
  "dashNextRun": "Следующий запуск",
  "dashLastRun": "Последний статус",
  "dashRunNext": "Запустить следующую",
  "dashOpenScheduler": "Открыть планировщик",
  "dashNoTasks": "Нет включённых задач.",
  "dashRunNextDone": "Запущено: {name}"
});

Object.assign(DICT.en, {
  "dashboard": "Dashboard",
  "accounts": "Accounts",
  "api": "Codex API",
  "providers": "Connections",
  "donate": "Donate",
  "settings": "Settings",
  "codex": "Codex",
  "general": "App",
  "overview": "Overview",
  "schedulerGroup": "Scheduler",
  "brandSub": "scheduler + codex",
  "codexPool": "Codex pool",
  "open": "Open",
  "weeklyLeft": "Weekly quota left: {n}%",
  "noAccountsYet": "No accounts yet.",
  "composer": "Composer Chips",
  "instances": "Codex Instances",
  "dashTitle": "Overview",
  "dashSub": "The Scheduler and the Codex pool in real time.",
  "gateway": "Gateway",
  "running": "running",
  "stopped": "stopped",
  "starting": "starting…",
  "start": "Start",
  "stop": "Stop",
  "restart": "Restart",
  "check": "Check API",
  "refresh": "Refresh",
  "sync": "Sync with gateway",
  "port": "Port",
  "reqs": "Requests/min",
  "sidecar": "engine",
  "found": "found",
  "missing": "missing",
  "poolSummary": "Account pool",
  "accountsCount": "accounts",
  "pool5h": "5h (total)",
  "poolWeek": "Week (total)",
  "blockedNow": "paused",
  "allReady": "all ready",
  "quick": "Quick actions",
  "refreshQuotas": "Refresh quotas",
  "importAuth": "Import current Codex login",
  "accountsSub": "ChatGPT account pool. Switching changes the active login and keeps a backup.",
  "importHint": "Adds an account you are already signed in to in Codex.",
  "fiveHour": "5h",
  "week": "Week",
  "resetIn": "resets in",
  "resetNow": "resetting now",
  "onceReset": "on first request",
  "reserveHourly": "5h reserve, %",
  "reserveWeekly": "Week reserve, %",
  "save": "Save",
  "makeCurrent": "Make current",
  "refreshLogin": "Refresh login",
  "refreshQuota": "Refresh quota",
  "remove": "Remove",
  "current": "current",
  "paused": "paused",
  "ready": "ready",
  "bHourly": "5-hour window exhausted",
  "bWeekly": "weekly window exhausted",
  "bHourlyReserve": "{r}% left ≤ {l}% reserve",
  "bWeeklyReserve": "{r}% left ≤ {l}% reserve",
  "bHourlyStopped": "stopped at {r}% (reserve {l}%)",
  "bWeeklyStopped": "stopped at {r}% (reserve {l}%)",
  "bHourlyExhaustedStopped": "5h quota exhausted — stopped at {r}%",
  "bWeeklyExhaustedStopped": "weekly quota exhausted — stopped at {r}%",
  "reserveExact": "The pause triggers exactly at this value. A request already in flight can leave a little less.",
  "poolPauseHourly": "All accounts are paused by the hourly reserve — resets at {time}",
  "poolPauseWeekly": "All accounts are paused by the weekly reserve — resets at {time}",
  "poolPauseMixed": "All accounts are paused — nearest reset at {time}",
  "poolPauseExhausted": "Quota exhausted — resets at {time}",
  "poolPauseLift": "Lift pause",
  "poolPauseConfirm": "Lift the reserve pause? Quota may drop to 0%.",
  "quotaAge": "quota updated",
  "quotaLive": "live gateway",
  "quotaUsage": "OpenAI usage",
  "never": "never",
  "stale": "stale",
  "history": "History",
  "historyHint": "Quota remaining across recent refreshes.",
  "apiSub": "A local OpenAI-compatible service on the pool of your Codex accounts.",
  "endpoint": "Base URL",
  "apiKey": "Key",
  "copy": "Copy",
  "copied": "Copied",
  "endpointsTitle": "Client setup",
  "checkTitle": "API check",
  "checkHint": "",
  "checkResult": "Result",
  "logFile": "Log",
  "dataDir": "Data",
  "codexRoute": "Codex integration",
  "routeApply": "Point Codex at the service",
  "routeRemove": "Remove routing",
  "routeActive": "Codex routes through this service",
  "routeInactive": "No route — the Codex app talks to OpenAI directly",
  "routeOther": "External route active: {name}",
  "catalog": "Model catalog",
  "bridge": "Composer chips",
  "bridgeOn": "Connected to the Codex app",
  "bridgeOff": "Not connected to the Codex app",
  "bridgeHint": "Codex is running without the debug port",
  "bridgeRestart": "Restart Codex with chips",
  "bridgeRestartConfirm": "Codex will close and reopen to attach the chips. Unsaved input may be lost. Continue?",
  "bridgeRestarted": "Codex relaunched",
  "apiControl": "API control",
  "startGateway": "Start service",
  "openCodex": "Open Codex",
  "launchCodex": "Launch Codex",
  "configuration": "Configuration",
  "apiKeyHint": "Use this key as the OpenAI API key in other tools.",
  "clientHint": "Any OpenAI-compatible tool can point at this service. Requests are served from the Codex accounts and are billed to your ChatGPT subscriptions.",
  "routingMode": "Routing mode",
  "manage": "Manage",
  "checkPassed": "Check passed",
  "checkFailed": "Check failed",
  "checkFailedHint": "The check failed. Make sure the service is running and try again.",
  "accountSwitched": "Account switched",
  "routeApplied": "Codex routing is on",
  "accountAdded": "Account added",
  "accountUpdated": "Account updated",
  "instanceLaunched": "Instance launched",
  "launchingCodex": "Launching Codex…",
  "launchNoteOn": "Routing is on — Codex requests are served from the account pool.",
  "launchNoteOff": "The launch connects the Codex app to this service (the previous connection is backed up) and reopens the app with the current routing.",
  "routeActiveShort": "Codex routes through this service.",
  "routeNoneShort": "No route set.",
  "routeOtherShort": "External route: {name}.",
  "technicalDetails": "Details",
  "serviceAddress": "Service URL",
  "serviceKey": "Access key",
  "appManagement": "Codex app",
  "appManagementSub": "Path to ChatGPT.exe for launching and composer chips.",
  "appFound": "App found",
  "appNotFound": "App not found",
  "appRunning": "running",
  "appNotRunning": "not running",
  "chooseAppPath": "Choose ChatGPT.exe",
  "chooseAppPathTitle": "Choose ChatGPT.exe",
  "changeAppPath": "Change path",
  "forgetAppPath": "Reset path",
  "appPathSaved": "App path saved",
  "appPathForgotten": "The app is found automatically",
  "appPathStale": "Path is outdated",
  "codexNotFoundTitle": "Codex app not found",
  "codexNotFoundBody": "Melon Tools could not find ChatGPT.exe. Choose the app — everything else starts automatically.",
  "codexPathInvalidTitle": "Could not open the app",
  "codexPathInvalidBody": "The selected file does not look like ChatGPT.exe. Choose the file again.",
  "codexLaunchFailedTitle": "Codex did not start",
  "codexLaunchFailedBody": "Close Codex manually and try again. If the app is installed in a protected folder, confirm the administrator prompt.",
  "codexServiceFailedTitle": "The service did not start",
  "codexServiceFailedBody": "Check the port in Settings and try again.",
  "codexRouteFailedTitle": "Could not connect Codex",
  "codexRouteFailedBody": "Check that the Codex folder is available and try again.",
  "downloadCodex": "Download Codex",
  "retry": "Retry",
  "cancel": "Cancel",
  "choose": "Choose",
  "codexOpened": "Codex opened",
  "codexPathTechnical": "Path",
  "codexSourceTechnical": "Source",
  "codexDebugPort": "Chips port",
  "codexSourceManual": "selected manually",
  "codexSourceAuto": "found automatically",
  "codexSourceStore": "Store version",
  "codexSourceEnvironment": "environment variable",
  "codexHint": "If the app is installed from the Microsoft Store, no path is needed — Melon Tools finds it automatically.",
  "providersSub": "Codex models: the account pool and connected providers",
  "openrouter": "OpenRouter",
  "orKey": "OpenRouter key",
  "totalCredits": "Purchased",
  "spend": "Spent",
  "remaining": "Remaining",
  "available": "available",
  "balance": "Balance",
  "lifetime": "Lifetime",
  "keyLimit": "Key limit",
  "keyRemaining": "Key limit remaining",
  "keySpend": "Key usage",
  "opencode": "OpenCode",
  "ocKey": "OpenCode key (oc_sk_…)",
  "ocHint": "After saving keys restart the gateway — opencode/* and openrouter/* models appear in the list.",
  "deepinfra": "DeepInfra",
  "diKey": "DeepInfra key",
  "loadModels": "Load models",
  "diHint": "Chat models only. DeepInfra has no key balance endpoint: the card shows the model count and session spend. Restart the gateway after loading.",
  "vercel": "Vercel",
  "vcKey": "Vercel AI Gateway key",
  "vcHint": "Use a Vercel AI Gateway key (AI_GATEWAY_API_KEY), not a personal Vercel token. Balance and spend are shared by the team. Restart the gateway after loading.",
  "sessionSpend": "Session spend",
  "teamBalance": "Team balance",
  "lifetimeSpend": "Lifetime spend",
  "keyConfigured": "key set",
  "noKey": "no key",
  "keyRequired": "Set the key first",
  "modelsAvailable": "Models available",
  "claude": "Claude",
  "claudeSub": "Anthropic Claude: subscription sign-in via OAuth, optional API key.",
  "claudeConnect": "Connect",
  "claudeConnecting": "Waiting for confirmation…",
  "claudeCancel": "Cancel",
  "claudeDisconnect": "Disconnect",
  "claudeConnected": "connected",
  "claudeNotConnected": "not connected",
  "claudeLoginError": "Claude sign-in failed",
  "claudeKey": "Anthropic API key (fallback)",
  "claudeHint": "OAuth — the Claude subscription (primary). API key — pay-as-you-go fallback: the gateway config gains the block only when the toggle is on and the key is non-empty.",
  "claudeDisconnected": "Claude disconnected",
  "confirmClaudeDisconnect": "Disconnect Claude? The account is removed from the gateway.",
  "antigravity": "Antigravity",
  "antigravitySub": "Google account (Antigravity) via OAuth.",
  "antigravityConnect": "Connect",
  "antigravityConnecting": "Waiting for confirmation…",
  "antigravityCancel": "Cancel",
  "antigravityDisconnect": "Disconnect",
  "antigravityConnected": "connected",
  "antigravityNotConnected": "not connected",
  "antigravityLoginError": "Antigravity sign-in failed",
  "antigravityHint": "Sign in with the Antigravity Google account (OAuth only). No quota display — the API provides none.",
  "antigravityDisconnected": "Antigravity disconnected",
  "confirmAntigravityDisconnect": "Disconnect Antigravity? The account is removed from the gateway.",
  "loginTimeout": "Sign-in was not confirmed within 10 minutes — try again",
  "projectId": "Project",
  "settingsSub": "Appearance, language, service and quotas.",
  "language": "Language",
  "quotaInterval": "Quota refresh",
  "apply": "Apply",
  "about": "About",
  "version": "Version",
  "platform": "Platform",
  "appearance": "Appearance",
  "serviceSettings": "Service settings",
  "dashboardWidgets": "Dashboard widgets",
  "accent": "Accent",
  "goldenMelon": "golden melon",
  "showPoolHealth": "Show pool health",
  "showQuotaTrends": "Show quota limits",
  "showSpend": "Show spend & top providers",
  "showScheduler": "Show scheduler summary",
  "settingsPort": "Service port",
  "settingsPortHint": "Change it only when another program occupies the port.",
  "minutesShort": "{n} min",
  "off": "Off",
  "oneMin": "1 min",
  "fiveMin": "5 min",
  "fifteenMin": "15 min",
  "thirtyMin": "30 min",
  "aboutSub": "A personal console for the Scheduler and the Codex account pool.",
  "codexHome": "Codex home",
  "backupCard": "Backup",
  "backupCardSub": "An encrypted copy of the scheduler, settings, accounts and auth files, plus model sources. Logs and gateway keys are not included. The password is not stored.",
  "backupPassword": "Password",
  "backupExport": "Export",
  "backupImport": "Import",
  "backupLast": "Last backup",
  "backupNone": "No backup yet",
  "backupPasswordRequired": "Enter a password",
  "backupExported": "Backup saved: {path} ({bytes} bytes)",
  "backupImportConfirm": "Import the backup? Scheduler tasks, settings, accounts and auth files will be replaced by the backup contents.",
  "backupImported": "Imported: {tasks} tasks, {accounts} accounts, {auths} auth files, {settings} settings",
  "backupImportModels": " · model sources included",
  "backupImportRestartFailed": "Import finished, but the gateway did not restart — start the API service manually",
  "donateSub": "Support Melon Tools with a USDT (TRC20) transfer",
  "donateAddress": "Wallet address",
  "copyAddress": "Copy address",
  "donateThanks": "Thank you for supporting Melon Tools! 🍉",
  "donateNote": "TRON network (TRC20). Thanks for the support! 🍉",
  "warnNoAccounts": "The pool is empty — import the current Codex login or copy the vault from the macOS app.",
  "loading": "Loading…",
  "error": "Error",
  "done": "Done",
  "confirmDelete": "Remove {name} from the pool?",
  "confirmDeleteInstance": "Delete instance {name}?",
  "okPill": "ready",
  "autoRefresh": "quota auto-refresh",
  "addAccount": "Add account",
  "addAccountHint": "Device code: a page opens, enter the code.",
  "deviceCode": "Code",
  "deviceWaiting": "Waiting for confirmation…",
  "deviceOpen": "Open the sign-in page",
  "deviceTimeout": "The sign-in code expired — start again",
  "subscription": "Subscription",
  "until": "until",
  "resetsAvailable": "5h resets",
  "resetsNone": "none",
  "accountModels": "Models on this account",
  "accountSettings": "Account settings",
  "availableShort": "yes",
  "unavailableShort": "no",
  "routing": "Routing",
  "accountRouting": "Account routing",
  "strategy": "Strategy",
  "strategyAuto": "Auto (recommended)",
  "strategyQuotaHigh": "Most quota left first",
  "strategyQuotaLow": "Least quota left first",
  "strategyPlanHigh": "Top plan first",
  "strategyPlanLow": "Lower plan first",
  "strategyExpiry": "Expiring soon first",
  "strategyCustom": "Manual order",
  "orderUp": "Up",
  "orderDown": "Down",
  "resetOrder": "Reset order",
  "strategyHintAuto": "The “always first” account leads; then the one with the most quota left. Backups go last.",
  "strategyHintQuotaHigh": "The account with the most quota left is used first.",
  "strategyHintQuotaLow": "The account with the least quota left is used first — it drains before switching.",
  "strategyHintPlanHigh": "Higher-tier subscriptions are used first.",
  "strategyHintPlanLow": "Lower-tier subscriptions are used first.",
  "strategyHintExpiry": "The account whose subscription ends soonest is used first.",
  "strategyHintCustom": "Order is set with the arrows; limits and the backup role still apply.",
  "applyRouting": "Apply routing",
  "accountsInPool": "{n} accounts in the pool",
  "orderCustom": "Manual order enabled — the gateway follows the card list",
  "preferred": "Preferred",
  "backup": "Backup",
  "recentCalls": "Recent calls",
  "noCalls": "empty for now",
  "scheduler": "Scheduler",
  "schedulerSub": "Scheduled tasks: cron, intervals and templates. They run while Melon Tools is in the tray.",
  "schedulerAdd": "Add task",
  "schedulerAddTitle": "New task",
  "schedulerEditTitle": "Edit task",
  "schedulerName": "Name",
  "schedulerPrompt": "Prompt",
  "schedulerModel": "Model",
  "schedulerEffort": "Reasoning effort",
  "schedulerEffortDefault": "default",
  "schedulerInterval": "Interval, min",
  "schedulerEnabled": "Enabled",
  "schedulerRunNow": "Run now",
  "schedulerNext": "Next run",
  "schedulerLast": "Last run",
  "schedulerStatus": "Status",
  "schedulerResult": "Result",
  "schedulerNoResult": "No results yet",
  "schedulerEmpty": "No tasks yet — add the first one.",
  "schedulerDelete": "Delete",
  "schedulerEdit": "Edit",
  "schedulerRequired": "Fill in the name, prompt and model",
  "confirmDeleteTask": "Delete task {name}?",
  "schedulerEvery": "every {n} min",
  "schedulerDue": "due",
  "schedulerRunning": "running…",
  "schedulerOk": "ok",
  "schedulerError": "error",
  "schedulerNever": "never ran",
  "schedulerHistory": "History",
  "schedulerFile": "File",
  "schedulerClose": "Close",
  "schedulerModelHint": "Gateway models from /v1/models.",
  "schedulerModelsFailed": "Model list unavailable — start the gateway and refresh.",
  "schedulerGatewayOff": "The gateway is not reachable — there is nowhere to run tasks. Start the API service and retry.",
  "schedulerTokens": "tokens",
  "schedulerDuration": "time",
  "schedulerMinutesShort": "{n} min",
  "schedulerTemplate": "Template",
  "schedulerTemplateNone": "No template",
  "schedulerFromTemplate": "From template",
  "schedulerWorkingDirectory": "Working directory (optional)",
  "schedulerGitContext": "Append git status, log and diff to the prompt",
  "schedulerMaxTokens": "Max tokens (0 = default)",
  "schedulerRetries": "Retries",
  "schedulerRetryDelay": "Retry delay, min",
  "schedulerScheduleType": "Schedule type",
  "schedulerScheduleInterval": "Interval",
  "schedulerScheduleCron": "Cron",
  "schedulerCron": "Cron expression",
  "schedulerCronHint": "Minute hour day month weekday",
  "schedulerCronExamples": "*/15 * * * * · 0 9 * * 1-5 · 0 */6 * * * · 0 0 1 * *",
  "schedulerCronInvalid": "Check the cron expression: 5 fields are required",
  "schedulerTimeZone": "Time zone",
  "schedulerZoneSystem": "System",
  "schedulerVariables": "Variables",
  "schedulerVariableRequired": "Fill in the template variables",
  "schedulerTrayHint": "Close the window — Melon Tools stays in the tray and keeps running tasks.",
  "schedulerRepo": "Repository",
  "schedulerBranch": "Branch",
  "schedulerPath": "Path",
  "schedulerTplMorning": "Morning digest",
  "schedulerTplMorningDesc": "Recent changes and open work, every weekday morning.",
  "schedulerTplPR": "PR review",
  "schedulerTplPRDesc": "Open pull requests, checks and risky changes before the end of the workday.",
  "schedulerTplWeekly": "Weekly repo summary",
  "schedulerTplWeeklyDesc": "Merged work, active branches and open risks for the week.",
  "schedulerTplLogs": "Log check",
  "schedulerTplLogsDesc": "Scan recent logs for errors and warnings every six hours.",
  "schedulerTplSpend": "Daily spend report",
  "schedulerTplSpendDesc": "Token spend, expensive models and unusual spikes for the day.",
  "schedulerQueued": "queued",
  "schedulerQueuedCount": "queued: {n}",
  "schedulerRunQueued": "{name} — queued, it runs after the current one",
  "schedulerCancelCurrent": "Cancel current",
  "schedulerCancelling": "cancelling…",
  "schedulerCancelDone": "Cancel requested — the queue is cleared",
  "schedulerCancelIdle": "No active runs",
  "schedulerCancelled": "cancelled",
  "schedulerSkipped": "skipped",
  "schedulerDailyTokenLimit": "Daily token limit (0 = no limit)",
  "schedulerDailyLimit": "Daily token limit",
  "schedulerDailyLimitNone": "no limit",
  "schedulerDailyLimitInvalid": "Daily token limit: 0 or 1 to 1,000,000",
  "sgGateway": "Gateway",
  "sgClaude": "Claude",
  "sgOpenCode": "OpenCode",
  "sgOpenRouter": "OpenRouter",
  "sgDeepInfra": "DeepInfra",
  "sgVercel": "Vercel",
  "instancesLabel": "Instances",
  "instanceNew": "New instance name",
  "instanceCreate": "Create",
  "instanceLaunch": "Launch Codex",
  "instanceBind": "Account",
  "instanceNone": "current login",
  "instanceDelete": "Delete",
  "instanceHint": "A separate CODEX_HOME with its own login.",
  "instancesSub": "Parallel Codex CLI sessions — each with its own login and account.",
  "instancesEmpty": "No instances",
  "instancesEmptyHint": "Create an instance to run a Codex CLI session under a specific account.",
  "composerLabel": "Composer",
  "composerHint": "Live account pool chips in the Codex input row.",
  "connected": "Connected",
  "notConnected": "Not connected",
  "checkNow": "Check now",
  "howItWorks": "How it works",
  "status": "Status",
  "composerHow1": "Melon Tools shows live pool chips right inside the Codex window: accounts, 5-hour and weekly quota, and account health.",
  "composerHow2": "Data comes from Melon Tools on this computer. When Melon Tools is not running, the chips dim and keep the last values.",
  "composerHow3": "Click the Accounts chip to see the details. If the chips are missing, relaunch Codex with the button above.",
  "models": "Models",
  "modelsSearch": "Search models…",
  "modelsCount": "models",
  "sources": "Sources",
  "sourceEnabled": "enabled",
  "poolTitle": "Codex models",
  "poolSubtitle": "OpenAI models from the shared account pool. The picker shows models selected on at least one account.",
  "poolInPool": "In pool: {n} of {total}",
  "poolAccountSelected": "Selected: {n} of {total}",
  "poolAccounts": "{n} of {total} accounts",
  "poolAll": "Select all",
  "poolClear": "Clear",
  "poolCloseLabel": "Close",
  "poolAtLeastOne": "At least one model must stay selected.",
  "poolRelaunch": "Relaunch Codex to refresh the model list.",
  "poolNewOff": "New models stay off until you select them.",
  "poolUnavailable": "unavailable",
  "autostart": "Start with Windows",
  "session": "Session",
  "donateScan": "Scan the code or paste the address into any wallet that supports USDT TRC20.",
  "update": "Update",
  "updateCheck": "Check for updates",
  "updateChecking": "Checking for updates…",
  "updateAvailable": "Update {v} is available",
  "updateUpToDate": "You are up to date ({v})",
  "updateFailed": "Could not check for updates",
  "updateDownloading": "Downloading the update…",
  "updateInstalling": "Installing… the app will restart",
  "updateCancel": "Cancel",
  "updateApply": "Update",
  "onboardingTitle": "Welcome to Melon Tools",
  "onboardingWelcome": "Set up the app in three steps.",
  "onboardingStep1": "Add or import a Codex account.",
  "onboardingStep2": "Connect sources: OpenRouter, OpenCode, DeepInfra, Vercel AI Gateway, Claude, Antigravity.",
  "onboardingStep3": "Start the API service and launch Codex.",
  "onboardingDisclaimer": "Use only your own accounts. Follow provider terms — accounts can be banned for rule violations.",
  "onboardingAccounts": "Open Accounts",
  "onboardingProviders": "Open Connections",
  "onboardingDone": "Done",
  "onboardingClose": "Close",
  "onboardingHealth": "Environment health",
  "onboardingHealthSub": "Live status without sending a request.",
  "onboardingPass": "PASS",
  "onboardingWarn": "WARN",
  "onboardingFail": "FAIL",
  "onboardingGateway": "API service",
  "onboardingGatewayOn": "Gateway is running and reachable",
  "onboardingGatewayOff": "Gateway is not running",
  "onboardingAccount": "Account",
  "onboardingAccountsCount": "{n} accounts",
  "onboardingNoAccounts": "No accounts added",
  "onboardingModels": "Models",
  "onboardingModelsCount": "{n} models available",
  "onboardingNoModels": "Model catalog is empty",
  "onboardingScheduler": "Scheduler",
  "onboardingTasksCount": "{n} tasks",
  "onboardingNextRun": "Next run: {time}",
  "onboardingNoTasks": "No tasks yet",
  "onboardingBackup": "Backup",
  "onboardingBackupAt": "Last backup: {time}",
  "onboardingNoBackup": "No backup yet",
  "onboardingOpen": "Open",
  "onboardingRunHealth": "Run health check",
  "onboardingDemoTask": "Create demo task",
  "onboardingDemoName": "Demo task",
  "onboardingDemoPrompt": "Briefly describe the state of this workspace.",
  "onboardingDemoCreated": "Demo task created and disabled",
  "diagTitle": "Connection check",
  "diagHint": "model list + a small paid probe",
  "diagRun": "Check connections",
  "diagIdle": "The check has not run yet.",
  "diagAt": "checked",
  "diagProvider": "Provider",
  "diagAuth": "Auth",
  "diagQuota": "Last quota",
  "diagCodex": "Codex accounts",
  "diagKeySet": "key set",
  "diagKeyMissing": "no key",
  "diagUp": "up",
  "diagDown": "down",
  "diagApiOk": "API ok",
  "notifications": "Notifications",
  "notifyLowQuota": "Low quota",
  "notifyScheduler": "Scheduler runs",
  "notifyQuotaReset": "Quota reset",
  "notificationsHint": "Master notification switch; individual categories below.",
  "dashCards": "Dashboard cards",
  "dashCardPool": "Pool health",
  "dashCardTrends": "Quota limits",
  "dashCardSpend": "Spend",
  "dashCardScheduler": "Scheduler",
  "dashPoolHealth": "Pool health",
  "dashTotal": "Total",
  "dashUsable": "Usable",
  "dashPaused": "Paused",
  "dashErrors": "Errors",
  "dashAvgFive": "Avg 5h",
  "dashAvgWeek": "Avg week",
  "dashQuotaTrends": "Quota limits",
  "dashLast24h": "24 hours · hourly",
  "dashLast7d": "7 days · daily",
  "dashTrendEmpty": "No data yet",
  "dashTrendHint": "Total remaining across Codex accounts.",
  "dashSamplesCount": "Samples: {n}",
  "dashOfMax": "of {n}%",
  "dashSpend": "Spend & providers",
  "dashSessionSpend": "Session spend",
  "dashSessionTokens": "Session tokens",
  "dashTopProviders": "Top 3 providers by tokens",
  "dashProvider": "Provider",
  "dashTokens": "Tokens",
  "dashTurns": "Turns",
  "dashSpendShort": "Spend",
  "dashNoUsage": "No usage data — run a scheduler task.",
  "dashScheduler": "Scheduler",
  "dashDue": "Due",
  "dashNextRun": "Next run",
  "dashLastRun": "Last status",
  "dashRunNext": "Run next",
  "dashOpenScheduler": "Open scheduler",
  "dashNoTasks": "No enabled tasks.",
  "dashRunNextDone": "Started: {name}"
});

function orderingState() {
  const accounts = S.accounts || [];
  const routing = S.routing || {};
  const ids = routing.orderedIds && routing.orderedIds.length
    ? routing.orderedIds
    : accounts.map((account) => account.id);
  const byId = new Map(accounts.map((account) => [account.id, account]));
  const ordered = ids.filter((id) => byId.has(id));
  // A freshly imported account may be missing from a stale routing snapshot.
  for (const account of accounts) {
    if (!ordered.includes(account.id)) ordered.push(account.id);
  }
  return {
    accounts,
    ordered,
    byId,
    strategy: routing.strategy || "auto",
    blockedIds: new Set(routing.blockedIds || []),
  };
}

function quotaDotClass(account) {
  const hourly = account && account.hourlyRemaining;
  if (hourly === null || hourly === undefined) return "";
  if (hourly > 30) return "ok";
  if (hourly > 5) return "warn";
  return "err";
}

function priorityRow(account, index, blocked) {
  const hourly = account.hourlyRemaining;
  const weekly = account.weeklyRemaining;
  const plan = String(account.planType || "").trim();
  return `<div class="priority-row">
    <span class="priority-index">${index + 1}</span>
    <span class="dot ${blocked ? "warn" : quotaDotClass(account)}"></span>
    <span class="priority-name">${esc(account.displayName || account.email)}</span>
    ${plan ? `<span class="priority-plan">${esc(plan)}</span>` : ""}
    ${hourly !== null && hourly !== undefined ? `<span class="priority-quota">${round(hourly)}</span>` : ""}
    ${weekly !== null && weekly !== undefined ? `<span class="priority-quota">· ${round(weekly)}</span>` : ""}
    ${account.preferredFirst ? `<span class="role-badge">${t("preferred")}</span>` : ""}
    ${account.isBackup ? `<span class="role-badge">${t("backup")}</span>` : ""}
    ${blocked ? `<span class="priority-blocked">${esc(blockText(account.blockInfo))}</span>` : ""}
    <span class="spacer"></span>
    ${index === 0 ? `<span class="pill ok">${t("current")}</span>` : ""}
  </div>`;
}

function priorityList() {
  const { accounts, ordered, byId, strategy, blockedIds } = orderingState();
  if (!accounts.length) return `<div class="footnote">${t("warnNoAccounts")}</div>`;
  return `<div class="priority-list">${ordered.map((id, index) => {
    const account = byId.get(id);
    const blocked = !!account.blocked || blockedIds.has(id);
    return priorityRow(account, index, blocked);
  }).join("")}</div>`;
}

function routeInfo() {
  const route = S.route;
  if (!route || !route.provider) {
    return { cls: "", title: t("routeNoneShort"), text: t("routeInactive") };
  }
  if (route.ours) {
    return { cls: "ok", title: t("routeActiveShort"), text: t("routeActive") };
  }
  const name = route.provider;
  return { cls: "warn", title: fmt(t("routeOtherShort"), { name }), text: fmt(t("routeOther"), { name }) };
}

function codexSourceLabel(source) {
  switch (source) {
    case "manual": return t("codexSourceManual");
    case "store": return t("codexSourceStore");
    case "environment": return t("codexSourceEnvironment");
    case "path": return t("codexSourceAuto");
    default: return t("codexSourceAuto");
  }
}

function codexAppCard() {
  const app = S.codexApp;
  const found = !!(app && app.found);
  const saved = app && app.savedPath ? app.savedPath : "";
  const savedValid = !!(app && app.savedPathValid);
  const running = !!(app && app.running);
  return `
  <div class="card">
    <h2>${t("appManagement")}</h2>
    <div class="row">
      <span class="pill ${found ? "ok" : "warn"}">${found ? t("appFound") : t("appNotFound")}</span>
      ${found ? `<span class="pill">${running ? t("appRunning") : t("appNotRunning")}</span>` : ""}
      ${saved ? `<span class="pill ${savedValid ? "gold" : "warn"}">${savedValid ? t("codexSourceManual") : t("appPathStale")}</span>` : ""}
      <span class="spacer"></span>
      <button class="btn small" data-action="codexPickPath">${found ? t("changeAppPath") : t("chooseAppPath")}</button>
      ${saved ? `<button class="ghost small" data-action="codexForgetPath">${t("forgetAppPath")}</button>` : ""}
    </div>
    <div class="footnote">${t("appManagementSub")} ${t("codexHint")}</div>
    <details class="advanced">
      <summary>${t("technicalDetails")}</summary>
      <div class="advanced-body">
        <div class="found-path">${esc((app && app.path) || "—")}</div>
        <div class="footnote">
          ${t("codexSourceTechnical")}: ${esc(codexSourceLabel(app && app.source))}
          · ${t("codexDebugPort")}: ${esc((S.bridge && S.bridge.debugPort) || "—")}
        </div>
      </div>
    </details>
  </div>`;
}

function launchErrorInfo(code) {
  switch (code) {
    case "codex_not_found":
      return { title: t("codexNotFoundTitle"), body: t("codexNotFoundBody"), pick: true };
    case "codex_path_invalid":
      return { title: t("codexPathInvalidTitle"), body: t("codexPathInvalidBody"), pick: true };
    case "service_failed":
      return { title: t("codexServiceFailedTitle"), body: t("codexServiceFailedBody"), retry: true };
    case "codex_route_failed":
      return { title: t("codexRouteFailedTitle"), body: t("codexRouteFailedBody"), retry: true };
    default:
      return { title: t("codexLaunchFailedTitle"), body: t("codexLaunchFailedBody"), retry: true };
  }
}

function launchModal() {
  if (!S.launchModal) return "";
  const info = launchErrorInfo(S.launchError);
  return `
  <div class="modal">
    <div class="modal-card codex-modal-card">
      <div class="app-mark">🍉</div>
      <h2>${esc(info.title)}</h2>
      <div class="modal-sub">${esc(info.body)}</div>
      ${S.codexApp && S.codexApp.path ? `<div class="found-path" style="margin-top:14px">${esc(S.codexApp.path)}</div>` : ""}
      <div class="codex-modal-actions">
        <button class="ghost" data-action="launchClose">${t("cancel")}</button>
        ${info.pick ? `<button class="ghost" data-action="codexDownload">${t("downloadCodex")}</button>
                      <button class="btn" data-action="codexPickPath">${t("choose")}</button>` : ""}
        ${info.retry ? `<button class="ghost" data-action="codexPickPath">${t("changeAppPath")}</button>
                        <button class="btn" data-action="codexOpen">${t("retry")}</button>` : ""}
      </div>
    </div>
  </div>`;
}

function strategyOptions() {
  return [
    ["auto", "strategyAuto", "strategyHintAuto"],
    ["quotaHighFirst", "strategyQuotaHigh", "strategyHintQuotaHigh"],
    ["quotaLowFirst", "strategyQuotaLow", "strategyHintQuotaLow"],
    ["planHighFirst", "strategyPlanHigh", "strategyHintPlanHigh"],
    ["planLowFirst", "strategyPlanLow", "strategyHintPlanLow"],
    ["expirySoonFirst", "strategyExpiry", "strategyHintExpiry"],
    ["custom", "strategyCustom", "strategyHintCustom"],
  ];
}

function strategyHint(strategy) {
  const entry = strategyOptions().find(([value]) => value === strategy);
  return t(entry ? entry[2] : "strategyHintAuto");
}

function strategySelect(current) {
  return `<select id="routing-strategy" data-action="setStrategy" data-on="change">
    ${strategyOptions().map(([value, key]) => `<option value="${value}" ${current === value ? "selected" : ""}>${t(key)}</option>`).join("")}
  </select>`;
}

function miniApiCard() {
  const status = S.status || {};
  const running = !!status.running;
  const route = routeInfo();
  const routeIsMelon = !!(S.route && S.route.ours);
  const strategy = orderingState().strategy;
  return `
  <div class="card mini-api-card">
    <div class="row">
      <b style="font-size:13px">${t("apiControl")}</b>
      <span class="spacer"></span>
      <span class="pill ${running ? "ok" : ""}">${running ? t("running") : t("stopped")}</span>
    </div>
    <div class="row">
      <span class="footnote">${t("routingMode")}</span>
      <span class="spacer"></span>
      ${strategySelect(strategy)}
    </div>
    ${priorityList()}
    <div class="row mini-actions">
      <button class="btn small" data-action="codexOpen" ${S.busy.launch ? "disabled" : ""}>${routeIsMelon ? t("openCodex") : t("launchCodex")}</button>
      <button class="ghost small" data-action="go" data-id="api">${t("manage")}</button>
      <span class="spacer"></span>
    </div>
    <div class="api-route"><span class="dot ${route.cls}"></span>${esc(route.title)}</div>
  </div>`;
}

function subscriptionText(raw) {
  if (!raw) return "";
  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) return `${t("subscription")}: ${esc(raw)}`;
  const expired = date.getTime() < Date.now();
  const text = `${t("subscription")}: ${t("until")} ${date.toLocaleDateString()}`;
  return expired ? `${text} ⚠` : text;
}

function quotaBlock(title, percent, resetUnix, present) {
  const width = percent === null || percent === undefined ? 0 : Math.min(100, Math.max(0, percent));
  return `
  <div class="quota">
    <div class="top"><span class="name">${esc(title)}</span><span class="val">${round(percent)}</span></div>
    <div class="bar"><i class="${quotaTint(percent)}" style="width:${width}%"></i></div>
    <div class="bottom">
      <span>${present ? resetText(resetUnix) : t("onceReset")}</span>
    </div>
  </div>`;
}

const ACCOUNT_SETTINGS_ICON = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2.1"/><circle cx="7" cy="17" r="2.1"/></svg>';

function accountCard(account) {
  const resetsText = account.resetCreditsAvailable === null || account.resetCreditsAvailable === undefined
    ? t("resetsNone")
    : `${account.resetCreditsAvailable} ${t("available")}${account.resetCreditsNextExpiry ? " · " + resetText(account.resetCreditsNextExpiry) : ""}`;
  const models = account.modelAvailability || [];
  const modelsBlock = models.length
    ? `<details><summary class="footnote" style="cursor:pointer">${t("accountModels")} (${models.length})</summary>
         <div class="stack" style="margin-top:8px">
           ${models.map((m) => `<div class="row" style="gap:8px"><span class="pill ${m.available ? "ok" : ""}">${m.available ? t("availableShort") : t("unavailableShort")}</span><span class="mono" style="font-size:11px">${esc(m.model)}</span></div>`).join("")}
         </div>
       </details>`
    : "";
  return `
    <div class="card">
      <div class="account-head">
        <span class="email">${esc(account.email || account.displayName)}</span>
        ${account.planType ? `<span class="plan">${esc(account.planType)}</span>` : ""}
        ${account.preferredFirst ? `<span class="pill gold">${t("preferred")}</span>` : ""}
        ${account.isBackup ? `<span class="pill">${t("backup")}</span>` : ""}
        ${account.current ? `<span class="pill ok">${t("current")}</span>` : ""}
        ${account.blocked
          ? `<span class="pill warn" title="${esc(blockText(account.blockInfo))}">${t("paused")}</span>`
          : `<span class="pill ok">${t("ready")}</span>`}
        <span class="spacer"></span>
        <button class="icon-btn" title="${t("accountSettings")}" data-action="accountSettingsOpen" data-id="${esc(account.id)}">${ACCOUNT_SETTINGS_ICON}</button>
        <button class="ghost small" title="${t("orderUp")}" data-action="movePriority" data-id="${esc(account.id)}" data-value="true">↑</button>
        <button class="ghost small" title="${t("orderDown")}" data-action="movePriority" data-id="${esc(account.id)}" data-value="false">↓</button>
      </div>

      <div class="stack">
        ${quotaBlock(t("fiveHour"), account.hourlyRemaining, account.hourlyResetAt, account.hourlyWindowPresent)}
        ${quotaBlock(t("week"), account.weeklyRemaining, account.weeklyResetAt, account.weeklyWindowPresent)}
        ${historyStrip(account.id)}

        ${account.blocked ? `<div class="footnote">⏸ ${esc(blockText(account.blockInfo))}</div>` : ""}
        <div class="row">
          ${account.subscriptionActiveUntil ? `<span class="footnote">${esc(subscriptionText(account.subscriptionActiveUntil))}</span>` : ""}
          <span class="footnote">${t("resetsAvailable")}: ${esc(resetsText)}</span>
        </div>
        <div class="footnote">${t("quotaAge")}: ${esc(ageText(account.quotaUpdatedAt))} · ${t(account.quotaSource === "gateway" ? "quotaLive" : "quotaUsage")}${account.quotaError ? " · " + esc(account.quotaError) : ""}</div>
        ${modelsBlock}

        <div class="row">
          ${account.current ? "" : `<button class="btn small" data-action="switchAccount" data-id="${esc(account.id)}">${t("makeCurrent")}</button>`}
          <button class="ghost small" data-action="refreshQuota" data-id="${esc(account.id)}">${t("refreshQuota")}</button>
          <button class="ghost small" data-action="refreshLogin" data-id="${esc(account.id)}">${t("refreshLogin")}</button>
          <button class="ghost small" data-action="poolOpenAccount" data-id="${esc(account.id)}">${t("models")}</button>
          <span class="spacer"></span>
          <button class="ghost small danger" data-action="deleteAccount" data-id="${esc(account.id)}">${t("remove")}</button>
        </div>
      </div>
    </div>`;
}

function accountSettingsModal() {
  if (!S.accountSettings) return "";
  const account = (S.accounts || []).find((item) => item.id === S.accountSettings);
  if (!account) return "";
  return `
  <div class="modal">
    <div class="modal-card account-settings-card">
      <div class="row" style="align-items:flex-start">
        <div class="stack" style="gap:2px">
          <span class="stat-label">${t("accountSettings")}</span>
          <b style="font-size:15px">${esc(account.email || account.displayName)}</b>
        </div>
        <span class="spacer"></span>
        <button class="icon-btn" title="${t("cancel")}" data-action="accountSettingsClose">×</button>
      </div>
      <div class="divider"></div>
      <div class="row">
        <label class="field">${t("reserveHourly")}
          <input type="number" id="account-res-h" min="0" max="100" value="${account.hourlyReservePercent ?? ""}">
        </label>
        <label class="field">${t("reserveWeekly")}
          <input type="number" id="account-res-w" min="0" max="100" value="${account.weeklyReservePercent ?? ""}">
        </label>
      </div>
      <div class="stack" style="gap:8px">
        <label class="card-toggle"><input type="checkbox" id="account-preferred" ${account.preferredFirst ? "checked" : ""}> ${t("preferred")}</label>
        <label class="card-toggle"><input type="checkbox" id="account-backup" ${account.isBackup ? "checked" : ""}> ${t("backup")}</label>
      </div>
      <div class="footnote">${t("reserveExact")}</div>
      <div class="codex-modal-actions">
        <button class="ghost" data-action="accountSettingsClose">${t("cancel")}</button>
        <button class="ghost" data-action="accountSettingsModels" data-id="${esc(account.id)}">${t("models")}</button>
        <button class="btn" data-action="accountSettingsSave" data-id="${esc(account.id)}">${t("save")}</button>
      </div>
    </div>
  </div>`;
}

function accountsPage() {
  const { accounts, byId, ordered } = orderingState();
  const deviceLogin = S.deviceLogin;
  const cards = ordered.map((id) => accountCard(byId.get(id))).join("");

  const deviceBlock = deviceLogin && !deviceLogin.done
    ? `<div class="row">
         <span class="muted">${t("deviceCode")}:</span>
         <b class="mono" style="font-size:16px">${esc(deviceLogin.userCode)}</b>
         <button class="ghost small" data-action="copy" data-text="${esc(deviceLogin.userCode)}">${t("copy")}</button>
         <button class="btn small" data-action="deviceOpen">${t("deviceOpen")}</button>
       </div>
       <div class="footnote">${t("deviceWaiting")}</div>`
    : `<div class="row">
         <button class="ghost small" data-action="deviceStart" ${S.busy.device ? "disabled" : ""}>${t("addAccount")}</button>
         <span class="footnote">${t("addAccountHint")}</span>
       </div>`;

  return `
  ${pageHead("codex", t("accounts"), t("accountsSub"))}
  <div class="row">
    <button class="btn" data-action="importAuth">${t("importAuth")}</button>
    <button class="ghost" data-action="importJsonPick">${t("importJson")}</button>
    <input type="file" id="accounts-json-file" accept=".json,application/json" hidden data-action="importJsonFile" data-on="change">
    <button class="ghost" data-action="refreshQuotas" ${S.busy.quotas ? "disabled" : ""}>${t("refreshQuotas")}</button>
    <span class="footnote">${t("importHint")}</span>
  </div>
  <div class="card">
    <h2>${t("addAccount")}</h2>
    <div class="stack">${deviceBlock}</div>
  </div>
  ${poolPauseBanner()}
  <div class="account-grid">
    ${miniApiCard()}
    ${cards || `<div class="card"><div class="muted">${t("warnNoAccounts")}</div></div>`}
  </div>
  ${poolModal()}
  ${launchModal()}
  ${accountSettingsModal()}`;
}

function apiPage() {
  const status = S.status || {};
  const settings = S.settings || {};
  const route = routeInfo();
  const running = !!status.running;
  const app = S.codexApp || {};
  const routeIsMelon = !!(S.route && S.route.ours);
  const bridge = S.bridge;
  const base = `http://127.0.0.1:${settings.port || status.port || 18317}/v1`;
  const strategy = orderingState().strategy;

  return `
  ${pageHead("codex api", t("api"), t("apiSub"))}

  <div class="card">
    <h2>${t("apiControl")}</h2>
    <div class="stack">
      <div class="api-status">
        <span class="pill ${running ? "ok" : ""}">${running ? t("running") : t("stopped")}</span>
        <span class="pill">${t("reqs")}: ${status.requestsLastMinute ?? 0}</span>
        <span class="spacer"></span>
        ${running
          ? `<button class="ghost small" data-action="checkApi" ${S.busy.check ? "disabled" : ""}>${t("check")}</button>
             <button class="ghost small" data-action="gatewayRestart" ${S.busy.start ? "disabled" : ""}>${t("restart")}</button>
             <button class="ghost small" data-action="gatewayStop" ${S.busy.stop ? "disabled" : ""}>${t("stop")}</button>`
          : `<button class="btn small" data-action="gatewayStart" ${S.busy.start ? "disabled" : ""}>${t("startGateway")}</button>`}
      </div>

      <div class="row">
        <button class="btn" data-action="codexOpen" ${S.busy.launch ? "disabled" : ""}>
          ${S.busy.launch ? t("launchingCodex") : (routeIsMelon ? t("openCodex") : t("launchCodex"))}
        </button>
        ${routeIsMelon ? `<button class="ghost small" data-action="codexRouteRemove" ${S.busy.route ? "disabled" : ""}>${t("routeRemove")}</button>` : ""}
        <span class="api-route"><span class="dot ${route.cls}"></span>${esc(route.title)}</span>
      </div>
      <div class="api-launch-note">${esc(routeIsMelon ? t("launchNoteOn") : t("launchNoteOff"))}</div>
      ${S.checkResult
        ? `<div class="note-line ${S.checkPassed ? "ok" : "danger"}">${esc(S.checkResult)}</div>`
        : ""}
      ${S.codexAppError ? `<div class="note-line danger">${esc(S.codexAppError)}</div>` : ""}

      <div class="divider"></div>

      <div class="row">
        <b style="font-size:12px">${t("accountRouting")}</b>
        <span class="spacer"></span>
        ${strategySelect(strategy)}
      </div>
      <div class="footnote">${esc(strategyHint(strategy))}</div>
      ${priorityList()}
      <div class="row">
        ${orderingState().accounts.length > 1 ? `<button class="ghost small" data-action="resetOrder">${t("resetOrder")}</button>` : ""}
        <button class="btn small" data-action="gatewaySync" ${S.busy.sync ? "disabled" : ""}>${t("applyRouting")}</button>
        <span class="spacer"></span>
        <span class="footnote">${esc(fmt(t("accountsInPool"), { n: orderingState().accounts.length }))}</span>
      </div>
    </div>
  </div>

  ${codexAppCard()}

  <div class="card">
    <h2>${t("configuration")}</h2>
    <div class="row">
      <span class="mono" style="font-size:11px;color:var(--text2);width:130px">${t("serviceKey")}</span>
      <span class="mono" style="font-size:11px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:420px">${esc(settings.apiKey || "—")}</span>
      <button class="ghost small" data-action="copy" data-text="${esc(settings.apiKey || "")}">${t("copy")}</button>
    </div>
    <div class="footnote">${t("apiKeyHint")}</div>
  </div>

  <div class="card">
    <h2>${t("endpointsTitle")}</h2>
    <div class="row">
      <span class="mono" style="font-size:10px;color:var(--text2);width:130px">${t("serviceAddress")}</span>
      <span class="mono" style="font-size:11px">${esc(base)}</span>
      <button class="ghost small" data-action="copy" data-text="${esc(base)}">${t("copy")}</button>
    </div>
    <div class="row">
      <span class="mono" style="font-size:10px;color:var(--text2);width:130px">${t("apiKey")}</span>
      <span class="mono" style="font-size:11px">${esc(settings.apiKey || "…")}</span>
    </div>
    <div class="footnote">${t("clientHint")}</div>
    <details class="advanced">
      <summary>${t("technicalDetails")}</summary>
      <div class="advanced-body">
        <div class="footnote mono">${esc(base)}/chat/completions · /responses · /models</div>
        <div class="footnote mono">${esc(status.logPath || "—")}</div>
        <div class="footnote mono">${esc(status.dataDir || "—")}</div>
        ${bridge && bridge.reason ? `<div class="footnote mono">${esc(bridge.reason)}</div>` : ""}
        ${route.text ? `<div class="footnote">${esc(route.text)}</div>` : ""}
        ${S.checkErrorDetail ? `<div class="divider"></div><div class="footnote mono">${esc(S.checkErrorDetail)}</div>` : ""}
        ${(S.calls && S.calls.length)
          ? `<div class="divider"></div>
             <div class="footnote">${t("recentCalls")}</div>
             <table class="kv">${S.calls.map((call) => `<tr>
               <td>${esc(call.time || "")}</td>
               <td>${esc(call.method)} ${esc(call.path)} <span class="pill ${String(call.status).startsWith("2") ? "ok" : "warn"}">${esc(call.status)}</span> <span class="muted">${esc(call.duration || "")}</span></td>
             </tr>`).join("")}</table>`
          : ""}
      </div>
    </details>
  </div>
  ${launchModal()}`;
}

function settingsPage() {
  const settings = S.settings || {};
  const info = S.info || {};
  const interval = Number(settings.quotaInterval ?? 300);
  const intervalOptions = [
    [0, t("off")],
    [60, t("oneMin")],
    [300, t("fiveMin")],
    [900, t("fifteenMin")],
    [1800, t("thirtyMin")],
  ];
  return `
  ${pageHead("melon tools", t("settings"), t("settingsSub"))}

  <div class="card">
    <h2>${t("appearance")}</h2>
    <div class="row">
      <span class="setting-label">${t("language")}</span>
      <div class="segmented">
        <button class="${S.lang === "ru" ? "active" : ""}" data-action="setLanguage" data-id="ru">Русский</button>
        <button class="${S.lang === "en" ? "active" : ""}" data-action="setLanguage" data-id="en">English</button>
      </div>
    </div>
    <div class="row">
      <span class="setting-label">${t("accent")}</span>
      <span class="accent-dot"></span>
      <span class="mono" style="font-size:11px">${t("goldenMelon")}</span>
    </div>
  </div>

  <div class="card">
    <h2>${t("networkProxy")}</h2>
    <div class="stack">
      <label class="card-toggle">
        <input type="checkbox" id="set-proxy-enabled" ${settings.proxyEnabled ? "checked" : ""}>
        <span>${t("useProxy")}</span>
      </label>
      <div class="row">
        <label class="field" style="flex:1">${t("proxyUrl")}
          <input id="set-proxy-url" class="mono" placeholder="socks5h://127.0.0.1:1080" value="${esc(settings.proxyUrl || "")}">
        </label>
        <label class="field" style="flex:1">${t("proxyBypass")}
          <input id="set-proxy-bypass" class="mono" value="${esc(settings.proxyBypass || "127.0.0.1,localhost")}">
        </label>
      </div>
      <div class="footnote" style="margin:0">${t("proxyHint")}</div>
    </div>
  </div>

  <div class="card">
    <h2>${t("dashboardWidgets")}</h2>
    <div class="stack" style="gap:6px">
      <label class="card-toggle"><input type="checkbox" ${settings.dashboardShowPoolHealth !== false ? "checked" : ""} data-action="dashboardCardToggle" data-id="dashboardShowPoolHealth" data-on="change"> ${t("showPoolHealth")}</label>
      <label class="card-toggle"><input type="checkbox" ${settings.dashboardShowQuotaTrends !== false ? "checked" : ""} data-action="dashboardCardToggle" data-id="dashboardShowQuotaTrends" data-on="change"> ${t("showQuotaTrends")}</label>
      <label class="card-toggle"><input type="checkbox" ${settings.dashboardShowSpend !== false ? "checked" : ""} data-action="dashboardCardToggle" data-id="dashboardShowSpend" data-on="change"> ${t("showSpend")}</label>
      <label class="card-toggle"><input type="checkbox" ${settings.dashboardShowScheduler !== false ? "checked" : ""} data-action="dashboardCardToggle" data-id="dashboardShowScheduler" data-on="change"> ${t("showScheduler")}</label>
    </div>
  </div>

  <div class="card">
    <h2>${t("serviceSettings")}</h2>
    <div class="row">
      <span class="setting-label">${t("settingsPort")}</span>
      <input class="small" type="number" id="set-port" value="${settings.port ?? 18317}" min="1024" max="65535">
      <span class="footnote" style="margin:0">${t("settingsPortHint")}</span>
    </div>
    <div class="row">
      <span class="setting-label">${t("quotaInterval")}</span>
      <select id="set-interval">
        ${intervalOptions.map(([value, label]) => `<option value="${value}" ${interval === value ? "selected" : ""}>${esc(label)}</option>`).join("")}
      </select>
    </div>
    <div class="row">
      <label class="card-toggle">
        <input type="checkbox" ${S.autostart ? "checked" : ""} data-action="autostartToggle" data-on="change">
        <span>${t("autostart")}</span>
      </label>
      <span class="spacer"></span>
      <button class="btn small" data-action="applySettings" ${S.busy.settings ? "disabled" : ""}>${t("apply")}</button>
    </div>
  </div>

  <div class="card">
    <h2>${t("notifications")}</h2>
    <label class="card-toggle"><input type="checkbox" ${settings.notifications !== false ? "checked" : ""} data-action="notifyToggle" data-on="change"> ${t("notifications")}</label>
    <div class="stack" style="gap:6px;padding-left:20px">
      <label class="card-toggle"><input type="checkbox" ${settings.notifyLowQuota !== false ? "checked" : ""} data-action="notifyDetailToggle" data-id="notifyLowQuota" data-on="change"> ${t("notifyLowQuota")}</label>
      <label class="card-toggle"><input type="checkbox" ${settings.notifyScheduler !== false ? "checked" : ""} data-action="notifyDetailToggle" data-id="notifyScheduler" data-on="change"> ${t("notifyScheduler")}</label>
      <label class="card-toggle"><input type="checkbox" ${settings.notifyQuotaReset !== false ? "checked" : ""} data-action="notifyDetailToggle" data-id="notifyQuotaReset" data-on="change"> ${t("notifyQuotaReset")}</label>
    </div>
    <div class="footnote">${t("notificationsHint")}</div>
  </div>

  <div class="card">
    <h2>${t("backupCard")}</h2>
    <div class="stack">
      <div class="footnote" style="margin-top:0">${t("backupCardSub")}</div>
      <div class="row" style="align-items:flex-end">
        <label class="field">${t("backupPassword")}
          <input type="password" id="backup-password" autocomplete="new-password">
        </label>
        <button class="btn small" data-action="backupExport">${t("backupExport")}</button>
        <button class="ghost small" data-action="backupImportPick">${t("backupImport")}</button>
        <input type="file" id="backup-file" accept=".melon,.json,application/json" hidden data-action="backupImportFile" data-on="change">
      </div>
      <div class="footnote">${t("backupLast")}: ${S.backupLast ? esc(new Date(S.backupLast * 1000).toLocaleString()) : esc(t("backupNone"))}</div>
    </div>
  </div>

  <div class="card">
    <h2>${t("about")}</h2>
    <div class="row" style="align-items:center">
      <div class="about-mark">🍉</div>
      <div class="stack" style="gap:4px">
        <span class="mono" style="font-size:11px;font-weight:600">Melon Tools ${esc(info.version || "—")}</span>
        <span class="mono" style="font-size:10px;color:var(--text2)">${t("aboutSub")}</span>
      </div>
    </div>
    <details class="advanced">
      <summary>${t("technicalDetails")}</summary>
      <div class="advanced-body">
        <table class="kv">
          <tr><td>${t("platform")}</td><td>${esc(info.platform || "—")}</td></tr>
          <tr><td>${t("dataDir")}</td><td>${esc(info.dataDir || "—")}</td></tr>
          <tr><td>${t("codexHome")}</td><td>${esc(info.codexHome || "—")}</td></tr>
        </table>
      </div>
    </details>
  </div>`;
}

function composerPage() {
  const bridge = S.bridge;
  const attached = !!(bridge && bridge.attached);
  const reason = bridge && bridge.reason ? String(bridge.reason) : "";
  return `
  ${pageHead("codex composer", t("composer"), t("composerHint"))}

  <div class="card">
    <h2>${t("status")}</h2>
    <div class="stack">
      <div class="row">
        <span class="dot ${attached ? "ok" : "warn"}"></span>
        <b>${attached ? t("bridgeOn") : t("bridgeOff")}</b>
        <span class="spacer"></span>
        <button class="ghost small" data-action="refreshStatus" ${S.busy.refresh ? "disabled" : ""}>${t("checkNow")}</button>
        ${attached ? "" : `<button class="btn small" data-action="bridgeLaunchCodex" ${S.busy.launch ? "disabled" : ""}>${t("bridgeRestart")}</button>`}
      </div>
      ${attached ? "" : `<div class="footnote">${t("bridgeHint")}${reason ? " · " + esc(reason) : ""}</div>`}
      ${bridge && bridge.model ? `<span class="pill gold">${esc(bridge.model)}</span>` : ""}
      <details class="advanced">
        <summary>${t("technicalDetails")}</summary>
        <div class="advanced-body">
          <table class="kv">
            <tr><td>${t("port")}</td><td>${esc((bridge && bridge.debugPort) || "—")}</td></tr>
            <tr><td>${t("session")}</td><td>${esc(bridge && bridge.threadId ? bridge.threadId : "—")}</td></tr>
          </table>
        </div>
      </details>
    </div>
  </div>

  <div class="card">
    <h2>${t("howItWorks")}</h2>
    <div class="stack">
      <div class="footnote" style="margin:0">${t("composerHow1")}</div>
      <div class="footnote" style="margin:0">${t("composerHow2")}</div>
      <div class="footnote" style="margin:0">${t("composerHow3")}</div>
    </div>
  </div>
  ${launchModal()}`;
}

function instancesPage() {
  const instances = S.instancesData || [];
  const accounts = S.accounts || [];
  return `
  ${pageHead("codex", t("instances"), t("instancesSub"))}
  <div class="card">
    <h2>${t("instanceNew")}</h2>
    <div class="row">
      <input type="text" id="instance-name" placeholder="${t("instanceNew")}">
      <button class="btn small" data-action="instanceCreate">${t("instanceCreate")}</button>
      <span class="footnote" style="margin:0">${t("instanceHint")}</span>
    </div>
  </div>
  ${instances.length
    ? `<div class="account-grid">
    ${instances.map((instance) => `
      <div class="card">
        <div class="account-head">
          <span class="email">${esc(instance.name)}</span>
          <span class="pill ${instance.exists ? "ok" : "warn"}">${instance.exists ? t("found") : t("missing")}</span>
        </div>
        <div class="row">
          <label class="field">${t("instanceBind")}
            <select data-action="instanceBind" data-id="${esc(instance.id)}" data-on="change">
              <option value="">${t("instanceNone")}</option>
              ${accounts.map((a) => `<option value="${esc(a.id)}" ${instance.accountId === a.id ? "selected" : ""}>${esc(a.email || a.displayName)}</option>`).join("")}
            </select>
          </label>
          <span class="spacer"></span>
          <button class="btn small" data-action="instanceLaunch" data-id="${esc(instance.id)}">${t("instanceLaunch")}</button>
          <button class="ghost small danger" data-action="instanceDelete" data-id="${esc(instance.id)}">${t("instanceDelete")}</button>
        </div>
        <details class="advanced">
          <summary>${t("technicalDetails")}</summary>
          <div class="advanced-body"><div class="footnote mono">${esc(instance.homePath || "")}</div></div>
        </details>
      </div>`).join("")}
  </div>`
    : `<div class="card">
    <b>${t("instancesEmpty")}</b>
    <div class="footnote" style="margin:0">${t("instancesEmptyHint")}</div>
  </div>`}`;
}

// Scheduled tasks: result bodies are capped server-side (64 KiB); the viewer
// caps again so a huge answer cannot stall the DOM.

function donatePage() {
  const address = "TXtXMdkwKt2Nnxwo7ST9h4otFp3WYWjpfw";
  return `
  ${pageHead("app", t("donate"), t("donateSub"))}
  <div class="card">
    <h2>USDT · TRON (TRC20)</h2>
    <div class="donate-layout">
      <div class="donate-qr-wrap">
        <canvas id="donate-qr" width="240" height="240"></canvas>
        <div class="token-mark">₮</div>
      </div>
      <div class="donate-side">
        <span class="stat-label">${t("donateAddress")}</span>
        <span class="donate-address">${esc(address)}</span>
        <div><button class="ghost small" data-action="copy" data-text="${address}">${t("copyAddress")}</button></div>
        <div class="footnote" style="margin:0">${t("donateScan")}</div>
        <div class="donate-thanks">${t("donateThanks")}</div>
      </div>
    </div>
  </div>`;
}

function dashboardPoolCard(health) {
  const stat = (label, value, cls) => `<div class="stat ${cls || ""}">
    <span class="value">${value}</span><span class="label">${esc(label)}</span></div>`;
  const average = (label, value) => {
    const width = value === null || value === undefined ? 0 : Math.min(100, Math.max(0, value));
    return `<div class="average-cell">
      <span class="stat-label">${esc(label)}</span>
      <span class="average-value">${value === null || value === undefined ? "—" : `${Math.round(value)}%`}</span>
      <div class="bar"><i class="${quotaTint(value)}" style="width:${width}%"></i></div>
    </div>`;
  };
  return `<div class="card dash-card" data-dashboard-card="pool-health">
    <h2>${t("dashPoolHealth")}</h2>
    <div class="stat-grid">
      ${stat(t("dashTotal"), health.total, "")}
      ${stat(t("dashUsable"), health.usable, "ok")}
      ${stat(t("dashPaused"), health.paused, "warn")}
      ${stat(t("dashErrors"), health.errors, health.errors > 0 ? "danger" : "")}
    </div>
    <div class="average-grid">
      ${average(t("dashAvgFive"), health.averageHourly)}
      ${average(t("dashAvgWeek"), health.averageWeekly)}
    </div>
  </div>`;
}

function quotaTotals(accounts, field) {
  const list = Array.isArray(accounts) ? accounts : [];
  let sum = 0;
  let seen = 0;
  for (const account of list) {
    const value = finiteNumber(account && account[field]);
    if (value === null) continue;
    sum += value;
    seen += 1;
  }
  return {
    total: seen ? sum : null,
    max: list.length * 100,
    accounts: list.length,
  };
}

function quotaLimitRow(label, total, max) {
  const fraction = total === null || !max ? 0 : Math.min(1, Math.max(0, total / max));
  return `<div class="quota">
    <div class="top"><span class="name">${esc(label)}</span><span class="val">${total === null ? "—" : `${round(total)}`}</span></div>
    <div class="bar"><i class="${quotaTint(total === null ? null : fraction * 100)}" style="width:${(fraction * 100).toFixed(1)}%"></i></div>
  </div>`;
}

function dashboardTrendsCard(accounts) {
  const hourly = quotaTotals(accounts, "hourlyRemaining");
  const weekly = quotaTotals(accounts, "weeklyRemaining");
  const max = Math.max(hourly.max, weekly.max);
  return `<div class="card dash-card" data-dashboard-card="quota-trends">
    <h2>${t("dashQuotaTrends")} <span class="hint">${t("dashTrendHint")}</span></h2>
    <div class="stack" style="gap:var(--s3)">
      ${quotaLimitRow(t("fiveHour"), hourly.total, hourly.max)}
      ${quotaLimitRow(t("week"), weekly.total, weekly.max)}
      <div class="row">
        <span class="footnote" style="margin:0">${esc(fmt(t("accountsInPool"), { n: hourly.accounts }))}</span>
        <span class="spacer"></span>
        <span class="footnote" style="margin:0">${max ? esc(fmt(t("dashOfMax"), { n: Math.round(max) })) : ""}</span>
      </div>
    </div>
  </div>`;
}

function dashboardSpendCard(usage) {
  const rows = usage.rows.map((row) => `<tr>
    <td>${esc(providerName(row.provider))}</td>
    <td>${formatTokens(row.tokens)}</td>
    <td>${row.priced && row.usd !== null ? formatMoney(row.usd) : "—"}</td>
    <td>${row.turns}</td>
  </tr>`).join("");
  return `<div class="card dash-card" data-dashboard-card="spend">
    <h2>${t("dashSpend")}</h2>
    <div class="usage-totals">
      <div class="stat"><span class="value">${formatMoney(usage.sessionSpend)}</span><span class="label">${esc(t("dashSessionSpend"))}</span></div>
      <div class="stat"><span class="value">${formatTokens(usage.sessionTokens)}</span><span class="label">${esc(t("dashSessionTokens"))}</span></div>
    </div>
    ${usage.rows.length ? `<div class="usage-title">${esc(t("dashTopProviders"))}</div>
      <table class="usage">
        <thead><tr><th>${t("dashProvider")}</th><th>${t("dashTokens")}</th><th>${t("dashSpendShort")}</th><th>${t("dashTurns")}</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>` : `<div class="footnote">${t("dashNoUsage")}</div>`}
  </div>`;
}

function dashboardSchedulerCard(summary) {
  const next = summary.next;
  const last = summary.last;
  return `<div class="card dash-card" data-dashboard-card="scheduler">
    <h2>${t("dashScheduler")}</h2>
    <div class="stat-grid">
      <div class="stat ${summary.due ? "warn" : ""}"><span class="value">${summary.due}</span><span class="label">${esc(t("dashDue"))}</span></div>
      <div class="stat"><span class="value">${next ? esc(schedulerNextText(next.nextRunAt)) : "—"}</span><span class="label">${esc(t("dashNextRun"))}</span></div>
    </div>
    <div class="row">
      <span class="stat-label">${esc(t("dashLastRun"))}</span>
      ${last ? schedulerStatusPill(last) : `<span class="pill">${t("never")}</span>`}
      ${last ? `<span class="footnote" style="margin:0">${esc(last.name || "")}</span>` : ""}
      <span class="spacer"></span>
    </div>
    <div class="row dash-bottom">
      <button class="btn small" data-action="schedulerRunNext" ${next && !S.busy["sched-run-next"] ? "" : "disabled"}>${t("dashRunNext")}</button>
      <button class="ghost small" data-action="go" data-id="scheduler">${t("dashOpenScheduler")}</button>
      ${last ? `<span class="footnote" style="margin:0">${esc(ageText(last.lastRunAt))}</span>` : `<span class="footnote" style="margin:0">${t("dashNoTasks")}</span>`}
    </div>
  </div>`;
}

function dashboardCodexCard(accounts, health) {
  const rows = accounts.slice(0, 4).map((account) => `<div class="pool-row">
    <span class="dot ${quotaDotClass(account)}"></span>
    <div class="pool-text">
      <span class="pool-name">${esc(account.displayName || account.email)}</span>
      <span class="pool-plan">${esc(account.planType || "—")}</span>
    </div>
    ${account.current ? `<span class="pill ok">${t("current")}</span>` : ""}
    <span class="spacer"></span>
    <span class="pool-week">${account.weeklyRemaining === null || account.weeklyRemaining === undefined ? "—" : `${round(account.weeklyRemaining)}`}</span>
  </div>`).join("");
  const average = health.averageWeekly;
  return `<div class="card dash-card" data-dashboard-card="codex-pool">
    <h2>${t("codexPool")}</h2>
    ${accounts.length ? `<div class="pool-list">${rows}</div>` : `<div class="footnote" style="margin:0">${t("noAccountsYet")}</div>`}
    <div class="dash-bottom">
      <div class="divider"></div>
      <div class="row">
        <span class="footnote" style="margin:0">${esc(fmt(t("accountsInPool"), { n: accounts.length }))}${average === null || average === undefined ? "" : ` · ${esc(fmt(t("weeklyLeft"), { n: Math.round(average) }))}`}</span>
        <span class="spacer"></span>
        <button class="ghost small" data-action="go" data-id="accounts">${t("open")}</button>
      </div>
    </div>
  </div>`;
}

function dashboardGatewayCard(status) {
  const running = !!status.running;
  const busy = S.busy || {};
  return `<div class="card dash-card" data-dashboard-card="gateway">
    <h2>${t("api")}</h2>
    <div class="row">
      <span class="dot ${running ? "ok" : "err"}"></span>
      <b>${running ? t("running") : t("stopped")}</b>
      <span class="pill">${t("reqs")}: ${status.requestsLastMinute ?? 0}</span>
    </div>
    <div class="footnote" style="margin:0">${t("gateway")} · :${status.port || "—"} · ${t("sidecar")}: ${status.sidecarFound ? t("found") : t("missing")}</div>
    <div class="row dash-bottom">
      ${running
        ? `<button class="ghost small" data-action="gatewayStop" ${busy.stop ? "disabled" : ""}>${t("stop")}</button>`
        : `<button class="btn small" data-action="gatewayStart" ${busy.start ? "disabled" : ""}>${t("start")}</button>`}
      <button class="ghost small" data-action="checkApi" ${busy.check ? "disabled" : ""}>${t("check")}</button>
      <span class="spacer"></span>
      <button class="ghost small" data-action="go" data-id="api">${t("open")}</button>
    </div>
    ${S.checkResult ? `<div class="note-line ${S.checkPassed ? "ok" : "danger"}">${esc(S.checkResult)}</div>` : ""}
  </div>`;
}

function dashboardPage() {
  const accounts = Array.isArray(S.accounts) ? S.accounts : [];
  const status = S.status || {};
  const cards = dashboardVisibility(S.settings);
  const health = poolHealth(accounts, S.routing);
  const scheduleData = S.schedulerSummary || S.scheduler;
  const usage = usageSummary(scheduleData, S.bridge);
  const schedule = schedulerSummary(scheduleData, nowRef());

  return `
  ${pageHead("melon tools", t("dashTitle"), t("dashSub"))}
  <div class="dash-grid">
    ${cards.pool ? dashboardPoolCard(health) : ""}
    ${cards.scheduler ? dashboardSchedulerCard(schedule) : ""}
    ${cards.trends ? dashboardTrendsCard(accounts) : ""}
    ${cards.spend ? dashboardSpendCard(usage) : ""}
    ${dashboardCodexCard(accounts, health)}
    ${dashboardGatewayCard(status)}
  </div>
  ${!accounts.length ? `<div class="card"><div class="muted">${t("warnNoAccounts")}</div></div>` : ""}
  `;
}
