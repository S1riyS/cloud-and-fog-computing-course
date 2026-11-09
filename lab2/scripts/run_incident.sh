#!/usr/bin/env bash
# Прогон нагрузки: фиксированный объём запросов (прогрев кэша, затем спокойная фаза, всплеск и хвост).
# Использование: run_incident.sh [--phase before|after]. before создаёт тикет; after повторяет ту же нагрузку после исправления.
cd "$(dirname "$0")/.." || exit 1
phase=before
[ "${1:-}" = "--phase" ] && phase="${2:-before}"
mkdir -p evidence
export LOCAL_UID=$(id -u) LOCAL_GID=$(id -g)
docker compose --profile tools run --rm -T loadgen --phase "$phase"
