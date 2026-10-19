#!/usr/bin/env bash
# 부하 테스트 모드를 켜고 끄고 확인한다. 서버(deploy 디렉터리)에서 실행한다.
#   ./loadtest.sh on       외부 API 호출과 백그라운드 작업을 끄고 nginx 속도 제한을 푼다
#   ./loadtest.sh off      기본 설정으로 되돌린다
#   ./loadtest.sh status   지금 모드를 보여 준다(키 값은 보여 주지 않고 설정 여부만)
# 선택: LOADTEST_STOP="ai server-mock" ./loadtest.sh on  처럼 테스트 동안 같이 멈출 컨테이너를 지정한다(off가 다시 켠다)
set -euo pipefail
cd "$(dirname "$0")"

DC="sudo docker compose"
TEST_FILES=(-f docker-compose.yml -f docker-compose.loadtest.yml)

case "${1:-status}" in
  on)
    $DC "${TEST_FILES[@]}" config -q
    $DC "${TEST_FILES[@]}" up -d --no-deps --force-recreate server nginx
    if [ -n "${LOADTEST_STOP:-}" ]; then
      # shellcheck disable=SC2086
      $DC stop $LOADTEST_STOP
    fi
    echo "테스트 모드 ON. 끝나면 ./loadtest.sh off (다음 배포가 돌아도 자동으로 꺼진다)"
    ;;
  off)
    $DC up -d --no-deps --force-recreate server nginx
    # 테스트 동안 멈춘 컨테이너가 있으면 다시 켠다
    $DC up -d
    echo "테스트 모드 OFF(기본 설정)"
    ;;
  status)
    echo "== server 환경(키는 설정 여부만)"
    $DC exec -T server sh -c '
      for v in SEOUL_SUBWAY_REALTIME_API_KEY SEOUL_OPEN_API_KEY PUBLIC_DATA_API_KEY VWORLD_API_KEY EXPO_ACCESS_TOKEN; do
        eval "val=\${$v:-}"; [ -n "$val" ] && echo "$v: 설정됨" || echo "$v: 비어 있음"
      done
      echo "TRAIN_POSITION_ENABLED=${TRAIN_POSITION_ENABLED:-}"
      echo "PUSH_SCHEDULER_ENABLED=${PUSH_SCHEDULER_ENABLED:-}"'
    echo "== nginx 속도 제한(limit_req_zone)"
    $DC exec -T nginx nginx -T 2>/dev/null | grep -E "limit_req_zone" || true
    ;;
  *)
    echo "usage: $0 on|off|status" >&2
    exit 1
    ;;
esac
