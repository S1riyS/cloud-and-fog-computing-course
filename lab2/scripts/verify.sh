#!/usr/bin/env bash
# Проверка формата сдачи перед отправкой (содержательные ответы не проверяются).
cd "$(dirname "$0")/.." || exit 1
command -v python3 >/dev/null 2>&1 || { echo "python3 не найден: проверьте evidence.json вручную"; exit 0; }
python3 - <<'PY'
import json, re, sys, os
errs = []
try:
    ev = json.load(open("evidence.json", encoding="utf-8"))
except Exception as e:
    sys.exit(f"evidence.json не читается: {e}")
allowed = ev.get("_allowed", {})
for k in ("run_id", "first_error_time_utc", "failing_service", "root_cause_class", "trap_class"):
    if not str(ev.get(k, "")).strip():
        errs.append(f"не заполнено поле {k}")
for k in ("failing_service", "root_cause_class", "trap_class"):
    if ev.get(k) and allowed.get(k) and ev[k] not in allowed[k]:
        errs.append(f"{k}: допустимые значения {allowed[k]}")
if not (ev.get("key_metric") or {}).get("query"):
    errs.append("key_metric.query пуст")
if not ev.get("trace_ids"):
    errs.append("trace_ids пуст")
for f in ("evidence/loadgen_result.json", "evidence/loadgen_after.json", "report.md"):
    if not os.path.isfile(f):
        errs.append(f"нет файла {f}")
if os.path.isfile("report.md"):
    t = open("report.md", encoding="utf-8").read()
    for n in range(6):
        if not re.search(rf"^##\s*{n}\.", t, re.M):
            errs.append(f"в report.md нет раздела '## {n}.'")
print("\n".join("[!] " + e for e in errs) if errs else "Формат сдачи в порядке.")
sys.exit(1 if errs else 0)
PY
