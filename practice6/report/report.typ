= Практическая работа 6. MicroShift

== Практическое занятие: Управление ресурсами и жесткими квотами на Edge-узлах (MINC / MicroShift)

== ЭТАП 0. Подготовка локального стенда MINC

Кластер поднят через Docker (`-p docker`): утилиты `oc` в системе нет, дальше используется `kubectl`.

```bash
❯ minc create -p docker --disable-overlay-cache
time=2026-11-25T20:43:50.753+03:00 level=INFO msg="Ensuring cluster image (quay.io/minc-org/minc:4.19.0-okd-scos.17-amd64) ..."
time=2026-11-25T20:46:38.443+03:00 level=INFO msg="Waiting for MicroShift service to start..."
time=2026-11-25T20:47:35.292+03:00 level=INFO msg="Waiting for KubeConfig ..."
time=2026-11-25T20:47:35.421+03:00 level=INFO msg="Waiting for pods to be ready..."
time=2026-11-25T20:47:35.635+03:00 level=INFO msg="Cluster created"
❯ minc generate-kubeconfig -p docker
kubeconfig generated and context is added to default config
❯ kubectl config current-context
microshift
❯ kubectl get nodes
NAME               STATUS   ROLES                         AGE   VERSION
127.0.0.1.nip.io   Ready    control-plane,master,worker   49s   v1.32.8
```

== ЭТАП 1. Изучение бесконтрольного потребления и OOM-Kill

Под без `requests` и `limits` ушёл в `OOMKilled` с кодом `137`. Счётчик `RESTARTS` вырос до 1, kubelet поставил контейнер в `BackOff`. Класс QoS пода - `BestEffort`.

```bash
❯ kubectl config current-context
microshift
❯ kubectl create namespace edge-test
namespace/edge-test created
❯ kubectl apply -f memory-hog.yaml
pod/memory-hog-pod created
❯ kubectl get pods -n edge-test -w
NAME             READY   STATUS              RESTARTS   AGE
memory-hog-pod   0/1     ContainerCreating   0          3s
memory-hog-pod   1/1     Running             0          13s
memory-hog-pod   0/1     OOMKilled           0          55s
memory-hog-pod   1/1     Running             1 (2s ago)   56s
memory-hog-pod   0/1     OOMKilled           1 (31s ago)   85s
^C
❯ kubectl get pods -n edge-test
NAME             READY   STATUS    RESTARTS      AGE
memory-hog-pod   1/1     Running   1 (30s ago)   84s
❯ kubectl describe pod memory-hog-pod -n edge-test
Name:             memory-hog-pod
Namespace:        edge-test
Priority:         0
Service Account:  default
Node:             127.0.0.1.nip.io/172.17.0.2
Start Time:       Wed, 25 Nov 2026 20:51:20 +0300
Labels:           <none>
Annotations:      openshift.io/scc: nonroot-v2
                  seccomp.security.alpha.kubernetes.io/pod: runtime/default
Status:           Running
SeccompProfile:   RuntimeDefault
IP:               10.42.0.8
IPs:
  IP:  10.42.0.8
Containers:
  memory-eater:
    Container ID:    cri-o://62862345724ebfbd51518dfcd56c0c68dfd1ceb34be94a9216e8663808402ad6
    Image:           python:3.9-slim
    Image ID:        docker.io/library/python@sha256:2d97f6910b16bd338d3060f261f53f144965f755599aab1acda1e13cf1731b1b
    Port:            <none>
    Host Port:       <none>
    SeccompProfile:  RuntimeDefault
    Command:
      python
      -c
      import time; a = []; [a.append(' ' * 10**7) for i in range(1000)]; time.sleep(300)
    State:          Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Wed, 25 Nov 2026 20:52:15 +0300
      Finished:     Wed, 25 Nov 2026 20:52:44 +0300
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Wed, 25 Nov 2026 20:51:32 +0300
      Finished:     Wed, 25 Nov 2026 20:52:14 +0300
    Ready:          False
    Restart Count:  1
    Environment:    <none>
    Mounts:
      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-q6n97 (ro)
Conditions:
  Type                        Status
  PodReadyToStartContainers   True
  Initialized                 True
  Ready                       False
  ContainersReady             False
  PodScheduled                True
Volumes:
  kube-api-access-q6n97:
    Type:                    Projected (a volume that contains injected data from multiple sources)
    TokenExpirationSeconds:  3607
    ConfigMapName:           kube-root-ca.crt
    Optional:                false
    DownwardAPI:             true
    ConfigMapName:           openshift-service-ca.crt
    Optional:                false
QoS Class:                   BestEffort
Node-Selectors:              <none>
Tolerations:                 node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
Events:
  Type     Reason     Age                From               Message
  ----     ------     ----               ----               -------
  Normal   Scheduled  86s                default-scheduler  Successfully assigned edge-test/memory-hog-pod to 127.0.0.1.nip.io
  Normal   Pulling    86s                kubelet            spec.containers{memory-eater}: Pulling image"python:3.9-slim"
  Normal   Pulled     74s                kubelet            spec.containers{memory-eater}: Successfully pulled image "python:3.9-slim" in 11.998s (11.998s including waiting). Image size: 126472493 bytes.
  Normal   Created    31s (x2 over 74s)  kubelet            spec.containers{memory-eater}: Created container: memory-eater
  Normal   Started    31s (x2 over 74s)  kubelet            spec.containers{memory-eater}: Started container memory-eater
  Normal   Pulled     31s                kubelet            spec.containers{memory-eater}: Container image "python:3.9-slim" already present on machine
  Warning  BackOff    1s                 kubelet            spec.containers{memory-eater}: Back-off restarting failed container memory-eater in pod memory-hog-pod_edge-test(a6dd7813-429d-429c-830a-9b586d0e0c6d)
```

== ЭТАП 2. Настройка Requests и Limits (Quality of Service)

Под `limited-pod` перешёл в `Running` без рестартов. `qosClass` равен `Burstable`.

Класс `Guaranteed` ставится только когда у каждого контейнера заданы и CPU, и память, и для каждого из этих ресурсов `requests` равны `limits`. Класс `BestEffort` был у `memory-hog-pod`: там не было ни одного request и ни одного limit. У `limited-pod` запрос меньше потолка и по памяти, и по CPU, поэтому планировщик резервирует нижнюю границу, а cgroup разрешает кратковременный рост до лимита. Это и есть `Burstable`.

```bash
❯ kubectl apply -f resource-limited-pod.yaml
pod/limited-pod created
❯ kubectl get pod limited-pod -n edge-test -w
NAME          READY   STATUS              RESTARTS   AGE
limited-pod   0/1     Pending             0          2s
limited-pod   0/1     ContainerCreating   0          4s
limited-pod   1/1     Running             0          6s
^C
❯ kubectl get pod limited-pod -n edge-test -o jsonpath='{.status.qosClass}{"\n"}'
Burstable
❯ kubectl describe pod limited-pod -n edge-test
Name:             limited-pod
Namespace:        edge-test
Priority:         0
Service Account:  default
Node:             127.0.0.1.nip.io/172.17.0.2
Start Time:       Wed, 25 Nov 2026 20:59:50 +0300
Labels:           <none>
Annotations:      openshift.io/scc: nonroot-v2
                  seccomp.security.alpha.kubernetes.io/pod: runtime/default
Status:           Running
SeccompProfile:   RuntimeDefault
IP:               10.42.0.8
IPs:
  IP:  10.42.0.8
Containers:
  constrained-app:
    Container ID:    cri-o://f5e7abe19e4c4052a2ccffa2256356ae766939b0bd46b755b06a8ec77d78726b
    Image:           python:3.9-slim
    Image ID:        docker.io/library/python@sha256:2d97f6910b16bd338d3060f261f53f144965f755599aab1acda1e13cf1731b1b
    Port:            <none>
    Host Port:       <none>
    SeccompProfile:  RuntimeDefault
    Command:
      python
      -c
      import time; print('Running within limits'); time.sleep(300)
    State:          Running
      Started:      Wed, 25 Nov 2026 20:59:51 +0300
    Ready:          True
    Restart Count:  0
    Limits:
      cpu:     500m
      memory:  128Mi
    Requests:
      cpu:        100m
      memory:     64Mi
    Environment:  <none>
    Mounts:
      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-h424p (ro)
Conditions:
  Type                        Status
  PodReadyToStartContainers   True
  Initialized                 True
  Ready                       True
  ContainersReady             True
  PodScheduled                True
Volumes:
  kube-api-access-h424p:
    Type:                    Projected (a volume that contains injected data from multiple sources)
    TokenExpirationSeconds:  3607
    ConfigMapName:           kube-root-ca.crt
    Optional:                false
    DownwardAPI:             true
    ConfigMapName:           openshift-service-ca.crt
    Optional:                false
QoS Class:                   Burstable
Node-Selectors:              <none>
Tolerations:                 node.kubernetes.io/memory-pressure:NoSchedule op=Exists
                             node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  37s   default-scheduler  Successfully assigned edge-test/limited-pod to 127.0.0.1.nip.io
  Normal  Pulled     33s   kubelet            spec.containers{constrained-app}: Container image "python:3.9-slim" already present on machine
  Normal  Created    33s   kubelet            spec.containers{constrained-app}: Created container: constrained-app
  Normal  Started    33s   kubelet            spec.containers{constrained-app}: Started container constrained-app
```

== ЭТАП 3. Установка Namespace-level ResourceQuota

Квота применена, пока `limited-pod` ещё работал, поэтому в `Used` уже видны его `64Mi` / `128Mi` и один под. Второй под API не создал: `Forbidden`, квота `edge-env-quota` превышена по памяти.

`quota-violation-pod` запрашивает `400Mi` и столько же ставит в лимит. С учётом уже занятого получается:

- `requests.memory` `64Mi + 400Mi = 464Mi` при потолке `256Mi`
- `limits.memory` `128Mi + 400Mi = 528Mi` при потолке `512Mi`.
- CPU и число подов в ошибку не попали:
  - `requests.cpu` остался бы `200m` из `500m`
  - `limits.cpu` — `700m` из `1`, подов стало бы 2 из 3.

```bash
❯ kubectl apply -f quota.yaml
resourcequota/edge-env-quota created
❯ kubectl describe resourcequota edge-env-quota -n edge-test
Name:            edge-env-quota
Namespace:       edge-test
Resource         Used   Hard
--------         ----   ----
limits.cpu       500m   1
limits.memory    128Mi  512Mi
pods             1      3
requests.cpu     100m   500m
requests.memory  64Mi   256Mi
❯ kubectl apply -f quota-violation-pod.yaml
Error from server (Forbidden): error when creating "quota-violation-pod.yaml": pods "quota-violation-pod" is forbidden: exceeded quota: edge-env-quota, requested: limits.memory=400Mi,requests.memory=400Mi, used: limits.memory=128Mi,requests.memory=64Mi, limited: limits.memory=512Mi,requests.memory=256Mi
```

== ЭТАП 4. Оформление инженерного отчета

=== Индивидуальный опыт и трудности

Стенд собирался в WSL2 с Docker Desktop. ООООЧень долго скачивался образ, но в итоге все успешно запустилось!

Кроме того, у меня по какой-то причине WSL2 начинает потреблять какое-от неимоверное кол-во ресурсов (особенно RAM - порядка 8.5 ГБ) при включении Docker. После Этапа №1 (когда не было ограничения на ресурсы) даже пришлось перезапустиьт WSL

=== Логи OOM-Kill

Полный `kubectl describe` приведён в этапе 1. Причина завершения контейнера `memory-eater`:

```bash
    State:          Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Wed, 25 Nov 2026 20:52:15 +0300
      Finished:     Wed, 25 Nov 2026 20:52:44 +0300
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Wed, 25 Nov 2026 20:51:32 +0300
      Finished:     Wed, 25 Nov 2026 20:52:14 +0300
    Ready:          False
    Restart Count:  1
```

=== Анализ квот

`requests` планировщик резервирует на узле. Процесс они не останавливают: контейнер может занять больше, чем просил. `limits` - потолок cgroup.

Память сверх `limits.memory` ядро выделить не может, поэтому процесс сразу получает SIGKILL. Kubelet пишет `OOMKilled` и код `137`. CPU сверх `limits.cpu` у процесса не отнимают: его просто реже ставят на процессор, он жив, но медленнее. Это троттлинг.
