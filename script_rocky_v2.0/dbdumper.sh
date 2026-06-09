#!/bin/bash
###################################################
#                global variables                 #
###################################################
#DB 계정정보
#USER="root"
#PW="test@09!@#"

#DB Name
#DB_NM="test"
DB_NM="all"

#백업경로
BACKUP_DIR="/data/backup"

#예외 테이블 리스트
EXCLUDE_LIST=(
        test.user_bak
        test.user_backup
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
> "$BACKUP_DIR/$DATE/skip-tables.txt"
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
--regex '^(?!(information_schema\.|performance_schema\.|sys\.))' \
--outputdir="$BACKUP_DIR"/"$DATE"/backup \
--compress \
--trx-tables=0 \
--set-names=utf8mb4 \
--events --routines --triggers \
--skip-definer \ 
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

loader() {
	if ! find "$BACKUP_DIR" -maxdepth 1 -type d | grep -qE '/[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
		echo "없음"
		exit 1
	fi
	
	check_date=$1
	if [ -z "$check_date" ]; then
		check_date=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort | tail -1)
	fi
	mkdir -p "$BACKUP_DIR"/"$DATE"/log
	> "$BACKUP_DIR/$DATE/log/myloader.log"
	
	myloader \
  --defaults-file=/etc/mydumper.cnf \
  --directory="$BACKUP_DIR"/"$check_date"/backup \
  --threads=1 \
  --drop-table \
  --logfile="$BACKUP_DIR"/"$DATE"/log/myloader.log 
	
	if [ $? -ne 0 ]; then
		echo "check "$BACKUP_DIR"/"$DATE"/log/myloader.log"
		exit 1
	fi	
}

mkcnf() {
        cp /etc/mydumper.cnf /etc/mydumper.cnf.ori
        cat /dev/null > /etc/mydumper.cnf
        read -s -p "mariadb pw: " USER_PW
        echo ""
        echo "[client]
user=root
password=$USER_PW
host=127.0.0.1
port=3306

[mydumper]
ignore-engines=tokudb
set-names=utf8mb4
default-character-set=utf8mb4
less-locking=1
long-query-guard=120

[mydumper_session_variables]
CHARACTER_SET_RESULTS=NULL" > /etc/mydumper.cnf

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
		 help|--help|-h)
			usage
			;;
		mkcnf)
            mkcnf
			;;

		*)
			echo "Usage: $0 {backup|recover (yyyy-mm-dd)|help}"
			exit 0
			;;
	esac
}

main "$@"
