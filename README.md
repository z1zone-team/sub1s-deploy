# Sub1S 프로덕션 배포 가이드 (OCI ARM 인스턴스)

본 문서는 Oracle Cloud Infrastructure (OCI) Free Tier Ampere A1 (1 vCPU / 6GB RAM, Ubuntu 24.04 aarch64) 단일 VM 환경에서 Sub1S 백엔드 및 AI 서비스를 안정적으로 운영 배포하기 위한 실전 가이드입니다.

---

## 🏛️ 1. 아키텍처 개요

```
[모바일 앱 / 클라이언트]
       │ (HTTPS / WSS)
       ▼
 [Nginx :80/443]  (WSS 프록시, SSL 종단, Rate Limit)
       │
       ├─► [NestJS 백엔드 :3000] (다익스트라 라우팅, 실시간 소켓 게이트웨이)
       │         │
       │         ├─► [FastAPI AI :8000] (Whisper STT, Gemini NLU, Edge-TTS)
       │         │
       │         ├─► [PostgreSQL 16 :5432] (pgvector 확장, 799개 역 노선망)
       │         │
       │         └─► [Valkey 7.2 :6379] (실시간 캐시, BullMQ 큐 브로커)
```

---

## 🧹 2. OCI 기존 인스턴스 정리 및 준비

기존에 빌드(`build`) 용도로 사용하던 파이프라인과 도구는 보존하면서, 불필요한 dev/k6 잔여 프로세스 및 컨테이너를 안전하게 정리합니다.

```bash
# 1. 실행 중인 불필요한 기존 컨테이너 및 k6 프로세스 정리
docker ps -a
docker stop $(docker ps -a -q --filter "name=k6") 2>/dev/null || true
docker rm $(docker ps -a -q --filter "name=k6") 2>/dev/null || true

# 2. 미사용 도커 볼륨 및 댕글링 이미지 정리 (디스크 공간 확보)
docker image prune -a -f --filter "until=168h"
docker volume prune -f

# 3. 디스크 사용량 점검 (최소 20GB 이상의 여유 공간 확보 권장)
df -h /
```

---

## ⚡ 3. 4GB Swap 메모리 및 커널 파라미터 튜닝

단일 6GB 물리 메모리 환경에서 Whisper STT 연산 및 다익스트라 경로 탐색 동시 요청 시 OOM Killer를 원천 차단하기 위해 4GB 스왑을 활성화합니다.

```bash
cd ~/sub1s-deploy
chmod +x setup-swap.sh
sudo ./setup-swap.sh 4G
```

* **적용 내역**:
  - `/swapfile` (4GB) 생성 및 `/etc/fstab` 영속 등록
  - `vm.swappiness = 15` (불필요한 스왑 I/O 방지)
  - `vm.vfs_cache_pressure = 50`
  - `vm.overcommit_memory = 1`

---

## 🔒 4. 방화벽 (포트 개방) 설정

1. **OCI 콘솔 수신 규칙 (Ingress Rules)**:
   - 포트 `80` (HTTP), `443` (HTTPS) 인바운드 허용 (`0.0.0.0/0`)
2. **Ubuntu OS 방화벽 (iptables)**:
   ```bash
   sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
   sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
   sudo netfilter-persistent save
   ```

---

## 🌐 5. 도메인 연결 및 최초 SSL 발급

OCI 공인 IP를 보유하신 개인 도메인(예: `api.sub1s.com`)의 DNS A 레코드에 등록한 후 실행합니다.

```bash
# 환경변수 파일 복사 및 값 수정
cp .env.example .env
nano .env

# 최초 SSL 인증서 자동 발급 및 Nginx 기동
chmod +x init-letsencrypt.sh
./init-letsencrypt.sh api.sub1s.com your-email@example.com
```

---

## 🚀 6. 전체 컨테이너 구동 및 데이터 시딩

```bash
# 1. 전체 서비스 백그라운드 구동
docker compose up -d

# 2. 서비스 상태 점검
docker compose ps

# 3. 최초 1회 데이터베이스 스키마 생성 및 지하철 그래프 데이터 시딩
# (server 컨테이너 내부 또는 호스트에서 실행)
docker compose exec server npx prisma db push
docker compose exec server node dist/src/scripts/seed-subway-graph.js
```

---

## 🩺 7. 배포 검증 커맨드

```bash
# 1. 백엔드 시스템 헬스체크
curl -sf https://api.sub1s.com/api/health

# 2. AI 워커 헬스체크 (내부 포트 8000)
docker compose exec ai curl -sf http://localhost:8000/health

# 3. WebSocket 실시간 WSS 핸드셰이크 점검
curl -sf "https://api.sub1s.com/socket.io/?EIO=4&transport=polling"

# 4. 실시간 컨테이너 리소스 점검 (메모리 누수 감시)
docker stats
```
