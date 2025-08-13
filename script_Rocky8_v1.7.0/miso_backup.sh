#!/bin/bash
source 00.util_Install_latest
SCRIPTLOGFILE=miso_backup.log
exec > >(tee -a "$SCRIPTLOGFILE") 2>&1
echo $DATE" is running" >> ${SCRIPTLOGFILE}
nohup bash -c "sleep 300; cat /dev/null > "${SCRIPTLOGFILE} > /dev/null 2>&1 &

webappsckp=0
fileUploadckp=0
editorImageckp=0
miso_daemonckp=0
tomcatckp=0
mariadbckp=0


init()
{
read -p "local backup path = "${local_backup_path}" y(continue) or n (exit) > " RET
if [ "${RET}" == "n" ]; then
	echo "ckeck local_backup_path"
	exit 0
elif [ "${RET}" == "y" ]; then
	echo "make backup dir"
	sudo mkdir -p ${local_backup_path}/miso/webapps
	sudo mkdir -p ${local_backup_path}/miso/fileUpload
	sudo mkdir -p ${local_backup_path}/miso/editorImage
	sudo mkdir -p ${local_backup_path}/miso/miso_daemon
	
	sudo mkdir -p ${local_backup_path}/conf-set/tomcat
	sudo mkdir -p ${local_backup_path}/conf-set/mariadb
	
	sudo mkdir -p ${local_backup_path}/dbdump
	
	
else
	echo "not command"
fi
}

miso_backup()
{
remote_passwd=$(decoding "${RP_ENC}")
echo "00.util_install_latest file backup start"
yes | sudo cp -f 1.txt ${local_backup_path}/miso/. 2>/dev/null
echo "00.util_install_latest file backup end"
echo "miso webapps backup start"
miso_webapps_backup $1
echo "miso webapps backup end"
echo "miso editorImage backup start"
miso_editorImage_backup $1
echo "miso editorImage backup end"
echo "miso daemon backup start"
miso_daemon_backup $1
echo "miso daemon backup end"
echo "miso fileUpload backup start"
miso_fileUpload_backup $1
echo "miso fileUpload backup end"
}

miso_webapps_backup()
{
if [ ! -e ${local_backup_path}"/miso/webapps/backup.log" ]; then
	sudo touch ${local_backup_path}/miso/webapps/backup.log
fi
####size / modify / change 기록 및 비교 하여 백업 여부 설정
#### backup.log 내 결과 값 저장
last_size=$(sudo tac ${local_backup_path}/miso/webapps/backup.log | grep -m 1 'Size:' | awk '{print $2}')
last_modify=$(sudo tac ${local_backup_path}/miso/webapps/backup.log | grep -m 1 'Modify:' | awk '{print $2, $3}')
last_change=$(sudo tac ${local_backup_path}/miso/webapps/backup.log | grep -m 1 'Change:' | awk '{print $2, $3}')
now_size=$(sudo stat ${miso_path}/webapps | grep -m 1 'Size' | awk '{print $2}')
now_modify=$(sudo stat ${miso_path}/webapps | grep -m 1 'Modify' | awk '{print $2, $3}')
now_change=$(sudo stat ${miso_path}/webapps | grep -m 1 'Change' | awk '{print $2, $3}')
sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/miso/webapps/backup.log'
sudo sh -c 'echo "backup date is ="'${DATE}' >> '${local_backup_path}'/miso/webapps/backup.log'
#### -f 옵션으로 강제 백업 
if [ "$1" == "-f" ]; then
	if [ "${split_opt}" == "n" ]; then
		sudo tar -czf ${local_backup_path}/miso/webapps/webapps_${DATE}.tar.gz -C ${miso_path} webapps 
	else
		sudo tar -zcf - -C ${miso_path} webapps | sudo split -b ${split_size} - ${local_backup_path}/miso/webapps/webapps_${DATE}.tar.gz
	fi
	sudo sh -c 'sudo stat '${miso_path}'/webapps | grep -m 1 "Size" | awk "{print \$1, \$2}" >> '${local_backup_path}'/miso/webapps/backup.log'
	sudo sh -c 'sudo stat '${miso_path}'/webapps | grep -m 1 "Modify" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/webapps/backup.log'
	sudo sh -c 'sudo stat '${miso_path}'/webapps | grep -m 1 "Change" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/webapps/backup.log'
	webappsckp=1
else
	if [[ "${last_size}" == "${now_size}" && "${last_modify}" == "${now_modify}" && "${last_change}" == "${now_change}" ]]; then
		sudo sh -c 'echo "last backup size same" >>  '${local_backup_path}'/miso/webapps/backup.log'
		sudo sh -c 'echo "last backup modify same" >>  '${local_backup_path}'/miso/webapps/backup.log'
		sudo sh -c 'echo "last backup change same" >> '${local_backup_path}'/miso/webapps/backup.log'
		sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/miso/webapps/backup.log'
	else
		if [ "${split_opt}" == "n" ]; then
			sudo tar -czf ${local_backup_path}/miso/webapps/webapps_${DATE}.tar.gz -C ${miso_path} webapps 
		else
			sudo tar -zcf - -C ${miso_path} webapps | sudo split -b ${split_size} - ${local_backup_path}/miso/webapps/webapps_${DATE}.tar.gz
		fi
		sudo sh -c 'sudo stat '${miso_path}'/webapps | grep -m 1 "Size" | awk "{print \$1, \$2}" >> '${local_backup_path}'/miso/webapps/backup.log'
		sudo sh -c 'sudo stat '${miso_path}'/webapps | grep -m 1 "Modify" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/webapps/backup.log'
		sudo sh -c 'sudo stat '${miso_path}'/webapps | grep -m 1 "Change" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/webapps/backup.log'
		webappsckp=1
	fi
fi

if [ -z "${remote_passwd}" ]; then
	echo "check the RP_ENC"
fi

if [[ "${scp_opt}" == "y" && "${webappsckp}" == "1" && -n "${remote_passwd}" ]]; then
	echo "scp option y"
	sudo sshpass -p ${remote_passwd} scp -P ${remote_port} ${local_backup_path}/miso/webapps/*${DATE}* ${remote_user}@${remote_ip}:${remote_path}
fi

}
miso_editorImage_backup()
{
if [ ! -e ${local_backup_path}"/miso/editorImage/backup.log" ]; then
	sudo touch ${local_backup_path}/miso/editorImage/backup.log
fi
####size / modify / change 기록 및 비교 하여 백업 여부 설정
#### backup.log 내 결과 값 저장
last_size=$(sudo tac ${local_backup_path}/miso/editorImage/backup.log | grep -m 1 'Size:' | awk '{print $2}')
last_modify=$(sudo tac ${local_backup_path}/miso/editorImage/backup.log | grep -m 1 'Modify:' | awk '{print $2, $3}')
last_change=$(sudo tac ${local_backup_path}/miso/editorImage/backup.log | grep -m 1 'Change:' | awk '{print $2, $3}')
now_size=$(sudo stat ${miso_path}/editorImage | grep -m 1 'Size' | awk '{print $2}')
now_modify=$(sudo stat ${miso_path}/editorImage | grep -m 1 'Modify' | awk '{print $2, $3}')
now_change=$(sudo stat ${miso_path}/editorImage | grep -m 1 'Change' | awk '{print $2, $3}')
sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/miso/editorImage/backup.log'
sudo sh -c 'echo "backup date is ="'${DATE}' >> '${local_backup_path}'/miso/editorImage/backup.log'
#### -f 옵션으로 강제 백업
if [ "$1" == "-f" ]; then
	if [ "${split_opt}" == "n" ]; then
		sudo tar -czf ${local_backup_path}/miso/editorImage/editorImage_${DATE}.tar.gz -C ${miso_path} editorImage 
	else
		sudo tar -zcf - -C ${miso_path} editorImage | sudo split -b ${split_size} - ${local_backup_path}/miso/editorImage/editorImage_${DATE}.tar.gz
	fi
	sudo sh -c 'sudo stat '${miso_path}'/editorImage | grep -m 1 "Size" | awk "{print \$1, \$2}" >> '${local_backup_path}'/miso/editorImage/backup.log'
	sudo sh -c 'sudo stat '${miso_path}'/editorImage | grep -m 1 "Modify" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/editorImage/backup.log'
	sudo sh -c 'sudo stat '${miso_path}'/editorImage | grep -m 1 "Change" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/editorImage/backup.log'
	editorImageckp=1
else
	if [[ "${last_size}" == "${now_size}" && "${last_modify}" == "${now_modify}" && "${last_change}" == "${now_change}" ]]; then
		sudo sh -c 'echo "last backup size same" >>  '${local_backup_path}'/miso/editorImage/backup.log'
		sudo sh -c 'echo "last backup modify same" >>  '${local_backup_path}'/miso/editorImage/backup.log'
		sudo sh -c 'echo "last backup change same" >> '${local_backup_path}'/miso/editorImage/backup.log'
		sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/miso/editorImage/backup.log'
	else
		if [ "${split_opt}" == "n" ]; then
			sudo tar -czf ${local_backup_path}/miso/editorImage/editorImage_${DATE}.tar.gz -C ${miso_path} editorImage 
		else
			sudo tar -zcf - -C ${miso_path} editorImage | sudo split -b ${split_size} - ${local_backup_path}/miso/editorImage/editorImage_${DATE}.tar.gz
		fi
		sudo tar -czf ${local_backup_path}/miso/editorImage/editorImage_${DATE}.tar.gz -C ${miso_path} editorImage 
		sudo sh -c 'sudo stat '${miso_path}'/editorImage | grep -m 1 "Size" | awk "{print \$1, \$2}" >> '${local_backup_path}'/miso/editorImage/backup.log'
		sudo sh -c 'sudo stat '${miso_path}'/editorImage | grep -m 1 "Modify" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/editorImage/backup.log'
		sudo sh -c 'sudo stat '${miso_path}'/editorImage | grep -m 1 "Change" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/editorImage/backup.log'
		editorImageckp=1
	fi
fi
if [ -z "${remote_passwd}" ]; then
	echo "check the RP_ENC"
fi
if [[ "${scp_opt}" == "y" && "${editorImageckp}" == "1" && -n "${remote_passwd}" ]]; then
	echo "scp option y"
	sudo sshpass -p ${remote_passwd} scp -P ${remote_port} ${local_backup_path}/miso/editorImage/*${DATE}* ${remote_user}@${remote_ip}:${remote_path}
fi

}
miso_daemon_backup()
{
if [ ! -e ${local_backup_path}"/miso/miso_daemon/backup.log" ]; then
	sudo touch ${local_backup_path}/miso/miso_daemon/backup.log
fi
####size / modify / change 기록 및 비교 하여 백업 여부 설정
#### backup.log 내 결과 값 저장
last_size=$(sudo tac ${local_backup_path}/miso/miso_daemon/backup.log | grep -m 1 'Size:' | awk '{print $2}')
last_modify=$(sudo tac ${local_backup_path}/miso/miso_daemon/backup.log | grep -m 1 'Modify:' | awk '{print $2, $3}')
last_change=$(sudo tac ${local_backup_path}/miso/miso_daemon/backup.log | grep -m 1 'Change:' | awk '{print $2, $3}')
now_size=$(sudo stat ${miso_path}/miso_daemon | grep -m 1 'Size' | awk '{print $2}')
now_modify=$(sudo stat ${miso_path}/miso_daemon | grep -m 1 'Modify' | awk '{print $2, $3}')
now_change=$(sudo stat ${miso_path}/miso_daemon | grep -m 1 'Change' | awk '{print $2, $3}')
sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/miso/miso_daemon/backup.log'
sudo sh -c 'echo "backup date is ="'${DATE}' >> '${local_backup_path}'/miso/miso_daemon/backup.log'
#### -f 옵션으로 강제 백업
if [ "$1" == "-f" ]; then
	if [ "${split_opt}" == "n" ]; then
		sudo tar -czf ${local_backup_path}/miso/miso_daemon/miso_daemon_${DATE}.tar.gz -C ${miso_path} miso_daemon 
	else
		sudo tar -zcf - -C ${miso_path} miso_daemon | sudo split -b ${split_size} - ${local_backup_path}/miso/miso_daemon/miso_daemon_${DATE}.tar.gz
	fi
	sudo sh -c 'sudo stat '${miso_path}'/miso_daemon | grep -m 1 "Size" | awk "{print \$1, \$2}" >> '${local_backup_path}'/miso/miso_daemon/backup.log'
	sudo sh -c 'sudo stat '${miso_path}'/miso_daemon | grep -m 1 "Modify" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/miso_daemon/backup.log'
	sudo sh -c 'sudo stat '${miso_path}'/miso_daemon | grep -m 1 "Change" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/miso_daemon/backup.log'
	miso_daemonckp=1
else
	if [[ "${last_size}" == "${now_size}" && "${last_modify}" == "${now_modify}" && "${last_change}" == "${now_change}" ]]; then
		sudo sh -c 'echo "last backup size same" >>  '${local_backup_path}'/miso/miso_daemon/backup.log'
		sudo sh -c 'echo "last backup modify same" >>  '${local_backup_path}'/miso/miso_daemon/backup.log'
		sudo sh -c 'echo "last backup change same" >> '${local_backup_path}'/miso/miso_daemon/backup.log'
		sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/miso/miso_daemon/backup.log'
	else
		if [ "${split_opt}" == "n" ]; then
			sudo tar -czf ${local_backup_path}/miso/miso_daemon/miso_daemon_${DATE}.tar.gz -C ${miso_path} miso_daemon 
		else
			sudo tar -zcf - -C ${miso_path} miso_daemon | sudo split -b ${split_size} - ${local_backup_path}/miso/miso_daemon/miso_daemon_${DATE}.tar.gz
		fi
		sudo sh -c 'sudo stat '${miso_path}'/miso_daemon | grep -m 1 "Size" | awk "{print \$1, \$2}" >> '${local_backup_path}'/miso/miso_daemon/backup.log'
		sudo sh -c 'sudo stat '${miso_path}'/miso_daemon | grep -m 1 "Modify" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/miso_daemon/backup.log'
		sudo sh -c 'sudo stat '${miso_path}'/miso_daemon | grep -m 1 "Change" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/miso_daemon/backup.log'
		miso_daemonckp=1
	fi
fi
if [ -z "${remote_passwd}" ]; then
	echo "check the RP_ENC"
fi
if [[ "${scp_opt}" == "y" && "${miso_daemonckp}" == "1" && -n "${remote_passwd}" ]]; then
	echo "scp option y"
	sudo sshpass -p ${remote_passwd} scp -P ${remote_port} ${local_backup_path}/miso/miso_daemon/*${DATE}* ${remote_user}@${remote_ip}:${remote_path}
fi
}
miso_fileUpload_backup()
{
if [ ! -e ${local_backup_path}"/miso/fileUpload/backup.log" ]; then
	sudo touch ${local_backup_path}/miso/fileUpload/backup.log
fi
####size / modify / change 기록 및 비교 하여 백업 여부 설정
#### backup.log 내 결과 값 저장
last_size=$(sudo tac ${local_backup_path}/miso/fileUpload/backup.log | grep -m 1 'Size:' | awk '{print $2}')
last_modify=$(sudo tac ${local_backup_path}/miso/fileUpload/backup.log | grep -m 1 'Modify:' | awk '{print $2, $3}')
last_change=$(sudo tac ${local_backup_path}/miso/fileUpload/backup.log | grep -m 1 'Change:' | awk '{print $2, $3}')
now_size=$(sudo stat ${miso_path}/fileUpload | grep -m 1 'Size' | awk '{print $2}')
now_modify=$(sudo stat ${miso_path}/fileUpload | grep -m 1 'Modify' | awk '{print $2, $3}')
now_change=$(sudo stat ${miso_path}/fileUpload | grep -m 1 'Change' | awk '{print $2, $3}')
sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/miso/fileUpload/backup.log'
sudo sh -c 'echo "backup date is ="'${DATE}' >> '${local_backup_path}'/miso/fileUpload/backup.log'
#### -f 옵션으로 강제 백업
if [ "$1" == "-f" ]; then
	if [ "${split_opt}" == "n" ]; then
		sudo tar -czf ${local_backup_path}/miso/fileUpload/fileUpload_${DATE}.tar.gz -C ${miso_path} fileUpload 
	else
		sudo tar -zcf - -C ${miso_path} fileUpload | sudo split -b ${split_size} - ${local_backup_path}/miso/fileUpload/fileUpload_${DATE}.tar.gz
		fi
	sudo sh -c 'sudo stat '${miso_path}'/fileUpload | grep -m 1 "Size" | awk "{print \$1, \$2}" >> '${local_backup_path}'/miso/fileUpload/backup.log'
	sudo sh -c 'sudo stat '${miso_path}'/fileUpload | grep -m 1 "Modify" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/fileUpload/backup.log'
	sudo sh -c 'sudo stat '${miso_path}'/fileUpload | grep -m 1 "Change" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/fileUpload/backup.log'
	fileUploadckp=1
else
	if [[ "${last_size}" == "${now_size}" && "${last_modify}" == "${now_modify}" && "${last_change}" == "${now_change}" ]]; then
		sudo sh -c 'echo "last backup size same" >>  '${local_backup_path}'/miso/fileUpload/backup.log'
		sudo sh -c 'echo "last backup modify same" >>  '${local_backup_path}'/miso/fileUpload/backup.log'
		sudo sh -c 'echo "last backup change same" >> '${local_backup_path}'/miso/fileUpload/backup.log'
		sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/miso/fileUpload/backup.log'
	else
		if [ "${split_opt}" == "n" ]; then
			sudo tar -czf ${local_backup_path}/miso/fileUpload/fileUpload_${DATE}.tar.gz -C ${miso_path} fileUpload 
		else
			sudo tar -zcf - -C ${miso_path} fileUpload | sudo split -b ${split_size} - ${local_backup_path}/miso/fileUpload/fileUpload_${DATE}.tar.gz
		fi
		sudo tar -czf ${local_backup_path}/miso/fileUpload/fileUpload_${DATE}.tar.gz -C ${miso_path} fileUpload 
		sudo sh -c 'sudo stat '${miso_path}'/fileUpload | grep -m 1 "Size" | awk "{print \$1, \$2}" >> '${local_backup_path}'/miso/fileUpload/backup.log'
		sudo sh -c 'sudo stat '${miso_path}'/fileUpload | grep -m 1 "Modify" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/fileUpload/backup.log'
		sudo sh -c 'sudo stat '${miso_path}'/fileUpload | grep -m 1 "Change" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/miso/fileUpload/backup.log'
		fileUploadckp=1
	fi
fi
if [ -z "${remote_passwd}" ]; then
	echo "check the RP_ENC"
fi
if [[ "${scp_opt}" == "y" && "${fileUploadckp}" == "1" && -n "${remote_passwd}" && -n "${remote_passwd}" ]]; then
	echo "scp option y"
	sudo sshpass -p ${remote_passwd} scp -P ${remote_port} ${local_backup_path}/miso/fileUpload/*${DATE}* ${remote_user}@${remote_ip}:${remote_path}
fi
}

tomcat_backup()
{
if [ ! -e ${local_backup_path}"/conf-set/tomcat/backup.log" ]; then
	sudo touch ${local_backup_path}/conf-set/tomcat/backup.log
fi
####size / modify / change 기록 및 비교 하여 백업 여부 설정
#### backup.log 내 결과 값 저장
last_size=$(sudo tac ${local_backup_path}/conf-set/tomcat/backup.log | grep -m 1 'Size:' | awk '{print $2}')
last_modify=$(sudo tac ${local_backup_path}/conf-set/tomcat/backup.log | grep -m 1 'Modify:' | awk '{print $2, $3}')
last_change=$(sudo tac ${local_backup_path}/conf-set/tomcat/backup.log | grep -m 1 'Change:' | awk '{print $2, $3}')
now_size=$(sudo stat ${tomcat_path}/conf-set | grep -m 1 'Size' | awk '{print $2}')
now_modify=$(sudo stat ${tomcat_path}/conf-set | grep -m 1 'Modify' | awk '{print $2, $3}')
now_change=$(sudo stat ${tomcat_path}/conf-set | grep -m 1 'Change' | awk '{print $2, $3}')

sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/conf-set/tomcat/backup.log'
sudo sh -c 'echo "backup date is ="'${DATE}' >> '${local_backup_path}'/conf-set/tomcat/backup.log'
#### -f 옵션으로 강제 백업
if [ "$1" == "-f" ]; then
	sudo tar -czf ${local_backup_path}/conf-set/tomcat/tomcat_conf-set_${DATE}.tar.gz -C ${tomcat_path} conf-set 
	sudo sh -c 'sudo stat '${tomcat_path}'/conf-set | grep -m 1 "Size" | awk "{print \$1, \$2}" >> '${local_backup_path}'/conf-set/tomcat/backup.log'
	sudo sh -c 'sudo stat '${tomcat_path}'/conf-set | grep -m 1 "Modify" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/conf-set/tomcat/backup.log'
	sudo sh -c 'sudo stat '${tomcat_path}'/conf-set | grep -m 1 "Change" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/conf-set/tomcat/backup.log'
	tomcatckp=1
else
	if [[ "${last_size}" == "${now_size}" && "${last_modify}" == "${now_modify}" && "${last_change}" == "${now_change}" ]]; then
		sudo sh -c 'echo "last backup size same" >>  '${local_backup_path}'/conf-set/tomcat/backup.log'
		sudo sh -c 'echo "last backup modify same" >>  '${local_backup_path}'/conf-set/tomcat/backup.log'
		sudo sh -c 'echo "last backup change same" >> '${local_backup_path}'/conf-set/tomcat/backup.log'
		sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/conf-set/tomcat/backup.log'
	else
		sudo tar -czf ${local_backup_path}/conf-set/tomcat/tomcat_conf-set_${DATE}.tar.gz -C ${tomcat_path} conf-set 
		sudo sh -c 'sudo stat '${tomcat_path}'/conf-set | grep -m 1 "Size" | awk "{print \$1, \$2}" >> '${local_backup_path}'/conf-set/tomcat/backup.log'
		sudo sh -c 'sudo stat '${tomcat_path}'/conf-set | grep -m 1 "Modify" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/conf-set/tomcat/backup.log'
		sudo sh -c 'sudo stat '${tomcat_path}'/conf-set | grep -m 1 "Change" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/conf-set/tomcat/backup.log'
		tomcatckp=1
	fi
fi
remote_passwd=$(decoding "${RP_ENC}")
if [ -z "${remote_passwd}" ]; then
	echo "check the RP_ENC"
fi
if [[ "${scp_opt}" == "y" && "${tomcatckp}" == "1" && -n "${remote_passwd}" ]]; then
	echo "scp option y"
	sudo sshpass -p ${remote_passwd} scp -P ${remote_port} ${local_backup_path}/conf-set/tomcat/*${DATE}* ${remote_user}@${remote_ip}:${remote_path}
fi
}

db_backup()
{
if [ ${host_in_db} == "n" ]; then
	return 0
fi

if [ ! -e ${local_backup_path}"/conf-set/mariadb/backup.log" ]; then
	sudo touch ${local_backup_path}/conf-set/mariadb/backup.log
fi
####size / modify / change 기록 및 비교 하여 백업 여부 설정
#### backup.log 내 결과 값 저장
last_size=$(sudo tac ${local_backup_path}/conf-set/mariadb/backup.log | grep -m 1 'Size:' | awk '{print $2}')
last_modify=$(sudo tac ${local_backup_path}/conf-set/mariadb/backup.log | grep -m 1 'Modify:' | awk '{print $2, $3}')
last_change=$(sudo tac ${local_backup_path}/conf-set/mariadb/backup.log | grep -m 1 'Change:' | awk '{print $2, $3}')
now_size=$(sudo stat ${db_path}/conf-set | grep -m 1 'Size' | awk '{print $2}')
now_modify=$(sudo stat ${db_path}/conf-set | grep -m 1 'Modify' | awk '{print $2, $3}')
now_change=$(sudo stat ${db_path}/conf-set | grep -m 1 'Change' | awk '{print $2, $3}')
sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/conf-set/mariadb/backup.log'
sudo sh -c 'echo "backup date is ="'${DATE}' >> '${local_backup_path}'/conf-set/mariadb/backup.log'
#### -f 옵션으로 강제 백업
if [ "$1" == "-f" ]; then
	sudo tar -czf ${local_backup_path}/conf-set/mariadb/mariadb_conf-set_${DATE}.tar.gz -C ${db_path} conf-set 
	sudo sh -c 'sudo stat '${db_path}'/conf-set | grep -m 1 "Size" | awk "{print \$1, \$2}" >> '${local_backup_path}'/conf-set/mariadb/backup.log'
	sudo sh -c 'sudo stat '${db_path}'/conf-set | grep -m 1 "Modify" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/conf-set/mariadb/backup.log'
	sudo sh -c 'sudo stat '${db_path}'/conf-set | grep -m 1 "Change" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/conf-set/mariadb/backup.log'
	mariadbckp=1
else
	if [[ "${last_size}" == "${now_size}" && "${last_modify}" == "${now_modify}" && "${last_change}" == "${now_change}" ]]; then
		sudo sh -c 'echo "last backup size same" >>  '${local_backup_path}'/conf-set/mariadb/backup.log'
		sudo sh -c 'echo "last backup modify same" >>  '${local_backup_path}'/conf-set/mariadb/backup.log'
		sudo sh -c 'echo "last backup change same" >> '${local_backup_path}'/conf-set/mariadb/backup.log'
		sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/conf-set/mariadb/backup.log'
	else
		sudo tar -czf ${local_backup_path}/conf-set/mariadb/mariadb_conf-set_${DATE}.tar.gz -C ${db_path} conf-set 
		sudo sh -c 'sudo stat '${db_path}'/conf-set | grep -m 1 "Size" | awk "{print \$1, \$2}" >> '${local_backup_path}'/conf-set/mariadb/backup.log'
		sudo sh -c 'sudo stat '${db_path}'/conf-set | grep -m 1 "Modify" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/conf-set/mariadb/backup.log'
		sudo sh -c 'sudo stat '${db_path}'/conf-set | grep -m 1 "Change" | awk "{print \$1, \$2, \$3}" >> '${local_backup_path}'/conf-set/mariadb/backup.log'
		mariadbckp=1
	fi
fi
remote_passwd=$(decoding "${RP_ENC}")
if [ -z "${remote_passwd}" ]; then
	echo "check the RP_ENC"
fi
if [[ "${scp_opt}" == "y" && "${mariadbckp}" == "1" && -n "${remote_passwd}" ]]; then
	echo "scp option y"
	sudo sshpass -p ${remote_passwd} scp -P ${remote_port} ${local_backup_path}/conf-set/mariadb/*${DATE}* ${remote_user}@${remote_ip}:${remote_path}
fi
}
dbdump()
{
if [ "${host_in_db}" == "n" ]; then
	return 0
fi
if [ ! -e ${local_backup_path}"/dbdump/backup.log" ]; then
	sudo touch ${local_backup_path}/dbdump/backup.log
fi
sudo sh -c 'echo "########################################################" >> '${local_backup_path}'/dbdump/backup.log'
sudo sh -c 'echo "backup date is ="'${DATE}' >> '${local_backup_path}'/dbdump/backup.log'
db_root_passwd=$(decoding "$DRP_ENC")
DB_PASSWD=$(decoding "$DP_ENC")
if [ "${dbfullbackup}" == "y" ]; then
	if [ -z "${db_root_passwd}" ]; then
		echo "check the DRP_ENC"
		exit 0
	fi
	if [ "${split_opt}" == "n" ]; then
		sudo ${db_path}/bin/mysqldump -u root -p${db_root_passwd} --all-databases --events --single-transaction --triggers --routines --quick --lock-tables=false --default-character-set=utf8mb4 --hex-blob  > fullbackup_${DATE}.sql&&sudo mv fullbackup_${DATE}.sql ${local_backup_path}/dbdump/
	else
		sudo ${db_path}/bin/mysqldump -u root -p${db_root_passwd} --all-databases --events --single-transaction --triggers --routines --quick --lock-tables=false --default-character-set=utf8mb4 --hex-blob  | sudo split -b ${split_size} - fullbackup_${DATE}.sql&&sudo mv fullbackup_${DATE}.sql* ${local_backup_path}/dbdump/
	fi
else
	if [ -z "${DB_PASSWD}" ]; then
		echo "check the DP_ENC"
		exit 0
	fi
	if [ "${split_opt}" == "n" ]; then
		sudo ${db_path}/bin/mysqldump -u ${DB_USER} -p${DB_PASSWD} ${DB_NAME} --events --single-transaction --triggers --routines --quick --lock-tables=false --default-character-set=utf8mb4 --hex-blob  > ${DB_NAME}_${DATE}.sql &&sudo mv ${DB_NAME}_${DATE}.sql ${local_backup_path}/dbdump/
	else
		sudo ${db_path}/bin/mysqldump -u ${DB_USER} -p${DB_PASSWD} ${DB_NAME} --events --single-transaction --triggers --routines --quick --lock-tables=false --default-character-set=utf8mb4 --hex-blob  | sudo split -b ${split_size} - ${DB_NAME}_${DATE}.sql &&sudo mv ${DB_NAME}_${DATE}.sql* ${local_backup_path}/dbdump/
	fi
fi
remote_passwd=$(decoding "${RP_ENC}")
if [ -z "${remote_passwd}" ]; then
	echo "check the RP_ENC"
fi
if [[ "${scp_opt}" == "y" && -n "${remote_passwd}" ]]; then
        echo "scp option y"
        sudo sshpass -p ${remote_passwd} scp -P ${remote_port} ${local_backup_path}/dbdump/*${DATE}* ${remote_user}@${remote_ip}:${remote_path}
fi
}
decoding()
{
salt=$(printf $SERV_USER | md5sum | cut -c1-16)
DEC_VALUE=$(echo $1 | openssl enc -aes-256-cbc -a -d -S $salt -pbkdf2 -iter 100000 -pass pass:$MY_USER 2>/dev/null)
if [[ "$DEC_VALUE" == "" ]]; then
	#echo "incorrect data : " $1
	echo ""
else
	echo $DEC_VALUE
fi
}

main()
{
	case "$1" in
		init)
			init
			;;
		miso)
			miso_backup $2
			;;
		app)
			tomcat_backup $2 && db_backup $2
			;;
		dbdump)
			dbdump
			;;
		db)
			db_backup&& dbdump
			;;
		help)
			echo " option = {init|miso|app(tomcat,DB)|dbdump|db}"
			;;
		*)
			echo "Usage: $0 {init|miso|app|dbdump|db}"
			exit 1
			;;
	esac
}

main "$@"


