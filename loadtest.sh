#!/usr/bin/env bash
# 부하 테스트 모드를 켜고 끄고 확인한다. 서버(deploy 디렉터리)에서 실행한다.
#   ./loadtest.sh on [시간]    외부 API 호출과 백그라운드 작업을 끄고 nginx 속도 제한을 푼다.
#                              시간(90m, 2h, 3600s, 숫자만이면 분)이 지나면 자동으로 off. 기본 60m, 0이면 자동 복구 없음
#   ./loadtest.sh off          기본 설정으로 되돌린다(자동 복구 타이머도 취소)
#   ./loadtest.sh status       지금 모드와 자동 복구까지 남은 시간(키 값은 보여 주지 않고 설정 여부만)
#   ./loadtest.sh observe [시간]  5초마다 컨테이너 CPU, 메모리, 스왑, 부하, DB 연결 수, 호스트 CPU와 steal을 TSV로 출력(기본 60m). 파일로 받으려면 nohup과 > 로 리다이렉트
# 선택: LOADTEST_STOP="ai server-mock" ./loadtest.sh on  처럼 테스트 동안 같이 멈출 컨테이너를 지정한다(off가 다시 켠다)
set -euo pipefail
cd "$(dirname "$0")"

DC="sudo docker compose"
TEST_FILES=(-f docker-compose.yml -f docker-compose.loadtest.yml)
TIMER_UNIT="sub1s-loadtest-off"

# "90m", "2h", "3600s", "90"(분) -> 초. 0, none은 0. 형식이 틀리면 종료
ttl_seconds() {
  local v="${1:-${LOADTEST_TTL:-60m}}"
  if [ "$v" = "0" ] || [ "$v" = "none" ]; then echo 0; return; fi
  if [[ "$v" =~ ^([0-9]+)([smh]?)$ ]]; then
    local n="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in
      s) echo "$n" ;;
      h) echo $((n * 3600)) ;;
      *) echo $((n * 60)) ;;
    esac
    return
  fi
  echo "시간 형식이 올바르지 않다: '$v' (예: 90m, 2h, 3600s, 0)" >&2
  exit 1
}

# 자동 복구 타이머만 멈춘다(타이머가 실행한 off가 자기 자신을 끊지 않도록 service는 건드리지 않는다)
cancel_timer() {
  sudo systemctl stop "$TIMER_UNIT.timer" 2>/dev/null || true
  sudo systemctl reset-failed "$TIMER_UNIT.timer" "$TIMER_UNIT.service" 2>/dev/null || true
}

case "${1:-status}" in
  on)
    secs=$(ttl_seconds "${2:-}")
    $DC "${TEST_FILES[@]}" config -q
    $DC "${TEST_FILES[@]}" up -d --no-deps --force-recreate server nginx
    if [ -n "${LOADTEST_STOP:-}" ]; then
      # shellcheck disable=SC2086
      $DC stop $LOADTEST_STOP
    fi
    cancel_timer
    if [ "$secs" -gt 0 ]; then
      sudo systemd-run --quiet --unit "$TIMER_UNIT" --on-active="${secs}s" \
        --working-directory="$PWD" "$PWD/loadtest.sh" off
      echo "테스트 모드 ON. ${secs}초 뒤 자동으로 기본 설정으로 돌아온다(타이머 $TIMER_UNIT). 먼저 끝나면 ./loadtest.sh off"
    else
      echo "테스트 모드 ON. 자동 복구 없음. 끝나면 ./loadtest.sh off (다음 배포가 돌아도 꺼진다)"
    fi
    ;;
  off)
    cancel_timer
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
    echo "== 자동 복구 타이머"
    timer=$(sudo systemctl list-timers "$TIMER_UNIT.timer" --no-legend 2>/dev/null || true)
    if [ -n "$timer" ]; then echo "$timer"; else echo "없음"; fi
    ;;
  observe)
    dur=$(ttl_seconds "${2:-60m}")
    interval="${INTERVAL:-5}"
    end=$(( $(date +%s) + dur ))
    printf 'time\tcontainer\tcpu\tmem\tavail_mb\tswap_used_mb\tload1\tpg_conns\thost_cpu\thost_steal\n'
    prev_total=0; prev_idle=0; prev_steal=0
    while [ "$(date +%s)" -lt "$end" ]; do
      ts=$(date +%H:%M:%S)
      avail=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
      swap=$(awk '/SwapTotal/ {t=$2} /SwapFree/ {f=$2} END {printf "%d", (t-f)/1024}' /proc/meminfo)
      load=$(cut -d' ' -f1 /proc/loadavg)
      # 호스트 전체 CPU 사용률(%)과 steal(%). 직전 기록 이후의 변화량으로 구한다. 첫 기록은 -
      read -r _ c_user c_nice c_sys c_idle c_iow c_irq c_sirq c_steal _ < /proc/stat
      c_total=$((c_user + c_nice + c_sys + c_idle + c_iow + c_irq + c_sirq + c_steal))
      c_idle_all=$((c_idle + c_iow))
      if [ "$prev_total" -gt 0 ] && [ "$c_total" -gt "$prev_total" ]; then
        d_total=$((c_total - prev_total))
        host_cpu=$(awk -v t="$d_total" -v i="$((c_idle_all - prev_idle))" 'BEGIN {printf "%.1f", (t - i) * 100 / t}')
        host_steal=$(awk -v t="$d_total" -v s="$((c_steal - prev_steal))" 'BEGIN {printf "%.1f", s * 100 / t}')
      else
        host_cpu="-"; host_steal="-"
      fi
      prev_total=$c_total; prev_idle=$c_idle_all; prev_steal=$c_steal
      conns=$($DC exec -T postgres psql -U sub1s_user -d sub1s_db -At -c "select count(*) from pg_stat_activity" 2>/dev/null || echo "-")
      if [ "$avail" -lt 500 ]; then echo "[경고] $ts 사용 가능한 메모리 ${avail}MB (500MB 미만)" >&2; fi
      sudo docker stats --no-stream --format '{{.Name}}	{{.CPUPerc}}	{{.MemUsage}}' | while IFS=$'\t' read -r name cpu mem; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$name" "$cpu" "$mem" "$avail" "$swap" "$load" "$conns" "$host_cpu" "$host_steal"
      done
      sleep "$interval"
    done
    ;;
  *)
    echo "usage: $0 on [시간] | off | status | observe [시간]" >&2
    exit 1
    ;;
esac
