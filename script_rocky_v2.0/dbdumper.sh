#!/bin/bash
###################################################
#                global variables                 #
###################################################
#DB 계정정보
USER="root"
PW="Wlfks@09!@#"
host="localhost"

#DB Name
#DB_NM="test"
DB_NM="all"

#백업경로
BACKUP_DIR="/data/backup"

#예외 테이블 리스트
EXCLUDE_LIST=(
        miso.user_backup  #테이블 없음
		miso.user_login_log         #실제 파일
		miso.user_action_log
		
)
MY_CNF="/etc/my.cnf"
DATE=$(date +%Y-%m-%d)
###################################################
#                     function                    #
###################################################

backup(){
chkp=$(cat /etc/mydumper.cnf 2>/dev/null | grep -i "\[client\]")
if [ -z "$chkp" ]; then
	mkcnf
fi
	mkdir -p "$BACKUP_DIR"/"$DATE"/backup_struct
	mkdir -p "$BACKUP_DIR"/"$DATE"/backup_data
	mkdir -p "$BACKUP_DIR"/"$DATE"/log
> "$BACKUP_DIR/$DATE/log/mydumper_struct.log"
> "$BACKUP_DIR/$DATE/log/mydumper_data.log"
> "$BACKUP_DIR/$DATE/skip-tables.txt"
printf "%s\n" "${EXCLUDE_LIST[@]}" >> "$BACKUP_DIR"/"$DATE"/skip-tables.txt 
################################## struct
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
--regex '^(?!(information_schema\.|performance_schema\.|sys\.))' \
--outputdir="$BACKUP_DIR"/"$DATE"/backup_struct \
--no-data \
--compress \
--trx-tables=0 \
--set-names=utf8mb4 \
--events --triggers \
--logfile="$BACKUP_DIR"/"$DATE"/log/mydumper_struct.log \
--verbose=3 \
--clear
################################## data  
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
--no-schemas \
--threads=4 \
--rows=50000 \
--omit-from-file="$BACKUP_DIR"/"$DATE"/skip-tables.txt  \
--regex '^(?!(information_schema\.|performance_schema\.|sys\.))' \
--outputdir="$BACKUP_DIR"/"$DATE"/backup_data \
--compress \
--trx-tables=0 \
--set-names=utf8mb4 \
--events --routines --triggers \
--logfile="$BACKUP_DIR"/"$DATE"/log/mydumper_data.log \
--verbose=3 \
--clear  
  
}

loader() {
	if ! find "$BACKUP_DIR" -maxdepth 1 -type d | grep -qE '/[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
		echo "없음"
		exit 1
	fi
	
	chkp=$(cat /etc/mydumper.cnf 2>/dev/null | grep -i "\[client\]")
	if [ -z "$chkp" ]; then
		mkcnf
	fi
	check_date=$1
	if [ -z "$check_date" ]; then
		check_date=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort | tail -1)
	fi
	mkdir -p "$BACKUP_DIR"/"$DATE"/log
	> "$BACKUP_DIR/$DATE/log/myloader_struct.log"
	> "$BACKUP_DIR/$DATE/log/myloader_data.log"
	echo "start recover $check_date"
	myloader \
  --defaults-file=/etc/mydumper.cnf \
  --directory="$BACKUP_DIR"/"$check_date"/backup_struct \
  --threads=4 \
  --drop-database \
  --verbose=3 \
  --logfile="$BACKUP_DIR"/"$DATE"/log/myloader_struct.log 
	echo "struct recover done"
	
	myloader \
  --defaults-file=/etc/mydumper.cnf \
  --directory="$BACKUP_DIR"/"$check_date"/backup_data \
  --threads=4 \
  --verbose=3 \
  --logfile="$BACKUP_DIR"/"$DATE"/log/myloader_data.log 

}

mkcnf() {
tee /etc/mydumper.cnf > /dev/null << EOF
[client]
user=root
password=$PW
host=$host
port=3306

[mydumper]
ignore-engines=tokudb
set-names=utf8mb4
default-character-set=utf8mb4
less-locking=1
long-query-guard=120

[mydumper_session_variables]
CHARACTER_SET_RESULTS=NULL
EOF

cat /etc/mydumper.cnf
}

###################################################
#                   start script                  #
###################################################

if ! command -v mydumper &>/dev/null; then
        echo "install mydumper"
        exit 1
fi


usage() 
{
echo "================================================"
echo " Usage: $0 [option]"
echo "================================================"
echo " Options:"
sed -n '/case "\$1" in/,/esac/p' "$0" | \
grep -E '^\s+[a-zA-Z]{2,}\)' | \
grep -v '#' | \
awk -F')' '{gsub(/\t| /,"",$1); printf "  %-15s\n", $1}'
echo "================================================"
}
main()
{
	case "$1" in
		backup)
			backup
			;;
		recover)
			loader $2
			;;
		mkcnf)
            mkcnf
			;;
		 help|--help|-h)
			usage
			;;
		*)
			echo "Usage: $0 {backup|recover (yyyy-mm-dd)|help}"
			exit 0
			;;
	esac
}

main "$@"
