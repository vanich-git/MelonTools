# Аудит macOS Local AI (read-only)

Дата: 2026-11-04. Проверялись: `LocalDownloadManager.swift`, `LocalModelStore.swift`,
`HuggingFaceService.swift`, `RuntimeStore.swift`, `RuntimePackageInstaller.swift`,
`RuntimeCatalog.swift`, `RuntimeDownloadProgress.swift`, `GgufMetadata.swift`,
`LocalAIMigration.swift`, `MacOS/scripts/fetch-runtime.sh`, тесты, docs.
Исходники, пользовательские данные и настройки не изменялись. `xcodebuild` не
запускался (в том числе чтобы не конкурировать с родительским агентом), реальные
скачивания/модели/рантаймы не запускались. Все проверки — статический разбор плюс
изолированные Swift/tar/bash-эксперименты в `/tmp/melon-audit`.

Документы `docs/LOCAL_AI_ARCHITECTURE.md`, `docs/HUGGING_FACE_INTEGRATION.md`,
`docs/LOCAL_AI_RUNTIME.md` — это документация, а не полное ТЗ 6.0.0; их утверждения
ниже используются как заявленные контракты, а не как доказательство корректности.

## Итог

P0 не найдено. P1 — 6 (потеря/порча данных, crash/OOM, обход каталога).
P2 — 9 (возобновление, финализация, скрытые runtime, временные файлы, миграция,
производительность, гонки состояний). P3 — 5+ (метаданные, URL, Keychain,
context, документация/тесты).

Главный вывод: большинство «fixed»-комментариев закрывают только узкий случай,
а соседние пути (другой репозиторий, другое имя, импорт, внешний каталог,
перезапуск) по-прежнему нарушают те же инварианты.

---

## P1

### P1-1. Коллизии имени файла и API-id: тихая перезапись и потеря установленных моделей

**Где:** `LocalDownloadManager.swift:96-112` (дедупликация только по паре
`repoId+fileName`), `:115` (`.part` только по `fileName`), `:325-326` (final только
по `fileName`), `:363-366` (`removeItem(finalFile)` перед `moveItem`), `:372-374`
(нормализованный id без уникализации), `:404`; `LocalModelStore.swift:159-164`,
`:629-635` (импорт: `removeItem(target)` до `copyItem`), `:410-412` (шарды),
`:563-570` (`addOrUpdateModel` заменяет запись по id), `:465-485` (`uniqueModelID`
есть, но используется только в `:241`, `:302`, `:427`, не в `:672` и не в download);
`docs/LOCAL_AI_ARCHITECTURE.md:51-53` (обещание «никогда не делят один API-id»).

**Доказательный сценарий:**

1. В двух репозиториях есть файл с одинаковым именем, например
   `Qwen3-4B-Q4_K_M.gguf` (типичная ситуация у разных квантователей). Пользователь
   запускает обе загрузки: проверка `:98-107` пропускает их, потому что `repoId`
   разный. Оба пишут в `downloads/Qwen3-4B-Q4_K_M.gguf.part` (`:115`), каждый со
   своим `FileHandle` и своим `seekToEnd`. Байты перемешиваются; один из
   обработчиков удаляет общий `.part` при ошибке проверки.
2. Последовательно: вторая загрузка на `:363-366` удаляет уже установленный файл
   первой модели и кладёт новый; `:372-374` даёт тот же `local/qwen3-4b-q4_k_m`,
   поэтому `addOrUpdateModel` заменяет запись. Первая модель исчезает из реестра,
   её файл уничтожен — без предупреждения.
3. Импорт: `prepareImport` всегда пишет в `models/<basename>` (`:160`). Импорт
   `/A/model.gguf`, затем `/B/model.gguf` даёт две записи с разными id (async-путь
   использует `uniqueModelID`), но один и тот же файл `models/model.gguf`. Удаление
   любой из записей с `deleteFiles:true` удаляет общий файл у обеих.
4. На стандартном APFS (case-insensitive) `Model.gguf` и `model.gguf` — один файл,
   но сравнения в `:98-112` и `:159-164` регистрозависимы. Проверено в `/tmp`:
   после `Model.gguf` запись `model.gguf` изменила тот же файл.

**Impact:** потеря установленной модели, «модель есть в списке, файла нет», либо
две записи, обслуживающие один и тот же (не тот) файл; при одновременной загрузке —
порча `.part`. При отсутствии LFS-дайджеста смешанный файл может пройти проверку
magic+размера.

**Минимальное исправление:** хранить загрузку в
`downloads/<repo-slug>/<sha12>/<basename>.part`; final-имя строить из уникального
id (`uniqueModelID`), а не из имени HF; перед публикацией — атомарная замена без
предварительного удаления; при коллизии final/id — уникализировать или спрашивать;
в импорте — `uniqueModelID` + уникальное имя файла; сверять `repoId`/`sha256` при
повторной загрузке.

### P1-2. Импорт удаляет существующий файл до копирования

**Где:** `LocalModelStore.swift:159-164` (`try? removeItem(target)` → `copyItem`),
`:629-635` (то же в sync-импорте), `:410-412` (шарды).

**Сценарий:** в `models/` уже лежит рабочая модель `foo.gguf`; пользователь
импортирует другой `foo.gguf` (или тот же файл с отсоединившегося сетевого тома).
`removeItem` уже уничтожил старый файл, `copyItem` падает (нет места/нет доступа/
источник исчез) — функция бросает ошибку, но старой модели больше нет. Запись в
реестре остаётся до следующего запуска и выглядит установленной. Аналогично для
каждого шарда в `:410-412`.

**Impact:** необратимая потеря установленной модели при неудачном импорте; при
успешном импорте — тихая подмена файла другой модели.

**Минимальное исправление:** копировать в `.<uuid>.tmp` в целевом каталоге,
проверять размер/метаданные, затем `replaceItemAt`/`rename`; никогда не удалять
старый target до успешной подготовки нового; при коллизии — уникальное имя или
явное подтверждение.

### P1-3. «Перенос» каталога моделей без переноса и без повторной проверки

**Где:** `LocalModelStore.swift:33-42` (models/downloads — разные каталоги),
`:83-92` (если внешний том не смонтирован — молчаливый fallback на внутренний),
`:95-112` (`setCustomModelsDirectory` только меняет путь и пишет настройку),
`:504-507` (относительные пути проверяются уже в новом каталоге),
`:597-607` (`removeModel` разрешает относительный путь в новом каталоге);
`Views/LocalAI/LocalAISettingsTab.swift:405-415` (выбор каталога без предупреждения
и без миграции); `docs/LOCAL_AI_ARCHITECTURE.md:76-78` («каталог можно перенести»).

**Сценарий:** пользователь выбирает пустой внешний каталог. Все относительные
`files` внезапно указывают в него: карточки остаются «installed», но Start падает
«Model file does not exist»; старые файлы остаются во внутреннем каталоге и
становятся orphan. Если выбрать каталог, где уже есть файлы с теми же именами,
реестр молча привязывается к ним: Start запускает чужой файл, а «Delete Model and
File» удаляет именно его. Если внешний том не смонтирован при запуске, `:83-92`
подставляет внутренний каталог, помечает модели `notInstalled`, новые загрузки
кладутся внутрь; после монтирования они не видны, а `removeModel` их не удалит.
`downloads/` при этом всегда внутренний (`:40-42`), то есть финализация идёт
между томами (см. P2-3).

**Impact:** массовая «пропажа» моделей, обслуживание не того файла, удаление
чужих файлов, многогигабайтные orphan-файлы; заявленный перенос хранилища не
реализован.

**Минимальное исправление:** явная миграция (копирование с прогрессом, проверка,
атомарное переключение, rollback); хранить в реестре абсолютный корень/volume UUID
или пересканировать каталог; проверять writability и наличие тома; не делать
молчаливый fallback без предупреждения; при смене каталога перепроверять каждый
файл и пересчитывать размеры.

### P1-4. Split GGUF: шарды скачиваются/импортируются как самостоятельные модели

**Где:** `LocalDownloadManager.swift:370-404` (любой скачанный `.gguf` регистрируется
как отдельная модель); `Views/LocalAI/HuggingFaceCatalogView.swift:318,377`
(кнопка Download на каждый `rfilename`); `HuggingFaceService.swift:242-269`
(список включает все шарды); `LocalModelStore.swift:272-332` (группировка без
проверки полноты), `:345-360` (`total` парсится, но нигде не используется),
`:424-459` (sync-импорт), `:154-162` (`fileExists` проверяет только перечисленные
файлы); `LocalInferenceService.swift:432,438` (в preset попадает только первый файл).

**Сценарий:** пользователь скачивает `model-Q4_K_M-00001-of-00003.gguf` — запись
«installed», но llama-server не находит остальные шарды и падает при Start.
Скачивает все три — получает три отдельные модели
`local/model-...-00001-of-00003` и т.д. Импорт папки, где не хватает
`00002-of-00003`, принимает набор `[1,3]` (или `[2]`), потому что `total` не
сверяется; `fileExists` возвращает true, модель числится установленной.

**Impact:** нерабочие «установленные» модели, дубли, неверный `fileSize`/context;
для больших моделей — частая ситуация.

**Минимальное исправление:** в каталоге/UI распознавать `-NNNNN-of-NNNNN`,
скачивать набор целиком (или блокировать частичную загрузку); при регистрации
проверять `index` 1...`total`, уникальность и согласованность `total`; объединять
шарды в одну запись и считать `ready` только при полном наборе.

### P1-5. Некорректные длины в GGUF: trap или OOM при импорте/запуске

**Где:** `GgufMetadata.swift:220-240` (`skipArray`), `:214-216`
(`skipBytes` → `readData(ofLength:)`), `:143-150` (`Int(raw)` для UInt64),
`:204-211` (`readString`); вызовы: `LocalModelStore.swift:516` (на главном
actor при загрузке реестра), `LocalDownloadManager.swift:370` (после move),
`LocalModelStore.swift:171` (импорт).

**Доказательство:** из `GgufMetadata.swift` без изменений собран harness в
`/tmp/melon-audit/gguf`. Файл: magic `GGUF`, version 3, `tensor_count=0`,
`metadata_kv_count=1`, key `general.architecture`, value type `tArray`, element
type `tUInt8`, length `UInt64.max`. Процесс завершился `Trace/BPT trap: 5`
(exit 133) на `Int(length)` (`:234`). Отдельно `readData(ofLength: 200_000_000)`
на 10-байтовом файле дал max RSS ~135 MB — то есть `skipBytes` пытается
аллоцировать запрошенный объём, а не ограничивается размером файла; для
`Int.max`-подобной длины это OOM/падение. `Int(raw)` в `:148` — такой же trap для
`context_length`/`block_count` типа UInt64/Int64.

**Сценарий:** пользователь импортирует/скачивает `.gguf` с валидным magic, но
испорченным KV-блоком. Импорт (off-main) или `loadRegistry` (main) падает; если
файл уже попал в реестр, приложение падает при каждом запуске. `try?` в
`LocalModelStore.swift:516` ловит только Swift-throws, не trap.

**Impact:** crash/DoS, невозможность запуска приложения, повреждение пользовательского
сеанса.

**Минимальное исправление:** ограничивать `length` остатком файла
(`fileSize - offset`) и разумным лимитом метаданных; использовать
`Int(exactly:)`/`guard length <= UInt64(Int.max)`; для пропуска использовать
`seek`, а не `readData`; ограничить суммарный объём KV; парсить вне main actor с
таймаутом/отменой; добавить fuzz-тесты.

### P1-6. `fileName`/`rfilename` не валидируется: выход за каталог и застревание загрузки

**Где:** `LocalDownloadManager.swift:115` (`downloadsDirectory.appendingPathComponent("\(fileName).part")`),
`:217` (cancel), `:325-326` (final); `HuggingFaceService.swift:248` (URL из
`repoId`/`rfilename` без разбора пути); `LocalModelStore.swift:383/599`
(`files` из download и `removeModel`).

**Доказательство:** для базы
`.../MelonTools/downloads` вызов `appendingPathComponent("../../../../tmp/x.gguf")`
даёт путь с `..` (Foundation не нормализует), а `"/tmp/x.gguf"` — вложенный
`.../downloads/tmp/x.gguf`. `sub/model.gguf` даёт `.../downloads/sub/model.gguf`,
но `downloads/sub` никто не создаёт: `createFile` возвращает false, `FileHandle`
бросает, а элемент уже добавлен в `items` (`:136`) — карточка навсегда
«Downloading…», повтор блокируется проверкой `:98-107`, пока пользователь не
нажмёт Cancel.

**Сценарий:** HF API (или будущий direct-URL, или скомпрометированный ответ)
возвращает `rfilename="../../../../Users/<user>/Documents/evil.gguf"`. Файл
пишется/перемещается вне `models/`; в реестр попадает `files: ["../../..."]`;
«Delete Model and File» затем удаляет файл по этому пути. Даже без атаки
`subdir/model.gguf` — обычная структура HF-репозиториев — ломает скачивание и
оставляет застрявшую карточку.

**Impact:** запись `.gguf` вне управляемого каталога, удаление файлов вне него,
застрявшая загрузка и невозможность повтора.

**Минимальное исправление:** брать только `URL(fileURLWithPath: fileName).lastPathComponent`,
отвергать пустое имя/`.`/`..`/разделители (`/`, `\`), канонизировать и проверять
префикс каталога; если нужны подкаталоги — создавать их и хранить
repo-специфичный путь; при любой ошибке после `items.append` удалять/помечать
элемент failed; URL строить через `URLComponents` с percent-encoding.

---

## P2

### P2-1. Слепое возобновление `.part`: склейка ревизий и потеря готового файла

**Где:** `LocalDownloadManager.swift:115-151` (Range/If-Range), `:200-202`
(`clearFinished` не удаляет `.part`), `:263-270` (нет проверки начала
`Content-Range`), `:340` (сверяется счётчик, не размер файла), `:408` (catch
удаляет `.part`); отсутствие персистентности `DownloadItem`.

**Сценарий:** приложение завершилось/сеть упала, `.part` остался. При следующем
запуске `items` пуст, `validator` теряется; пользователь снова нажимает Download
(из каталога), `existingBytes > 0`, отправляется `Range`, но **без `If-Range`**.
Если upstream за это время обновил файл с тем же размером, в `.part` склеиваются
две ревизии; при отсутствии `lfs.sha256` проверяются только magic и счётчик —
испорченная модель принимается. Если `.part` уже полный (краш между завершением
данных и `handleTaskCompleted`), сервер отвечает 416; тело ошибки дописывается,
размер не сходится, catch удаляет **полный** `.part`.

**Impact:** принятая испорченная модель (без дайджеста) либо потеря полностью
скачанного файла; в остальных случаях — скрытая повторная загрузка.

**Минимальное исправление:** sidecar-метаданные рядом с `.part` (`repoId`, URL,
ETag/Last-Modified, total, sha256); возобновлять только при полном совпадении;
без validator/дайджеста — начинать с нуля; проверять начало `Content-Range`;
на 416 — сначала проверить/финализировать существующий файл; `clearFinished`
должен удалять `.part` или сохранять его метаданные.

### P2-2. Проверка места при resume считает весь файл, а не остаток

**Где:** `LocalDownloadManager.swift:86-94` (проверка до чтения `.part`),
`:116-119` (размер `.part` читается позже).

**Сценарий:** модель 8 ГБ, `.part` 7,5 ГБ, свободно 3 ГБ. `totalNeeded =
8 ГБ + 2 ГБ = 10 ГБ` → отказ «Insufficient disk space», хотя нужен остаток
0,5 ГБ + резерв. Пользователь не может возобновить почти готовую загрузку, пока
не освободит лишние гигабайты.

**Минимальное исправление:** сначала прочитать `existingBytes`, затем считать
`remaining = max(0, expectedSize - existingBytes)` и резерв от остатка (или
отдельный небольшой резерв); при неизвестном размере — консервативно, но не
блокировать очевидный resume.

### P2-3. Финализация между томами на главном потоке; нет проверки места назначения; удаление старого до перемещения

**Где:** `LocalDownloadManager.swift:89` (свободное место только у
`downloadsDirectory`), `:325-326`, `:363-366` (`removeItem(finalFile)` →
`moveItem`), `:406-413` (catch удаляет `.part`), `:56` (`@MainActor`).

**Сценарий:** `customModelsDirectory` — внешний диск, `downloads/` — внутренний.
Загрузка завершена; на внешнем диске нет места (или том отмонтирован).
`removeItem(finalFile)` уже удалил старую модель, `moveItem` падает, catch удаляет
`.part` — потеряны и старая модель, и новая загрузка. `FileManager.moveItem`
между томами — это copy+delete, на главном actor интерфейс зависает на минуты;
прогресс/отмена не обрабатываются, другие загрузки стоят.

**Минимальное исправление:** проверять свободное место на `modelsDirectory`
(после учёта `.part`); копировать в `.<uuid>.tmp` на целевом томе, проверять,
затем атомарно `replaceItemAt`; при ошибке сохранять `.part`; выполнять hash/move
вне main actor (см. P2-8).

### P2-4. Ошибка открытия `.part` оставляет элемент в состоянии `.downloading`

**Где:** `LocalDownloadManager.swift:122-136` (append до открытия),
`:153-160` (create/FileHandle), `:98-107` ( dedupe).

**Сценарий:** имя с подкаталогом (P1-6), слишком длинный путь, нет прав, `.part`
существует как каталог. `createFile`/`FileHandle` падает после `items.append`;
`startDownload` бросает, UI показывает ошибку, но карточка остаётся
«Downloading…», а повтор блокируется как «This file is already downloading».
`pauseDownload` для неё ничего не делает (`activeTasks[id] == nil`), помогает
только Cancel.

**Минимальное исправление:** открывать файл до `items.append`; при ошибке
удалять/помечать элемент failed; либо оборачивать весь участок в do/catch с
откатом.

### P2-5. Runtime package с id, начинающимся с точки, устанавливается, но не виден

**Где:** `RuntimePackageInstaller.swift:13-17` (`validID` разрешает `.foo`),
`:94-102` (публикация в `root/.foo`); `RuntimeStore.swift:347-349`
(`reload` пропускает все каталоги с `.`).

**Сценарий:** пакет с `runtime.json` `"id": ".metal-custom"` проходит
`validID`, `installFolder` публикует `.metal-custom`; `reload()` его пропускает;
UI не показывает runtime. Повторная установка падает «already installed», потому
что destination существует; удалить через UI нельзя. То же для id, начинающихся
с `.install-`/`.extract-`/`.download-`.

**Impact:** «успешная» установка, которую нельзя выбрать/удалить; забитое место.

**Минимальное исправление:** запретить ведущую `.` и зарезервированные префиксы
в `validID`; в `reload` пропускать только известные временные префиксы, а не все
скрытые каталоги.

### P2-6. Временные артефакты не убираются после краша/отмены

**Где:** `RuntimeStore.swift:91` (`.download-*.tar.gz`), `:135`
(`.extract-*`), `RuntimePackageInstaller.swift:89` (`.install-*`), `:135`;
`RuntimeStore.swift:347-349` (скрытые пропускаются); `LocalDownloadManager.swift:115`
(`.part`), `:200-202` (`clearFinished` его не удаляет).

**Сценарий:** приложение убито/упало во время установки runtime или загрузки
модели. Остаются многогигабайтные `.download-*`, `.extract-*`, `.install-*`,
`.part`. При следующем запуске никто их не сканирует и не удаляет; они не видны
в UI. Через несколько попыток диск заполняется; старый `.part` затем может быть
слепо возобновлён (P2-1).

**Impact:** утечка диска, невозможность новых загрузок/установок.

**Минимальное исправление:** GC при старте: удалять временные артефакты старше
N часов/при отсутствии активной операции; для `.part` — либо sidecar-метаданные,
либо удаление при отсутствии элемента; логировать освобождённое место.

### P2-7. Миграция 6.0.0 делает backup после возможной перезаписи и ставит marker даже при неудаче

**Где:** `LocalAIMigration.swift:5-8` (обещание «runs before any store rewrites»),
`:27` (`LocalModelStore.shared.metadataDirectory` — инициализация store),
`:48` (`CodexGatewayService.shared.configPath` — инициализация gateway),
`:56-64` (копирование `models.json`), `:83-85` (marker пишется через `try?`);
`LocalModelStore.swift:19-24` (init → `loadRegistry`), `:489-544`
(`loadRegistry` при repair вызывает `saveRegistry`), `CodexGatewayService.swift:113-118`
(init пишет `gatewayPort`, API key, удаляет legacy-ключ); `MelonToolsApp.swift:117-124`.

**Сценарий:** у пользователя есть `models.json` (6.0.0 beta/previous build).
`runIfNeeded` первой строкой инициализирует store; `loadRegistry` читает,
«ремонтирует» метаданные и сохраняет файл. Только после этого миграция копирует
`models.json` — backup уже не отражает состояние до 6.0.0. `CodexGatewayService`
успевает изменить `UserDefaults` до копирования `preferences.plist`. Если
копирование config/registry/prefs не удалось (нет места/прав), marker всё равно
записывается, и повторной попытки не будет.

**Impact:** backup не пригоден для rollback; «успешная» миграция без backup;
потеря исходного registry при последующих изменениях.

**Минимальное исправление:** вычислять пути без инициализации shared-сервисов;
запускать миграцию до `LocalModelStore`/`CodexGatewayService`; проверять каждую
копию (размер/хеш), писать marker только после успеха; хранить manifest с
путями/хешами; предусмотреть restore.

### P2-8. Хеширование и перемещение моделей выполняются на главном actor

**Где:** `LocalDownloadManager.swift:56` (`@MainActor`), `:350-353`
(`Self.sha256Hex` синхронно), `:366` (`moveItem`), `:60`, `:284-300`
(обновление `@Published items` на каждый чанк); `LocalModelStore.swift:516`
(парсинг каждого GGUF при старте на main).

**Сценарий:** скачана модель 20 ГБ с LFS-дайджестом. После завершения
`handleTaskCompleted` считает SHA-256 на главном потоке — десятки секунд
«Verifying…», окно не отвечает, pause/cancel не обрабатываются, данные других
загрузок копятся. Если `modelsDirectory` на другом томе, `moveItem` там же
копирует гигабайты на main. В обычной загрузке каждый чанк мутирует `items` и
дёргает SwiftUI.

**Impact:** зависание UI, невозможность отмены, таймауты/гонки колбэков,
значимая деградация на больших моделях.

**Минимальное исправление:** hash — в `Task.detached`, `moveItem`/copy — вне
main actor; обновлять прогресс батчами (например, 2–4 раза/с), а не на каждый
чанк; `loadRegistry`-парсинг — в фоне с публикацией результата.

### P2-9. Гонки состояний pause/cancel с завершением задачи

**Где:** `LocalDownloadManager.swift:169-175` (pause), `:208-220` (cancel),
`:302-324` (completion), `:308` (нет проверки `item.state`).

**Сценарий:** пользователь нажимает Pause/Cancel в момент, когда задача уже
успела завершиться. `handleTaskCompleted` не проверяет состояние и может:
- при успехе — проверить/переместить файл и зарегистрировать модель, хотя
  карточка `.paused`/`.cancelled`;
- при ошибке — перезаписать `.paused` на `.failed`;
- `cancelDownload` после успеха удаляет `.part` (его уже нет) и ставит
  `.cancelled`, хотя модель установлена.

**Impact:** ложные состояния, «удалённая» модель остаётся, «paused» становится
failed; пользователь не понимает, что установлено.

**Минимальное исправление:** проверять `item.state` в `handleResponse`/
`handleDataReceived`/`handleTaskCompleted`; финализировать только из
`.downloading/.verifying`; сверять идентичность задачи (id уже уникален);
сделать pause/cancel идемпотентными; после cancel не позволять completion
регистрировать модель.

---

## P3

### P3-1. Неверная таблица `general.file_type` для 36–40

**Где:** `GgufMetadata.swift:65-78`. Код: `36: Q4_0_4_8`, `37: Q4_0_8_8`,
`38: TQ1_0`, `39: TQ2_0`, `40: MXFP4`. Актуальный `llama_ftype`:
`36 TQ1_0`, `37 TQ2_0`, `38 MXFP4_MOE`, `39 NVFP4`, `40 Q1_0` (плюс `41 Q2_0`,
`42 F8_E4M3`). Проверено по `include/llama.h` upstream для закреплённого `b12099` и для master — значения совпадают.

**Impact:** неверный бейдж квантования и суффикс id (`uniqueModelID` использует
`metadata.quantization`), поиск/сортировка; на работу движка не влияет.

**Исправление:** обновить таблицу и добавить тест на 36–40; не полагаться на
устаревшие удалённые значения 33–35.

### P3-2. `#`/`?` в имени HF-файла обрезают URL

**Где:** `HuggingFaceService.swift:248` (`URL(string: ".../\(rfilename)")!`).
Проверено: имя `model#1.gguf` даёт URL с фрагментом (`path` = `.../model`),
`model?x.gguf` — query; запрос уходит не на тот файл (404/чужой ресурс).
Пробелы/кириллица кодируются нормально; force unwrap для них не падает, но
контрольные/невалидные последовательности могут дать nil.

**Impact:** не скачиваются валидные файлы с `#`/`?`; возможна загрузка не того
объекта.

**Исправление:** собирать URL через `URLComponents`/`percentEncodedPath`,
проверять `URL` без `!`, отклонять файлы с недопустимыми именами.

### P3-3. Ошибка сохранения токена Keychain игнорируется, старый токен удаляется первым

**Где:** `LocalModelStore.swift:120-127` (`_ = save...`, затем
`hfTokenConfigured = true`); `LocalKeychainHelper.swift:10-12`
(`deleteHuggingFaceToken()` до `SecItemAdd`), `:22`.

**Сценарий:** Keychain заблокирован/доступ запрещён. `save` возвращает false,
но UI показывает «Saved» и `hfTokenConfigured = true`; при этом старый токен уже
удалён. Gated-загрузки падают 401, пользователь не понимает почему.
**Исправление:** `SecItemUpdate`/add без предварительного delete, проверять
`OSStatus`, возвращать ошибку в UI, не менять `hfTokenConfigured` при неудаче.

### P3-4. Контекст скачанной модели: `configuredContext` и `userSettings` расходятся

**Где:** `LocalDownloadManager.swift:388-401`: `configuredContext =
min(8192, metadata.contextLength)`, но `userSettings =
defaultSettings(forContext: 8192)`. `LocalInferenceService.swift:440` берёт
`settings.contextLength` для `ctx-size`; `LocalModelsView` показывает
`userSettings.contextLength`. Для модели с native context 4096 UI/движок
получают 8192. `LocalModelStore.swift:696` (sync import) — та же ошибка.
**Impact:** неверный context в UI/пресете, возможные предупреждения/деградация
или отказ модели, если движок не принимает context > native.
**Исправление:** использовать один `workingContext` для `configuredContext`,
`userSettings.contextLength` и UI; синхронизировать при импорте/загрузке/ремонте
реестра.

### P3-5. Документация и тесты содержат неверные/непроверенные утверждения

- `docs/LOCAL_AI_ARCHITECTURE.md:51-53`: «суффикс добавляется автоматически…
  никогда не делят один API-идентификатор» — неверно для download
  (`LocalDownloadManager.swift:372-374`) и sync import (`LocalModelStore.swift:672`).
- `docs/LOCAL_AI_ARCHITECTURE.md:76-78`: «каталог можно перенести» — кода переноса
  нет (P1-3).
- `LocalAIMigration.swift:5-8`: «runs before any store rewrites a file» — неверно
  (P2-7); `:90` «shown in Settings» — `latestBackup` нигде не используется.
- `LocalDownloadManager.swift:55`: «Background download manager» — используется
  `URLSessionConfiguration.default` (`:66`), не background; при завершении
  приложения загрузка не продолжается.
- `LocalDownloadManager.swift:96-97`: «two concurrent starts could write the same
  .part file» — для другого repo/регистра это по-прежнему возможно.
- `LocalDownloadManager.swift:274-275`: комментарий «Returns nil for the `*`
  form» противоречит коду/тесту (`bytes */4096` → 4096).
- `LocalModelStore.swift:51-53` docs claim; `LocalModelStore.swift:465-485`
  helper есть, но не применён в download/sync.

**Тесты:** `MacOS/app/MelonToolsTests/LocalAITests.swift` покрывает в основном
чистые helper'ы: content-range (`:150-169`), GGUF happy path (`:173-209`),
repositoryID (`:221-233`), SHA (`:236-245`), shard parsing (`:302-315`), runtime
digest/manifest (`:319-351`), package validation (`:437-627`), catalog parse
(`:665-722`). Нет тестов на:
`LocalDownloadManager.startDownload/pause/resume/cancel`, коллизии имён,
path traversal, повторный resume/416, split download, `LocalAIMigration`,
`setCustomModelsDirectory`, скрытый runtime id, malformed GGUF array/overflow,
`LocalModelStore.prepareImport` при ошибке копирования, Keychain failure.
`testRuntimeCatalogInstallEndToEnd` (`:728-755`) по умолчанию skip.
`testShardNameParsing` проверяет только парсер, но не полноту набора и не
использование `total`. `testGgufParserRejectsForeignFiles` — только 4 байта,
не truncation/array. `testLocalModelCodableRoundtrip` использует default date
strategy, тогда как registry — ISO8601; совместимость не проверяется.
`testRuntimeFolderInstall...` не проверяет `.foo`; `testRuntimeArchive...` не
проверяет `..`/absolute/hardlink/отмену. `test-fetch-runtime.sh` проверяет
`--check`/sandbox, но не adversarial tar.

---

## Что проверено и признано корректным (чтобы не переусердствовать с P)

- **Archive security `RuntimePackageInstaller.installArchive`:** проверка
  `tar -tzf` отвергает absolute/`..`; `tar -tvzf` требует первый символ `-`/`d`,
  поэтому symlink (`l`) и hardlink (`h`) отвергаются; digest проверяется до
  распаковки; extraction в `.extract-*`, затем `.install-*`; нет выполнения
  кода. Локально проверен вывод BSD tar для hardlink: строка начинается с `h`;
  обхода через hardlink не найдено. Остаточные риски: нет проверки свободного
  места под 16 ГиБ распаковки, доверие к `tar`-listing, TOCTOU для локального
  файла (same-user).
- **Authorization при редиректе:** локальный тест `URLSession` (302 на другой
  origin) показал, что `Authorization` не пересылается; утечки HF-токена через
  redirect не найдено. Токен идёт только в header к `huggingface.co`; в логи/
  конфиг/`DownloadItem` не попадает; Keychain — `AfterFirstUnlockThisDeviceOnly`;
  миграция HF-токен не копирует.
- **LFS/hash/size:** при наличии `lfs.sha256` сравнение корректное; при `200`
  после `If-Range` есть truncate; `Content-Range` total парсится; для 206
  `expectedContentLength` не используется как total.
- **Runtime catalog:** digest берётся из того же GitHub API-ответа, размер
  проверяется после скачивания, SHA — до merge; `installFolder` проверяет
  `runtime.json`, backend/platform, SHA бинарника, нативную архитектуру;
  существующий runtime в `runtime/` не перезаписывается.
- **fetch-runtime.sh:** pinned digests до скачивания, staging, проверка
  universal/digest/signature, atomic swap, `safe_rm_rf` с ограничением корней,
  отказ от symlink DEST; тестовый sandbox есть.
- **Локальные модели:** `removeModel` возвращает список неудалённых файлов;
  импорт async выполняет копирование/чтение metadata вне main actor; `loadRegistry`
  перепроверяет наличие файлов.

## Что не проверялось

- `xcodebuild`/полный тестовый набор не запускались (по условию — не параллельно
  родителю; фактически не запускались вовсе). Реальные скачивания, llama-server,
  runtime-установки, UI и внешние тома не использовались.
- Полное ТЗ 6.0.0 отсутствует; `docs/*` — только документация, не спека.
- Не проверялись Windows-реализация, `LocalInferenceService` целиком,
  `CodexGatewayService`, `ModelSources` (кроме точек стыка), подпись/нотаризация,
  sandbox/TCC, производительность на реальных 20+ ГБ моделях.
- Не воспроизводились гонки main-actor колбэков под нагрузкой; вывод о
  потенциальном переупорядочении `didReceive data` — теоретический, требует
  stress-теста. Не проверялись реальные HF-имена с `#`/`?`/подкаталогами;
  path traversal зависит от доверия к HF API.
- `fetch-runtime.sh` не исполнялся (сеть/мутации); вывод по коду и отдельным
  tar-экспериментам. Adversarial fuzzing архивов не проводился.

## Приоритетный порядок исправлений

1. P1-1/P1-2: атомарная публикация, уникальные имена/id, запрет overwrite.
2. P1-5: bounds/`Int(exactly:)`/seek в GGUF, парсинг вне main.
3. P1-3: реальная миграция каталога + проверка тома/файлов.
4. P1-4: группировка и полнота split.
5. P1-6: basename/canonical path.
6. P2-1/P2-3: sidecar resume + atomic replace/space/off-main.
7. P2-5/P2-6/P2-7: hidden runtime, GC temp, migration order.
8. P2-8/P2-9: off-main hash/move, state guards.
9. P3: map/URL/Keychain/context/docs/tests.
