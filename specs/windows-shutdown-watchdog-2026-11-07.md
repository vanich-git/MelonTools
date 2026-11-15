# SPEC — Windows: выход, watchdog и блокирующая детекция (W6–W10)

Задача: закрыть пункты W6–W10 из `AUDIT-LOCAL-AI-2026-11-07.md` (§2.2 и §5)
в Windows/Tauri-бэкенде. Режим: SpecLoop, запись — этот файл; зонтичная спека —
`specs/local-ai-audit-remediation-2026-11-07.md` (не перезаписывается).

## SPEC

### Область

Ровно три файла, всё остальное — вне правок:

- `Windows/app/src-tauri/src/main.rs`
- `Windows/app/src-tauri/src/gateway.rs`
- `Windows/app/src-tauri/src/local_ai/hardware.rs`

`local_ai/local_runtime.rs` и `local_ai/system_prompt_proxy.rs` в это время правят
другие агенты — они только читаются. `Cargo.toml` не меняется, новых зависимостей
нет, сборка/тесты не запускаются (запрещено постановкой), коммитов нет.

### Критерии приёмки (из зонтичной спеки)

- **W6.** Выход ограничен по времени (5 с); по истечении — запись в лог, приложение
  не висит; движок не остаётся держать модель.
- **W7.** Счётчик рестартов сбрасывается после устойчивого здоровья (N успешных
  тиков), состояние «watchdog выключен» видно в существующем статусе/логе, а не
  только в памяти.
- **W8.** После начала выхода тик не стартует шлюз (флаг `shutting_down`/проверка
  под тем же замком, что и остановка).
- **W9.** Повторный `gateway::stop` идемпотентен и не запускает `taskkill /IM`
  второй раз.
- **W10.** Длинная (до 8 с) детекция железа выполняется вне удерживаемого замка;
  результат публикуется после повторной проверки ревизии.

### Найденное поведение (до правок)

- `main.rs`, `RunEvent::Exit` и пункт меню `quit` вызывали
  `block_on(runtime.stop())` без таймаута. `stop()` ждёт `lifecycle`-мьютекс,
  который `load_model` держит минутами.
- `watchdog_check` при `restarts >= 3` молча выходил: счётчик не сбрасывался,
  причина не попадала ни в статус, ни в лог.
- Тик супервизора проверял только `user_stopped`, затем 15-секундный health-probe
  и `gateway::start`; остановка на выходе могла произойти внутри этого окна.
- `gateway::stop` при каждом вызове заново читал PID-файл и, если его нет,
  прогонял `taskkill /IM` по всем `SIDECAR_NAMES`. На выходе он вызывается дважды
  (quit → `app.exit` → `RunEvent::Exit`), а также из апдейтера.
- `local_ai/local_runtime.rs:2763` (`load_model`) держит `self.lifecycle.lock()`,
  а на строке `2856` вызывает синхронный `detect_hardware(Some(&models_dir))`,
  который может занять до 8 с (PowerShell) — под этим замком.

## EVIDENCE

- `tauri::async_runtime::block_on` → `GlobalRuntime::block_on` →
  `TokioRuntime::block_on` на `tokio::runtime::Runtime::new()`, т.е. с драйвером
  времени: `tokio::time::timeout` внутри `block_on` срабатывает.
- `tokio` уже собран с `time`; `spawn_blocking` уже используется в проекте
  (`gateway.rs:1176`, `local_runtime.rs:978`).
- Крейтов `log`/`tracing` в `Cargo.toml` нет: проект пишет через `eprintln!` с
  префиксами `[gateway]` / `[local-ai]` / `[watchdog]`. Требования «`error!`» и
  «`warn!`» реализованы как префиксные `eprintln!` — отклонение от буквы, не от
  смысла (сообщение видно в stderr и в логах запуска).
- `Gateway` (`gateway.rs:17`) хранит только `child: Mutex<Option<Child>>` и
  `started_generation`; публичного признака «уже остановлен» не было.
- `Watchdog` (`main.rs:78`) сериализуется целиком в `gateway_status`
  (`main.rs:198`), поэтому новое не-`skip` поле автоматически доходит до UI.
- У `LocalRuntimeManager` нет публичного `force_stop`/`terminate` — только
  `stop()` (`local_runtime.rs:2617`), поэтому таймаут не может «дожать» движок
  вторым способом.
- `engine_job.rs` держит Windows Job Object с `KILL_ON_JOB_CLOSE` для каждого
  запущенного движка: при завершении процесса ядро убьёт детей. Это и есть
  страховка на случай таймаута; следующий запуск добивает по записанному PID.

## BUILD

### W6 — ограниченная остановка Local AI

- `main.rs:114` — `const RUNTIME_STOP_BUDGET: Duration = Duration::from_secs(5)`.
- `main.rs:143` — `stop_runtime_bounded(state: &AppState) -> bool`:
  `tauri::async_runtime::block_on(tokio::time::timeout(RUNTIME_STOP_BUDGET,
  state.local_runtime.stop()))`; на `Err(Elapsed)` — `eprintln!("[local-ai] stop
  did not finish in 5 s; exiting anyway (the next launch reaps the engine)")` и
  `false`. Паники/`unwrap` нет.
- `main.rs:68` — `AppState::runtime_stop_attempted: AtomicBool`: один бюджет на
  выход. Трей останавливает движок, затем `RunEvent::Exit` вызывает тот же путь;
  второй пятисекундный wait только удвоил бы худший случай, не освободив ничего.
- `main.rs:1998` (quit) и `main.rs:2870` (`RunEvent::Exit`) — вызов хелпера.
- Форс-килла нет по факту API; вместо него — громкий лог + job object + reap при
  следующем старте (задокументировано в doc-комментарии хелпера).

### W7 — сброс и видимость watchdog

- `main.rs:78` — в `Watchdog` добавлены `healthy_streak: u32` (`#[serde(skip)]`)
  и `disabled_reason: Option<String>` (сериализуется как `disabledReason`).
- `main.rs:105/109` — `WATCHDOG_MAX_RESTARTS = 3`,
  `WATCHDOG_RESET_AFTER_TICKS = 20` (20 × 30 с = 10 минут здоровья).
- `main.rs:1791` — при исчерпанном бюджете один раз пишется
  `disabled_reason = "off after 3 restarts"` и `eprintln!` с числом рестартов;
  дальше ранний выход, как раньше.
- `main.rs:1809` — успешный health-тик: `healthy_streak += 1`, при достижении
  порога `restarts = 0`, `healthy_streak = 0`, `disabled_reason = None`. Пока
  `restarts == 0`, счётчик держится нулём (не растёт бесконечно).
- `main.rs:371` — ручной старт (`start_gateway`) сбрасывает `restarts`,
  `healthy_streak` и `disabled_reason`.

### W8 — `shutting_down` против гонки на выходе

- `main.rs:63` — `AppState::shutting_down: AtomicBool`.
- `main.rs:125` — `begin_shutdown()`: сначала `shutting_down = true`, затем под
  `watchdog`-замком `user_stopped = true, supervised = false, health_ok = false`.
- `main.rs:1996` (quit) и `main.rs:2861` (`RunEvent::Exit`) — вызов первым
  действием, до `gateway::stop`.
- `main.rs:1777/1788` — `watchdog_check` читает флаг в начале и выходит, если он
  взведён.
- `main.rs:1890` — непосредственно перед `gateway::start` (после 15-секундной
  пробы) повторно проверяются `user_stopped`/`restarts` под `watchdog`-замком и
  `shutting_down`. `std::sync::Mutex` через `.await` не удерживается.
- `main.rs:1901` — после `gateway::start` ещё одна проверка: если выход случился,
  пока старт был в полёте, движок останавливается повторно
  (идемпотентный `gateway::stop`, см. W9) и учёт рестарта не ведётся.
- `main.rs:1840` — та же пост-проверка в ветке ротации лога.
- `main.rs:2608` — тик Local AI супервизора: `user_stopped || shutting_down` перед
  стартом и повторный `gateway::stop` после, если выход начался во время старта.

### W9 — идемпотентный `gateway::stop`

- `gateway.rs:17` — в `Gateway` добавлено `stopped: Mutex<bool>`.
- `gateway.rs:41` — `mark_running()` сбрасывает флаг; вызывается на обеих
  успешных ветках `start`: adopt (`gateway.rs:1239`) и spawn (`gateway.rs:1299`).
- `gateway.rs:1317` — `stop` берёт `stopped` под замок, при `true` сразу
  возвращает `Ok("already stopped")`, не трогая child/PID-файл и не запуская
  `taskkill /IM`. Иначе выполняет прежнюю уборку и ставит флаг в конце.
- Замок сериализует одновременные выходы (quit и `RunEvent::Exit`), поэтому
  второй вызов не гоняется с первым за PID-файл.
- Флаг сбрасывается и при неудачном старте не взводится: `mark_running` стоит
  после успешного spawn/adopt, так что «stopped → start упал → stop» не считается
  повтором, если движок всё-таки был запущен частично (child лежит в `Gateway`).

### W10 — детекция железа вне async-воркера (частично, см. LOOP)

- `hardware.rs:653` — `pub async fn detect_hardware_async(models_dir:
  Option<PathBuf>) -> HardwareInfo`: `tokio::task::spawn_blocking` вокруг
  синхронного `detect_hardware`; при `JoinError` — лог и повторная синхронная
  детекция (без паники). `PathBuf` нужен, потому что `LocalModelStore::models_dir()`
  возвращает владеемый путь.
- Обёртка **не подключена**: единственный вызов под замком находится в
  `local_runtime.rs`, который запрещён к правке.

## REVIEW

Самопроверка (сборка запрещена, поэтому статически):

1. `rustfmt --edition 2021 --check` по трём файлам: синтаксис валиден, мои участки
   совпадают с форматированием (единственные diff'ы — в чужом `local_runtime.rs`).
2. Сигнатуры: `stop` по-прежнему `fn(&Gateway) -> Result<String, String>`, все
   вызовы в `main.rs` не менялись; `start` не менял контракт.
3. `Watchdog` — `Default + Clone + Serialize`; новые поля либо `skip`, либо
   `Option<String>`, поэтому `gateway_status` не ломается.
4. `AtomicBool`/`Ordering` импортированы; `Duration` уже был в области видимости;
   `tokio::time::timeout` доступен по фиче `time`.
5. Ни один `std::sync::Mutex` не удерживается через `.await`: проверки перед
   стартом берут замок коротким блоком, `shutting_down` — атомик.
6. Гонка «выход во время старта» закрыта дважды: проверка до старта и откат после.
7. Идемпотентность `stop` не мешает апдейтеру: он вызывает `stop` до свопа exe,
   затем `RunEvent::Exit` получает `"already stopped"`.
8. Риск: `stop` теперь держит `stopped` на время `taskkill` (до нескольких секунд).
   Второй параллельный вызов ждёт и получает `"already stopped"` — это и требуется;
   дедлока нет, других владельцев этого замка нет.
9. Риск: `detect_hardware_async` при паннике блокирующей задачи повторяет
   синхронную детекцию на async-потоке. Путь аварийный, в норме недостижим;
   выбран сознательно, чтобы не выдумывать CPU-профиль и не менять backend.

Что осталось за границей правок:

- `local_runtime.rs:2763` держит `lifecycle` на весь `load_model`, а `:2856`
  вызывает `detect_hardware` под ним. Пока вызов не перенесён, W10 закрыт только
  наполовину: обёртка есть, потребителя нет.

## LOOP

| ID | Вердикт | Файл:строки | Что сделано |
|----|---------|-------------|-------------|
| W6 | PASS | `main.rs:114,143,1998,2871` | 5-секундный бюджет на `runtime.stop()` в обоих путях выхода, лог при таймауте, один бюджет на процесс |
| W7 | PASS | `main.rs:78,105,109,371,1791,1810` | сброс `restarts` после 20 здоровых тиков, `disabledReason` в `gateway_status`, однократный `eprintln!` |
| W8 | PASS | `main.rs:63,125,1777,1890,1901,2619,2861` | `shutting_down` + перепроверка под замком перед стартом и откат после |
| W9 | PASS | `gateway.rs:17,41,1239,1299,1317` | флаг `stopped`, ранний `Ok("already stopped")`, без повторного `taskkill /IM` |
| W10 | BLOCKED | `hardware.rs:653`; блокирующее место — `local_runtime.rs:2763,2856` | добавлена `detect_hardware_async`, но вызов под замком в запрещённом файле; нужен перенос вызова/`await` обёртки/кэш `HardwareInfo` |

### Предлагаемый патч для W10 (в `local_runtime.rs`, вне моей зоны)

Вынести детекцию до захвата `lifecycle` и передать результат в `load_model`:

```rust
pub async fn load_model(&self, model_id: &str) -> Result<(), String> {
    let (generation, mut cancelled) = self.begin_lifecycle();
    let models_dir = LocalModelStore::models_dir();
    // 8 s PowerShell probe, off the lock and off the async worker.
    let hw = detect_hardware_async(Some(models_dir.clone())).await;
    let _guard = self.lifecycle.lock().await;
    if !self.is_current_generation(generation) {
        return Err(Self::superseded_message());
    }
    ...
    // publish only after the generation re-check above
}
```

и убрать `let hw = detect_hardware(Some(&models_dir));` со строки 2856.
Альтернатива без изменения порядка: кэшировать `HardwareInfo` в менеджере и
обновлять его фоновой задачей. Критерий «результат публикуется после повторной
проверки ревизии» выполняется существующей проверкой `is_current_generation`.
