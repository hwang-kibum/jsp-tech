#!/usr/bin/env bash

set -euo pipefail0

# ============================================================
# 로그 삭제 스크립트
#
# 목적:
#   1) manager.2026-04-01 형태의 daemon 로그는 DAEMON_LOG_DAYS 기준 삭제
#   2) apcSync.log.2026-04-01 등 개별 로그는 INDIVIDUAL_LOG_DAYS 기준 삭제
#
# 주의:
#   - 현재 사용 중인 원본 로그 파일은 삭제하지 않도록 날짜 패턴이 붙은 파일만 대상으로 함
#   - 최초 테스트 시 DRY_RUN="true"로 두고 삭제 대상만 확인
# ============================================================

# 로그 파일이 있는 디렉토리
LOG_PATH="/app/logs/daemon"

# 로그 파일네임 suffix
LOG_DATE_PATTERN=".20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]"

# manager 로그 보관일
DAEMON_LOG_DAYS=14

# 개별 로그 보관일
INDIVIDUAL_LOG_DAYS=30

# manager 로그 파일명prefix
# 예: manager.2026-04-01
DAEMON_LOG_NAME="daemonLog.log$LOG_DATE_PATTERN"

# true  : 삭제하지 않고 대상만 출력
# false : 실제 삭제
DRY_RUN="true"

# 개별 로그 파일명 prefix 배열
INDIVIDUAL_LOG_NAME_ARRAY=(
    "apcSync.log"
    "assetRegulation.log"
    "assetSync.log"
    "daemonErrorLog.log"
    "fdr.log"
    "IpSecVpnSync.log"
    "nacSync.log"
    "netclientsSync.log"
    "performEvalScoreCalc.log"
    "performEvalTargetUser.log"
    "personalInfoHandler.log"
    "personnelSync.log"
    "stepDocuOutSync.log"
    "webmisSync.log"
)


# ------------------------------------------------------------
# 공통 검증
# ------------------------------------------------------------
validate_config() {
    if [[ ! -d "$LOG_PATH" ]]; then
        echo "ERROR: 로그 경로가 존재하지 않습니다: $LOG_PATH"
        exit 1
    fi

    if ! [[ "$DAEMON_LOG_DAYS" =~ ^[0-9]+$ ]]; then
        echo "ERROR: DAEMON_LOG_DAYS는 숫자여야 합니다: $DAEMON_LOG_DAYS"
        exit 1
    fi

    if ! [[ "$INDIVIDUAL_LOG_DAYS" =~ ^[0-9]+$ ]]; then
        echo "ERROR: INDIVIDUAL_LOG_DAYS는 숫자여야 합니다: $INDIVIDUAL_LOG_DAYS"
        exit 1
    fi
}

# ------------------------------------------------------------
# manager 로그 삭제
# ------------------------------------------------------------
daemon_delete_log() {
    echo "============================================================"
    echo "[daemon log] 패턴: $DAEMON_LOG_NAME"
    echo "[daemon log] 보관일: ${DAEMON_LOG_DAYS}일 초과"
    echo "============================================================"

    if [[ "$DRY_RUN" == "true" ]]; then
        find "$LOG_PATH" \
            -type f \
            -name "$DAEMON_LOG_NAME" \
            -mtime +"$DAEMON_LOG_DAYS" \
            -print
    else
        find "$LOG_PATH" \
            -type f \
            -name "$DAEMON_LOG_NAME" \
            -mtime +"$DAEMON_LOG_DAYS" \
            -print \
            -delete
    fi
}

# ------------------------------------------------------------
# 개별 로그 삭제
# ------------------------------------------------------------
individual_delete_log() {
    echo "============================================================"
    echo "[individual log] 보관일: ${INDIVIDUAL_LOG_DAYS}일 초과"
    echo "============================================================"

    for log_name in "${INDIVIDUAL_LOG_NAME_ARRAY[@]}"; do
        echo
        #echo "패턴 확인: $log_name"
        pattern="${log_name}${LOG_DATE_PATTERN}"
        echo "패턴 확인: $pattern"
        if [[ "$DRY_RUN" == "true" ]]; then
            find "$LOG_PATH" \
                -type f \
                -name "$pattern" \
                -mtime +"$INDIVIDUAL_LOG_DAYS" \
                -print
        else
            find "$LOG_PATH" \
                -type f \
                -name "$pattern" \
                -mtime +"$INDIVIDUAL_LOG_DAYS" \
                -print \
                -delete
        fi
    done
}

# ------------------------------------------------------------
# 실행
# ------------------------------------------------------------
echo "START: $(date '+%F %T')"
echo "LOG_PATH: $LOG_PATH"
echo "DRY_RUN: $DRY_RUN"
echo

validate_config
daemon_delete_log
individual_delete_log

echo
echo "END: $(date '+%F %T')"
