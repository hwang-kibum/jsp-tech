#!/bin/bash

# MariaDB 비밀번호 만료/인증 플러그인 관리 스크립트

# ==================== 설정 영역 ====================
MYSQL_USER="root"
MYSQL_PASSWORD="[PASSWORD]"

# 접속 방식
# - SOCKET: Unix socket으로 접속합니다. root@localhost 계정 사용 시 권장합니다.
# - TCP   : TCP/IP로 접속합니다. 이 경우 localhost 대신 127.0.0.1 사용을 권장합니다.
MYSQL_CONNECT_MODE="SOCKET"
MYSQL_SOCKET="/tmp/mysql.sock"
MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"

ACCOUNTS=(
    # "root@localhost"
    # "root@127.0.0.1"
    # "app@localhost"
    # "app@127.0.0.1"
    "all"
)

#mariadb.sys, mysql 계정 조회시 false, 미포함 조회시 true
EXCLUDE_SYSTEM_ACCOUNTS=false

# 비밀번호 재설정 시 기본 인증 플러그인
# 빈 값이면 MariaDB 기본 방식인 IDENTIFIED BY를 사용합니다.
# 예시: mysql_native_password, ed25519, unix_socket
DEFAULT_AUTH_PLUGIN=""
# ==================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# mysql 옵션은 배열로 관리합니다.
# 비밀번호나 Host 값에 특수문자가 있어도 쉘 단어 분리가 발생하지 않게 하기 위함입니다.
MYSQL_OPTS=("-u${MYSQL_USER}")

case "${MYSQL_CONNECT_MODE}" in
    "SOCKET")
        MYSQL_OPTS+=("--protocol=SOCKET" "--socket=${MYSQL_SOCKET}")
        ;;
    "TCP")
        MYSQL_OPTS+=("--protocol=TCP" "-h${MYSQL_HOST}" "-P${MYSQL_PORT}")
        ;;
    *)
        echo -e "${RED}ERROR: MYSQL_CONNECT_MODE 값이 올바르지 않습니다: ${MYSQL_CONNECT_MODE}${NC}"
        echo "허용 값: SOCKET, TCP"
        exit 1
        ;;
esac

if [ -n "$MYSQL_PASSWORD" ]; then
    MYSQL_OPTS+=("-p${MYSQL_PASSWORD}")
fi


print_tsv_table() {
    # 한글/영문 혼합 문자열을 printf %-Ns로 맞추면 표시 폭이 깨질 수 있습니다.
    # TSV로 만든 뒤 column이 터미널 표시 폭 기준으로 정렬하게 합니다.
    if command -v column >/dev/null 2>&1; then
        column -t -s $'\t'
    else
        cat
    fi
}

print_usage() {
    local exit_code="${1:-1}"

    local script_name
    script_name=$(basename "$0")

    cat <<'EOF' | sed "s|SCRIPT_NAME|${script_name}|g"
==========================================
MariaDB 비밀번호 만료/인증 플러그인 관리 스크립트
==========================================

사용법:
  ./SCRIPT_NAME                         # 조회 모드: 계정별 비밀번호 만료 상태 + 인증모듈 조회
  ./SCRIPT_NAME --help                  # 도움말 출력
  ./SCRIPT_NAME -h                      # 도움말 출력
  ./SCRIPT_NAME plugins                 # 서버에 로드된 인증 플러그인 조회
  ./SCRIPT_NAME pw-check                 # 비밀번호 검증 플러그인 상태 조회(simple/reuse)
  ./SCRIPT_NAME pw-check '<password>'    # 입력 비밀번호가 simple_password_check 정책을 만족하는지 테스트
  ./SCRIPT_NAME reuse-check              # password_reuse_check 활성/정책값 조회
  ./SCRIPT_NAME set <user@host> <policy> [args...]

접속 설정:
  - MYSQL_CONNECT_MODE="SOCKET"이면 MYSQL_SOCKET 경로로 접속합니다.
  - MYSQL_CONNECT_MODE="TCP"이면 MYSQL_HOST/MYSQL_PORT로 접속합니다.
  - TCP 사용 시 MYSQL_HOST="localhost"는 IPv6 ::1로 해석될 수 있으므로 127.0.0.1을 권장합니다.

조회 모드 출력 컬럼:
  - 계정
  - 개별설정
  - 적용기간(일)
  - 마지막변경일
  - 만료예정일
  - 인증/암호화모듈
  - 패스워드복잡도체크
  - 패스워드이력체크
  - 상태

비밀번호 만료 정책 설정:
  ./SCRIPT_NAME set <user@host> never
      → 해당 계정 비밀번호를 만료되지 않도록 설정

  ./SCRIPT_NAME set <user@host> default
      → 해당 계정 비밀번호 만료 정책을 전역 default_password_lifetime 값에 따르도록 설정

  ./SCRIPT_NAME set <user@host> <days>
      → 해당 계정 비밀번호를 <days>일 후 만료되도록 설정

비밀번호 변경:
  ./SCRIPT_NAME set <user@host> reset '<password>'
      → 비밀번호 변경 + PASSWORD EXPIRE NEVER 적용
      → 인증 플러그인은 MariaDB 기본 방식 유지

  ./SCRIPT_NAME set <user@host> reset '<password>' <auth_plugin>
      → 비밀번호 변경 + 인증 플러그인 변경 + PASSWORD EXPIRE NEVER 적용

  ./SCRIPT_NAME set <user@host> reset-with '<password>' <days>
      → 비밀번호 변경 + <days>일 후 만료되도록 설정
      → 인증 플러그인은 MariaDB 기본 방식 유지

  ./SCRIPT_NAME set <user@host> reset-with '<password>' <days> <auth_plugin>
      → 비밀번호 변경 + 인증 플러그인 변경 + <days>일 후 만료되도록 설정

인증 플러그인 변경:
  ./SCRIPT_NAME plugins
      → 현재 MariaDB 서버에서 사용 가능한 인증 플러그인 조회

  ./SCRIPT_NAME set <user@host> auth-plugin <auth_plugin>
      → 인증 플러그인만 변경
      → unix_socket처럼 비밀번호를 사용하지 않는 인증 방식에 적합

  ./SCRIPT_NAME set <user@host> auth-plugin <auth_plugin> '<password>'
      → 인증 플러그인 변경 + 비밀번호도 함께 재설정
      → ed25519, mysql_native_password 같은 비밀번호 기반 인증 방식에 권장

사용 예시:
  ./SCRIPT_NAME
  ./SCRIPT_NAME plugins
  ./SCRIPT_NAME pw-check
  ./SCRIPT_NAME pw-check 'Abcdefg1!'
  ./SCRIPT_NAME reuse-check

  ./SCRIPT_NAME set root@localhost never
  ./SCRIPT_NAME set root@localhost default
  ./SCRIPT_NAME set root@localhost 90

  ./SCRIPT_NAME set app@% reset '[PASSWORD]'
  ./SCRIPT_NAME set app@% reset '[PASSWORD]' ed25519
  ./SCRIPT_NAME set app@% reset-with '[PASSWORD]' 90
  ./SCRIPT_NAME set app@% reset-with '[PASSWORD]' 90 mysql_native_password

  ./SCRIPT_NAME set root@localhost auth-plugin unix_socket
  ./SCRIPT_NAME set app@% auth-plugin ed25519 '[PASSWORD]'
  ./SCRIPT_NAME set app@% auth-plugin mysql_native_password '[PASSWORD]'

지원/예상 인증 플러그인 예시:
  - mysql_native_password
  - ed25519
  - unix_socket

주의사항:
  1) 특수문자가 포함된 비밀번호는 반드시 작은따옴표('')로 감싸세요.
  2) 인증 플러그인은 information_schema.PLUGINS에서 ACTIVE 상태여야 합니다.
  3) ed25519가 ACTIVE가 아니면 먼저 플러그인을 로드해야 합니다.
     예: INSTALL SONAME 'auth_ed25519';
  4) unix_socket은 일반 비밀번호 인증 방식이 아니므로 비밀번호를 같이 지정하지 않는 방식을 권장합니다.
  5) root 계정의 인증 플러그인을 변경하기 전에는 반드시 별도 DBA 계정으로 접속 가능한지 확인하세요.
  6) EXCLUDE_SYSTEM_ACCOUNTS=true이면 mariadb.sys, mysql 계정은 조회에서 제외됩니다.
  7) simple_password_check 정책 변수(simple_password_check%)가 조회되면 비밀번호 변경 전에 사전 검증합니다.
     - simple_password_check_minimal_length
     - simple_password_check_digits
     - simple_password_check_letters_same_case
     - simple_password_check_other_characters
     정책을 만족하지 않으면 ALTER USER를 실행하지 않고 현재 옵션값과 부족 항목을 출력합니다.
  8) password_reuse_check가 활성화되면 기존 비밀번호 재사용 여부는 MariaDB 서버가 ALTER USER 실행 시점에 검사합니다.
     - password_reuse_check_interval=0 이면 이력 무제한 보관입니다.
     - password_reuse_check_interval=N 이면 최근 N일 이내 사용한 비밀번호 재사용을 차단합니다.
     - 스크립트가 이전 평문 비밀번호를 직접 알 수 없으므로 재사용 여부는 사전 계산하지 않고 서버 오류를 안내합니다.

  9) 비밀번호 검증 플러그인 적용 여부가 애매하면 먼저 아래 명령으로 확인하세요.
     ./SCRIPT_NAME pw-check
     ./SCRIPT_NAME pw-check 'Abcdefg1!'
     ./SCRIPT_NAME reuse-check

  10) 조회 모드의 패스워드복잡도체크/패스워드이력체크 컬럼 기준:
     - 대상: 해당 검증 플러그인 활성 + 비밀번호 기반 인증 플러그인 사용
     - 대상(복합): unix_socket 등과 비밀번호 기반 인증 플러그인이 함께 설정됨
     - 비대상: 해당 검증 플러그인 정책 없음, PUBLIC, unix_socket 전용 등
     - 확인필요: 인증 플러그인 정보가 없거나 스크립트가 알 수 없는 인증 방식
EOF

    exit "$exit_code"
}

# SQL 문자열 리터럴 이스케이프 함수
# - 작은따옴표를 두 개로 변경합니다.
# - 사용자명, Host, 비밀번호처럼 SQL 문자열에 들어가는 값에 사용합니다.
escape_sql_string() {
    local value="$1"
    echo "${value//\'/\'\'}"
}

# 비밀번호 이스케이프 함수
escape_password() {
    escape_sql_string "$1"
}

# MariaDB 접속 사전 점검
# - 접속 실패 상태에서 조회를 계속하면 "정상"처럼 보이는 오탐이 발생할 수 있으므로 즉시 중단합니다.
# - TCP localhost가 IPv6 ::1로 해석되어 root@::1 인증 오류가 나는 상황을 명확히 안내합니다.
check_mysql_connection() {
    local output

    output=$(mysql "${MYSQL_OPTS[@]}" --batch --skip-column-names -e "SELECT 1;" 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: MariaDB 접속에 실패했습니다.${NC}"
        echo "$output"
        echo ""
        echo "현재 스크립트 접속 설정:"
        echo "  - MYSQL_CONNECT_MODE=${MYSQL_CONNECT_MODE}"
        if [ "${MYSQL_CONNECT_MODE}" = "SOCKET" ]; then
            echo "  - MYSQL_SOCKET=${MYSQL_SOCKET}"
            echo ""
            echo "확인 명령:"
            echo "  mysql -u${MYSQL_USER} -p --protocol=SOCKET --socket=${MYSQL_SOCKET} -e \"SELECT @@socket, CURRENT_USER();\""
        else
            echo "  - MYSQL_HOST=${MYSQL_HOST}"
            echo "  - MYSQL_PORT=${MYSQL_PORT}"
            echo ""
            echo "확인 명령:"
            echo "  mysql -u${MYSQL_USER} -p --protocol=TCP -h${MYSQL_HOST} -P${MYSQL_PORT} -e \"SELECT @@port, CURRENT_USER();\""
            echo ""
            echo "주의: TCP에서 localhost는 환경에 따라 IPv6 ::1로 해석될 수 있습니다."
            echo "      root@::1 계정이 없으면 Access denied for user '''root'''@'''::1''' 오류가 납니다."
            echo "      이 경우 MYSQL_HOST=127.0.0.1로 지정하거나 SOCKET 접속을 사용하세요."
        fi
        exit 1
    fi
}

# 인증 플러그인 이름 검증
# - 플러그인명은 SQL 식별자로 직접 들어가므로 반드시 문자/숫자/언더스코어만 허용합니다.
# - 예: mysql_native_password, ed25519, unix_socket
validate_auth_plugin_name() {
    local plugin="$1"

    if [ -z "$plugin" ]; then
        return 0
    fi

    if [[ ! "$plugin" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo -e "${RED}ERROR: 인증 플러그인 이름이 안전하지 않습니다: $plugin${NC}"
        echo "허용 형식: 영문, 숫자, 언더스코어(_)만 사용"
        exit 1
    fi
}

# 인증 플러그인이 서버에 ACTIVE 상태인지 확인
check_auth_plugin_active() {
    local plugin="$1"

    if [ -z "$plugin" ]; then
        return 0
    fi

    validate_auth_plugin_name "$plugin"

    local count
    count=$(mysql "${MYSQL_OPTS[@]}" -sNe "
        SELECT COUNT(*)
        FROM information_schema.PLUGINS
        WHERE PLUGIN_TYPE = 'AUTHENTICATION'
          AND PLUGIN_STATUS = 'ACTIVE'
          AND PLUGIN_NAME = '$plugin';
    " 2>/dev/null)

    if [ "${count:-0}" -eq 0 ]; then
        echo -e "${RED}ERROR: 인증 플러그인이 ACTIVE 상태가 아닙니다: $plugin${NC}"
        echo "확인 명령: $0 plugins"
        echo "ed25519 예시 로드: INSTALL SONAME 'auth_ed25519';"
        exit 1
    fi
}

# 사용 가능한 인증 플러그인 조회
show_auth_plugins() {
    echo "==================================================================="
    echo "MariaDB 인증 플러그인 조회"
    echo "==================================================================="
    echo ""

    printf "%-30s | %-10s | %-30s | %-15s\n" \
        "플러그인" "상태" "라이브러리" "로드옵션"
    echo "-------------------------------------------------------------------------------------------"

    mysql "${MYSQL_OPTS[@]}" --batch --skip-column-names -e "
        SELECT
            PLUGIN_NAME,
            PLUGIN_STATUS,
            IFNULL(PLUGIN_LIBRARY, 'builtin'),
            IFNULL(LOAD_OPTION, '')
        FROM information_schema.PLUGINS
        WHERE PLUGIN_TYPE = 'AUTHENTICATION'
        ORDER BY PLUGIN_NAME;
    " | while IFS=$'\t' read -r plugin status library load_option; do
        printf "%-30s | %-10s | %-30s | %-15s\n" \
            "$plugin" "$status" "$library" "$load_option"
    done

    echo ""
}


# simple_password_check 정책 변수 조회
# - MariaDB 버전/빌드에 따라 PLUGINS 조회와 실제 정책 변수 노출 상태가 다를 수 있어
#   플러그인 ACTIVE 여부만 보지 않고 simple_password_check% 변수 존재 여부를 기준으로 검증합니다.
get_simple_password_policy_rows() {
    # MariaDB 11.4.x 환경에서 SHOW GLOBAL VARIABLES ... WHERE 절이
    # 클라이언트/서버 조합에 따라 실패하거나 빈 결과로 처리되는 경우를 피하기 위해
    # LIKE 조회 후 쉘에서 필요한 정책 변수만 필터링합니다.
    # 출력 형식은 기존과 동일하게 유지합니다: <Variable_name><TAB><Value>
    mysql "${MYSQL_OPTS[@]}" --batch --skip-column-names -e \
        "SHOW GLOBAL VARIABLES LIKE 'simple_password_check%';" 2>/dev/null \
    | awk '$1 == "simple_password_check_minimal_length" || \
           $1 == "simple_password_check_digits" || \
           $1 == "simple_password_check_letters_same_case" || \
           $1 == "simple_password_check_other_characters" { print $1 "\t" $2 }' \
    | sort
}
# simple_password_check 플러그인 상태 조회
get_simple_password_plugin_status() {
    local status

    status=$(mysql "${MYSQL_OPTS[@]}" --batch --skip-column-names -e "
        SELECT IFNULL(MAX(PLUGIN_STATUS), 'NOT INSTALLED')
        FROM information_schema.PLUGINS
        WHERE PLUGIN_NAME = 'simple_password_check';
    " 2>/dev/null)

    if [ -z "$status" ]; then
        echo "UNKNOWN"
    else
        echo "$status"
    fi
}

# password_reuse_check 정책 변수 조회
# - password_reuse_check_interval 값이 조회되면 password_reuse_check 정책을 확인할 수 있는 상태입니다.
get_password_reuse_policy_rows() {
    mysql "${MYSQL_OPTS[@]}" --batch --skip-column-names -e \
        "SHOW GLOBAL VARIABLES LIKE 'password_reuse_check%';" 2>/dev/null \
    | awk '$1 == "password_reuse_check_interval" { print $1 "\t" $2 }' \
    | sort
}

# password_reuse_check 플러그인 상태 조회
get_password_reuse_plugin_status() {
    local status

    status=$(mysql "${MYSQL_OPTS[@]}" --batch --skip-column-names -e "
        SELECT IFNULL(MAX(PLUGIN_STATUS), 'NOT INSTALLED')
        FROM information_schema.PLUGINS
        WHERE PLUGIN_NAME = 'password_reuse_check';
    " 2>/dev/null)

    if [ -z "$status" ]; then
        echo "UNKNOWN"
    else
        echo "$status"
    fi
}

# password_reuse_check interval 값만 조회
get_password_reuse_interval() {
    local interval

    interval=$(get_password_reuse_policy_rows | awk '$1 == "password_reuse_check_interval" { print $2; exit }')
    if [ -z "$interval" ]; then
        echo "N/A"
    else
        echo "$interval"
    fi
}

# password_reuse_check 상태/정책값 출력
show_password_reuse_check_status() {
    local plugin_status
    local policy_rows
    local interval

    plugin_status=$(get_password_reuse_plugin_status)
    policy_rows=$(get_password_reuse_policy_rows)
    interval=$(get_password_reuse_interval)

    echo "==================================================================="
    echo "MariaDB password_reuse_check 상태 조회"
    echo "==================================================================="
    echo "플러그인 상태: ${plugin_status}"
    echo ""

    if [ -z "$policy_rows" ]; then
        echo -e "${YELLOW}password_reuse_check 정책 변수가 조회되지 않습니다.${NC}"
        echo ""
        echo "가능한 원인:"
        echo "  1) password_reuse_check 플러그인이 설치/로드되지 않음"
        echo "  2) 현재 접속 계정에 변수 조회 권한이 부족함"
        echo "  3) MariaDB 10.7 미만 또는 해당 플러그인을 제공하지 않는 빌드 사용"
        echo ""
        echo "서버에서 직접 확인:"
        echo "  SELECT PLUGIN_NAME, PLUGIN_STATUS, PLUGIN_TYPE, PLUGIN_LIBRARY, LOAD_OPTION"
        echo "  FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'password_reuse_check';"
        echo "  SHOW GLOBAL VARIABLES LIKE 'password_reuse_check%';"
        echo "  INSTALL SONAME 'password_reuse_check';"
        echo ""
        return 1
    fi

    printf "%-50s | %-10s\n" "옵션" "값"
    echo "-------------------------------------------------------------------"
    while IFS=$'\t' read -r variable_name variable_value; do
        printf "%-50s | %-10s\n" "$variable_name" "$variable_value"
    done <<< "$policy_rows"
    echo ""

    if [ "$interval" = "0" ]; then
        echo "해석: password_reuse_check_interval=0 → 이전 비밀번호 이력을 무제한 보관합니다."
    elif [[ "$interval" =~ ^[0-9]+$ ]]; then
        echo "해석: password_reuse_check_interval=${interval} → 최근 ${interval}일 이내 사용한 비밀번호 재사용을 차단합니다."
    else
        echo "해석: interval 값을 확인하지 못했습니다."
    fi
    echo ""

    return 0
}

# 비밀번호 검증 플러그인 전체 상태 출력
show_password_validation_status() {
    show_simple_password_check_status
    echo ""
    show_password_reuse_check_status
}

# password_reuse_check는 과거 평문 비밀번호를 스크립트가 알 수 없으므로 사전 비교하지 않습니다.
# 대신 활성 상태와 interval 정책을 출력하고, 실제 재사용 차단은 MariaDB의 ALTER USER 실행 결과로 판단합니다.
show_password_reuse_change_notice() {
    local policy_rows
    local interval

    policy_rows=$(get_password_reuse_policy_rows)
    if [ -z "$policy_rows" ]; then
        return 0
    fi

    interval=$(get_password_reuse_interval)
    if [ "$interval" = "0" ]; then
        echo -e "${BLUE}정보: password_reuse_check 활성 - 이전 비밀번호 이력 무제한 기준으로 재사용 여부를 서버가 검사합니다.${NC}"
    elif [[ "$interval" =~ ^[0-9]+$ ]]; then
        echo -e "${BLUE}정보: password_reuse_check 활성 - 최근 ${interval}일 이내 사용한 비밀번호 재사용 여부를 서버가 검사합니다.${NC}"
    else
        echo -e "${BLUE}정보: password_reuse_check 활성 - 비밀번호 재사용 여부를 서버가 검사합니다.${NC}"
    fi
}

# 비밀번호 변경 실패 시 password validation 플러그인 상태를 같이 안내합니다.
show_password_validation_failure_hint() {
    echo ""
    echo "비밀번호 검증 플러그인 확인:"
    echo "  - simple_password_check: $(get_simple_password_plugin_status)"
    echo "  - password_reuse_check : $(get_password_reuse_plugin_status)"

    local simple_rows
    local reuse_rows
    local reuse_interval
    simple_rows=$(get_simple_password_policy_rows)
    reuse_rows=$(get_password_reuse_policy_rows)
    reuse_interval=$(get_password_reuse_interval)

    if [ -n "$simple_rows" ]; then
        echo ""
        echo "simple_password_check 정책값:"
        while IFS=$'\t' read -r variable_name variable_value; do
            echo "  - ${variable_name} = ${variable_value}"
        done <<< "$simple_rows"
    fi

    if [ -n "$reuse_rows" ]; then
        echo ""
        echo "password_reuse_check 정책값:"
        echo "  - password_reuse_check_interval = ${reuse_interval}"
        if [ "$reuse_interval" = "0" ]; then
            echo "  - 해석: 이전 비밀번호 이력 무제한 보관"
        elif [[ "$reuse_interval" =~ ^[0-9]+$ ]]; then
            echo "  - 해석: 최근 ${reuse_interval}일 이내 사용한 비밀번호 재사용 차단"
        fi
    fi

    echo ""
    echo "주의: MariaDB는 simple_password_check와 password_reuse_check 모두 정책 위반 시 ERROR 1819를 반환할 수 있습니다."
    echo "      simple_password_check는 스크립트에서 사전 검증하지만, password_reuse_check는 서버가 저장한 이력과 비교하므로 ALTER USER 실행 결과로 판단합니다."
}

# simple_password_check 상태/정책값 출력
show_simple_password_check_status() {
    local plugin_status
    local policy_rows

    plugin_status=$(get_simple_password_plugin_status)
    policy_rows=$(get_simple_password_policy_rows)

    echo "==================================================================="
    echo "MariaDB simple_password_check 상태 조회"
    echo "==================================================================="
    echo "플러그인 상태: ${plugin_status}"
    echo ""

    if [ -z "$policy_rows" ]; then
        echo -e "${YELLOW}simple_password_check 정책 변수가 조회되지 않습니다.${NC}"
        echo ""
        echo "가능한 원인:"
        echo "  1) simple_password_check 플러그인이 설치/로드되지 않음"
        echo "  2) 현재 접속 계정에 변수 조회 권한이 부족함"
        echo "  3) MariaDB 버전/빌드에서 해당 플러그인을 제공하지 않음"
        echo ""
        echo "서버에서 직접 확인:"
        echo "  SHOW PLUGINS LIKE 'simple_password_check';"
        echo "  SHOW GLOBAL VARIABLES LIKE 'simple_password_check%';"
        echo "  INSTALL SONAME 'simple_password_check';"
        echo ""
        return 1
    fi

    printf "%-50s | %-10s\n" "옵션" "값"
    echo "-------------------------------------------------------------------"
    while IFS=$'\t' read -r variable_name variable_value; do
        printf "%-50s | %-10s\n" "$variable_name" "$variable_value"
    done <<< "$policy_rows"
    echo ""

    return 0
}

# simple_password_check 정책값을 조회하고 비밀번호가 조건을 만족하는지 사전 검증
# - 조건 미충족 시 ALTER USER를 실행하지 않습니다.
# - MariaDB 서버가 ERROR 1819만 반환하는 상황을 피하고, 현재 옵션값과 부족 항목을 보여주기 위함입니다.
check_simple_password_policy() {
    local password="$1"

    local policy_rows
    policy_rows=$(get_simple_password_policy_rows)

    # 정책 변수가 없으면 simple_password_check가 적용된 상태로 볼 수 없으므로 사전 검증은 건너뜁니다.
    # 실제 적용 여부 확인은 ./SCRIPT_NAME pw-check 로 확인하세요.
    if [ -z "$policy_rows" ]; then
        return 0
    fi

    # MariaDB 문서상 기본값입니다. 실제 조회값이 있으면 아래 while에서 덮어씁니다.
    local min_length=8
    local required_digits=1
    local required_same_case=1
    local required_other=1
    local variable_name
    local variable_value

    while IFS=$'\t' read -r variable_name variable_value; do
        case "$variable_name" in
            simple_password_check_minimal_length)
                min_length="$variable_value"
                ;;
            simple_password_check_digits)
                required_digits="$variable_value"
                ;;
            simple_password_check_letters_same_case)
                required_same_case="$variable_value"
                ;;
            simple_password_check_other_characters)
                required_other="$variable_value"
                ;;
        esac
    done <<< "$policy_rows"

    local length=${#password}
    local digits=0
    local upper=0
    local lower=0
    local other=0
    local i
    local ch

    for ((i = 0; i < length; i++)); do
        ch="${password:i:1}"
        if [[ "$ch" =~ [[:digit:]] ]]; then
            ((digits++))
        elif [[ "$ch" =~ [[:upper:]] ]]; then
            ((upper++))
        elif [[ "$ch" =~ [[:lower:]] ]]; then
            ((lower++))
        else
            ((other++))
        fi
    done

    local errors=()

    if (( length < min_length )); then
        errors+=("길이 부족: 현재 ${length}, 필요 ${min_length} 이상")
    fi

    if (( digits < required_digits )); then
        errors+=("숫자 부족: 현재 ${digits}, 필요 ${required_digits} 이상")
    fi

    if (( upper < required_same_case )); then
        errors+=("대문자 부족: 현재 ${upper}, 필요 ${required_same_case} 이상")
    fi

    if (( lower < required_same_case )); then
        errors+=("소문자 부족: 현재 ${lower}, 필요 ${required_same_case} 이상")
    fi

    if (( other < required_other )); then
        errors+=("특수/기타문자 부족: 현재 ${other}, 필요 ${required_other} 이상")
    fi

    if (( ${#errors[@]} > 0 )); then
        echo -e "${RED}ERROR: 입력한 비밀번호가 simple_password_check 정책을 만족하지 않습니다.${NC}"
        echo ""
        echo "현재 simple_password_check 옵션값:"
        echo "  - simple_password_check_minimal_length      = ${min_length}"
        echo "  - simple_password_check_digits              = ${required_digits}"
        echo "  - simple_password_check_letters_same_case   = ${required_same_case}"
        echo "    · 대문자 ${required_same_case}개 이상 + 소문자 ${required_same_case}개 이상 필요"
        echo "  - simple_password_check_other_characters    = ${required_other}"
        echo "    · 숫자/영문자가 아닌 문자 ${required_other}개 이상 필요"
        echo ""
        echo "입력한 비밀번호의 구성:"
        echo "  - 길이: ${length}"
        echo "  - 숫자: ${digits}"
        echo "  - 대문자: ${upper}"
        echo "  - 소문자: ${lower}"
        echo "  - 특수/기타문자: ${other}"
        echo ""
        echo "부족 항목:"
        local error
        for error in "${errors[@]}"; do
            echo "  - ${error}"
        done
        echo ""
        echo "비밀번호를 정책에 맞게 수정한 뒤 다시 실행하세요."
        echo "정책 확인 명령: SHOW GLOBAL VARIABLES LIKE 'simple_password_check%';"
        exit 1
    fi

    return 0
}

# 입력 비밀번호가 simple_password_check 정책을 만족하는지 단독 테스트
# - password_reuse_check 상태도 함께 보여주지만, 재사용 여부는 서버 이력 기반이라 사전 검증하지 않습니다.
run_simple_password_check_test() {
    local password="$1"

    show_password_validation_status

    if [ -z "$password" ]; then
        return 0
    fi

    check_simple_password_policy "$password"
    echo -e "${GREEN}✓ 입력한 비밀번호가 simple_password_check 정책을 만족합니다.${NC}"
    show_password_reuse_change_notice
}

# 조회 모드에서 패스워드 체크 대상 여부를 계산하는 SQL CASE 조각 생성
# - simple_password_check는 서버 전역 password validation plugin입니다.
# - 계정 단위로 켜고 끄는 옵션이 아니라, 비밀번호를 설정/변경하는 계정에 적용됩니다.
# - 다만 unix_socket 전용, PUBLIC, 익명 계정처럼 비밀번호 변경 대상이 아니거나 판단이 애매한 계정은 구분해서 표시합니다.
build_password_check_target_case_sql() {
    local enabled="$1"

    cat <<EOF
CASE
    WHEN ${enabled} = 0 THEN '비대상(정책없음)'
    WHEN User = 'PUBLIC' THEN '비대상(PUBLIC)'
    WHEN User = '' THEN '확인필요(익명계정)'
    WHEN NULLIF(CONCAT_WS(',',
            NULLIF(JSON_VALUE(Priv, '$.plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[0].plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[1].plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[2].plugin'), '')
        ), '') IS NULL THEN '확인필요(인증정보없음)'
    WHEN CONCAT_WS(',',
            NULLIF(JSON_VALUE(Priv, '$.plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[0].plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[1].plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[2].plugin'), '')
        ) REGEXP '(^|,)(mysql_native_password|ed25519|mysql_old_password|mysql_clear_password|caching_sha2_password)(,|$)'
         AND CONCAT_WS(',',
            NULLIF(JSON_VALUE(Priv, '$.plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[0].plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[1].plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[2].plugin'), '')
        ) REGEXP '(^|,)unix_socket(,|$)' THEN '대상(복합)'
    WHEN CONCAT_WS(',',
            NULLIF(JSON_VALUE(Priv, '$.plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[0].plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[1].plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[2].plugin'), '')
        ) REGEXP '(^|,)(mysql_native_password|ed25519|mysql_old_password|mysql_clear_password|caching_sha2_password)(,|$)' THEN '대상'
    WHEN CONCAT_WS(',',
            NULLIF(JSON_VALUE(Priv, '$.plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[0].plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[1].plugin'), ''),
            NULLIF(JSON_VALUE(Priv, '$.auth_or[2].plugin'), '')
        ) REGEXP '(^|,)unix_socket(,|$)' THEN '비대상(unix_socket)'
    ELSE '확인필요(인증방식)'
END
EOF
}

# ALTER USER의 인증 절 생성
# - auth_plugin이 비어 있으면 기존 방식인 IDENTIFIED BY를 사용합니다.
# - auth_plugin이 있으면 IDENTIFIED VIA <plugin> USING PASSWORD('<password>')를 사용합니다.
build_identified_clause() {
    local password="$1"
    local auth_plugin="$2"
    local escaped_password
    escaped_password=$(escape_password "$password")

    if [ -n "$auth_plugin" ]; then
        check_auth_plugin_active "$auth_plugin"
        echo "IDENTIFIED VIA $auth_plugin USING PASSWORD('$escaped_password')"
    else
        echo "IDENTIFIED BY '$escaped_password'"
    fi
}

generate_where_clause() {
    local conditions=()
    local account
    local user
    local host
    local safe_user
    local safe_host

    for account in "${ACCOUNTS[@]}"; do
        if [ "$account" == "all" ]; then
            echo "1=1"
            return
        fi
    done

    for account in "${ACCOUNTS[@]}"; do
        if [[ $account =~ ^([^@]+)@(.+)$ ]]; then
            user="${BASH_REMATCH[1]}"
            host="${BASH_REMATCH[2]}"
            safe_user=$(escape_sql_string "$user")
            safe_host=$(escape_sql_string "$host")
            conditions+=("(User = '$safe_user' AND Host = '$safe_host')")
        fi
    done

    if [ ${#conditions[@]} -eq 0 ]; then
        echo "1=0"
        return
    fi

    local IFS='|'
    echo "${conditions[*]}" | sed 's/|/ OR /g'
}

set_password_policy() {
    local account=$1
    local policy=$2
    local new_password="${3:-}"
    local days="${4:-}"
    local auth_plugin="${5:-${DEFAULT_AUTH_PLUGIN:-}}"

    if [[ $account =~ ^([^@]+)@(.+)$ ]]; then
        local user="${BASH_REMATCH[1]}"
        local host="${BASH_REMATCH[2]}"
    else
        echo -e "${RED}ERROR: 잘못된 계정 형식${NC}"
        echo "형식: user@host"
        exit 1
    fi

    local safe_user
    local safe_host
    safe_user=$(escape_sql_string "$user")
    safe_host=$(escape_sql_string "$host")

    echo "=========================================="
    echo -e "${BLUE}비밀번호 만료/인증 플러그인 설정${NC}"
    echo "=========================================="
    echo "계정: $user@$host"
    echo "정책: $policy"
    echo ""

    local sql=""
    local identified_clause=""

    case $policy in
        "never")
            sql="ALTER USER '$safe_user'@'$safe_host' PASSWORD EXPIRE NEVER;"
            echo -e "${GREEN}→ 비밀번호가 만료되지 않도록 설정합니다.${NC}"
            ;;
        "default")
            sql="ALTER USER '$safe_user'@'$safe_host' PASSWORD EXPIRE DEFAULT;"
            echo -e "${YELLOW}→ 전역 설정을 따르도록 설정합니다.${NC}"
            ;;
        "reset")
            if [ -z "$new_password" ]; then
                echo -e "${RED}ERROR: 비밀번호를 입력해주세요.${NC}"
                echo "예시: $0 set $account reset '[PASSWORD]'"
                echo "예시: $0 set $account reset '[PASSWORD]' ed25519"
                exit 1
            fi

            # reset 정책에서는 4번째 인자를 인증 플러그인으로 사용합니다.
            # main 전달 기준: set user reset password plugin
            if [ -n "$days" ] && [ -z "${5:-}" ]; then
                auth_plugin="$days"
                days=""
            fi

            check_simple_password_policy "$new_password"
            show_password_reuse_change_notice

            identified_clause=$(build_identified_clause "$new_password" "$auth_plugin")
            sql="ALTER USER '$safe_user'@'$safe_host' $identified_clause PASSWORD EXPIRE NEVER;"

            if [ -n "$auth_plugin" ]; then
                echo -e "${GREEN}→ 비밀번호를 재설정하고 인증 플러그인을 $auth_plugin 으로 변경하며 만료되지 않도록 설정합니다.${NC}"
            else
                echo -e "${GREEN}→ 비밀번호를 재설정하고 만료되지 않도록 설정합니다.${NC}"
            fi
            ;;
        "reset-with")
            if [ -z "$new_password" ] || [ -z "$days" ]; then
                echo -e "${RED}ERROR: 비밀번호와 만료 일수를 입력해주세요.${NC}"
                echo "예시: $0 set $account reset-with '[PASSWORD]' 90"
                echo "예시: $0 set $account reset-with '[PASSWORD]' 90 ed25519"
                exit 1
            fi

            if [[ ! "$days" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}ERROR: 만료 일수는 숫자만 입력해야 합니다: $days${NC}"
                exit 1
            fi

            check_simple_password_policy "$new_password"
            show_password_reuse_change_notice

            identified_clause=$(build_identified_clause "$new_password" "$auth_plugin")
            sql="ALTER USER '$safe_user'@'$safe_host' $identified_clause PASSWORD EXPIRE INTERVAL $days DAY;"

            if [ -n "$auth_plugin" ]; then
                echo -e "${GREEN}→ 비밀번호를 재설정하고 인증 플러그인을 $auth_plugin 으로 변경하며 ${days}일 후 만료되도록 설정합니다.${NC}"
            else
                echo -e "${GREEN}→ 비밀번호를 재설정하고 ${days}일 후 만료되도록 설정합니다.${NC}"
            fi
            ;;
        "auth-plugin"|"plugin")
            auth_plugin="$new_password"
            local plugin_password="$days"

            if [ -z "$auth_plugin" ]; then
                echo -e "${RED}ERROR: 인증 플러그인을 입력해주세요.${NC}"
                echo "예시: $0 set $account auth-plugin ed25519 '[PASSWORD]'"
                echo "예시: $0 set $account auth-plugin unix_socket"
                exit 1
            fi

            check_auth_plugin_active "$auth_plugin"

            if [ -n "$plugin_password" ]; then
                check_simple_password_policy "$plugin_password"
                show_password_reuse_change_notice

                local escaped_password
                escaped_password=$(escape_password "$plugin_password")
                sql="ALTER USER '$safe_user'@'$safe_host' IDENTIFIED VIA $auth_plugin USING PASSWORD('$escaped_password');"
                echo -e "${GREEN}→ 인증 플러그인을 $auth_plugin 으로 변경하고 비밀번호도 재설정합니다.${NC}"
            else
                sql="ALTER USER '$safe_user'@'$safe_host' IDENTIFIED VIA $auth_plugin;"
                echo -e "${YELLOW}→ 인증 플러그인만 $auth_plugin 으로 변경합니다.${NC}"
                echo -e "${YELLOW}주의: 비밀번호 기반 플러그인은 비밀번호를 함께 지정하는 방식을 권장합니다.${NC}"
            fi
            ;;
        [0-9]*)
            if [[ ! "$policy" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}ERROR: 만료 일수는 숫자만 입력해야 합니다: $policy${NC}"
                exit 1
            fi
            sql="ALTER USER '$safe_user'@'$safe_host' PASSWORD EXPIRE INTERVAL $policy DAY;"
            echo -e "${YELLOW}→ ${policy}일 후 만료되도록 설정합니다.${NC}"
            ;;
        *)
            echo -e "${RED}ERROR: 잘못된 정책${NC}"
            print_usage
            ;;
    esac

    # SQL 실행
    local mysql_output
    mysql_output=$(mysql "${MYSQL_OPTS[@]}" -e "$sql" 2>&1)
    if [ $? -eq 0 ]; then
        [ -n "$mysql_output" ] && echo "$mysql_output"
        echo -e "${GREEN}✓ 설정이 완료되었습니다.${NC}"
        echo ""
        echo "변경 후 상태:"
        mysql "${MYSQL_OPTS[@]}" --batch --skip-column-names -e "
        SELECT
            CONCAT('계정: ', User, '@', Host),
            CONCAT('개별설정: ',
                CASE
                    WHEN JSON_VALUE(Priv, '$.password_lifetime') IS NULL THEN '설정없음 (전역값 따름)'
                    WHEN JSON_VALUE(Priv, '$.password_lifetime') = 0 THEN '무기한 (Never)'
                    WHEN JSON_VALUE(Priv, '$.password_lifetime') = -1 THEN 'DEFAULT (전역값 따름)'
                    ELSE CONCAT(JSON_VALUE(Priv, '$.password_lifetime'), '일')
                END
            ),
            CONCAT('적용기간: ',
                CASE
                    WHEN JSON_VALUE(Priv, '$.password_lifetime') IS NULL OR JSON_VALUE(Priv, '$.password_lifetime') = -1
                        THEN @@global.default_password_lifetime
                    ELSE JSON_VALUE(Priv, '$.password_lifetime')
                END, '일'
            ),
            CONCAT('인증플러그인: ',
                IFNULL(
                    NULLIF(
                        CONCAT_WS(', ',
                            NULLIF(JSON_VALUE(Priv, '$.plugin'), ''),
                            NULLIF(JSON_VALUE(Priv, '$.auth_or[0].plugin'), ''),
                            NULLIF(JSON_VALUE(Priv, '$.auth_or[1].plugin'), ''),
                            NULLIF(JSON_VALUE(Priv, '$.auth_or[2].plugin'), '')
                        ),
                        ''
                    ),
                    'N/A'
                )
            )
        FROM mysql.global_priv
        WHERE User = '$safe_user' AND Host = '$safe_host';
        " 2>/dev/null
    else
        [ -n "$mysql_output" ] && echo "$mysql_output"
        echo -e "${RED}✗ 설정 실패${NC}"
        show_password_validation_failure_hint
        exit 1
    fi
}

show_password_status() {
    local WHERE_CLAUSE
    WHERE_CLAUSE=$(generate_where_clause)

    local SIMPLE_PASSWORD_CHECK_ENABLED=0
    local SIMPLE_PASSWORD_CHECK_STATUS="비활성/정책없음"
    local PASSWORD_REUSE_CHECK_ENABLED=0
    local PASSWORD_REUSE_CHECK_STATUS="비활성/정책없음"
    local PASSWORD_REUSE_CHECK_INTERVAL="N/A"
    local PASSWORD_COMPLEXITY_TARGET_CASE
    local PASSWORD_REUSE_TARGET_CASE

    if [ -n "$(get_simple_password_policy_rows)" ]; then
        SIMPLE_PASSWORD_CHECK_ENABLED=1
        SIMPLE_PASSWORD_CHECK_STATUS="활성(정책변수 확인)"
    fi

    if [ -n "$(get_password_reuse_policy_rows)" ]; then
        PASSWORD_REUSE_CHECK_ENABLED=1
        PASSWORD_REUSE_CHECK_INTERVAL=$(get_password_reuse_interval)
        if [ "$PASSWORD_REUSE_CHECK_INTERVAL" = "0" ]; then
            PASSWORD_REUSE_CHECK_STATUS="활성(interval=0, 이력 무제한)"
        elif [[ "$PASSWORD_REUSE_CHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
            PASSWORD_REUSE_CHECK_STATUS="활성(interval=${PASSWORD_REUSE_CHECK_INTERVAL}일)"
        else
            PASSWORD_REUSE_CHECK_STATUS="활성(정책변수 확인)"
        fi
    fi

    PASSWORD_COMPLEXITY_TARGET_CASE=$(build_password_check_target_case_sql "$SIMPLE_PASSWORD_CHECK_ENABLED")
    PASSWORD_REUSE_TARGET_CASE=$(build_password_check_target_case_sql "$PASSWORD_REUSE_CHECK_ENABLED")

    if [ "$EXCLUDE_SYSTEM_ACCOUNTS" == "true" ]; then
        WHERE_CLAUSE="($WHERE_CLAUSE) AND User NOT IN ('mariadb.sys', 'mysql')"
    fi

    echo "==================================================================="
    echo "MariaDB 계정 비밀번호 만료/인증 플러그인 상태 조회"
    echo "==================================================================="
    echo ""

    {
        printf "계정\t개별설정\t기간\t마지막변경일\t만료예정일\t인증모듈\t복잡도\t이력\t상태\n"

        mysql "${MYSQL_OPTS[@]}" --batch --skip-column-names -e "
        SELECT
            CONCAT(User, '@', Host) AS account,
            CASE
                WHEN JSON_VALUE(Priv, '$.password_lifetime') IS NULL THEN '전역값'
                WHEN JSON_VALUE(Priv, '$.password_lifetime') = 0 THEN '무기한'
                WHEN JSON_VALUE(Priv, '$.password_lifetime') = -1 THEN 'DEFAULT'
                ELSE CONCAT(JSON_VALUE(Priv, '$.password_lifetime'), '일')
            END AS individual_policy,
            CASE
                WHEN JSON_VALUE(Priv, '$.password_lifetime') IS NULL
                    OR JSON_VALUE(Priv, '$.password_lifetime') = -1
                    THEN @@global.default_password_lifetime
                ELSE JSON_VALUE(Priv, '$.password_lifetime')
            END AS effective_lifetime,
            IFNULL(DATE_FORMAT(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')), '%Y-%m-%d %H:%i:%s'), 'N/A') AS last_changed,
            CASE
                WHEN JSON_VALUE(Priv, '$.password_lifetime') = 0 THEN '만료안됨'
                WHEN JSON_VALUE(Priv, '$.password_lifetime') > 0 THEN
                    DATE_FORMAT(DATE_ADD(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')), INTERVAL JSON_VALUE(Priv, '$.password_lifetime') DAY), '%Y-%m-%d %H:%i:%s')
                WHEN (JSON_VALUE(Priv, '$.password_lifetime') IS NULL OR JSON_VALUE(Priv, '$.password_lifetime') = -1)
                    AND @@global.default_password_lifetime > 0 THEN
                    DATE_FORMAT(DATE_ADD(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')), INTERVAL @@global.default_password_lifetime DAY), '%Y-%m-%d %H:%i:%s')
                ELSE '만료안됨'
            END AS expire_date,
            IFNULL(
                NULLIF(
                    CONCAT_WS(',',
                        NULLIF(JSON_VALUE(Priv, '$.plugin'), ''),
                        NULLIF(JSON_VALUE(Priv, '$.auth_or[0].plugin'), ''),
                        NULLIF(JSON_VALUE(Priv, '$.auth_or[1].plugin'), ''),
                        NULLIF(JSON_VALUE(Priv, '$.auth_or[2].plugin'), '')
                    ),
                    ''
                ),
                'N/A'
            ) AS auth_module,
            $PASSWORD_COMPLEXITY_TARGET_CASE AS password_complexity_target,
            $PASSWORD_REUSE_TARGET_CASE AS password_reuse_target,
            CASE
                WHEN JSON_VALUE(Priv, '$.password_lifetime') = 0 THEN 'OK'
                WHEN @@global.default_password_lifetime = 0
                    AND (JSON_VALUE(Priv, '$.password_lifetime') IS NULL OR JSON_VALUE(Priv, '$.password_lifetime') = -1)
                    THEN 'OK'
                WHEN JSON_VALUE(Priv, '$.password_last_changed') IS NULL
                    THEN 'UNKNOWN'
                WHEN NOW() > DATE_ADD(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')),
                     INTERVAL CASE
                        WHEN JSON_VALUE(Priv, '$.password_lifetime') IS NULL OR JSON_VALUE(Priv, '$.password_lifetime') = -1
                            THEN @@global.default_password_lifetime
                        ELSE JSON_VALUE(Priv, '$.password_lifetime')
                     END DAY)
                     THEN 'EXPIRED'
                ELSE 'OK'
            END AS status
        FROM
            mysql.global_priv
        WHERE
            $WHERE_CLAUSE
        ORDER BY
            User, Host;
        "
    } | print_tsv_table

    echo ""
    echo "==================================================================="
    if [ "${MYSQL_CONNECT_MODE}" = "SOCKET" ]; then
        echo "접속 설정: SOCKET (${MYSQL_SOCKET})"
    else
        echo "접속 설정: TCP (${MYSQL_HOST}:${MYSQL_PORT})"
    fi
    echo "전역 설정: default_password_lifetime = $(mysql "${MYSQL_OPTS[@]}" -sNe 'SELECT @@global.default_password_lifetime;')일"
    echo "전역 설정: simple_password_check = ${SIMPLE_PASSWORD_CHECK_STATUS}"
    echo "전역 설정: password_reuse_check = ${PASSWORD_REUSE_CHECK_STATUS}"
    echo "==================================================================="

    # 하단 만료 집계는 위 표의 상태 계산식과 반드시 동일해야 합니다.
    EXPIRED_COUNT=$(mysql "${MYSQL_OPTS[@]}" -sNe "
    SELECT COUNT(*)
    FROM (
        SELECT
            CASE
                WHEN JSON_VALUE(Priv, '$.password_lifetime') = 0 THEN 'OK'
                WHEN @@global.default_password_lifetime = 0
                    AND (JSON_VALUE(Priv, '$.password_lifetime') IS NULL OR JSON_VALUE(Priv, '$.password_lifetime') = -1)
                    THEN 'OK'
                WHEN JSON_VALUE(Priv, '$.password_last_changed') IS NULL
                    THEN 'UNKNOWN'
                WHEN NOW() > DATE_ADD(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')),
                     INTERVAL CASE
                        WHEN JSON_VALUE(Priv, '$.password_lifetime') IS NULL OR JSON_VALUE(Priv, '$.password_lifetime') = -1
                            THEN @@global.default_password_lifetime
                        ELSE JSON_VALUE(Priv, '$.password_lifetime')
                     END DAY)
                     THEN 'EXPIRED'
                ELSE 'OK'
            END AS status
        FROM mysql.global_priv
        WHERE ($WHERE_CLAUSE)
    ) AS status_result
    WHERE status = 'EXPIRED';
    ")

    if [ "${EXPIRED_COUNT:-0}" -gt 0 ]; then
        echo -e "${RED}경고: ${EXPIRED_COUNT}개의 계정이 만료되었습니다!${NC}"
        echo ""
        echo "만료된 계정 목록:"

        {
            printf "계정\t개별설정\t기간\t마지막변경일\t만료일\t인증모듈\t복잡도\t이력\n"

            mysql "${MYSQL_OPTS[@]}" --batch --skip-column-names -e "
            SELECT
                account,
                individual_policy,
                effective_lifetime,
                last_changed,
                expire_date,
                auth_module,
                password_complexity_target,
                password_reuse_target
            FROM (
                SELECT
                    CONCAT(User, '@', Host) AS account,
                    CASE
                        WHEN JSON_VALUE(Priv, '$.password_lifetime') IS NULL THEN '전역값'
                        WHEN JSON_VALUE(Priv, '$.password_lifetime') = 0 THEN '무기한'
                        WHEN JSON_VALUE(Priv, '$.password_lifetime') = -1 THEN 'DEFAULT'
                        ELSE CONCAT(JSON_VALUE(Priv, '$.password_lifetime'), '일')
                    END AS individual_policy,
                    CASE
                        WHEN JSON_VALUE(Priv, '$.password_lifetime') IS NULL
                            OR JSON_VALUE(Priv, '$.password_lifetime') = -1
                            THEN @@global.default_password_lifetime
                        ELSE JSON_VALUE(Priv, '$.password_lifetime')
                    END AS effective_lifetime,
                    IFNULL(DATE_FORMAT(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')), '%Y-%m-%d %H:%i:%s'), 'N/A') AS last_changed,
                    CASE
                        WHEN JSON_VALUE(Priv, '$.password_lifetime') = 0 THEN '만료안됨'
                        WHEN JSON_VALUE(Priv, '$.password_lifetime') > 0 THEN
                            DATE_FORMAT(DATE_ADD(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')), INTERVAL JSON_VALUE(Priv, '$.password_lifetime') DAY), '%Y-%m-%d %H:%i:%s')
                        WHEN (JSON_VALUE(Priv, '$.password_lifetime') IS NULL OR JSON_VALUE(Priv, '$.password_lifetime') = -1)
                            AND @@global.default_password_lifetime > 0 THEN
                            DATE_FORMAT(DATE_ADD(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')), INTERVAL @@global.default_password_lifetime DAY), '%Y-%m-%d %H:%i:%s')
                        ELSE '만료안됨'
                    END AS expire_date,
                    IFNULL(
                        NULLIF(
                            CONCAT_WS(',',
                                NULLIF(JSON_VALUE(Priv, '$.plugin'), ''),
                                NULLIF(JSON_VALUE(Priv, '$.auth_or[0].plugin'), ''),
                                NULLIF(JSON_VALUE(Priv, '$.auth_or[1].plugin'), ''),
                                NULLIF(JSON_VALUE(Priv, '$.auth_or[2].plugin'), '')
                            ),
                            ''
                        ),
                        'N/A'
                    ) AS auth_module,
                    $PASSWORD_COMPLEXITY_TARGET_CASE AS password_complexity_target,
                    $PASSWORD_REUSE_TARGET_CASE AS password_reuse_target,
                    CASE
                        WHEN JSON_VALUE(Priv, '$.password_lifetime') = 0 THEN 'OK'
                        WHEN @@global.default_password_lifetime = 0
                            AND (JSON_VALUE(Priv, '$.password_lifetime') IS NULL OR JSON_VALUE(Priv, '$.password_lifetime') = -1)
                            THEN 'OK'
                        WHEN JSON_VALUE(Priv, '$.password_last_changed') IS NULL
                            THEN 'UNKNOWN'
                        WHEN NOW() > DATE_ADD(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')),
                             INTERVAL CASE
                                WHEN JSON_VALUE(Priv, '$.password_lifetime') IS NULL OR JSON_VALUE(Priv, '$.password_lifetime') = -1
                                    THEN @@global.default_password_lifetime
                                ELSE JSON_VALUE(Priv, '$.password_lifetime')
                             END DAY)
                             THEN 'EXPIRED'
                        ELSE 'OK'
                    END AS status
                FROM mysql.global_priv
                WHERE ($WHERE_CLAUSE)
            ) AS expired_result
            WHERE status = 'EXPIRED'
            ORDER BY account;
            "
        } | print_tsv_table
    else
        echo -e "${GREEN}모든 조회된 계정이 정상 상태입니다.${NC}"
    fi
    echo ""
}

# 메인
case "${1:-}" in
    "")
        check_mysql_connection
        show_password_status
        ;;
    "--help"|"-h"|"help")
        print_usage 0
        ;;
    "plugins")
        check_mysql_connection
        show_auth_plugins
        ;;
    "pw-check")
        check_mysql_connection
        run_simple_password_check_test "${2:-}"
        ;;
    "reuse-check")
        check_mysql_connection
        show_password_reuse_check_status
        ;;
    "set")
        if [ $# -lt 3 ]; then
            print_usage 1
        fi
        check_mysql_connection
        set_password_policy "$2" "$3" "${4:-}" "${5:-}" "${6:-}"
        ;;
    *)
        echo -e "${RED}ERROR: 알 수 없는 명령입니다: $1${NC}"
        echo "도움말: $0 --help"
        exit 1
        ;;
esac
