#!/bin/bash
set -euo pipefail

SWAP_SIZE="${1:-4G}"
SWAP_FILE="/swapfile"

if swapon --show | grep -q "${SWAP_FILE}"; then
  echo "setup-swap: ${SWAP_FILE} 이미 활성화되어 있음. 종료."
  exit 0
fi

if [ -f "${SWAP_FILE}" ]; then
  echo "setup-swap: ${SWAP_FILE} 이 이미 존재함. 스왑 활성화 시도."
  sudo chmod 600 "${SWAP_FILE}"
  sudo mkswap "${SWAP_FILE}" || true
  sudo swapon "${SWAP_FILE}"
else
  echo "setup-swap: ${SWAP_SIZE} 크기의 스왑 파일 생성 중..."
  sudo fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}" || sudo dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=4096
  sudo chmod 600 "${SWAP_FILE}"
  sudo mkswap "${SWAP_FILE}"
  sudo swapon "${SWAP_FILE}"
fi

if ! grep -q "${SWAP_FILE}" /etc/fstab; then
  echo "${SWAP_FILE} none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
fi

# OCI 저사양(1 vCPU / 6GB RAM) 환경 최적화 커널 파라미터 적용 (ADR-006)
sudo sysctl -w vm.swappiness=15
sudo sysctl -w vm.vfs_cache_pressure=50
sudo sysctl -w vm.overcommit_memory=1

cat <<EOF | sudo tee /etc/sysctl.d/99-sub1s-tuning.conf > /dev/null
vm.swappiness = 15
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 1
EOF

echo "setup-swap: ${SWAP_SIZE} 스왑 메모리 및 커널 파라미터 튜닝 완료"
swapon --show
