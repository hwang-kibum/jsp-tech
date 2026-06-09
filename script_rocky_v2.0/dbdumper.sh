#!/bin/bash
###################################################
#                global variables                 #
###################################################
#DB 계정정보
USER="root"
PW="Wlfks@09!@#"

#DB Name
#DB_NM="miso"
DB_NM="all"

#백업경로
BACKUP_DIR="/data/backup"

#예외 테이블 리스트
EXCLUDE_LIST=(
        miso.user_bak
        miso.user_backup
)
MY_CNF="/etc/my.cnf"
DATE=$(date +%Y-%m-%d)
###################################################
#                     function                    #
###################################################

backup(){
	mkdir -p "$BACKUP_DIR"/"$DATE"/backup
	mkdir -p "$BACKUP_DIR"/"$DATE"/log
	mkdir -p "$BACKUP_DIR"/"$DATE"/exclude_tables
> "$BACKUP_DIR/$DATE/log/mydumper.log"
> "$BACKUP_DIR/$DATE/exclude_tables/skip-tables.txt"
printf "%s\n" "${EXCLUDE_LIST[@]}" >> "$BACKUP_DIR"/"$DATE"/skip-tables.txt 

systemd-run \
--scope \
--unit=mydumper-final \
-p CPUQuota=200% \
-p CPUWeight=50 \
-p MemoryHigh=1G \
-p MemoryMax=2G \
-p MemorySwapMax=0 \
-p IOWeight=50 \
mydumper \
--defaults-file=/etc/mydumper.cnf \
$( [ "$DB_NM" != "all" ] && echo "--database=$DB_NM" ) \
--threads=4 \
--rows=50000 \
--omit-from-file="$BACKUP_DIR"/"$DATE"/skip-tables.txt  \
--outputdir="$BACKUP_DIR"/"$DATE"/backup \
--compress \
--trx-tables=0 \
--set-names=utf8mb4 \
--events --routines --triggers \
--logfile="$BACKUP_DIR"/"$DATE"/log/mydumper.log \
--verbose=3 \
--clear

if [ $? -ne 0 ]; then
    echo "check "$BACKUP_DIR"/"$DATE"/log/mydumper.log"
	exit 1
fi

TABLES=$(paste -sd, "$BACKUP_DIR"/"$DATE"/skip-tables.txt)

mydumper \
  --tables-list="$TABLES" \
  --no-data \
  --outputdir="$BACKUP_DIR"/"$DATE"/exclude_tables \
  --logfile="$BACKUP_DIR"/"$DATE"/log/mydumper_exclude.log \
  --clear

}

###################################################
#                   start script                  #
###################################################

if [ -z $(command -v mydumper) ]; then
        echo "install mydumper"
        exit 1
fi


backup

