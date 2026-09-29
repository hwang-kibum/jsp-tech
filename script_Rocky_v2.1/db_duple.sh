#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/00.mariadb_duple"

SERVICE_NAME="mariadb-duple-monitor"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"

if [ "${1:-}" != "__monitor_worker" ]; then
    LOG_FILE="${LOG_DIR}/$(basename "${BASH_SOURCE[0]%.sh}")_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "로그 파일: ${LOG_FILE}"
fi

DB_ROOT_USER_DEFAULT="root"
ERROR_LOG_DEFAULT="/data/logs/mariadb/error/error.err"
EXPIRE_LOGS_DAYS_DEFAULT="7"

HEALTH_INTERVAL_DEFAULT=10
HEALTH_FAIL_THRESHOLD_DEFAULT=6
HEALTH_TIMEOUT_DEFAULT=5

FAILOVER_MODE_DEFAULT=3

VIP_MODE_DEFAULT="no"

AUTO_START_MONITOR_DEFAULT="no"

CONFIG_CHANGED=0

COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'

log() {
    local msg="$1"
    local color="$COLOR_GREEN"

    case "$msg" in
        "[ERROR]"*) color="$COLOR_RED" ;;
        "[WARN]"*)  color="$COLOR_YELLOW" ;;
    esac

    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}${COLOR_RESET}" >&2
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "[ERROR] 설정 파일을 찾을 수 없습니다: $CONFIG_FILE"
        exit 1
    fi
    source "$CONFIG_FILE"

    DB_ROOT_USER="${DB_ROOT_USER:-$DB_ROOT_USER_DEFAULT}"
    ERROR_LOG="${ERROR_LOG:-$ERROR_LOG_DEFAULT}"
    EXPIRE_LOGS_DAYS="${EXPIRE_LOGS_DAYS:-$EXPIRE_LOGS_DAYS_DEFAULT}"

    HEALTH_INTERVAL="${HEALTH_INTERVAL:-$HEALTH_INTERVAL_DEFAULT}"
    HEALTH_FAIL_THRESHOLD="${HEALTH_FAIL_THRESHOLD:-$HEALTH_FAIL_THRESHOLD_DEFAULT}"
    HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-$HEALTH_TIMEOUT_DEFAULT}"

    FAILOVER_MODE="${FAILOVER_MODE:-$FAILOVER_MODE_DEFAULT}"
    VIP_MODE="${VIP_MODE:-$VIP_MODE_DEFAULT}"
    AUTO_START_MONITOR="${AUTO_START_MONITOR:-$AUTO_START_MONITOR_DEFAULT}"

    if [ "$VIP_MODE" == "yes" ] && [ -z "$SUB_IP" ]; then
        log "[ERROR] VIP_MODE=yes 인데 SUB_IP 가 설정되어 있지 않습니다."
        exit 1
    fi

    case "$FAILOVER_MODE" in
        1|2|3) ;;
        *)
            log "[ERROR] FAILOVER_MODE 값이 올바르지 않습니다: '${FAILOVER_MODE}' (1, 2, 3 중 하나여야 합니다)"
            exit 1
            ;;
    esac
}

failover_mode_desc() {
    case "$FAILOVER_MODE" in
        1) echo "모드 1 - 장애 감지 시 판정 구분 없이 자동 승격" ;;
        2) echo "모드 2 - 실제 장애로 확인된 경우만 자동 승격" ;;
        3) echo "모드 3 - 자동 승격 안 함 (수동 승격만)" ;;
    esac
}

should_auto_promote() {
    case "$FAILOVER_MODE" in
        1)
            return 0
            ;;
        2)
            if [ "$HC_VERDICT" == "SERVER_DOWN" ] || [ "$HC_VERDICT" == "DB_DOWN" ]; then
                return 0
            fi
            return 1
            ;;
        3)
            return 1
            ;;
    esac
    return 1
}

check_dir_owner() {
    local dir="$1"
    local expected_owner="$2"
    local label="$3"
    local required="$4"

    if [ ! -d "$dir" ]; then
        if [ "$required" -eq 1 ]; then
            log "[ERROR] ${label}(${dir}) 디렉토리가 존재하지 않습니다. MariaDB 설치 상태를 확인하세요."
            exit 1
        else
            log "${label}(${dir}) 디렉토리가 아직 없습니다 (필요 시 자동 생성되는 경로라 통과)"
            return
        fi
    fi

    local current_owner
    current_owner="$(stat -c '%U' "$dir" 2>/dev/null)"

    if [ "$current_owner" != "$expected_owner" ]; then
        log "[WARN] ${label}(${dir}) 소유자가 '${current_owner}' 로 되어 있어 '${expected_owner}' 로 변경합니다."
        chown -R "${expected_owner}:${expected_owner}" "$dir"
    else
        log "${label}(${dir}) 소유자 확인 완료 (${expected_owner})"
    fi
}

validate_paths() {
    log "설정 경로 검증 시작"

    check_dir_owner "$BASEDIR" "$DB_owner" "BASEDIR" 1
    check_dir_owner "$DATADIR" "$DB_owner" "DATADIR" 1
    check_dir_owner "$DATADIR_OLD_BACKUP" "$DB_owner" "DATADIR_OLD_BACKUP" 0

    if [ ! -d "$BACKUP_DIR" ]; then
        log "[WARN] BACKUP_DIR(${BACKUP_DIR})이 없어 새로 생성합니다."
        mkdir -p "$BACKUP_DIR"
    fi
    chown -R "${SSH_USER}:${SSH_USER}" "$BACKUP_DIR"
    log "BACKUP_DIR(${BACKUP_DIR}) 소유자 확인/설정 완료 (${SSH_USER})"

    log "설정 경로 검증 완료"
}

decrypt_password() {
    local enc_value="$1"
    local salt
    salt=$(printf '%s' "${DB_owner}" | md5sum | cut -c1-16)

    echo "${enc_value}" | openssl enc -aes-256-cbc -a -d \
        -S "${salt}" -pbkdf2 -iter 100000 -pass pass:"${REPL_USER}" 2>/dev/null
}

resolve_password() {
    local enc_value="$1"
    local label="$2"
    local result=""

    if [ -z "$enc_value" ]; then
        log "[WARN] ${label} 값이 설정 파일(config/00.mariadb_duple)에 없습니다. 직접 입력해주세요."
    else
        result="$(decrypt_password "$enc_value")"
        if [ -z "$result" ]; then
            log "[WARN] ${label} 복호화 결과가 공백입니다. 직접 입력해주세요."
        fi
    fi

    if [ -z "$result" ]; then
        read -r -s -p "${label} 입력: " result
        echo >&2
    fi

    if [ -z "$result" ]; then
        log "[ERROR] ${label} 값이 비어 있습니다. 스크립트를 종료합니다."
        exit 1
    fi

    echo "$result"
}

resolve_root_password() {
    local enc_value="$1"
    local result=""

    if [ -n "$enc_value" ]; then
        result="$(decrypt_password "$enc_value")"
    fi

    if [ -n "$result" ]; then
        echo "$result"
        return
    fi

    log "[WARN] DB ROOT 비밀번호 값을 설정 파일에서 확인할 수 없습니다. 실제 계정 상태를 확인합니다."

    if "${MYSQL_BIN}" -u"${DB_ROOT_USER}" -e "SELECT 1;" >/dev/null 2>&1; then
        log "[WARN] ${DB_ROOT_USER}@localhost 계정에 비밀번호가 설정되어 있지 않습니다. 새 비밀번호를 설정합니다."

        local new_pw new_pw_confirm
        while true; do
            read -r -s -p "새로 사용할 ${DB_ROOT_USER} 비밀번호 입력: " new_pw
            echo >&2
            read -r -s -p "비밀번호 확인 (다시 입력): " new_pw_confirm
            echo >&2

            if [ -z "$new_pw" ]; then
                log "[WARN] 비밀번호는 비워둘 수 없습니다. 다시 입력해주세요."
                continue
            fi
            if [ "$new_pw" != "$new_pw_confirm" ]; then
                log "[WARN] 입력하신 두 값이 서로 다릅니다. 다시 입력해주세요."
                continue
            fi
            break
        done

        if ! "${MYSQL_BIN}" -u"${DB_ROOT_USER}" -e "ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${new_pw}'; FLUSH PRIVILEGES;"; then
            log "[ERROR] 비밀번호 설정(ALTER USER)에 실패했습니다."
            exit 1
        fi

        if ! "${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${new_pw}" -e "SELECT 1;" >/dev/null 2>&1; then
            log "[ERROR] 비밀번호를 설정했으나 해당 비밀번호로 로그인되지 않습니다."
            log "[ERROR] ${DB_ROOT_USER} 계정이 localhost 외 다른 호스트로 정의되어 있을 수 있습니다."
            exit 1
        fi

        log "${DB_ROOT_USER}@localhost 비밀번호 설정 및 로그인 확인 완료"
        echo "$new_pw"
    else
        log "[WARN] ${DB_ROOT_USER} 계정에 실제로는 비밀번호가 설정되어 있는 것으로 보입니다."

        local attempt=1
        local max_attempts=3
        while [ "$attempt" -le "$max_attempts" ]; do
            read -r -s -p "${DB_ROOT_USER} 비밀번호 입력 (${attempt}/${max_attempts}): " result
            echo >&2

            if [ -z "$result" ]; then
                log "[WARN] 비밀번호가 입력되지 않았습니다."
                attempt=$((attempt + 1))
                continue
            fi

            if "${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${result}" -e "SELECT 1;" >/dev/null 2>&1; then
                log "${DB_ROOT_USER} 계정 로그인 확인 완료"
                echo "$result"
                return
            fi

            log "[WARN] 로그인에 실패했습니다. 비밀번호를 다시 확인해주세요."
            attempt=$((attempt + 1))
        done

        log "[ERROR] ${max_attempts}회 시도했으나 ${DB_ROOT_USER} 계정 로그인에 실패했습니다."
        exit 1
    fi
}

resolve_active_passwords() {
    DB_ROOT_PASSWORD="$(resolve_root_password "${DB_ROOT_PASSWORD_ENC}")"
    REPL_PASSWORD="$(resolve_password "${REPL_PASSWORD_ENC}" "REPLICATION 계정(${REPL_USER}) 비밀번호")"

    update_config_enc "DB_ROOT_PASSWORD_ENC" "$DB_ROOT_PASSWORD"
}

resolve_standby_passwords() {
    log "Standby에 적용할 비밀번호를 입력받습니다 (Active에서 사용 중인 값과 동일해야 합니다)."

    DB_ROOT_PASSWORD="$(resolve_password "${DB_ROOT_PASSWORD_ENC}" "Active와 동일한 DB ROOT 비밀번호")"
    REPL_PASSWORD="$(resolve_password "${REPL_PASSWORD_ENC}" "Active와 동일한 REPLICATION 계정(${REPL_USER}) 비밀번호")"

    update_config_enc "DB_ROOT_PASSWORD_ENC" "$DB_ROOT_PASSWORD"
    update_config_enc "REPL_PASSWORD_ENC" "$REPL_PASSWORD"

    log "입력받은 값은 실제 백업 복원 후 로그인 검증으로 최종 확인됩니다."
}

encrypt_password() {
    local plain_value="$1"
    local salt
    salt=$(printf '%s' "${DB_owner}" | md5sum | cut -c1-16)

    echo "${plain_value}" | openssl enc -aes-256-cbc -a \
        -S "${salt}" -pbkdf2 -iter 100000 -pass pass:"${REPL_USER}" 2>/dev/null
}

update_config_enc() {
    local var_name="$1"
    local plain_value="$2"
    local enc_value
    enc_value="$(encrypt_password "$plain_value")"

    if [ -z "$enc_value" ]; then
        log "[WARN] ${var_name} 암호화에 실패하여 설정 파일 갱신을 건너뜁니다."
        return
    fi

    if grep -q "^${var_name}=" "$CONFIG_FILE"; then
        sed -i "s#^${var_name}=.*#${var_name}=\"${enc_value}\"#" "$CONFIG_FILE"
        log "${var_name} 값을 설정 파일(${CONFIG_FILE})에 갱신했습니다."
    else
        echo "${var_name}=\"${enc_value}\"" >> "$CONFIG_FILE"
        log "${var_name} 값을 설정 파일(${CONFIG_FILE})에 추가했습니다."
    fi
}

vip_enabled() {
    [ "$VIP_MODE" == "yes" ] && [ -n "$SUB_IP" ]
}

resolve_sub_ip_dev() {
    if [ -n "$SUB_IP_DEV" ]; then
        echo "$SUB_IP_DEV"
        return 0
    fi

    local my_ip dev
    my_ip="$(hostname -I | awk '{print $1}')"
    dev="$(ip -o -4 addr show 2>/dev/null | awk -v ip="$my_ip" '$4 ~ "^"ip"/" {print $2; exit}')"

    if [ -z "$dev" ]; then
        dev="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
    fi

    echo "$dev"
}

sub_ip_is_assigned() {
    ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$SUB_IP"
}

sub_ip_in_use_by_peer() {
    local target="$1"
    timeout 3 bash -c "echo > /dev/tcp/${SUB_IP}/${SSH_PORT}" 2>/dev/null
}

sub_ip_alive_on_network() {
    if command -v arping >/dev/null 2>&1; then
        local dev
        dev="$(resolve_sub_ip_dev)"
        if [ -n "$dev" ]; then
            arping -q -c 2 -w 3 -D -I "$dev" "$SUB_IP" 2>/dev/null && return 1
            return 0
        fi
    fi

    ping -c 2 -W 2 "$SUB_IP" >/dev/null 2>&1
}

check_sub_ip_conflict() {
    vip_enabled || return 0

    if sub_ip_is_assigned; then
        return 0
    fi

    if sub_ip_alive_on_network; then
        log "[WARN] SUB_IP(${SUB_IP})가 네트워크에서 아직 응답하고 있습니다."
        log "[WARN] 기존 Active가 이 IP를 잡고 있을 수 있어, 지금 부여하면 IP 충돌이 발생합니다."
        log "[WARN] Active 서버에서 monitor-start 로 자가 감시를 돌리면 이 상황을 자동으로 막을 수 있습니다."
        return 1
    fi

    return 0
}

attach_sub_ip() {
    vip_enabled || return 0

    if ! command -v ip >/dev/null 2>&1; then
        log "[ERROR] 'ip' 명령을 찾을 수 없어 보조 IP를 부여할 수 없습니다 (iproute2 설치 필요)."
        return 1
    fi

    if sub_ip_is_assigned; then
        log "보조 IP(${SUB_IP})가 이미 이 서버에 부여되어 있습니다."
        return 0
    fi

    local dev
    dev="$(resolve_sub_ip_dev)"
    if [ -z "$dev" ]; then
        log "[ERROR] 보조 IP를 부여할 네트워크 인터페이스를 찾지 못했습니다."
        log "[ERROR] config의 SUB_IP_DEV 에 인터페이스명을 직접 지정하세요 (예: ens192)"
        return 1
    fi

    log "보조 IP 부여: ${SUB_IP}/${SUB_IP_CIDR} dev ${dev}"
    if ip addr add "${SUB_IP}/${SUB_IP_CIDR}" dev "$dev" 2>/dev/null; then
        command -v arping >/dev/null 2>&1 && \
            arping -q -c 2 -A -I "$dev" "$SUB_IP" 2>/dev/null || true
        log "보조 IP 부여 완료 (${SUB_IP} -> ${dev})"
    else
        log "[ERROR] 보조 IP 부여에 실패했습니다: ip addr add ${SUB_IP}/${SUB_IP_CIDR} dev ${dev}"
        return 1
    fi
}

detach_sub_ip() {
    vip_enabled || return 0

    if ! sub_ip_is_assigned; then
        return 0
    fi

    local dev
    dev="$(ip -o -4 addr show 2>/dev/null | awk -v ip="$SUB_IP" '$4 ~ "^"ip"/" {print $2; exit}')"
    [ -z "$dev" ] && dev="$(resolve_sub_ip_dev)"

    log "보조 IP 회수: ${SUB_IP}/${SUB_IP_CIDR} dev ${dev}"
    ip addr del "${SUB_IP}/${SUB_IP_CIDR}" dev "$dev" 2>/dev/null || true
}

release_peer_sub_ip() {
    local peer="$1"

    log "상대 서버(${peer})의 SUB_IP(${SUB_IP}) 회수"

    local before
    before=$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${peer}" \
        "ip -o -4 addr show 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | grep -qx '${SUB_IP}' && echo HAS || echo NONE" \
        2>/dev/null)

    if [ "$before" == "NONE" ]; then
        log "상대 서버에 SUB_IP 가 없습니다 (이미 회수됨)"
        return 0
    fi

    if [ -z "$before" ]; then
        log "[WARN] 상대 서버 상태를 확인하지 못했습니다 (SSH 불가)."
        log "[WARN] 서버가 내려간 상태라면 IP 도 함께 사라졌을 가능성이 높습니다."
        read -r -p "그래도 이 서버에 SUB_IP 를 부여할까요? (yes 입력 시 진행): " VIP_FORCE
        [ "$VIP_FORCE" == "yes" ] && return 0
        return 1
    fi

    timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${peer}" \
        "dev=\$(ip -o -4 addr show | awk -v ip=${SUB_IP} '\$4 ~ \"^\"ip\"/\" {print \$2; exit}'); \
         [ -n \"\$dev\" ] && sudo -n ip addr del ${SUB_IP}/${SUB_IP_CIDR} dev \$dev" \
        >/dev/null 2>&1 || true

    sleep 2

    local after
    after=$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${peer}" \
        "ip -o -4 addr show 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | grep -qx '${SUB_IP}' && echo HAS || echo NONE" \
        2>/dev/null)

    if [ "$after" == "NONE" ]; then
        log "상대 서버 SUB_IP 회수 확인 완료"
        return 0
    fi

    log "[ERROR] 상대 서버에 SUB_IP 가 아직 남아 있습니다."
    log "[ERROR] ${SSH_USER} 계정의 sudo(NOPASSWD) 권한을 확인하세요:"
    log "        ssh ${SSH_USER}@${peer} 'sudo -n ip addr show'"
    return 1
}

detach_sub_ip_on_peer() {
    vip_enabled || return 0

    log "기존 Active(${DB_ACTIVE_IP})에서 보조 IP(${SUB_IP}) 회수를 시도합니다."

    timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${DB_ACTIVE_IP}" \
        "dev=\$(ip -o -4 addr show | awk -v ip=${SUB_IP} '\$4 ~ \"^\"ip\"/\" {print \$2; exit}'); \
         [ -n \"\$dev\" ] && sudo -n ip addr del ${SUB_IP}/${SUB_IP_CIDR} dev \$dev" \
        2>/dev/null || log "[WARN] 기존 Active에서 보조 IP를 회수하지 못했습니다 (이미 내려갔거나 권한 부족)."
}

apply_sub_ip_by_role() {
    vip_enabled || return 0

    if [ "$ROLE" == "ACTIVE" ]; then
        attach_sub_ip || true
    else
        if sub_ip_is_assigned; then
            log "[WARN] 이 서버는 STANDBY 인데 보조 IP(${SUB_IP})가 부여되어 있어 회수합니다."
            detach_sub_ip
        fi
    fi
}

detect_role() {
    CURRENT_IP=$(hostname -I | awk '{print $1}')

    if [ "$CURRENT_IP" == "$DB_ACTIVE_IP" ]; then
        ROLE="ACTIVE"
        SERVER_ID=1
        PEER_IP="$DB_STANDBY_IP"
    elif [ "$CURRENT_IP" == "$DB_STANDBY_IP" ]; then
        ROLE="STANDBY"
        SERVER_ID=2
        PEER_IP="$DB_ACTIVE_IP"
    else
        log "[ERROR] 현재 서버 IP($CURRENT_IP)가 DB_ACTIVE_IP/DB_STANDBY_IP와 일치하지 않습니다."
        exit 1
    fi

    log "현재 서버 역할: $ROLE (IP: $CURRENT_IP, server_id: $SERVER_ID)"
}

SUDOERS_FILE="/etc/sudoers.d/mariadb-duple-${SSH_USER}"

ensure_local_sudo_privilege() {
    if [ "$SSH_USER" == "root" ]; then
        return 0
    fi

    if ! id "$SSH_USER" >/dev/null 2>&1; then
        log "[WARN] SSH_USER 계정이 존재하지 않습니다: ${SSH_USER}"
        cat <<EOF

=====================================================
 이 스크립트는 상대 서버 접속에 ${SSH_USER} 계정을 사용합니다.
 계정이 없어 지금 생성할 수 있습니다.

   - 계정 생성 (useradd)
   - wheel 그룹 추가
   - 비밀번호 설정
   - 홈 디렉토리 및 .ssh 준비

 비밀번호는 SSH 키교환(ssh-copy-id) 을 할 때 한 번 필요합니다.
 양쪽 서버에 같은 값으로 설정해두면 편합니다.
 키교환이 끝난 뒤에는 키 인증만 사용합니다.
=====================================================

EOF
        read -r -p "${SSH_USER} 계정을 생성할까요? (y/n): " CREATE_ANSWER
        if [[ "$CREATE_ANSWER" != "y" && "$CREATE_ANSWER" != "Y" ]]; then
            log "[ERROR] ${SSH_USER} 계정 없이는 진행할 수 없습니다."
            log "[ERROR] 계정을 만든 뒤 다시 실행하세요: useradd -m -G wheel ${SSH_USER}"
            exit 1
        fi

        if ! useradd -m -G wheel "$SSH_USER" 2>/dev/null; then
            log "[ERROR] ${SSH_USER} 계정 생성에 실패했습니다."
            exit 1
        fi

        local new_pw new_pw_confirm
        while true; do
            read -r -s -p "${SSH_USER} 계정 비밀번호 입력: " new_pw
            echo >&2
            read -r -s -p "비밀번호 확인 (다시 입력): " new_pw_confirm
            echo >&2

            if [ -z "$new_pw" ]; then
                log "[WARN] 비밀번호는 비워둘 수 없습니다. 상대 서버와 키교환할 때 필요합니다."
                continue
            fi
            if [ "$new_pw" != "$new_pw_confirm" ]; then
                log "[WARN] 입력하신 두 값이 서로 다릅니다. 다시 입력해주세요."
                continue
            fi
            break
        done

        if echo "${SSH_USER}:${new_pw}" | chpasswd 2>/dev/null; then
            log "${SSH_USER} 계정 비밀번호 설정 완료"
        else
            log "[ERROR] 비밀번호 설정에 실패했습니다."
            exit 1
        fi

        local home_dir
        home_dir="$(getent passwd "$SSH_USER" | cut -d: -f6)"
        if [ -n "$home_dir" ]; then
            mkdir -p "${home_dir}/.ssh"
            touch "${home_dir}/.ssh/authorized_keys"
            chmod 700 "${home_dir}/.ssh"
            chmod 600 "${home_dir}/.ssh/authorized_keys"
            chown -R "${SSH_USER}:${SSH_USER}" "${home_dir}/.ssh"
        fi

        log "${SSH_USER} 계정 생성 완료 (wheel 그룹 포함, 홈: ${home_dir})"
        log "[WARN] 상대 서버에도 동일한 계정이 있어야 합니다."
    else
        if ! id -nG "$SSH_USER" 2>/dev/null | tr ' ' '\n' | grep -qx wheel; then
            log "[WARN] ${SSH_USER} 계정이 wheel 그룹에 없습니다."
            read -r -p "wheel 그룹에 추가할까요? (y/n): " WHEEL_ANSWER
            if [[ "$WHEEL_ANSWER" == "y" || "$WHEEL_ANSWER" == "Y" ]]; then
                usermod -aG wheel "$SSH_USER" && \
                    log "${SSH_USER} 를 wheel 그룹에 추가했습니다."
            fi
        fi
    fi

    if sudo -n -u "$SSH_USER" sudo -n true 2>/dev/null; then
        log "${SSH_USER} 계정의 sudo(NOPASSWD) 권한 확인 완료"
        return 0
    fi

    if [ -f "$SUDOERS_FILE" ]; then
        log "${SSH_USER} sudo 설정 파일이 이미 존재합니다: ${SUDOERS_FILE}"
        return 0
    fi

    log "[WARN] ${SSH_USER} 계정에 비밀번호 없는 sudo 권한이 없습니다."
    cat <<EOF

=====================================================
 이 스크립트는 상대 서버에 ${SSH_USER} 계정으로 접속해
 아래 작업을 수행합니다. 모두 root 권한이 필요합니다.

   - MariaDB 정지 (승격 시 기존 Active 차단)
   - 보조 IP(SUB_IP) 부여 및 회수
   - 백업 디렉토리 권한 조정

 권한이 없으면 해당 단계에서 실패합니다.
 아래 파일을 생성해 필요한 명령만 허용할 수 있습니다.

   ${SUDOERS_FILE}
=====================================================

EOF

    read -r -p "지금 ${SSH_USER} 계정에 sudo 권한을 부여할까요? (y/n): " GRANT_ANSWER
    if [[ "$GRANT_ANSWER" != "y" && "$GRANT_ANSWER" != "Y" ]]; then
        log "[WARN] 권한 부여를 건너뜁니다. 원격 작업이 필요한 단계에서 실패할 수 있습니다."
        return 0
    fi

    local ip_bin systemctl_bin pkill_bin
    ip_bin="$(command -v ip 2>/dev/null || echo /usr/sbin/ip)"
    systemctl_bin="$(command -v systemctl 2>/dev/null || echo /usr/bin/systemctl)"
    pkill_bin="$(command -v pkill 2>/dev/null || echo /usr/bin/pkill)"

    cat > "$SUDOERS_FILE" <<EOF
${SSH_USER} ALL=(ALL) NOPASSWD: ${ip_bin}
${SSH_USER} ALL=(ALL) NOPASSWD: ${systemctl_bin} stop ${DB_SERVICE_NAME}
${SSH_USER} ALL=(ALL) NOPASSWD: ${systemctl_bin} start ${DB_SERVICE_NAME}
${SSH_USER} ALL=(ALL) NOPASSWD: ${systemctl_bin} status ${DB_SERVICE_NAME}
${SSH_USER} ALL=(ALL) NOPASSWD: ${pkill_bin} -f mysqld
${SSH_USER} ALL=(ALL) NOPASSWD: /usr/bin/mkdir, /bin/mkdir
${SSH_USER} ALL=(ALL) NOPASSWD: /usr/bin/chown, /bin/chown
EOF
    chmod 440 "$SUDOERS_FILE"

    if visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
        log "${SSH_USER} sudo 권한 부여 완료: ${SUDOERS_FILE}"
    else
        log "[ERROR] sudoers 문법 검증에 실패하여 파일을 삭제합니다."
        rm -f "$SUDOERS_FILE"
        exit 1
    fi

    log "[WARN] 상대 서버에서도 동일하게 설정해야 합니다 (해당 서버에서 이 스크립트 실행)."
}

check_ssh_exchange() {
    local my_ip
    my_ip="$(hostname -I | awk '{print $1}')"

    log "SSH 키교환 상태 확인 중: (${my_ip}) -> ${SSH_USER}@${PEER_IP}"

    if timeout 15 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${PEER_IP}" "exit" 2>/dev/null; then
        log "SSH 키교환 확인 완료 (비밀번호 없이 접속 가능)"
        check_remote_backup_dir_writable
        return
    fi

    log "[WARN] SSH 키교환이 되어 있지 않습니다."

    read -r -p "지금 자동으로 SSH 키교환을 시도할까요? (ssh-keygen/ssh-copy-id 진행, 원격 비밀번호 입력 필요) (y/n): " DO_SSH_EXCHANGE
    if [[ "$DO_SSH_EXCHANGE" != "y" && "$DO_SSH_EXCHANGE" != "Y" ]]; then
        print_ssh_exchange_guide "$my_ip"
        exit 1
    fi

    if [ ! -f "$SSH_KEY" ]; then
        log "로컬(${my_ip})에 SSH 키가 없어 새로 생성합니다: ${SSH_KEY}"
        mkdir -p "$(dirname "$SSH_KEY")"
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -q || true
    fi

    log "상대 서버(${PEER_IP})로 공개키 등록 시도 (비밀번호 입력 필요할 수 있습니다)"
    ssh-copy-id -i "${SSH_KEY}.pub" -p "$SSH_PORT" -o StrictHostKeyChecking=no "${SSH_USER}@${PEER_IP}" || true

    log "키교환 재검증 중"
    if timeout 15 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${PEER_IP}" "exit" 2>/dev/null; then
        log "SSH 키교환 자동 처리 완료"
        check_remote_backup_dir_writable
    else
        log "[ERROR] 자동 키교환에 실패했습니다."
        print_ssh_exchange_guide "$my_ip"
        exit 1
    fi
}

print_ssh_exchange_guide() {
    local my_ip="$1"
    cat <<EOF

=====================================================
 SSH 키교환이 필요합니다. 현재 서버(${my_ip})에서 아래 순서대로 진행하세요.

 1) 로컬(${my_ip})에 키가 없다면 생성:
    ssh-keygen -t rsa -b 4096 -f ${SSH_KEY}

 2) 상대 서버(${PEER_IP})로 공개키 등록:
    ssh-copy-id -i ${SSH_KEY}.pub -p ${SSH_PORT} ${SSH_USER}@${PEER_IP}

 3) 접속 테스트:
    ssh -i ${SSH_KEY} -p ${SSH_PORT} ${SSH_USER}@${PEER_IP}

 * 참고: 반대편(${PEER_IP})에서도 이 서버(${my_ip})로의 키교환이
   필요하다면, 해당 서버에서 아래 명령을 실행해야 합니다.
    ssh-copy-id -i ${SSH_KEY}.pub -p ${SSH_PORT} ${SSH_USER}@${my_ip}

 위 과정 완료 후 스크립트를 다시 실행하세요.
=====================================================

EOF
}

check_remote_backup_dir_writable() {
    log "상대 서버(${PEER_IP})의 BACKUP_DIR(${BACKUP_DIR}) 권한 확인 중"

    local remote_check
    remote_check=$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${PEER_IP}" "
            mkdir -p '${BACKUP_DIR}' 2>/dev/null
            if [ -w '${BACKUP_DIR}' ]; then
                touch '${BACKUP_DIR}/.write_test' 2>/dev/null && rm -f '${BACKUP_DIR}/.write_test' 2>/dev/null && echo OK
            fi
        " 2>/dev/null)

    if [ "$remote_check" == "OK" ]; then
        log "상대 서버 BACKUP_DIR 쓰기 권한 확인 완료 (${SSH_USER} 계정)"
        return
    fi

    log "[WARN] ${SSH_USER} 계정으로 ${BACKUP_DIR} 쓰기 불가. sudo로 자동 수정 시도"

    timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${PEER_IP}" \
        "sudo -n mkdir -p '${BACKUP_DIR}' && sudo -n chown -R ${SSH_USER}:${SSH_USER} '${BACKUP_DIR}'" \
        2>/dev/null || true

    remote_check=$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${PEER_IP}" "
            if [ -w '${BACKUP_DIR}' ]; then
                touch '${BACKUP_DIR}/.write_test' 2>/dev/null && rm -f '${BACKUP_DIR}/.write_test' 2>/dev/null && echo OK
            fi
        " 2>/dev/null)

    if [ "$remote_check" == "OK" ]; then
        log "sudo를 통해 ${BACKUP_DIR} 소유권을 ${SSH_USER}로 자동 변경 완료"
    else
        log "[ERROR] 상대 서버(${PEER_IP})의 ${BACKUP_DIR} 에 ${SSH_USER} 계정으로 쓰기가 안 됩니다."
        log "[ERROR] sudo 자동 수정도 실패했습니다 (NOPASSWD sudo 미설정이거나 권한 부족)."
        cat <<EOF

=====================================================
 상대 서버(${PEER_IP})에서 아래 명령으로 디렉토리 권한을 맞춰주세요.

 (${PEER_IP} 서버에 접속하여 실행)
    sudo mkdir -p ${BACKUP_DIR}
    sudo chown -R ${SSH_USER}:${SSH_USER} ${BACKUP_DIR}

 완료 후 스크립트를 다시 실행하세요.
=====================================================

EOF
        exit 1
    fi
}

resolve_mycnf_path() {
    MYCNF_PATH="/etc/my.cnf"

    if [ ! -f "$MYCNF_PATH" ]; then
        log "[ERROR] my.cnf 파일을 찾을 수 없습니다: ${MYCNF_PATH}"
        exit 1
    fi
}

force_mycnf_kv() {
    local key="$1"
    local value="$2"
    local pattern="^[[:space:]]*${key}[[:space:]]*="

    if grep -qE "$pattern" "$MYCNF_PATH"; then
        local current
        current="$(grep -m1 -E "$pattern" "$MYCNF_PATH" | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]')"
        if [ "$current" == "$value" ]; then
            log "  [OK]  ${key} = ${value}"
            return 0
        fi
        sed -i "s#^[[:space:]]*${key}[[:space:]]*=.*#${key} = ${value}#" "$MYCNF_PATH"
        log "  [SET] ${key} : ${current} -> ${value}"
    else
        echo "${key} = ${value}" >> "$MYCNF_PATH"
        log "  [ADD] ${key} = ${value}"
    fi
    CONFIG_CHANGED=1
}

ensure_mycnf_kv() {
    local key="$1"
    local value="$2"
    local line pattern

    if [ -z "$value" ]; then
        pattern="^[[:space:]]*${key}[[:space:]]*(#.*)?$"
        line="${key}"
    else
        pattern="^[[:space:]]*${key}[[:space:]]*="
        line="${key} = ${value}"
    fi

    if grep -qE "$pattern" "$MYCNF_PATH"; then
        log "  [OK]  ${key} - 이미 설정되어 있음"
    else
        echo "$line" >> "$MYCNF_PATH"
        log "  [ADD] ${key} -> ${line}"
        CONFIG_CHANGED=1
    fi
}

verify_and_update_mycnf() {
    resolve_mycnf_path
    log "my.cnf 설정 검증 시작 (${MYCNF_PATH})"

    log "my.cnf Replication/Binlog 설정 검증"
    ensure_mycnf_kv "server_id" "${SERVER_ID}"
    ensure_mycnf_kv "log_bin" "${DATADIR}/mysql-bin"
    ensure_mycnf_kv "binlog_format" "ROW"
    ensure_mycnf_kv "expire_logs_days" "${EXPIRE_LOGS_DAYS}"
    ensure_mycnf_kv "gtid_strict_mode" "1"
    ensure_mycnf_kv "log_slave_updates" "1"

    if [ "$ROLE" == "STANDBY" ]; then
        force_mycnf_kv "read_only" "1"
    fi

    log "my.cnf 검증 완료 (변경 여부: ${CONFIG_CHANGED})"
}

handle_restart_if_needed() {
    if [ "$CONFIG_CHANGED" -eq 0 ]; then
        log "my.cnf 변경 사항 없음. 재기동 불필요"
        return
    fi

    read -r -p "my.cnf 설정이 변경되었습니다. 지금 MariaDB를 재기동하시겠습니까? (y/n): " ANSWER
    case "$ANSWER" in
        y|Y)
            log "재기동을 진행합니다."
            ;;
        *)
            log "설정 변경 사항은 재기동 후에만 적용됩니다. 재기동을 선택하지 않아 스크립트를 종료합니다."
            exit 0
            ;;
    esac

    if systemctl list-unit-files 2>/dev/null | grep -qE "^${DB_SERVICE_NAME}\.service"; then
        log "systemd 서비스로 등록되어 있음 -> systemctl로 재기동"
        systemctl restart "$DB_SERVICE_NAME"
    else
        log "systemd 서비스로 등록되어 있지 않음 -> mysqld_safe로 백그라운드 재기동"
        if [ -x "${BASEDIR}/bin/mysqld_safe" ]; then
            pkill -u "${DB_owner}" -f mysqld || true
            sleep 2
            nohup "${BASEDIR}/bin/mysqld_safe" --datadir="${DATADIR}" --user="${DB_owner}" \
                > /dev/null 2>&1 &
            sleep 3
        else
            log "[ERROR] 재기동 방법을 찾을 수 없습니다. 수동으로 MariaDB를 재기동해주세요."
            exit 1
        fi
    fi

    sleep 3
    if ! pgrep -x mysqld >/dev/null 2>&1 && ! pgrep -x mariadbd >/dev/null 2>&1 && \
       ! systemctl is-active --quiet "$DB_SERVICE_NAME" 2>/dev/null; then
        log "[ERROR] MariaDB 재기동 확인 실패. 로그를 확인하세요: ${ERROR_LOG}"
        exit 1
    fi
    log "MariaDB 재기동 완료"
}

mysql_root() {
    "${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" -e "$1"
}

mysql_root_out() {
    "${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" -e "$1" 2>/dev/null
}

setup_active() {
    log "[ACTIVE] Replication 계정 생성/갱신"
    if mysql_root "
        CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PASSWORD}';
        GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
        FLUSH PRIVILEGES;
    "; then
        log "[ACTIVE] Replication 계정(${REPL_USER}) 생성/갱신 성공"
        update_config_enc "REPL_PASSWORD_ENC" "$REPL_PASSWORD"
    else
        log "[ERROR] Replication 계정 생성에 실패했습니다."
        exit 1
    fi

    local BACKUP_TS
    BACKUP_TS="$(date +%Y%m%d_%H%M%S)"
    local BACKUP_TARGET_DIR="${BACKUP_DIR}/${BACKUP_TS}"

    log "[ACTIVE] mariabackup 백업 시작 -> ${BACKUP_TARGET_DIR}"
    mkdir -p "${BACKUP_TARGET_DIR}"
    "${MARIABACKUP_BIN}" --backup \
        --target-dir="${BACKUP_TARGET_DIR}" \
        --user="${DB_ROOT_USER}" \
        --password="${DB_ROOT_PASSWORD}"

    local GTID_POS
    GTID_POS="$("${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" \
        -N -B -e "SELECT @@GLOBAL.gtid_binlog_pos;" 2>/dev/null)"

    if [ -n "$GTID_POS" ]; then
        echo "$GTID_POS" > "${BACKUP_TARGET_DIR}/gtid_info.txt"
        log "[ACTIVE] GTID 위치 확보: ${GTID_POS}"
    else
        log "[WARN] GTID 위치를 조회하지 못했습니다. Standby에서 gtid_slave_pos를 수동 확인해야 할 수 있습니다."
    fi

    echo "${BACKUP_TS}" > "${BACKUP_TARGET_DIR}/.backup_complete"

    log "[ACTIVE] 백업 완료 (${BACKUP_TARGET_DIR})"

    log "[ACTIVE] 백업 디렉토리 소유권을 ${SSH_USER}로 변경"
    chown -R "${SSH_USER}:${SSH_USER}" "${BACKUP_TARGET_DIR}"

    log "[ACTIVE] Standby(${PEER_IP})로 백업 자동 전송 시작"
    if rsync -avP -e "ssh -i ${SSH_KEY} -p ${SSH_PORT}" \
            "${BACKUP_TARGET_DIR}" "${SSH_USER}@${PEER_IP}:${BACKUP_DIR}/"; then
        log "[ACTIVE] Standby로 백업 전송 완료. Standby에서 스크립트를 실행하세요."
    else
        log "[WARN] 자동 rsync 전송에 실패했습니다. 아래 명령으로 수동 전송해주세요."
        log "        rsync -avP -e \"ssh -i ${SSH_KEY} -p ${SSH_PORT}\" ${BACKUP_TARGET_DIR} ${SSH_USER}@${PEER_IP}:${BACKUP_DIR}/"
    fi
}

find_latest_backup_dir() {
    local latest
    latest=$(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name 'rollback_*' 2>/dev/null | sort | tail -n 1)

    if [ -z "$latest" ]; then
        log "[ERROR] ${BACKUP_DIR} 하위에 백업 디렉토리가 없습니다."
        cat <<EOF

=====================================================
 이 서버(Standby)에 필요한 준비는 모두 끝났습니다.
 이제 Active 의 데이터를 받아와야 합니다.

   - SSH 계정 / 백업 디렉토리 준비 완료
   - 비밀번호 저장 완료
   - my.cnf 설정 완료

 다음 순서로 진행하세요.

 1) Active(${DB_ACTIVE_IP}) 에서 실행
      ./$(basename "$0")

    설치가 끝나면 백업이 이 서버로 자동 전송됩니다.

 2) 전송 확인 후 이 서버에서 다시 실행
      ./$(basename "$0")
=====================================================

EOF
        exit 1
    fi

    if [ ! -f "${latest}/.backup_complete" ]; then
        log "[ERROR] ${latest} 안에 .backup_complete 마커 파일이 없습니다."
        log "[ERROR] 백업이 완전히 전송되지 않았거나 아직 완료되지 않았을 수 있습니다."
        exit 1
    fi

    echo "$latest"
}

setup_standby() {
    local TARGET_DIR
    TARGET_DIR="$(find_latest_backup_dir)"
    log "[STANDBY] 사용할 백업 디렉토리: ${TARGET_DIR}"

    log "[STANDBY] 백업 prepare 진행"
    "${MARIABACKUP_BIN}" --prepare --target-dir="${TARGET_DIR}"

    log "[STANDBY] MariaDB 중지"
    if systemctl list-unit-files 2>/dev/null | grep -qE "^${DB_SERVICE_NAME}\.service"; then
        systemctl stop "$DB_SERVICE_NAME"
    else
        pkill -u "${DB_owner}" -f mysqld || true
        sleep 2
    fi

    log "[STANDBY] 기존 datadir 백업: ${DATADIR} -> ${DATADIR_OLD_BACKUP}"
    rm -rf "${DATADIR_OLD_BACKUP:?}"
    mv "${DATADIR}" "${DATADIR_OLD_BACKUP}"
    mkdir -p "${DATADIR}"

    log "[STANDBY] datadir 복원 (copy-back)"
    "${MARIABACKUP_BIN}" --copy-back \
        --target-dir="${TARGET_DIR}" \
        --datadir="${DATADIR}"

    chown -R "${DB_owner}:${DB_owner}" "${DATADIR}"

    log "[STANDBY] MariaDB 시작"
    if systemctl list-unit-files 2>/dev/null | grep -qE "^${DB_SERVICE_NAME}\.service"; then
        systemctl start "$DB_SERVICE_NAME"
    else
        nohup "${BASEDIR}/bin/mysqld_safe" --datadir="${DATADIR}" --user="${DB_owner}" \
            > /dev/null 2>&1 &
    fi
    sleep 3

    log "[STANDBY] 복원된 DB에서 config 비밀번호로 로그인 검증"
    if ! "${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
        log "[ERROR] 복원된 DB에 config의 DB ROOT 비밀번호로 로그인이 안 됩니다."
        log "[ERROR] Active의 config(00.mariadb_duple) 파일이 이 서버와 다른 것으로 보입니다."
        log "[ERROR] Active에서 최신 config 파일을 이 서버로 다시 복사한 뒤, 아래 명령으로 replication만 재설정하세요."
        log "        ${MYSQL_BIN} -u${DB_ROOT_USER} -p'<Active의 실제 root 비밀번호>' -e \"...\""
        exit 1
    fi
    log "[STANDBY] 로그인 검증 완료 (Active와 동일한 계정 정보로 복원됨)"

    if [ -f "${TARGET_DIR}/gtid_info.txt" ]; then
        local GTID_POS
        GTID_POS="$(cat "${TARGET_DIR}/gtid_info.txt")"
        if [ -n "$GTID_POS" ]; then
            log "[STANDBY] gtid_slave_pos 설정: ${GTID_POS}"
            mysql_root "SET GLOBAL gtid_slave_pos = '${GTID_POS}';"
        fi
    else
        log "[WARN] gtid_info.txt 파일이 없습니다. gtid_slave_pos가 자동 설정되지 않았을 수 있으니 replication 상태를 꼭 확인하세요."
    fi

    log "[STANDBY] Replication 설정 (GTID 기반)"
    mysql_root "
        STOP SLAVE;
        RESET SLAVE ALL;
        CHANGE MASTER TO
            MASTER_HOST='${DB_ACTIVE_IP}',
            MASTER_PORT=${DB_PORT},
            MASTER_USER='${REPL_USER}',
            MASTER_PASSWORD='${REPL_PASSWORD}',
            MASTER_USE_GTID=${GTID_MODE};
        START SLAVE;
    "

    sleep 2
    log "[STANDBY] Replication 상태 확인"
    local slave_out
    slave_out="$("${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" -e "SHOW SLAVE STATUS\G" 2>/dev/null)"
    echo "$slave_out" \
        | grep -E "Slave_IO_Running|Slave_SQL_Running|Last_IO_Error|Last_SQL_Error|Seconds_Behind_Master" \
        | while IFS= read -r l; do colorize_slave_status "$l"; done

    if ! diagnose_slave_error "$slave_out"; then
        log "[ERROR] Replication 구성은 되었으나 정상 동작하지 않습니다. 위 안내를 확인하세요."
        exit 1
    fi

    if [ -n "$ROLE_STATE" ] && [ "$ROLE_STATE" != "normal" ]; then
        log "[STANDBY] 이전 역할 상태(${ROLE_STATE})를 정리합니다."
        set_role_state "normal"
    fi

    log "[STANDBY] 구성 완료"
}

reset_enc_values() {
    log "[INIT] 기존 ENC 값을 초기화합니다: DB_ROOT_PASSWORD_ENC, REPL_PASSWORD_ENC"

    if grep -q "^DB_ROOT_PASSWORD_ENC=" "$CONFIG_FILE"; then
        sed -i 's#^DB_ROOT_PASSWORD_ENC=.*#DB_ROOT_PASSWORD_ENC=""#' "$CONFIG_FILE"
    else
        echo 'DB_ROOT_PASSWORD_ENC=""' >> "$CONFIG_FILE"
    fi

    if grep -q "^REPL_PASSWORD_ENC=" "$CONFIG_FILE"; then
        sed -i 's#^REPL_PASSWORD_ENC=.*#REPL_PASSWORD_ENC=""#' "$CONFIG_FILE"
    else
        echo 'REPL_PASSWORD_ENC=""' >> "$CONFIG_FILE"
    fi

    log "[INIT] 초기화 완료. 다음 실행 시 비밀번호를 새로 입력받습니다."
}

resolve_bin() {
    local cmd="$1"
    local hint="$2"

    if [ -x "${BASEDIR}/bin/${cmd}" ]; then
        echo "${BASEDIR}/bin/${cmd}"
        return 0
    fi

    if command -v "$cmd" >/dev/null 2>&1; then
        command -v "$cmd"
        return 0
    fi

    log "[ERROR] 필수 명령어를 찾을 수 없습니다: ${cmd} (확인 위치: ${BASEDIR}/bin, PATH)"
    [ -n "$hint" ] && log "        설치 방법: ${hint}"
    return 1
}

check_dependencies() {
    local missing=0

    MYSQL_BIN="$(resolve_bin "mysql" "yum install -y mariadb  (또는 apt-get install -y mariadb-client)")" || missing=1
    MARIABACKUP_BIN="$(resolve_bin "mariabackup" "yum install -y MariaDB-backup  (또는 apt-get install -y mariadb-backup)")" || missing=1

    require_cmd() {
        local cmd="$1"
        local hint="$2"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "[ERROR] 필수 명령어를 찾을 수 없습니다: ${cmd}"
            [ -n "$hint" ] && log "        설치 방법: ${hint}"
            missing=1
        fi
    }

    require_cmd "openssl" "yum install -y openssl  (또는 apt-get install -y openssl)"
    require_cmd "ssh"     "yum install -y openssh-clients  (또는 apt-get install -y openssh-client)"
    require_cmd "sed"     "yum install -y sed  (또는 apt-get install -y sed)"
    require_cmd "md5sum"  "yum install -y coreutils  (또는 apt-get install -y coreutils)"

    if [ "$missing" -eq 1 ]; then
        log "[ERROR] 위 명령어들을 설치하거나 BASEDIR(${BASEDIR}/bin) 경로를 확인한 후 다시 실행하세요."
        exit 1
    fi

    log "필수 명령어 확인 완료 (mysql=${MYSQL_BIN}, mariabackup=${MARIABACKUP_BIN})"
}

ensure_open_files_limit() {
    local current
    current="$(ulimit -n)"

    local ibd_count=0
    if [ -d "$DATADIR" ]; then
        ibd_count="$(find "$DATADIR" -name "*.ibd" 2>/dev/null | wc -l)"
    fi

    local required=$((ibd_count + 3000))
    [ "$required" -lt 65535 ] && required=65535

    log "파일 디스크립터 확인 (현재 ulimit -n=${current}, .ibd 파일=${ibd_count}개)"

    if [ "$current" != "unlimited" ] && [ "$current" -lt "$required" ]; then
        if ulimit -n "$required" 2>/dev/null; then
            log "파일 디스크립터 한도를 ${current} -> $(ulimit -n) 로 상향했습니다."
        else
            local hard
            hard="$(ulimit -Hn)"
            if [ "$hard" != "unlimited" ] && [ "$hard" -gt "$current" ]; then
                ulimit -n "$hard" 2>/dev/null && \
                    log "[WARN] 목표(${required})까지는 올리지 못하고 하드 리밋($(ulimit -n))까지만 상향했습니다."
            fi
        fi
    fi

    current="$(ulimit -n)"
    if [ "$current" != "unlimited" ] && [ "$current" -le "$ibd_count" ]; then
        log "[ERROR] 파일 디스크립터 한도(${current})가 .ibd 파일 수(${ibd_count})보다 작습니다."
        log "[ERROR] mariabackup 실행 중 'Too many open files' 오류가 발생합니다."
        cat <<EOF

=====================================================
 파일 디스크립터 한도를 올린 뒤 다시 실행하세요.

 1) 이번 세션에서만 적용
    ulimit -n 65535
    $0

 2) 영구 적용 (/etc/security/limits.conf 에 추가)
    * soft nofile 65535
    * hard nofile 65535

 3) MariaDB 서비스에도 적용
    mkdir -p /etc/systemd/system/${DB_SERVICE_NAME}.service.d
    echo -e "[Service]\\nLimitNOFILE=65535" > \\
      /etc/systemd/system/${DB_SERVICE_NAME}.service.d/limits.conf
    systemctl daemon-reload && systemctl restart ${DB_SERVICE_NAME}
=====================================================

EOF
        exit 1
    fi
}

is_mariadb_running() {
    if systemctl list-unit-files 2>/dev/null | grep -qE "^${DB_SERVICE_NAME}\.service"; then
        systemctl is-active --quiet "$DB_SERVICE_NAME"
    else
        pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1
    fi
}

ensure_mariadb_running() {
    if is_mariadb_running; then
        log "MariaDB 서비스 기동 확인 완료"
        return
    fi

    log "[WARN] MariaDB가 기동되어 있지 않습니다. 기동을 시도합니다."

    if systemctl list-unit-files 2>/dev/null | grep -qE "^${DB_SERVICE_NAME}\.service"; then
        systemctl start "$DB_SERVICE_NAME"
    elif [ -x "${BASEDIR}/bin/mysqld_safe" ]; then
        nohup "${BASEDIR}/bin/mysqld_safe" --datadir="${DATADIR}" --user="${DB_owner}" \
            > /dev/null 2>&1 &
    else
        log "[ERROR] MariaDB 기동 방법을 찾을 수 없습니다 (systemd 미등록, mysqld_safe 없음)."
        exit 1
    fi

    sleep 5

    if is_mariadb_running; then
        log "MariaDB 기동 완료"
    else
        log "[ERROR] MariaDB 기동에 실패했습니다. 에러 로그를 확인하세요: ${ERROR_LOG}"
        exit 1
    fi
}

colorize_slave_status() {
    local output="$1"
    local line

    while IFS= read -r line; do
        case "$line" in
            *Slave_IO_Running:*|*Slave_SQL_Running:*)
                if [[ "$line" == *": Yes"* ]]; then
                    echo -e "${COLOR_GREEN}${line}${COLOR_RESET}"
                else
                    echo -e "${COLOR_RED}${line}${COLOR_RESET}"
                fi
                ;;
            *Seconds_Behind_Master:*)
                if [[ "$line" == *": NULL"* ]]; then
                    echo -e "${COLOR_RED}${line}${COLOR_RESET}"
                else
                    echo -e "${COLOR_GREEN}${line}${COLOR_RESET}"
                fi
                ;;
            *Last_IO_Error:*|*Last_SQL_Error:*)
                if [[ "$line" =~ Error:[[:space:]]*$ ]]; then
                    echo "$line"
                else
                    echo -e "${COLOR_RED}${line}${COLOR_RESET}"
                fi
                ;;
            *Slave_SQL_Running_State:*)
                if [[ "$line" == *rror* ]]; then
                    echo -e "${COLOR_RED}${line}${COLOR_RESET}"
                else
                    echo "$line"
                fi
                ;;
            *)
                echo "$line"
                ;;
        esac
    done <<< "$output"
}

diagnose_slave_error() {
    local output="$1"
    local io_running sql_running io_error sql_error
    local has_problem=0

    io_running=$(echo "$output"  | grep -m1 "Slave_IO_Running:"  | sed 's/.*Slave_IO_Running:[[:space:]]*//')
    sql_running=$(echo "$output" | grep -m1 "Slave_SQL_Running:" | sed 's/.*Slave_SQL_Running:[[:space:]]*//')
    io_error=$(echo "$output"    | grep -m1 "Last_IO_Error:"     | sed 's/.*Last_IO_Error:[[:space:]]*//')
    sql_error=$(echo "$output"   | grep -m1 "Last_SQL_Error:"    | sed 's/.*Last_SQL_Error:[[:space:]]*//')

    [ "$io_running" != "Yes" ]  && has_problem=1
    [ "$sql_running" != "Yes" ] && has_problem=1
    [ -n "$io_error" ]  && has_problem=1
    [ -n "$sql_error" ] && has_problem=1

    if [ "$has_problem" -eq 0 ]; then
        echo ""
        echo -e "${COLOR_GREEN}Replication 정상 동작 중입니다.${COLOR_RESET}"
        return 0
    fi

    echo ""
    echo -e "${COLOR_RED}=====================================================${COLOR_RESET}"
    echo -e "${COLOR_RED} Replication 이상이 감지되었습니다. 확인이 필요합니다.${COLOR_RESET}"
    echo -e "${COLOR_RED}=====================================================${COLOR_RESET}"

    if [ -n "$io_error" ]; then
        echo ""
        echo -e "${COLOR_RED}[IO 오류]${COLOR_RESET} ${io_error}"

        case "$io_error" in
            *"No route to host"*|*"Can't connect"*|*"Connection refused"*|*"timed out"*)
                cat <<EOF

 원인: Standby에서 Active(${DB_ACTIVE_IP}:${DB_PORT}) 로 접속하지 못하고 있습니다.
       Active 서버가 내려갔거나, 방화벽에 막혀 있을 가능성이 큽니다.

 확인 순서:
   1) Active 서버 기동 여부
      ping ${DB_ACTIVE_IP}

   2) DB 포트 연결 확인 (Standby 에서 실행)
      timeout 3 bash -c "echo > /dev/tcp/${DB_ACTIVE_IP}/${DB_PORT}" && echo OPEN || echo CLOSED

   3) Active 방화벽에 DB 포트 허용 여부
      firewall-cmd --list-ports
      firewall-cmd --permanent --add-port=${DB_PORT}/tcp && firewall-cmd --reload

   4) Active의 MariaDB 기동 여부
      systemctl status ${DB_SERVICE_NAME}
EOF
                ;;
            *"Access denied"*)
                cat <<EOF

 원인: replication 계정(${REPL_USER}) 인증에 실패했습니다.
       Active와 Standby가 알고 있는 비밀번호가 다를 수 있습니다.

 확인 순서:
   1) Active에서 계정/권한 확인
      SELECT user, host FROM mysql.user WHERE user='${REPL_USER}';
      SHOW GRANTS FOR '${REPL_USER}'@'%';

   2) 비밀번호를 재설정하고 양쪽을 맞춘 뒤 재연결
      ./$(basename "$0") init      (저장된 비밀번호 초기화 후 재실행)
EOF
                ;;
            *"Could not find first log file"*|*"binary log is not open"*|*"Binary log is not open"*)
                cat <<EOF

 원인: Active의 binlog를 찾을 수 없습니다.
       binlog가 비활성화됐거나, 필요한 로그가 이미 삭제(expire)되었을 수 있습니다.

 확인 순서:
   1) Active에서 binlog 활성 여부
      SHOW VARIABLES LIKE 'log_bin';
      SHOW MASTER STATUS;

   2) 로그가 삭제된 경우라면 백업부터 다시 받아 재구성해야 합니다.
      (Active에서 실행 후 Standby에서 실행)
      ./$(basename "$0")
EOF
                ;;
            *)
                echo ""
                echo " 위 오류 메시지를 확인하고 Active 서버 상태를 점검하세요."
                ;;
        esac
    fi

    if [ -n "$sql_error" ]; then
        echo ""
        echo -e "${COLOR_RED}[SQL 오류]${COLOR_RESET} ${sql_error}"
        cat <<EOF

 원인: 받아온 트랜잭션을 Standby에 적용하는 중 실패했습니다.
       데이터 불일치나 스키마 차이일 가능성이 큽니다.

 확인 순서:
   1) 오류가 난 대상 확인 후 수동 조치
   2) 조치 후 재시작
      STOP SLAVE; START SLAVE;
EOF
    fi

    if [ -z "$io_error" ] && [ -z "$sql_error" ]; then
        echo ""
        echo " IO/SQL 스레드가 정지 상태입니다. START SLAVE; 로 재시작해 보세요."
    fi

    echo ""
    return 1
}

detect_effective_role() {
    local slave_out read_only
    slave_out="$(mysql_root_out "SHOW SLAVE STATUS\G")"
    read_only="$(mysql_root_out "SELECT @@GLOBAL.read_only;" | tail -1)"

    EFFECTIVE_READONLY="$read_only"

    if [ -n "$slave_out" ]; then
        EFFECTIVE_ROLE="STANDBY"
    elif [ "$read_only" == "1" ]; then
        EFFECTIVE_ROLE="ORPHANED"
    else
        EFFECTIVE_ROLE="ACTIVE"
    fi
}

print_role_banner() {
    local config_role="$1"

    echo -e "${COLOR_BLUE}=== 서버 상태 (${CURRENT_IP}) ===${COLOR_RESET}"
    echo -e "  config 기준 역할 : ${config_role}"
    echo -e "  실제 동작 역할   : ${EFFECTIVE_ROLE}"

    local ro_txt="쓰기 가능"
    local ro_color="$COLOR_GREEN"
    if [ "$EFFECTIVE_READONLY" == "1" ]; then
        ro_txt="읽기 전용"
        ro_color="$COLOR_YELLOW"
    fi
    echo -e "  쓰기 상태        : ${ro_color}${ro_txt}${COLOR_RESET}"

    case "$ROLE_STATE" in
        active-temporary)
            echo -e "  ${COLOR_YELLOW}상태: 장애로 임시 승격된 서버입니다 (승격 시각: ${PROMOTED_AT})${COLOR_RESET}"
            echo -e "  ${COLOR_YELLOW}      원래 구성으로 되돌리려면 ${DB_ACTIVE_IP} 에서 rollback-prepare 를 실행하세요.${COLOR_RESET}"
            ;;
        rollback-syncing)
            echo -e "  ${COLOR_YELLOW}상태: 원복 진행 중 - 데이터를 따라잡는 중입니다.${COLOR_RESET}"
            echo -e "  ${COLOR_YELLOW}      지연이 0 이 되면 rollback-switch 를 실행하세요.${COLOR_RESET}"
            ;;
    esac

    if [ "$EFFECTIVE_ROLE" == "ORPHANED" ]; then
        echo -e "  ${COLOR_RED}상태: Active 도 Standby 도 아닌 상태입니다.${COLOR_RESET}"
        echo -e "  ${COLOR_RED}      replication 설정이 없고 쓰기도 막혀 있습니다.${COLOR_RESET}"
        echo -e "  ${COLOR_RED}      Standby 로 편입하려면 이 서버에서 실행: $0${COLOR_RESET}"
    elif [ "$config_role" != "$EFFECTIVE_ROLE" ]; then
        echo -e "  ${COLOR_YELLOW}참고: config 의 IP 설정과 실제 역할이 다릅니다 (승격 이력 있음).${COLOR_RESET}"
    fi

    if [ "$EFFECTIVE_ROLE" == "STANDBY" ] && [ "$EFFECTIVE_READONLY" != "1" ]; then
        echo -e "  ${COLOR_RED}경고: Standby 인데 쓰기가 열려 있습니다. my.cnf 의 read_only 를 확인하세요.${COLOR_RESET}"
    fi
    echo ""
}

run_status_check() {
    load_config
    check_dependencies
    ensure_mariadb_running
    DB_ROOT_PASSWORD="$(resolve_root_password "${DB_ROOT_PASSWORD_ENC}")"
    detect_role
    detect_effective_role
    print_role_banner "$ROLE"

    if [ "$EFFECTIVE_ROLE" == "ACTIVE" ]; then
        echo -e "${COLOR_BLUE}=== ACTIVE Replication 상태 ===${COLOR_RESET}"
        "${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" -e "SHOW MASTER STATUS\G" 2>/dev/null \
            | grep -E "File|Position"
    else
        echo -e "${COLOR_BLUE}=== STANDBY(SLAVE) Replication 상태 ===${COLOR_RESET}"
        local output
        output="$("${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" -e "SHOW SLAVE STATUS\G" 2>/dev/null)"
        if [ -z "$output" ]; then
            echo -e "${COLOR_RED}SHOW SLAVE STATUS 결과가 없습니다. Replication이 설정되지 않았을 수 있습니다.${COLOR_RESET}"
            exit 1
        fi

        colorize_slave_status "$(echo "$output" \
            | grep -E "Slave_IO_Running|Slave_SQL_Running|Last_IO_Error|Last_SQL_Error|Seconds_Behind_Master")"
        diagnose_slave_error "$output" || exit 1
    fi
}

auto_start_monitor_if_enabled() {
    [ "$AUTO_START_MONITOR" == "yes" ] || return 0

    if [ "$ROLE" == "ACTIVE" ] && ! vip_enabled; then
        log "Active 는 VIP_MODE=no 이면 자가 감시할 대상이 없어 모니터링을 기동하지 않습니다."
        return 0
    fi

    if service_is_active; then
        log "모니터링이 systemd 서비스로 이미 실행 중입니다 (${SERVICE_NAME})"
        return 0
    fi

    if monitor_is_running; then
        log "모니터링이 이미 실행 중입니다 (PID $(cat "$PID_FILE"))"
        return 0
    fi

    log "설치 완료 - 모니터링을 systemd 서비스로 등록하고 기동합니다 (AUTO_START_MONITOR=yes)"

    if ! command -v systemctl >/dev/null 2>&1; then
        log "[WARN] systemctl 을 사용할 수 없어 백그라운드로 기동합니다 (재부팅 시 자동 시작 안 됨)."
        ( monitor_start ) || true
        sleep 1
        if monitor_is_running; then
            log "모니터링 백그라운드 기동 완료 (PID $(cat "$PID_FILE"))"
        else
            log "[WARN] 모니터링 기동에 실패했습니다. 수동으로 실행하세요: $0 monitor-start"
        fi
        return 0
    fi

    ( service_install ) || {
        log "[WARN] 서비스 등록에 실패했습니다. 수동으로 실행하세요: $0 service-install"
        return 0
    }

    if systemctl start "${SERVICE_NAME}.service" 2>/dev/null; then
        sleep 2
        if service_is_active; then
            log "모니터링 서비스 기동 완료 (${SERVICE_NAME})"
            log "재부팅 후에도 자동으로 시작됩니다."
        else
            log "[WARN] 서비스가 기동되지 않았습니다. 확인: systemctl status ${SERVICE_NAME}"
        fi
    else
        log "[WARN] 서비스 기동에 실패했습니다. 확인: systemctl status ${SERVICE_NAME}"
    fi
}

main() {
    load_config
    ensure_local_sudo_privilege
    validate_paths
    check_dependencies
    ensure_open_files_limit
    ensure_mariadb_running
    detect_role

    if [ "$ROLE" == "ACTIVE" ]; then
        resolve_active_passwords
    else
        resolve_standby_passwords
    fi

    check_ssh_exchange

    verify_and_update_mycnf
    handle_restart_if_needed

    if [ "$ROLE" == "ACTIVE" ]; then
        setup_active
    else
        setup_standby
    fi

    apply_sub_ip_by_role
    auto_start_monitor_if_enabled

    log "=========================================="
    log " ${ROLE} 서버 설치/구성 스크립트 완료"
    log "=========================================="
}

PID_FILE="${SCRIPT_DIR}/logs/monitor.pid"
MONITOR_LOG="${LOG_DIR}/monitor.log"

verify_monitor_role() {
    CURRENT_IP=$(hostname -I | awk '{print $1}')

    if [ "$CURRENT_IP" == "$DB_ACTIVE_IP" ]; then
        MONITOR_ROLE="ACTIVE"
    elif [ "$CURRENT_IP" == "$DB_STANDBY_IP" ]; then
        MONITOR_ROLE="STANDBY"
    else
        log "[ERROR] 현재 서버 IP(${CURRENT_IP})가 config의 Active/Standby IP와 일치하지 않습니다."
        exit 1
    fi

    if [ "$MONITOR_ROLE" == "ACTIVE" ] && ! vip_enabled; then
        log "[ERROR] 이 서버는 Active 이며, VIP_MODE 가 꺼져 있어 감시할 대상이 없습니다."
        log "[ERROR] Active 자가 감시는 VIP_MODE=yes 일 때만 의미가 있습니다 (SUB_IP 자가 회수)."
        exit 1
    fi
}

check_local_db_alive() {
    if systemctl list-unit-files 2>/dev/null | grep -qE "^${DB_SERVICE_NAME}\.service"; then
        systemctl is-active --quiet "$DB_SERVICE_NAME" || return 1
    else
        pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1 || return 1
    fi

    timeout "$HEALTH_TIMEOUT" "${MYSQL_BIN}" \
        -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" \
        -N -B -e "SELECT 1;" >/dev/null 2>&1
}

peer_is_active() {
    local peer="$1"
    local slave_out read_only

    slave_out=$(timeout "$HEALTH_TIMEOUT" "${MYSQL_BIN}" \
        -h"${peer}" -P"${DB_PORT}" \
        -u"${REPL_USER}" -p"${REPL_PASSWORD}" \
        --ssl-verify-server-cert=0 \
        -N -B -e "SELECT 1;" 2>/dev/null)

    if [ -z "$slave_out" ]; then
        slave_out=$(timeout "$HEALTH_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout=3 \
            -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${peer}" \
            "ip -o -4 addr show 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | grep -qx '${SUB_IP}' && echo VIP_HELD || echo NO_VIP" \
            2>/dev/null)

        if [ "$slave_out" == "VIP_HELD" ]; then
            PEER_STATE="ACTIVE"
            return 0
        fi
        PEER_STATE="UNKNOWN"
        return 1
    fi

    read_only=$(timeout "$HEALTH_TIMEOUT" "${MYSQL_BIN}" \
        -h"${peer}" -P"${DB_PORT}" \
        -u"${REPL_USER}" -p"${REPL_PASSWORD}" \
        --ssl-verify-server-cert=0 \
        -N -B -e "SELECT @@GLOBAL.read_only;" 2>/dev/null | tail -1)

    if [ "$read_only" == "0" ]; then
        PEER_STATE="ACTIVE"
        return 0
    fi

    PEER_STATE="STANDBY"
    return 1
}

active_startup_vip_check() {
    log "시작 전 상대 서버(${DB_STANDBY_IP}) 상태 확인"

    if peer_is_active "$DB_STANDBY_IP"; then
        log "[ERROR] 상대 서버(${DB_STANDBY_IP})가 현재 Active 로 동작 중입니다."
        cat <<EOF

=====================================================
 이 서버는 config 상 Active 이지만, 그동안 장애로
 ${DB_STANDBY_IP} 가 승격되어 서비스 중입니다.

 지금 SUB_IP 를 부여하면 IP 가 중복되어 네트워크가
 꼬이므로 부여하지 않고 감시를 종료합니다.

 원래 구성으로 되돌리려면 아래 순서로 진행하세요.

   1) ${DB_STANDBY_IP} 에서
        $0 rollback-send

   2) 이 서버에서
        $0 rollback-prepare
        $0 status            (지연 0 확인)
        $0 rollback-switch
=====================================================

EOF
        return 1
    fi

    if [ "$PEER_STATE" == "UNKNOWN" ]; then
        log "[WARN] 상대 서버 상태를 확인하지 못했습니다 (DB/SSH 모두 응답 없음)."
        log "[WARN] 상대가 내려가 있을 가능성이 높지만, 확실하지 않아 네트워크를 한번 더 확인합니다."
    else
        log "상대 서버는 Standby 입니다. 이 서버가 Active 로 동작합니다."
    fi

    if ! check_sub_ip_conflict; then
        log "[ERROR] SUB_IP(${SUB_IP})가 네트워크에서 응답하고 있어 부여하지 않습니다."
        log "[ERROR] 누가 이 IP 를 쓰고 있는지 확인한 뒤 감시를 다시 시작하세요."
        return 1
    fi

    return 0
}

run_active_monitor_loop() {
    local fail_count=0
    set +e

    log "Active 자가 감시 시작 (주기 ${HEALTH_INTERVAL}초, 연속 ${HEALTH_FAIL_THRESHOLD}회 실패 시 SUB_IP 회수)"
    log "대상 SUB_IP: ${SUB_IP}/${SUB_IP_CIDR}"

    if ! active_startup_vip_check; then
        log "Active 자가 감시를 시작하지 않고 종료합니다."
        rm -f "$PID_FILE"
        exit 0
    fi

    attach_sub_ip || log "[WARN] 시작 시점 SUB_IP 부여에 실패했습니다."

    while true; do
        if check_local_db_alive; then
            if [ "$fail_count" -gt 0 ]; then
                log "로컬 MariaDB 정상 복구됨 (직전 연속 실패 ${fail_count}회 초기화)"
                fail_count=0
            fi

            if ! sub_ip_is_assigned; then
                log "[WARN] DB 는 정상인데 SUB_IP 가 내려가 있습니다. 재부여 전 상태를 확인합니다."
                if peer_is_active "$DB_STANDBY_IP"; then
                    log "[ERROR] 상대 서버가 Active 로 동작 중이라 SUB_IP 를 부여하지 않습니다."
                    log "[ERROR] 원복 절차(rollback-send/prepare/switch)가 필요합니다. 감시를 종료합니다."
                    rm -f "$PID_FILE"
                    exit 0
                fi
                if check_sub_ip_conflict; then
                    attach_sub_ip || true
                else
                    log "[ERROR] SUB_IP 가 네트워크에서 사용 중이라 부여하지 않습니다."
                fi
            fi
        else
            fail_count=$((fail_count + 1))
            log "[WARN] 로컬 MariaDB 이상 감지 - 연속 ${fail_count}/${HEALTH_FAIL_THRESHOLD}회"

            if [ "$fail_count" -ge "$HEALTH_FAIL_THRESHOLD" ]; then
                log "[ERROR] 연속 ${fail_count}회 실패 - 로컬 MariaDB 장애로 판정합니다."

                if sub_ip_is_assigned; then
                    log "[ERROR] SUB_IP(${SUB_IP})를 회수합니다 (Standby 승격 시 IP 충돌 방지)."
                    detach_sub_ip
                    log "SUB_IP 회수 완료."
                else
                    log "SUB_IP 가 이미 내려가 있어 회수할 것이 없습니다."
                fi

                cat <<EOF

=====================================================
 Active 자가 감시를 종료합니다.

 이 서버의 MariaDB 가 정상화되지 않아 더 이상 감시할
 의미가 없습니다. 로그가 계속 쌓이는 것을 막기 위해
 서비스를 종료합니다.

 조치 후 아래로 다시 시작하세요.

   1) MariaDB 상태 확인
        systemctl status ${DB_SERVICE_NAME}
        tail -50 ${ERROR_LOG}

   2) 정상화 후 감시 재시작
        systemctl start ${SERVICE_NAME}
=====================================================

EOF
                log "Active 자가 감시 종료"
                rm -f "$PID_FILE"
                exit 0
            fi
        fi

        sleep "$HEALTH_INTERVAL"
    done
}

check_active_port() {
    timeout "$HEALTH_TIMEOUT" bash -c \
        "echo > /dev/tcp/${DB_ACTIVE_IP}/${DB_PORT}" 2>/dev/null
}

check_active_ping() {
    ping -c 2 -W 1 "$DB_ACTIVE_IP" >/dev/null 2>&1
}

check_active_query_repl() {
    timeout "$HEALTH_TIMEOUT" "${MYSQL_BIN}" \
        -h"${DB_ACTIVE_IP}" -P"${DB_PORT}" \
        -u"${REPL_USER}" -p"${REPL_PASSWORD}" \
        --ssl-verify-server-cert=0 \
        -N -B -e "DO 1;" >/dev/null 2>&1
}

run_health_check() {
    HC_PING="FAIL"; HC_PORT="FAIL"
    HC_QUERY_REPL="FAIL"; HC_QUERY="FAIL"

    if ! check_active_ping; then
        HC_VERDICT="SERVER_DOWN"
        return
    fi
    HC_PING="OK"

    check_active_port && HC_PORT="OK"
    check_active_query_repl && HC_QUERY_REPL="OK"
    [ "$HC_QUERY_REPL" == "OK" ] && HC_QUERY="OK"

    if [ "$HC_QUERY" == "OK" ]; then
        HC_VERDICT="HEALTHY"
    elif [ "$HC_PORT" == "FAIL" ]; then
        HC_VERDICT="DB_DOWN"
    else
        HC_VERDICT="DEGRADED"
    fi
}

print_health_result() {
    local pc="$COLOR_RED"; [ "$HC_PORT" == "OK" ] && pc="$COLOR_GREEN"
    local rc="$COLOR_RED"; [ "$HC_PING" == "OK" ] && rc="$COLOR_GREEN"
    local q2="$COLOR_RED"; [ "$HC_QUERY_REPL" == "OK" ] && q2="$COLOR_GREEN"
    local vc="$COLOR_RED"
    [ "$HC_VERDICT" == "HEALTHY" ]  && vc="$COLOR_GREEN"
    [ "$HC_VERDICT" == "DEGRADED" ] && vc="$COLOR_YELLOW"

    echo -e "${COLOR_BLUE}=== Active(${DB_ACTIVE_IP}) 헬스체크 ===${COLOR_RESET}"
    echo -e "  모드                  : $(failover_mode_desc)"
    echo -e "  포트(${DB_PORT})        : ${pc}${HC_PORT}${COLOR_RESET}"
    echo -e "  서버 응답(ping)       : ${rc}${HC_PING}${COLOR_RESET}"
    echo -e "  접속(${REPL_USER})          : ${q2}${HC_QUERY_REPL}${COLOR_RESET}"
    echo -e "  종합 판정             : ${vc}${HC_VERDICT}${COLOR_RESET}"
}

prepare_health_env() {
    load_config
    verify_monitor_role

    MYSQL_BIN="$(resolve_bin "mysql")" || {
        log "[ERROR] mysql 명령어를 찾을 수 없습니다 (${BASEDIR}/bin, PATH 확인)"
        exit 1
    }

    DB_ROOT_PASSWORD="$(decrypt_password "${DB_ROOT_PASSWORD_ENC}")"
    if [ -z "$DB_ROOT_PASSWORD" ]; then
        log "[ERROR] DB ROOT 비밀번호를 복호화하지 못했습니다. config를 확인하세요."
        exit 1
    fi

    if [ "$MONITOR_ROLE" == "STANDBY" ]; then
        REPL_PASSWORD="$(decrypt_password "${REPL_PASSWORD_ENC}")"
        if [ -z "$REPL_PASSWORD" ]; then
            log "[ERROR] REPLICATION 계정(${REPL_USER}) 비밀번호를 복호화하지 못했습니다. config를 확인하세요."
            exit 1
        fi
    fi
}

run_check_once() {
    prepare_health_env
    set +e

    if [ "$MONITOR_ROLE" == "ACTIVE" ]; then
        echo -e "${COLOR_BLUE}=== ACTIVE 자가 점검 (${CURRENT_IP}) ===${COLOR_RESET}"
        local db_state="FAIL" ip_state="미부여"
        check_local_db_alive && db_state="OK"
        sub_ip_is_assigned && ip_state="부여됨"

        local dc="$COLOR_RED"; [ "$db_state" == "OK" ] && dc="$COLOR_GREEN"
        local ic="$COLOR_RED"; [ "$ip_state" == "부여됨" ] && ic="$COLOR_GREEN"
        echo -e "  로컬 MariaDB      : ${dc}${db_state}${COLOR_RESET}"
        echo -e "  SUB_IP(${SUB_IP}) : ${ic}${ip_state}${COLOR_RESET}"

        if [ "$db_state" == "OK" ] && [ "$ip_state" == "부여됨" ]; then
            exit 0
        fi
        if [ "$db_state" == "FAIL" ] && [ "$ip_state" == "부여됨" ]; then
            echo -e "${COLOR_RED}  DB가 죽었는데 SUB_IP가 남아 있습니다. Standby 승격 시 IP 충돌 위험이 있습니다.${COLOR_RESET}"
        fi
        exit 1
    fi

    run_health_check
    print_health_result
    [ "$HC_VERDICT" == "HEALTHY" ] && exit 0
    exit 1
}

run_monitor_loop() {
    local fail_count=0

    set +e

    log "감시 시작 (주기 ${HEALTH_INTERVAL}초, 연속 ${HEALTH_FAIL_THRESHOLD}회 실패 시 장애 판정)"

    while true; do
        run_health_check

        local all_failed=0
        if [ "$HC_PING" != "OK" ] && [ "$HC_PORT" == "FAIL" ] \
           && [ "$HC_QUERY_REPL" == "FAIL" ]; then
            all_failed=1
        fi

        local detail="[ping:${HC_PING} 포트:${HC_PORT} ${REPL_USER}:${HC_QUERY_REPL}]"

        if [ "$all_failed" -eq 1 ]; then
            fail_count=$((fail_count + 1))
            log "[WARN] Active 장애 감지 (${HC_VERDICT}) - 연속 ${fail_count}/${HEALTH_FAIL_THRESHOLD}회 ${detail}"

            if [ "$fail_count" -ge "$HEALTH_FAIL_THRESHOLD" ]; then
                log "[ERROR] 연속 ${fail_count}회 실패 - Active 장애로 판정합니다 (판정: ${HC_VERDICT})"

                if should_auto_promote; then
                    log "[ERROR] 자동 승격을 시작합니다 ($(failover_mode_desc))"
                    rm -f "$PID_FILE"
                    PROMOTE_TRIGGER="auto"
                    execute_promotion
                    log "자동 승격 완료 - 모니터링을 종료합니다."
                    exit 0
                fi

                if [ "$FAILOVER_MODE" == "3" ]; then
                    log "[ERROR] 자동 승격이 꺼져 있습니다 (모드 3)."
                else
                    log "[WARN] 판정(${HC_VERDICT})은 실제 장애로 단정할 수 없어 승격을 보류합니다."
                fi

                cat <<EOF

=====================================================
 Active 감시를 종료합니다.

 장애는 감지되었으나 자동 승격을 수행하지 않았습니다.
 로그가 계속 쌓이는 것을 막기 위해 서비스를 종료합니다.

 판정: ${HC_VERDICT}

 조치 후 아래로 진행하세요.

   1) 상태 확인
        $0 check

   2) 승격이 필요하면
        $0 promote

   3) Active 복구 후 감시 재시작
        systemctl start ${SERVICE_NAME}
=====================================================

EOF
                log "Active 감시 종료"
                rm -f "$PID_FILE"
                exit 0
            fi

        elif [ "$HC_VERDICT" == "HEALTHY" ]; then
            if [ "$fail_count" -gt 0 ]; then
                log "Active 정상 복구됨 (직전 연속 실패 ${fail_count}회 초기화)"
            fi
            fail_count=0

        else
            if [ "$fail_count" -gt 0 ]; then
                log "일부 항목만 실패하여 연속 실패 카운트를 초기화합니다 (직전 ${fail_count}회)"
                fail_count=0
            fi
            log "[WARN] Active 일부 항목 이상 (${HC_VERDICT}) - 승격 카운트에는 반영하지 않음 ${detail}"
        fi

        sleep "$HEALTH_INTERVAL"
    done
}

monitor_is_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

monitor_start() {
    if monitor_is_running; then
        log "[WARN] 모니터링이 이미 실행 중입니다 (PID $(cat "$PID_FILE"))"
        exit 0
    fi

    prepare_health_env

    if [ "$MONITOR_ROLE" == "ACTIVE" ]; then
        log "감시 유형: ACTIVE 자가 감시 (로컬 DB 장애 시 SUB_IP 자가 회수)"
        log "대상 SUB_IP: ${SUB_IP}/${SUB_IP_CIDR}"
    else
        log "감시 유형: STANDBY -> Active 감시"
        log "Fail-over 설정: $(failover_mode_desc)"
        if [ "$FAILOVER_MODE" != "3" ]; then
            log "[WARN] 자동 승격이 켜져 있습니다. 임계값 도달 시 확인 없이 승격됩니다."
        fi
    fi

    log "모니터링을 백그라운드로 시작합니다."
    setsid nohup "$0" __monitor_worker >> "$MONITOR_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    sleep 2
    if monitor_is_running; then
        log "모니터링 시작됨 (PID ${pid})"
        log "로그: ${MONITOR_LOG}"
        log "중지: $0 monitor-stop"
    else
        log "[ERROR] 모니터링 기동에 실패했습니다. 로그를 확인하세요: ${MONITOR_LOG}"
        rm -f "$PID_FILE"
        exit 1
    fi
}

monitor_stop() {
    if ! monitor_is_running; then
        log "[WARN] 실행 중인 모니터링이 없습니다."
        rm -f "$PID_FILE"
        exit 0
    fi

    local pid
    pid="$(cat "$PID_FILE")"
    kill "$pid" 2>/dev/null || true
    sleep 1

    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    log "모니터링 중지됨 (PID ${pid})"
}

service_is_active() {
    systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null
}

monitor_status() {
    check_service_path_match || echo ""

    if service_is_active; then
        echo -e "${COLOR_GREEN}모니터링 실행 중 (systemd 서비스: ${SERVICE_NAME})${COLOR_RESET}"
        echo "로그: ${MONITOR_LOG}"
        echo ""
        echo "최근 로그 10줄:"
        tail -n 10 "$MONITOR_LOG" 2>/dev/null || echo "  (로그 없음)"
        return
    fi

    if monitor_is_running; then
        echo -e "${COLOR_GREEN}모니터링 실행 중 (PID $(cat "$PID_FILE"))${COLOR_RESET}"
        echo "로그: ${MONITOR_LOG}"
        echo ""
        echo "최근 로그 10줄:"
        tail -n 10 "$MONITOR_LOG" 2>/dev/null || echo "  (로그 없음)"
    else
        echo -e "${COLOR_YELLOW}모니터링이 실행 중이 아닙니다.${COLOR_RESET}"
    fi
}

set_role_state() {
    local state="$1"

    if grep -q "^ROLE_STATE=" "$CONFIG_FILE"; then
        sed -i "s#^ROLE_STATE=.*#ROLE_STATE=\"${state}\"#" "$CONFIG_FILE"
    else
        echo "ROLE_STATE=\"${state}\"" >> "$CONFIG_FILE"
    fi

    if grep -q "^PROMOTED_AT=" "$CONFIG_FILE"; then
        sed -i "s#^PROMOTED_AT=.*#PROMOTED_AT=\"$(date '+%Y-%m-%d %H:%M:%S')\"#" "$CONFIG_FILE"
    else
        echo "PROMOTED_AT=\"$(date '+%Y-%m-%d %H:%M:%S')\"" >> "$CONFIG_FILE"
    fi

    log "역할 상태 기록: ROLE_STATE=${state}"
}

fence_old_active() {
    log "[1/7] 기존 Active(${DB_ACTIVE_IP}) 차단 시도"

    if [ "$HC_VERDICT" == "SERVER_DOWN" ]; then
        log "[WARN] 판정이 SERVER_DOWN 이므로 SSH로 차단할 수 없습니다."
        log "[WARN] 기존 Active가 나중에 단독으로 살아나면 split-brain 위험이 있습니다."
        log "[WARN] 복구 시 반드시 해당 서버를 Standby로 재구성한 뒤 기동하세요."
        return
    fi

    if timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 \
            -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${DB_ACTIVE_IP}" "exit" 2>/dev/null; then

        log "SSH 접속 가능 - 기존 Active의 MariaDB를 정지합니다."

        timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=5 \
            -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${DB_ACTIVE_IP}" \
            "sudo -n systemctl stop ${DB_SERVICE_NAME} 2>/dev/null || sudo -n pkill -f mysqld 2>/dev/null" \
            2>/dev/null || true

        sleep 3

        local still_alive
        still_alive=$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 \
            -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${DB_ACTIVE_IP}" \
            "if pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1; then echo ALIVE; else echo STOPPED; fi" 2>/dev/null) || still_alive="UNKNOWN"

        if [ "$still_alive" == "STOPPED" ]; then
            log "기존 Active의 MariaDB 정지 확인 완료"
        else
            log "[WARN] 기존 Active의 MariaDB가 여전히 살아있거나 확인이 불가합니다 (${still_alive})."
            log "[WARN] sudo NOPASSWD 미설정이거나 권한이 부족할 수 있습니다."
            handle_fence_failure
        fi
    else
        log "[WARN] SSH 접속 불가 - 기존 Active를 차단할 수 없습니다."
        handle_fence_failure
    fi
}

handle_fence_failure() {
    if [ "$PROMOTE_TRIGGER" == "auto" ]; then
        case "$FAILOVER_MODE" in
            1)
                log "[WARN] 모드 1: 차단에 실패했지만 전환을 우선하여 승격을 계속 진행합니다."
                log "[WARN] 기존 Active가 살아있다면 split-brain이 발생할 수 있으니 즉시 확인하세요."
                ;;
            *)
                log "[ERROR] 모드 ${FAILOVER_MODE}: 기존 Active 차단에 실패하여 자동 승격을 중단합니다."
                log "[ERROR] split-brain 위험이 있어 자동으로 진행하지 않습니다."
                log "[ERROR] 기존 Active(${DB_ACTIVE_IP})의 MariaDB를 직접 정지시킨 뒤 실행하세요: $0 promote"
                exit 1
                ;;
        esac
        return
    fi

    read -r -p "그래도 승격을 계속 진행하시겠습니까? (yes 입력 시 진행): " FORCE_ANSWER
    if [ "$FORCE_ANSWER" != "yes" ]; then
        log "사용자 취소로 승격을 중단합니다."
        exit 1
    fi
}

wait_relay_applied() {
    log "[2/7] 잔여 relay log 적용 대기"

    local max_wait=30
    local waited=0

    while [ "$waited" -lt "$max_wait" ]; do
        local behind
        behind=$("${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" \
            -e "SHOW SLAVE STATUS\G" 2>/dev/null \
            | grep "Seconds_Behind_Master:" | awk '{print $2}')

        if [ -z "$behind" ] || [ "$behind" == "NULL" ]; then
            log "Active와 연결이 끊긴 상태입니다 (받을 수 있는 로그가 없음). 대기를 종료합니다."
            break
        fi

        if [ "$behind" -eq 0 ] 2>/dev/null; then
            log "지연 0 확인 - 잔여 로그 적용 완료"
            break
        fi

        log "지연 ${behind}초 - 대기 중 (${waited}/${max_wait}초)"
        sleep 3
        waited=$((waited + 3))
    done

    if [ "$waited" -ge "$max_wait" ]; then
        log "[WARN] ${max_wait}초 내에 지연이 해소되지 않았습니다. 일부 트랜잭션이 유실될 수 있습니다."
    fi
}

release_replication() {
    log "[3/7] Replication 설정 해제"
    mysql_root "
        STOP SLAVE;
        RESET SLAVE ALL;
    "
    log "Replication 해제 완료"
}

enable_write_runtime() {
    log "[4/7] 쓰기 허용 (런타임 적용)"
    mysql_root "SET GLOBAL read_only = 0;"
    log "read_only = 0 적용 완료"
}

persist_write_config() {
    log "[5/7] my.cnf에 쓰기 허용 영구 반영"
    resolve_mycnf_path

    cp -f "$MYCNF_PATH" "${MYCNF_PATH}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    if grep -qE "^[[:space:]]*read_only[[:space:]]*=" "$MYCNF_PATH"; then
        sed -i "s#^[[:space:]]*read_only[[:space:]]*=.*#read_only = 0#" "$MYCNF_PATH"
        log "my.cnf의 read_only 값을 0으로 변경했습니다."
    else
        log "my.cnf에 read_only 설정이 없습니다 (기본값이 쓰기 가능이므로 추가 불필요)."
    fi
}

notify_client_switch() {
    log "[6/7] 클라이언트 접속 전환"

    if vip_enabled; then
        if check_sub_ip_conflict; then
            attach_sub_ip || log "[WARN] 보조 IP 부여에 실패했습니다. 수동으로 확인하세요."
        else
            log "[ERROR] IP 충돌 위험으로 SUB_IP 부여를 건너뜁니다."
            log "[ERROR] 기존 Active에서 IP를 내린 뒤 수동으로 부여하세요:"
            log "        ip addr add ${SUB_IP}/${SUB_IP_CIDR} dev \$(ip route show default | awk '{print \$5;exit}')"
        fi
    fi

    if [ -n "$SUB_IP" ] && sub_ip_is_assigned; then
        cat <<EOF

=====================================================
 DB 승격이 완료되었습니다.

   새 Active   : ${CURRENT_IP}
   기존 Active : ${DB_ACTIVE_IP} (정지/장애 상태)
   서비스 IP   : ${SUB_IP}  <- 이 서버로 이동 완료

 애플리케이션이 서비스 IP(${SUB_IP}) 로 접속 중이라면
 별도 조치 없이 그대로 사용하면 됩니다.
=====================================================

EOF
    else
        cat <<EOF

=====================================================
 DB 승격은 완료되었습니다. 이제 애플리케이션이 이 서버를
 바라보도록 접속 대상을 전환해야 합니다.

   새 Active   : ${CURRENT_IP}
   기존 Active : ${DB_ACTIVE_IP} (정지/장애 상태)

 VIP, DNS, 커넥션 설정 중 사용 중인 방식에 맞춰 전환하세요.
=====================================================

EOF
    fi
}

verify_promotion() {
    log "[7/7] 승격 검증 및 역할 기록"

    local ro
    ro=$("${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" \
        -N -B -e "SELECT @@GLOBAL.read_only;" 2>/dev/null)

    if [ "$ro" == "0" ]; then
        log "쓰기 가능 상태 확인 (read_only=0)"
    else
        log "[ERROR] read_only 값이 여전히 ${ro} 입니다. 승격이 정상 완료되지 않았습니다."
        exit 1
    fi

    local slave_status
    slave_status=$("${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" \
        -e "SHOW SLAVE STATUS\G" 2>/dev/null)

    if [ -z "$slave_status" ]; then
        log "Replication 해제 확인 (SHOW SLAVE STATUS 비어 있음)"
    else
        log "[WARN] SHOW SLAVE STATUS에 아직 정보가 남아 있습니다. 확인이 필요합니다."
    fi

    set_role_state "active-temporary"
}

execute_promotion() {
    fence_old_active
    if vip_enabled; then
        release_peer_sub_ip "$DB_ACTIVE_IP" || \
            log "[WARN] 기존 Active 의 SUB_IP 회수를 확인하지 못했습니다. 부여 단계에서 다시 확인합니다."
    fi
    wait_relay_applied
    release_replication
    enable_write_runtime
    persist_write_config
    notify_client_switch
    verify_promotion

    log "=========================================="
    log " 승격 완료 - 이 서버(${CURRENT_IP})가 새 Active 입니다"
    log " ROLE_STATE=active-temporary (원복 시 참조)"
    log "=========================================="
}

run_promote() {
    prepare_health_env
    set +e

    log "=========================================="
    log " 승격 절차 시작 (Standby -> Active)"
    log "=========================================="

    log "현재 Active 상태를 먼저 확인합니다."
    run_health_check
    print_health_result

    if [ "$HC_VERDICT" == "HEALTHY" ]; then
        log "[WARN] Active(${DB_ACTIVE_IP})가 정상 동작 중입니다."
        log "[WARN] 이 상태에서 승격하면 양쪽이 모두 쓰기를 받는 split-brain이 발생할 수 있습니다."
    fi

    echo ""
    read -r -p "정말 이 서버를 Active로 승격하시겠습니까? (yes 입력 시 진행): " ANSWER
    if [ "$ANSWER" != "yes" ]; then
        log "사용자 취소로 승격을 중단합니다."
        exit 0
    fi

    if monitor_is_running; then
        log "실행 중인 모니터링을 중지합니다."
        monitor_stop || true
    fi

    PROMOTE_TRIGGER="manual"
    execute_promotion
}

rollback_detect_context() {
    CURRENT_IP=$(hostname -I | awk '{print $1}')

    if [ "$CURRENT_IP" == "$DB_ACTIVE_IP" ]; then
        RB_ROLE="OLD_ACTIVE"
        RB_PEER="$DB_STANDBY_IP"
    elif [ "$CURRENT_IP" == "$DB_STANDBY_IP" ]; then
        RB_ROLE="TEMP_ACTIVE"
        RB_PEER="$DB_ACTIVE_IP"
    else
        log "[ERROR] 현재 서버 IP(${CURRENT_IP})가 config의 Active/Standby IP와 일치하지 않습니다."
        exit 1
    fi
}

rollback_send() {
    load_config
    check_dependencies
    ensure_open_files_limit
    rollback_detect_context
    set +e

    if [ "$RB_ROLE" != "TEMP_ACTIVE" ]; then
        log "[ERROR] rollback-send 는 현재 서비스 중인 서버(${DB_STANDBY_IP})에서 실행해야 합니다."
        log "[ERROR] 현재 서버: ${CURRENT_IP}"
        exit 1
    fi

    log "=========================================="
    log " 원복 준비: 백업 생성 후 ${RB_PEER} 로 전송"
    log "=========================================="

    DB_ROOT_PASSWORD="$(resolve_root_password "${DB_ROOT_PASSWORD_ENC}")"

    local ts backup_dir
    ts="$(date +%Y%m%d_%H%M%S)"
    backup_dir="${BACKUP_DIR}/rollback_${ts}"

    log "[1/4] 로컬 백업 생성: ${backup_dir}"
    mkdir -p "$backup_dir"
    if ! "${MARIABACKUP_BIN}" --backup \
            --target-dir="${backup_dir}" \
            --user="${DB_ROOT_USER}" \
            --password="${DB_ROOT_PASSWORD}"; then
        log "[ERROR] 백업 생성에 실패했습니다."
        exit 1
    fi

    log "[2/4] GTID 위치 기록"
    local gtid_pos
    gtid_pos="$("${MYSQL_BIN}" -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" \
        -N -B -e "SELECT @@GLOBAL.gtid_binlog_pos;" 2>/dev/null)"
    if [ -n "$gtid_pos" ]; then
        echo "$gtid_pos" > "${backup_dir}/gtid_info.txt"
        log "GTID: ${gtid_pos}"
    else
        log "[WARN] GTID 위치를 조회하지 못했습니다."
    fi

    echo "${ts}" > "${backup_dir}/.backup_complete"

    log "[3/4] 전송 권한 정리"
    chown -R "${SSH_USER}:${SSH_USER}" "$backup_dir"

    log "[4/4] ${RB_PEER} 로 전송"
    if ! rsync -avP -e "ssh -i ${SSH_KEY} -p ${SSH_PORT}" \
            "${backup_dir}" "${SSH_USER}@${RB_PEER}:${BACKUP_DIR}/"; then
        log "[ERROR] 전송에 실패했습니다."
        log "[ERROR] ${RB_PEER} 의 ${BACKUP_DIR} 쓰기 권한을 확인하세요."
        exit 1
    fi

    log "=========================================="
    log " 백업 전송 완료"
    log "=========================================="
    cat <<EOF

 전송된 백업: ${BACKUP_DIR}/rollback_${ts}

 이제 ${RB_PEER} 서버에서 아래를 실행하세요.

   $0 rollback-prepare

EOF
}

rollback_prepare() {
    load_config
    check_dependencies
    ensure_open_files_limit
    rollback_detect_context
    set +e

    if [ "$RB_ROLE" != "OLD_ACTIVE" ]; then
        log "[ERROR] rollback-prepare 는 원래 Active 였던 서버(${DB_ACTIVE_IP})에서 실행해야 합니다."
        log "[ERROR] 현재 서버: ${CURRENT_IP}"
        exit 1
    fi

    log "=========================================="
    log " 원복 1단계: 이 서버(${CURRENT_IP})를 Standby로 편입"
    log " 데이터 원본: ${RB_PEER} (현재 서비스 중인 Active)"
    log "=========================================="

    DB_ROOT_PASSWORD="$(resolve_root_password "${DB_ROOT_PASSWORD_ENC}")"
    REPL_PASSWORD="$(resolve_password "${REPL_PASSWORD_ENC}" "REPLICATION 계정(${REPL_USER}) 비밀번호")"

    log "[1/5] 현재 서비스 중인 Active(${RB_PEER}) 상태 확인"
    if ! timeout "$HEALTH_TIMEOUT" "${MYSQL_BIN}" -h"${RB_PEER}" -P"${DB_PORT}" \
            -u"${REPL_USER}" -p"${REPL_PASSWORD}" --ssl-verify-server-cert=0 \
            -N -B -e "DO 1;" >/dev/null 2>&1; then
        log "[ERROR] ${RB_PEER} 에 접속할 수 없습니다. 원복 대상이 정상 동작 중이어야 합니다."
        exit 1
    fi
    log "${RB_PEER} 정상 확인"

    log "[2/5] 로컬 MariaDB 정지 및 쓰기 차단 설정"
    if is_mariadb_running; then
        if systemctl list-unit-files 2>/dev/null | grep -qE "^${DB_SERVICE_NAME}\.service"; then
            systemctl stop "$DB_SERVICE_NAME"
        else
            pkill -u "${DB_owner}" -f mysqld || true
            sleep 2
        fi
    fi

    resolve_mycnf_path
    cp -f "$MYCNF_PATH" "${MYCNF_PATH}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    if grep -qE "^[[:space:]]*read_only[[:space:]]*=" "$MYCNF_PATH"; then
        sed -i "s#^[[:space:]]*read_only[[:space:]]*=.*#read_only = 1#" "$MYCNF_PATH"
    else
        echo "read_only = 1" >> "$MYCNF_PATH"
    fi
    log "my.cnf read_only = 1 설정 완료"

    log "[3/5] 전송된 백업 확인"
    local backup_local
    backup_local="$(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'rollback_*' 2>/dev/null | sort | tail -n 1)"

    if [ -z "$backup_local" ]; then
        log "[ERROR] ${BACKUP_DIR} 에 rollback_* 백업 디렉토리가 없습니다."
        cat <<EOF

=====================================================
 먼저 현재 서비스 중인 서버(${RB_PEER})에서 백업을 생성해
 이 서버로 전송해야 합니다.

 ${RB_PEER} 에서 실행:

   $0 rollback-send

 전송이 끝난 뒤 이 서버에서 다시 실행하세요.
=====================================================

EOF
        exit 1
    fi

    if [ ! -f "${backup_local}/.backup_complete" ]; then
        log "[ERROR] ${backup_local} 백업이 불완전합니다 (.backup_complete 없음)."
        log "[ERROR] ${RB_PEER} 에서 rollback-send 를 다시 실행하세요."
        exit 1
    fi
    log "사용할 백업: ${backup_local}"

    log "[4/5] 백업 prepare 및 datadir 교체"
    if ! "${MARIABACKUP_BIN}" --prepare --target-dir="${backup_local}"; then
        log "[ERROR] prepare 에 실패했습니다."
        exit 1
    fi

    rm -rf "${DATADIR_OLD_BACKUP:?}"
    mv "${DATADIR}" "${DATADIR_OLD_BACKUP}"
    mkdir -p "${DATADIR}"

    if ! "${MARIABACKUP_BIN}" --copy-back --target-dir="${backup_local}" --datadir="${DATADIR}"; then
        log "[ERROR] copy-back 에 실패했습니다. 기존 데이터는 ${DATADIR_OLD_BACKUP} 에 있습니다."
        exit 1
    fi
    chown -R "${DB_owner}:${DB_owner}" "${DATADIR}"

    log "[5/5] MariaDB 기동 및 Replication 연결"
    if systemctl list-unit-files 2>/dev/null | grep -qE "^${DB_SERVICE_NAME}\.service"; then
        systemctl start "$DB_SERVICE_NAME"
    else
        nohup "${BASEDIR}/bin/mysqld_safe" --datadir="${DATADIR}" --user="${DB_owner}" > /dev/null 2>&1 &
    fi
    sleep 5

    local gtid_pos=""
    [ -f "${backup_local}/gtid_info.txt" ] && gtid_pos="$(cat "${backup_local}/gtid_info.txt")"
    if [ -z "$gtid_pos" ]; then
        gtid_pos="$(timeout 10 "${MYSQL_BIN}" -h"${RB_PEER}" -P"${DB_PORT}" \
            -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" --ssl-verify-server-cert=0 \
            -N -B -e "SELECT @@GLOBAL.gtid_binlog_pos;" 2>/dev/null)"
    fi
    if [ -n "$gtid_pos" ]; then
        log "gtid_slave_pos 설정: ${gtid_pos}"
        mysql_root "SET GLOBAL gtid_slave_pos = '${gtid_pos}';"
    fi

    mysql_root "
        STOP SLAVE;
        RESET SLAVE ALL;
        CHANGE MASTER TO
            MASTER_HOST='${RB_PEER}',
            MASTER_PORT=${DB_PORT},
            MASTER_USER='${REPL_USER}',
            MASTER_PASSWORD='${REPL_PASSWORD}',
            MASTER_USE_GTID=${GTID_MODE};
        START SLAVE;
    "

    sleep 3
    set_role_state "rollback-syncing"

    log "=========================================="
    log " 원복 1단계 완료"
    log "=========================================="
    cat <<EOF

 이 서버(${CURRENT_IP})는 이제 ${RB_PEER} 를 바라보는 Standby 입니다.

 다음 순서로 진행하세요.

  1) 동기화 상태를 확인하며 지연이 0 이 될 때까지 기다립니다.
       $0 status

  2) 지연이 0 이고 IO/SQL 스레드가 모두 Yes 이면,
     트래픽이 적은 시점에 전환을 실행합니다.
       $0 rollback-switch

 전환 전까지 서비스는 ${RB_PEER} 에서 계속 동작합니다.

EOF
}

rollback_switch() {
    load_config
    check_dependencies
    rollback_detect_context
    set +e

    if [ "$RB_ROLE" != "OLD_ACTIVE" ]; then
        log "[ERROR] rollback-switch 는 원래 Active 였던 서버(${DB_ACTIVE_IP})에서 실행해야 합니다."
        exit 1
    fi

    if [ "$ROLE_STATE" != "rollback-syncing" ]; then
        log "[ERROR] 원복 준비 단계가 완료되지 않았습니다 (ROLE_STATE=${ROLE_STATE:-없음})."
        log "[ERROR] 먼저 실행하세요: $0 rollback-prepare"
        exit 1
    fi

    DB_ROOT_PASSWORD="$(resolve_root_password "${DB_ROOT_PASSWORD_ENC}")"
    REPL_PASSWORD="$(decrypt_password "${REPL_PASSWORD_ENC}")"

    log "=========================================="
    log " 원복 2단계: 서비스를 이 서버(${CURRENT_IP})로 전환"
    log "=========================================="

    log "[1/7] 동기화 상태 확인"
    local slave_out behind io_run sql_run
    slave_out="$(mysql_root_out "SHOW SLAVE STATUS\G")"
    behind="$(echo "$slave_out"  | grep -m1 "Seconds_Behind_Master:" | awk '{print $2}')"
    io_run="$(echo "$slave_out"  | grep -m1 "Slave_IO_Running:"      | awk '{print $2}')"
    sql_run="$(echo "$slave_out" | grep -m1 "Slave_SQL_Running:"     | awk '{print $2}')"

    log "  IO=${io_run} SQL=${sql_run} 지연=${behind}"

    if [ "$io_run" != "Yes" ] || [ "$sql_run" != "Yes" ]; then
        log "[ERROR] Replication 이 정상 동작 중이 아닙니다. 전환할 수 없습니다."
        exit 1
    fi
    if [ "$behind" != "0" ]; then
        log "[ERROR] 아직 지연이 남아 있습니다 (${behind}초). 0 이 될 때까지 기다린 뒤 다시 실행하세요."
        exit 1
    fi

    echo ""
    read -r -p "서비스를 ${RB_PEER} 에서 ${CURRENT_IP} 로 전환합니다. 계속할까요? (yes 입력): " ANSWER
    if [ "$ANSWER" != "yes" ]; then
        log "사용자 취소로 중단합니다."
        exit 0
    fi

    log "[2/7] 현재 Active(${RB_PEER}) 쓰기 차단"
    timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${RB_PEER}" \
        "${BASEDIR}/bin/mysql -u${DB_ROOT_USER} -p'${DB_ROOT_PASSWORD}' -e 'SET GLOBAL read_only = 1;'" \
        2>/dev/null || log "[WARN] 원격 쓰기 차단에 실패했습니다. 수동 확인이 필요합니다."

    log "[3/7] 잔여 로그 반영 대기"
    local waited=0
    while [ "$waited" -lt 30 ]; do
        behind="$(mysql_root_out "SHOW SLAVE STATUS\G" | grep -m1 "Seconds_Behind_Master:" | awk '{print $2}')"
        [ "$behind" == "0" ] && break
        sleep 2
        waited=$((waited + 2))
    done
    log "  최종 지연: ${behind}"

    log "[4/7] Replication 해제"
    mysql_root "STOP SLAVE; RESET SLAVE ALL;"

    log "[5/7] 쓰기 허용 (런타임 + my.cnf)"
    mysql_root "SET GLOBAL read_only = 0;"
    resolve_mycnf_path
    cp -f "$MYCNF_PATH" "${MYCNF_PATH}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    if grep -qE "^[[:space:]]*read_only[[:space:]]*=" "$MYCNF_PATH"; then
        sed -i "s#^[[:space:]]*read_only[[:space:]]*=.*#read_only = 0#" "$MYCNF_PATH"
    fi

    log "[6/7] 서비스 IP 이동"
    if vip_enabled; then
        if release_peer_sub_ip "$RB_PEER"; then
            attach_sub_ip || log "[WARN] SUB_IP 부여에 실패했습니다."
        else
            log "[ERROR] 상대 서버(${RB_PEER})의 SUB_IP 회수를 확인하지 못했습니다."
            log "[ERROR] IP 충돌을 막기 위해 이 서버에는 SUB_IP 를 부여하지 않았습니다."
            local my_dev
            my_dev="$(resolve_sub_ip_dev)"
            cat <<EOF

=====================================================
 DB 전환은 완료되었으나 서비스 IP 는 이동하지 않았습니다.
 IP 충돌을 막기 위해 부여를 건너뛰었습니다.

 아래 순서로 직접 처리하세요.

 1) ${RB_PEER} 에서 IP 회수
      ip addr del ${SUB_IP}/${SUB_IP_CIDR} dev <인터페이스>

    (인터페이스 확인)
      ip -o -4 addr show | grep ${SUB_IP}

 2) 회수 확인 후, 이 서버(${CURRENT_IP})에서 부여
      ip addr add ${SUB_IP}/${SUB_IP_CIDR} dev ${my_dev}
      arping -q -c 2 -A -I ${my_dev} ${SUB_IP}

 반드시 1) 을 먼저 끝낸 뒤 2) 를 실행하세요.
=====================================================

EOF
        fi
    else
        log "  VIP_MODE=no 이므로 접속 대상을 직접 전환해야 합니다."
    fi

    log "[7/7] 상태 기록 및 모니터링 재기동"
    set_role_state "normal"

    ROLE="ACTIVE"
    restart_monitor_after_switch

    log "=========================================="
    log " 원복 완료 - ${CURRENT_IP} 가 다시 Active 입니다"
    log "=========================================="
    cat <<EOF

 남은 작업: ${RB_PEER} 를 다시 Standby 로 붙여야 합니다.
 ${RB_PEER} 서버에서 아래를 실행하세요.

   $0 rollback-finish

 전환 시점까지 동기화되어 있으므로 데이터 복원 없이
 복제 방향만 바꿉니다. 모니터링도 함께 기동됩니다.

EOF
}

restart_monitor_after_switch() {
    if [ "$AUTO_START_MONITOR" != "yes" ]; then
        log "AUTO_START_MONITOR=no 이므로 모니터링을 기동하지 않습니다."
        log "필요 시 실행: systemctl start ${SERVICE_NAME}"
        return 0
    fi

    if ! vip_enabled; then
        log "VIP_MODE=no 이므로 Active 자가 감시를 기동하지 않습니다."
        return 0
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        log "[WARN] systemctl 을 사용할 수 없어 모니터링을 자동 기동하지 않습니다."
        return 0
    fi

    if service_is_active; then
        log "모니터링을 재시작합니다 (${SERVICE_NAME})"
        systemctl restart "${SERVICE_NAME}.service" 2>/dev/null || true
    else
        if [ ! -f "$SERVICE_FILE" ]; then
            log "서비스가 등록되어 있지 않아 등록 후 기동합니다."
            ( service_install ) || {
                log "[WARN] 서비스 등록에 실패했습니다. 수동 실행: $0 service-install"
                return 0
            }
        fi
        log "모니터링을 기동합니다 (${SERVICE_NAME})"
        systemctl start "${SERVICE_NAME}.service" 2>/dev/null || true
    fi

    sleep 2
    if service_is_active; then
        log "모니터링 기동 완료 (${SERVICE_NAME})"
    else
        log "[WARN] 모니터링이 기동되지 않았습니다. 확인: systemctl status ${SERVICE_NAME}"
    fi
}

wait_for_db() {
    load_config

    MYSQL_BIN="$(resolve_bin "mysql")" || {
        log "[ERROR] mysql 명령어를 찾을 수 없습니다."
        exit 1
    }

    local max_wait="${DB_WAIT_TIMEOUT:-300}"
    local waited=0

    log "MariaDB 기동 대기 (최대 ${max_wait}초)"
    log "systemd 등록 여부와 무관하게 실제 프로세스/접속으로 확인합니다."

    while [ "$waited" -lt "$max_wait" ]; do
        if pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1; then
            if timeout 5 "${MYSQL_BIN}" -u"${DB_ROOT_USER}" \
                    -p"$(decrypt_password "${DB_ROOT_PASSWORD_ENC}")" \
                    -N -B -e "SELECT 1;" >/dev/null 2>&1; then
                log "MariaDB 기동 확인 완료 (${waited}초 경과)"
                return 0
            fi
        fi

        sleep 5
        waited=$((waited + 5))

        if [ $((waited % 30)) -eq 0 ]; then
            log "  대기 중... (${waited}/${max_wait}초)"
        fi
    done

    log "[ERROR] ${max_wait}초 내에 MariaDB 가 준비되지 않았습니다."
    return 1
}

check_service_path_match() {
    [ -f "$SERVICE_FILE" ] || return 0

    local registered
    registered="$(grep -m1 '^ExecStart=' "$SERVICE_FILE" | sed 's#^ExecStart=##' | awk '{print $1}')"
    local current="${SCRIPT_DIR}/$(basename "$0")"

    if [ -n "$registered" ] && [ "$registered" != "$current" ]; then
        log "[WARN] 등록된 서비스의 스크립트 경로가 현재 위치와 다릅니다."
        log "[WARN]   서비스 등록 경로: ${registered}"
        log "[WARN]   현재 스크립트    : ${current}"
        log "[WARN] 부팅 시 모니터링이 동작하지 않습니다. 아래로 재등록하세요:"
        log "        $0 service-install"
        return 1
    fi
    return 0
}

generate_service_file() {
    local script_path="$1"
    local target="$2"

    cat > "$target" <<EOF
[Unit]
Description=MariaDB Active-Standby Monitor
Documentation=file://${script_path}
After=network-online.target
Wants=network-online.target
ConditionPathExists=${CONFIG_FILE}
ConditionPathExists=${script_path}

[Service]
Type=simple
User=root
WorkingDirectory=${SCRIPT_DIR}
ExecStartPre=${script_path} wait-db
ExecStart=${script_path} __monitor_worker
Restart=on-failure
RestartSec=30
TimeoutStartSec=600
TimeoutStopSec=30
KillMode=mixed
StandardOutput=append:${SCRIPT_DIR}/logs/monitor.log
StandardError=append:${SCRIPT_DIR}/logs/monitor.log

[Install]
WantedBy=multi-user.target
EOF
}

service_install() {
    load_config

    local script_path="${SCRIPT_DIR}/$(basename "$0")"

    if [ ! -x "$script_path" ]; then
        log "[WARN] 스크립트에 실행 권한이 없어 부여합니다: ${script_path}"
        chmod +x "$script_path" 2>/dev/null || true
    fi

    if monitor_is_running; then
        log "[WARN] 수동으로 기동된 모니터링이 실행 중입니다 (PID $(cat "$PID_FILE"))."
        log "[WARN] 서비스와 중복 실행되지 않도록 먼저 중지합니다."
        monitor_stop || true
    fi

    mkdir -p "${SCRIPT_DIR}/logs"

    log "systemd 서비스 파일 생성: ${SERVICE_FILE}"
    generate_service_file "$script_path" "$SERVICE_FILE"

    local backup_copy="${SCRIPT_DIR}/config/${SERVICE_NAME}.service"
    generate_service_file "$script_path" "$backup_copy"
    log "복사본 저장: ${backup_copy}"

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"

    log "서비스 등록 완료"
    cat <<EOF

 등록된 서비스: ${SERVICE_NAME}.service

   시작   : systemctl start ${SERVICE_NAME}
   중지   : systemctl stop ${SERVICE_NAME}
   상태   : systemctl status ${SERVICE_NAME}
   로그   : tail -f ${SCRIPT_DIR}/logs/monitor.log

 부팅 시 자동 시작이 활성화되었습니다.
 지금 바로 시작하려면: systemctl start ${SERVICE_NAME}

EOF
}

service_uninstall() {
    load_config

    if [ ! -f "$SERVICE_FILE" ]; then
        log "[WARN] 등록된 서비스가 없습니다: ${SERVICE_FILE}"
        exit 0
    fi

    log "서비스 중지 및 등록 해제"
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    log "서비스 제거 완료"
}

rollback_finish() {
    load_config
    check_dependencies
    ensure_mariadb_running
    rollback_detect_context
    set +e

    if [ "$RB_ROLE" != "TEMP_ACTIVE" ]; then
        log "[ERROR] rollback-finish 는 승격되었던 서버(${DB_STANDBY_IP})에서 실행해야 합니다."
        log "[ERROR] 현재 서버: ${CURRENT_IP}"
        exit 1
    fi

    log "=========================================="
    log " 원복 마무리: 이 서버(${CURRENT_IP})를 Standby 로 복귀"
    log "=========================================="

    DB_ROOT_PASSWORD="$(resolve_root_password "${DB_ROOT_PASSWORD_ENC}")"
    REPL_PASSWORD="$(resolve_password "${REPL_PASSWORD_ENC}" "REPLICATION 계정(${REPL_USER}) 비밀번호")"
    MYSQL_BIN="$(resolve_bin "mysql")"

    log "[1/6] 상대 서버(${RB_PEER})가 Active 인지 확인"
    if ! peer_is_active "$RB_PEER"; then
        log "[ERROR] ${RB_PEER} 가 Active 로 동작하고 있지 않습니다 (상태: ${PEER_STATE})."
        log "[ERROR] 먼저 ${RB_PEER} 에서 rollback-switch 를 완료하세요."
        exit 1
    fi
    log "${RB_PEER} 가 Active 로 확인되었습니다."

    log "[2/6] 서비스 IP 보유 여부 확인"
    if vip_enabled && sub_ip_is_assigned; then
        log "[WARN] 이 서버가 아직 SUB_IP(${SUB_IP})를 들고 있어 회수합니다."
        detach_sub_ip
    fi

    log "[3/6] 쓰기 차단 (런타임 + my.cnf)"
    mysql_root "SET GLOBAL read_only = 1;"
    resolve_mycnf_path
    cp -f "$MYCNF_PATH" "${MYCNF_PATH}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    force_mycnf_kv "read_only" "1"

    log "[4/6] 복제 시작 위치 확인"
    local cur_pos
    cur_pos="$(mysql_root_out "SELECT @@GLOBAL.gtid_current_pos;" | tail -1)"
    if [ -z "$cur_pos" ]; then
        log "[ERROR] gtid_current_pos 를 조회하지 못했습니다."
        exit 1
    fi
    log "현재 위치: ${cur_pos}"
    log "이 서버는 전환 시점까지 ${RB_PEER} 와 동기화된 상태이므로 데이터 복원 없이 이어붙입니다."

    log "[5/6] Replication 연결 (${RB_PEER} 를 Master 로)"
    mysql_root "
        STOP SLAVE;
        RESET SLAVE ALL;
        SET GLOBAL gtid_slave_pos = '${cur_pos}';
        CHANGE MASTER TO
            MASTER_HOST='${RB_PEER}',
            MASTER_PORT=${DB_PORT},
            MASTER_USER='${REPL_USER}',
            MASTER_PASSWORD='${REPL_PASSWORD}',
            MASTER_USE_GTID=${GTID_MODE};
        START SLAVE;
    "

    sleep 3
    local slave_out
    slave_out="$(mysql_root_out "SHOW SLAVE STATUS\G")"
    echo "$slave_out" \
        | grep -E "Slave_IO_Running|Slave_SQL_Running|Last_IO_Error|Last_SQL_Error|Seconds_Behind_Master" \
        | while IFS= read -r l; do colorize_slave_status "$l"; done

    if ! diagnose_slave_error "$slave_out"; then
        log "[ERROR] Replication 이 정상 동작하지 않습니다."
        cat <<EOF

=====================================================
 위치가 맞지 않아 이어붙이기에 실패했을 수 있습니다.
 그런 경우에는 데이터를 새로 받아야 합니다.

 1) 이 서버의 예전 백업 정리
      rm -rf ${BACKUP_DIR}/rollback_*

 2) ${RB_PEER} 에서 새 백업 생성 및 전송
      ./$(basename "$0")

 3) 이 서버에서 복원
      ./$(basename "$0")
=====================================================

EOF
        exit 1
    fi

    log "[6/6] 상태 기록 및 모니터링 기동"
    set_role_state "normal"

    ROLE="STANDBY"
    if [ "$AUTO_START_MONITOR" == "yes" ] && command -v systemctl >/dev/null 2>&1; then
        if [ ! -f "$SERVICE_FILE" ]; then
            ( service_install ) || log "[WARN] 서비스 등록 실패"
        fi
        systemctl restart "${SERVICE_NAME}.service" 2>/dev/null || \
            systemctl start "${SERVICE_NAME}.service" 2>/dev/null || true
        sleep 2
        service_is_active && log "모니터링 기동 완료 (${SERVICE_NAME})"
    fi

    log "=========================================="
    log " 원복 완료 - 이중화가 복구되었습니다"
    log " ${RB_PEER} = Active / ${CURRENT_IP} = Standby"
    log "=========================================="
}

print_usage() {
    cat <<EOF

사용법: $0 [명령]

  (없음)          설치/구성 진행 (Active/Standby 자동 판별)
  init            저장된 ENC 비밀번호 초기화
  status          Replication 상태 확인
  check           헬스체크 1회 (Standby: Active 점검 / Active: 자가 점검)
  monitor-start   백그라운드 모니터링 시작
                  - Standby: Active 감시 (장애 시 승격 판단)
                  - Active : 자가 감시 (DB 장애 시 SUB_IP 자가 회수, VIP_MODE=yes 필요)
  monitor-stop    백그라운드 모니터링 중지
  monitor-status  모니터링 실행 여부 및 최근 로그 확인
  promote         이 서버를 Active로 승격 (Standby 전용, 확인 후 진행)

  [systemd 서비스 등록 - 부팅 시 모니터링 자동 시작]
  service-install    모니터링을 systemd 서비스로 등록
  service-uninstall  서비스 등록 해제
  wait-db            MariaDB 가 응답할 때까지 대기 (서비스가 내부적으로 사용)

  [원복 - 승격 이후 원래 구성으로 되돌리기]
  rollback-send     (현재 서비스 중인 서버에서) 백업 생성 후 상대 서버로 전송
  rollback-prepare  (구 Active 서버에서) 받은 백업으로 복원하고 Standby 로 편입
  rollback-switch   (구 Active 서버에서) 동기화 완료 후 서비스를 되돌림
  rollback-finish   (승격됐던 서버에서) Standby 로 복귀 · 데이터 복원 없이 연결

EOF
}

case "${1:-}" in
    init)
        load_config
        reset_enc_values
        ;;
    status)
        run_status_check
        ;;
    check)
        run_check_once
        ;;
    promote)
        run_promote
        ;;
    rollback-send)
        rollback_send
        ;;
    rollback-prepare)
        rollback_prepare
        ;;
    rollback-switch)
        rollback_switch
        ;;
    rollback-finish)
        rollback_finish
        ;;
    wait-db)
        wait_for_db
        ;;
    service-install)
        service_install
        ;;
    service-uninstall)
        service_uninstall
        ;;
    monitor-start)
        monitor_start
        ;;
    monitor-stop)
        load_config
        monitor_stop
        ;;
    monitor-status)
        load_config
        monitor_status
        ;;
    __monitor_worker)
        prepare_health_env
        if [ "$MONITOR_ROLE" == "ACTIVE" ]; then
            run_active_monitor_loop
        else
            run_monitor_loop
        fi
        ;;
    "")
        main
        ;;
    -h|--help|help)
        print_usage
        ;;
    *)
        log "[ERROR] 알 수 없는 명령: $1"
        print_usage
        exit 1
        ;;
esac