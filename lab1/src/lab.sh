#!/bin/bash
# ЛР1, ИСУ 413732: вариант 0 (CPU, SHA-256), лимиты 2 vCPU и 2 GB.
# Файл целиком не запускать: ниже команды по пунктам задания.
# Работайте из lab1/src в Terminal. Docker Desktop и Multipass должны быть запущены.
echo "Не запускайте файл целиком. Копируйте в терминал команды нужного этапа."
exit 0

# =============================================================================
# Стенд (в отчёт: версии)
# =============================================================================
sw_vers
uname -srm
openssl version
docker version
multipass version
multipass get local.driver

# =============================================================================
# Этап 0. Скрипт benchmark.sh уже лежит рядом. Образ для этапа 3
# =============================================================================
chmod +x benchmark.sh
docker build -t lab-ubuntu .

# =============================================================================
# Этап 1. Хост
# Повторите блок time три раза. В таблицу — среднее или медиану, не один прогон.
# В zsh смотрите total, это и есть время выполнения.
# =============================================================================
time ./benchmark.sh

# Второе окно, пока benchmark ещё идёт.
# В задании: top -b -n 1 | head -n 20 — это Linux. На macOS:
top -l 2 -n 20 -s 1 | head -n 40
ps aux | grep openssl | grep -v grep

# В задании: strace -c ./benchmark.sh 2> strace_host.txt
# На macOS strace нет. Отказ тоже скриншот в отчёт. SIP не отключать.
sudo dtruss -c ./benchmark.sh 2> strace_host.txt

# =============================================================================
# Этап 2.1. Холодный старт ВМ
# Первый launch качает Ubuntu — этот замер выбросить.
# =============================================================================
multipass launch 24.04 --name img-warm --cpus 2 --memory 2G
multipass delete img-warm
multipass purge

# Дальше три раза: launch, записать время, delete && purge.
# В отчёт — время до возврата команды (SSH уже готов).
time multipass launch 24.04 --name lab-vm --cpus 2 --memory 2G

# Пакеты не входят во время старта и не входят во время workload.
multipass exec lab-vm -- sudo apt-get update
multipass exec lab-vm -- sudo apt-get install -y openssl strace procps
multipass transfer benchmark.sh lab-vm:/home/ubuntu/
multipass exec lab-vm -- chmod +x /home/ubuntu/benchmark.sh

# =============================================================================
# Этап 2.2. Workload и strace внутри ВМ
# time — три раза. strace — отдельно, его время в таблицу не писать.
# =============================================================================
multipass exec lab-vm -- bash -c 'cd /home/ubuntu && time ./benchmark.sh'
multipass exec lab-vm -- bash -c 'cd /home/ubuntu && strace -c ./benchmark.sh' 2> strace_vm.txt

# =============================================================================
# Этап 2.3. Thread dump изнутри ВМ, пока workload идёт
# Окно 1: benchmark. Окно 2: ps. Потом снимок гипервизора с macOS.
# =============================================================================
multipass exec lab-vm -- bash /home/ubuntu/benchmark.sh
multipass exec lab-vm -- ps -efL > process_dump_vm_inside.txt
ps aux | grep -E 'qemu|multipass|VirtualMachine' | grep -v grep > process_dump_vm_from_host.txt

# =============================================================================
# Этап 3. Контейнер, лимиты 2 CPU и 2 GB
# Старт среды — три раза, в таблицу. Образ lab-ubuntu уже локальный.
# =============================================================================
time docker run --rm --cpus="2.0" --memory="2g" lab-ubuntu true

# time внутри контейнера, как ./benchmark.sh на хосте и в ВМ.
# Внешний time замерил бы только клиент docker.
docker run --rm --cpus="2.0" --memory="2g" -v "$(pwd)":/app lab-ubuntu bash -c 'time bash /app/benchmark.sh'

# =============================================================================
# Этап 3.1. Видимость процессов с хоста
# Сначала запустить в фоне, потом сразу снять docker top и ps.
# На macOS в ps процесса openssl из контейнера нет: он внутри Linux VM Docker.
# В задании «Да» написано для Linux-хоста. В отчёт — что показал ps на этом Mac.
# =============================================================================
docker run -d --name lab-ctr --cpus="2.0" --memory="2g" -v "$(pwd)":/app lab-ubuntu bash /app/benchmark.sh
docker top lab-ctr
ps aux | grep -E 'benchmark|openssl' | grep -v grep > process_dump_container_from_host.txt
docker top lab-ctr >> process_dump_container_from_host.txt
ps aux | grep -E 'docker|qemu|VirtualMachine' | grep -v grep >> process_dump_container_from_host.txt
docker rm -f lab-ctr

# =============================================================================
# Этап 3.2. strace в контейнере. Время прогона в таблицу не писать.
# seccomp=unconfined нужен, потому что Docker Desktop режет ptrace.
# =============================================================================
docker run --rm --privileged --cpus="2.0" --memory="2g" \
  --security-opt seccomp=unconfined \
  -v "$(pwd)":/app lab-ubuntu \
  strace -c bash /app/benchmark.sh 2> strace_container.txt

# =============================================================================
# Этапы 4 и 5 — текст в отчёте, команд нет.
# =============================================================================

# =============================================================================
# Hard track, +15%, по желанию. Выполняется внутри Ubuntu-ВМ, не на macOS.
# cgroups v2 на ядре macOS нет, nsenter в контейнер Docker Desktop тоже.
# =============================================================================
multipass shell lab-vm

# Уже внутри ВМ. Квота 0.2 CPU, нагрузка её превышает.
sudo mkdir -p /sys/fs/cgroup/lab1cpu
echo '+cpu' | sudo tee /sys/fs/cgroup/cgroup.subtree_control
echo '20000 100000' | sudo tee /sys/fs/cgroup/lab1cpu/cpu.max
echo $$ | sudo tee /sys/fs/cgroup/lab1cpu/cgroup.procs
openssl speed -seconds 5 -bytes 8192 sha256
cat /sys/fs/cgroup/lab1cpu/cpu.stat

# nsenter в pid и net namespace контейнера, без docker exec.
sudo apt-get install -y docker.io
sudo systemctl enable --now docker
sudo docker run -d --name nsdemo ubuntu:24.04 sleep 300
pid=$(sudo docker inspect -f '{{.State.Pid}}' nsdemo)
sudo nsenter -t "$pid" -p -n ps -ef
