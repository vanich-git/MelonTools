# RSS lifecycle `llama-server` b12099: один router pid, 15 циклов

**Дата:** 2026-11-04  
**Система:** macOS 27.0 (26A428), arm64  
**Движок:** `/Applications/Melon Tools.app/Contents/Resources/runtime/llama-server`,
`version: 0.8.0-dev (build 12099, commit bee23322f)`  
**Модель:** `~/Library/Application Support/MelonTools/models/Qwen3.5-2B-BF16.gguf`,
3 775 709 216 байт  
**Изоляция:** порт `18418`, отдельный preset, токен в `--api-key-file`, пустой
временный `LLAMA_CACHE`; установленное приложение и его порт `18317` не
затрагивались.

## Итог

Воспроизведения роста **83 → 110 MB как функции циклов** нет. Стартовые
сэмплы после `/health` были **109.66–110.02 MiB**, baseline после 5 s
стабилизации — **109.47 MiB**; после первого load/unload RSS родителя
упал до ~13 MiB, затем 12 измеряемых циклов держался на **11.25 MiB** (median),
а physical footprint — на **45 MiB**. Роста ни по RSS, ни по footprint, ни по
fd, ни по числу pid после unload не было. Это не «bounded cache leak»: рост
83 → 110 MB в этом сценарии не подтверждён; наблюдаемый высокий уровень
родителя — стартовый пик/переиспользуемые clean-страницы, которые macOS
забирает при загрузке модели.

## Endpoint'ы b12099

По [README b12099](https://github.com/ggml-org/llama.cpp/blob/bee23322f/tools/server/README.md)
router использует:

- `GET /models` — список моделей и `status.value` (`unloaded`, `loading`,
  `loaded`, `sleeping`);
- `POST /models/load` — `{"model": "..."}`;
- `POST /models/unload` — `{"model": "..."}`, ответ `{"success": true}`;
- `POST /models` / `DELETE /models` — скачивание, не использовались.

`/models/unload` в b12099 доступен. Preflight на незагруженной модели вернул
`400 model is not running` — это подтверждает наличие маршрута, а не 404.
Отдельного «unload all» нет; выгружалась одна модель. Ответ `unload`
возвращается до завершения child; статус `unloaded` появляется после выхода
child (см. [server-models.cpp](https://github.com/ggml-org/llama.cpp/blob/bee23322f/tools/server/server-models.cpp)).
Поэтому после каждого unload опрашивались и `/models`, и дерево процессов.
Fallback `--sleep-idle-seconds` не понадобился.

## Методика

Один router pid `33055`, один preset, одна модель. Параметры запуска:
`--models-max 1 --metrics --parallel 1`, контекст `2048` в preset
(`ctx-size = 2048`), `n-gpu-layers = 99`, `reasoning = off`.

- 15 циклов: 3 warmup + 12 измеряемых.
- Цикл: `POST /models/load` → poll до `loaded` и появления child → короткий
  `POST /v1/chat/completions` (`max_tokens: 8`, `temperature: 0`,
  `reasoning_effort: none`, ответ 2 токена) → `POST /models/unload` → poll до
  `unloaded` и отсутствия всех потомков → settle 2 s → 3 сэмпла за 1 s.
- Родитель: RSS через `ps -o rss`; physical footprint через `footprint -p`.
- Дети: рекурсивно по `ppid`; aggregate RSS и количество pid.
- fd: числовые дескрипторы через `lsof -Fn` (строки `f<number>`).
- Начальный idle: 5 s стабилизации после `/health`, затем 30 s baseline.
- Recovery: 60 s после последнего unload, без запросов.
- Stop: `SIGTERM` router, проверка exit code, отсутствия parent/child и
  свободности порта.

## Результаты

### Родитель после unload

| Фаза | parent RSS, MiB | parent footprint, MiB | child count | parent fds |
|---|---:|---:|---:|---:|
| startup (9 сэмплов) | 109.66–110.02 | peak 105.0 → 65.0 | 0 | 10 |
| baseline 30 s | **109.47** | **64.0** | 0 | 10 |
| 12 measured после unload | **median 11.25** (10.88–14.39) | **median 45.0** (45–54) | **0** | **10** |
| recovery 60 s | 11.28–11.50 | 45.0 | 0 | 10 |

Все 15 циклов: `status = unloaded`, child count после unload `0`,
`post_unload_clean = true`. Максимум детей после unload — `0`.

### Загруженная модель (для контекста)

| Показатель | Значение |
|---|---:|
| child aggregate RSS | 3.64–3.76 GiB (median ~3.76 GiB) |
| child count | 1 |
| parent RSS | 10.33–14.38 MiB |
| parent footprint | 45–54 MiB |
| parent fds / child fds | 13 / 16 |
| `/metrics?model=...` | HTTP 200 во всех 12 циклах |

### Тренд и тайминги

- Линейный тренд parent RSS по 12 измеряемым циклам: **−0.246 MiB/цикл**,
  `r = −0.70`, `n = 12`.
- Первый измеряемый → последний: **14.39 → 11.28 MiB** (−3.11 MiB).
- Baseline → последний измеряемый: **−98.19 MiB**.
- Загрузка: median **889 ms** (854–1438 ms).
- Ответ: median **186 ms** (171–322 ms).
- Unload: median **354 ms** (339–388 ms).
- Stop: exit code `0`, shutdown **204 ms**, `leftover_pids = []`, порт `18418`
  свободен.

### vmmap

`vmmap -summary` для родителя: baseline physical footprint **64.5M**,
peak **105.2M**; recovery **45.4M**. Пик 105.2M — стартовый, не циклический.

## Интерпретация

1. **Роста на циклах нет.** После первого load/unload RSS и footprint
   родителей только уменьшились; 12 измеряемых циклов дали стабильную
   площадку. Это не утечка на цикл и не «bounded cache leak».
2. **`ps rss` здесь обманчив.** RSS родителя упал со 109.47 до 11.25 MiB,
   потому что macOS вытеснила/сжала clean-страницы при загрузке 3.7 GiB
   модели. Physical footprint (64 → 45 MiB) подтверждает: реального роста нет.
   Ориентироваться только на RSS в этом сценарии нельзя.
3. **83 → 110 MB не воспроизведён как процесс на 15 циклах.** Стартовые
   сэмплы уже 109.66–110.02 MiB, baseline 109.47 MiB; более раннюю точку
   83 MiB этот прогон не наблюдал. Если 83 → 110 относится к старту
   router/чтению preset, это
   одноразовый пик (vmmap peak 105.2M), а не накопление за load/unload.
4. **Lifecycle чистый.** `/models/unload` доступен, child завершается за
   ~0.35 s, pid count и fd после unload возвращаются к 0/10, parent/child
   после stop отсутствуют. Оснований для ссылки на lifecycle-баг b12099 в
   этом сценарии нет; Swift не редактировался.

## Ограничения

- Одна модель, один Mac, 15 циклов, явный unload; это не доказательство
  отсутствия утечки за часы или на других моделях/контекстах.
- `ps rss` и `footprint` — разные метрики; в отчёте обе, выводы основаны на
  footprint и на отсутствии тренда, а не на одном числе RSS.
- Во время прогона, в 14:33:57, на порту `18318` появился посторонний
  `llama-server` из **Debug**-сборки (`pid 33926`, `ppid 1`, ~47 MB, без
  child). Это не процесс probe (probe запускал installed binary на 18418);
  его parent — launchd (`ppid 1`), а не установленное приложение 68902. Он не
  трогался. Его появление совпало со
  ступенькой footprint 55 → 45 MiB между циклами 6 и 7; на вывод об
  отсутствии роста это не влияет, но это внешний шум.

## Артефакты

- Скрипт: [`run_rss_probe.py`](../MacOS/build/rss-probe/run_rss_probe.py)
- Полный прогон: [`full-20261104-143236`](../MacOS/build/rss-probe/runs/full-20261104-143236)
  - [`cycles.csv`](../MacOS/build/rss-probe/runs/full-20261104-143236/cycles.csv)
  - [`timeline.csv`](../MacOS/build/rss-probe/runs/full-20261104-143236/timeline.csv)
  - [`summary.json`](../MacOS/build/rss-probe/runs/full-20261104-143236/summary.json)
  - `router.log`, `vmmap-baseline.txt`, `vmmap-recovery.txt`, `models.ini`,
    `command.txt`
- Токен создавался в run-каталоге, передавался только через `--api-key-file`,
  удалён после прогона. Поиск 64-hex и `api-key` в артефактах не нашёл токена.
