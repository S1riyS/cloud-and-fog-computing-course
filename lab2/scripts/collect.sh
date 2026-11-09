#!/usr/bin/env bash
# Сбор артефактов и упаковка сдачи: submission_<student_id>.zip (evidence.json, report.md, evidence/, screenshots/).
cd "$(dirname "$0")/.." || exit 1
mkdir -p evidence
docker compose ps > evidence/compose_ps.txt 2>&1
docker version > evidence/docker_version.txt 2>&1
bash scripts/probe.sh > evidence/probe.json 2>&1
cp .env evidence/env.txt
for f in evidence/loadgen_result.json evidence/loadgen_after.json evidence.json report.md; do
  [ -f "$f" ] || echo "ВНИМАНИЕ: нет файла $f"
done
sid=$(sed -n 's/.*"student_id": *"\([^"]*\)".*/\1/p' evidence.json | head -1)
out="submission_${sid:-student}.zip"
rm -f "$out"
items="evidence.json report.md evidence"
[ -d screenshots ] && items="$items screenshots"
if command -v zip >/dev/null 2>&1; then zip -qr "$out" $items -x 'evidence/.gitkeep'
elif command -v python3 >/dev/null 2>&1; then python3 -m zipfile -c "$out" $items
else tar czf "${out%.zip}.tar.gz" $items; out="${out%.zip}.tar.gz"; fi
echo "Готово: $out"
