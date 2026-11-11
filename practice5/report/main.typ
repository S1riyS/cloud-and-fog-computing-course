#set page(paper: "a4", margin: (x: 1.6cm, y: 1.5cm), numbering: "1")
#set text(font: ("Times New Roman", "Liberation Serif"), size: 12pt, lang: "ru")
#set par(justify: false, leading: 0.65em)
#set heading(numbering: none)
#show heading: set block(above: 1em, below: 0.4em)
#show heading.where(level: 1): set text(size: 14pt)
#show heading.where(level: 2): set text(size: 12pt)
#show raw.where(block: true): it => {
  set text(font: ("DejaVu Sans Mono", "Menlo", "Courier New"), size: 6.5pt)
  block(
    breakable: false,
    width: 100%,
    fill: luma(245),
    inset: (x: 8pt, y: 6pt),
    radius: 2pt,
    above: 0.7em,
    below: 0.7em,
    it,
  )
}

#align(center)[
  #text(size: 16pt, weight: "bold")[Практическая работа 5] \
  Kubernetes: Health Probes
]

= ЭТАП 0. Подготовка и установка k3s

Контекст `k3d-p5`. Узел в `Ready`.

```bash
> kubectl config current-context
k3d-p5
```

```bash
> kubectl get nodes -o wide
NAME              STATUS   ROLES           VERSION
k3d-p5-server-0   Ready    control-plane   v1.36.4+k3s1
```

= ЭТАП 1. Создание приложения с имитацией деградации

Манифест `src/app-deployment.yaml` применён. Оба пода `Running`, `READY 1/1`.

```bash
> kubectl apply -f src/app-deployment.yaml
> kubectl get deploy,svc,pods -l app=health-demo -o wide
NAME                               READY   STATUS    RESTARTS      AGE   IP           NODE         NOMINATED NODE   READINESS GATES
pod/health-demo-5499b76fdc-lz2cr   1/1     Running   2 (25m ago)   42m   10.42.0.9    k3d-p5-server-0   <none>           <none>
pod/health-demo-5499b76fdc-qc9md   1/1     Running   1 (41m ago)   42m   10.42.0.10   k3d-p5-server-0   <none>           <none>
```

= ЭТАП 2. Эксперимент №1: Тестирование Readiness Probe

`kubectl port-forward svc/health-service 8080:80` работает иначе, чем Service. В момент запуска kubectl один раз берёт один под из Endpoints и открывает туннель лично до него. Локальный порт `8080` приклеен к этому туннелю. Запросы на `127.0.0.1:8080` не попадают в kube-proxy, поэтому в логе одно имя, даже когда оба пода `1/1`.

Вместо цикла на `localhost` запросы шли так: тот же `while`, но `curl` выполняется внутри `qc9md` и бьёт в Service `health-service`. Пока оба пода `1/1`, в логе оба имени. `10.42.0.9` — это `lz2cr`, `10.42.0.10` — `qc9md`.

```bash
> while true; do
>   ts=$(date +%H:%M:%S)
>   if body=$(kubectl exec health-demo-5499b76fdc-qc9md -- curl -fsS --http1.0 --max-time 2 http://health-service/hostname 2>&1); then
>     echo "$ts  200  $body"
>   else
>     echo "$ts  ERROR  $body"
>   fi
>   sleep 0.5
> done | tee practice5/evidence/curl.log
21:17:59  200  health-demo-5499b76fdc-lz2cr
21:18:00  200  health-demo-5499b76fdc-qc9md
21:18:00  200  health-demo-5499b76fdc-qc9md
21:18:01  200  health-demo-5499b76fdc-lz2cr
21:18:02  200  health-demo-5499b76fdc-qc9md
21:18:02  200  health-demo-5499b76fdc-lz2cr
21:18:03  200  health-demo-5499b76fdc-qc9md
21:18:03  200  health-demo-5499b76fdc-qc9md
```

```bash
> kubectl get pods -l app=health-demo -o wide
NAME                           READY   STATUS    RESTARTS        IP
health-demo-5499b76fdc-lz2cr   1/1     Running   2 (9m42s ago)   10.42.0.9
health-demo-5499b76fdc-qc9md   1/1     Running   1 (25m ago)     10.42.0.10
```

`/make-not-ready` на `lz2cr`. Под остался `Running`, readiness стала `0/1`, `RESTARTS` не изменился. Цикл в этом окне писал `200` только от `qc9md`.

```bash
> kubectl exec health-demo-5499b76fdc-lz2cr -- curl -s http://127.0.0.1:8080/make-not-ready
> kubectl get pods -l app=health-demo
NAME                           READY   STATUS    RESTARTS      AGE
health-demo-5499b76fdc-lz2cr   0/1     Running   2 (11m ago)   28m
health-demo-5499b76fdc-qc9md   1/1     Running   1 (26m ago)   28m
```

```bash
...
21:18:20  200  health-demo-5499b76fdc-qc9md
21:18:21  200  health-demo-5499b76fdc-qc9md
21:18:21  200  health-demo-5499b76fdc-qc9md
21:18:22  200  health-demo-5499b76fdc-qc9md
21:18:22  200  health-demo-5499b76fdc-qc9md
21:18:23  200  health-demo-5499b76fdc-qc9md
21:18:23  200  health-demo-5499b76fdc-qc9md
21:18:24  200  health-demo-5499b76fdc-qc9md
```

```bash
> kubectl exec health-demo-5499b76fdc-lz2cr -- curl -s http://127.0.0.1:8080/make-ready
```

После `make-ready` оба пода снова `1/1`, `RESTARTS`. Цикл снова пишет оба имени. (Эксперемент 1 я выполнил после эксперимента 2, так что в столбце `RESTARTS` может выглядеть не так, как в "эталонном" исполнении)

```bash
> kubectl get pods -l app=health-demo
NAME                           READY   STATUS    RESTARTS      AGE
health-demo-5499b76fdc-lz2cr   1/1     Running   2 (11m ago)   28m
health-demo-5499b76fdc-qc9md   1/1     Running   1 (27m ago)   28m
```

```bash
...
21:20:20  200  health-demo-5499b76fdc-lz2cr
21:20:21  200  health-demo-5499b76fdc-qc9md
21:20:21  200  health-demo-5499b76fdc-lz2cr
21:20:22  200  health-demo-5499b76fdc-qc9md
21:20:22  200  health-demo-5499b76fdc-lz2cr
21:20:23  200  health-demo-5499b76fdc-qc9md
21:20:24  200  health-demo-5499b76fdc-lz2cr
21:20:24  200  health-demo-5499b76fdc-qc9md
```

= ЭТАП 3. Эксперимент №2: Тестирование Liveness Probe и Self-Healing

`/make-not-alive` на `lz2cr`. Сначала `READY 0/1`, затем тот же под: `RESTARTS` 1 → 2 и снова `1/1`.

```bash
> kubectl exec health-demo-5499b76fdc-lz2cr -- curl -s http://localhost:8080/make-not-alive
> kubectl get pods -w
health-demo-5499b76fdc-lz2cr   0/1     Running   1 (10m ago)   16m
health-demo-5499b76fdc-qc9md   1/1     Running   1 (15m ago)   16m
health-demo-5499b76fdc-lz2cr   0/1     Running   2 (0s ago)    17m
health-demo-5499b76fdc-lz2cr   1/1     Running   2 (6s ago)    17m
```

```bash
> kubectl get pods -l app=health-demo
NAME                           READY   STATUS    RESTARTS      AGE
health-demo-5499b76fdc-lz2cr   1/1     Running   2 (26s ago)   17m
health-demo-5499b76fdc-qc9md   1/1     Running   1 (15m ago)   17m
```

В `kubectl describe` у `lz2cr`: прошлый контейнер убит с кодом 137, `Restart Count: 2`.

```bash
> kubectl describe pod health-demo-5499b76fdc-lz2cr
Last State:     Terminated
  Reason:       Error
  Exit Code:    137
Ready:          True
Restart Count:  2
```

```bash
> kubectl describe pod health-demo-5499b76fdc-lz2cr
Warning  Unhealthy  Readiness probe failed: HTTP probe failed with statuscode: 500
Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 500
Normal   Killing    Container web-app failed liveness probe, will be restarted
```

= ЭТАП 4. Оформление инженерного отчёта
== Трудности

- Я работаю на Mac, так что цикл запросов из задания на PowerShell пришлось переписать на bash.

- `kubectl port-forward` на Service не балансирует: подробнее расписано в этапе 2

== Вывод

Liveness перезапускает контейнер только после трёх провалов, около 15 секунд. Всё это время под остаётся в Service и принимает запросы. Readiness убирает его из выдачи сразу: `lz2cr` стал `0/1` без рестарта, и цикл пошёл на `qc9md`.

В production readiness нужна рядом с liveness. Неготовый под не должен получать трафик, пока liveness ещё не убила процесс.
