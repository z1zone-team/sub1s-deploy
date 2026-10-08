#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# -----------------------------------------------------------------------------
# Sub1S OCI 인스턴스 환경변수 및 레지스트리 토큰 수신 스크립트
#
# OCI Object Storage 인스턴스 프린시펄(Instance Principal)을 통해
# 시크릿 버킷에서 프로덕션 .env 및 GHCR 토큰을 안전하게 동기화합니다.
# -----------------------------------------------------------------------------

BUCKET_NAME="${OCI_SECRET_BUCKET:-sub1s-secrets}"
NAMESPACE="${OCI_NAMESPACE:-axnuzlnrs1xz}"
ENV_FILE_NAME="sub1s.env"
TOKEN_FILE_NAME="ghcr-pull-token.txt"

OCI_BIN="$HOME/oci-cli-venv/bin/oci"
if [ ! -f "$OCI_BIN" ]; then
  OCI_BIN="oci"
fi

if command -v "$OCI_BIN" >/dev/null 2>&1; then
  echo "fetch-env: OCI CLI를 통한 시크릿 다운로드 시도..."
  if "$OCI_BIN" os object get \
    --bucket-name "$BUCKET_NAME" \
    --namespace "$NAMESPACE" \
    --name "$ENV_FILE_NAME" \
    --file .env \
    --auth instance_principal 2>/dev/null; then
    echo "fetch-env: .env 파일 갱신 완료"
  else
    echo "fetch-env: OCI 버킷에서 .env 수신 건너뜀 (기존 로컬 .env 유지)"
  fi

  # GHCR pull용 토큰 로그인 처리 (도커 레지스트리 비공개 이미지 다운로드용)
  if "$OCI_BIN" os object get \
    --bucket-name "$BUCKET_NAME" \
    --namespace "$NAMESPACE" \
    --name "$TOKEN_FILE_NAME" \
    --file - \
    --auth instance_principal 2>/dev/null | sudo docker login ghcr.io -u strfunctionk --password-stdin 2>/dev/null; then
    echo "fetch-env: GHCR 도커 레지스트리 로그인 완료"
  fi
else
  echo "fetch-env: OCI CLI 미설치 환경. 로컬 .env 파일 존재 여부 확인 중..."
fi

if [ -f .env ]; then
  echo "fetch-env: .env 준비 완료"
else
  echo "⚠️ 경고: .env 파일이 없습니다. .env.example을 복사하여 환경변수를 설정해주세요."
fi
