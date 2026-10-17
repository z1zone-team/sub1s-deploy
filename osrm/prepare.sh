#!/usr/bin/env bash
# 한국 OSM 데이터를 받아 OSRM 보행(foot) 데이터로 만든다.
# 운영 서버에서 처음 한 번, 그리고 데이터를 새로 받고 싶을 때 실행한다(README 9장). 도커 권한이 필요해 sudo로 실행한다.
#   sudo nohup ./osrm/prepare.sh > osrm-prepare.log 2>&1 &
#
# 서버는 1코어라 처리에 몇십 분이 걸릴 수 있다. 처리 컨테이너는 메모리와 CPU를 제한해 다른 서비스가 밀리지 않게 한다.
# OSRM 이미지는 다운로드 도구가 없어 받기는 curl 이미지로 따로 하고, 처리는 OSRM 이미지로 한다.
set -euo pipefail

# docker-compose.yml의 osrm 서비스와 같은 이미지여야 한다(엔진 버전이 다르면 만든 데이터를 읽지 못할 수 있다)
IMAGE="${OSRM_IMAGE:-ghcr.io/project-osrm/osrm-backend@sha256:55dbfd47d984c2cacd64e32901b4321c86b5ec761438e69aa053dc78698a786f}"
VOLUME="${OSRM_VOLUME:-sub1s_osrm_data}"
PBF_URL="${OSRM_PBF_URL:-https://download.geofabrik.de/asia/south-korea-latest.osm.pbf}"
MEMORY="${OSRM_PREPARE_MEMORY:-3g}"
CPUS="${OSRM_PREPARE_CPUS:-0.8}"
MIN_FREE_GB="${OSRM_MIN_FREE_GB:-10}"
NAME="south-korea"

cd "$(dirname "$0")/.."
started=$(date +%s)
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# 디스크 여유 확인 (받은 파일 0.3GB + 처리 결과 3GB + 여유)
free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
  echo "디스크 여유가 ${free_gb}GB뿐입니다. ${MIN_FREE_GB}GB 이상 필요합니다." >&2
  exit 1
fi

docker volume create "$VOLUME" > /dev/null

log "1/5 osrm 컨테이너를 멈춥니다(처리 중에는 서버가 직선 추정을 씁니다)"
docker compose stop osrm || true

log "2/5 한국 OSM 데이터를 받습니다 ($PBF_URL)"
docker run --rm --user 0 -v "$VOLUME:/data" curlimages/curl:8.11.1 \
  -fL --retry 3 --retry-delay 5 -o "/data/$NAME.osm.pbf.part" "$PBF_URL"
docker run --rm -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c \
  "mv /data/$NAME.osm.pbf.part /data/$NAME.osm.pbf && rm -f /data/$NAME.osrm.*"

osrm() {
  docker run --rm -v "$VOLUME:/data" --memory "$MEMORY" --cpus "$CPUS" "$IMAGE" "$@"
}

log "3/5 도로 데이터를 읽습니다(extract, 가장 오래 걸립니다)"
osrm osrm-extract -p /opt/foot.lua "/data/$NAME.osm.pbf"
log "4/5 구역을 나눕니다(partition, customize)"
osrm osrm-partition "/data/$NAME.osrm"
osrm osrm-customize "/data/$NAME.osrm"

log "5/5 받은 원본을 지우고 osrm 컨테이너를 다시 띄웁니다"
docker run --rm -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c "rm -f /data/$NAME.osm.pbf"
docker compose up -d osrm

elapsed=$(( $(date +%s) - started ))
log "완료 (${elapsed}초). README 9장의 '확인'으로 동작을 확인하세요"
