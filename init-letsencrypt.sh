#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Sub1S Let's Encrypt 최초 인증서 발급 스크립트
#
# 사용법:
#   ./init-letsencrypt.sh <도메인> <이메일>
#   예: ./init-letsencrypt.sh api.sub1s.com admin@sub1s.com
# -----------------------------------------------------------------------------

cd "$(dirname "$0")"

DOMAIN="${1:-}"
EMAIL="${2:-}"

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
  echo "사용법: $0 <도메인> <이메일>"
  echo "예시:   $0 api.sub1s.com developer@example.com"
  exit 1
fi

echo "=== 1. Nginx 설정 파일 내 도메인 교체 ==="
sed -i "s|sub1s.domain.com|$DOMAIN|g" ./nginx/default.conf

echo "=== 2. HTTP 전용 모드로 Nginx 기동 (부트스트랩) ==="
NGINX_CONF=default.http-only.conf docker compose up -d nginx

echo "=== 3. Let's Encrypt SSL 인증서 발급 요청 ==="
docker compose run --rm --entrypoint "certbot certonly --webroot -w /var/www/certbot -d ${DOMAIN} --email ${EMAIL} --rsa-key-size 4096 --agree-tos --non-interactive" certbot

echo "=== 4. TLS 모드로 Nginx 재기동 ==="
NGINX_CONF=default.conf docker compose up -d --force-recreate nginx

echo "=== 5. SSL 발급 및 연동 검증 ==="
sleep 3
if curl -sfI "https://${DOMAIN}/api/health" > /dev/null; then
  echo "✅ SSL 인증서 발급 및 HTTPS API 통신이 성공적으로 확인되었습니다: https://${DOMAIN}/api/health"
else
  echo "⚠️ HTTPS 응답 확인 대기 중... 도메인 DNS A 레코드 및 443 방화벽을 확인해주세요."
fi
