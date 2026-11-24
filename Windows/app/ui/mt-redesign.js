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
  updateNotifiedVersion: null,
  popup: null,
});

Object.assign(DICT.ru, {
  "dashboard": "Обзор",
  "accounts": "Аккаунты",
  "api": "API-сервис",
  "providers": "Провайдеры",
  "donate": "Донат",
  "settings": "Настройки",
  "codex": "Codex",
  "general": "Приложение",
  "overview": "Обзор",
  "schedulerGroup": "Планировщик",
  "local_ai": "Локальный ИИ",
  "brandSub": "провайдеры, агенты и маршрутизация",
  "codexPool": "Пул Codex",
  "open": "Открыть",
  "weeklyLeft": "Остаток недели: {n}%",
  "noAccountsYet": "Аккаунтов пока нет.",
  "composer": "Чипы композера",
  "instances": "Инстансы Codex",
  "dashTitle": "Обзор",
  "dashSub": "Состояние шлюза, аккаунтов и расходов в реальном времени.",
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
  "apiSub": "Локальный OpenAI-совместимый шлюз на ваших провайдерах и аккаунтах.",
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
  "rotateKey": "Сменить ключ",
  "rotateKeyHint": "Новый ключ обновляет шлюз и маршрут Codex. Перезапустите сервис, если другой клиент ещё держит старый ключ.",
  "rotateKeyConfirm": "Сгенерировать новый ключ доступа? Старый перестанет работать после перезапуска сервиса.",
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
  "nvidiaKey": "Ключ NVIDIA API",
  "nvidiaHint": "Лимит NVIDIA: 40 запросов в минуту. Список публичный, ключ проверяется при первом запросе; не все модели поддерживают чат.",
  "loadModels": "Загрузить модели",
  "diHint": "Только чат-модели. У DeepInfra нет баланса ключа: карточка показывает число моделей и расход сессии. После загрузки перезапустите шлюз.",
  "vercel": "Vercel",
  "vcKey": "Ключ Vercel AI Gateway",
  "vcHint": "Ключ Vercel AI Gateway (AI_GATEWAY_API_KEY), не личный токен Vercel. Баланс и расход — общие для команды. После загрузки перезапустите шлюз.",
  "zai": "Z.ai",
  "zaiKey": "Ключ Z.ai Coding Plan (id.secret)",
  "zaiHint": "Ключ из Personal Coding Plan → Plan Overview, не обычный API-ключ. Coding-эндпоинт: api.z.ai/api/coding/paas/v4. GLM Coding Plan разрешён только в поддерживаемых Z.ai инструментах — прямое использование через шлюз на ваш риск. После загрузки перезапустите шлюз.",
  "sgZai": "Z.ai",
  "commandcode": "CommandCode",
  "ccKey": "Ключ CommandCode (cmd_…)",
  "ccHint": "Ключ провайдера CommandCode. Модели с поддержкой /messages уходят в Anthropic-совместимый апстрим, остальные — в OpenAI-совместимый; алиасы commandcode/* одинаковы для обоих. Каталог отдаёт 95 моделей и не сообщает цены. После загрузки перезапустите шлюз.",
  "ccAnthropicModels": "Anthropic-модели",
  "sgCommandCode": "CommandCode",
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
  "goldenMelon": "циан",
  "showPoolHealth": "Показывать состояние пула",
  "showAntigravity": "Показывать состояние пула Antigravity",
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
  "allProviders": "Все провайдеры",
  "providerDetailSub": "Подключение, модели и маршрутизация этого провайдера.",
  "qosToggle": "Переключать аккаунт Antigravity, если первый токен медлит",
  "connection": "Подключение",
  "advanced": "Дополнительно",
  "standby": "ожидает",
  "noAccounts": "нет аккаунтов",
  "noBinary": "нет бинарника",
  "signedInAs": "вход выполнен как {email}",
  "autoRetry": "Продолжать автоматически после ошибки ёмкости",
  "autoRetryHint": "Нажимает Retry в Codex; если кнопка пропала, отправляет короткое продолжение.",
  "autoRetryLast": "Последнее автоматическое действие: {time}",
  "gatewayAutoStart": "Запускать сервис при старте приложения",
  "gatewayAutoStartHint": "Если выключить, локальный API не стартует сам. Запустить его можно кнопкой на странице API-сервис.",
  "browserLogin": "Вход через браузер",
  "browserLoginHint": "Откроется страница OpenAI, вход завершится сам.",
  "browserLoginWaiting": "Завершите вход в браузере",
  "browserLoginCancel": "Отменить вход",
  "browserLoginDone": "Вход выполнен",
  "browserLoginFailed": "Не удалось выполнить вход",
  "browserLoginTimeout": "Браузер не вернул код за 10 минут",
  "pasteLoginJson": "Вставить вход (JSON)",
  "pasteLoginHint": "Вставьте целиком содержимое сохранённого файла входа Codex (JSON).",
  "import": "Импортировать",
  "pasteUnavailable": "Буфер обмена недоступен",
  "pasteEmpty": "Буфер обмена пуст",
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
  "poolEnabled": "Участвует в общем пуле",
  "poolDisabled": "Выключен из пула",
  "poolEnabledHint": "Квоты продолжают обновляться. Выключенный аккаунт вернётся в маршрутизацию только после ручного включения.",
  "availableShort": "есть",
  "unavailableShort": "нет",
  "routing": "Маршрутизация",
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
  "applyRouting": "Применить маршрутизацию",
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
  "schedulerTokens": "Токены",
  "schedulerTokensUnit": "токенов",
  "schedulerDuration": "Время",
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
  "dashCardAntigravity": "Состояние пула Antigravity",
  "dashCardSpend": "Расход",
  "dashCardScheduler": "Планировщик",
  "dashProviders": "Провайдеры",
  "dashPools": "Пулы аккаунтов",
  "dashPoolHealth": "Состояние пула Codex",
  "dashTotalFive": "Общий остаток 5 ч",
  "dashTotalWeek": "Общий остаток недели",
  "dashConnected": "Подключено: {n}",
  "dashNoProviders": "Провайдеры не подключены.",
  "dashAllPools": "Всего в пулах",
  "accountsShort": "аккаунтов",
  "modelsShort": "моделей",
  "notConnected": "не подключён",
  "dashTotal": "Всего",
  "dashUsable": "Рабочие",
  "dashPaused": "На паузе",
  "dashErrors": "С ошибкой",
  "dashAvgFive": "Средний 5ч",
  "dashAvgWeek": "Средняя неделя",
  "dashAntigravityPool": "Состояние пула Antigravity",
  "dashTotalGemini": "Общий остаток Gemini 5 ч",
  "dashTotalClaude": "Общий остаток Claude / GPT 5 ч",
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
  "api": "API Service",
  "providers": "Providers",
  "donate": "Donate",
  "settings": "Settings",
  "codex": "Codex",
  "general": "App",
  "overview": "Overview",
  "schedulerGroup": "Scheduler",
  "local_ai": "Local AI",
  "brandSub": "providers, agents and routing",
  "codexPool": "Codex pool",
  "open": "Open",
  "weeklyLeft": "Weekly quota left: {n}%",
  "noAccountsYet": "No accounts yet.",
  "composer": "Composer Chips",
  "instances": "Codex Instances",
  "dashTitle": "Overview",
  "dashSub": "Gateway, accounts and spending in real time.",
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
  "apiSub": "A local OpenAI-compatible gateway on your providers and accounts.",
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
  "rotateKey": "Rotate key",
  "rotateKeyHint": "A new key updates the gateway and the Codex route. Restart the service if another client still uses the old key.",
  "rotateKeyConfirm": "Generate a new access key? The old one stops working after the service restarts.",
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
  "nvidiaKey": "NVIDIA API key",
  "nvidiaHint": "NVIDIA limit: 40 requests per minute. The list is public; the key is checked on the first request. Not all models support chat.",
  "loadModels": "Load models",
  "diHint": "Chat models only. DeepInfra has no key balance endpoint: the card shows the model count and session spend. Restart the gateway after loading.",
  "vercel": "Vercel",
  "vcKey": "Vercel AI Gateway key",
  "vcHint": "Use a Vercel AI Gateway key (AI_GATEWAY_API_KEY), not a personal Vercel token. Balance and spend are shared by the team. Restart the gateway after loading.",
  "zai": "Z.ai",
  "zaiKey": "Z.ai Coding Plan key (id.secret)",
  "zaiHint": "Use a key from Personal Coding Plan → Plan Overview, not a standard API key. Coding endpoint: api.z.ai/api/coding/paas/v4. GLM Coding Plan is limited to Z.ai's supported tools — direct gateway use is at your own risk. Restart the gateway after loading.",
  "sgZai": "Z.ai",
  "commandcode": "CommandCode",
  "ccKey": "CommandCode provider key (cmd_…)",
  "ccHint": "CommandCode provider key. Models that support /messages go to the Anthropic-compatible upstream, the rest to the OpenAI-compatible one; both publish the same commandcode/* aliases. The catalogue lists 95 models and reports no prices. Restart the gateway after loading.",
  "ccAnthropicModels": "Anthropic models",
  "sgCommandCode": "CommandCode",
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
  "goldenMelon": "cyan",
  "showPoolHealth": "Show pool health",
  "showAntigravity": "Show Antigravity pool health",
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
  "allProviders": "All providers",
  "providerDetailSub": "This provider's connection, models and routing.",
  "qosToggle": "Switch Antigravity accounts when the first token is slow",
  "connection": "Connection",
  "advanced": "Advanced",
  "standby": "standby",
  "noAccounts": "no accounts",
  "noBinary": "no binary",
  "signedInAs": "signed in as {email}",
  "autoRetry": "Auto-continue after capacity errors",
  "autoRetryHint": "Presses Codex Retry; when that control disappears, sends a short continuation.",
  "autoRetryLast": "Last automatic action: {time}",
  "gatewayAutoStart": "Start the service at app launch",
  "gatewayAutoStartHint": "When off, the local API does not start by itself. Start it from the API Service page.",
  "browserLogin": "OAuth browser login",
  "browserLoginHint": "A page opens; the login completes on its own.",
  "browserLoginWaiting": "Complete the sign-in in the browser",
  "browserLoginCancel": "Cancel login",
  "browserLoginDone": "Logged in",
  "browserLoginFailed": "Login failed",
  "browserLoginTimeout": "The browser returned no code within 10 minutes",
  "pasteLoginJson": "Paste login (JSON)",
  "pasteLoginHint": "Paste the full contents of a saved Codex login file (JSON).",
  "import": "Import",
  "pasteUnavailable": "Clipboard is unavailable",
  "pasteEmpty": "Clipboard is empty",
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
  "poolEnabled": "Participates in the shared pool",
  "poolDisabled": "Excluded from pool",
  "poolEnabledHint": "Quotas keep updating. An excluded account returns to routing only when manually enabled.",
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
  "schedulerTokens": "Tokens",
  "schedulerTokensUnit": "tokens",
  "schedulerDuration": "Time",
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
  "dashCardAntigravity": "Antigravity pool health",
  "dashCardSpend": "Spend",
  "dashCardScheduler": "Scheduler",
  "dashProviders": "Providers",
  "dashPools": "Account pools",
  "dashPoolHealth": "Codex pool health",
  "dashTotalFive": "Total left 5h",
  "dashTotalWeek": "Total left weekly",
  "dashConnected": "Connected: {n}",
  "dashNoProviders": "No providers connected yet.",
  "dashAllPools": "All pools",
  "accountsShort": "accounts",
  "modelsShort": "models",
  "notConnected": "not connected",
  "dashTotal": "Total",
  "dashUsable": "Usable",
  "dashPaused": "Paused",
  "dashErrors": "Errors",
  "dashAvgFive": "Avg 5h",
  "dashAvgWeek": "Avg week",
  "dashAntigravityPool": "Antigravity pool health",
  "dashTotalGemini": "Total left Gemini 5h",
  "dashTotalClaude": "Total left Claude / GPT 5h",
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

// Account card/sheet terminology follows the macOS CodexAccountsView.
Object.assign(DICT.ru, {
  accountSettings: "Настройки маршрута аккаунта",
  accountActive: "Активный", accountSwitch: "Переключить", accountQuota: "Квота", accountLaunch: "Запустить в Codex",
  accountHourly: "часовая", accountWeekly: "недельная", accountPreferred: "Всегда первый", accountBackup: "Резерв",
  accountHourlyReserve: "5 ч ≤ {n}%", accountWeeklyReserve: "Неделя ≤ {n}%",
  accountSubscriptionExpires: "Подписка истекает {date}", accountSubscriptionExpired: "Подписка истекла {date}", accountDays: "{n} дн.",
  accountNoResets: "Нет доступных сбросов", accountCredits: "Кредиты", accountAvailable: "доступна", accountUnavailable: "недоступна",
  accountWeeklyExhausted: "Недельная квота — 0%, поэтому 5-часовое окно недоступно",
  accountLimits: "Лимиты", accountHourlyLimit: "Лимит 5 часов", accountWeeklyLimit: "Недельный лимит",
  accountThresholdHint: "переключать, когда остаток квоты упадёт до этого процента",
  accountRecoveryHint: "Когда порог достигнут, автоматически включается следующий аккаунт, а этот вернётся после восстановления квоты.",
  accountPreferredHint: "Аккаунт «Всегда первый» идёт первым, пока не на паузе по лимитам.",
  accountBackupHint: "Резервный аккаунт используется только когда обычные аккаунты недоступны.",
  accountQueuePosition: "Позиция в очереди: №{n}", accountChooseModels: "Выбрать модели для аккаунта…",
  accountModelsHint: "По умолчанию доступны все модели из пула. Можно оставить только нужные модели для этого аккаунта.",
  accountInvalidLimit: "Укажите целый порог от 1 до 100% или выключите лимит.",
  accountSelect: "Выбрать {name}", accountSelectAll: "Выбрать все", accountClearSelection: "Снять выделение", accountSelected: "Выбрано: {n}",
  accountRefreshSelected: "Обновить выбранные", accountDeleteSelected: "Удалить выбранные",
  accountWakeSelected: "Разбудить выбранные", accountWakeSleeping: "Разбудить спящие", accountWakeSleepingN: "Разбудить спящие ({n})",
  wakeAccount: "Разбудить аккаунт", wake: "Разбудить", sleeping: "спит",
  warmup: "Прогреть", warmupAccount: "Прогреть аккаунт", warmupAll: "Прогреть все",
  accountDeleteSelectedConfirm: "Удалить выбранные аккаунты ({n}) из пула?",
});
Object.assign(DICT.en, {
  accountActive: "Active", accountSwitch: "Switch", accountQuota: "Quota", accountLaunch: "Launch in Codex",
  accountHourly: "hourly", accountWeekly: "weekly", accountPreferred: "Always first", accountBackup: "Backup",
  accountHourlyReserve: "5h reserve {n}%", accountWeeklyReserve: "weekly reserve {n}%",
  accountSubscriptionExpires: "Subscription until {date}", accountSubscriptionExpired: "Subscription expired {date}", accountDays: "{n}d",
  accountNoResets: "No resets available", accountCredits: "Credits", accountAvailable: "available", accountUnavailable: "unavailable",
  accountWeeklyExhausted: "Weekly quota is 0%, so the 5-hour window is unavailable",
  accountLimits: "Limits", accountHourlyLimit: "5-hour limit", accountWeeklyLimit: "Weekly limit",
  accountThresholdHint: "switch when quota left drops to this percent",
  accountRecoveryHint: "When the threshold is reached, the next account takes over automatically; this one returns when its quota recovers.",
  accountPreferredHint: "The “always first” account leads while it is not paused by limits.",
  accountBackupHint: "A backup account is used only when the regular accounts are unavailable.",
  accountQueuePosition: "Queue position: #{n}", accountChooseModels: "Choose models for this account…",
  accountModelsHint: "All pool models are available by default. You can keep only the models needed for this account.",
  accountInvalidLimit: "Enter a whole threshold from 1 to 100%, or turn the limit off.",
  accountSelect: "Select {name}", accountSelectAll: "Select all", accountClearSelection: "Clear selection", accountSelected: "Selected: {n}",
  accountRefreshSelected: "Refresh selected", accountDeleteSelected: "Delete selected",
  accountWakeSelected: "Wake selected", accountWakeSleeping: "Wake sleeping", accountWakeSleepingN: "Wake sleeping ({n})",
  wakeAccount: "Wake up account", wake: "Wake up", sleeping: "sleeping",
  warmup: "Warm up", warmupAccount: "Warm up account", warmupAll: "Warm up all",
  accountDeleteSelectedConfirm: "Remove the selected accounts ({n}) from the pool?",
});

// Provider detail tabs (see providerModelsSection and friends).
Object.assign(DICT.ru, {
  accountsTotal: "Всего аккаунтов", accountsInPoolLabel: "В пуле", manageAccounts: "Управлять аккаунтами",
  routingMode: "Режим маршрутизации",
  accountsOrderHint: "Порядок аккаунтов задаётся на странице «Аккаунты».",
  modelsSelected: "Моделей в пуле", providerHost: "Хост", modelsFromAccount: "Модели приходят вместе с аккаунтом: отдельного запроса у провайдера нет.",
  modelsLoadHint: "Запрос списка моделей к провайдеру с текущим ключом.",
  modelsInPool: "Моделей в пуле: {n}",
  gatewayStrategy: "Стратегия шлюза", baseUrl: "Базовый адрес", protocol: "Протокол",
  sourceIdentifier: "Идентификатор источника", enabled: "Включён", on: "Да", checkConnection: "Проверить подключение",
  applyConfig: "Применить конфигурацию",
  advancedNoteProvider: "Значения только для чтения: они выводятся из ключа и адреса провайдера.",
  advancedNoteGateway: "Адрес локального шлюза. Меняется в «Настройках» вместе с портом.",
  advancedNoteClaude: "OAuth-файлы Claude лежат в папке auth шлюза, резервный ключ записывается в config.yaml.",
  advancedNoteAntigravity: "Файлами авторизации Antigravity управляет движок, прокси привязан к каждому аккаунту.",
  codexResponsesApi: "Codex responses API",
  claudeAccountHint: "Один Claude-аккаунт на приложение: ключ выпускается при входе.",
  routeNoteCodex: "Аккаунты пула Codex маршрутизирует планировщик аккаунтов, а не группы моделей.",
  routeNoteClaude: "Claude подключается одним аккаунтом и не участвует в перестановке порядка.",
  routeNoteAntigravity: "Порядок аккаунтов Antigravity задаётся приоритетом в списке аккаунтов.",
  routeNoteOpenRouter: "OpenRouter идёт через общий шлюз и подчиняется стратегии шлюза.",
  routeNoteOpenCode: "OpenCode проксируется шлюзом: стратегия та же, что у остальных источников.",
  routeNoteCommandCode: "CommandCode проксируется шлюзом с общей стратегией.",
  routeNoteDefault: "Источник участвует в маршрутизации шлюза на общих правилах.",
  gatewayWeighted: "Взвешенный round-robin", gatewayRoundRobin: "Round-robin", gatewayFillFirst: "Заполнять по порядку",
  gatewayWeightedHint: "Распределяет запросы внутри старшего готового уровня с учётом доли каждого аккаунта.",
  gatewayRoundRobinHint: "Перебирает учётные данные по порядку, не глядя на закэшированную квоту.",
  gatewayFillFirstHint: "Держит первые готовые учётные данные, пока они не сломаются, затем переходит к следующим.",
  groupsBulletAlias: "Псевдоним группы записывается каждому провайдеру-участнику, поэтому клиент видит одно имя модели.",
  groupsBulletFailover: "Сбойный запрос уходит к другому участнику группы, а не к тому же аккаунту.",
  groupsBulletOrder: "Движок упорядочивает провайдеров по числу моделей, затем по имени.",
  groupsBulletNotBalancer: "Группа не балансировщик нагрузки: она только склеивает одинаковые модели под одним псевдонимом.",
});

Object.assign(DICT.en, {
  accountsTotal: "Total accounts", accountsInPoolLabel: "In pool", manageAccounts: "Manage accounts",
  routingMode: "Routing mode",
  accountsOrderHint: "Account order is set on the Accounts page.",
  modelsSelected: "Models in pool", providerHost: "Host", modelsFromAccount: "Models arrive with the account: this provider has no separate request.",
  modelsLoadHint: "Asks the provider for its model list with the current key.",
  modelsInPool: "Models in pool: {n}",
  gatewayStrategy: "Gateway strategy", baseUrl: "Base URL", protocol: "Protocol",
  sourceIdentifier: "Source identifier", enabled: "Enabled", on: "Yes", checkConnection: "Check connection",
  applyConfig: "Apply config",
  advancedNoteProvider: "Read-only values derived from the provider key and address.",
  advancedNoteGateway: "The local gateway address. It changes together with the port in Settings.",
  advancedNoteClaude: "Claude OAuth files live in the gateway auth folder; the fallback key is written to config.yaml.",
  advancedNoteAntigravity: "Antigravity auth files are managed by the engine; proxy binding is per account.",
  codexResponsesApi: "Codex responses API",
  claudeAccountHint: "One Claude account per app: the key is issued on sign-in.",
  routeNoteCodex: "Codex pool accounts are routed by the account planner, not by model groups.",
  routeNoteClaude: "Claude connects as a single account and takes no part in the order.",
  routeNoteAntigravity: "Antigravity account order comes from the priority in the account list.",
  routeNoteOpenRouter: "OpenRouter goes through the shared gateway and follows the gateway strategy.",
  routeNoteOpenCode: "OpenCode is proxied by the gateway, so the strategy is the same as for other sources.",
  routeNoteCommandCode: "CommandCode is proxied by the gateway with the shared strategy.",
  routeNoteDefault: "This source takes part in gateway routing under the shared rules.",
  gatewayWeighted: "Weighted round-robin", gatewayRoundRobin: "Round-robin", gatewayFillFirst: "Fill first",
  gatewayWeightedHint: "Spreads requests inside the highest ready tier, weighted by each account's share.",
  gatewayRoundRobinHint: "Rotates credentials in order, regardless of the cached quota.",
  gatewayFillFirstHint: "Uses the first ready credential until it fails, then moves to the next one.",
  groupsBulletAlias: "The group alias is written to every member provider, so the client sees one model name.",
  groupsBulletFailover: "A failed request moves to another member provider, not to the same account.",
  groupsBulletOrder: "The engine orders providers by model count, then by name.",
  groupsBulletNotBalancer: "A group is not a load balancer: it only merges identical models under one alias.",
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
    ${index === 0 && !blocked ? `<span class="pill ok">${t("current")}</span>` : ""}
    <button class="icon-btn priority-move" aria-label="${t("orderUp")}" title="${t("orderUp")}" data-action="movePriority" data-id="${esc(account.id)}" data-value="true" ${index === 0 ? "disabled" : ""}>↑</button>
    <button class="icon-btn priority-move" aria-label="${t("orderDown")}" title="${t("orderDown")}" data-action="movePriority" data-id="${esc(account.id)}" data-value="false" ${index >= (S.accounts || []).filter((item) => item.poolEnabled !== false).length - 1 ? "disabled" : ""}>↓</button>
  </div>`;
}

function priorityList() {
  const { accounts, ordered, byId, strategy, blockedIds } = orderingState();
  if (!accounts.length) return `<div class="footnote">${t("warnNoAccounts")}</div>`;
  const enabled = ordered.filter((id) => byId.get(id).poolEnabled !== false);
  return `<div class="priority-list">${enabled.map((id, index) => {
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

/// Paste-login sheet, the Windows twin of macOS `importSheet`: one textarea,
/// Cancel and Import. Nothing is read from disk here.
function pasteLoginModal() {
  if (!S.pasteLogin) return "";
  return `
  <div class="modal">
    <div class="modal-card codex-modal-card">
      <h2>${t("pasteLoginJson")}</h2>
      <div class="modal-sub">${t("pasteLoginHint")}</div>
      <textarea id="paste-login-text" class="mono" rows="10" placeholder="{ ... }" ${S.busy["import-json"] ? "disabled" : ""}>${esc(S.pasteLogin.text || "")}</textarea>
      <div class="codex-modal-actions">
        <button class="ghost" data-action="loginJsonPasteClose">${t("cancel")}</button>
        <button class="btn" data-action="loginJsonPasteImport" ${S.busy["import-json"] ? "disabled" : ""}>${t("import")}</button>
      </div>
    </div>
  </div>`;
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

/// The three engine strategies macOS exposes on the Routing screen. They are
/// kept apart from `strategyOptions`, which orders the accounts themselves.
const GATEWAY_STRATEGIES = [
  ["weighted", "gatewayWeighted", "gatewayWeightedHint"],
  ["roundRobin", "gatewayRoundRobin", "gatewayRoundRobinHint"],
  ["fillFirst", "gatewayFillFirst", "gatewayFillFirstHint"],
];

function gatewayStrategy(current) {
  return GATEWAY_STRATEGIES.some(([value]) => value === current) ? current : "weighted";
}

function gatewayStrategyPicker(current) {
  const value = gatewayStrategy(current);
  return `<div class="segmented">${GATEWAY_STRATEGIES
    .map(([id, label]) => `<button class="${value === id ? "active" : ""}" data-action="setGatewayStrategy" data-id="${id}">${esc(t(label))}</button>`)
    .join("")}</div>`;
}

function gatewayStrategyHint(current) {
  const value = gatewayStrategy(current);
  const row = GATEWAY_STRATEGIES.find(([id]) => id === value);
  return t(row[2]);
}

/// macOS keeps account routing on the Accounts screen (MiniAPICard) and the
/// engine strategy on Routing. The card shows both the routing mode picker and
/// the order the planner will actually use.
function miniApiCard() {
  const status = S.status || {};
  const running = !!status.running;
  const route = routeInfo();
  const routeIsMelon = !!(S.route && S.route.ours);
  const routing = orderingState();
  const ttl = routing.accounts.length
    ? `<div class="order-preview">${routing.ordered
        .filter((id) => routing.byId.get(id))
        .map((id, index) => {
          const account = routing.byId.get(id);
          const blocked = !!account.blocked || routing.blockedIds.has(id);
          return `<div class="row" style="gap:6px;align-items:center">
            <span class="mono" style="font-size:9px;color:var(--text2);width:12px;text-align:right">${index + 1}</span>
            <span class="dot ${blocked ? "warn" : account.hourlyWindowPresent === false ? "" : "ok"}"></span>
            <span class="mono" style="font-size:10px">${esc(account.displayName || account.email || account.id)}</span>
            ${blocked ? `<span class="pill" style="font-size:9px">${esc(t("paused"))}</span>` : ""}
          </div>`;
        }).join("")}</div>`
    : `<div class="footnote" style="margin:0">${esc(t("warnNoAccounts"))}</div>`;
  return `
  <div class="card mini-api-card">
    <div class="row">
      <b style="font-size:13px">${t("apiControl")}</b>
      <span class="spacer"></span>
      <span class="pill ${running ? "ok" : ""}">${running ? t("running") : t("stopped")}</span>
    </div>
    <div class="row">
      <span class="stat-label">${esc(t("routingMode"))}</span>
      <span class="spacer"></span>
      ${strategySelect(routing.strategy)}
    </div>
    <div class="footnote" style="margin:0">${esc(strategyHint(routing.strategy))}</div>
    ${ttl}
    <div class="row mini-actions">
      <button class="btn small" data-action="codexOpen" ${S.busy.launch ? "disabled" : ""}>${routeIsMelon ? t("openCodex") : t("launchCodex")}</button>
      <button class="ghost small" data-action="openApi">${t("manage")}</button>
      <span class="spacer"></span>
    </div>
    <div class="api-route"><span class="dot ${route.cls}"></span>${esc(route.title)}</div>
  </div>`;
}

function subscriptionText(raw) {
  if (!raw) return "";
  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) return `${t("subscription")}: ${raw}`;
  const formatted = date.toLocaleDateString(S.lang === "en" ? "en-US" : "ru-RU", { day: "numeric", month: "short", year: "numeric" });
  return fmt(t(date.getTime() < Date.now() ? "accountSubscriptionExpired" : "accountSubscriptionExpires"), { date: formatted });
}

function accountIcon(name) {
  const paths = {
    switch: '<path d="M4 7h15l-4-4M20 17H5l4 4M19 7l-4 4M5 17l4-4"/>',
    quota: '<circle cx="12" cy="12" r="9"/><path d="m12 12 4-4M6 12h1m10 0h1M12 6v1M8 8l1 1"/>',
    launch: '<rect x="4" y="4" width="16" height="16" rx="4"/><path d="M9 15l6-6m-6 0h6v6"/>',
    models: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
    trash: '<path d="M4 6h16M9 6V3h6v3M7 6l1 15h8l1-15M10 10v7m4-7v7"/>',
    reset: '<path d="M4 10a8 8 0 1 0 3-5M4 3v7h7"/>',
    calendar: '<rect x="3" y="5" width="16" height="15" rx="2"/><path d="M7 3v4m8-4v4M3 10h16m-12 4h1m4 0h1m-6 3h1"/>',
    check: '<path d="m5 12 4 4L19 6"/>',
    wake: '<path d="M12 2v3m0 14v3M4.93 4.93l2.12 2.12m9.9 9.9l2.12 2.12M2 12h3m14 0h3M4.93 19.07l2.12-2.12m9.9-9.9l2.12-2.12"/><circle cx="12" cy="12" r="4"/>',
  };
  return `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${paths[name] || ""}</svg>`;
}

function accountQueuePosition(account) {
  if (account.poolEnabled === false) return null;
  const state = orderingState();
  const ids = state.ordered.filter((id) => state.byId.get(id).poolEnabled !== false);
  const index = ids.indexOf(account.id);
  return index < 0 ? null : index + 1;
}

function accountModelSelection(account) {
  const models = (S.pool && S.pool.models) || [];
  const selected = account.selectedModels;
  const count = Array.isArray(selected)
    ? models.filter((model) => selected.includes(model.slug)).length : models.length;
  return fmt(t("poolAccountSelected"), { n: count, total: models.length });
}

function accountHistoryStrip(id) {
  const samples = (S.history || []).filter((sample) => sample && sample.key === id);
  const hourly = samples.filter((sample) => Number.isFinite(sample.hourlyLeft)).length;
  const weekly = samples.filter((sample) => Number.isFinite(sample.weeklyLeft)).length;
  if (hourly < 2 && weekly < 2) return "";
  return `<div class="spark-row account-history" title="${esc(t("historyHint"))}">
    ${hourly >= 2 ? `<span class="spark-label">${t("accountHourly")}</span>${sparkline(id, "hourlyLeft", t("accountHourly"))}` : ""}
    ${weekly >= 2 ? `<span class="spark-label">${t("accountWeekly")}</span><span class="account-weekly-spark">${sparkline(id, "weeklyLeft", t("accountWeekly"))}</span>` : ""}
  </div>`;
}

function quotaBlock(title, percent, resetUnix, present) {
  const width = percent === null || percent === undefined ? 0 : Math.min(100, Math.max(0, percent));
  return `
  <div class="quota">
    <div class="top"><span class="name">${esc(title)}</span><span class="val ${quotaTint(percent)}">${round(percent)}</span></div>
    <div class="bar"><i class="${quotaTint(percent)}" style="width:${width}%"></i></div>
    <div class="bottom">
      <span>${present ? resetText(resetUnix) : t("onceReset")}</span>
    </div>
  </div>`;
}

const ACCOUNT_SETTINGS_ICON = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2.1"/><circle cx="7" cy="17" r="2.1"/></svg>';

function accountCard(account) {
  const poolDisabled = account.poolEnabled === false;
  const position = accountQueuePosition(account);
  const selected = (S.selectedAccounts || []).includes(account.id);
  const plan = String(account.planType || "").replace(/(^|[_ -])(\w)/g, (_, space, letter) => (space ? " " : "") + letter.toUpperCase());
  const subscription = subscriptionText(account.subscriptionActiveUntil);
  const expiry = account.subscriptionActiveUntil ? new Date(account.subscriptionActiveUntil) : null;
  const days = expiry && Number.isFinite(expiry.getTime()) ? Math.floor((expiry.getTime() - Date.now()) / 86400000) : null;
  const roles = [
    account.hourlyReservePercent > 0 ? `<span class="account-role">${fmt(t("accountHourlyReserve"), { n: account.hourlyReservePercent })}</span>` : "",
    account.weeklyReservePercent > 0 ? `<span class="account-role">${fmt(t("accountWeeklyReserve"), { n: account.weeklyReservePercent })}</span>` : "",
    account.preferredFirst ? `<span class="account-role gold">${t("accountPreferred")}</span>` : "",
    account.isBackup ? `<span class="account-role gold">${t("accountBackup")}</span>` : "",
    account.blocked && !poolDisabled ? `<span class="account-role warn" title="${esc(blockText(account.blockInfo))}">${esc(blockText(account.blockInfo))}</span>` : "",
  ].join("");
  const resetCount = Number(account.resetCreditsAvailable);
  const hasResets = Number.isFinite(resetCount) && resetCount > 0;
  const resetBusy = !!S.busy["reset-" + account.id];
  const resetTitle = account.resetCreditsNextExpiry
    ? fmt(t("resetExpires"), {
        date: new Date(account.resetCreditsNextExpiry * 1000).toLocaleDateString(S.lang === "en" ? "en-US" : "ru-RU"),
      })
    : t("resetActivate");
  const resetControl = hasResets
    ? `<button class="btn small account-reset" data-action="resetActivate" data-id="${esc(account.id)}" title="${esc(resetTitle)}" ${resetBusy ? "disabled" : ""}>${accountIcon("reset")} ${esc(resetBusy ? t("resetInFlight") : resetCountLabel(resetCount))}</button>`
    : account.resetCreditsAvailable != null ? `<span class="footnote">${t("accountNoResets")}</span>` : "";
  const models = account.modelAvailability || [];
  const modelsBlock = models.length
    ? `<details class="account-models"><summary>${t("accountModels")} (${models.length})</summary>
         <div class="stack">
           ${models.map((m) => `<div class="row"><span class="dot ${m.available ? "ok" : ""}"></span><span class="mono">${esc(m.model)}</span><span class="spacer"></span><span class="footnote">${t(m.available ? "accountAvailable" : "accountUnavailable")}</span></div>`).join("")}
         </div>
       </details>`
    : "";
  return `
    <div class="card account-card codex-account-card${poolDisabled ? " account-pool-disabled" : ""}">
      <div class="account-head">
        <input class="account-select" type="checkbox" aria-label="${esc(fmt(t("accountSelect"), { name: account.displayName || account.email }))}" data-action="accountSelect" data-id="${esc(account.id)}" data-on="change" ${selected ? "checked" : ""}>
        <div class="account-identity"><span class="email">${esc(account.displayName || account.email)}</span>
          <div class="account-plan-line"><span class="plan">${esc(plan)}</span>${position ? `<span>· №${position}</span>` : ""}</div>
        </div>
        <span class="spacer"></span>
        ${account.hourlyWindowPresent === false ? `<span class="pill warn">${t("sleeping")}</span>` : ""}
        ${poolDisabled ? `<span class="pill">${t("poolDisabled")}</span>` : account.current ? `<span class="pill ok">${t("accountActive")}</span>` : ""}
        <button class="icon-btn" aria-label="${t("accountSettings")}" title="${t("accountSettings")}" data-action="accountSettingsOpen" data-id="${esc(account.id)}">${ACCOUNT_SETTINGS_ICON}</button>
      </div>
      ${roles ? `<div class="account-roles">${roles}</div>` : ""}
      ${subscription ? `<div class="account-subscription${days != null && days < 0 ? " expired" : ""}">${accountIcon("calendar")}<span>${esc(subscription)}</span>${days != null && days >= 0 ? `<span class="footnote">${fmt(t("accountDays"), { n: days })}</span>` : ""}</div>` : ""}
      <div class="stack account-quota-stack">
        ${quotaBlock(t("accountHourly"), account.hourlyRemaining, account.hourlyResetAt, account.hourlyWindowPresent)}
        ${quotaBlock(t("accountWeekly"), account.weeklyRemaining, account.weeklyResetAt, account.weeklyWindowPresent)}
        ${accountHistoryStrip(account.id)}
        <div class="row account-credits">${resetControl}${account.unlimitedCredits ? `<span class="pill ok">${t("accountCredits")}</span>` : account.creditsBalance && account.creditsBalance !== "0" ? `<span class="footnote">${t("accountCredits")}: ${esc(account.creditsBalance)}</span>` : ""}</div>
      </div>
      ${account.weeklyRemaining === 0 && account.hourlyRemaining > 0 ? `<div class="footnote account-warning">${t("accountWeeklyExhausted")}</div>` : ""}
      ${account.quotaError ? `<div class="footnote account-error">${esc(account.quotaError)}</div>` : ""}
      <div class="footnote account-updated">${t("quotaAge")} ${esc(ageText(account.quotaUpdatedAt))} · ${t(account.quotaSource === "gateway" ? "quotaLive" : "quotaUsage")}</div>
      ${modelsBlock}
      <div class="account-actions">
        ${account.current ? "" : `<button class="ghost small" data-action="switchAccount" data-id="${esc(account.id)}" ${S.busy.quotas ? "disabled" : ""}>${accountIcon("switch")}${t("accountSwitch")}</button>`}
        <button class="ghost small" data-action="refreshQuota" data-id="${esc(account.id)}" ${S.busy.quotas ? "disabled" : ""}>${accountIcon("quota")}${t("accountQuota")}</button>
        ${account.hourlyWindowPresent === false ? `<button class="ghost small" data-action="accountWake" data-id="${esc(account.id)}" ${S.busy.quotas ? "disabled" : ""} title="${t("wakeAccount")}">${accountIcon("wake")}${t("wake")}</button>` : ""}
        <button class="ghost small" data-action="launchAccountInCodex" data-id="${esc(account.id)}" ${S.busy.launch ? "disabled" : ""}>${accountIcon("launch")}${t("accountLaunch")}</button>
        <button class="ghost small account-models-button" data-action="poolOpenAccount" data-id="${esc(account.id)}" title="${esc(accountModelSelection(account))}">${accountIcon("models")}${t("models")}</button>
        <span class="spacer"></span>
        <button class="icon-btn account-delete" aria-label="${t("remove")}" title="${t("remove")}" data-action="deleteAccount" data-id="${esc(account.id)}">${accountIcon("trash")}</button>
      </div>
    </div>`;
}

function accountSettingsValues(account) {
  if (S.accountSettingsDraft && S.accountSettingsDraft.id === account.id) return S.accountSettingsDraft;
  return {
    id: account.id, poolEnabled: account.poolEnabled !== false,
    hourlyEnabled: account.hourlyReservePercent > 0, hourly: account.hourlyReservePercent || 5,
    weeklyEnabled: account.weeklyReservePercent > 0, weekly: account.weeklyReservePercent || 5,
    preferred: !!account.preferredFirst, backup: !!account.isBackup,
  };
}

function accountLimitRow(kind, title, enabled, value) {
  const suffix = kind === "hourly" ? "h" : "w";
  return `<div class="account-limit">
    <label class="card-toggle"><input type="checkbox" role="switch" id="account-res-${suffix}-enabled" data-action="accountSettingsDraftChange" data-on="change" ${enabled ? "checked" : ""}>${t(title)}</label>
    <div class="account-limit-value" ${enabled ? "" : "hidden"}>
      <div class="account-stepper"><label class="sr-only" for="account-res-${suffix}">${t(title)} (%)</label><input type="number" id="account-res-${suffix}" min="1" max="100" step="1" value="${esc(value)}" data-action="accountSettingsDraftChange" data-on="input"><span>%</span></div>
      <span class="footnote">${t("accountThresholdHint")}</span>
    </div>
  </div>`;
}

function accountSettingsModal() {
  if (!S.accountSettings) return "";
  const account = (S.accounts || []).find((item) => item.id === S.accountSettings);
  if (!account) return "";
  const draft = accountSettingsValues(account);
  const position = accountQueuePosition(account);
  const busy = !!S.busy["account-settings-" + account.id];
  return `
  <div class="modal">
    <section class="modal-card account-settings-card" role="dialog" aria-modal="true" aria-labelledby="account-settings-title">
      <h2 id="account-settings-title">${t("accountSettings")}</h2>
      <div class="account-settings-email">${esc(account.email || account.displayName)}</div>
      <fieldset ${busy ? "disabled" : ""}>
        <div class="account-settings-section">
          <label class="card-toggle"><input type="checkbox" role="switch" id="account-pool-enabled" data-action="accountSettingsDraftChange" data-on="change" ${draft.poolEnabled ? "checked" : ""}>${t("poolEnabled")}</label>
          <p class="footnote">${t("poolEnabledHint")}</p>
        </div>
        <div class="account-settings-section">
          <h3>${t("accountLimits")}</h3>
          ${accountLimitRow("hourly", "accountHourlyLimit", draft.hourlyEnabled, draft.hourly)}
          ${accountLimitRow("weekly", "accountWeeklyLimit", draft.weeklyEnabled, draft.weekly)}
          <p class="footnote">${t("accountRecoveryHint")}</p>
          <p class="footnote">${t("reserveExact")}</p>
        </div>
        <div class="divider"></div>
        <div class="account-settings-section">
          <label class="card-toggle"><input type="checkbox" role="switch" id="account-preferred" data-action="accountSettingsDraftChange" data-on="change" ${draft.preferred ? "checked" : ""}>${t("accountPreferred")}</label>
          <p class="footnote">${t("accountPreferredHint")}</p>
          <label class="card-toggle"><input type="checkbox" role="switch" id="account-backup" data-action="accountSettingsDraftChange" data-on="change" ${draft.backup ? "checked" : ""}>${t("accountBackup")}</label>
          <p class="footnote">${t("accountBackupHint")}</p>
        </div>
        <p class="footnote account-queue-position">${draft.poolEnabled && position ? fmt(t("accountQueuePosition"), { n: position }) : t("poolDisabled")}</p>
        <div class="divider"></div>
        <div class="account-settings-section">
          <div class="row account-model-settings-row"><h3>${t("models")}</h3><span class="footnote">${esc(accountModelSelection(account))}</span><span class="spacer"></span><button class="ghost small account-choose-models" data-action="accountSettingsModels" data-id="${esc(account.id)}" title="${t("accountChooseModels")}">${accountIcon("models")}${t("models")}</button></div>
          <p class="footnote">${t("accountModelsHint")}</p>
          ${account.quotaError ? `<button class="ghost small" data-action="refreshLogin" data-id="${esc(account.id)}">${t("refreshLogin")}</button>` : ""}
        </div>
      </fieldset>
      <div class="codex-modal-actions">
        <button class="ghost" data-action="accountSettingsClose" ${busy ? "disabled" : ""}>${t("cancel")}</button>
        <button class="btn" data-action="accountSettingsSave" data-id="${esc(account.id)}" ${busy ? "disabled" : ""}>${t("save")}</button>
      </div>
    </section>
  </div>`;
}

/// Providers board: one row per provider, the macOS `CodexProvidersView`
/// layout. A row opens that provider's own page; the keys and toggles live
/// there instead of all being stacked on a single screen.
const PROVIDER_ROWS = [
  { id: "codexPool", title: "Codex" },
  { id: "claude", title: "Claude" },
  { id: "antigravity", title: "Antigravity" },
  { id: "openRouter", title: "OpenRouter", key: true },
  { id: "openCode", title: "OpenCode", key: true },
  { id: "commandCode", title: "CommandCode", key: true },
  { id: "deepInfra", title: "DeepInfra", key: true },
  { id: "nvidia", title: "NVIDIA", key: true },
  { id: "vercel", title: "Vercel", key: true },
  { id: "zai", title: "Z.ai", key: true },
  { id: "localAI", title: "Local AI" },
];

/// Board row glyphs, drawn inline so the row needs no icon dependency.
const PROVIDER_GLYPHS = {
  codexPool: '<svg viewBox="0 0 24 24"><path d="M12 3 4 7v10l8 4 8-4V7l-8-4Z"/><path d="M12 3v18M4 7l8 4 8-4"/></svg>',
  claude: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="7"/><path d="M12 5v14M5 12h14"/></svg>',
  antigravity: '<svg viewBox="0 0 24 24"><path d="M12 4 4 20h16L12 4Z"/></svg>',
  openRouter: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M4 12h16M12 4v16"/></svg>',
  openCode: '<svg viewBox="0 0 24 24"><path d="M8 6 4 10l4 4M16 6l4 4-4 4"/><path d="M9 18h6"/></svg>',
  commandCode: '<svg viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="14" rx="2"/><path d="M7 10h4M7 14h8"/></svg>',
  deepInfra: '<svg viewBox="0 0 24 24"><path d="M13 3 6 13h5l-2 8 9-11h-5l2-7Z"/></svg>',
  nvidia: '<svg viewBox="0 0 24 24"><path d="M4 8h16v8H4z"/><path d="M8 12h3M14 12h3"/></svg>',
  vercel: '<svg viewBox="0 0 24 24"><path d="M12 5 21 20H3L12 5Z"/></svg>',
  zai: '<svg viewBox="0 0 24 24"><path d="M6 6h12l-12 12h12"/></svg>',
  localAI: '<svg viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="2"/><path d="M12 2v4M12 18v4M2 12h4M18 12h4"/></svg>',
};

/// Settings key and the placeholder each provider's key field shows.
const PROVIDER_KEY_FIELDS = {
  openRouter: { field: "openrouterKey", label: "orKey", placeholder: "sk-or-v1-…" },
  openCode: { field: "opencodeKey", label: "ocKey", placeholder: "oc_sk_…" },
  commandCode: { field: "commandcodeKey", label: "ccKey", placeholder: "cmd_…" },
  deepInfra: { field: "deepinfraKey", label: "diKey", placeholder: "di_…" },
  nvidia: { field: "nvidiaKey", label: "nvidiaKey", placeholder: "nvapi-…" },
  vercel: { field: "vercelKey", label: "vercelKey", placeholder: "vck_…" },
  zai: { field: "zaiKey", label: "zaiKey", placeholder: "id.secret" },
};

/// Enabled flag next to the key field. Absent means enabled, like every
/// provider toggle the gateway reads.
const PROVIDER_ENABLED_FIELDS = {
  openRouter: "openrouterEnabled",
  openCode: "opencodeEnabled",
  commandCode: "commandcodeEnabled",
  deepInfra: "deepinfraEnabled",
  nvidia: "nvidiaEnabled",
  vercel: "vercelEnabled",
  zai: "zaiEnabled",
};

function providerRouteMeta(id) {
  return PROVIDER_ROWS.find((route) => route.id === id) || null;
}

function providerKeyValue(settings, id) {
  const field = PROVIDER_KEY_FIELDS[id];
  if (!field) return "";
  return String(settings[field.field] || "").trim();
}

function providerRowSubtitle(id) {
  if (id === "codexPool") {
    const accounts = (S.accounts || []).length;
    const models = providerModelCount("codex");
    return `${accountsCountText(accounts)} · ${modelsCountText(models)}`;
  }
  if (id === "claude") {
    const claude = S.claude || {};
    if (claude.email) return fmt(t("signedInAs"), { email: claude.email });
    if (claude.connected) return t("connected");
    return `api.anthropic.com · ${modelsCountText(providerModelCount("claude"))}`;
  }
  if (id === "antigravity") {
    const pool = S.antigravity || {};
    const count = Array.isArray(pool.accounts) ? pool.accounts.length : 0;
    return `antigravity · ${accountsCountText(count)}`;
  }
  if (id === "localAI") {
    const ready = (S.localAi && Array.isArray(S.localAi.models) ? S.localAi.models : [])
      .filter((model) => model.runtimeStatus === "ready").length;
    const running = !!((S.localAi || {}).runtime || {}).running;
    return `${running ? "llama-server" : t("noBinary")} · ${ready} ${t("ready")}`;
  }
  const host = PROVIDER_HOSTS[id] || "";
  return `${host} · ${modelsCountText(providerModelCount(id))}`;
}

const PROVIDER_HOSTS = {
  openRouter: "openrouter.ai/api/v1",
  openCode: "opencode.ai",
  commandCode: "commandcode.ai",
  deepInfra: "api.deepinfra.com",
  nvidia: "integrate.api.nvidia.com",
  vercel: "ai-gateway.vercel.sh",
  zai: "api.z.ai",
  claude: "api.anthropic.com",
  antigravity: "daily-cloudcode-pa.googleapis.com",
};

/// One board row: icon, title, subtitle, badges, chevron.
function providerRow(route) {
  const settings = S.settings || {};
  const meta = providerRouteMeta(route);
  if (!meta) return "";
  let badges = "";
  if (meta.key) {
    const configured = !!providerKeyValue(settings, meta.id);
    badges += `<span class="pill ${configured ? "ok" : ""}">${configured ? t("keyConfigured") : t("noKey")}</span>`;
  }
  if (meta.id === "codexPool") {
    const running = !!(S.status && S.status.running);
    badges += `<span class="pill ${running ? "ok" : ""}">${running ? t("running") : t("stopped")}</span>`;
  }
  if (meta.id === "antigravity") {
    const connected = !!((S.antigravity || {}).connected);
    badges += `<span class="pill ${connected ? "ok" : ""}">${connected ? t("connected") : t("noAccounts")}</span>`;
  }
  if (meta.id === "localAI") {
    const running = !!((S.localAi || {}).runtime || {}).running;
    badges += `<span class="pill ${running ? "ok" : ""}">${running ? t("running") : t("standby")}</span>`;
  }
  return `<button class="provider-row" data-action="providerOpen" data-id="${meta.id}">
    <span class="provider-row-icon">${PROVIDER_GLYPHS[meta.id] || ""}</span>
    <span class="provider-row-text">
      <b>${esc(meta.title)}</b>
      <span>${esc(providerRowSubtitle(meta.id))}</span>
    </span>
    <span class="provider-row-badges">${badges}</span>
    <span class="provider-row-chevron">›</span>
  </button>`;
}

function providersBoard() {
  return `
  ${pageHead("codex", t("providers"), t("providersSub"))}
  ${poolPauseBanner()}
  <div class="card provider-board">
    ${PROVIDER_ROWS.map((route, index) => `${index ? `<div class="provider-row-sep"></div>` : ""}${providerRow(route.id)}`).join("")}
    ${(S.settings && Array.isArray(S.settings.customProviders) && S.settings.customProviders.length)
      ? S.settings.customProviders.map((source) => `<div class="provider-row-sep"></div>${customProviderRow(source)}`).join("")
      : ""}
  </div>
  <div class="row" style="gap:var(--s3)">
    <button class="btn" data-action="customProviderOpen">${t("customProviderAdd")}</button>
  </div>
  ${diagnosticsCard()}
  ${customProviderModal()}`;
}

/// Providers that are not one of the fixed keys: a row that opens the same
/// editor the Add flow uses.
function customProviderRow(source) {
  return `<button class="provider-row" data-action="customProviderOpen" data-id="${esc(source.id)}">
    <span class="provider-row-icon">${PROVIDER_GLYPHS.localAI}</span>
    <span class="provider-row-text">
      <b>${esc(source.name || source.id)}</b>
      <span>${esc(source.baseUrl || "")} · ${(source.selectedModels || []).length} ${t("modelsCount")}</span>
    </span>
    <span class="provider-row-badges"><span class="pill ${source.enabled !== false ? "ok" : ""}">${source.enabled !== false ? t("sourceEnabled") : t("off")}</span></span>
    <span class="provider-row-chevron">›</span>
  </button>`;
}

/// The provider's own page: back to the board plus the card that used to be
/// stacked on the list. `localAI` routes to the Local AI section instead.
function providerDetail(id) {
  const settings = S.settings || {};
  const meta = providerRouteMeta(id);
  if (!meta) return providersBoard();
  const back = `<div class="row"><button class="ghost small" data-action="providerBack">‹ ${esc(t("allProviders"))}</button></div>`;
  // macOS shows a chip picker for the provider's own sections. The Windows
  // cards are single-scroll, so the chips jump to the matching anchor instead
  // of hiding content behind a tab that would look empty.
  const sections = [["connection", "connection"], ["models", "models"]];
  if (["codexPool", "claude", "antigravity"].includes(id)) sections.push(["accounts", "accounts"]);
  sections.push(["routing", "routing"]);
  sections.push(["advanced", "advanced"]);
  const section = S.providerSection && sections.some((pair) => pair[0] === S.providerSection.replace(/Section$/, ""))
    ? S.providerSection.replace(/Section$/, "")
    : "connection";
  const chips = `<div class="segmented provider-chips">${sections
    .map(([key, label]) => `<button class="${section === key ? "active" : ""}" data-action="providerSection" data-id="${key}">${esc(t(label))}</button>`)
    .join("")}</div>`;
  const anchor = (key, html) => `<div data-provider-section="${key}">${html}</div>`;
  let connection = "";
  switch (id) {
    case "codexPool": connection = codexPoolCard(); break;
    case "claude": connection = claudeCard(settings); break;
    case "antigravity": connection = antigravityCard(); break;
    case "localAI": connection = localAiConnectionCard(); break;
    case "openRouter": connection = openRouterCard(settings); break;
    case "openCode": connection = openCodeCard(settings); break;
    case "commandCode": connection = commandCodeCard(settings); break;
    case "deepInfra": connection = deepInfraCard(settings); break;
    case "nvidia": connection = nvidiaCard(settings); break;
    case "vercel": connection = vercelCard(settings); break;
    case "zai": connection = zaiCard(settings); break;
    default: connection = "";
  }
  // Every chip macOS offers gets a card here: a chip that scrolls to nothing
  // reads as a broken tab, so the sections are always rendered.
  const body = `${anchor("connection", connection)}
    ${anchor("models", providerModelsSection(id, meta))}
    ${["codexPool", "claude", "antigravity"].includes(id) ? anchor("accounts", providerAccountsSection(id)) : ""}
    ${anchor("routing", providerRoutingSection(id))}
    ${anchor("advanced", providerAdvancedSection(id, meta))}`;
  return `
  ${pageHead("codex", meta.title, t("providerDetailSub"))}
  ${back}
  ${chips}
  ${poolPauseBanner()}
  ${body}
  ${customProviderModal()}`;
}

/// Providers section entry point: the board, or one provider's page.
/// The Models tab of a provider page. Codex pool keeps its tri-state model
/// list, every key-based provider shows the loaded count and a reload button,
/// and the OAuth providers say where their models come from.
function providerModelsSection(id, meta) {
  if (id === "codexPool") {
    const pool = S.pool || {};
    const total = Array.isArray(pool.models) ? pool.models.length : 0;
    const selected = Number(pool.selectedCount || 0);
    return `<div class="card"><h2>${t("models")}</h2>
      <div class="footnote">${esc(total ? fmt(t("poolInPool"), { n: selected, total }) : fmt(t("modelsInPool"), { n: selected }))}</div>
      <div class="row" style="margin-top:10px">
        ${searchField({ id: "models-search", value: S.modelsQuery, placeholder: t("modelsSearch"), action: "modelsSearch", clearAction: "modelsClearSearch" })}
        <button class="ghost small" data-action="modelsLoad">${t("loadModels")}</button>
      </div>
      <div id="provider-model-list" style="max-height:420px;overflow:auto;margin-top:10px">${providerModelRowsMarkup()}</div>
    </div>`;
  }
  const count = providerModelCount(id);
  // OAuth providers have no key and no model request of their own: their
  // catalogue arrives with the pool or the account quota.
  const oauth = ["claude", "antigravity", "localAI"].includes(id);
  return `<div class="card"><h2>${t("models")}</h2>
    <div class="stat-grid">
      <div class="stat"><span class="value">${count}</span><span class="label">${esc(t("modelsSelected"))}</span></div>
      <div class="stat"><span class="label">${esc(t("providerHost"))}</span><span class="value mono" style="font-size:11px">${esc(PROVIDER_HOSTS[id] || meta.title)}</span></div>
    </div>
    <div class="row" style="margin-top:12px">
      ${oauth
        ? `<span class="footnote" style="margin:0">${esc(t("modelsFromAccount"))}</span>`
        : `<button class="ghost small" data-action="modelsLoad">${t("loadModels")}</button>
           <span class="footnote" style="margin:0">${esc(t("modelsLoadHint"))}</span>`}
    </div>
  </div>`;
}

/// Accounts tab: the three providers that own a credential list reuse the
/// cards from the Connection tab, which already list and manage them.
function providerAccountsSection(id) {
  if (id === "codexPool") {
    const accounts = S.accounts || [];
    const connected = accounts.filter((account) => account.poolEnabled !== false).length;
    return `<div class="card"><h2>${t("accounts")}</h2>
      <div class="stat-grid">
        <div class="stat"><span class="value">${accounts.length}</span><span class="label">${esc(t("accountsTotal"))}</span></div>
        <div class="stat"><span class="value">${connected}</span><span class="label">${esc(t("accountsInPoolLabel"))}</span></div>
      </div>
      <div class="row" style="margin-top:12px">
        <button class="btn small" data-action="go" data-id="accounts">${t("manageAccounts")}</button>
        <span class="footnote" style="margin:0">${esc(t("accountsOrderHint"))}</span>
      </div>
    </div>`;
  }
  if (id === "claude") {
    const claude = S.claude || {};
    return `<div class="card"><h2>${t("accounts")}</h2>
      <div class="row">
        <span class="pill ${claude.connected ? "ok" : ""}">${claude.connected ? t("connected") : t("notConnected")}</span>
        ${claude.email ? `<span class="mono" style="font-size:11px">${esc(claude.email)}</span>` : ""}
      </div>
      <div class="row" style="margin-top:12px">
        ${claude.connected
          ? `<button class="ghost small" data-action="claudeDisconnect">${t("antigravityDisconnect")}</button>
             <button class="ghost small" data-action="claudeRefreshUsage">${t("refresh")}</button>`
          : `<button class="btn small" data-action="claudeConnect">${t("claudeConnect")}</button>`}
        <span class="footnote" style="margin:0">${esc(t("claudeAccountHint"))}</span>
      </div>
    </div>`;
  }
  const pool = S.antigravity || {};
  const accounts = Array.isArray(pool.accounts) ? pool.accounts : [];
  return `<div class="card"><h2>${t("accounts")}</h2>
    <div class="row">
      <span class="pill ${accounts.length ? "ok" : ""}">${esc(fmt(t("accountsInPool"), { n: accounts.length }))}</span>
      <span class="spacer"></span>
      <button class="btn small" data-action="antigravityConnect">${t("addGoogleAccount")}</button>
    </div>
    ${accounts.length
      ? `<div class="stack" style="margin-top:10px">${accounts.map((account) => `<div class="row">
          <span class="dot ${account.disabled ? "" : "ok"}"></span>
          <span class="mono" style="font-size:11px">${esc(account.email || account.name)}</span>
          ${account.priority ? `<span class="pill gold">P${account.priority}</span>` : ""}
        </div>`).join("")}</div>`
      : `<div class="footnote" style="margin-top:8px">${esc(t("antigravityHint"))}</div>`}
  </div>`;
}

/// Routing tab: the engine strategy is one global value, so the card states it
/// and links to the screen that owns the picker, exactly like macOS.
function providerRoutingSection(id) {
  const settings = S.settings || {};
  const strategy = settings.routingStrategy || "auto";
  const label = strategyOptions().find(([value]) => value === strategy);
  const notes = {
    codexPool: "routeNoteCodex",
    claude: "routeNoteClaude",
    antigravity: "routeNoteAntigravity",
    openRouter: "routeNoteOpenRouter",
    openCode: "routeNoteOpenCode",
    commandCode: "routeNoteCommandCode",
  };
  return `<div class="card"><h2>${t("routing")}</h2>
    <div class="row">
      <span class="stat-label">${esc(t("gatewayStrategy"))}</span>
      <b style="font-size:12px">${esc(t(label ? label[1] : "strategyAuto"))}</b>
      <span class="spacer"></span>
      <button class="ghost small" data-action="go" data-id="routing">${t("openRouting")}</button>
    </div>
    <div class="footnote" style="margin-top:8px">${esc(t(notes[id] || "routeNoteDefault"))}</div>
    ${["codexPool", "claude", "antigravity"].includes(id)
      ? `<div class="footnote">${esc(t("accountsOrderHint"))}</div>`
      : ""}
  </div>`;
}

/// Advanced tab: read-only facts about the upstream plus the two actions that
/// touch it, matching the macOS card row for row.
function providerAdvancedSection(id, meta) {
  const settings = S.settings || {};
  const custom = id.startsWith("custom:")
    ? (settings.customProviders || []).find((source) => source.id === id.replace(/^custom:/, ""))
    : null;
  const gatewayUrl = `http://127.0.0.1:${settings.port || 18317}/v1`;
  const host = PROVIDER_HOSTS[id] || "";
  const baseUrl = custom
    ? custom.baseUrl || ""
    : id === "codexPool" || id === "localAI"
      ? gatewayUrl
      : host ? `https://${host}` : "-";
  // macOS shows the protocol title from the provider catalogue; the local
  // gateway speaks the Codex responses API.
  const protocol = custom
    ? custom.protocol || "openai-chat"
    : id === "codexPool" || id === "localAI"
      ? t("codexResponsesApi")
      : id === "claude" ? "anthropic" : "openai-chat";
  const notes = {
    codexPool: "advancedNoteGateway",
    claude: "advancedNoteClaude",
    antigravity: "advancedNoteAntigravity",
  };
  return `<div class="card"><h2>${t("advanced")}</h2>
    <div class="stack" style="gap:6px">
      <div class="agent-kv"><span>${esc(t("baseUrl"))}</span><code class="mono">${esc(baseUrl)}</code></div>
      <div class="agent-kv"><span>${esc(t("protocol"))}</span><code class="mono">${esc(protocol)}</code></div>
      ${custom
        ? `<div class="agent-kv"><span>${esc(t("sourceIdentifier"))}</span><code class="mono">${esc(custom.id)}</code></div>
           <div class="agent-kv"><span>${esc(t("enabled"))}</span><code class="mono">${esc(custom.enabled !== false ? t("on") : t("off"))}</code></div>`
        : ""}
      <div class="agent-kv"><span>${esc(t("gateway"))}</span><code class="mono">${esc(gatewayUrl)}</code></div>
    </div>
    <div class="row" style="margin-top:12px">
      <button class="btn small" data-action="diagRun" ${S.busy.diag ? "disabled" : ""}>${t("checkConnection")}</button>
      <button class="ghost small" data-action="gatewaySync" ${S.busy.sync ? "disabled" : ""}>${t("applyConfig")}</button>
      <span class="spacer"></span>
    </div>
    <div class="footnote" style="margin-top:8px">${esc(t(notes[id] || "advancedNoteProvider"))}</div>
  </div>`;
}

function providersPage() {
  if (S.providerRoute) return providerDetail(S.providerRoute);
  return providersBoard();
}

function accountsPage() {
  const { accounts, byId, ordered } = orderingState();
  const deviceLogin = S.deviceLogin;
  const browserLogin = S.browserLogin;
  const cards = ordered.map((id) => accountCard(byId.get(id))).join("");
  const selected = (S.selectedAccounts || []).filter((id) => byId.has(id));
  const allSelected = accounts.length > 0 && selected.length === accounts.length;
  const sleeping = accounts.filter((account) => account.hourlyWindowPresent === false);

  // Browser OAuth runs on its own: while it waits the device form is hidden,
  // so the user sees one pending login instead of two competing ones.
  const browserBlock = browserLogin
    ? `<div class="row">
         <span class="pill gold">${t("browserLogin")}</span>
         <span class="footnote" style="margin:0">${t("browserLoginWaiting")}</span>
         <span class="spacer"></span>
         <button class="ghost small danger" data-action="browserLoginCancel">${t("browserLoginCancel")}</button>
       </div>`
    : "";

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
    <button class="btn" data-action="browserLoginStart" ${browserLogin || S.busy["browser-login"] ? "disabled" : ""}>${t("browserLogin")}</button>
    <button class="ghost" data-action="importAuth">${t("importAuth")}</button>
    <button class="ghost" data-action="loginJsonPaste">${t("pasteLoginJson")}</button>
    <button class="ghost" data-action="importJsonPick">${t("importJson")}</button>
    <input type="file" id="accounts-json-file" accept=".json,application/json" hidden data-action="importJsonFile" data-on="change">
    ${sleeping.length ? `<button class="ghost" data-action="accountsWakeSleeping" ${S.busy.quotas ? "disabled" : ""}>${fmt(t("accountWakeSleepingN"), { n: sleeping.length })}</button>` : ""}
    <button class="ghost" data-action="refreshQuotas" ${S.busy.quotas ? "disabled" : ""}>${t("refreshQuotas")}</button>
    <span class="footnote">${t("importHint")}</span>
  </div>
  <div class="card">
    <h2>${t("addAccount")}</h2>
    <div class="stack">${browserBlock}${deviceBlock}</div>
  </div>
  ${poolPauseBanner()}
  ${accounts.length ? `<div class="row account-selection-bar">
    <label><input type="checkbox" data-action="accountsSelectAll" data-on="change" ${allSelected ? "checked" : ""}>${t(allSelected ? "accountClearSelection" : "accountSelectAll")}</label>
    <span class="footnote">${fmt(t("accountSelected"), { n: selected.length })}</span><span class="spacer"></span>
    <button class="ghost small" data-action="accountsRefreshSelected" ${!selected.length || S.busy.quotas ? "disabled" : ""}>${t("accountRefreshSelected")}</button>
    <button class="ghost small" data-action="accountsWakeSelected" ${!selected.length || S.busy.quotas ? "disabled" : ""}>${t("accountWakeSelected")}</button>
    ${sleeping.length ? `<button class="ghost small" data-action="accountsWakeSleeping" ${S.busy.quotas ? "disabled" : ""}>${fmt(t("accountWakeSleepingN"), { n: sleeping.length })}</button>` : ""}
    <button class="ghost small danger" data-action="accountsDeleteSelected" ${!selected.length || S.busy["accounts-delete"] ? "disabled" : ""}>${t("accountDeleteSelected")}</button>
  </div>` : ""}
  <div class="account-grid">
    ${miniApiCard()}
    ${cards || `<div class="card"><div class="muted">${t("warnNoAccounts")}</div></div>`}
  </div>
  ${poolModal()}
  ${pasteLoginModal()}
  ${launchModal()}
  ${accountSettingsModal()}`;
}

function formatUsageDate(iso) {
  if (!iso) return "-";
  try {
    const d = new Date(iso);
    return isNaN(d.getTime()) ? iso : d.toLocaleString(S.lang === "en" ? "en-US" : "ru-RU");
  } catch (e) {
    return iso;
  }
}

function formatUsageTime(iso) {
  if (!iso) return "-";
  try {
    const d = new Date(iso);
    return isNaN(d.getTime()) ? iso : d.toLocaleTimeString(S.lang === "en" ? "en-US" : "ru-RU", {
      hour: "2-digit", minute: "2-digit", second: "2-digit",
    });
  } catch (e) {
    return iso;
  }
}

function usageCard() {
  const usage = S.usage || [];
  const last = usage[0];
  if (!last) {
    return `
  <div class="card">
    <h2>${t("usageTitle")}</h2>
    <div class="footnote">${t("noUsageData")}</div>
  </div>`;
  }

  const isOk = String(last.status).startsWith("2");
  return `
  <div class="card">
    <h2>${t("usageTitle")}</h2>
    <div class="stack">
      <div class="row" style="flex-wrap:wrap;gap:16px">
        <div style="min-width:140px">
          <div class="setting-sub" style="font-size:10px;text-transform:uppercase">${t("model")}</div>
          <div class="mono" style="font-size:12px;font-weight:600">${esc(last.model || "-")}</div>
        </div>
        <div style="min-width:180px">
          <div class="setting-sub" style="font-size:10px;text-transform:uppercase">${t("providerAccount")}</div>
          <div class="mono" style="font-size:12px">${esc(last.provider || "-")} / ${esc(last.auth || "-")}</div>
        </div>
        <div style="min-width:140px">
          <div class="setting-sub" style="font-size:10px;text-transform:uppercase">${t("dateTime")}</div>
          <div class="mono" style="font-size:11px">${esc(formatUsageDate(last.timestamp))}</div>
        </div>
        <div style="min-width:80px">
          <div class="setting-sub" style="font-size:10px;text-transform:uppercase">${t("mode")}</div>
          <div class="mono" style="font-size:11px">${esc(last.mode || "chat")}</div>
        </div>
        <div style="min-width:80px">
          <div class="setting-sub" style="font-size:10px;text-transform:uppercase">${t("status")}</div>
          <span class="pill ${isOk ? "ok" : "warn"}">${esc(last.status || 200)}</span>
        </div>
      </div>

      <div class="row" style="gap:24px">
        <div>
          <span class="setting-sub" style="font-size:10px">INPUT: </span>
          <span class="mono" style="font-size:12px;font-weight:600">${Number(last.input || 0)}</span>
        </div>
        <div>
          <span class="setting-sub" style="font-size:10px">OUTPUT: </span>
          <span class="mono" style="font-size:12px;font-weight:600">${Number(last.output || 0)}</span>
        </div>
      </div>

      ${usage.length > 1
        ? `<div class="divider"></div>
           <div class="footnote" style="font-weight:600">${t("recentUsage")}</div>
           <table class="kv">${usage.slice(0, 5).map((item) => `<tr>
             <td>${esc(formatUsageTime(item.timestamp))}</td>
             <td class="mono" style="font-size:11px">${esc(item.model || "-")} <span class="muted">${esc(item.provider || "-")}/${esc(item.auth || "-")}</span></td>
             <td class="mono" style="font-size:10px">in: ${Number(item.input || 0)} out: ${Number(item.output || 0)}</td>
             <td><span class="pill ${String(item.status).startsWith("2") ? "ok" : "warn"}">${esc(item.status || 200)}</span></td>
           </tr>`).join("")}</table>`
        : ""}
    </div>
  </div>`;
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

      <div class="row api-routing-head">
        <b style="font-size:12px">${t("accountRouting")}</b>
        <span class="spacer"></span>
        ${strategySelect(orderingState().strategy)}
      </div>
      <div class="footnote">${esc(strategyHint(orderingState().strategy))}</div>
      ${priorityList()}
      <div class="row">
        ${(S.accounts || []).length > 1 ? `<button class="ghost small" data-action="resetOrder">${t("resetOrder")}</button>` : ""}
        <button class="btn small" data-action="gatewaySync" ${S.busy.sync ? "disabled" : ""}>${t("applyRouting")}</button>
        <span class="spacer"></span>
        <button class="ghost small" data-action="go" data-id="routing">${t("openRouting")}</button>
      </div>
    </div>
  </div>

  ${usageCard()}

  ${codexAppCard()}

  <div class="card">
    <h2>${t("configuration")}</h2>
    <div class="row">
      <span class="mono" style="font-size:11px;color:var(--text2);width:130px">${t("serviceKey")}</span>
      <span class="mono" style="font-size:11px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:420px">${esc(settings.apiKey || "—")}</span>
      <button class="ghost small" data-action="copy" data-text="${esc(settings.apiKey || "")}">${t("copy")}</button>
      <button class="ghost small" data-action="apiKeyRotate">${t("rotateKey")}</button>
    </div>
    <div class="footnote">${t("apiKeyHint")}</div>
    <div class="footnote">${t("rotateKeyHint")}</div>
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

/// Codex composer chips as a Settings card: the Composer integration used to
/// live on its own screen, and the macOS build keeps it as a bento card.
function composerChipsCard() {
  const bridge = S.bridge;
  const attached = !!(bridge && bridge.attached);
  const settings = S.settings || {};
  // The chips report every automatic answer; the card shows the last one so a
  // user can tell the fallback is working instead of guessing.
  const lastStamp = bridge && bridge.lastAutoRetryAt
    ? new Date(bridge.lastAutoRetryAt * 1000).toLocaleTimeString(S.lang === "en" ? "en-US" : "ru-RU", {
        hour: "2-digit", minute: "2-digit", second: "2-digit",
      })
    : null;
  const lastAutoRetry = lastStamp && bridge.autoRetryActions
    ? lastStamp
    : null;
  return `<div class="card">
    <h2>${t("composer")}</h2>
    <div class="stack">
      <div class="row">
        <span class="dot ${attached ? "ok" : "warn"}"></span>
        <b style="font-size:12px">${attached ? t("bridgeOn") : t("bridgeOff")}</b>
        <span class="spacer"></span>
        <button class="ghost small" data-action="refreshStatus" ${S.busy.refresh ? "disabled" : ""}>${t("checkNow")}</button>
        ${attached ? "" : `<button class="ghost small" data-action="bridgeLaunchCodex" ${S.busy.launch ? "disabled" : ""}>${t("bridgeRestart")}</button>`}
      </div>
      <div class="footnote" style="margin:0">${t("composerHint")}</div>
      <div class="row" style="margin-top:2px">
        <label class="card-toggle">
          <input type="checkbox" ${settings.autoRetryEnabled !== false ? "checked" : ""} data-action="autoRetryToggle" data-on="change">
          <span>${t("autoRetry")}</span>
        </label>
      </div>
      <div class="footnote" style="margin:0">${t("autoRetryHint")}</div>
      ${lastAutoRetry ? `<div class="footnote" style="margin:0">${fmt(t("autoRetryLast"), { time: lastAutoRetry })}</div>` : ""}
    </div>
  </div>`;
}

/// Codex instances as a Settings card. Same fields as the old screen.
function instancesCard() {
  const instances = S.instancesData || [];
  const accounts = S.accounts || [];
  return `<div class="card">
    <h2>${t("instances")} <span class="hint">${instances.length}</span></h2>
    <div class="stack">
      <div class="row">
        <input class="small instance-name" type="text" id="instance-name" placeholder="${esc(t("instanceNew"))}">
        <button class="btn small" data-action="instanceCreate">${t("instanceCreate")}</button>
      </div>
      ${instances.length
        ? `<div class="stack" style="gap:6px">${instances.map((instance) => `
            <div class="row" style="gap:8px">
              <span class="dot ${instance.exists ? "ok" : "warn"}"></span>
              <b style="font-size:12px">${esc(instance.name)}</b>
              <select data-action="instanceBind" data-id="${esc(instance.id)}" data-on="change">
                <option value="">${t("instanceNone")}</option>
                ${accounts.map((account) => `<option value="${esc(account.id)}" ${instance.accountId === account.id ? "selected" : ""}>${esc(account.email || account.displayName)}</option>`).join("")}
              </select>
              <span class="spacer"></span>
              <button class="ghost small" data-action="instanceLaunch" data-id="${esc(instance.id)}">${t("instanceLaunch")}</button>
              <button class="ghost small danger" data-action="instanceDelete" data-id="${esc(instance.id)}">${t("instanceDelete")}</button>
            </div>`).join("")}</div>`
        : `<div class="footnote" style="margin:0">${esc(t("instanceHint"))}</div>`}
    </div>
  </div>`;
}

function settingsPage() {
  const settings = S.settings || {};
  const info = S.info || {};
  const interval = Number(settings.quotaInterval ?? 300);
  const islandAutoCollapse = [0, 5, 10, 15, 20].indexOf(Number(settings.islandAutoCollapseSeconds)) >= 0 ? Number(settings.islandAutoCollapseSeconds) : 15;
  const proxyUrlDraft = S.proxyUrlDraft !== null && S.proxyUrlDraft !== undefined
    ? String(S.proxyUrlDraft)
    : String(settings.proxyUrl || "");
  const proxyUrlDirty = proxyUrlDraft.trim() !== String(settings.proxyUrl || "").trim();
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
      <span class="setting-label">${t("theme")}</span>
      <div class="segmented">
        ${[["system", "themeSystem"], ["light", "themeLight"], ["dark", "themeDark"]].map(([id, key]) => `<button class="${(settings.theme || "system") === id ? "active" : ""}" data-action="setTheme" data-id="${id}">${esc(t(key))}</button>`).join("")}
      </div>
    </div>
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
      <div class="row" style="align-items:flex-end">
        <label class="field" style="flex:1">${t("proxyUrl")}
          <input id="set-proxy-url" class="mono" placeholder="socks5h://127.0.0.1:1080" value="${esc(proxyUrlDraft)}" data-action="proxyUrlChanged" data-on="input">
        </label>
        <button class="proxy-save" id="proxy-save" data-action="saveProxyUrl" title="${t("saveProxyUrl")}" aria-label="${t("saveProxyUrl")}" ${proxyUrlDirty ? "" : "hidden"}>✓</button>
        <label class="field" style="flex:1">${t("proxyBypass")}
          <input id="set-proxy-bypass" class="mono" value="${esc(settings.proxyBypass || "127.0.0.1,localhost")}">
        </label>
      </div>
      <div class="footnote" style="margin:0">${t("proxyHint")}</div>
    </div>
  </div>

  <div class="card">
    <h2>${t("qosCard")}</h2>
    <div class="stack">
      <label class="card-toggle">
        <input type="checkbox" ${Number(settings.streamBootstrapTimeoutSeconds ?? 180) > 0 ? "checked" : ""} data-action="firstTokenFailoverToggle" data-on="change">
        <span>${t("qosToggle")}</span>
      </label>
      <div class="row">
        <label class="field">${t("firstTokenTimeout")}
          <input class="small" type="number" id="set-stream-timeout" min="0" max="300" step="15" value="${Number(settings.streamBootstrapTimeoutSeconds ?? 180)}">
        </label>
      </div>
      <div class="footnote" style="margin:0">${t("qosHint")}</div>
    </div>
  </div>

  <div class="card">
    <h2>${t("statusIsland")}</h2>
    <label class="card-toggle"><input type="checkbox" ${settings.islandVisible !== false ? "checked" : ""} data-action="islandToggle" data-on="change"> ${t("showStatusIsland")}</label>
    <div class="footnote" style="margin:2px 0 0">${t("islandVisibleHint")}</div>
    <label class="field" style="margin-top:10px">${t("islandAutoCollapse")}
      <select data-action="islandAutoCollapse" data-on="change">
        <option value="0" ${islandAutoCollapse === 0 ? "selected" : ""}>${t("islandAutoCollapseOff")}</option>
        ${[5, 10, 15, 20].map((n) => `<option value="${n}" ${islandAutoCollapse === n ? "selected" : ""}>${n} ${t("secondsUnit")}</option>`).join("")}
      </select>
    </label>
    <div class="footnote" style="margin:4px 0 0">${t("islandAutoCollapseHint")}</div>
  </div>

  <div class="card">
    <h2>${t("taskbarWidget")}</h2>
    <label class="card-toggle"><input type="checkbox" role="switch" ${settings.taskbarWidgetVisible === true ? "checked" : ""} data-action="taskbarWidgetToggle" data-on="change" ${S.busy["taskbar-widget"] ? "disabled" : ""}> ${t("showTaskbarWidget")}</label>
    <div class="footnote">${t("taskbarWidgetHint")}</div>
  </div>

  <div class="card">
    <h2>${t("dashboardWidgets")}</h2>
    <div class="stack" style="gap:6px">
      <label class="card-toggle"><input type="checkbox" ${settings.dashboardShowPoolHealth !== false ? "checked" : ""} data-action="dashboardCardToggle" data-id="dashboardShowPoolHealth" data-on="change"> ${t("showPoolHealth")}</label>
      <label class="card-toggle"><input type="checkbox" ${settings.dashboardShowAntigravityPool !== false ? "checked" : ""} data-action="dashboardCardToggle" data-id="dashboardShowAntigravityPool" data-on="change"> ${t("showAntigravity")}</label>
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
    </div>
    <div class="row">
      <label class="card-toggle">
        <input type="checkbox" ${settings.gatewayAutoStart !== false ? "checked" : ""} data-action="gatewayAutoStartToggle" data-on="change">
        <span>${t("gatewayAutoStart")}</span>
      </label>
    </div>
    <div class="footnote">${t("gatewayAutoStartHint")}</div>
    <div class="row" style="justify-content:flex-end">
      <button class="btn small" data-action="applySettings" ${S.busy.settings ? "disabled" : ""}>${t("apply")}</button>
    </div>
  </div>

  ${composerChipsCard()}

  ${instancesCard()}

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
      <div class="footnote">${t("backupLast")}: ${S.backupLast ? esc(dateTimeText(S.backupLast)) : esc(t("backupNone"))}</div>
    </div>
  </div>

  <div class="card">
    <h2>${t("supportBundle")}</h2>
    <div class="footnote">${esc(t("supportBundleHint"))}</div>
    <div class="row" style="margin-top:10px">
      <button class="ghost small" data-action="diagRun" ${S.busy.diag ? "disabled" : ""}>${t("diagRun")}</button>
      <button class="btn small" data-action="supportBundle" ${S.busy.support ? "disabled" : ""}>${t("supportBundle")}</button>
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

function cardIcon(svg, tint) {
  return `<span class="card-icon" style="color:${tint || "var(--accent)"}">${svg}</span>`;
}

const CARD_ICONS = {
  health: '<svg viewBox="0 0 24 24"><path d="M3 12h4l2-5 4 10 2-5h4"/></svg>',
  providers: '<svg viewBox="0 0 24 24"><path d="M12 3 3 8l9 5 9-5-9-5Z"/><path d="M3 14l9 5 9-5"/></svg>',
  pools: '<svg viewBox="0 0 24 24"><circle cx="8" cy="8" r="3"/><circle cx="16" cy="16" r="3"/><path d="M8 11v2a3 3 0 0 0 3 3h2"/></svg>',
  trends: '<svg viewBox="0 0 24 24"><path d="M4 19a15 15 0 0 1 16 0"/><path d="M12 19l4-6"/></svg>',
  scheduler: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/></svg>',
  spend: '<svg viewBox="0 0 24 24"><path d="M12 4v16"/><path d="M16 8a4 4 0 0 0-8 0c0 4 8 2 8 6a4 4 0 0 1-8 0"/></svg>',
  gateway: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M4 12h16M12 4a13 13 0 0 1 0 16a13 13 0 0 1 0-16"/></svg>',
};

function dashAverage(values) {
  const list = values.filter((value) => typeof value === "number" && Number.isFinite(value));
  return list.length ? list.reduce((sum, value) => sum + value, 0) / list.length : null;
}

function pluralRu(value, one, few, many) {
  const n = Math.abs(Number(value) || 0);
  const tail = n % 100;
  if (tail >= 11 && tail <= 14) return many;
  const last = n % 10;
  if (last === 1) return one;
  if (last >= 2 && last <= 4) return few;
  return many;
}

function accountsCountText(value) {
  const n = Number(value) || 0;
  if (S.lang === "en") return `${n} ${n === 1 ? "account" : "accounts"}`;
  return `${n} ${pluralRu(n, "аккаунт", "аккаунта", "аккаунтов")}`;
}

function modelsCountText(value) {
  const n = Number(value) || 0;
  if (S.lang === "en") return `${n} ${n === 1 ? "model" : "models"}`;
  return `${n} ${pluralRu(n, "модель", "модели", "моделей")}`;
}

function providerLines() {
  const settings = S.settings || {};
  const accounts = Array.isArray(S.accounts) ? S.accounts : [];
  const agAccounts = (S.antigravity && Array.isArray(S.antigravity.accounts)) ? S.antigravity.accounts : [];
  const claudeOn = !!(S.claude && S.claude.connected);
  const models = Array.isArray(S.models) ? S.models : [];
  const countModels = (prefix) => models.filter((model) => String(model.id || "").startsWith(prefix)).length;
  const hasKey = (value) => String(value || "").trim().length > 0;
  const lines = [];

  lines.push({
    id: "codex",
    name: "Codex",
    on: accounts.length > 0,
    detail: accountsCountText(accounts.length),
    tint: "var(--info)",
  });
  if (hasKey(settings.openrouterKey)) lines.push({ id: "openrouter", name: "OpenRouter", on: true, detail: modelsCountText(countModels("openrouter/")), tint: "var(--violet)" });
  if (hasKey(settings.opencodeKey)) lines.push({ id: "opencode", name: "OpenCode", on: true, detail: modelsCountText(countModels("opencode/")), tint: "var(--info)" });
  if (hasKey(settings.deepinfraKey)) lines.push({ id: "deepinfra", name: "DeepInfra", on: true, detail: modelsCountText(countModels("deepinfra/")), tint: "var(--ok)" });
  if (hasKey(settings.nvidiaKey)) lines.push({ id: "nvidia", name: "NVIDIA", on: !!settings.nvidiaEnabled, detail: modelsCountText(countModels("nvidia/")), tint: "var(--ok)" });
  if (hasKey(settings.vercelKey)) lines.push({ id: "vercel", name: "Vercel", on: true, detail: modelsCountText(countModels("vercel/")), tint: "var(--text2)" });
  if (hasKey(settings.zaiKey)) lines.push({ id: "zai", name: "Z.ai", on: true, detail: modelsCountText(countModels("zai/")), tint: "var(--accent)" });
  if (hasKey(settings.commandcodeKey)) lines.push({ id: "commandcode", name: "CommandCode", on: true, detail: modelsCountText(countModels("commandcode/")), tint: "var(--violet)" });
  if (claudeOn || hasKey(settings.claudeKey)) lines.push({ id: "claude", name: "Claude", on: true, detail: t("connected"), tint: "var(--accent)" });
  if (agAccounts.length) lines.push({ id: "antigravity", name: "Antigravity", on: true, detail: accountsCountText(agAccounts.length), tint: "var(--info)" });

  return lines.sort((lhs, rhs) => {
    if (lhs.on !== rhs.on) return lhs.on ? -1 : 1;
    return lhs.name.localeCompare(rhs.name);
  });
}

function dashboardProvidersCard() {
  const lines = providerLines();
  const models = Array.isArray(S.models) ? S.models.length : 0;
  const body = lines.length
    ? lines.map((line) => `<div class="provider-line${line.on ? "" : " off"}">
        <span class="provider-dot" style="background:${line.on ? line.tint : "var(--text3)"}"></span>
        <span class="provider-name">${esc(line.name)}</span>
        <span class="provider-detail">${esc(line.detail)}</span>
      </div>`).join("")
    : `<div class="footnote" style="margin:0">${t("dashNoProviders")}</div>`;
  return `<div class="card dash-card" data-dashboard-card="providers">
    <h2>${cardIcon(CARD_ICONS.providers, "var(--violet)")}${t("dashProviders")}</h2>
    <div class="stack" style="gap:6px">${body}</div>
    <div class="spacer"></div>
    <div class="card-footer">
      <span>${esc(fmt(t("dashConnected"), { n: lines.filter((line) => line.on).length }))}</span>
      <span class="spacer"></span>
      <span>${models} ${t("modelsShort")}</span>
    </div>
  </div>`;
}

function poolMetric(label, value) {
  const text = value === null || value === undefined ? "—" : `${Math.round(value)}%`;
  return `<div class="pool-metric"><span class="label">${esc(label)}</span><span class="value">${text}</span></div>`;
}

function dashboardPoolsCard() {
  const accounts = Array.isArray(S.accounts) ? S.accounts : [];
  const health = poolHealth(accounts, S.routing);
  const agAccounts = (S.antigravity && Array.isArray(S.antigravity.accounts)) ? S.antigravity.accounts : [];
  const gemini = dashAverage(agAccounts.map((account) => {
    const value = account && account.gemini && account.gemini.remaining;
    return typeof value === "number" ? value * 100 : null;
  }));
  const claudePool = dashAverage(agAccounts.map((account) => {
    const value = account && account.claude && account.claude.remaining;
    return typeof value === "number" ? value * 100 : null;
  }));
  const claudeConnected = !!(S.claude && S.claude.connected);
  const total = accounts.length + agAccounts.length + (claudeConnected ? 1 : 0);

  const row = (icon, tint, title, count, metrics) => `<div class="pool-line">
    <span class="pool-icon" style="color:${tint}">${icon}</span>
    <span class="stack" style="gap:0">
      <span class="provider-name">${esc(title)}</span>
      <span class="provider-detail" style="margin:0">${esc(fmt(t("accountsInPool"), { n: count }))}</span>
    </span>
    <span class="pool-metrics">${metrics.join("")}</span>
  </div>`;

  const codexIcon = '<svg viewBox="0 0 24 24"><path d="M12 12a4 4 0 1 0 0-8a4 4 0 0 0 0 8Z"/><path d="M5 20a7 7 0 0 1 14 0"/></svg>';
  const agIcon = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="2"/><path d="M12 4a8 8 0 0 1 8 8M12 20a8 8 0 0 1-8-8"/></svg>';
  const claudeIcon = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M12 8v8"/></svg>';

  const rows = [];
  rows.push(row(codexIcon, "var(--info)", t("codexPool"), accounts.length, [
    poolMetric(t("fiveHour"), health.averageHourly),
    poolMetric(t("week"), health.averageWeekly),
  ]));
  if (agAccounts.length) {
    rows.push(row(agIcon, "var(--violet)", "Antigravity", agAccounts.length, [
      poolMetric("Gemini", gemini),
      poolMetric("Claude", claudePool),
    ]));
  }
  if (claudeConnected) {
    rows.push(row(claudeIcon, "var(--accent)", "Claude", 1, []));
  }

  return `<div class="card dash-card" data-dashboard-card="pools">
    <h2>${cardIcon(CARD_ICONS.pools, "var(--ok)")}${t("dashPools")}</h2>
    <div class="stack" style="gap:10px">${rows.join("")}</div>
    <div class="spacer"></div>
    <div class="card-footer">
      <span>${t("dashAllPools")}</span>
      <span class="spacer"></span>
      <span>${accountsCountText(total)}</span>
    </div>
  </div>`;
}

function totalCell(label, total, max) {
  const fraction = total === null || !max ? 0 : Math.min(1, Math.max(0, total / max));
  return `<div class="average-cell">
    <span class="stat-label">${esc(label)}</span>
    <span class="average-value">${total === null ? "—" : `${Math.round(total)}%`}${total === null ? "" : ` <span class="footnote" style="margin:0">${esc(fmt(t("dashOfMax"), { n: Math.round(max) }))}</span>`}</span>
    <div class="bar"><i class="${quotaTint(total === null ? null : fraction * 100)}" style="width:${(fraction * 100).toFixed(1)}%"></i></div>
  </div>`;
}

function dashboardPoolCard(health, accounts) {
  const list = Array.isArray(accounts) ? accounts : [];
  const hourly = quotaTotals(list, "hourlyRemaining");
  const weekly = quotaTotals(list, "weeklyRemaining");
  const stat = (label, value, cls) => `<div class="stat ${cls || ""}">
    <span class="value">${value}</span><span class="label">${esc(label)}</span></div>`;
  return `<div class="card dash-card" data-dashboard-card="pool-health">
    <h2>${cardIcon(CARD_ICONS.health, "var(--ok)")}${t("dashPoolHealth")}</h2>
    <div class="stat-grid">
      ${stat(t("dashTotal"), health.total, "")}
      ${stat(t("dashUsable"), health.usable, "ok")}
      ${stat(t("dashPaused"), health.paused, "warn")}
      ${stat(t("dashErrors"), health.errors, health.errors > 0 ? "danger" : "")}
    </div>
    <div class="average-grid">
      ${totalCell(t("dashTotalFive"), hourly.total, hourly.max)}
      ${totalCell(t("dashTotalWeek"), weekly.total, weekly.max)}
    </div>
  </div>`;
}

function quotaTotals(accounts, field) {
  const list = Array.isArray(accounts) ? accounts.filter((account) => account && account.poolEnabled !== false) : [];
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

/// Antigravity exposes two 5-hour pools (Gemini and Claude / GPT) and no
/// weekly window, so the second total tracks the Claude pool instead of
/// inventing a weekly figure. An account on pause or in a cooldown cannot
/// serve a request, which is what "usable" means here.
function dashboardAntigravityCard(antigravity) {
  const list = antigravity && Array.isArray(antigravity.accounts) ? antigravity.accounts : [];
  let usable = 0;
  let errors = 0;
  let gemini = 0;
  let geminiSeen = 0;
  let claude = 0;
  let claudeSeen = 0;
  for (const account of list) {
    if (!account) continue;
    const cooling = Array.isArray(account.cooldowns) && account.cooldowns.length > 0;
    if (!account.disabled && !cooling) usable += 1;
    if (account.quotaError) errors += 1;
    const geminiLeft = finiteNumber(account.gemini && account.gemini.remaining);
    if (geminiLeft !== null) {
      gemini += geminiLeft * 100;
      geminiSeen += 1;
    }
    const claudeLeft = finiteNumber(account.claude && account.claude.remaining);
    if (claudeLeft !== null) {
      claude += claudeLeft * 100;
      claudeSeen += 1;
    }
  }
  const max = list.length * 100;
  const stat = (label, value, cls) => `<div class="stat ${cls || ""}">
    <span class="value">${value}</span><span class="label">${esc(label)}</span></div>`;
  return `<div class="card dash-card" data-dashboard-card="antigravity-pool">
    <h2>${cardIcon(CARD_ICONS.health, "var(--ok)")}${t("dashAntigravityPool")}</h2>
    <div class="stat-grid">
      ${stat(t("dashTotal"), list.length, "")}
      ${stat(t("dashUsable"), usable, "ok")}
      ${stat(t("dashPaused"), list.length - usable, "warn")}
      ${stat(t("dashErrors"), errors, errors > 0 ? "danger" : "")}
    </div>
    <div class="average-grid">
      ${totalCell(t("dashTotalGemini"), geminiSeen ? gemini : null, max)}
      ${totalCell(t("dashTotalClaude"), claudeSeen ? claude : null, max)}
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
    <h2>${cardIcon(CARD_ICONS.spend, "var(--violet)")}${t("dashSpend")}</h2>
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
    <h2>${cardIcon(CARD_ICONS.scheduler, "var(--accent)")}${t("dashScheduler")}</h2>
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
    <h2>${cardIcon(CARD_ICONS.pools, "var(--info)")}${t("codexPool")}</h2>
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
    <h2>${cardIcon(CARD_ICONS.gateway, "var(--ok)")}${t("api")}</h2>
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
      <button class="ghost small" data-action="openApi">${t("open")}</button>
    </div>
    ${S.checkResult ? `<div class="note-line ${S.checkPassed ? "ok" : "danger"}">${esc(S.checkResult)}</div>` : ""}
  </div>`;
}

function dashHero(status) {
  const running = !!status.running;
  const busy = S.busy || {};
  return `<div class="dash-hero">
    <img class="hero-logo" src="logo.png" alt="" />
    <div class="hero-text">
      <div class="hero-title">
        <h1>Melon Tools</h1>
        <span class="dot ${running ? "ok" : "warn"}"></span>
        <span style="font-size:10px;font-weight:600;color:${running ? "var(--ok)" : "var(--text2)"}">${running ? t("running") : t("stopped")}</span>
      </div>
      <span class="hero-sub">${t("dashSub")}</span>
    </div>
    <div class="hero-actions">
      ${running
        ? `<button class="ghost small" data-action="gatewayStop" ${busy.stop ? "disabled" : ""}>${t("stop")}</button>`
        : `<button class="btn small" data-action="gatewayStart" ${busy.start ? "disabled" : ""}>${t("start")}</button>`}
      <button class="ghost small" data-action="go" data-id="accounts">${t("accounts")}</button>
    </div>
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
  ${dashHero(status)}
  <div class="dash-grid">
    ${dashboardProvidersCard()}
    ${dashboardPoolsCard()}
    ${cards.pool ? dashboardPoolCard(health, accounts) : ""}
    ${cards.antigravity ? dashboardAntigravityCard(S.antigravity) : ""}
    ${cards.scheduler ? dashboardSchedulerCard(schedule) : ""}
    ${cards.spend ? dashboardSpendCard(usage) : ""}
    <div class="dash-wide">${dashboardGatewayCard(status)}</div>
  </div>
  ${!accounts.length ? `<div class="card"><div class="muted">${t("warnNoAccounts")}</div></div>` : ""}
  `;
}
