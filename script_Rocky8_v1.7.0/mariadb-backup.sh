#!/bin/bash

USER="root"
PW="Wlfks@09!@#"

DB_NM="miso"
EX_TABLE="${DB_NM} mail_send"
EXCLUDE_1="${DB_NM}.mail_send"
EXCLUDE_2=""
EXCLUDE_3=""
EXCLUDE_4=""
EXCLUDE_5=""
EXCLUDE_6=""
CORE=2

DATE=$(date +%Y-%m-%d)
ASDOW=$(TZ=Asia/Seoul date +%w) # 0=Sunday ... 6=Saturday

DATA="/data/mariadbData"
MARIADB="/data/mariadb"
BACKUP_DIR="/data/backup"
LOG_DIR="$BACKUP_DIR/logs"
LOG="$LOG_DIR/backup_$DATE.log"

# 마지막 백업 번호 찾기 (0-6)
LAST_NUM=$(find /data/backup/INC/ -mindepth 1 -maxdepth 1 -type d -name '[0-6]' 2>/dev/null | \
           grep -oE '[0-6]$' | sort -n | tail -n1)

# 7일 주기 삭제 함수 (logs 디렉토리 보호)
function cycle_seven_days_delete(){
    echo "Cleaning up old backups (keeping logs directory)..." >> "$LOG"
    find "$BACKUP_DIR/INC/" -mindepth 1 -maxdepth 1 -type d ! -name "logs" -exec rm -rf {} +
    echo "Cleanup completed" >> "$LOG"
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
        --tables-exclude="$EXCLUDE_1" \
        --target-dir="${BACKUP_DIR}/INC/0/" \
        --binlog-info=ON 2>>"$LOG"

    if [ $? -eq 0 ]; then
        echo "Full backup successful" >> "$LOG"
    else
        echo "ERROR: Full backup failed" >> "$LOG"
        exit 1
    fi
    
    # 예외 테이블 DDL 백업
    "$MARIADB/bin/mariadb-dump" -u"$USER" -p"$PW" \
        --single-transaction \
        --lock-tables=false \
        --no-data $EX_TABLE > "${BACKUP_DIR}/INC/${EXCLUDE_1}_structure.sql"

    # my.cnf 백업
    cp /etc/my.cnf "${BACKUP_DIR}/INC/my.cnf"

    echo "Full Backup Completed: $DATE" >> "$LOG"
    echo "========================================" >> "$LOG"
}

# 증분 백업 함수
function incremental_backup() {
    local base_dir="$1"
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
        --tables-exclude="$EXCLUDE_1" \
        --incremental-basedir="$base_dir" \
        --target-dir="$target_dir" \
        --binlog-info=ON 2>>"$LOG"

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
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
        echo "Created directory: $1" >> "$LOG"
    fi
}

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
        ;;

    1|2|3|4|5|6)  # Monday to Saturday - Incremental Backup
        if [ -z "$LAST_NUM" ]; then
            # 이전 백업이 없으면 전체 백업 수행
            echo "No previous backup found. Performing full backup." >> "$LOG"
            cycle_seven_days_delete
            check_create_dir "${BACKUP_DIR}/INC/0"
            full_backup
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
            else
                check_create_dir "$CURRENT_BACKUP"
                incremental_backup "$LAST_BACKUP" "$CURRENT_BACKUP"
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


