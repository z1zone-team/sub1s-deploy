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
  # ---------------------------------------------------------------------------
  # SSL 인증서 발급 상태 검사 및 Nginx TLS 설정 자동 보존
  # ---------------------------------------------------------------------------
  if grep -q '^DOMAIN=' .env 2>/dev/null; then
    CURRENT_DOMAIN=$(grep '^DOMAIN=' .env 2>/dev/null | cut -d '=' -f2 | tr -d ' "\r' || true)
    if [ -z "$CURRENT_DOMAIN" ] || [ "$CURRENT_DOMAIN" = "sub1s.domain.com" ] || [ "$CURRENT_DOMAIN" = "api.sub1s.com" ]; then
      CURRENT_DOMAIN="sub1s.devnoco.com"
      sed -i "s|^DOMAIN=.*|DOMAIN=${CURRENT_DOMAIN}|" .env
    fi
  else
    CURRENT_DOMAIN="sub1s.devnoco.com"
    echo "DOMAIN=${CURRENT_DOMAIN}" >> .env
  fi

  CERT_EXISTS=false
  CERT_MOUNT="/var/lib/docker/volumes/sub1s_certbot-conf/_data/live/${CURRENT_DOMAIN}/fullchain.pem"
  if command -v sudo >/dev/null 2>&1 && sudo test -f "$CERT_MOUNT" 2>/dev/null; then
    CERT_EXISTS=true
  elif [ -f "$CERT_MOUNT" ]; then
    CERT_EXISTS=true
  fi

  if [ "$CERT_EXISTS" = true ]; then
    echo "fetch-env: 유효한 Let's Encrypt SSL 인증서가 확인되었습니다 (${CURRENT_DOMAIN})"
    if grep -q '^NGINX_CONF=' .env 2>/dev/null; then
      sed -i "s|^NGINX_CONF=.*|NGINX_CONF=default.conf|" .env
    else
      echo "NGINX_CONF=default.conf" >> .env
    fi
    if [ -f ./nginx/default.conf ]; then
      sed -i "s|sub1s.domain.com|${CURRENT_DOMAIN}|g" ./nginx/default.conf
    fi
  else
    echo "fetch-env: SSL 인증서 미발급 상태. 기존 NGINX_CONF 설정을 유지합니다."
  fi

  echo "fetch-env: .env 준비 완료"
else
  echo "⚠️ 경고: .env 파일이 없습니다. .env.example을 복사하여 환경변수를 설정해주세요."
fi
