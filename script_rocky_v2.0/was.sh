#!/usr/bin/env bash
#
# tomcat-ctl.sh
# /data 하위에 설치된 여러 버전의 Apache Tomcat 을 관리하는 스크립트
# (Rocky Linux 8.10 기준)
#
# - 디렉토리 이름/깊이에 상관없이 bin/catalina.sh 존재 여부로 자동 탐색
# - 기동/중지/재기동/상태/포트 확인을 함수 단위로 제공 (확장 용이)
# - 이름이 같은 톰캣이 여러 개 있어도 list 의 번호(NUM) 로 안전하게 지정 가능
# - 개별 지정(번호/전체경로) 또는 'all' 로 전체 일괄 처리 가능
# - start/stop/restart/status 를 인자 없이 실행하면 목록을 보여주고
#   번호를 입력받는 대화식 모드로 동작
#
# 사용법: tomcat-ctl.sh {list|start|stop|restart|status|ports|help} [번호|경로|all]
#
set -o pipefail

# ------------------------------------------------------------------
# 환경 설정 (필요 시 이 영역만 수정하면 됨)
# ------------------------------------------------------------------
BASE_DIR="/data"    # 톰캣을 찾을 최상위 경로 (하위 구조/깊이는 자유, 이름도 무관)
MAX_DEPTH=6          # BASE_DIR 기준 탐색할 최대 깊이 (너무 크면 탐색이 느려짐)
STOP_TIMEOUT=30       # 정지 대기 시간(초), 초과 시 강제 종료
START_WAIT=2          # 기동 명령 후 기동 확인까지 대기(초)
LOG_LINES=200         # log 명령 기본 출력 줄 수 (tail)

# 색상 출력
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_NC='\033[0m'

log_info()  { echo -e "${C_BLUE}[INFO]${C_NC} $*"; }
log_ok()    { echo -e "${C_GREEN}[ OK ]${C_NC} $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_NC} $*"; }
log_err()   { echo -e "${C_RED}[FAIL]${C_NC} $*" >&2; }

# ==================================================================
# 탐색 / 경로 처리 함수
# ==================================================================

# BASE_DIR 하위(설정한 MAX_DEPTH 이내)에서 실제 톰캣 설치 위치를 탐색.
# 디렉토리 "이름"이 아니라 bin/catalina.sh 실행파일이 존재하는지로 판별하므로
# /data/tomcat, /data/tmp/tomcat, /data/svc/was01/tomcat-9 등 어떤 이름/깊이여도 인식됨.
tomcat_discover() {
    find "$BASE_DIR" -maxdepth "$MAX_DEPTH" -type f -name 'catalina.sh' -path '*/bin/catalina.sh' 2>/dev/null \
        | sed 's#/bin/catalina\.sh$##' \
        | sort -u
}

# 사용자가 입력한 이름(절대경로 / 디렉토리명 / 경로 일부 / 버전문자열)을
# 실제 CATALINA_HOME 절대경로로 변환.
# 이름 패턴에 의존하지 않고, tomcat_discover 로 찾은 실제 설치 목록을 대상으로
# (1) 완전 일치 -> (2) 부분 일치 순으로 매칭한다. 매칭이 여러 개면 모호하다고 알리고
# 전체 경로 지정을 요구한다 (잘못된 톰캣을 기동/중지하는 사고 방지).
tomcat_resolve_home() {
    local name="$1" h
    local -a all_homes=() matches=()

    while IFS= read -r h; do
        [[ -n "$h" ]] && all_homes+=("$h")
    done < <(tomcat_discover)

    # 0) 사용자가 절대/상대 경로를 직접 준 경우: 실제 catalina.sh 가 있어야 인정
    name="${name%/}"
    if [[ -d "$name" && -x "${name}/bin/catalina.sh" ]]; then
        echo "$name"
        return 0
    fi

    # 1) 설치 경로의 마지막 디렉토리명과 완전 일치
    for h in "${all_homes[@]}"; do
        [[ "$(basename "$h")" == "$name" ]] && matches+=("$h")
    done

    # 2) 완전 일치가 없으면 전체 경로 문자열에 부분 일치 (버전 문자열 등)
    if [[ ${#matches[@]} -eq 0 ]]; then
        for h in "${all_homes[@]}"; do
            [[ "$h" == *"$name"* ]] && matches+=("$h")
        done
    fi

    case "${#matches[@]}" in
        0)
            return 1
            ;;
        1)
            echo "${matches[0]}"
            return 0
            ;;
        *)
            log_err "'${name}' 에 매칭되는 톰캣이 여러 개입니다. 전체 경로로 지정해주세요:"
            printf '  %s\n' "${matches[@]}" >&2
            return 1
            ;;
    esac
}

# 실행 중 번호 선택에 사용할 전역 인덱스 배열
declare -a TCH_HOMES=()

# TCH_HOMES 를 현재 탐색 결과로 새로 채움 (호출 시점마다 최신 상태 반영)
tomcat_build_index() {
    TCH_HOMES=()
    local h
    while IFS= read -r h; do
        [[ -n "$h" ]] && TCH_HOMES+=("$h")
    done < <(tomcat_discover)
}

# 각 톰캣의 PID 파일 경로 (톰캣 홈 바로 아래 저장하여 버전간 충돌 방지)
tomcat_pid_file() {
    echo "$1/tomcat.pid"
}

# ==================================================================
# 상태 조회 함수
# ==================================================================

# 실행 중인 PID 조회. 성공 시 stdout 으로 PID 출력, return 0
tomcat_get_pid() {
    local home="$1" pidfile pid
    pidfile=$(tomcat_pid_file "$home")

    if [[ -f "$pidfile" ]]; then
        pid=$(cat "$pidfile" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi

    # pid 파일이 없거나 유효하지 않으면 프로세스 목록에서 CATALINA_BASE 로 재탐색
    pid=$(pgrep -f "catalina.base=${home}([[:space:]]|$)" | head -n1)
    if [[ -n "$pid" ]]; then
        echo "$pid"
        return 0
    fi

    return 1
}

# Connector 태그 한 줄에서 port 속성값 추출 (속성 순서 무관)
_extract_port() {
    grep -oP 'port="[0-9]+"' <<< "$1" | head -n1 | grep -oP '[0-9]+'
}

# server.xml 파싱 공통 로직: "shutdown|http1,http2|ajp1,ajp2" 형태로 출력
_tomcat_parse_ports() {
    local home="$1" server_xml="$1/conf/server.xml"
    local shutdown_port="" http_ports="" ajp_ports="" line port

    if [[ ! -f "$server_xml" ]]; then
        echo "||"
        return 1
    fi

    line=$(grep '<Server' "$server_xml" | head -n1)
    shutdown_port=$(_extract_port "$line")

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        port=$(_extract_port "$line")
        [[ -z "$port" ]] && continue
        if grep -q 'protocol="HTTP/1\.1"' <<< "$line" || ! grep -q 'protocol=' <<< "$line"; then
            http_ports+="${port},"
        elif grep -q 'protocol="AJP/1\.3"' <<< "$line"; then
            ajp_ports+="${port},"
        fi
    done < <(grep '<Connector' "$server_xml")

    echo "${shutdown_port}|${http_ports%,}|${ajp_ports%,}"
}

# server.xml 에서 shutdown / HTTP / AJP 포트 파싱 (상세 표시용)
tomcat_get_ports() {
    local home="$1" parsed shutdown_port http_ports ajp_ports

    parsed=$(_tomcat_parse_ports "$home") || { echo "server.xml 없음"; return 1; }
    IFS='|' read -r shutdown_port http_ports ajp_ports <<< "$parsed"

    echo "shutdown=${shutdown_port:-N/A}  http=${http_ports:-N/A}  ajp=${ajp_ports:-N/A}"
}

# list 테이블용 압축 포트 표시: "http/ajp" (없으면 -)
tomcat_ports_summary() {
    local home="$1" parsed shutdown_port http_ports ajp_ports

    parsed=$(_tomcat_parse_ports "$home") || { echo "N/A"; return; }
    IFS='|' read -r shutdown_port http_ports ajp_ports <<< "$parsed"

    echo "${http_ports:--}/${ajp_ports:--}"
}

# 지정 포트가 실제 LISTEN 상태인지 확인
tomcat_check_listen() {
    local port="$1"
    ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q ":${port}[[:space:]]"
}

# ==================================================================
# 제어 함수 (기동 / 중지 / 재기동 / 상태)
# ==================================================================

tomcat_start() {
    local name="$1" home pid
    home=$(tomcat_resolve_home "$name") || { log_err "톰캣 홈을 찾을 수 없습니다: $name"; return 1; }

    if pid=$(tomcat_get_pid "$home"); then
        log_warn "$(basename "$home") 은(는) 이미 실행중입니다 (PID=$pid)"
        return 0
    fi

    if [[ ! -x "${home}/bin/catalina.sh" ]]; then
        log_err "catalina.sh 실행 파일이 없습니다: ${home}/bin/catalina.sh"
        return 1
    fi

    (
        export CATALINA_HOME="$home"
        export CATALINA_BASE="$home"
        export CATALINA_PID
        CATALINA_PID=$(tomcat_pid_file "$home")
        cd "$home" || exit 1
        "${home}/bin/catalina.sh" start >/dev/null 2>&1
    )

    log_info "$(basename "$home") 기동중..."
    sleep "$START_WAIT"

    if pid=$(tomcat_get_pid "$home"); then
        log_ok "$(basename "$home") 기동 완료 (PID=$pid)"
    else
        log_err "$(basename "$home") 기동 실패. 로그 확인: ${home}/logs/catalina.out"
        return 1
    fi
}

tomcat_stop() {
    local name="$1" home pid waited=0
    home=$(tomcat_resolve_home "$name") || { log_err "톰캣 홈을 찾을 수 없습니다: $name"; return 1; }

    if ! pid=$(tomcat_get_pid "$home"); then
        log_warn "$(basename "$home") 은(는) 이미 중지 상태입니다"
        return 0
    fi

    log_info "$(basename "$home") 정지중... (PID=$pid)"
    (
        export CATALINA_HOME="$home"
        export CATALINA_BASE="$home"
        export CATALINA_PID
        CATALINA_PID=$(tomcat_pid_file "$home")
        "${home}/bin/catalina.sh" stop "$STOP_TIMEOUT" -force >/dev/null 2>&1
    )

    while kill -0 "$pid" 2>/dev/null && [[ $waited -lt $STOP_TIMEOUT ]]; do
        sleep 1
        ((waited++))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log_warn "정상 종료 실패, kill -9 로 강제 종료합니다"
        kill -9 "$pid" 2>/dev/null
    fi

    rm -f "$(tomcat_pid_file "$home")"
    log_ok "$(basename "$home") 정지 완료"
}

tomcat_restart() {
    local name="$1"
    tomcat_stop "$name"
    sleep 2
    tomcat_start "$name"
}

tomcat_status() {
    local name="$1" home pid ports http_ports p
    home=$(tomcat_resolve_home "$name") || { log_err "톰캣 홈을 찾을 수 없습니다: $name"; return 1; }

    if pid=$(tomcat_get_pid "$home"); then
        log_ok "$(basename "$home") : 실행중 (PID=$pid)"
    else
        log_warn "$(basename "$home") : 중지됨"
    fi

    echo "        경로 : $home"
    ports=$(tomcat_get_ports "$home")
    echo "        포트 : $ports"

    if [[ -n "${pid:-}" && -f "${home}/conf/server.xml" ]]; then
        http_ports=$(grep -oP '<Connector[^>]*protocol="HTTP/1\.1"[^>]*port="\K[0-9]+' "${home}/conf/server.xml")
        for p in $http_ports; do
            if tomcat_check_listen "$p"; then
                echo "        LISTEN($p) : OK"
            else
                echo "        LISTEN($p) : 응답없음"
            fi
        done
    fi
}

# ==================================================================
# 로그 (catalina.out) 탐색 / 조회
# ==================================================================

# catalina.out 실제 경로를 찾는다. 표준 위치가 아닐 수 있으므로 아래 순서로 탐색:
#   1) 실행 중이면 실제 프로세스의 표준출력(fd 1)이 가리키는 파일을 최우선 확인.
#      setenv.sh 파싱과 달리 systemd/wrapper 등 어떤 방식으로 리다이렉트했든
#      실제 값 그대로 반영되므로 가장 정확하다.
#   2) bin/setenv.sh (없으면 bin/catalina.sh) 에 정의된 CATALINA_OUT
#   3) 표준 기본 위치: $CATALINA_BASE/logs/catalina.out
#   4) logs 대신 log 등 다른 디렉토리명을 쓰는 경우를 대비해 홈 하위 폭넓게 탐색
tomcat_find_catalina_out() {
    local home="$1" catalina_out="" f pid

    # 1) 실행 중인 프로세스의 fd/1 (가장 신뢰도 높음)
    if pid=$(tomcat_get_pid "$home" 2>/dev/null); then
        catalina_out=$(readlink -f "/proc/${pid}/fd/1" 2>/dev/null)
        # 파이프/소켓/삭제된 파일 등은 -f 검사에서 자연히 걸러짐
        if [[ -n "$catalina_out" && -f "$catalina_out" ]]; then
            echo "$catalina_out"
            return 0
        fi
    fi

    # 2) 설정 파일에 지정된 CATALINA_OUT
    catalina_out=""
    for f in "${home}/bin/setenv.sh" "${home}/bin/catalina.sh"; do
        [[ -f "$f" ]] || continue
        catalina_out=$(grep -oP '(?<![A-Za-z_])CATALINA_OUT\s*=\s*"?\K[^"[:space:]]+' "$f" | tail -n1)
        [[ -n "$catalina_out" ]] && break
    done

    if [[ -n "$catalina_out" ]]; then
        catalina_out="${catalina_out//\$\{CATALINA_BASE\}/$home}"
        catalina_out="${catalina_out//\$CATALINA_BASE/$home}"
        catalina_out="${catalina_out//\$\{CATALINA_HOME\}/$home}"
        catalina_out="${catalina_out//\$CATALINA_HOME/$home}"
        if [[ -f "$catalina_out" ]]; then
            echo "$catalina_out"
            return 0
        fi
    fi

    # 3) 표준 기본 위치
    if [[ -f "${home}/logs/catalina.out" ]]; then
        echo "${home}/logs/catalina.out"
        return 0
    fi

    # 4) 폭넓게 탐색 (logs 대신 log 등 다른 이름 대비)
    catalina_out=$(find "$home" -maxdepth 4 -type f -iname 'catalina.out' 2>/dev/null | head -n1)
    if [[ -n "$catalina_out" ]]; then
        echo "$catalina_out"
        return 0
    fi

    return 1
}

# 로그 조회. opt: 비어있으면 LOG_LINES 만큼 tail, 숫자면 해당 줄 수만큼 tail,
# f/-f/follow 면 tail -f (실시간). 단일 톰캣 대상으로 호출됨(전체는 main 에서 순회).
tomcat_log() {
    local name="$1" opt="$2" home logfile n

    home=$(tomcat_resolve_home "$name") || { log_err "톰캣 홈을 찾을 수 없습니다: $name"; return 1; }
    logfile=$(tomcat_find_catalina_out "$home") || {
        log_err "$(basename "$home") 의 catalina.out 을 찾지 못했습니다 (홈: ${home})"
        return 1
    }

    log_info "$(basename "$home") 로그 파일: $logfile"

    case "$opt" in
        f|-f|follow)
            tail -n 50 -f "$logfile"
            ;;
        *)
            n="$opt"
            [[ "$n" =~ ^[0-9]+$ ]] || n="$LOG_LINES"
            tail -n "$n" "$logfile"
            ;;
    esac
}

# ==================================================================
# 목록 / 전체 처리
# ==================================================================

tomcat_list() {
    local filter="$1"
    tomcat_build_index
    tomcat_print_indexed_list "$filter"
}

# TCH_HOMES 를 NUM/HOME/STATUS/PID/PORT 순서로 출력 (list, 대화식 선택에서 공용)
# 인자로 up/down 을 주면 해당 상태만 필터링해서 보여준다.
# NUM 은 필터와 무관하게 전체 목록 기준 번호를 그대로 유지한다 (start/stop 시 그대로 사용 가능).
tomcat_print_indexed_list() {
    local filter="${1,,}"   # 소문자로 정규화 (up/down/빈값)

    if [[ -n "$filter" && "$filter" != "up" && "$filter" != "down" ]]; then
        log_err "알 수 없는 필터입니다: $1 (up 또는 down 만 가능)"
        return 1
    fi

    if [[ ${#TCH_HOMES[@]} -eq 0 ]]; then
        log_warn "탐색된 톰캣이 없습니다: $BASE_DIR"
        return 1
    fi

    printf "%-4s %-45s %-8s %-8s %s\n" "NUM" "HOME" "STATUS" "PID" "PORT(http/ajp)"
    printf '%s\n' "-------------------------------------------------------------------------------------------"

    local i=1 h status pid ports matched=0
    for h in "${TCH_HOMES[@]}"; do
        if pid=$(tomcat_get_pid "$h"); then
            status="UP"
        else
            status="DOWN"; pid="-"
        fi

        if [[ -z "$filter" || "${status,,}" == "$filter" ]]; then
            ports=$(tomcat_ports_summary "$h")
            printf "%-4s %-45s %-8s %-8s %s\n" "$i" "$h" "$status" "$pid" "$ports"
            ((matched++))
        fi
        ((i++))
    done

    if [[ -n "$filter" && $matched -eq 0 ]]; then
        echo "(상태가 ${filter^^} 인 톰캣이 없습니다)"
    fi
}

tomcat_ports_all() {
    local home
    while IFS= read -r home; do
        [[ -z "$home" ]] && continue
        echo "== $home =="
        tomcat_get_ports "$home"
    done < <(tomcat_discover)
}

# action 이름과 실제 호출할 함수명을 받아 설치된 전체 톰캣에 대해 순차 실행
# (이름이 아닌 전체 경로로 넘겨서, 동일 basename 이 여러개여도 안전하게 동작)
tomcat_dispatch_all() {
    local func="$1" home
    while IFS= read -r home; do
        [[ -z "$home" ]] && continue
        "$func" "$home"
        echo
    done < <(tomcat_discover)
}

# 인자 없이 start/stop/restart/status 호출 시: 목록을 보여주고 번호를 입력받아
# 실제 CATALINA_HOME 절대경로(또는 "all")를 stdout 으로 반환한다.
tomcat_prompt_select() {
    tomcat_build_index
    tomcat_print_indexed_list >&2 || return 1

    local choice
    echo >&2
    read -r -p "번호를 선택하세요 (전체: all, 취소: q): " choice < /dev/tty

    case "$choice" in
        q|Q|"")
            return 1
            ;;
        all|ALL)
            echo "all"
            return 0
            ;;
    esac

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice - 1))
        if [[ $idx -ge 0 && $idx -lt ${#TCH_HOMES[@]} ]]; then
            echo "${TCH_HOMES[$idx]}"
            return 0
        fi
    fi

    log_err "잘못된 번호입니다: $choice"
    return 1
}

# start/stop/restart/status 의 대상(target)을 실제 홈 경로 또는 "all" 로 확정.
# - target 이 비어있으면: 목록을 보여주고 번호를 입력받는 대화식 모드
# - target 이 "all": 그대로 all
# - target 이 숫자: 마지막으로 빌드된 인덱스 기준 번호 조회 (list 와 동일 정렬 순서)
# - 그 외: 기존 방식(전체경로/디렉토리명/부분일치)으로 조회
tomcat_resolve_target() {
    local target="$1" home

    if [[ "$target" == "all" ]]; then
        echo "all"
        return 0
    fi

    if [[ -z "$target" ]]; then
        tomcat_prompt_select
        return $?
    fi

    if [[ "$target" =~ ^[0-9]+$ ]]; then
        tomcat_build_index
        local idx=$((target - 1))
        if [[ $idx -ge 0 && $idx -lt ${#TCH_HOMES[@]} ]]; then
            echo "${TCH_HOMES[$idx]}"
            return 0
        fi
        log_err "잘못된 번호입니다: $target (범위: 1~${#TCH_HOMES[@]}, 'list' 로 확인)"
        return 1
    fi

    if home=$(tomcat_resolve_home "$target"); then
        echo "$home"
        return 0
    fi

    log_err "톰캣을 찾을 수 없습니다: $target"
    return 1
}

# ==================================================================
# 사용법
# ==================================================================

tomcat_usage() {
    cat <<EOF
사용법: $(basename "$0") <명령> [번호|톰캣경로|all]

명령:
  list [up|down]                설치된 모든 톰캣 번호/상태/PID/포트 표시
                                 (up 또는 down 을 주면 해당 상태만 표시, NUM은 전체 기준 유지)
  start   [번호|경로|all]        기동 (인자 없으면 목록을 보여주고 번호 입력)
  stop    [번호|경로|all]        정지 (인자 없으면 목록을 보여주고 번호 입력)
  restart [번호|경로|all]        재기동 (인자 없으면 목록을 보여주고 번호 입력)
  status  [번호|경로|all]        상태 및 포트 표시 (인자 없으면 목록을 보여주고 번호 입력)
  ports   [번호|경로|all]        사용 포트만 표시 (생략 시 all)
  log     [번호|경로|all] [N|-f]  catalina.out 조회 (인자 없으면 목록을 보여주고 번호 입력)
                                 N: 마지막 N줄 (기본 ${LOG_LINES}줄), -f: 실시간 tail (all 불가)
  help                          도움말 표시

톰캣 탐색 방식:
  ${BASE_DIR} 하위(깊이 ${MAX_DEPTH} 이내)에서 bin/catalina.sh 가 존재하는
  디렉토리를 모두 실제 톰캣으로 인식합니다. 디렉토리 이름이나 위치는
  자유입니다 (예: /data/tomcat, /data/tmp/tomcat, /data/was/tomcat-9.0.85 등).
  이름이 같은 톰캣이 여러 개 있어도(예: tomcat, tomcat, tomcat) list 의
  NUM 번호 또는 전체 경로로 정확히 지정할 수 있습니다.

사용 예:
  $(basename "$0") list                 # 번호와 함께 전체 목록 확인
  $(basename "$0") list up              # 실행중인 톰캣만 확인
  $(basename "$0") list down            # 중지된 톰캣만 확인
  $(basename "$0") start                # 목록을 보고 번호 입력 후 기동
  $(basename "$0") start 2              # 목록의 2번 톰캣 기동
  $(basename "$0") stop all             # 전체 정지
  $(basename "$0") restart /data/tmp/tomcat-8.5.100   # 전체 경로 직접 지정
  $(basename "$0") status               # 목록을 보고 번호 입력 후 상태 확인
  $(basename "$0") log                  # 목록을 보고 번호 입력 후 catalina.out 마지막 ${LOG_LINES}줄 확인
  $(basename "$0") log 1                # 1번 톰캣의 catalina.out 마지막 ${LOG_LINES}줄
  $(basename "$0") log 1 500            # 1번 톰캣의 catalina.out 마지막 500줄
  $(basename "$0") log 1 -f             # 1번 톰캣의 catalina.out 실시간 조회 (Ctrl+C 종료)
EOF
}

# ==================================================================
# main
# ==================================================================

main() {
    local cmd="${1:-help}" target extra
    [[ $# -gt 0 ]] && shift
    target="${1:-}"
    extra="${2:-}"

    case "$cmd" in
        list)
            tomcat_list "$target"
            ;;
        start|stop|restart|status)
            local resolved
            resolved=$(tomcat_resolve_target "$target") || exit 1
            if [[ "$resolved" == "all" ]]; then
                tomcat_dispatch_all "tomcat_${cmd}"
            else
                "tomcat_${cmd}" "$resolved"
            fi
            ;;
        log)
            local resolved home
            resolved=$(tomcat_resolve_target "$target") || exit 1
            if [[ "$resolved" == "all" ]]; then
                if [[ "$extra" == "-f" || "$extra" == "f" || "$extra" == "follow" ]]; then
                    log_err "log all 에서는 -f(실시간) 를 사용할 수 없습니다. 번호로 개별 지정해주세요."
                    exit 1
                fi
                while IFS= read -r home; do
                    [[ -z "$home" ]] && continue
                    echo "== $home =="
                    tomcat_log "$home" "$extra"
                    echo
                done < <(tomcat_discover)
            else
                tomcat_log "$resolved" "$extra"
            fi
            ;;
        ports)
            if [[ -z "$target" || "$target" == "all" ]]; then
                tomcat_ports_all
            else
                local home
                home=$(tomcat_resolve_target "$target") || exit 1
                tomcat_get_ports "$home"
            fi
            ;;
        help|-h|--help)
            tomcat_usage
            ;;
        *)
            log_err "알 수 없는 명령: $cmd"
            tomcat_usage
            exit 1
            ;;
    esac
}

main "$@"