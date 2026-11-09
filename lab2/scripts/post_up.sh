#!/usr/bin/env bash
# Создаёт в Kibana data view для логов приложения (app-logs-*).
curl -s -o /dev/null -w "Kibana data view: HTTP %{http_code}\n" -X POST "http://localhost:5601/api/data_views/data_view" \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"override":true,"data_view":{"title":"app-logs-*","name":"app-logs","timeFieldName":"@timestamp"}}'
