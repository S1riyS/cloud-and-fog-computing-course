#!/bin/bash
# Инициализация БД: схема и тестовые данные (число строк и пользователей берётся из .env).
set -euo pipefail
psql -v ON_ERROR_STOP=1 -v rows="${DB_ROWS}" -v users="${USERS}" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /sql/init.sql
