#!/bin/bash

# MariaDB 비밀번호 만료 관리 스크립트

# ==================== 설정 영역 ====================
MYSQL_USER="root"
MYSQL_PASSWORD="PASSWORD"
MYSQL_HOST="localhost"
MYSQL_PORT="3306"

ACCOUNTS=(
    # "root@localhost"
    # "root@127.0.0.1"
    # "app@localhost"
    # "app@127.0.0.1"
    "all"
)

EXCLUDE_SYSTEM_ACCOUNTS=true
# ==================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_usage() {
    echo "=========================================="
    echo "MariaDB 비밀번호 만료 관리 스크립트"
    echo "=========================================="
    echo ""
    echo "사용법:"
    echo "  $0                           # 조회 모드"
    echo "  $0 set <user@host> <policy>  # 설정 모드"
    echo ""
    echo "설정 모드 예시:"
    echo "  $0 set root@localhost never"
    echo "  $0 set root@localhost 90"
    echo "  $0 set root@localhost default"
    echo "  $0 set root@localhost reset 'Password@1!@#'"
    echo "  $0 set root@localhost reset-with 'Password@1!@#' 90"
    echo ""
    echo "주의: 특수문자가 포함된 비밀번호는 반드시 작은따옴표('')로 감싸주세요!"
    echo ""
    exit 1
}

generate_where_clause() {
    local conditions=()
    
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
            conditions+=("(User = '$user' AND Host = '$host')")
        fi
    done
    
    local IFS='|'
    echo "${conditions[*]}" | sed 's/|/ OR /g'
}

MYSQL_OPTS=" -u${MYSQL_USER}"
if [ -n "$MYSQL_PASSWORD" ]; then
    MYSQL_OPTS="$MYSQL_OPTS -p${MYSQL_PASSWORD}"
fi

# 비밀번호 이스케이프 함수 (SQL injection 방지)
escape_password() {
    local password="$1"
    # 작은따옴표를 두 개로 변경 (SQL 표준 이스케이프)
    echo "${password//\'/\'\'}"
}

set_password_policy() {
    local account=$1
    local policy=$2
    local new_password="$3"  # 따옴표로 보호
    local days=$4
    
    if [[ $account =~ ^([^@]+)@(.+)$ ]]; then
        local user="${BASH_REMATCH[1]}"
        local host="${BASH_REMATCH[2]}"
    else
        echo -e "${RED}ERROR: 잘못된 계정 형식${NC}"
        exit 1
    fi
    
    echo "=========================================="
    echo -e "${BLUE}비밀번호 만료 정책 설정${NC}"
    echo "=========================================="
    echo "계정: $user@$host"
    echo "정책: $policy"
    echo ""
    
    local sql=""
    local escaped_password=""
    
    case $policy in
        "never")
            sql="ALTER USER '$user'@'$host' PASSWORD EXPIRE NEVER;"
            echo -e "${GREEN}→ 만료되지 않도록 설정합니다.${NC}"
            ;;
        "default")
            sql="ALTER USER '$user'@'$host' PASSWORD EXPIRE DEFAULT;"
            echo -e "${YELLOW}→ 전역 설정을 따르도록 설정합니다.${NC}"
            ;;
        "reset")
            if [ -z "$new_password" ]; then
                echo -e "${RED}ERROR: 비밀번호를 입력해주세요.${NC}"
                echo "예시: $0 set $account reset 'Hoho@89!@#'"
                exit 1
            fi
            # 비밀번호 이스케이프 처리
            escaped_password=$(escape_password "$new_password")
            sql="ALTER USER '$user'@'$host' IDENTIFIED BY '$escaped_password' PASSWORD EXPIRE NEVER;"
            echo -e "${GREEN}→ 비밀번호를 재설정하고 만료되지 않도록 설정합니다.${NC}"
            ;;
        "reset-with")
            if [ -z "$new_password" ] || [ -z "$days" ]; then
                echo -e "${RED}ERROR: 비밀번호와 만료 일수를 입력해주세요.${NC}"
                echo "예시: $0 set $account reset-with 'Hoho@89!@#' 90"
                exit 1
            fi
            # 비밀번호 이스케이프 처리
            escaped_password=$(escape_password "$new_password")
            sql="ALTER USER '$user'@'$host' IDENTIFIED BY '$escaped_password' PASSWORD EXPIRE INTERVAL $days DAY;"
            echo -e "${GREEN}→ 비밀번호를 재설정하고 ${days}일 후 만료되도록 설정합니다.${NC}"
            ;;
        [0-9]*)
            sql="ALTER USER '$user'@'$host' PASSWORD EXPIRE INTERVAL $policy DAY;"
            echo -e "${YELLOW}→ ${policy}일 후 만료되도록 설정합니다.${NC}"
            ;;
        *)
            echo -e "${RED}ERROR: 잘못된 정책${NC}"
            exit 1
            ;;
    esac
    
    # SQL 실행 (에러 출력 포함)
    if mysql $MYSQL_OPTS -e "$sql" 2>&1; then
        echo -e "${GREEN}✓ 설정이 완료되었습니다.${NC}"
        echo ""
        echo "변경 후 상태:"
        mysql $MYSQL_OPTS --batch --skip-column-names -e "
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
            )
        FROM mysql.global_priv
        WHERE User = '$user' AND Host = '$host';
        " 2>/dev/null
    else
        echo -e "${RED}✗ 설정 실패${NC}"
        exit 1
    fi
}

show_password_status() {
    local WHERE_CLAUSE=$(generate_where_clause)
    
    if [ "$EXCLUDE_SYSTEM_ACCOUNTS" == "true" ]; then
        WHERE_CLAUSE="($WHERE_CLAUSE) AND User NOT IN ('mariadb.sys', 'mysql')"
    fi
    
    echo "==================================================================="
    echo "MariaDB 계정 비밀번호 만료 상태 조회"
    echo "==================================================================="
    echo ""
    
    printf "%-30s | %-30s | %-15s | %-20s | %-20s | %-10s\n" \
        "계정" "개별설정" "적용기간(일)" "마지막변경일" "만료예정일" "상태"
    echo "-----------------------------------------------------------------------------------------------------------------------------------"
    
    mysql $MYSQL_OPTS --batch --skip-column-names -e "
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
        CASE 
            WHEN JSON_VALUE(Priv, '$.password_lifetime') = 0 THEN 'OK'
            WHEN @@global.default_password_lifetime = 0 
                AND (JSON_VALUE(Priv, '$.password_lifetime') IS NULL OR JSON_VALUE(Priv, '$.password_lifetime') = -1) 
                THEN 'OK'
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
    " | while IFS=$'\t' read -r account setting period last_changed expire_date status; do
        if [ "$status" == "EXPIRED" ]; then
            status_color="${RED}${status}${NC}"
        else
            status_color="${GREEN}${status}${NC}"
        fi
        
        printf "%-30s | %-30s | %-15s | %-20s | %-20s | %b\n" \
            "$account" "$setting" "$period" "$last_changed" "$expire_date" "$status_color"
    done
    
    echo ""
    echo "==================================================================="
    echo "전역 설정: default_password_lifetime = $(mysql $MYSQL_OPTS -sNe 'SELECT @@global.default_password_lifetime;')일"
    echo "==================================================================="
    
    EXPIRED_COUNT=$(mysql $MYSQL_OPTS -sNe "
    SELECT COUNT(*) 
    FROM mysql.global_priv 
    WHERE ($WHERE_CLAUSE)
      AND JSON_VALUE(Priv, '$.password_lifetime') != 0
      AND (@@global.default_password_lifetime != 0 OR JSON_VALUE(Priv, '$.password_lifetime') IS NOT NULL)
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
if [ $# -eq 0 ]; then
    show_password_status
elif [ "$1" == "set" ]; then
    if [ $# -lt 3 ]; then
        print_usage
    fi
    set_password_policy "$2" "$3" "$4" "$5"
else
    print_usage
fi
