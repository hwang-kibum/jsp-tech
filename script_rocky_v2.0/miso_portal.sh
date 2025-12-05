#!/bin/bash
cd "$(dirname "$0")"
source 01.util_Install_latest
SCRIPTLOGFILE=miso_portal.log
exec > >(tee -a "$SCRIPTLOGFILE") 2>&1
echo $DATE" is running" >> ${SCRIPTLOGFILE}
#nohup bash -c "sleep 300; cat /dev/null > "${SCRIPTLOGFILE} > /dev/null 2>&1 &

DBINSTALLQ=y
checkp=0
checkuserserv=0
checkuserdb=0

check_file()
{
if [ ! -e "../jdk/${JAVAFILE}" ]; then
	echo ${JAVAFILE}" not exist"
	exit 0
elif [ ! -e "../tomcat/${TOMCATFILE}" ]; then
	echo ${TOMCATFILE}" not exist"
	exit 0
elif [ ! -e "../mariadb/${DBFILE}" ]; then
	echo ${DBFILE}" not exist"
	exit 0
else 
	echo "install ok"
fi
}
check_sel()
{
CURRENT_SEL=$(getenforce)
CONF_SEL=$(cat /etc/selinux/config | grep '^SELINUX=' | cut -d '=' -f2 )
if [ "Enforcing" == ${CURRENT_SEL} ];then
	echo "SELINUX BAD config"
	echo "CURRENT SELINUX : ${CURRENT_SEL}"
	read -p "change SELINUX DISABLED : yes(enter key) or no(n key):  >" RET
		if [ "${RET}" = "n" ]; then
			echo "change SELINUX Config"
			return 0
		else
			sudo setenforce 0
			sudo sed -i 's/SELINUX='${CONF_SEL}'/SELINUX=disabled/g' /etc/selinux/config
		fi
elif [ "Permissive" == ${CURRENT_SEL} ];then
	echo "CURRENT SELINUX : ${CURRENT_SEL}"
	read -p "change SELINUX DISABLED : yes(enter key) or no(n key):  >" RET
		if [ "${RET}" = "n" ]; then
			echo "change SELINUX Config later"
		else
			sudo sed -i 's/SELINUX='${CONF_SEL}'/SELINUX=disabled/g' /etc/selinux/config
		fi
elif [ "Disabled" == ${CURRENT_SEL} ];
	echo "CURRENT SELINUX : ${CURRENT_SEL}"
then
	echo "check selinux config"
fi
checkp=1
}

check_path()
{
echo "###########config path###########"
read -p "install_path (Recommand(enter key): "${install_path}"):  >" RET
if [ ! -z "${RET}" ]; then
	install_path="${RET}"
fi
miso_path="${install_path}/miso"
mlogs_path="${install_path}/logs"
tomcat_path="${install_path}/tomcat"
tlog_path="${install_path}/logs/tomcat"
db_path="${install_path}/mariadb"
dbdata_path="${install_path}/mariadbData"
dlog_path="${install_path}/logs/mariadb"

read -p "miso path (webapps, fileUpload, editorImage, daemon) (Recommand(enter key): "${miso_path}"):  >" RET
if [ ! -z "${RET}" ]; then
	miso_path="${RET}"
fi
read -p "miso log path (Recommand(enter key): "${mlogs_path}"):  >" RET
if [ ! -z "${RET}" ]; then
	mlogs_path="${RET}"
fi
read -p "tomcat path (Recommand(enter key): "${tomcat_path}"): >" RET
if [ ! -z "${RET}" ]; then
	tomcat_path="${RET}"
fi
read -p "tomcat log path (Recommand(enter key): "${tlog_path}"): >" RET
if [ ! -z "${RET}" ]; then
	tlog_path="${RET}"
fi
read -p "DB path (Recommand(enter key): "${db_path}"): >" RET
if [ ! -z "${RET}" ]; then
	db_path="${RET}"
fi
read -p "DB DATA path (Recommand(enter key): "${dbdata_path}"): >" RET
if [ ! -z "${RET}" ]; then
	dbdata_path="${RET}"
fi

read -p "DB log path (Recommand(enter key): "${dlog_path}"): >" RET
if [ ! -z "${RET}" ]; then
	dlog_path="${RET}"
fi
echo "###########config path###########"
checking
}

checking()
{
echo "================================="
echo " install path                                               : ${install_path}"
echo " miso path(webapps, fileUpload, editorImage, miso_daemon)   : ${miso_path}"
echo " miso log path(miso,miso_daemon)                            : ${mlogs_path}"
echo " tomcat path(tomcat,conf-set)                               : ${tomcat_path}"
echo " tomcat log path                                            : ${tlog_path}"
echo " DB path(db, conf-set)                                      : ${db_path}"
echo " DB DATA path                                               : ${dbdata_path}"
echo " DB log path                                                : ${dlog_path}"
echo " next (press y or anykey)"
echo " modify (press n) "
echo "================================="
read RET
case $RET in
n)
check_path
;;
y)
source_variable
;;
*)
source_variable
;;
esac
}
source_variable()
{
echo "source path variable >> 01.util_Install_latest"
sudo sed -i "/install_path=/ c\install_path="${install_path} 01.util_Install_latest
sudo sed -i "/miso_path=/ c\miso_path="${miso_path} 01.util_Install_latest
sudo sed -i "/mlogs_path=/ c\mlogs_path="${mlogs_path} 01.util_Install_latest
sudo sed -i "/tomcat_path=/ c\tomcat_path="${tomcat_path} 01.util_Install_latest
sudo sed -i "/tlog_path=/ c\tlog_path="${tlog_path} 01.util_Install_latest
sudo sed -i "/db_path=/ c\db_path="${db_path} 01.util_Install_latest
sudo sed -i "/dbdata_path=/ c\dbdata_path="${dbdata_path} 01.util_Install_latest
sudo sed -i "/dlog_path=/ c\dlog_path="${dlog_path} 01.util_Install_latest
echo "source path variable  done"
}
check_user_serv()
{
echo "check "${SERV_USER}
tmp=$(sudo cat /etc/passwd | awk -F: '{print $1}' | grep "^${SERV_USER}$")
if [ -z "${tmp}" ]; then
	echo "create "${SERV_USER} "service id"
	sudo useradd -Ms /bin/false ${SERV_USER}
	echo "create "${SERV_USER}" done"
else
        echo ${SERV_USER}" already exist"
fi
checkuserserv=1
}
check_user_db()
{
echo "check "${MY_USER}
tmp=$(sudo cat /etc/passwd | awk -F: '{print $1}' | grep "^${MY_USER}$")
if [ -z "${tmp}" ]; then
	echo "create "${MY_USER} "service id"
	sudo useradd -Ms /bin/false ${MY_USER}
	echo "create "${MY_USER}" done"
else
        echo ${MY_USER}" already exist"
fi
checkuserdb=1
}

makedir()
{
echo "================================="
echo "mkdir miso path"
	sudo mkdir -p ${miso_path}/webapps
	sudo mkdir -p ${miso_path}/fileUpload
	sudo mkdir -p ${miso_path}/editorImage
	sudo mkdir -p ${miso_path}/miso_daemon
	sudo chown -R ${SERV_USER}:${SERV_USER} ${miso_path}
	echo "mkdir miso path done"

echo "================================="
	sudo mkdir -p ${mlogs_path}/miso
	sudo mkdir -p ${mlogs_path}/miso_daemon
	sudo chown -R ${SERV_USER}:${SERV_USER} ${mlogs_path}/miso*
	echo "mkdir miso log path done"
echo "================================="
echo "mkdir path done"
}

install_java()
{
echo "#####java install"
if [ -d "${install_path}/java" ]; then
	echo "java already install"
	read -p ${install_path}"/java mv "${install_path}"/java.ori : yes(enter key) or no(n key) : >" RET
	if [ "${RET}" == "n" ]; then
		echo "using java or mv java"
		return 0
	else
		echo "mv file"
		sudo mv -f ${install_path}/java ${install_path}/java.ori
		echo "mv file done"
		sudo mkdir -p ${install_path}/java		
	fi
fi
if [ ! -d "${install_path}/java" ]; then
       	sudo mkdir -p ${install_path}/java
fi
sudo tar -xzvf ../jdk/"${JAVAFILE}"* -C ${install_path}/java --strip-components=1 >/dev/null 2>&1
sudo chown -R ${SERV_USER}:${SERV_USER} ${install_path}/java
sudo sh -c 'echo "export JAVA_HOME=\"'${install_path}'/java\"" >> /etc/profile '
sudo sh -c 'echo "export PATH=\"\$JAVA_HOME/bin:\$PATH\"" >> /etc/profile'
sudo sh -c 'echo "export CLASSPATH=\"\$JAVA_HOME/jre:/lib/ext:\$JAVA_HOME/lib/tools.jar\"" >>/etc/profile'
echo "#####java install done"
echo "##### source /etc/profile #####"
}

tomcat_install()
{
#### 수동 설치시 파일 체크
if [ ! -e "../jdk/${JAVAFILE}" ]; then
	echo ${JAVAFILE}" not exist"
	exit 0
elif [ ! -e "../tomcat/${TOMCATFILE}" ]; then
	echo ${TOMCATFILE}" not exist"
	exit 0
fi
#### 사용자 체크
if [ "${checkuserserv}" == "0" ]; then
check_user_serv
fi

echo "checking java install"
if [ -d "${install_path}/java" ]; then
	echo ${install_path}"/java installed"
else
	read -p "install java : yes(enter key) or no(n key) >" RET
	if [ "${RET}" == "n" ]; then
		echo "please install java"
		exit 0
	else
		install_java
	fi
fi
#### ckeck path
checking

echo "#####tomcat install"
if [ -d "${tomcat_path}" ]; then
	echo "tomcat already install"
	read -p ${tomcat_path}" mv "${tomcat_path}".ori : yes(enter key) or no(n key) : >" RET
	if [ "${RET}" == "n" ]; then
		echo "use tomcat or mv tomcat "
		return 0
	else
		echo "mv file"
		sudo mv -f ${tomcat_path} ${tomcat_path}.ori
		echo "mv file done"
		sudo mkdir -p ${tomcat_path}		
	fi
fi
#### tomcat dir 생성
echo "mkdir tomcat dir"
if [ ! -d "${tomcat_path}" ]; then
       	sudo mkdir -p ${tomcat_path}
fi
sudo tar -xzf ../tomcat/"${TOMCATFILE}"* -C ${tomcat_path} --strip-components=1 >/dev/null 2>&1
sudo mkdir -p ${tomcat_path}/conf-set

#### tomcat log dir 생성
echo "mkdir tomcat log dir"
if [ -d "${tlog_path}" ]; then
	echo ${tlog_path} "already exist"
	read -p ${tlog_path}" mv "${tlog_path}".ori : yes(enter key) or no(n key) : >" RET
	if [ "${RET}" == "n" ]; then
		echo "change tomcat log path"
		exit 0
	else
		echo "mv file"
		sudo mv -f ${tlog_path} ${tlog_path}.ori
		echo "mv file done"
		sudo mkdir -p ${tlog_path}
		echo "mkdir tomcat log path done"
	fi
else
	sudo mkdir -p ${tlog_path}
	echo "mkdir tomcat log path done"
fi
echo "#####tomcat install done"
tomcat_set
}

tomcat_set()
{
echo "#####tomcat setting"
#setenv.sh 파일 생성
sudo tee ${tomcat_path}/bin/setenv.sh > /dev/null << EOF
LANG="ko_KR.utf8"
JAVA_HOME="${install_path}/java"
export JAVA_OPTS="-server -Djava.awt.headless=true -Dfile.encoding=UTF-8 -Xms512m -Xmx1024m -XX:MetaspaceSize=256m -XX:MaxMetaspaceSize=512m"
EOF

#server.xml 복사
sudo cp -arp ${tomcat_path}/conf/server.xml ${tomcat_path}/conf/server.xml.ori
#server.xml 수정
sudo sed -i 's|unpackWARs="true" autoDeploy="true"|unpackWARs="false" autoDeploy="false"|' ${tomcat_path}/conf/server.xml 
sudo sed -i 's|maxParameterCount="1000"|maxParameterCount="1000" URIEncoding="UTF-8" enableLookups="false" server="server"|' ${tomcat_path}/conf/server.xml

#catalina.sh 파일 복사
sudo cp -arp ${tomcat_path}/bin/catalina.sh ${tomcat_path}/bin/catalina.sh.ori
#catalina.sh 파일 수정
sudo sed -i '125d' ${tomcat_path}/bin/catalina.sh
sudo sed -i '125 i\JAVA_HOME="'"${install_path}"'/java/"' ${tomcat_path}/bin/catalina.sh
sudo sed -i '126 i\JAVA_OPTS="-Xms1024m -Xmx2048m -XX:NewSize=400m -XX:MaxNewSize=400m -XX:SurvivorRatio=4"' ${tomcat_path}/bin/catalina.sh
sudo sed -i '127 i\CATALINA_OUT="'"${tlog_path}"'/catalina.out"' ${tomcat_path}/bin/catalina.sh
sudo sed -i '128 i\CATALINA_OPTS="-Djava.net.preferIPv4Stack=true"' ${tomcat_path}/bin/catalina.sh

#log경로 수정 
sudo cp -arp ${tomcat_path}/conf/logging.properties  ${tomcat_path}/conf/logging.properties.ori
sudo sed -i 's|\${catalina.base}/logs|'${tlog_path}'|g' ${tomcat_path}/conf/logging.properties
sudo sed -ri 's#^([0-9]+)([a-z-]+)\.(.*AsyncFileHandler\.directory = )(.*)$#\1\2.\3\4/\2#' ${tomcat_path}/conf/logging.properties
sudo sed -ri 's#(.*maxDays = ).*$#\1180#' ${tomcat_path}/conf/logging.properties

sudo sed -i 's|pattern="%h %l %u %t &quot;%r&quot; %s %b" />|pattern="combined" resolveHosts="false" />|' ${tomcat_path}/conf/server.xml
sudo sed -ri 's#(.*AccessLogValve" directory=)(.*)$#\1"'${tlog_path}'/localhost_access"#' ${tomcat_path}/conf/server.xml
sudo sed -ri 's#(.*suffix=)(.*)$#\1".log"#' ${tomcat_path}/conf/server.xml 
sudo sed -ri 's#(.*suffix=".log")#\1 fileDateFormat=".yyyy-MM-dd"  rotatable="true" renameOnRotate="false" maxDays="180"#'  ${tomcat_path}/conf/server.xml 

## 권한 전체 수정
sudo chown -R ${SERV_USER}:${SERV_USER} ${tomcat_path}
sudo chown -R ${SERV_USER}:${SERV_USER} ${tlog_path}

##logrotate 설정 root 권한 필요
sudo tee ${tomcat_path}/conf-set/tomcat.logrotate > /dev/null << EOF
${tlog_path}/*.out
{
        daily
        rotate 180
        missingok
        notifempty
        compress
        delaycompress
        compresscmd /usr/bin/gzip
        uncompresscmd /usr/bin/gunzip
        compressoptions -9
        create 640 ${SERV_USER} ${SERV_USER}
        maxage 180
        size 100M
        dateext
		copytruncate
}
EOF
chekp=$(which logrotate 2>/dev/null)
if [ -z $chekp ]; then
        echo "check logrotate file"
else
	sudo ln -s ${tomcat_path}/conf-set/tomcat.logrotate /etc/logrotate.d/tomcat.logrotate
	sudo chown -R root:root ${tomcat_path}/conf-set/tomcat.logrotate
fi
echo "#####tomcat setting done"
tomcat_service
}

tomcat_service()
{
echo "#####make tomcat service"

FIN="/usr/lib/systemd/system/tomcat.service"
if [ -e $FIN ] || [ -L $FIN ]; then
	read -p "tomcat.service mv tomcat.servce_bak : y(enter key) n(exit) > " RET
	if [ "${RET}" = "n" ]; then
		echo "please mv tomcat.service"
		exit 0
	else
		sudo unlink /usr/lib/systemd/system/tomcat.service
		sudo mv -f /usr/lib/systemd/system/tomcat.service /usr/lib/systemd/system/tomcat.service_bak 2>/dev/null
	fi
fi
sudo tee ${tomcat_path}/conf-set/tomcat.service > /dev/null << EOF
[Unit]
Description=tomcat 9
After=network.target syslog.target
Wants=network.target

[Service]
Type=forking
User=${SERV_USER}
Group=${SERV_USER}
ExecStart=${tomcat_path}/bin/startup.sh start
ExecStop=${tomcat_path}/bin/shutdown.sh stop

[Install]
WantedBy=multi-user.target
EOF

#### mariadb 서비스 기동 후 내용추가
FIN="/usr/lib/systemd/system/mariadb.service"
if [ -e $FIN ]; then
	echo "find file! mariadb.service" 
	sudo sed -i 's/After=network.target syslog.target/After=network.target syslog.target mariadb.service/' ${tomcat_path}/conf-set/tomcat.service
	sudo sed -i 's/Wants=network.target/Wants=network.target mariadb.service/' ${tomcat_path}/conf-set/tomcat.service
fi

sudo chown -R root:root ${tomcat_path}/conf-set/tomcat.service
echo "#####create tomcat.service done"

echo "#####sybolic link tomcat service"
sudo ln -s ${tomcat_path}/conf-set/tomcat.service /usr/lib/systemd/system/tomcat.service

#ls -alt /usr/lib/systemd/system | grep tomcat.service
sudo systemctl daemon-reload
sudo systemctl enable tomcat
echo "#####make tomcat service done"

if [[ $1 == "tomcat" ]]; then
	read -p "systemctl start tomcat.service : n(not running) , y(running) >" RET
	if [ "${RET}" == "y" ]; then
		sudo systemctl start tomcat
	elif [ "${RET}" == "n" ]; then
		echo "after running tomcat"
	else
		echo "not command y or n"
	fi
fi
}

db_install()
{
#### 수동 설치시 파일 체크
if [ ! -e "../mariadb/${DBFILE}" ]; then
	echo ${DBFILE}" not exist"
	exit 0
fi
echo "#####DB install"
read -p "INSTALL MARIADB (install(y or anykey) | not install (n key)) >" DBINSTALLQ
case $DBINSTALLQ in
n)
echo "use other server DB"
return 0
;;
y)
;;
*)
;;
esac
#### 설정값 체크
checking
#### 사용자 체크
if [ "${checkuserdb}" == "0" ]; then
check_user_db
fi

if [ -d "${db_path}" ]; then
	echo "DB already install"
	read -p ${db_path}" mv "${db_path}".ori : y(enter key) or no(n key) : >" RET
	if [ "${RET}" == "n" ]; then
		echo "use DB or mv DB "
		return 0
	else
		echo "mv file"
		sudo mv -f ${db_path} ${db_path}.ori
		echo "mv file done"
		sudo mkdir -p ${db_path}		
	fi
fi
if [ ! -d "${db_path}" ]; then
       	sudo mkdir -p ${db_path}
fi
echo "mkdir DB log path"
if [ -d "${dlog_path}" ]; then
	echo ${dlog_path} "already exist"
	read -p ${dlog_path}" mv "${dlog_path}".ori : yes(enter key) or no(n key) : >" RET
	if [ "${RET}" == "n" ]; then
		echo "change DB log path"
		exit 0
	else
		echo "mv file"
		sudo mv -f ${dlog_path} ${dlog_path}.ori
		echo "mv file done"
		sudo mkdir -p ${dlog_path}/error
		echo "mkdir DB log path done"
	fi	
else
	sudo mkdir -p ${dlog_path}/error
	echo "mkdir DB log path done"
fi
echo "mkdir DB DATA path"
if [ -d "${dbdata_path}" ]; then
	echo ${dbdata_path} "already exist"
	read -p ${dbdata_path}" mv "${dbdata_path}".ori : yes(enter key) or no(n key) : >" RET
	if [ "${RET}" == "n" ]; then
		echo "change DB DATA path"
		exit 0
	else
		echo "mv file"
		sudo mv -f ${dbdata_path} ${dbdata_path}.ori
		echo "mv file done"
		sudo mkdir -p ${dbdata_path}		
	fi
	
else
	sudo mkdir -p ${dbdata_path}
	echo "mkdir DB DATA path done"
fi
sudo tar -xzf ../mariadb/"${DBFILE}"* -C ${db_path} --strip-components=1 >/dev/null 2>&1
sudo mkdir -p ${db_path}/conf-set
sudo ${db_path}/scripts/mysql_install_db --user=${MY_USER} --basedir=${db_path} --datadir=${dbdata_path}
echo "#####DB install done"
db_set
}

db_set()
{
echo "#####DB setting"
#### Symbolic link
result1=$(find /usr -name libncurses.so.5 2>/dev/null -print -quit)
result2=$(find /usr -name 'libncursesw.so.6*' 2>/dev/null -print -quit)
result3=$(find /usr -name libtinfo.so.5 2>/dev/null -print -quit)

if [ -z "$result1" ]; then
    if [ -n "$result2" ]; then
		first_word=$(echo "$result2" | awk -F'/' '{print $NF}')
		path_without_last=$(echo "$result2" | awk -F'/' -v OFS='/' '{$NF=""; print $0}')
		sudo ln -s "$result2" "$path_without_last/libncurses.so.5"
		result1=$(find /usr -name libncurses.so.5 2>/dev/null -print -quit)
		echo "$result1"
	else
		echo "libncursesw.so.6 check plz1"
	fi
fi

if [ -z "$result3" ]; then
    if [ -n "$result2" ]; then
		first_word=$(echo "$result2" | awk -F'/' '{print $NF}')
		path_without_last=$(echo "$result2" | awk -F'/' -v OFS='/' '{$NF=""; print $0}')
		sudo ln -s "$result2" "$path_without_last/libtinfo.so.5"
		result1=$(find /usr -name libtinfo.so.5 2>/dev/null -print -quit)
		echo "$result1"
	else
		echo "libncursesw.so.6 check plz2"
	fi
fi

#### mariadb.service 복사 및 수정
sudo cp -arp ${db_path}/support-files/systemd/mariadb.service ${db_path}/conf-set/mariadb.service
# 주석제거 
sudo sed -i '/^#/d' ${db_path}/conf-set/mariadb.service 
# 공백제거
sudo sed -i '/^\s*$/d' ${db_path}/conf-set/mariadb.service 
# ProtectHome=true-> false
sudo sed -i 's/ProtectHome=true/ProtectHome=false/' ${db_path}/conf-set/mariadb.service
# 경로 변경
sudo sed -i 's|/usr/local/mysql/bin/mariadbd|'${db_path}'/bin/mariadbd-safe|' ${db_path}/conf-set/mariadb.service
sudo sed -i 's|/usr/local/mysql/data|'${dbdata_path}'|' ${db_path}/conf-set/mariadb.service
sudo sed -i 's|/usr/local/mysql|'${db_path}'|g' ${db_path}/conf-set/mariadb.service
# 구문 추가
sudo sed -i'' -r -e "/Type=notify/a\NotifyAccess=all" ${db_path}/conf-set/mariadb.service
#### mariadb.service 복사 및 수정 done
sudo chown -R root:root ${db_path}/conf-set/mariadb.service
FIN="/usr/lib/systemd/system/mariadb.service"
if [ -e $FIN ] || [ -L $FIN ] ; then
	read -p "mariadb.service mv mariadb.servce_bak : y(enter key) n(exit) > " RET
	if [ "${RET}" = "n" ]; then
		echo "please mv mariadb.service"
		exit 0
	else
		sudo unlink /usr/lib/systemd/system/mariadb.service 
		sudo mv -f /usr/lib/systemd/system/mariadb.service /usr/lib/systemd/system/mariadb.service_bak 2>/dev/null
	fi
fi
#### galera_recovery 수정
sudo cp -arp ${db_path}/bin/galera_recovery ${db_path}/bin/galera_recovery.ori
sudo sed -i 's|/usr/local/mysql|'${db_path}'|' ${db_path}/bin/galera_recovery

#### con-set/my.cnf 생성 
sudo tee ${db_path}/conf-set/my.cnf > /dev/null << EOF
# This group is read both both by the client and the server
# use it for options that affect everything
#
[client-server]

[client]
default-character-set = utf8mb4

[mysql]
default-character-set = utf8mb4

[mysqld]
port=${DB_PORT}
datadir = ${dbdata_path}
basedir = ${db_path}
lower_case_table_names = 1
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max_allowed_packet = 256M
innodb_buffer_pool_size = 4G
skip-host-cache
skip-name-resolve
log-error = ${dlog_path}/error/error.err
max_heap_table_size = 268435456
tmp_table_size = 268435456
local_infile=0
EOF
sudo chmod 600 ${db_path}/conf-set/my.cnf

##DB 권한 수정
sudo chown -R ${MY_USER}:${MY_USER} ${db_path}
sudo chown -R ${MY_USER}:${MY_USER} ${dbdata_path}
sudo chown -R ${MY_USER}:${MY_USER} ${dlog_path}

#### /etc/my.cnf 확인
if [ -e "/etc/my.cnf" ] ||  [ -L "/etc/my.cnf" ]; then
	echo "/etc/my.cnf already exist"
	read -p "/etc/my.cnf mv /etc/my.cnf.ori : yes(enter key) or no(n key) : >" RET
	if [ "${RET}" == "n" ]; then
		echo "change my.cnf path "
		return 0
	else
		echo "mv file"
		sudo unlink /etc/my.cnf
		sudo mv -f /etc/my.cnf /etc/my.cnf.ori 2>/dev/null
		echo "mv file done"
	fi
fi
echo "##### /etc/my.cnf sybolic link"
sudo ln -s ${db_path}/conf-set/my.cnf /etc/my.cnf
#### mysql bin 파일 복사
if [ -e "/usr/bin/mysql" ]; then
	echo "/usr/bin/mysql already exist"
else
	sudo cp ${db_path}/bin/mysql /usr/bin/mysql
	echo ${db_path}"/bin/mysql /usr/bin/mysql"
fi

if [ -e "/usr/bin/mysqld" ]; then
	echo "/usr/bin/mysqld already exist"
else
	sudo cp ${db_path}/bin/mysqld /usr/bin/mysqld
	echo ${db_path}"/bin/mysqld /usr/bin/mysqld"
fi
if [ -e "/usr/bin/mysqldump" ]; then
	echo "/usr/bin/mysqldump already exist"
else
	sudo cp ${db_path}/bin/mysqldump /usr/bin/mysqldump
	echo ${db_path}"/bin/mysqldump /usr/bin/mysqldump"
fi
if [ -e "/usr/bin/mysqladmin" ]; then
	echo "/usr/bin/mysqladmin already exist"
else
	sudo cp ${db_path}/bin/mysqladmin /usr/bin/mysqladmin
	echo ${db_path}"/bin/mysqladmin /usr/bin/mysqladmin"
fi
	
#### mariadb.service 지정 및 기동
sudo ln -s ${db_path}/conf-set/mariadb.service /usr/lib/systemd/system/mariadb.service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable mariadb
echo "#####DB setting done"

if [[ $1 == "mariadb" ]]; then
	read -p "systemctl start mariadb.service : n(not running) , y(running) >" RET
	if [ "${RET}" == "y" ]; then
		sudo systemctl start mariadb
	elif [ "${RET}" == "n" ]; then
		echo "after running mariadb"
	else
		echo "not command y or n"
	fi
fi
}

miso_install()
{
## 수동시 디렉토리 체크
if [ ! -d "${miso_path}/webapps" ]; then
	sudo mkdir -p ${miso_path}/webapps
	sudo mkdir -p ${miso_path}/fileUpload
	sudo mkdir -p ${miso_path}/editorImage
	sudo mkdir -p ${miso_path}/miso_daemon
	sudo chown -R ${SERV_USER}:${SERV_USER} ${miso_path}
	echo "mkdir miso path done"
fi

if [ ! -d "${mlogs_path}/miso" ]; then
	sudo mkdir -p ${mlogs_path}/miso
	sudo mkdir -p ${mlogs_path}/miso_daemon
	sudo chown -R ${SERV_USER}:${SERV_USER} ${mlogs_path}/miso*
	echo "mkdir miso log path done"
fi

if [ ! -d "${install_path}/java" ]; then
	echo ${install_path}"/java not installed"
	exit 0
fi

#### miso.tar.gz > webapps 지정
if [ ! -e "../miso_pack/${webapps}" ]; then
	echo ${webapps}" not exist"
	exit 0
fi

sudo tar -xzf ../miso_pack/"${webapps}"* -C ${miso_path}/webapps --strip-components=1 >/dev/null 2>&1


#### system.properties설정값 복사
echo "####setting system.properties"
sudo cp ${miso_path}/webapps/WEB-INF/classes/properties/system.properties ${miso_path}/webapps/WEB-INF/classes/properties/system.properties.ori
db_setting

#### system.properties설정값 세팅
sudo sed -i 's|miso.db.url=jdbc:mysql:|#miso.db.url=jdbc:mysql:|' ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
sudo sed -i'' -r -e "/#miso.db.url=jdbc:mysql/a\miso.db.url=jdbc:mysql://"${DB_IP}":"${DB_PORT}"/"${DB_NAME}"?autoReconnect=true" ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
sudo sed -i -E 's/(miso.db.user=).*/\1'${DB_USER}'/' ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
sudo sed -i -E 's/(miso.db.password=).*/\1'${DB_PASSWD}'/' ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
sudo sed -i -E 's|(fileUpload.dir=).*|\1'${miso_path}/fileUpload'|' ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
echo "####setting system.properties done"

#### miso Log 설정
echo "####setting miso log"
LOG_LEVEL='DEBUG'
LOG_TYPE='file'
LOG_PATH=${mlogs_path}'/miso'

read -p "log level select ("${LOG_LEVEL}" : recommand(enter key) | INFO | ERROR): " RET
if [ ! -z "${RET}" ]; then
	LOG_LEVEL="${RET}"
fi
read -p "log type select ("${LOG_TYPE}" : recommand(enter key) | console): " RET
if [ ! -z "${RET}" ]; then
	LOG_TYPE="${RET}"
fi
read -p "log path ("${LOG_PATH}" : recommand(enter key)) : " RET
if [ ! -z "${RET}" ]; then
	LOG_PATH="${RET}"
fi
sudo cp ${miso_path}/webapps/WEB-INF/classes/logback.properties ${miso_path}/webapps/WEB-INF/classes/logback.properties.ori
sudo sed -i -E 's/(LOG_LEVEL=).*/\1'${LOG_LEVEL}'/' ${miso_path}/webapps/WEB-INF/classes/logback.properties
sudo sed -i -E 's/(LOG_OUTPUT_TYPE=).*/\1'${LOG_TYPE}'/' ${miso_path}/webapps/WEB-INF/classes/logback.properties
sudo sed -i -E 's|(LOG_HOME=).*|\1'${LOG_PATH}'|' ${miso_path}/webapps/WEB-INF/classes/logback.properties

#세션 타입아웃 10으로 수정.
sudo cp ${miso_path}/webapps/WEB-INF/web.xml ${miso_path}/webapps/WEB-INF/web.xml.ori
sudo sed -i 's/<session-timeout>30<\/session-timeout>/<session-timeout>10<\/session-timeout>/g' ${miso_path}/webapps/WEB-INF/web.xml

#LogBackup.xml
sudo cp ${miso_path}/webapps/WEB-INF/classes/logback.xml ${miso_path}/webapps/WEB-INF/classes/logback.xml.ori
sudo sed -i 's#<maxHistory>30</maxHistory>#<maxHistory>180</maxHistory>#g' ${miso_path}/webapps/WEB-INF/classes/logback.xml

echo "####setting miso log done"
# 소유권 수정
sudo chown -R ${SERV_USER}:${SERV_USER} ${miso_path}/webapps

#server.xml 내용 추가(디렉토리 내용)
echo "####setting miso server.xml"
sudo sed -i'' -r -e '/unpackWARs=/a\<Context path="/" docBase="'${miso_path}'/webapps" reloadable="true"/>' ${tomcat_path}/conf/server.xml
echo "####setting miso server.xml done"
}
db_setting()
{
read -p "HOST IP setting (Recommand(enter key):"${HOST_IP}"):  >" RET
if [ ! -z "${RET}" ]; then
	HOST_IP="${RET}"
fi
read -p "WAS IP setting (Recommand(enter key):"${WAS_IP}"):  >" RET
if [ ! -z "${RET}" ]; then
	WAS_IP="${RET}"
fi
read -p "DB IP setting (Recommand(enter key):"${DB_IP}"):  >" RET
if [ ! -z "${RET}" ]; then
	DB_IP="${RET}"
fi
read -p "DB PORT setting (Recommand(enter key):"${DB_PORT}"):  >" RET
if [ ! -z "${RET}" ]; then
	DB_PORT="${RET}"
fi
read -p "DB USER setting (Recommand(enter key):"${DB_USER}"):  >" RET
if [ ! -z "${RET}" ]; then
	DB_USER="${RET}"
fi
read -p "DB PASSWORD setting : >" DB_PASSWD

read -p "DB DATABASE NAME setting (Recommand(enter key):"${DB_NAME}"):  >" RET
if [ ! -z "${RET}" ]; then
	DB_NAME="${RET}"
fi
db_setting_check
}
db_setting_check()
{
echo "================================="
echo " HOST IP      : ${HOST_IP}"
echo " WAS IP      : ${WAS_IP}"
echo " DB IP        : ${DB_IP}"
echo " DB PORT      : ${DB_PORT}"
echo " DB USER      : ${DB_USER}"
echo " DB PASSWORD  : ${DB_PASSWD}"
echo " DB DATABASE  : ${DB_NAME}"
echo " next (press y or anykey)"
echo " modify (press n) "
echo "================================="
read RET
case $RET in
n)
db_setting
;;
y)
source_db_variable
;;
*)
source_db_variable
;;
esac
}

source_db_variable()
{
salt=$(printf $SERV_USER | md5sum | cut -c1-16)
ENC_VALUE=$(echo $DB_PASSWD | openssl enc -aes-256-cbc -a -S $salt -pbkdf2 -iter 100000 -pass pass:$MY_USER)
echo "source DB variable >> 01.util_Install_latest"
sudo sed -i "/HOST_IP=/ c\HOST_IP="${HOST_IP} 01.util_Install_latest
sudo sed -i "/WAS_IP=/ c\WAS_IP="${WAS_IP} 01.util_Install_latest
sudo sed -i "/DB_IP=/ c\DB_IP="${DB_IP} 01.util_Install_latest
sudo sed -i "/DB_PORT=/ c\DB_PORT="${DB_PORT} 01.util_Install_latest
sudo sed -i "/DB_USER=/ c\DB_USER="${DB_USER} 01.util_Install_latest
sudo sed -i "/DB_NAME=/ c\DB_NAME="${DB_NAME} 01.util_Install_latest
sudo sed -i "/DP_ENC=/ c\DP_ENC="${ENC_VALUE} 01.util_Install_latest
echo "source path variable  done"
}

editor()
{
#파일체크 
cd ../miso_pack/
if ls ce_*.zip >/dev/null 2>&1 || [ -d namo ]; then
	if [ ! -d namo ]; then
		mkdir namo
		unzip ce_* -d namo
	fi
else
	echo "check editor file"
fi

chown -R ${SERV_USER}:${SERV_USER} ../miso_pack/namo
chmod -R 700 ../miso_pack/namo

#war 안 namo plugin 파일 백업
sudo mv -f ${miso_path}/webapps/web/plugins/namo ${miso_path}/webapps/web/plugins/namo.ori
sudo cp -r ../miso_pack/namo ${miso_path}/webapps/web/plugins/namo

#websource/jsp , manage/jsp 백업
sudo cp -r ${miso_path}/webapps/web/plugins/namo/websource/jsp ${miso_path}/webapps/web/plugins/namo/websource/jsp.ori
#sudo cp -r ${miso_path}/webapps/web/plugins/namo/manage/jsp ${miso_path}/webapps/web/plugins/namo/manage/jsp.ori

#UTF-8 수정
sudo find ${miso_path}/webapps/web/plugins/namo/websource/jsp -type f -name "*.jsp" -exec sed -i '/^</s/UTF-8\>/utf-8/g' {} +
#sudo find ${miso_path}/webapps/web/plugins/namo/manage/jsp -type f -name "*.jsp" -exec sed -i '/^</s/UTF-8\>/utf-8/g' {} +

#세미콜론 분리
sudo find ${miso_path}/webapps/web/plugins/namo/websource/jsp -type f -name "*.jsp" -exec sed -i '/^</s/;charset=utf-8/; charset=utf-8/g' {} +
#sudo find ${miso_path}/webapps/web/plugins/namo/manage/jsp -type f -name "*.jsp" -exec sed -i '/^</s/;charset=utf-8/; charset=utf-8/g' {} +

#ImagePath.jsp 주석 제거 및 파일 수정
sudo sed -i 's/\/\*//g' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's/\*\///g' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's|String namoFilePhysicalPath.*|String namoFilePhysicalPath = "'${miso_path}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's|String namoFlashPhysicalPath.*|String namoFlashPhysicalPath = "'${miso_path}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's|String namoImagePhysicalPath.*|String namoImagePhysicalPath = "'${miso_path}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp

cnt=0
while [ "$cnt" == "0" ]; do 
	read -p "insert URL (ex : http://localhost.com:8080) >" URL
	read -p "URL = $URL / y(enterkey) n(change) >" RET1
	case $RET1 in
	n)
	;;
	y)
	cnt=1
	;;
	*)
	cnt=1
	;;
	esac
done
sudo sed -i 's|String namoFileUPath =.*|String namoFileUPath = "'${URL}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's|String namoFlashUPath =.*|String namoFlashUPath = "'${URL}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's|String namoImageUPath =.*|String namoImageUPath = "'${URL}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's|useExternalServer =.*|useExternalServer = "'${URL}'/editorImage/namo/" + "websource/jsp/ImageUploadExecute.jsp";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp

#Config.xml 파일 수정
sudo cp -r ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml.ori
sudo sed -i 's|<ImageSavePath></ImageSavePath>|<ImageSavePath>'${miso_path}'/editorImage</ImageSavePath>|g' ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml
sudo sed -i 's|<UploadFileViewer>false</UploadFileViewer>|<UploadFileViewer></UploadFileViewer>|g' ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml
sudo sed -i 's#<CreateTab>0|1|2</CreateTab>#<CreateTab>0|2</CreateTab>#g' ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml
sudo sed -i 's#<ReturnKeyActionBR></ReturnKeyActionBR>#<ReturnKeyActionBR>True</ReturnKeyActionBR>#g' ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml
sudo sed -i 's#<SupportBrowser></SupportBrowser>#<SupportBrowser>0</SupportBrowser>#g' ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml

if [ -d "${miso_path}/editorImage/namo" ]; then
	echo ${miso_path}"/editorImage/namo already exist"
	echo "mv file"
	sudo mv -f ${miso_path}/editorImage/namo ${miso_path}/editorImage/namo.ori
	echo "mv file done"
fi

sudo cp -r ${miso_path}/webapps/web/plugins/namo ${miso_path}/editorImage/.

#소유권 수정
sudo chown -R ${SERV_USER}:${SERV_USER} ${miso_path}/webapps
sudo chown -R ${SERV_USER}:${SERV_USER} ${miso_path}/editorImage
#server.xml 수정
sudo sed -i'' -r -e '/unpackWARs=/a\<Context path="/editorImage" docBase="'${miso_path}'/editorImage" reloadable="true"/>' ${tomcat_path}/conf/server.xml

cd -
}
DB_RUN()
{
echo "#### DB RUN"
if [ "${DBINSTALLQ}" == "n" ]; then
	echo "DB NOT INSTALL"
else
	sudo systemctl start mariadb.service || true
fi
}
tomcat_RUN()
{
echo "#### tomcat RUN"
sudo systemctl start tomcat.service || true
}

firewalld_setting()
{
echo "####firewalld setting"
HTTP=8080
read -p "web port is "${HTTP}" :  y(enter key) or no(port insert) >" RET
	if [ ! -z "${RET}" ]; then
		HTTP="${RET}"
	fi
read -p "firewall setting web port "${HTTP}" down : y(enter key) or no(n key) > " RET
case $RET in
n)
;;
y)
sudo firewall-cmd --permanent --zone=public --add-port=${HTTP}/tcp
;;
*)
sudo firewall-cmd --permanent --zone=public --add-port=${HTTP}/tcp
;;
esac

read -p "DB port is "${DB_PORT}" :  y(enter key) or no(port insert) >" RET
	if [ ! -z "${RET}" ]; then
		DB_PORT="${RET}"
	fi
read -p "firewall setting web port "${DB_PORT}" down : y(enter key) or no(n key) > " RET
case $RET in
n)
;;
y)
sudo firewall-cmd --permanent --zone=public --add-port=${DB_PORT}/tcp
;;
*)
sudo firewall-cmd --permanent --zone=public --add-port=${DB_PORT}/tcp
;;
esac
sudo firewall-cmd --reload

echo "####firewalld setting done"
}

source_sql()
{
	echo "db setting"
	if [ ! -e "../miso_pack/${init_sql}" ]; then
		echo ${init_sql}" not exist"
		exit 0
	fi
	
	db_setting_check
	echo "schema & user set"
	mysql -u root -Bse "CREATE DATABASE \`${DB_NAME}\` /*!40100 COLLATE 'utf8mb4_unicode_ci'*/;"
	mysql -u root -Bse "CREATE USER '${DB_USER}'@'${WAS_IP}' IDENTIFIED BY '${DB_PASSWD}';"
	mysql -u root -Bse "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWD}';"
	mysql -u root -Bse "GRANT all PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${WAS_IP}' IDENTIFIED BY '${DB_PASSWD}';"
	mysql -u root -Bse "GRANT all PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWD}';"
	mysql -u root -Bse "FLUSH PRIVILEGES"
	
	mysql -u root ${DB_NAME} < ../miso_pack/${init_sql}
	if [ -n "${alter_sql}" ] && [ -e "../test/${alter_sql}" ]; then
		mysql -u root ${DB_NAME} --force < ../miso_pack/${alter_sql}
	fi
	
	echo "db setting done"
}
main()
{
	case "$1" in
		check)
			check_file&&check_sel
			;;
		install)
			db_install&&tomcat_install&&makedir&&miso_install&&
			DB_RUN&&source_sql&&firewalld_setting&&tomcat_RUN
			;;
		tomcat)
			tomcat_install 
			;;
		db)
			db_install 
			;;
		firewalld)
			firewalld_setting
			;;
		webappsset)
			makedir&&miso_install
			;;
		dbset)
			source_sql
			;;
		editor)
			editor
			;;
		*)
			echo "Usage: $0 {check|install}"
			exit 0
			;;
	esac
}

main "$@"
