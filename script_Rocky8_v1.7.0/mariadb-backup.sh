#!/bin/bash
###################################################
#                global variables                 #
###################################################
#DB 계정정보
USER="USER"
PW="PASSWORD"
#DB Name
DB_NM="miso"

#mariadb Basedir
MARIADB="/data/mariadb"
#백업경로
BACKUP_DIR="/backup"

#LOG remove day
LOG_REMOVE_DAYS=60

#예외 테이블 리스트
EXCLUDE_LIST=(
        "${DB_NM}.exclude_table1"
        "${DB_NM}.exclude_table2"
        "${DB_NM}.exclude_table3"
)
EXCLUDE_PATTERN=$(printf "|%s" "${EXCLUDE_LIST[@]}")
EXCLUDE_PATTERN=${EXCLUDE_PATTERN:1} # 맨 앞의 '|' 제거

#예외 테이블중 구조만 백업받을 리스트
STRUCTURE_ONLY_LIST=(
        "exclude_table1"
        "exclude_table2"
        "exclude_table3"
)
STRUCTURE_TABLE_STR="${STRUCTURE_ONLY_LIST[*]}"
MY_CNF="/etc/my.cnf"

###################################################
#                const variables                  #
###################################################
#년-월-일
DATE=$(date +%Y-%m-%d)
#요일 확인  0=Sunday ... 6=Saturday
ASDOW=$(TZ=Asia/Seoul date +%w)
# 마지막 백업 번호 찾기 (0-6)
LAST_NUM=$(find ${BACKUP_DIR}/INC -mindepth 1 -maxdepth 1 -type d -name '[0-6]' 2>/dev/null | \
           grep -oE '[0-6]$' | sort -n | tail -n1)

#로그 경로
LOG_DIR="$BACKUP_DIR/logs"

#로그파일
LOG="${LOG_DIR}/backup_$DATE.log"


###################################################
#                     function                    #
###################################################
# 로그 디렉토리 정리 함수
function log_file_remove() {
    if [ -d "${LOG_DIR}" ]; then
        echo "log_file_remove ${LOG_DIR} " >> "$LOG"
        find ${LOG_DIR}/* -type f -mtime +${LOG_REMOVE_DAYS} -exec rm -rf {} \;
    fi
}

# 7일 주기 삭제 함수 (logs 디렉토리 보호)
function cycle_seven_days_delete(){
    echo "Cleaning up old backups (keeping logs directory)..." >> "$LOG"
    find "$BACKUP_DIR/INC/" -mindepth 1 -maxdepth 1 -type d ! -name "logs" -exec rm -rf {} +
    echo "Cleanup completed" >> "$LOG"
}

# 예외 테이블중 구조백업필요한 경우
function structure_backup(){
    # 리스트가 0보다 커야한다.
    if [ ${#STRUCTURE_ONLY_LIST[@]} -gt 0 ]; then
        echo "dumping structure for table: ${STRUCTURE_ONLY_LIST[*]}" >> "${LOG}"
        "$MARIADB/bin/mariadb-dump" -u"$USER" -p"$PW" \
                --single-transaction \
                --lock-tables=false \
                --no-data \
                "${DB_NM}" "${STRUCTURE_ONLY_LIST[@]}" > "${BACKUP_DIR}/INC/no_data_structure_tables.sql"
        if [ $? -eq 0 ]; then
                    echo "Structure dump successful" >> "${LOG}"
        else
                    echo "ERROR: Structure dump failed. Check table names." >> "${LOG}"
        fi
    else
        echo "no specific tables defined for structure backup. skipping" >> "${LOG}"
    fi
}

#my.cnf 백업.
function my_cnf_backup(){
        if [ -f "${MY_CNF}" ]; then
                cp ${MY_CNF} "${BACKUP_DIR}/INC/my.cnf"
        fi
}

# 전체 백업 함수
function full_backup() {
    echo "========================================" >> "$LOG"
    echo "Starting Full Backup: $DATE" >> "$LOG"

    # 전체 백업
    "$MARIADB/bin/mariadb-backup" \
        --backup \
        --no-lock \
        --user="$USER" \
        --password="$PW" \
        --tables-exclude="${EXCLUDE_PATTERN}" \
        --target-dir="${BACKUP_DIR}/INC/0/" \
        --binlog-info=ON 2>>"$LOG"

    # mariadb-backup 명령어 $? 성공=0, 실패=1...
    if [ $? -eq 0 ]; then
        echo "Full backup successful" >> "$LOG"
    else
        echo "ERROR: Full backup failed" >> "$LOG"
        exit 1
    fi

    # 예외 테이블 DDL 백업
    structure_backup

    # my.cnf 백업
    my_cnf_backup

    echo "Full Backup Completed: $DATE" >> "$LOG"
    echo "========================================" >> "$LOG"
}

# 증분 백업 함수
function incremental_backup() {
    # 앞전 마지막으로 백업한 베이스 디렉토리
    local base_dir="$1"
    # 현재 백업할 디렉토리
    local target_dir="$2"

    echo "========================================" >> "$LOG"
    echo "Starting Incremental Backup: $DATE - Day $ASDOW" >> "$LOG"
    echo "Base directory: $base_dir" >> "$LOG"
    echo "Target directory: $target_dir" >> "$LOG"

    # 증분 백업
    "$MARIADB/bin/mariadb-backup" --backup \
        --no-lock \
        --user="$USER" \
        --password="$PW" \
        --tables-exclude="${EXCLUDE_PATTERN}" \
        --incremental-basedir="$base_dir" \
        --target-dir="$target_dir" \
        --binlog-info=ON 2>>"$LOG"

    # mariadb-backup 명령어 $? 성공=0, 실패=1...
    if [ $? -eq 0 ]; then
        echo "Incremental backup successful" >> "$LOG"
    else
        echo "ERROR: Incremental backup failed" >> "$LOG"
        exit 1
    fi

    echo "Incremental Backup Completed: $DATE - Day $ASDOW" >> "$LOG"
    echo "========================================" >> "$LOG"
}

# 디렉토리 확인 및 생성
function check_create_dir(){
# 파리미터 로 받은 패스가 디렉토리가 아니면 생성.
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
        echo "Created directory: $1" >> "$LOG"
    fi
}

###################################################
#                   start script                  #
###################################################

# 초기 디렉토리 생성
check_create_dir "$LOG_DIR"
check_create_dir "$BACKUP_DIR/INC"

# 백업 시작 로그
echo "" >> "$LOG"
echo "========================================" >> "$LOG"
echo "Backup process started at: $DATE" >> "$LOG"
echo "Day of the week: $ASDOW (0=Sunday)" >> "$LOG"
echo "Last backup number: ${LAST_NUM:-None}" >> "$LOG"

# 요일별 백업 처리
case $ASDOW in
    0)  # Sunday - Full Backup
        echo "Sunday detected - Performing full backup" >> "$LOG"

        # 기존 백업 모두 삭제
        cycle_seven_days_delete

        # 0번 디렉토리 생성 및 전체 백업
        check_create_dir "${BACKUP_DIR}/INC/0"
        full_backup
        log_file_remove
        ;;

    1|2|3|4|5|6)  # 월요일(1) ... 토요일(6) - 증분백업
        if [ -z "$LAST_NUM" ]; then
            # 이전 백업이 없으면 전체 백업 수행
            echo "previous backup not found. Performing full backup." >> "$LOG"
            cycle_seven_days_delete
            check_create_dir "${BACKUP_DIR}/INC/0"
            full_backup
            log_file_remove
        else
            # 증분 백업 수행
            echo "Previous backup found: $LAST_NUM" >> "$LOG"

            LAST_BACKUP="${BACKUP_DIR}/INC/${LAST_NUM}"
            CURRENT_BACKUP="${BACKUP_DIR}/INC/${ASDOW}"

            # 백업 디렉토리 존재 확인
            if [ ! -d "$LAST_BACKUP" ]; then
                echo "ERROR: Last backup directory not found: $LAST_BACKUP" >> "$LOG"
                echo "Performing full backup instead." >> "$LOG"
                cycle_seven_days_delete
                check_create_dir "${BACKUP_DIR}/INC/0"
                full_backup
                log_file_remove
            else
                check_create_dir "$CURRENT_BACKUP"
                incremental_backup "$LAST_BACKUP" "$CURRENT_BACKUP"
                log_file_remove
            fi
        fi
        ;;

    *)
        echo "ERROR: Invalid day of week: $ASDOW" >> "$LOG"
        exit 1
        ;;
esac

echo "Backup process finished at: $(date +%Y-%m-%d\ %H:%M:%S)" >> "$LOG"
echo "========================================" >> "$LOG"
echo "" >> "$LOG"
