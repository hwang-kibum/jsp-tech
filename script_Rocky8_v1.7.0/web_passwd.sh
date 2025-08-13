#!/bin/bash

check_id(){
if [ -z $1 ]; then
	echo "use >> $0 WEB_ID WEB_PORT"
	exit 0
fi
}

find_tomcat_path(){
##find tomcat port
passwd=''
tomcat_port=($1)
for port in "${tomcat_port[@]}"; do
#echo $port
passwd=$(curl -k -m 5 https://127.0.0.1:"$port"/system/user/getEncPassword.do  2>/dev/null | grep -i enc | cut -d ':' -f2 | sed 's/^[ \t]*//')
if [ ! -z $passwd ]; then
	break
fi
passwd=$(curl -k -m 5 http://127.0.0.1:"$port"/system/user/getEncPassword.do  2>/dev/null | grep -i enc | cut -d ':' -f2 | sed 's/^[ \t]*//')
if [ ! -z $passwd ]; then
	break
fi

done

if [ -z $passwd ]; then
	echo "check tomcat path or process"
	exit 0
fi
#echo $passwd
}

find_webapps_path(){
##find miso_webapps_path
tomcat_home=$(ps -ef | grep $(netstat -antp | grep -w "$1" | grep -i listen | head -n 1 | awk -F " " '{print $7}' | awk -F "/" '{print $1}') | sed -n 's/.*config\.file=\(.*\)\/conf\/logging\.properties.*/\1/p')
if [ -z $tomcat_home ]; then
	echo "check tomcat_path"
	exit 0
fi
webapps_path=$(grep -rE 'path=\"/\".*docBase=' "$tomcat_home"/conf/server.xml | cut -d '=' -f3 | awk '{print $1}' | sed -e 's/\"//g')
#echo $webapps_path

if [ -z $webpass_path ]; then
	webapps_path="$tomcat_home"/webapps/ROOT
fi
}

find_db_info(){
##find DB_info
DB_user=$(grep -r ^miso.db.user "$webapps_path"/WEB-INF/classes/properties/system.properties | cut -d '=' -f2)
DB_passwd=$(grep -r ^miso.db.password "$webapps_path"/WEB-INF/classes/properties/system.properties | cut -d '=' -f2)
DB_name=$(grep -r ^miso.db.url "$webapps_path"/WEB-INF/classes/properties/system.properties | cut -d '=' -f2 | awk -F "/" '{print $4}' | awk -F "?" '{print$1}')
DB_IP=$(grep -r ^miso.db.url "$webapps_path"/WEB-INF/classes/properties/system.properties |  awk -F "//" '{print $2}' | awk -F ":" '{print$1}')

}

db_query(){
echo "###################################################"
if [[ "$DB_IP" == "localhost" || "$DB_IP" == "127.0.0.1" ]]; then
	check_id=$(mysql -u$DB_user -p$DB_passwd $DB_name -Bse "select USER_ID from user where USER_ID='$1'")
	check_id2=$(mysql -u$DB_user -p$DB_passwd $DB_name -Bse "select EMP_ID from cms_partner_emp where EMP_ID='$1'")
	if [ ! -z $check_id ]; then
		mysql -u$DB_user -p$DB_passwd $DB_name -Bse "update user set PASSWORD = '$passwd', PWD_CHANGE_DT = now(), INSERT_DT = now(), ACCT_STATE_CD='U' where USER_ID = '$1'"
		echo "'$DB_name'.'$1' change passwd"
	elif [ ! -z $check_id2 ]; then
		mysql -u$DB_user -p$DB_passwd $DB_name -Bse "update cms_partner_emp set EMP_PASSWORD = '$passwd', PWD_CHANGE_DT = now(), INSERT_DT = now(), ACCT_STATE_CD='U', LOGIN_YN='Y' where EMP_ID = '$1'"
		echo "'$DB_name'.'$1' change passwd"
	fi

else
	echo "update $DB_name.user set PASSWORD = '$passwd', ACCT_STATE_CD='U' where USER_ID = '$1';"
fi
echo "###################################################"
}

if [ "$#" -eq 2 ]; then
	check_id $1
	find_tomcat_path  $2
	find_webapps_path $2
	find_db_info
	db_query $1
	exit 0
else
    echo "how to use >> ./webpasswd.sh web_id web_port"
    exit 0
fi