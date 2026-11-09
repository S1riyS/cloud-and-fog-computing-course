#!/usr/bin/env bash
# Сборка и запуск стенда; ждёт готовности всех сервисов (первый запуск 5-10 минут: скачивание образов, наполнение БД).
cd "$(dirname "$0")/.." || exit 1
mkdir -p evidence
if ! docker compose up -d --build --wait --wait-timeout 900; then
  echo "Стенд не поднялся. Диагностика: docker compose ps; docker compose logs <сервис>" >&2
  docker compose ps
  exit 1
fi
bash scripts/post_up.sh        # настройка интерфейса логов (зависит от стека)
echo "Стенд готов. Адреса интерфейсов: см. variant.md"
