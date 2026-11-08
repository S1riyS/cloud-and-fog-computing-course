#!/bin/bash
# ИСУ 413732 % 4 = 0: CPU-bound, SHA-256.
# 2 vCPU и 2 GB задаются при запуске ВМ и контейнера, не здесь.
echo "=== Start Workload ==="
openssl speed -seconds 10 -bytes 8192 sha256
echo "=== End Workload ==="
