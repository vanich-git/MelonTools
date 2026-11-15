#!/bin/bash
# Обертка для cargo check, которая удаляет файлы AppleDouble перед запуском,
# чтобы обойти баг tauri build.rs на exFAT.

TARGET_DIR="Windows/app/src-tauri/.cargo-target-windows"

if [ -d "$TARGET_DIR" ]; then
    find "$TARGET_DIR" -name "._*" -delete
fi

cd Windows/app/src-tauri && cargo check --offline
