#!/bin/bash
# Запуск cargo check и параллельная очистка AppleDouble файлов
TARGET_DIR="Windows/app/src-tauri/.cargo-target-windows"

cd Windows/app/src-tauri

# Запускаем cargo в фоне, записываем pid
cargo check --offline &
CARGO_PID=$!

# Пока cargo работает, чистим файлы
while kill -0 $CARGO_PID 2>/dev/null; do
    find "$TARGET_DIR" -name "._*" -delete 2>/dev/null
    sleep 0.1
done

# Дожидаемся завершения
wait $CARGO_PID
