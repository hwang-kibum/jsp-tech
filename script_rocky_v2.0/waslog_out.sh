# was 로그 추출 스크립트

#!/bin/bash

START_TIME=$(date '+%Y/%m/%d %H:%M')
START_DIR=$(date '+%Y%m%d_%H%M')
FROM_TIME=$(date -d '11 minutes ago' '+%Y/%m/%d %H:%M')

separation() {
file_path=$1
file_name=$(basename "$file_path")
file_type=$(dirname "$file_path" | xargs basename)
mkdir -p /tmp/misolog_"$START_DIR"/"$file_type"
tail -5000 "$file_path" | \
awk -v from="$FROM_TIME" '
match($0,/[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}/) {
    ts=substr($0,RSTART,RLENGTH)
    if (ts >= from)
        print
}' > /tmp/misolog_"$START_DIR"/"$file_type"/"$file_name"
}

find_setting(){

tomcat_pid=$(ss -antp | grep -E ":$1\s" | grep -i listen | head -n 1 | awk -F'pid=' '{print $2}' | awk -F',' '{print $1}')
tomcat_home=$(ps -ef | grep "$tomcat_pid" | sed -n 's/.*config\.file=\(.*\)\/conf\/logging\.properties.*/\1/p')
webapps_path=$(grep -rE 'path=\"/\".*docBase=' "$tomcat_home"/conf/server.xml | grep -v '<!--' | cut -d '=' -f3 | awk '{print $1}' | sed -e 's/\"//g')
if [ -z $webapps_path ]; then
	webapps_path="$tomcat_home"/webapps/ROOT
fi

log_type=$(cat "$webapps_path"/WEB-INF/classes/logback.properties | grep -i ^log_output_type | awk -F"=" '{print $2}'| xargs) 
log_home=$(cat "$webapps_path"/WEB-INF/classes/logback.properties | grep -i ^LOG_HOME | awk -F"=" '{print $2}'| xargs) 

if [ $log_type = "console" ]; then
	log_file=$(ls -l /proc/"$tomcat_pid"/fd/1 2>/dev/null | awk '{print $NF}')
	if [ $? -ne 0 ] || [ -z "$log_file" ]; then
		echo "tomcat log file not found"
		exit 1
	fi
	separation "$log_file"
elif [ $log_type = "file" ]; then
	log_file1="$log_home"/info/misolog.log
	separation "$log_file1"
	log_file2="$log_home"/error/misolog.log
	separation "$log_file2"
else
	echo "check tomcat log path"
	exit 1
fi

if [ -n "$(ls -A /tmp/misolog_"$START_DIR" 2>/dev/null)" ]; then
    echo "########compressing log########"
	tar -czvf misolog_"$START_DIR".tar.gz --remove-files -C /tmp misolog_"$START_DIR"
else
    echo "/tmp/misolog_"$START_DIR" 비어있음"
fi

}

if [ "$#" -eq 1 ]; then
	find_setting $1
	exit 0
else
    echo "how to use >> $0 web_port"
    exit 0
fi