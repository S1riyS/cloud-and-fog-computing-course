# Отчёт по ЛР2. Корреляция трёх источников

Студент: Анкудинов Кирилл Константинович (413732), группа OTV1 · Стек: ELK + Prometheus + Jaeger

## 0. Стенд

Проверка окружения `bash scripts/preflight.sh` (2026-11-09T16:11:41Z), вывод сохранён в `evidence/preflight.txt`:

```text
== preflight 2026-11-09T16:11:41Z ==
Linux DESKTOP-BCV3LVN 6.6.87.2-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Thu Jun  5 18:30:46 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux
[ ok ] docker: Docker version 28.1.1, build 4eba377
[ ok ] docker compose: 2.35.1-desktop.1
[ ok ] память Docker: 7942 МиБ
архитектура: x86_64
[ ok ] vm.max_map_count=262144
[ ok ] порт 3001 свободен
[ ok ] порт 5601 свободен
[ ok ] порт 8081 свободен
[ ok ] порт 9090 свободен
[ ok ] порт 9200 свободен
[ ok ] порт 16686 свободен
[ ok ] curl найден
[ ok ] python3 найден
ИТОГ: окружение готово
```

С первой попытки стенд не поднялся. `bash scripts/up.sh` скачал образы Elasticsearch, Kibana, Prometheus, Jaeger, PostgreSQL, Redis и экспортёров, затем упал на сборке приложения:

```text
=> CANCELED [payments] exporting to image
=> ERROR [orders] exporting to image
failed to solve: image "docker.io/library/lab2-app:local": already exists
```

`docker compose ps` после этого был пуст: контейнеры не создались. Причина в том, что `gateway`, `orders` и `payments` собирают один и тот же образ `lab2-app:local`, а `scripts/up.sh` передаёт `--build` и запускает эти сборки параллельно. Оба сервиса одновременно доходят до шага `naming to docker.io/library/lab2-app:local`, и BuildKit завершает экспорт с ошибкой «образ уже существует».

Повторный `bash scripts/up.sh` снова пошёл бы в ту же гонку, поэтому образ собран один раз, а стенд поднят без пересборки:

```bash
docker compose build gateway
docker compose up -d --no-build --wait --wait-timeout 900
bash scripts/post_up.sh
```

`docker compose up` дождался healthy у всех сервисов: `prometheus`, `payments`, `postgres`, `elasticsearch`, `jaeger`, `cadvisor`, `redis`, `redis-exporter`, `kibana`, `filebeat`, `orders`, `postgres-exporter`, `gateway`. `bash scripts/post_up.sh` создал data view Kibana `app-logs` и вернул `Kibana data view: HTTP 200`.

## 1. Источники

Успешный `POST /api/checkout`, пользователь 1, заказ 30001.

Логи, `screenshots/01-kibana-gateway.png`. Запрос `service:gateway AND message:request`:

```text
ts: 2026-11-09T16:32:30.647Z  status: 201  user_id: 1
trace_id: f1f3d78dd89f7bcfe9417980ce7405ff
```

Метрики, `screenshots/02-prometheus-http.png`: `sum by (service, status) (rate(http_requests_total[1m]))` — gateway 201, orders 201, payments 200.

Трейс, `screenshots/03-jaeger-checkout.png`, тот же `trace_id`, 902 мс, 3 сервиса. Цепочка: gateway → orders → PostgreSQL (`BEGIN`, `INSERT`, `COMMIT`) → payments `POST /charge` → PostgreSQL `UPDATE`. Redis в checkout нет.

Упавший запрос до PostgreSQL дошёл. `screenshots/04-jaeger-failed-history.png`, trace `298909ed019a27b49ef48d6d4cf089a7`, `GET /api/users/:id/history`: `SELECT` шёл около 4 с, следующий `pg-pool.connect` (2 с) упал с `timeout exceeded when trying to connect`.

## 2. Timeline

Прогон `before-mw9hp8pt-10f5e0`:

- 16:40:16–16:42:51Z
- 5833 ошибки из 6362
- все 100 пользователей
- p95 4003 мс
- Статусы gateway: 4786x503 и 1047x504.

События:

1. `16:39:46Z` — Redis отвергает запись истории.
   - Слой: ресурсы. Источник: `[log]`, `[metric]`.
   - `message:"cache set failed"`, ошибка `OOM command not allowed when used memory > 'maxmemory'`.
   - Занято около 1.19 МБ при лимите 1 048 576 байт, ключей 0, `evicted_keys` 0.
   - `screenshots/07-prometheus-redis-memory.png`.
2. `16:40:16Z` — промах кэша, `user_report` идёт 6389 мс.
   - Слой: ПО. Источник: `[log]`.
   - Trace `298909ed019a27b49ef48d6d4cf089a7`, в логе orders `ts` сдвинут: `2026-11-09T11:40:16.602`.
3. `16:40:20.604Z` — первая 5xx у пользователя.
   - Слой: пользователи. Источник: `[log]`.
   - Gateway 504, пользователь 38, `upstream timeout`.
   - Запрос `service:gateway AND status:>=500`. Дальше 5833 ошибки, все 100 пользователей.
4. `16:41:12Z` — пул PostgreSQL исчерпан.
   - Слой: ресурсы. Источник: `[metric]`, `[trace]`.
   - Занято 40 из 40, `db_pool_waiting` = 134. Orders: 5518 ошибок `db connection acquire timeout`.
   - `screenshots/06-prometheus-db-pool.png`, `screenshots/04-jaeger-failed-history.png`.
   - Всплеск нагрузки начался только в `16:40:42Z`, уже после первых ошибок.

Индекс `idx_orders_user_id` на `orders(user_id)` есть, `payments_queue_length` = 0. Это не отсутствующий индекс и не очередь payments.

## 3. Расхождения между источниками

Один trace `298909ed019a27b49ef48d6d4cf089a7`, `screenshots/05-kibana-time-skew.png`. На гистограмме два столбика с разницей 5 часов.

| Источник          | Время                             |
| ----------------- | --------------------------------- |
| Jaeger, старт     | 16:40:16Z                         |
| лог gateway, `ts` | 2026-11-09T16:40:20.604Z          |
| лог orders, `ts`  | 2026-11-09T11:40:16.602 без пояса |

Разница 5 часов. До исправления у orders стояли `ORDERS_TZ=America/New_York` и `ORDERS_LOG_TIME_MODE=local_naive`: в `ts` писалось местное время без смещения. Filebeat (`config/filebeat.yml`, layout без пояса) принимал его за UTC. В окне тикета 16:40 логов orders не было, по их `ts` ошибка выглядела на 5 часов раньше.

## 4. Исправление

В `.env`, затем `docker compose up -d --no-build`:

| Параметр               | Было             | Стало   |
| ---------------------- | ---------------- | ------- |
| `REDIS_MAXMEMORY_MB`   | 1                | 64      |
| `ORDERS_TZ`            | America/New_York | UTC     |
| `ORDERS_LOG_TIME_MODE` | local_naive      | utc_iso |

Лимит 1 МБ был меньше памяти самого процесса Redis, `SET` отвергался и история каждый раз шла в `user_report`. 64 МБ снимают этот отказ. Сдвиг часов у orders убирает ложную шкалу в Kibana.

Повторный прогон, те же 6362 запроса (`evidence/loadgen_after.json`):

|               | before    | after                    |
| ------------- | --------- | ------------------------ |
| 5xx           | 5833      | 898                      |
| пользователей | 100       | 99                       |
| p95           | 4003 мс   | 2429 мс                  |
| первая 5xx    | через 4 с | через 105 с, в 17:16:09Z |

После правки `redis_memory_max_bytes` = 67108864, занято около 1.1 МБ, `evicted_keys` = 0. За окно прогона около 1279 попаданий в кэш и 403 промаха. В trace `9179935556f50262de31c1b9eb01cee6` оба сервиса уже в UTC: orders `2026-11-09T17:16:05.470Z`, gateway `2026-11-09T17:16:09.470Z` (`screenshots/08-kibana-times-aligned.png`).

Остаток, 644x503 и 254x504, снова `db connection acquire timeout` (772 записи orders). Пул доходил до 40/40, `db_pool_waiting` до 125 (`screenshots/09-prometheus-after.png`). Кэш истории живёт 120 с, прогон длится около 156 с, ключи истекают к концу всплеска и `user_report` снова занимает пул.

## 5. Выводы

Инцидент виден до обращения в поддержку по двум условиям:

- Память Redis у лимита
- Очередь пула.

Алерт только на `redis_evicted_keys_total` этот случай не ловит: вытеснений не было, `SET` отвергался. Время всех сервисов должно быть UTC, иначе логи orders выпадают из окна тикета.

### Правило оповещения Prometheus

```yaml
groups:
  - name: lab2
    rules:
      - alert: RedisMemoryNearMax
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: Redis упёрся в maxmemory
      - alert: DbPoolWaiting
        expr: db_pool_waiting > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: Запросы ждут соединение PostgreSQL
      - alert: Http5xx
        expr: sum(rate(http_requests_total{status=~"5.."}[2m])) > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: Появились ответы 5xx
```
