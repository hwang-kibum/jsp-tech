#!/bin/bash

#########property#########
backup_path="/tmp/backup"

directories="
/data/tomcat
/data/mariadb
/data/java
/data/ssl
"
files="
/etc/my.cnf
"
db_user='root'
db_passwd='wlfks@09!'
db_schema="
miso
miso_X
"
ignore_table="
miso.user_action_log
miso_X.user_action_logs
"
del_option=y         #y/n
remain_backupfiles=1 #Number of backup files before: X

#########property#########
path=''
file=''
DATE=$(date "+%Y-%m-%d")

disk_check() {
local item="$1"
disk_remain_mb=$(df -m "$backup_path" | awk 'NR==2 {gsub("%","",$5); print $4}')
file_mb=$(du -s --block-size=1M --exclude="$(readlink -f "$item")/*[lL][oO][gG][sS]*/*" --exclude="$(readlink -f "$item")/*[dD][aA][tT][aA]*/*" $(readlink -f "$item") 2>/dev/null | sort -r | head -n 1 | awk '{print $1}') # sort, head DB때문
if [ "$disk_remain_mb" -lt $((file_mb + 5000)) ];then
		echo "available disk : $disk_remain_mb MB"
		echo "file size : $file_mb MB"
        echo ${file_mb}"MB + 5GB not available disk"
        exit 0
fi
}

detect() {
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue  
		if [[ ! -e "$(readlink -f $item)" ]]; then
			echo "check $item"
			continue
		fi
		check=$(find "$(readlink -f "$item")" -maxdepth 1 \( -type d \( -iname "*logs*" -o -iname "*data*" \) -prune \) -o -mtime -1 -print -quit)
		if [[ -z "$check" ]]; then
			echo "same $item"
			continue
		fi
		echo "detect $item"
        backup_item "$item"
    done <<< "$directories"
	
	while IFS= read -r item; do
        [[ -z "$item" ]] && continue  
		if [[ ! -e "$(readlink -f $item)" ]]; then
			echo "check $item"
			continue
		fi
		check=$(find "$(readlink -f "$item")" -maxdepth 1 \( -type d \( -iname "*logs*" -o -iname "*data*" \) -prune \) -o -mtime -1 -print -quit)
		if [[ -z "$check" ]]; then
			echo "same $item"
			continue
		fi
		echo "detect $item"
        backup_item "$item"
    done <<< "$files"
}

split() {
	path=''
	file=''
	local input="$1"
	path="${input%/*}"
    file="${input##*/}"
}

backup_item() {
    local item="$1"
	if [[ ! -e "$(readlink -f $item)" ]]; then
		echo "check $item"
		return
	fi
	#### disk check
	disk_check $item
	
    echo "backup start : $item -> $backup_path"
	backup_file=$(readlink -f $item)
	path=''
	file=''
	split "$backup_file"
		
	if [[ $del_option == "y" || $del_option == "Y" ]]; then
		find "$backup_path" -name "${file}*.tar.gz" | sort -r | tail -n +$(($remain_backupfiles + 1)) | xargs -r rm -v
	fi
	tar -C "$path" --exclude="$file/*[lL][oO][gG][sS]*/*" --exclude="$file/*[dD][aA][tT][aA]*/*" -zcvf "${backup_path}/${file}_$(date +%F_%H%M%S).tar.gz" "$file" >/dev/null 2>&1	
	echo "backup end : $item "
}

backup_schema () {
    local item=()
    if [[ -z "$1" ]]; then
        item=($db_schema)
    else
        item=("$1")
    fi
	if ! command -v mysqldump >/dev/null 2>&1; then
        echo "Error: mysqldump is not installed."
        exit 0
    fi
    start_date=$(date +%F_%H%M%S)
	for table in $ignore_table; do
		[[ -z "$table" ]] && continue   
		IGNORE_TABLES+=" --ignore-table=$table"
	done

    for schema in "${item[@]}"; do
        echo "Backing up schema: $schema"
		disk_check ${backup_path}/${schema}_data_*.sql
		if [[ $del_option == "y" || $del_option == "Y" ]]; then
			find "$backup_path" -name "${schema}_schema_*.sql" | sort -r | tail -n +$(($remain_backupfiles + 1)) | xargs -r rm -v
			find "$backup_path" -name "${schema}_data_*.sql" | sort -r | tail -n +$(($remain_backupfiles + 1)) | xargs -r rm -v
		fi
		#struct
		mysqldump -u$db_user -p$db_passwd --no-data --databases --single-transaction --lock-tables=false $schema > ${backup_path}/${schema}_schema_${start_date}.sql
		#data
		mysqldump -u$db_user -p$db_passwd --no-create-info --single-transaction --lock-tables=false $IGNORE_TABLES $schema > ${backup_path}/${schema}_data_${start_date}.sql
    done
}

main() {
	#### backup path check
	if [ ! -d "${backup_path}" ]; then
		echo "${backup_path} not found"
		exit 0
	fi
	echo "##################################"
	echo "$DATE is running"
	#### detect mode
	if [[ "$1" == "detect" ]]; then
		detect
		exit 0
	fi
	#### auto DB mode
	if [[ "$1" == "db" ]]; then
		if [[ -z "$db_passwd" ]]; then
			echo "check db passwd"
			exit 0
		fi
		backup_schema
		exit 0
	fi
    echo "D : Directory, F : File, S : Schema"
	echo "##################################"
    count=1
    declare -A item_map
    
    for dir in $directories; do
        printf "%2d. (%s) %-20s %s\n" "$count" "D" "$dir" "backup"
        item_map[$count]="$dir"
		item_map_type[$count]="D"
        ((count++))
    done
    
    for f in $files; do
        printf "%2d. (%s) %-20s %s\n" "$count" "F" "$f" "backup"
        item_map[$count]="$f"
		item_map_type[$count]="F"
        ((count++))
    done
	
	for db in $db_schema; do
        printf "%2d. (%s) %-20s %s\n" "$count" "S" "$db" "backup"
        item_map[$count]="$db"
		item_map_type[$count]="S"
        ((count++))
    done
	
    printf "%2d. %-24s %s\n" 0 "Exit" ""
    echo "##################################"

	while true; do
		read -p "Choose number: " sel
		[[ -z "$sel" ]] && { echo "번호를 입력하세요."; continue; }
		if [[ "$sel" == "0" ]]; then
			echo "exit"
			break
		elif [[ -n "${item_map[$sel]-}" ]]; then
			type="${item_map_type[$sel]}"   

			if [[ "$type" == "S" ]]; then
				backup_schema "${item_map[$sel]}"
			else
				backup_item "${item_map[$sel]}"
			fi
		else
			echo "wrong number."
		fi
	done

}

main "$@"
