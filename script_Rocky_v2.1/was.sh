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

# 지정 PID 가 실제로 LISTEN 중인 로컬 포트 목록을 줄단위로 반환.
# server.xml 은 port="${property}" 같은 변수 치환이 자주 쓰여서 정적 파싱만으로는
# 실제 바인딩된 포트와 다를 수 있다 (예: 설정엔 80, 실제 기동 옵션으로 82를 주입).
# ss 로 실행중인 프로세스가 실제 잡고 있는 소켓을 직접 확인하는 것이 가장 정확하다.
tomcat_get_listen_ports_by_pid() {
    local pid="$1"
    [[ -z "$pid" ]] && return 1

    ss -antp 2>/dev/null \
        | grep -i listen \
        | grep -E "pid=${pid}(,|\))" \
        | awk '{print $4}' \
        | grep -oP '[0-9]+$' \
        | sort -un
}

# server.xml 에서 shutdown / HTTP / AJP 포트 파싱 (상세 표시용).
# 실행 중이면 ss 로 확인한 실제 LISTEN 포트도 함께 보여줘서 설정값과의 괴리를 바로 알 수 있게 한다.
tomcat_get_ports() {
    local home="$1" parsed shutdown_port http_ports ajp_ports pid real_ports out

    parsed=$(_tomcat_parse_ports "$home") || { echo "server.xml 없음"; return 1; }
    IFS='|' read -r shutdown_port http_ports ajp_ports <<< "$parsed"

    out="server.xml 설정값 : shutdown=${shutdown_port:-N/A}  http=${http_ports:-N/A}  ajp=${ajp_ports:-N/A}"

    if pid=$(tomcat_get_pid "$home" 2>/dev/null); then
        real_ports=$(tomcat_get_listen_ports_by_pid "$pid")
        [[ -n "$shutdown_port" ]] && real_ports=$(grep -vx "$shutdown_port" <<< "$real_ports")
        real_ports=$(paste -sd, - <<< "$real_ports")
        out+=$'\n'"실제 LISTEN(PID=${pid})  : ${real_ports:-없음}"
    fi

    echo "$out"
}

# list 테이블용 압축 포트 표시.
# 실행중(pid 있음) 이면 ss 로 확인한 실제 LISTEN 포트를 그대로 보여준다 (가장 정확).
# 중지 상태면 server.xml 설정값을 추정치로 보여주고 '(설정값)' 을 붙여 실제와 다를 수 있음을 표시한다.
tomcat_ports_summary() {
    local home="$1" pid="$2" parsed shutdown_port http_ports ajp_ports real_ports

    if [[ -n "$pid" ]]; then
        real_ports=$(tomcat_get_listen_ports_by_pid "$pid")
        parsed=$(_tomcat_parse_ports "$home")
        IFS='|' read -r shutdown_port http_ports ajp_ports <<< "$parsed"
        [[ -n "$shutdown_port" ]] && real_ports=$(grep -vx "$shutdown_port" <<< "$real_ports")
        real_ports=$(paste -sd, - <<< "$real_ports")
        echo "${real_ports:-리스닝없음}"
        return 0
    fi

    parsed=$(_tomcat_parse_ports "$home") || { echo "N/A"; return; }
    IFS='|' read -r shutdown_port http_ports ajp_ports <<< "$parsed"
    echo "${http_ports:--}/${ajp_ports:--}(설정값)"
}

# `<홈>/bin/catalina.sh version` 실행 결과에서 톰캣 버전만 추출.
# JVM 을 띄워야 하므로 다소 느릴 수 있어 timeout 을 둔다.
tomcat_get_version() {
    local home="$1" out ver

    if [[ ! -x "${home}/bin/catalina.sh" ]]; then
        echo "-"
        return 1
    fi

    out=$(CATALINA_HOME="$home" CATALINA_BASE="$home" timeout 8 "${home}/bin/catalina.sh" version 2>/dev/null)

    ver=$(grep -oP 'Server version:\s*Apache Tomcat/\K\S+' <<< "$out")
    [[ -z "$ver" ]] && ver=$(grep -oP 'Server number:\s*\K\S+' <<< "$out")

    echo "${ver:--}"
}

# ==================================================================
# 제어 함수 (기동 / 중지 / 재기동 / 상태)
# ==================================================================

tomcat_start() {
    local name="$1" home pid work_dir
    home=$(tomcat_resolve_home "$name") || { log_err "톰캣 홈을 찾을 수 없습니다: $name"; return 1; }

    if pid=$(tomcat_get_pid "$home"); then
        log_warn "${home} 은(는) 이미 실행중입니다 (PID=$pid)"
        return 0
    fi

    if [[ ! -x "${home}/bin/catalina.sh" ]]; then
        log_err "catalina.sh 실행 파일이 없습니다: ${home}/bin/catalina.sh"
        return 1
    fi

    # 기동 직전 JSP 컴파일 캐시(work/Catalina) 삭제 - restart 도 내부적으로 이 함수를 타므로 자동 포함됨
    work_dir="${home}/work/Catalina"
    if [[ -d "$work_dir" ]]; then
        log_info "${home} : JSP 캐시 삭제 (${work_dir})"
        rm -rf "$work_dir"
    fi

    (
        export CATALINA_HOME="$home"
        export CATALINA_BASE="$home"
        export CATALINA_PID
        CATALINA_PID=$(tomcat_pid_file "$home")
        cd "$home" || exit 1
        "${home}/bin/catalina.sh" start >/dev/null 2>&1
    )

    log_info "${home} 기동중..."
    sleep "$START_WAIT"

    if pid=$(tomcat_get_pid "$home"); then
        log_ok "${home} 기동 완료 (PID=$pid)"
    else
        log_err "${home} 기동 실패. 로그 확인: ${home}/logs/catalina.out"
        return 1
    fi
}

tomcat_stop() {
    local name="$1" home pid waited=0
    home=$(tomcat_resolve_home "$name") || { log_err "톰캣 홈을 찾을 수 없습니다: $name"; return 1; }

    if ! pid=$(tomcat_get_pid "$home"); then
        log_warn "${home} 은(는) 이미 중지 상태입니다"
        return 0
    fi

    log_info "${home} 정지중... (PID=$pid)"
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
    log_ok "${home} 정지 완료"
}

tomcat_restart() {
    local name="$1"
    tomcat_stop "$name"
    sleep 2
    tomcat_start "$name"
}

tomcat_status() {
    local name="$1" home pid ports
    home=$(tomcat_resolve_home "$name") || { log_err "톰캣 홈을 찾을 수 없습니다: $name"; return 1; }

    if pid=$(tomcat_get_pid "$home"); then
        log_ok "${home} : 실행중 (PID=$pid)"
    else
        log_warn "${home} : 중지됨"
    fi

    echo "        경로 : $home"
    ports=$(tomcat_get_ports "$home")
    echo "$ports" | sed 's/^/        /'
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

    printf "%-4s %-45s %-8s %-8s %-20s %s\n" "NUM" "HOME" "STATUS" "PID" "PORT" "VERSION"
    printf '%s\n' "-------------------------------------------------------------------------------------------------------"

    local i=1 h status pid ports version matched=0
    for h in "${TCH_HOMES[@]}"; do
        if pid=$(tomcat_get_pid "$h"); then
            status="UP"
        else
            status="DOWN"; pid="-"
        fi

        if [[ -z "$filter" || "${status,,}" == "$filter" ]]; then
            if [[ "$status" == "UP" ]]; then
                ports=$(tomcat_ports_summary "$h" "$pid")
            else
                ports=$(tomcat_ports_summary "$h" "")
            fi
            version=$(tomcat_get_version "$h")
            printf "%-4s %-45s %-8s %-8s %-20s %s\n" "$i" "$h" "$status" "$pid" "$ports" "$version"
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
  list [up|down]                설치된 모든 톰캣 번호/상태/PID/포트/버전 표시
                                 (up 또는 down 을 주면 해당 상태만 표시, NUM은 전체 기준 유지)
  start   [번호|경로|all]        기동 (인자 없으면 목록을 보여주고 번호 입력)
                                 기동 직전 <홈>/work/Catalina(JSP 캐시) 삭제
  stop    [번호|경로|all]        정지 (인자 없으면 목록을 보여주고 번호 입력)
  restart [번호|경로|all]        재기동 (내부적으로 stop 후 start 호출, JSP 캐시 삭제도 포함됨)
  status  [번호|경로|all]        상태 및 포트 표시 (인자 없으면 목록을 보여주고 번호 입력)
  ports   [번호|경로|all]        사용 포트만 표시 (생략 시 all)
  log     [번호|경로|all] [N|-f]  catalina.out 조회 (인자 없으면 목록을 보여주고 번호 입력)
                                 N: 마지막 N줄 (기본 ${LOG_LINES}줄), -f: 실시간 tail (all 불가)
  home    [번호|경로]            해당 톰캣의 홈 경로만 출력 (all 불가, 쉘 이동 시 사용)
  help                          도움말 표시

톰캣 탐색 방식:
  ${BASE_DIR} 하위(깊이 ${MAX_DEPTH} 이내)에서 bin/catalina.sh 가 존재하는
  디렉토리를 모두 실제 톰캣으로 인식합니다. 디렉토리 이름이나 위치는
  자유입니다 (예: /data/tomcat, /data/tmp/tomcat, /data/was/tomcat-9.0.85 등).
  이름이 같은 톰캣이 여러 개 있어도(예: tomcat, tomcat, tomcat) list 의
  NUM 번호 또는 전체 경로로 정확히 지정할 수 있습니다.

참고: 쉘 스크립트는 부모 쉘의 현재 디렉토리를 바꿀 수 없으므로,
  home 명령은 경로만 출력합니다. 아래처럼 명령어 치환으로 이동하세요:
    cd "\$($(basename "$0") home 1)"

사용 예:
  $(basename "$0") list                 # 번호/상태/포트/버전 전체 목록 확인
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
  cd "\$($(basename "$0") home 1)"      # 1번 톰캣 홈 디렉토리로 이동
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
        home)
            local resolved
            resolved=$(tomcat_resolve_target "$target") || exit 1
            if [[ "$resolved" == "all" ]]; then
                log_err "home 명령은 all 을 지원하지 않습니다. 번호나 경로를 지정하세요."
                exit 1
            fi
            # 쉘 스크립트는 부모 쉘의 디렉토리를 바꿀 수 없으므로 경로만 출력한다.
            # 사용법: cd "\$($(basename "$0") home 1)"
            echo "$resolved"
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