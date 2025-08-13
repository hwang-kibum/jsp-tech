#!/bin/bash
source 00.util_Install_latest
SCRIPTLOGFILE=miso_recover.log
exec > >(tee -a "$SCRIPTLOGFILE") 2>&1
echo $DATE" is running" >> ${SCRIPTLOGFILE}
nohup bash -c "sleep 300; cat /dev/null > "${SCRIPTLOGFILE} > /dev/null 2>&1 &

input_date=0
dateckp=0
dbckp=0
LOOPBACK=127.0.0.1

find_file_date()
{
read -p "what recover file date (YYYY-MM-DD): " input_date

if [[ $input_date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
	dateckp=1
else
    echo "incorrect date insert YYYY-MM-DD "
	exit 0
fi
}
miso_recover()
{
if [ "${dateckp}" == "0" ]; then
	find_file_date
fi
echo "#### "$1" recover start"
if [ ! -d "${miso_path}" ]; then
	sudo mkdir -p ${miso_path}
fi
if [ -d "${miso_path}/$1" ]; then
	echo $1" already exist"
	read -p ${miso_path}"/"$1" mv "${miso_path}"/"$1".ori : yes(enter key) or no(n key) : >" RET
	if [ "${RET}" == "n" ]; then
		echo "please mv "$1" dir"
		return 0
	else
		echo "mv file"
		sudo mv ${miso_path}/$1 ${miso_path}/$1.ori
		echo "mv file done"		
	fi
fi
# 임시 디렉토리 생성
sudo mkdir -p ${miso_path}/tmp
TMP=$(ls -alr ${local_backup_path}/miso/$1/ | grep -i ${input_date} | awk '{print $9}')
lastfile=$(ls -alr ${local_backup_path}/miso/$1/ | grep -i $1 | awk '{print $9}' | head -n 1)
lastfiledate=$(ls -alr ${local_backup_path}/miso/$1/ | grep -i $1 | awk '{print $9}' | head -n 1 | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}')

#tmp 변수내 값이 없으면 lastfile 로 진행 여부 판단
if [ -z "${TMP}" ]; then
	echo ${input_date}" is not exist.   "${lastfile}" is last backup file"
	read -p ${lastfile}" restore : y(enter key) or n (exit) >" RET
	case $RET in
	n)
	echo "check file name"
	exit 0
	;;
	y)
	input_date=${lastfiledate}
	sudo cp -rf ${local_backup_path}/miso/$1/*${input_date}* ${miso_path}/tmp
	;;
	*)
	input_date=${lastfiledate}
	sudo cp -rf ${local_backup_path}/miso/$1/*${input_date}* ${miso_path}/tmp
	;;
	esac
else
     sudo cp -rf ${local_backup_path}/miso/$1/*${input_date}* ${miso_path}/tmp
fi

cd ${miso_path}/tmp&&sudo cat *${input_date}* | sudo tee tmp.tar.gz > /dev/null&&sudo tar -xzf tmp.tar.gz
sudo mv $1 ../.&&chown -R {SERV_USER}:{SERV_USER} $1 &&cd -
sudo rm -rf ${miso_path}/tmp
echo "#### "$1" recover end"
#### 설정값 server.xml 할지 말지
#### 이미 백업을 받았으므로 properites 는 유지
if [ "$1" == "webapps" ]; then
	echo "####check server.xml"
	check=$(sudo grep -r "docBase=\"${miso_path}/webapps\"" ${tomcat_path}/conf/server.xml)
	if [ -z "${check}" ]; then
		echo "insert command server.xml"
		sudo sed -i'' -r -e '/unpackWARs=/a\<Context path="/" docBase="'${miso_path}'/webapps" reloadable="true"/>' ${tomcat_path}/conf/server.xml
	fi
fi

}

dbdata_recover()
{
if [ "${dateckp}" == "0" ]; then
	find_file_date
fi
echo "#### dbdata recover start"
if [ ! -d "${db_path}" ]; then
	echo ${db_path}" not exist"
	exit 0
fi
sudo mkdir -p ${db_path}/tmpdir

if [ "$1" == "-full" ]; then
	TMP=$(ls -alr ${local_backup_path}/dbdump/ | grep -i fullbackup_${input_date} | awk '{print $9}')
	lastfile=$(ls -alr ${local_backup_path}/dbdump/ | grep -i fullbackup | awk '{print $9}' | head -n 1)
	lastfiledate=$(ls -alr ${local_backup_path}/dbdump/ | grep -i fullbackup | awk '{print $9}' | head -n 1 | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}')
	if [ -z "${TMP}" ]; then
		echo ${input_date}" is not exist.   "${lastfile}" is last backup file"
		read -p ${lastfile}" restore : y(enter key) or n (exit) >" RET
		case $RET in
		n)
		echo "check file name"
		exit 0
		;;
		y)
		input_date=${lastfiledate}
		sudo cp -rf ${local_backup_path}/dbdump/fullbackup_${input_date}* ${db_path}/tmpdir
		;;
		*)
		input_date=${lastfiledate}
		sudo cp -rf ${local_backup_path}/dbdump/fullbackup_${input_date}* ${db_path}/tmpdir
		;;
		esac
	fi
else
	TMP=$(ls -alr ${local_backup_path}/dbdump/ | grep -i ${DB_NAME}_${input_date} | awk '{print $9}')
	lastfile=$(ls -alr ${local_backup_path}/dbdump/ | grep -i ${DB_NAME} | awk '{print $9}' | head -n 1)
	lastfiledate=$(ls -alr ${local_backup_path}/dbdump/ | grep -i ${DB_NAME} | awk '{print $9}' | head -n 1 | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}')
	if [ -z "${TMP}" ]; then
		echo ${input_date}" is not exist.   "${lastfile}" is last backup file"
		read -p ${lastfile}" restore : y(enter key) or n (exit) >" RET
		case $RET in
		n)
		echo "check file name"
		exit 0
		;;
		y)
		input_date=${lastfiledate}
		sudo cp -rf ${local_backup_path}/dbdump/${DB_NAME}_${input_date}* ${db_path}/tmpdir
		;;
		*)
		input_date=${lastfiledate}
		sudo cp -rf ${local_backup_path}/dbdump/${DB_NAME}_${input_date}* ${db_path}/tmpdir
		;;
		esac
		fi
fi

cd ${db_path}/tmpdir&&sudo cat *${input_date}* | sudo tee tmp.sql > /dev/null && cd -

if [ "$1" != "-full" ]; then
#### miso 덤프만 했을경우 user/DB(miso)/grant 를 추가
	read -p "create db and user ? y(create) , n(skip) >" RET
	case $RET in
	n)
	echo "create DB user self"
	echo ${db_path}"/tmpdir/tmp.sql source"
	exit 0
	;;
	y)
	dbckp=1
	;;
	*)
	dbckp=1
	;;
	esac
fi
if [ "${dbckp}" == "1" ]; then
	db_setting
	touch insert.sql
	sudo echo "CREATE DATABASE \`${DB_NAME}\` /*!40100 COLLATE 'utf8mb4_unicode_ci'*/;" > insert.sql
	sudo echo "CREATE USER '${DB_USER}'@'${HOST_IP}' IDENTIFIED BY '${DB_PASSWD}';" >> insert.sql
	sudo echo "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWD}';" >> insert.sql
	if [ ${HOST_IP} != ${LOOPBACK} ]; then
		sudo echo "CREATE USER '${DB_USER}'@'${LOOPBACK}' IDENTIFIED BY '${DB_PASSWD}';" >> insert.sql
	fi
	sudo echo "GRANT ${GRANTS} PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${HOST_IP}' IDENTIFIED BY '${DB_PASSWD}';" >> insert.sql
	sudo echo "GRANT ${GRANTS} PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWD}';" >> insert.sql
	if [ ${HOST_IP} != ${LOOPBACK} ]; then
		 sudo echo "GRANT ${GRANTS} PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${LOOPBACK}' IDENTIFIED BY '${DB_PASSWD}';" >> insert.sql
	fi
	sudo echo "use ${DB_NAME}" >>insert.sql
	sudo mv insert.sql ${db_path}/tmpdir/insert.sql	
fi
#### 백업 내용 추가 (기존내용은 insert.sql 로 이름 변경)
if [ ! -e "${db_path}/tmpdir/insert.sql" ]; then
	sudo touch insert.sql
fi
#sudo cat ${db_path}/tmpdir/tmp.sql >> ${db_path}/tmpdir/insert.sql
sudo cat ${db_path}/tmpdir/tmp.sql | sudo tee -a ${db_path}/tmpdir/insert.sql > /dev/null

#### FLUSH PRIVILEGES 구문 하단 추가
#sudo echo "FLUSH PRIVILEGES" >> ${db_path}/tmpdir/insert.sql
sudo sh -c 'echo "FLUSH PRIVILEGES" >> '${db_path}'/tmpdir/insert.sql'
echo "####insert query"
echo -n "(DB root Password)"
sudo mysql -u root -p < ${db_path}/tmpdir/insert.sql
echo "####db restore done"
sudo rm -rf ${db_path}/tmpdir
}


db_setting()
{
read -p "HOST IP setting (Recommand(enter key):"${HOST_IP}"):  >" RET
if [ ! -z "${RET}" ]; then
	HOST_IP="${RET}"
fi
read -p "DB USER setting (Recommand(enter key):"${DB_USER}"):  >" RET
if [ ! -z "${RET}" ]; then
	DB_USER="${RET}"
fi
GRANTS=ALL
read -p "input ${DB_USER} GRANT ("${GRANTS}" (enter key) | etc) : " RET
if [ ! -z "${RET}" ]; then
	GRANTS="${RET}"
fi
read -p "DB PASSWORD setting : >" DB_PASSWD
db_setting_check
}
db_setting_check()
{
echo "================================="
echo " HOST IP      : ${HOST_IP}"
echo " DB USER      : ${DB_USER}"
echo " USER GRANTS  : ${GRANTS}"
echo " DB PASSWORD  : ${DB_PASSWD}"
echo " next (press y or anykey)"
echo " modify (press n) "
echo "================================="
read RET
case $RET in
n)
db_setting
;;
y)
;;
*)
;;
esac
}

main()
{
	case "$1" in
		date)
			find_file_date
			;;
		webapps)
			miso_recover $1
			;;
		fileUpload)
			miso_recover $1
			;;
		editorImage)
			miso_recover $1
			;;
		miso_daemon)
			miso_recover $1
			;;
		dbdata)
			dbdata_recover $2
			;;
		help)
			echo " option = {webapps|fileUpload|editorImage|miso_daemon|dbdata (-full)}"
			;;
		*)
			echo "Usage: $0 {webapps|fileUpload|editorImage|miso_daemon|dbdata (-full)}"
			exit 1
			;;
	esac
}

main "$@"


