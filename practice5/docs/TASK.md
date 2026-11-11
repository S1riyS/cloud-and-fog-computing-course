# Практическое занятие: Kubernetes (k3s) — Health Probes (Liveness/Readiness) и Self-Healing

**Цель:** Изучить механизмы проверки здоровья контейнеров в Kubernetes (`livenessProbe` и `readinessProbe`), понять разницу между перезапуском падающего пода и отключением его от пользовательского трафика, а также протестировать самовосстановление (Self-Healing) приложения при внешних и внутренних сбоях.

**Время:** 90 минут

**Инструмент:** `k3s` (или `k3d` / `rancher/k3s`) + `kubectl`

**Формат сдачи:** Отчёт с описанием индивидуального инженерного опыта, логами событий Kubernetes (`kubectl describe`) и графиком/выводом `curl` во время сбоя.

**Максимальный балл:** 6 баллов.

## Коротко о ключевых понятиях

- **`readinessProbe` (Готовность к приёму трафика):** Проверяет, готово ли приложение обрабатывать пользовательские запросы. Если проверка **проваливается**, Kubernetes **НЕ перезапускает** контейнер, а исключает под из эндпоинтов `Service`. Пользователи перестают получать 502/503 ошибки.
- **`livenessProbe` (Жив ли процесс/приложение):** Проверяет, не зависло ли приложение (deadlock, infinite loop). Если проверка **проваливается**, Kubernetes **убивает и перезапускает** контейнер (`SIGKILL`).

## ЭТАП 0. Подготовка и установка k3s (15 минут)

Развернём минималистичный кластер Kubernetes на базе `k3s`.

### Для Linux / macOS

```
# Установка k3s одной командой
curl -sfL https://get.k3s.io | sh -

# Проверка доступа к кластеру (без root):
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
```

### Для Windows (WSL2 / Docker Desktop) или macOS через `k3d`

Если вы используете Docker Desktop / WSL2, проще всего запустить `k3s` через `k3d`:

```
# Установка k3d или запуск контейнера k3s
docker run -d --name k3s-cluster --privileged -p 8080:8080 -p 6443:6443 rancher/k3s:v1.28.2-k3s1 server
```

## ЭТАП 1. Создание приложения с имитацией деградации (20 минут)

Создадим манифест `app-deployment.yaml`. Для наглядности мы задействуем готовый образ `registry.k8s.io/e2e-test-images/agnhost:2.39`, который умеет по команде меняться в статусе (возвращать HTTP 500 на эндпоинты здоровья).

Создайте файл `app-deployment.yaml`:

```
apiVersion: apps/v1kind: Deploymentmetadata:  name: health-demospec:  replicas: 2  selector:    matchLabels:      app: health-demo  template:    metadata:      labels:        app: health-demo    spec:      containers:      - name: web-app        image: registry.k8s.io/e2e-test-images/agnhost:2.39        command: ["/bin/sh", "-c"]        args:        - |          apk add --no-cache python3 >/dev/null 2>&1          python3 -c "          import os, http.server          st = {'ready': True, 'alive': True}          host = os.environ.get('HOSTNAME', '')          class H(http.server.BaseHTTPRequestHandler):              def do_GET(self):                  if self.path == '/hostname':                      self.send_response(200); self.end_headers(); self.wfile.write((host + '\n').encode())                  elif self.path == '/healthz':                      self.send_response(200 if (st['ready'] and st['alive']) else 500)                      self.end_headers(); self.wfile.write(b'OK' if (st['ready'] and st['alive']) else b'ERR')                  elif self.path == '/make-not-ready':                      st['ready'] = False; self.send_response(200); self.end_headers(); self.wfile.write(b'OK')                  elif self.path == '/make-ready':                      st['ready'] = True; st['alive'] = True; self.send_response(200); self.end_headers(); self.wfile.write(b'OK')                  elif self.path == '/make-not-alive':                      st['alive'] = False; st['ready'] = False; self.send_response(200); self.end_headers(); self.wfile.write(b'OK')          http.server.HTTPServer(('0.0.0.0', 8080), H).serve_forever()          "        ports:        - containerPort: 8080        readinessProbe:          httpGet:            path: /healthz            port: 8080          initialDelaySeconds: 5          periodSeconds: 3          failureThreshold: 2        livenessProbe:          httpGet:            path: /healthz            port: 8080          initialDelaySeconds: 10          periodSeconds: 5          failureThreshold: 3---apiVersion: v1kind: Servicemetadata:  name: health-servicespec:  selector:    app: health-demo  ports:  - port: 80    targetPort: 8080  type: ClusterIP
```

Примените манифест:

```
kubectl apply -f app-deployment.yaml
kubectl get pods -w
```

Дождитесь, пока оба пода перейдут в статус `Running` и `READY 1/1`.

## ЭТАП 2. Эксперимент №1: Тестирование Readiness Probe (20 минут)

Сделайте так, чтобы один из подов стал «неготов» (перестал отвечать `200 OK` на `/healthz`), но процесс при этом продолжал работать.

1. **Запустите генератор трафика** в отдельном терминале: ``` # Проброс порта сервиса kubectl port-forward svc/health-service 8080:80 ``` *В другом окне запускаем цикличный запрос:* ``` while ($true) { try { $res = Invoke-RestMethod -Uri "http://localhost:8080/hostname" -TimeoutSec 1 Write-Host "200 OK from Pod: $res" -ForegroundColor Green } catch { Write-Host "ERROR: $_" -ForegroundColor Red } Start-Sleep -Milliseconds 500 } ```
2. **Имитируем сбой готовности (Readiness failure)** на одном из подов: Узнаем имя первого пода: ``` kubectl get pods -l app=health-demo ``` Отправим команду подделать статус `/healthz` на 500 ошибку: ``` kubectl exec <POD_NAME> -- curl -s http://localhost:8080/make-not-ready ```
3. **Наблюдение:**

- Посмотрите на статус подов: `kubectl get pods`. Вы увидите, что на одном из подов количество готовых контейнеров изменилось на `READY 0/1`.
- **Посмотрите на окно с `Invoke-RestMethod`:** Запросы **НЕ падают** с ошибками! Kubernetes мгновенно исключил «неготовый» под из балансировщика сервиса и направляет 100% трафика на второй здоровый под.

1. **Верните под в здоровое состояние:** ``` kubectl exec <POD_NAME> -- curl -s http://localhost:8080/make-ready ``` Зафиксируйте, как под снова возвращается в статус `READY 1/1` и трафик начинает распределяться на оба пода.

## ЭТАП 3. Эксперимент №2: Тестирование Liveness Probe и Self-Healing (20 минут)

Теперь симулируем фатальное зависание приложения (Deadlock/Crash).

1. Передадим поду команду полностью «сломать» `/healthz` эндпоинт: ``` kubectl exec <POD_NAME> -- curl -s http://localhost:8080/make-not-alive ```
2. Запустите отслеживание событий пода в реальном времени: ``` kubectl get pods -w # В параллельном терминале: kubectl describe pod <POD_NAME> ```
3. **Что происходит:**

- Сначала срабатывает `readinessProbe` (под отключается от трафика, `READY 0/1`).
- Через 15 секунд (3 провала `livenessProbe` по 5 секунд) Kubernetes фиксирует провал проверки жизнеспособности.
- В логах `kubectl describe` появляется событие: `Container web-app failed liveness probe, will be restarted`.
- Kubernetes принудительно перезапускает контейнер внутри пода (счётчик `RESTARTS` увеличивается на `1`).
- После перезапуска контейнер сбрасывает своё внутреннее сломанное состояние и снова становится здоровым (`READY 1/1`).

## ЭТАП 4. Оформление инженерного отчёта (15 минут)

Оформите короткий отчет с описанием проведенного эксперимента.

**В отчете обязательно отразите:**

1. **Индивидуальный опыт и баги:** С какими сложностями вы столкнулись при установке/запуске `k3s` / `k3d`, настройке `port-forward` или составлении YAML-манифестов? Как их устранили?
2. **Анализ логов:** Приложите фрагмент вывода `kubectl describe pod` с зафиксированным событием автоматического перезапуска контейнера из-за `Liveness probe failed`.
3. **Сравнительный вывод (1–2 абзаца):** На основе проведённых экспериментов объясните, почему нельзя ограничиваться только `livenessProbe` и зачем в production-кластерах обязательно нужна `readinessProbe`.

## Критерии оценивания (6 баллов)

| Критерий | Баллы |
| --- | --- |
| **Установка и запуск:** Кластер k3s/k3d инициализирован, манифест с `Deployment` и `Service` успешно применён | **1.0 б.** |
| **Эксперимент 1 (Readiness):** Зафиксировано отключение пода от трафика без ошибок 500 для пользователя (`READY 0/1`) | **1.5 б.** |
| **Эксперимент 2 (Liveness & Self-Healing):** Зафиксирован автоматический перезапуск контейнера оркестратором и рост `RESTARTS` | **1.5 б.** |
| **Инженерный отчёт:** Описан личный опыт устранения проблем и дано четкое объяснение разницы между Liveness и Readiness пробами | **2.0 б.** |
