#!/usr/bin/env bash
# Проверка окружения перед запуском стенда. Вывод сохраняется в evidence/preflight.txt (приложите к отчёту).
cd "$(dirname "$0")/.." || exit 1
mkdir -p evidence
fail=0
ok()   { echo "[ ok ] $*"; }
warn() { echo "[warn] $*"; }
bad()  { echo "[FAIL] $*"; fail=1; }
{
  echo "== preflight $(date -u +%FT%TZ) =="
  uname -a
  if command -v docker >/dev/null 2>&1; then ok "docker: $(docker --version)"; else bad "docker не найден"; fi
  if docker compose version >/dev/null 2>&1; then ok "docker compose: $(docker compose version --short)"; else bad "нужен Docker Compose v2 (команда 'docker compose')"; fi
  if docker info >/dev/null 2>&1; then
    mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null)
    if [ -n "$mem" ] && [ "$mem" -ge 6000000000 ]; then ok "память Docker: $((mem/1024/1024)) МиБ"; else warn "память Docker ${mem:-?} Б; рекомендуется >= 6 ГиБ (стенд ~4.5 ГиБ)"; fi
    echo "архитектура: $(docker info --format '{{.Architecture}}')"
    mm=$(docker run --rm alpine cat /proc/sys/vm/max_map_count 2>/dev/null)
    if [ -n "$mm" ] && [ "$mm" -ge 262144 ]; then ok "vm.max_map_count=$mm"; else bad "vm.max_map_count=${mm:-?} < 262144 (нужно для Elasticsearch): sysctl -w vm.max_map_count=262144"; fi
  else
    bad "демон Docker недоступен"
  fi
  for p in $(cat scripts/ports.txt 2>/dev/null || echo '3001 5601 8081 9090'); do
    if (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null; then bad "порт $p занят"; else ok "порт $p свободен"; fi
  done
  command -v curl >/dev/null 2>&1 && ok "curl найден" || bad "curl не найден"
  command -v python3 >/dev/null 2>&1 && ok "python3 найден" || warn "python3 не найден: scripts/verify.sh и упаковка отчёта будут ограничены"
  [ "$fail" -eq 0 ] && echo "ИТОГ: окружение готово" || echo "ИТОГ: есть проблемы (FAIL), исправьте и опишите в отчёте"
} 2>&1 | tee evidence/preflight.txt
n=$(grep -c '^\[FAIL\]' evidence/preflight.txt)
[ "$n" -eq 0 ]
