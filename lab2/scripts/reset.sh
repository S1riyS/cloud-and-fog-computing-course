#!/usr/bin/env bash
# Полный сброс стенда: остановка, удаление контейнеров и томов (данные Elasticsearch, логи). Папка evidence/ не трогается.
cd "$(dirname "$0")/.." || exit 1
docker compose --profile tools down -v --remove-orphans
