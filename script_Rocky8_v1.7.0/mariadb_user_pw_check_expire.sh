#!/bin/bash

# MariaDB 비밀번호 만료/인증 플러그인 관리 스크립트

# ==================== 설정 영역 ====================
MYSQL_USER="root"
MYSQL_PASSWORD="[PASSWORD]"
MYSQL_HOST="localhost"
MYSQL_PORT="3306"

ACCOUNTS=(
    # "root@localhost"
    # "root@127.0.0.1"
    # "app@localhost"
    # "app@127.0.0.1"
    "all"
)

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
MYSQL_OPTS=("-h${MYSQL_HOST}" "-P${MYSQL_PORT}" "-u${MYSQL_USER}")
if [ -n "$MYSQL_PASSWORD" ]; then
    MYSQL_OPTS+=("-p${MYSQL_PASSWORD}")
fi

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
  ./SCRIPT_NAME set <user@host> <policy> [args...]

조회 모드 출력 컬럼:
  - 계정
  - 개별설정
  - 적용기간(일)
  - 마지막변경일
  - 만료예정일
  - 인증/암호화모듈
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
    if mysql "${MYSQL_OPTS[@]}" -e "$sql" 2>&1; then
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
        echo -e "${RED}✗ 설정 실패${NC}"
        exit 1
    fi
}

show_password_status() {
    local WHERE_CLAUSE
    WHERE_CLAUSE=$(generate_where_clause)

    if [ "$EXCLUDE_SYSTEM_ACCOUNTS" == "true" ]; then
        WHERE_CLAUSE="($WHERE_CLAUSE) AND User NOT IN ('mariadb.sys', 'mysql')"
    fi

    echo "==================================================================="
    echo "MariaDB 계정 비밀번호 만료/인증 플러그인 상태 조회"
    echo "==================================================================="
    echo ""

    printf "%-30s | %-30s | %-15s | %-20s | %-20s | %-28s | %-10s\n" \
        "계정" "개별설정" "적용기간(일)" "마지막변경일" "만료예정일" "인증/암호화모듈" "상태"
    echo "----------------------------------------------------------------------------------------------------------------------------------------------------------------"

    mysql "${MYSQL_OPTS[@]}" --batch --skip-column-names -e "
    SELECT
        CONCAT(User, '@', Host) AS '계정',
        CASE
            WHEN JSON_VALUE(Priv, '$.password_lifetime') IS NULL THEN '설정없음 (전역값 따름)'
            WHEN JSON_VALUE(Priv, '$.password_lifetime') = 0 THEN '무기한 (Never)'
            WHEN JSON_VALUE(Priv, '$.password_lifetime') = -1 THEN 'DEFAULT (전역값 따름)'
            ELSE CONCAT(JSON_VALUE(Priv, '$.password_lifetime'), '일')
        END AS '개별_설정',
        CASE
            WHEN JSON_VALUE(Priv, '$.password_lifetime') IS NULL
                OR JSON_VALUE(Priv, '$.password_lifetime') = -1
                THEN @@global.default_password_lifetime
            ELSE JSON_VALUE(Priv, '$.password_lifetime')
        END AS '적용_기간(일)',
        IFNULL(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')), 'N/A') AS '마지막_변경일',
        CASE
            WHEN JSON_VALUE(Priv, '$.password_lifetime') = 0 THEN '만료되지 않음'
            WHEN JSON_VALUE(Priv, '$.password_lifetime') > 0 THEN
                DATE_ADD(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')), INTERVAL JSON_VALUE(Priv, '$.password_lifetime') DAY)
            WHEN (JSON_VALUE(Priv, '$.password_lifetime') IS NULL OR JSON_VALUE(Priv, '$.password_lifetime') = -1)
                AND @@global.default_password_lifetime > 0 THEN
                DATE_ADD(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')), INTERVAL @@global.default_password_lifetime DAY)
            ELSE '만료되지 않음'
        END AS '만료_예정일',
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
        ) AS '인증_암호화_모듈',
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
        END AS '상태'
    FROM
        mysql.global_priv
    WHERE
        $WHERE_CLAUSE
    ORDER BY
        User, Host;
    " | while IFS=$'\t' read -r account setting period last_changed expire_date auth_module status; do
        if [ "$status" == "EXPIRED" ]; then
            status_color="${RED}${status}${NC}"
        elif [ "$status" == "UNKNOWN" ]; then
            status_color="${YELLOW}${status}${NC}"
        else
            status_color="${GREEN}${status}${NC}"
        fi

        printf "%-30s | %-30s | %-15s | %-20s | %-20s | %-28s | %b\n" \
            "$account" "$setting" "$period" "$last_changed" "$expire_date" "$auth_module" "$status_color"
    done

    echo ""
    echo "==================================================================="
    echo "전역 설정: default_password_lifetime = $(mysql "${MYSQL_OPTS[@]}" -sNe 'SELECT @@global.default_password_lifetime;')일"
    echo "==================================================================="

    EXPIRED_COUNT=$(mysql "${MYSQL_OPTS[@]}" -sNe "
    SELECT COUNT(*)
    FROM mysql.global_priv
    WHERE ($WHERE_CLAUSE)
      AND COALESCE(JSON_VALUE(Priv, '$.password_lifetime'), -1) != 0
      AND (@@global.default_password_lifetime != 0 OR JSON_VALUE(Priv, '$.password_lifetime') IS NOT NULL)
      AND JSON_VALUE(Priv, '$.password_last_changed') IS NOT NULL
      AND NOW() > DATE_ADD(FROM_UNIXTIME(JSON_VALUE(Priv, '$.password_last_changed')),
          INTERVAL CASE
            WHEN JSON_VALUE(Priv, '$.password_lifetime') IS NULL OR JSON_VALUE(Priv, '$.password_lifetime') = -1
                THEN @@global.default_password_lifetime
            ELSE JSON_VALUE(Priv, '$.password_lifetime')
          END DAY);
    ")

    if [ "$EXPIRED_COUNT" -gt 0 ]; then
        echo -e "${RED}경고: ${EXPIRED_COUNT}개의 계정이 만료되었습니다!${NC}"
    else
        echo -e "${GREEN}모든 조회된 계정이 정상 상태입니다.${NC}"
    fi
    echo ""
}

# 메인
case "${1:-}" in
    "")
        show_password_status
        ;;
    "--help"|"-h"|"help")
        print_usage 0
        ;;
    "plugins")
        show_auth_plugins
        ;;
    "set")
        if [ $# -lt 3 ]; then
            print_usage 1
        fi
        set_password_policy "$2" "$3" "${4:-}" "${5:-}" "${6:-}"
        ;;
    *)
        echo -e "${RED}ERROR: 알 수 없는 명령입니다: $1${NC}"
        echo "도움말: $0 --help"
        exit 1
        ;;
esac
