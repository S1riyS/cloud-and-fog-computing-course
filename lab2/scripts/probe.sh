#!/usr/bin/env bash
# Печатает JSON с количеством данных в трёх источниках: логи (Elasticsearch), трейсы (Jaeger), метрики (Prometheus).
num() { sed -n 's/.*"count":\([0-9][0-9]*\).*/\1/p'; }
logs=$(curl -s 'http://localhost:9200/app-logs-*/_count' | num)
traces=$(curl -s 'http://localhost:16686/api/traces?service=gateway&limit=20' | grep -o '"traceID"' | wc -l | tr -d ' ')
metrics=$(curl -sG 'http://localhost:9090/api/v1/query' --data-urlencode 'query=sum(http_requests_total)' | grep -c '"value"')
echo "{\"logs\":${logs:-0},\"traces\":${traces:-0},\"metrics\":${metrics:-0}}"
