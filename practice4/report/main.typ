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
  #text(size: 16pt, weight: "bold")[Практическая работа 4] \
  Docker Swarm
]

= Выполнение
== Routing Mesh

Стек `web-stack`: сервис `web-stack_web`, 3 реплики, порт `8080` в режиме ingress.

```bash
ID             NAME            MODE         REPLICAS   IMAGE                PORTS
er98bvogd17z   web-stack_web   replicated   3/3        python:3.11-alpine   *:8080->5678/tcp
```

Десять запросов на `http://127.0.0.1:8080` идут циклом слотов 3 → 2 → 1. Так Ingress Mesh балансирует по *round-robin*.

```bash
Hello from Swarm! Container ID: ed25e81beddc | Slot: 3
Hello from Swarm! Container ID: 8395ee12c802 | Slot: 2
Hello from Swarm! Container ID: 7f3aebf26713 | Slot: 1
Hello from Swarm! Container ID: ed25e81beddc | Slot: 3
Hello from Swarm! Container ID: 8395ee12c802 | Slot: 2
Hello from Swarm! Container ID: 7f3aebf26713 | Slot: 1
Hello from Swarm! Container ID: ed25e81beddc | Slot: 3
Hello from Swarm! Container ID: 8395ee12c802 | Slot: 2
Hello from Swarm! Container ID: 7f3aebf26713 | Slot: 1
Hello from Swarm! Container ID: ed25e81beddc | Slot: 3
```

== Масштабирование

`docker service scale web-stack_web=6` — сервис сошёлся в `6 out of 6 tasks`. Новые слоты 4–6 прошли `Pending`, затем сразу `Running`.

```bash
n1k7kkdouidm   web-stack_web.1   python:3.11-alpine   docker-desktop   Running   Running 4 minutes ago
lsa28b94cb76   web-stack_web.2   python:3.11-alpine   docker-desktop   Running   Running 4 minutes ago
qw67dcqngt2f   web-stack_web.3   python:3.11-alpine   docker-desktop   Running   Running 4 minutes ago
v393vz8pw8of   web-stack_web.4   python:3.11-alpine                    Running   Pending less than a second ago
e42jwg3i3rxf   web-stack_web.5   python:3.11-alpine                    Running   Pending less than a second ago
30b33udtzwkr   web-stack_web.6   python:3.11-alpine                    Running   Pending less than a second ago
```

```bash
n1k7kkdouidm   web-stack_web.1   python:3.11-alpine   docker-desktop   Running   Running 4 minutes ago
lsa28b94cb76   web-stack_web.2   python:3.11-alpine   docker-desktop   Running   Running 4 minutes ago
qw67dcqngt2f   web-stack_web.3   python:3.11-alpine   docker-desktop   Running   Running 4 minutes ago
v393vz8pw8of   web-stack_web.4   python:3.11-alpine   docker-desktop   Running   Running 1 second ago
e42jwg3i3rxf   web-stack_web.5   python:3.11-alpine   docker-desktop   Running   Running 1 second ago
30b33udtzwkr   web-stack_web.6   python:3.11-alpine   docker-desktop   Running   Running 1 second ago
```

`docker service scale web-stack_web=2` — `2 out of 2 tasks`. У слотов 3–6 желаемое состояние стало `Remove`, текущее — `Shutdown`. Состояния `Complete` в выводе не было. В списке остались слоты 1 и 2.

```bash
n1k7kkdouidm   web-stack_web.1   python:3.11-alpine   docker-desktop   Running   Running 7 minutes ago
lsa28b94cb76   web-stack_web.2   python:3.11-alpine   docker-desktop   Running   Running 7 minutes ago
qw67dcqngt2f   web-stack_web.3   python:3.11-alpine   docker-desktop   Remove    Shutdown less than a second ago
v393vz8pw8of   web-stack_web.4   python:3.11-alpine   docker-desktop   Remove    Shutdown less than a second ago
e42jwg3i3rxf   web-stack_web.5   python:3.11-alpine   docker-desktop   Remove    Shutdown less than a second ago
30b33udtzwkr   web-stack_web.6   python:3.11-alpine   docker-desktop   Remove    Shutdown less than a second ago
```

```bash
n1k7kkdouidm   web-stack_web.1   python:3.11-alpine   docker-desktop   Running   Running 7 minutes ago
lsa28b94cb76   web-stack_web.2   python:3.11-alpine   docker-desktop   Running   Running 7 minutes ago
```

#pagebreak()

== Самовосстановление

Реплик снова 3. До удаления контейнера все три задачи в `Running`.

```bash
n1k7kkdouidm   web-stack_web.1   python:3.11-alpine   docker-desktop   Running   Running 11 minutes ago
lsa28b94cb76   web-stack_web.2   python:3.11-alpine   docker-desktop   Running   Running 11 minutes ago
pee7h1il5xn9   web-stack_web.3   python:3.11-alpine   docker-desktop   Running   Running 2 minutes ago
```

Контейнер слота `web-stack_web.1` удалён через `docker rm -f`. Задача `n1k7kkdouidm` получила желаемое состояние `Shutdown` и текущее `Failed` с ошибкой `task: non-zero exit (137)`. На тот же слот Swarm создал задачу `8570m19dfih5`: `Pending` → `Ready` → `Starting` → `Running`.

```bash
8570m19dfih5   web-stack_web.1       Ready      Pending less than a second ago
n1k7kkdouidm    \_ web-stack_web.1   Shutdown   Failed less than a second ago   "task: non-zero exit (137)"
lsa28b94cb76   web-stack_web.2       Running    Running 11 minutes ago
pee7h1il5xn9   web-stack_web.3       Running    Running 2 minutes ago
```

```bash
8570m19dfih5   web-stack_web.1       Running    Starting less than a second ago
n1k7kkdouidm    \_ web-stack_web.1   Shutdown   Failed 5 seconds ago            "task: non-zero exit (137)"
lsa28b94cb76   web-stack_web.2       Running    Running 11 minutes ago
pee7h1il5xn9   web-stack_web.3       Running    Running 2 minutes ago
```

```bash
8570m19dfih5   web-stack_web.1       Running    Running 1 second ago
n1k7kkdouidm    \_ web-stack_web.1   Shutdown   Failed 6 seconds ago            "task: non-zero exit (137)"
lsa28b94cb76   web-stack_web.2       Running    Running 11 minutes ago
pee7h1il5xn9   web-stack_web.3       Running    Running 2 minutes ago
```

== Трудности

Цикл запросов в задании написан на PowerShell (`1..10 | ForEach-Object`). На macOS его нет, поэтому запросы сделал циклом bash:

```bash
for i in {1..10}; do curl -sS http://127.0.0.1:8080; done
```

В целом некоторые комадны пришлось заменить на bash-совместимые.
Отслеживание производилось путем записи в `.log` файлы, чтобы не приходилось ловить момент для копирования текста.

В остальном - проблем не было

= Вывод

В `docker-stack.yml` записано желаемое состояние: число реплик, порт, лимиты. `docker service scale` меняет это число, и Swarm сам доводит факт до него. `docker rm -f` убивает контейнер, но не меняет спецификацию, поэтому на тот же слот появляется новая задача.

== Преимущество Desired State
При `docker run` убитый контейнер так и остаётся остановленным, а запросы по репликам сами не распределяются.
