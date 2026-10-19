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

## 🧪 6.1 부하 테스트 모드

부하 테스트 동안 **외부 API(서울시, 공공데이터, V-World, 푸시) 호출과 한도 소모를 막고** nginx의 IP당 속도 제한(인증 없는 요청 30건/초)을 풀어서 서버의 진짜 한계를 보는 모드다. 서버 코드는 바꾸지 않는다(외부 API 제공자는 키가 비면 경고만 남기고 꺼진다).

```bash
cd ~/sub1s-deploy
./loadtest.sh status         # 지금 모드와 자동 복구까지 남은 시간(키는 설정 여부만 출력)
./loadtest.sh on 90m         # 테스트 모드 켜기. 90분 뒤 자동으로 기본 설정 복구(기본 60m, 0이면 자동 복구 없음)
./loadtest.sh off            # 기본 설정으로 바로 되돌리기(자동 복구 타이머도 취소)
./loadtest.sh observe 60m    # 5초마다 CPU, 메모리, 스왑, 부하, DB 연결 수를 TSV로 출력
# 파일로 받으려면: nohup ./loadtest.sh observe 60m > ~/observe.tsv 2> ~/observe.err &
# 테스트 동안 CPU를 쓰는 컨테이너를 같이 멈추려면(off가 다시 켠다)
LOADTEST_STOP="ai server-mock" ./loadtest.sh on 90m
```

- 켜면 `docker-compose.loadtest.yml`이 서버의 외부 서비스 키(서울시 실시간, 서울 열린데이터, 공공데이터, V-World, Expo, 데이터 알림)를 비우고 `TRAIN_POSITION_ENABLED`, `PUSH_SCHEDULER_ENABLED`를 끈다. nginx는 `nginx/nginx.loadtest.conf`(속도 제한만 사실상 해제)를 쓴다.
- **서버 컨테이너의 CPU 0.4코어, 메모리 768MB 제한은 그대로다.** 운영 용량 그대로 재기 위해서다.
- **자동 복구**: `on`이 정한 시간 뒤에 `off`를 실행하는 systemd 타이머(`sub1s-loadtest-off`)를 만든다. SSH를 끊어도 동작하고 `off`를 직접 하면 취소된다. 시간 형식은 `90m`, `2h`, `3600s`, 숫자만이면 분이다.
- 이 파일은 `docker-compose.override.yml`이 아니라서 자동으로 읽히지 않는다. 배포 워크플로는 기본 파일만으로 `docker compose up -d`를 하므로 **다음 배포가 돌아도 테스트 모드는 꺼진다.**
- `loadtest.sh`와 `docker-compose.loadtest.yml`은 배포 워크플로가 서버로 복사한다(`nginx/`는 원래 복사 대상).
- `nginx.conf`를 바꾸면 `nginx.loadtest.conf`도 같이 맞춘다.
- 테스트 모드에서는 열차 위치, 알림, 장소 검색이 동작하지 않는다. 사용자가 앱을 쓰지 않을 때만 켠다.

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

## 8. Android 초대 링크 도메인 연결

앱 PR [#148](https://github.com/z1zone-team/sub1s-app/pull/148)은 초대 링크를 `https://sub1s.devnoco.com/invite/:token`으로 만들고 Android intent filter를 설정한다. 이 저장소는 `https://sub1s.devnoco.com/.well-known/assetlinks.json`에서 해당 앱의 패키지명과 공개 서명 인증서 지문을 제공한다. 앱 설정과 웹 서버 연결 파일이 모두 적용되어야 Android가 도메인을 검증할 수 있다.

현재 등록한 앱은 **개발 빌드 `com.z1zone.sub1s.local`만**이다(사용자 결정). `app-debug.apk`에서 `apksigner verify --print-certs`로 확인한 SHA-256 인증서 지문을 사용한다. 다른 개발 키로 서명한 APK나 스토어용 `com.z1zone.sub1s`는 연결되지 않는다. 스토어용 연결은 실제 배포 서명 인증서가 정해지면 별도 항목을 추가한다. Google Play App Signing 사용 시 배포 앱의 서명 인증서 지문을 사용한다.

파일은 `nginx/assetlinks.json`에 있으며 Nginx 컨테이너에 읽기 전용 마운트한다. 기존 OCI 배포 workflow가 `nginx/`를 복사하고 Nginx 컨테이너를 다시 생성하므로 이 파일도 함께 배포된다. 공개 인증서 지문에는 비밀키가 포함되지 않는다. iOS는 이번 작업에서 보류한다.

### 배포 및 실기기 확인

1. 앱 PR #148과 이 배포 변경을 머지한다(사용자가 진행). deploy main 변경은 기존 OCI workflow로 자동 배포된다.
2. 연결 파일을 조회해 HTTP 200, `Content-Type: application/json`, JSON 본문을 확인한다. HTTPS 연결 파일은 다른 주소로 리다이렉트하면 안 된다.
3. 앱 설정이 포함되도록 Android 개발 앱을 재빌드해 설치한다. Metro 새로고침만으로 네이티브 intent filter가 바뀌지는 않는다.
4. Android 12 이상에서 도메인 검증 상태를 확인하고 실제로 공유한 초대 링크를 누른다.

```bash
curl -i https://sub1s.devnoco.com/.well-known/assetlinks.json
adb shell pm verify-app-links --re-verify com.z1zone.sub1s.local
# 검증에 시간이 걸릴 수 있으므로 기다린 뒤 확인한다
adb shell pm get-app-links com.z1zone.sub1s.local
# <실제_초대_토큰>을 공유한 링크의 16자리 토큰으로 바꾼다
adb shell am start -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "https://sub1s.devnoco.com/invite/<실제_초대_토큰>"
```

참고: [Expo Android App Links](https://docs.expo.dev/linking/android-app-links/), [Android 링크 검증](https://developer.android.com/training/app-links/verify-android-applinks).

## 9. 보행 경로(OSRM) 데이터 준비

서버가 걷는 구간을 실제 보행로로 구하도록(서버 이슈 #188 / PR #189) OSRM 컨테이너(`sub1s-osrm`)가 함께 뜬다.
**데이터를 만들기 전에는 컨테이너가 안내 문구만 남기고 대기하고, 서버는 응답이 없으면 직선 추정(직선 거리 x 1.25)으로 돌아가므로** 데이터 준비 전에 배포해도 서비스에는 영향이 없다.

### 처음 한 번 (그리고 데이터를 새로 받고 싶을 때)

한국 OSM 데이터(약 290MB)를 받아 OSRM 보행(foot) 데이터로 만든다. 서버는 1코어라 20분 남짓 걸려(실측 22분: 받기 약 2분, 추출 약 14분, 구역 나누기 약 6분) 끊겨도 이어지도록 `nohup`으로 돌린다.
처리 중에는 도커 컨테이너의 메모리(4GB)와 CPU(0.8코어)를 제한하고, 끝나면 `osrm` 컨테이너를 다시 띄운다.

> **메모리 주의**: 추출 단계에서 컨테이너가 4GB 상한 가까이(캐시 포함 4GiB) 쓰고, 그동안 서버 전체의 사용 가능 메모리가 약 600MB까지 내려간다. 다른 컨테이너의 메모리가 스왑으로 밀려 음성 인식(AI)의 첫 요청이 평소보다 느릴 수 있으므로 한가한 시간에 실행한다. 3GB 상한으로 돌리면 추출 마지막 단계에서 강제 종료(OOM)되므로 줄이지 않는다. 서비스 응답(`/api/health`)은 처리 중에도 정상이었다.

```bash
cd ~/sub1s-deploy
sudo nohup ./osrm/prepare.sh > osrm-prepare.log 2>&1 &
tail -f osrm-prepare.log        # 진행 확인. "완료"가 나오면 끝
```

만들어진 데이터는 도커 볼륨 `sub1s_osrm_data`에 약 3GB로 남는다(디스크 여유 10GB 이상 필요). 처리 중에는 `osrm` 컨테이너를 잠시 멈추므로 그동안 서버는 직선 추정을 쓴다.
데이터는 Geofabrik이 매일 갱신하지만 자주 바꿀 필요는 없다. 지도가 오래됐다고 느껴질 때(예: 분기마다) 같은 명령을 다시 실행한다.

### 확인

```bash
# 1. 컨테이너가 데이터를 읽어 떠 있는지 (대기 문구가 아니라 실행 로그가 보여야 한다)
sudo docker compose logs --tail 5 osrm

# 2. 서버 컨테이너에서 OSRM 호출 (경기광주 부근 약 1.3km 보행 경로, "code":"Ok"가 나와야 한다)
sudo docker compose exec -T server node -e "fetch('http://osrm:5000/route/v1/foot/127.2528,37.409;127.25263,37.399907?overview=false').then(r=>r.text()).then(console.log)"

# 3. 메모리 (osrm이 2GB 안팎)
sudo docker stats --no-stream
```

앱에서는 좌표로 경로를 검색했을 때 도보 구간 점선이 직선이 아니라 길을 따라가고, 응답의 `walkDistanceSource`가 `ROUTED`(환승 걷기가 없을 때)가 된다.

### 끄기

`sudo docker compose stop osrm`으로 멈추면 서버가 알아서(첫 실패 뒤 30초 동안 호출을 건너뛰며) 직선 추정으로 돌아간다. 다시 켜려면 `sudo docker compose up -d osrm`.

### 참고

- 이미지는 태그에 버전이 없어 다이제스트로 고정했다(`docker-compose.yml`과 `osrm/prepare.sh`의 `OSRM_IMAGE`). 다른 버전으로 올릴 때는 **둘을 같이 바꾸고 데이터를 다시 만들어야** 한다(엔진 버전이 다르면 만든 데이터를 읽지 못할 수 있다)
- OSM 데이터는 ODbL이라 출처 표기가 필요하다(앱에 "© OpenStreetMap contributors" 표기를 넣는 일은 앱 쪽 과제)
- 서버 사양(ARM, 1코어, 메모리 5.8GiB)에서 `osrm`의 메모리 상한은 2.5GB다. 음성 인식 등 다른 컨테이너와 함께 쓸 때 메모리가 부족하면 `docker stats`로 확인하고 상한을 조정한다

## 10. 열차 위치 mock 서버 (`server-mock`)

지도에 보이는 열차(`GET /api/v1/trains/positions`)는 `server-mock` 컨테이너가 가짜 열차로 답하고, nginx가 이 경로만 그쪽으로 보낸다. 서울시 실시간 API는 키 하나에 하루 1,000회라서 `server` 컨테이너가 그 호출을 시간표가 빠진 곳을 채우는 수집에 쓰기 때문이다.

- 같은 서버 이미지를 `TRAIN_POSITION_SOURCE=MOCK`으로 띄운다. 서울시 키는 주지 않는다.
- 정산 스케줄러(`PUSH_SCHEDULER_ENABLED=false`)와 음성 작업 처리기(`VALKEY_HOST` 없음)는 꺼 둔다. 서버는 시작할 때 DB에 연결하므로 `DATABASE_URL`은 넘기지만 DB에 쓰지 않는다.
- 응답의 `source`가 `MOCK`이다. 앱은 이 값으로 "시연용"임을 알려야 한다.
- 호선과 갱신 간격은 `MOCK_TRAIN_POSITION_LINES`(기본 01~09), `MOCK_TRAIN_POSITION_INTERVAL_SEC`(기본 3초)로 바꾼다. 호선을 하나씩 돌며 갱신하므로 한 호선의 갱신 주기는 호선 수 x 간격이다.
- nginx는 주소를 요청 때 해석한다. `server-mock`이 내려가 있어도 nginx는 뜨고 열차 위치만 502가 된다.

```bash
sudo docker compose up -d server-mock
sudo docker compose exec nginx nginx -s reload
curl -s "https://sub1s.devnoco.com/api/v1/trains/positions?lineId=03"   # "source":"MOCK"이 나와야 한다
sudo docker compose stop server-mock                                       # 끄기
```
