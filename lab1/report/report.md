# Лабораторная работа №1. Виртуализация и контейнеризация

ИСУ `413732`:

**Вариант 0** (CPU-bound, SHA-256), лимиты 2 vCPU и 2 GB.

Характеристики хоста:

- MacBook Apple M4 Pro
- 12 ядер
- 24 GB

## Подготовка и тестовый скрипт

`benchmark.sh` во всех средах запускает:

```bash
openssl speed -seconds 10 -bytes 8192 sha256
```

## Запуск на хосте

### Время выполнения

```text
time ./benchmark.sh
=== Start Workload ===
Doing sha256 ops for 10s on 8192 size blocks: 2351861 sha256 ops in 9.93s
version: 3.6.4
type             8192 bytes
sha256           1940226.11k
=== End Workload ===
./benchmark.sh  9,94s user 0,06s system 99% cpu 10,031 total
```

### Пиковое потребление CPU/RAM

`top` во время прогона: `openssl`, PID 69998, 50,2% CPU, 1824 КБ RAM.

### Системные вызовы

На MacBook `strace` нет. Команда пишет отказ в `strace_host.txt`. Весь файл:

```text
sudo dtruss -c ./benchmark.sh 2> strace_host.txt
```

```text
dtrace: system integrity protection is on, some features will not be available
dtrace: failed to execute ./benchmark.sh: Operation not permitted
```

`strace` хоста снят отдельно, на личном ПК в WSL2. Это не MacBook из замера времени выше: другая машина, OpenSSL 3.0.2, x86_64. Это сделано исключительно для того, чтобы получить  strace хоста (хоть и не изначального хоста).

```text
strace -c ./benchmark.sh 2> strace_host.txt
```

Заголовок таблицы, пять вызовов и итог:

```text
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 79.48    0.008087         898         9         8 wait4
  5.09    0.000518          10        50        15 newfstatat
  2.79    0.000284          17        16           rt_sigaction
  2.14    0.000218           6        33        13 openat
  1.47    0.000150          12        12           rt_sigprocmask
------ ----------- ----------- --------- --------- ----------------
100.00    0.010175          41       248        44 total
```

Топ-3: `wait4`, `newfstatat`, `rt_sigaction`. Ядро занято 0,010 с, 248 вызовов.

## Виртуальная машина

### Измерение времени старта ВМ

```text
time multipass launch 24.04 --name lab-vm --cpus 2 --memory 2G
Launched: lab-vm
multipass launch 24.04 --name lab-vm --cpus 2 --memory 2G  0,05s user 0,07s system 0% cpu 1:05,65 total
```

### Запуск Workload внутри ВМ

```text
time ./benchmark.sh
=== Start Workload ===
Doing sha256 for 10s on 8192 size blocks: 2312693 sha256's in 9.99s
version: 3.0.13
type             8192 bytes
sha256           1896454.56k
=== End Workload ===
real    0m10.004s
user    0m9.998s
sys     0m0.003s
```

```text
multipass exec lab-vm -- bash -c 'cd /home/ubuntu && strace -c ./benchmark.sh' 2> strace_vm.txt
```

Заголовок таблицы, пять вызовов и итог. Время прогона в workload не входит.

```text
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 31.20    0.001001         500         2         1 wait4
 14.99    0.000481          14        33        12 openat
  7.73    0.000248          11        21           fstat
  7.67    0.000246          11        21           close
  7.54    0.000242          10        24           mmap
------ ----------- ----------- --------- --------- ----------------
100.00    0.003208          15       211        19 total
```

Топ-3: `wait4`, `openat`, `fstat`. Ядро занято 0,003 с, 211 вызовов.

### Снятие Thread Dump изнутри ВМ

Внутри гостя: `openssl`, PID 1734, 99% CPU, родитель `benchmark.sh`, PID 1733.

С macOS этих PID нет. Виден `qemu-system-aarch64`, PID 1981, около 100% CPU (`-smp 2 -m 2048M`), и `multipassd`.

## Контейнер

```text
time docker run --rm --cpus="2.0" --memory="2g" lab-ubuntu true
docker run --rm --cpus="2.0" --memory="2g" lab-ubuntu true  0,03s user 0,02s system 17% cpu 0,283 total
```

```text
docker run --rm --cpus="2.0" --memory="2g" -v "$(pwd)":/app lab-ubuntu bash -c 'time bash /app/benchmark.sh'
=== Start Workload ===
Doing sha256 for 10s on 8192 size blocks: 2330838 sha256's in 9.99s
version: 3.0.13
type             8192 bytes
sha256           1911333.82k
=== End Workload ===
real    0m10.009s
user    0m10.002s
sys     0m0.005s
```

### Видимость процессов с хоста

`docker top`: `openssl`, PID 61448, около 91% CPU, родитель `bash /app/benchmark.sh`, PID 61433.

`ps aux | grep openssl` на macOS ничего не вывел. Docker Desktop запускает контейнер внутри своей Linux-ВМ, поэтому `ps` macOS эти PID не показывает. На Linux контейнер использует ядро хоста, и тот же `ps` показал бы процесс. В шаблоне таблицы «да» относится к Linux.

### Syscalls в контейнере

```text
docker run --rm --privileged --cpus="2.0" --memory="2g" --security-opt seccomp=unconfined -v "$(pwd)":/app lab-ubuntu strace -c bash /app/benchmark.sh 2> strace_container.txt
```

Заголовок таблицы, пять вызовов и итог. Время прогона в workload не входит.

```text
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 11.56    0.000302          43         7         1 openat
 10.33    0.000270         270         1           execve
  9.76    0.000255          15        17         6 newfstatat
  9.11    0.000238          23        10           mmap
  6.28    0.000164          82         2         2 connect
------ ----------- ----------- --------- --------- ----------------
100.00    0.002613          15       167        17 total
```

Топ-3: `openat`, `execve`, `newfstatat`. Ядро занято 0,003 с, 167 вызовов.

## Ловушка в методологии

Вывод «контейнеры в 8 раз быстрее ВМ на IO» не следует из протокола:

- Контейнер на Docker Desktop macOS писал в overlay, который кэшируется в памяти. ВМ писала через IDE с `sync` на HDD. 1200 MB/s против 150 MB/s — это память против диска.

- ВМ дали 1 ядро, контейнеру — все ядра хоста. CPU не выровнен, поэтому восьмикратную разницу нельзя относить к типу среды.

## Архитектурное обоснование

**А. Чужой Python.** ВМ или micro-VM. Код недоверенный, его нельзя пускать на общем ядре с платформой и другими арендаторами. Контейнер это ядро делит: выход из контейнера — выход на хост. У ВМ своё ядро, граница проходит по гипервизору.

**Б. Банк, ядро Linux 3.10 и свой драйвер.** ВМ. Контейнер работает на ядре хоста, модуль от 3.10 туда не загрузить и устройство одному приложению не отдать. В госте можно поставить нужное ядро и пробросить драйвер только ему.

**В. Каталог, много выкладок в день, масштаб до 200 копий.** Контейнеры. Частые деплои и рост числа копий требуют быстрого старта и малой цены экземпляра. ВМ на каждую копию поднимает отдельную ОС, поэтому старт и расход ресурсов здесь лишние.

## Итоговая сравнительная таблица

| Метрика | Хост | ВМ | Контейнер |
| --- | --- | --- | --- |
| Старт, с | 0 | 65,65 | 0,283 |
| Workload, с | 10,031 | 10,004 | 10,009 |
| Overhead CPU / RAM | 0% | ≈ 0%, RAM нагрузки ~2 МБ | ≈ 0%, RAM нагрузки ~2 МБ |
| Топ-3 syscall | `wait4`, `newfstatat`, `rt_sigaction` (личный ПК, WSL2; на MacBook `strace` нет) | `wait4`, `openat`, `fstat` | `openat`, `execve`, `newfstatat` |
| PID виден с хоста | да | нет, только `qemu` | нет в `ps` macOS, да в `docker top`; на Linux был бы виден |
