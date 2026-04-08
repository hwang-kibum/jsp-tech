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
elif [ "Permissive" == ${CURRENT_SEL} ] ;then
	echo "CURRENT SELINUX : ${CURRENT_SEL}"
	if [ "disabled" != ${CONF_SEL} ]; then
		read -p "change SELINUX DISABLED : yes(enter key) or no(n key):  >" RET
			if [ "${RET}" = "n" ]; then
				echo "change SELINUX Config later"
			else
				sudo sed -i 's/SELINUX='${CONF_SEL}'/SELINUX=disabled/g' /etc/selinux/config
			fi
	fi
elif [ "Disabled" == ${CURRENT_SEL} ];
	echo "CURRENT SELINUX : ${CURRENT_SEL}"
then
	echo "check selinux config"
fi
checkp=1
}
dircheck()
{
    SRC="$1"
    [ -e "$SRC" ] || [ -L "$SRC" ] || return 0
    BACKUP="${SRC}_bak_$(date +%Y%m%d_%H%M)"
    sudo mv "$SRC" "$BACKUP" || return 1
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
if [[ "$RET" == "y" || -z "$RET" ]]; then
	source_variable
else
	check_path
fi
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
decoding()
{
exec 3>&1      
exec > /dev/tty
salt=$(printf $SERV_USER | md5sum | cut -c1-16)
DEC_VALUE=$(echo $1 | openssl enc -aes-256-cbc -a -d -S $salt -pbkdf2 -iter 100000 -pass pass:$MY_USER 2>/dev/null)
if [[ "$DEC_VALUE" == "" ]]; then
	#echo "incorrect data : " $1
	echo ""
else
	echo $DEC_VALUE
fi
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
java_install()
{
echo "#####java install"
dircheck ${install_path}/java
sudo mkdir -p ${install_path}/java
sudo tar -xzvf ../jdk/"${JAVAFILE}"* -C ${install_path}/java --strip-components=1 >/dev/null 2>&1
sudo chown -R ${SERV_USER}:${SERV_USER} ${install_path}/java
#if ! grep -q "^export JAVA_HOME=" /etc/profile; then
#	sudo sh -c 'echo "export JAVA_HOME=\"'${install_path}'/java\"" >> /etc/profile '
#	sudo sh -c 'echo "export PATH=\"\$JAVA_HOME/bin:\$PATH\"" >> /etc/profile'
#	sudo sh -c 'echo "export CLASSPATH=\"\$JAVA_HOME/jre:/lib/ext:\$JAVA_HOME/lib/tools.jar\"" >>/etc/profile'
#fi
echo "#####java install done"
#echo "##### source /etc/profile #####"
}
tomcat_install()
{
if [ ! -e "../jdk/${JAVAFILE}" ]; then
	echo ${JAVAFILE}" not exist"
	exit 0
elif [ ! -e "../tomcat/${TOMCATFILE}" ]; then
	echo ${TOMCATFILE}" not exist"
	exit 0
fi
if [ "${checkuserserv}" == "0" ]; then
check_user_serv
fi

echo "checking java install"
if [ -d "${install_path}/java" ]; then
	echo ${install_path}"/java installed"
else
	java_install
fi
checking
dircheck /etc/logrotate.d/tomcat.logrotate
dircheck /usr/lib/systemd/system/tomcat.service
###################################################################
echo "#####tomcat install"
dircheck ${tomcat_path}
sudo mkdir -p ${tomcat_path}	
dircheck ${tlog_path}
sudo mkdir -p ${tlog_path}	
sudo mkdir -p ${tomcat_path}/conf-set
sudo tar -xzf ../tomcat/"${TOMCATFILE}"* -C ${tomcat_path} --strip-components=1 >/dev/null 2>&1

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

## LB file set
sudo tee ${tomcat_path}/conf-set/lb.txt > /dev/null << EOF
###########################Engine tag under line setting  <Engine name="Catalina" defaultHost="localhost">
<!-- jvmRoute change -->
<Engine name="Catalina" defaultHost="localhost" jvmRoute="tomcatA">   
<Cluster className="org.apache.catalina.ha.tcp.SimpleTcpCluster">
<Manager className="org.apache.catalina.ha.session.DeltaManager"
expireSessionsOnShutdown="false"
notifyListenersOnReplication="true"
notifySessionListenersOnReplication="true"
notifyContainerListenersOnReplication="true"/>

<Channel className="org.apache.catalina.tribes.group.GroupChannel">
<Valve className="org.apache.catalina.ha.tcp.ReplicationValve" filter=".*\.gif|.*\.js|.*\.jpeg|.*\.jpg|.*\.png|.*\.htm|.*\.html|.*\.css|.*\.txt" />

<!--local IP change -->
<Receiver className="org.apache.catalina.tribes.transport.nio.NioReceiver"
address="1.1.1.1"   
port="4000"
selectorTimeout="5000"
maxThreads="6"/>

<Sender className="org.apache.catalina.tribes.transport.ReplicationTransmitter">
<Transport className="org.apache.catalina.tribes.transport.nio.PooledParallelSender"/>
</Sender>

<Membership className="org.apache.catalina.tribes.membership.StaticMembershipService">

<!-- 로컬(A) -->
<!--uniqueId change -->
<LocalMember className="org.apache.catalina.tribes.membership.StaticMember"
uniqueId="{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,1}"/>   

<!-- 원격(B) -->
<!--remote IP, uniqueId change -->
<Member className="org.apache.catalina.tribes.membership.StaticMember"
host="1.1.1.2"
port="4000"
uniqueId="{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,2}"/>
</Membership>

<Interceptor className="org.apache.catalina.tribes.group.interceptors.TcpPingInterceptor"/>
<Interceptor className="org.apache.catalina.tribes.group.interceptors.TcpFailureDetector"/>
<Interceptor className="org.apache.catalina.tribes.group.interceptors.MessageDispatchInterceptor"/>
</Channel>
<Valve className="org.apache.catalina.ha.tcp.ReplicationValve" filter="" />
<Valve className="org.apache.catalina.ha.session.JvmRouteBinderValve"/>
<ClusterListener className="org.apache.catalina.ha.session.ClusterSessionListener"/>
</Cluster>

##########################################################
check web.xml <distributable/>
##########################################################
EOF

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

chekp=$(command -v logrotate)
if [ -z $chekp ]; then
        echo "check logrotate command"
else
	sudo cp -arp ${tomcat_path}/conf-set/tomcat.logrotate /etc/logrotate.d/tomcat.logrotate
	sudo chown -R root:root ${tomcat_path}/conf-set/tomcat.logrotate
fi
echo "#####tomcat setting done"
tomcat_service
}
tomcat_service()
{
echo "#####make tomcat service"
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

echo "#####copy tomcat service"
sudo cp -arp ${tomcat_path}/conf-set/tomcat.service /usr/lib/systemd/system/tomcat.service

#total owner change
sudo chown -R ${SERV_USER}:${SERV_USER} ${tomcat_path}

#ls -alt /usr/lib/systemd/system | grep tomcat.service
sudo systemctl daemon-reload
sudo systemctl enable tomcat
echo "#####make tomcat service done"

if [[ $1 == "tomcat" ]]; then
	read -p "systemctl start tomcat.service : n(not running) , y(running) >" RET
	if [[ "${RET}" == "y" || -z "${RET}" ]]; then
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
if [ ! -e "../mariadb/${DBFILE}" ]; then
	echo ${DBFILE}" not exist"
	exit 0
fi
echo "#####DB install"
read -p "INSTALL MARIADB (install(y or anykey) | not install (n key)) >" DBINSTALLQ
if [[ "$DBINSTALLQ" == "n" ]]; then
	echo "use other server DB"
	return 0
fi
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
		exit 0
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
		exit 0
	fi
fi
#### libcrypt 버전 확인
result1=$(find /usr -name libcrypt.so.1 2>/dev/null -print -quit)
version=$(cat /etc/*release* | grep VERSION_ID | cut -d "=" -f2 | tr -d '"')
if [[ -z "$result1" && $version == 10.* ]]; then
	rpm -ivh ../mariadb/libxcrypt-compat-4.4.36-10.el10.x86_64.rpm
elif [ -n "$result1" ]; then
	echo "check $result1"
else
	echo "check libcrypt.so.1"
	exit 0
fi

checking
if [ "${checkuserdb}" == "0" ]; then
check_user_db
fi
dircheck ${db_path}
dircheck ${dlog_path}
dircheck ${dbdata_path}
dircheck /usr/lib/systemd/system/mariadb.service 
dircheck /etc/my.cnf
######################################################################################
sudo mkdir -p ${db_path}
sudo mkdir -p ${dbdata_path}
sudo mkdir -p ${dlog_path}/error
sudo tar -xzf ../mariadb/"${DBFILE}"* -C ${db_path} --strip-components=1 >/dev/null 2>&1
sudo mkdir -p ${db_path}/conf-set
sudo ${db_path}/scripts/mysql_install_db --user=${MY_USER} --basedir=${db_path} --datadir=${dbdata_path}
echo "#####DB install done"
db_set
}
db_set()
{
echo "#####DB setting"
#### mariadb.service 복사 및 수정
sudo cp -arp ${db_path}/support-files/systemd/mariadb.service ${db_path}/conf-set/mariadb.service
sudo sed -i '/^#/d' ${db_path}/conf-set/mariadb.service 
sudo sed -i '/^\s*$/d' ${db_path}/conf-set/mariadb.service 
sudo sed -i 's/ProtectHome=true/ProtectHome=false/' ${db_path}/conf-set/mariadb.service
sudo sed -i 's|/usr/local/mysql/bin/mariadbd|'${db_path}'/bin/mariadbd-safe|' ${db_path}/conf-set/mariadb.service
sudo sed -i 's|/usr/local/mysql/data|'${dbdata_path}'|' ${db_path}/conf-set/mariadb.service
sudo sed -i 's|/usr/local/mysql|'${db_path}'|g' ${db_path}/conf-set/mariadb.service
sudo sed -i'' -r -e "/Type=notify/a\NotifyAccess=all" ${db_path}/conf-set/mariadb.service
sudo sed -i 's|^User=.*|User='${MY_USER}'|' ${db_path}/conf-set/mariadb.service
sudo sed -i 's|^Group=.*|Group='${MY_USER}'|' ${db_path}/conf-set/mariadb.service
sudo chown -R root:root ${db_path}/conf-set/mariadb.service
sudo cp -arp ${db_path}/conf-set/mariadb.service /usr/lib/systemd/system/mariadb.service


sudo cp -arp ${db_path}/bin/galera_recovery ${db_path}/bin/galera_recovery.ori
sudo sed -i 's|/usr/local/mysql|'${db_path}'|' ${db_path}/bin/galera_recovery

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
#sudo ln -s ${db_path}/conf-set/mariadb.service /usr/lib/systemd/system/mariadb.service
#sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable mariadb
echo "#####DB setting done"

if [[ $1 == "mariadb" ]]; then
	read -p "systemctl start mariadb.service : n(not running) , y(running) >" RET
	if [ "${RET}" == "y" ]; then
		sudo systemctl start mariadb
	elif [[ "${RET}" == "n" || -z "${RET}" ]]; then
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
################################################################################################
sudo tar -xzf ../miso_pack/"${webapps}"* -C ${miso_path}/webapps --strip-components=1 >/dev/null 2>&1

#### system.properties설정값 복사
echo "####setting system.properties"
sudo cp -arp ${miso_path}/webapps/WEB-INF/classes/properties/system.properties ${miso_path}/webapps/WEB-INF/classes/properties/system.properties.ori
db_setting

#### system.properties설정값 세팅
sudo sed -i 's|miso.db.url=jdbc:mysql:|#miso.db.url=jdbc:mysql:|' ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
sudo sed -i'' -r -e "/#miso.db.url=jdbc:mysql/a\miso.db.url=jdbc:mysql://"${DB_IP}":"${DB_PORT}"/"${DB_NAME}"?autoReconnect=true" ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
sudo sed -i -E 's/(miso.db.user=).*/\1'${DB_USER}'/' ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
sudo sed -i -E 's/(miso.db.password=).*/\1'${DB_PASSWD}'/' ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
sudo sed -i -E 's|(fileUpload.dir=).*|\1'${miso_path}/fileUpload'|' ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
sudo sed -i -E 's|(credentials.properties.file.path=).*|\1'${miso_path}/webapps/WEB-INF/classes/properties/credentials.properties'|' ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
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

#세션 타임아웃 10으로 수정.
sudo cp ${miso_path}/webapps/WEB-INF/web.xml ${miso_path}/webapps/WEB-INF/web.xml.ori
sudo sed -i 's/<session-timeout>30<\/session-timeout>/<session-timeout>10<\/session-timeout>/g' ${miso_path}/webapps/WEB-INF/web.xml

#LogBackup.xml
sudo cp ${miso_path}/webapps/WEB-INF/classes/logback.xml ${miso_path}/webapps/WEB-INF/classes/logback.xml.ori
sudo sed -i 's#<maxHistory>30</maxHistory>#<maxHistory>180</maxHistory>#g' ${miso_path}/webapps/WEB-INF/classes/logback.xml

echo "####setting miso log done"
# 소유권 및 권한 수정
sudo chown -R ${SERV_USER}:${SERV_USER} ${miso_path}/webapps
sudo chmod -R 750 ${miso_path}/webapps

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
echo " WAS IP       : ${WAS_IP}"
echo " DB IP        : ${DB_IP}"
echo " DB PORT      : ${DB_PORT}"
echo " DB USER      : ${DB_USER}"
#echo " DB PASSWORD  : ${DB_PASSWD}"
echo " DB PASSWORD  : ${DB_PASSWD}" | tee /dev/tty | sed 's/\(DB PASSWORD.*:\).*/\1 ********/' >> "$SCRIPTLOGFILE"
echo " DB DATABASE  : ${DB_NAME}"
echo " next (press y or anykey)"
echo " modify (press n) "
echo "================================="
read RET
if [[ "$RET" == "y" || -z "$RET" ]]; then
	source_db_variable
else
	db_setting
fi
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
if ls ce_*.zip >/dev/null 2>&1 || [ "$(ls -A namo 2>/dev/null)" ]; then
	if [ ! -d namo ] && [ "$(command -v unzip)" ]; then
		mkdir namo
		unzip ce_* -d namo
	fi
else
	echo "check editor file or unzip"
	exit 0
fi

sudo chown -R ${SERV_USER}:${SERV_USER} ../miso_pack/namo
sudo chmod -R 700 ../miso_pack/namo

#war 안 namo plugin 파일 백업
dircheck ${miso_path}/webapps/web/plugins/namo
sudo cp -arp ../miso_pack/namo ${miso_path}/webapps/web/plugins/namo

#websource/jsp , manage/jsp 백업
sudo cp -arp ${miso_path}/webapps/web/plugins/namo/websource/jsp ${miso_path}/webapps/web/plugins/namo/websource/jsp.ori
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
sudo sed -i -E 's|^//imagePhysicalPath =|imagePhysicalPath =|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i -E 's|^//imageUPath =|imageUPath =|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's|String namoFilePhysicalPath.*|String namoFilePhysicalPath = "'${miso_path}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's|String namoFlashPhysicalPath.*|String namoFlashPhysicalPath = "'${miso_path}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's|String namoImagePhysicalPath.*|String namoImagePhysicalPath = "'${miso_path}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i -E 's|^imagePhysicalPath = ".*|imagePhysicalPath = "'${miso_path}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp

while true; do
	read -p "insert URL (ex : http://localhost.com:8080) >" URL
	read -p "URL = $URL / y(enterkey) n(change) >" RET1
	if [[ "$RET" == "y" || -z "$RET" ]]; then
		break
	fi
done
sudo sed -i 's|String namoFileUPath =.*|String namoFileUPath = "'${URL}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's|String namoFlashUPath =.*|String namoFlashUPath = "'${URL}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's|String namoImageUPath =.*|String namoImageUPath = "'${URL}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i -E 's|^imageUPath = ".*|imageUPath = "'${URL}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
#sudo sed -i 's|useExternalServer =.*|useExternalServer = "'${URL}'/editorImage/namo/" + "websource/jsp/ImageUploadExecute.jsp";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp

#Config.xml 파일 수정
sudo cp -arp ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml.ori
sudo sed -i 's|<ImageSavePath></ImageSavePath>|<ImageSavePath>'${miso_path}'/editorImage</ImageSavePath>|g' ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml
sudo sed -i 's|<UploadFileViewer>false</UploadFileViewer>|<UploadFileViewer></UploadFileViewer>|g' ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml
sudo sed -i 's#<CreateTab>0|1|2</CreateTab>#<CreateTab>0|2</CreateTab>#g' ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml
sudo sed -i 's#<ReturnKeyActionBR></ReturnKeyActionBR>#<ReturnKeyActionBR>True</ReturnKeyActionBR>#g' ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml
sudo sed -i 's#<SupportBrowser></SupportBrowser>#<SupportBrowser>0</SupportBrowser>#g' ${miso_path}/webapps/web/plugins/namo/config/xmls/Config.xml

dircheck ${miso_path}/editorImage/namo
sudo cp -arp ${miso_path}/webapps/web/plugins/namo ${miso_path}/editorImage/.

#소유권 수정
sudo chown -R ${SERV_USER}:${SERV_USER} ${miso_path}/webapps
sudo chown -R ${SERV_USER}:${SERV_USER} ${miso_path}/editorImage
#server.xml 수정
sudo sed -i'' -r -e '/unpackWARs=/a\<Context path="/editorImage" docBase="'${miso_path}'/editorImage" reloadable="true"/>' ${tomcat_path}/conf/server.xml
cd -
echo "namo setting done"
}
crossviewer()
{
cd ../miso_pack/
if ls CrossViewer*.zip >/dev/null 2>&1 || [ "$(ls -A crossViewer 2>/dev/null)" ]; then
	if [ ! -d crossViewer ] && [ "$(command -v unzip)" ]; then
		mkdir crossViewer
		unzip CrossViewer* -d crossViewer
	fi
else
	echo "check crossviewer file or unzip"
	exit 0
fi

sudo chown -R ${SERV_USER}:${SERV_USER} ../miso_pack/crossViewer
sudo chmod -R 700 ../miso_pack/crossViewer

#war 안 crossViewer plugin 파일 백업
dircheck ${miso_path}/webapps/web/plugins/crossViewer
dircheck ${miso_path}/editorImage/crossViewer
sudo cp -arp ../miso_pack/crossViewer ${miso_path}/webapps/web/plugins/crossViewer
sudo cp -arp ../miso_pack/crossViewer ${miso_path}/editorImage/.
sudo sed -i 's|String namoFileUPath =.*|String namoFileUPath = "'${URL}'/editorImage";|' ${miso_path}/webapps/web/plugins/namo/websource/jsp/ImagePath.jsp
sudo sed -i 's|preview.temp.file.abs.path=.*|preview.temp.file.abs.path='${miso_path}'/webapps/web/plugins/crossViewer/viewerTempFile|' ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
echo "CrossViewer setting done"
}
ssl()
{
mkdir -p ${miso_path}/ssl

if [ ! -e "../jdk/${JAVAFILE}" ]; then
	echo ${JAVAFILE}" not exist"
	exit 0
elif [ ! -e "../tomcat/${TOMCATFILE}" ]; then
	echo ${TOMCATFILE}" not exist"
	exit 0
fi

echo "checking java install"
if [ -d "${install_path}/java" ]; then
	echo ${install_path}"/java installed"
else
	read -p "install java : y(enter key) n(not install) >" RET
	if [[ "$RET" == "y" || -z "$RET" ]]; then
		java_install
	else
		echo "please install java"
		exit 0
	fi
fi
while true; do
    read -s -p "Keystore Password: " KEYPASS
    echo
    read -s -p "Confirm Password: " KEYPASS2
    echo

    if [[ "$KEYPASS" == "$KEYPASS2" ]]; then
        break
    else
        echo "Password mismatch. Try again."
    fi
done

${install_path}/java/bin/keytool -genkey -storetype jks -keystore jsp.jks -storepass "$KEYPASS" -keypass "$KEYPASS" -keyalg RSA -keysize 2048 -startdate "${DATE//-//} 00:00:00" -validity 3650 -dname "CN=jsp, OU=jsp, O=jsp, L=jsp, ST=jsp, C=jsp"
mv jsp.jks ${miso_path}/ssl
chown -R ${SERV_USER}:${SERV_USER} ${miso_path}/ssl

echo "
	<Connector port=\"8443\" protocol=\"org.apache.coyote.http11.Http11NioProtocol\"
               maxThreads=\"150\" SSLEnabled=\"true\" maxParameterCount=\"1000\"
               URIEncoding=\"UTF-8\" enableLookups=\"false\" server=\"server\" scheme=\"https\" secure=\"true\">
        <SSLHostConfig protocols=\"TLSv1.2+TLSv1.3\">
                <Certificate certificateKeystoreFile=\"${miso_path}/ssl/jsp.jks\" certificateKeystorePassword=\"${KEYPASS}\" type=\"RSA\" />
        </SSLHostConfig>
    </Connector>
########################################################################
"
read -p "Press Enter > Open server.xml file"
vi ${tomcat_path}/conf/server.xml
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
echo "firewall setting rule"
ZONE="public"

declare -A TYPE_MAP
declare -A VALUE_MAP

firewalld_list()
{
echo "===== FIREWALL RULE LIST ====="
TYPE_MAP=()
VALUE_MAP=()
mapfile -t PORTS < <(sudo firewall-cmd --zone=$ZONE --list-ports | tr ' ' '\n')
mapfile -t RICH_RULES < <(sudo firewall-cmd --zone=$ZONE --list-rich-rules)
INDEX=1

for p in "${PORTS[@]}"; do
    [ -z "$p" ] && continue
    echo "$INDEX) port  $p"
    TYPE_MAP[$INDEX]="port"
    VALUE_MAP[$INDEX]="$p"
    ((INDEX++))
done
for r in "${RICH_RULES[@]}"; do
    echo "$INDEX) rich  $r"
    TYPE_MAP[$INDEX]="rich"
    VALUE_MAP[$INDEX]="$r"
    ((INDEX++))
done
}

firewalld_add()
{
echo "input type example"
echo "1) port, protocol(tcp:omitted): 3306,tcp"
echo "2) source_ip, port, protocol(tcp:omitted): 10.10.10.5,3306,tcp"
echo
read -p "data : " INPUT
IFS=',' read -r data1 data2 data3 <<< "$INPUT"
PROTO="tcp"
if [ -n "$data3" ]; then
    PROTO="$data3"
elif [ -n "$data2" ] && [[ "$data2" =~ ^(tcp|udp)$ ]]; then
    PROTO="$data2"
fi
if [[ "$data1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IP="$data1"
    PORT="$data2"
    echo "rich rule add"
    sudo firewall-cmd --permanent --zone=$ZONE \
    --add-rich-rule="rule family=\"ipv4\" source address=\"$IP\" port port=\"$PORT\" protocol=\"$PROTO\" accept"
else
    PORT="$data1"
    echo "port add"
    sudo firewall-cmd --permanent --zone=$ZONE --add-port=${PORT}/${PROTO}
fi
sudo firewall-cmd --reload
}

firewalld_remove()
{
    firewalld_list
    echo
    read -p "remove number : " NUM
    if ! [[ "$NUM" =~ ^[0-9]+$ ]]; then
        echo "invalid input"
        return
    fi
    TYPE=${TYPE_MAP[$NUM]}
    VALUE=${VALUE_MAP[$NUM]}

    if [ -z "$TYPE" ]; then
        echo "invalid number"
        return
    fi
    if [ "$TYPE" == "port" ]; then
        echo "remove port : $VALUE"
        sudo firewall-cmd --permanent --zone=$ZONE --remove-port=$VALUE
    else
        echo "remove rich rule"
        sudo firewall-cmd --permanent --zone=$ZONE --remove-rich-rule="$VALUE"
    fi
    sudo firewall-cmd --reload
    echo "done"
}

while true; do
    read -p "[[ add (1), remove (2) list (3) exit (0) ]] > " num
    case $num in
        1)  echo "=========================================="
            firewalld_add
            echo "=========================================="
            ;;
        2)  echo "=========================================="
            firewalld_remove
            echo "=========================================="
            ;;
        3)  echo "=========================================="
            firewalld_list
            echo "=========================================="
            ;;
        0)  break
            ;;
        *)  echo "invalid menu"
            ;;
    esac
done
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
	sudo mysql -u root -Bse "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
	sudo mysql -u root -Bse "CREATE DATABASE \`${DB_NAME}\` /*!40100 COLLATE 'utf8mb4_unicode_ci'*/;"
	sudo mysql -u root -Bse "CREATE USER IF NOT EXISTS '${DB_USER}'@'${WAS_IP}' IDENTIFIED BY '${DB_PASSWD}';"
	sudo mysql -u root -Bse "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWD}';"
	sudo mysql -u root -Bse "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${WAS_IP}';"
	sudo mysql -u root -Bse "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
	sudo mysql -u root -Bse "FLUSH PRIVILEGES"
	
	sudo mysql -u root ${DB_NAME} < ../miso_pack/${init_sql}
	if [ -n "${alter_sql}" ] && [ -e "../miso_pack/${alter_sql}" ]; then
		sudo mysql -u root ${DB_NAME} --force < ../miso_pack/${alter_sql}
	fi
	
	#mkdir -p sql
	#command -v unzip
	#mv ../miso_pack/miso.core.web-2.0.war ../miso_pack/miso.core.web-2.0.zip
	#unzip -j miso.core.web-2.0.zip "WEB-INF/classes/database/mysql/*" -d sql
	echo "db setting done"
}
setcap()
{
echo "setcap start"
sudo setcap "cap_net_bind_service=+ep" ${install_path}/java/bin/java
sudo getcap ${install_path}/java/bin/java

sudo bash -c "cat > /etc/ld.so.conf.d/java.conf" << EOF
${install_path}/java/jre/lib/amd64/jli/
EOF

sudo ldconfig | grep java
echo "setcap done"
}
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
		check)
			check_file&&check_sel
			;;
		install)
			check_file&&check_sel&&
			db_install&&tomcat_install&&makedir&&miso_install&&
			DB_RUN&&source_sql&&firewalld_setting&&tomcat_RUN
			;;
		tomcat)
			check_file&&check_sel&&
			tomcat_install 
			;;
		db)
			check_file&&check_sel&&
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
		namo)
			editor
			;;
		viewer)
			crossviewer
			;;
		ssl)
			ssl
			;;
		setcap)
			setcap
			;;
		decode)
			decoding $2
			;;
		 help|--help|-h)
			usage
			;;
		*)
			echo "Usage: $0 {check|install|help}"
			exit 0
			;;
	esac
}

main "$@"
