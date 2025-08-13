#!/bin/bash
cd "$(dirname "$0")"
source 00.util_Install_latest
SCRIPTLOGFILE=miso_total.log
exec > >(tee -a "$SCRIPTLOGFILE") 2>&1
echo $DATE" is running" >> ${SCRIPTLOGFILE}
#nohup bash -c "sleep 300; cat /dev/null > "${SCRIPTLOGFILE} > /dev/null 2>&1 &

DBINSTALLQ=y
checkp=0
checkuserserv=0
checkuserdb=0
DB_PASSWD=Wlfks@09!@#

check_file()
{
TEXT=$(cat ../miso_pack/${MISOWAR}.md5)
HS_VL=$(md5sum ../miso_pack/${MISOWAR} | awk '{print $1}')

if [ ! -e "../jdk/${JAVAFILE}" ]; then
	echo ${JAVAFILE}" not exist"
	exit 0
elif [ ! -e "../tomcat/${TOMCATFILE}" ]; then
	echo ${TOMCATFILE}" not exist"
	exit 0
elif [ ! -e "../mariadb/${DBFILE}" ]; then
	echo ${DBFILE}" not exist"
	exit 0
elif [ ! -e "../miso_pack/${MISOWAR}" ]; then
	echo ${MISOWAR}" not exist"
	exit 0
elif [ ! -e "../miso_pack/${MISOWAR}.md5" ]; then
	echo ${MISOWAR}".md5 not exist"	
	exit 0
elif [ ${TEXT} != ${HS_VL} ]; then
	echo " md5 text  : ${TEXT}"
	echo "hash value : ${HS_VL}"
	exit 0
else 
	echo "install ok"
fi
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
sudo rm -rf ${miso_path}
sudo rm -rf ${mlogs_path}
sudo mkdir -p ${miso_path}/webapps
sudo mkdir -p ${miso_path}/fileUpload
sudo mkdir -p ${miso_path}/editorImage
sudo mkdir -p ${miso_path}/miso_daemon
sudo mkdir -p ${mlogs_path}/miso
sudo mkdir -p ${mlogs_path}/miso_daemon
sudo chown -R ${SERV_USER}:${SERV_USER} ${miso_path}
sudo chown -R ${SERV_USER}:${SERV_USER} ${mlogs_path}
}

install_java()
{
echo "#####java install"
if [ ! -d "${install_path}/java" ]; then
sudo rm -rf ${install_path}/java
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

#### tomcat dir 생성
sudo rm -rf ${tomcat_path}
sudo mkdir -p ${tomcat_path}

sudo tar -xzf ../tomcat/"${TOMCATFILE}"* -C ${tomcat_path} --strip-components=1 >/dev/null 2>&1
sudo mkdir -p ${tomcat_path}/conf-set

#### tomcat log dir 생성
sudo rm -rf ${tlog_path}
sudo mkdir -p ${tlog_path}
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
sudo sed -i 's|pattern="%h %l %u %t &quot;%r&quot; %s %b" />|pattern="combined" resolveHosts="false" />|' ${tomcat_path}/conf/server.xml
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
sudo sed -i 's|logs|'${tlog_path}'|g' ${tomcat_path}/conf/server.xml
sudo sed -i 's|txt|log|g' ${tomcat_path}/conf/server.xml

##logrotate 설정
sudo tee ${tomcat_path}/conf-set/tomcat.logrotate > /dev/null << EOF
${tlog_path}/*.out
${tlog_path}/*.log
${tlog_path}/*.txt
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
        create 640 login login
        maxage 180
        size 100M
        dateext
}
EOF
chekp=$(which logrotate)
if [ -z $ckekp ]; then
        echo "check logrotate file"
else
	sudo ln -s ${tomcat_path}/conf-set/tomcat.logrotate /etc/logrotate.d/tomcat.logrotate
fi

## 권한 전체 수정
sudo chown -R ${SERV_USER}:${SERV_USER} ${tomcat_path}
sudo chown -R ${SERV_USER}:${SERV_USER} ${tlog_path}
echo "#####tomcat setting done"
tomcat_service
}

tomcat_service()
{
echo "#####make tomcat service"

FIN="/usr/lib/systemd/system/tomcat.service"
if [ -e $FIN ] || [ -L $FIN ]; then
	sudo unlink /usr/lib/systemd/system/tomcat.service
	sudo mv -f /usr/lib/systemd/system/tomcat.service /usr/lib/systemd/system/tomcat.service_bak 2>/dev/null
fi
sudo tee ${tomcat_path}/conf-set/tomcat.service > /dev/null << EOF
[Unit]
Description=tomcat 8
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
}

db_install()
{
#### 수동 설치시 파일 체크
echo "#####DB install"
sudo rm -rf ${db_path}
sudo mkdir -p ${db_path}

sudo rm -rf ${dlog_path}/error
sudo mkdir -p ${dlog_path}/error
	
sudo rm -rf ${dbdata_path}
sudo mkdir -p ${dbdata_path}

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
result1=$(find / -name libncurses.so.5 2>/dev/null | head -n 1)
result2=$(find / -name 'libncursesw.so.6*' 2>/dev/null | head -n 1)
result3=$(find / -name libtinfo.so.5 2>/dev/null | head -n 1)

if [ -z "$result1" ]; then
    if [ -z "$result2" ]; then
        echo "libncursesw.so.6 check plz1"
        exit 0
    fi
    first_word=$(echo "$result2" | awk -F'/' '{print $NF}')
    path_without_last=$(echo "$result2" | awk -F'/' -v OFS='/' '{$NF=""; print $0}')
    sudo ln -s "$result2" "$path_without_last/libncurses.so.5"
    result1=$(find / -name libncurses.so.5 2>/dev/null | head -n 1)
    echo "$result1"
fi

if [ -z "$result3" ]; then
    if [ -z "$result2" ]; then
        echo "libncursesw.so.6 check plz2"
        exit 0
    fi
    first_word=$(echo "$result2" | awk -F'/' '{print $NF}')
    path_without_last=$(echo "$result2" | awk -F'/' -v OFS='/' '{$NF=""; print $0}')
    sudo ln -s "$result2" "$path_without_last/libtinfo.so.5"
    result1=$(find / -name libtinfo.so.5 2>/dev/null | head -n 1)
    echo "$result1"
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
	sudo unlink /usr/lib/systemd/system/mariadb.service 
	sudo mv -f /usr/lib/systemd/system/mariadb.service /usr/lib/systemd/system/mariadb.service_bak 2>/dev/null
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
innodb_buffer_pool_size = 12G
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
	sudo unlink /etc/my.cnf
	sudo mv -f /etc/my.cnf /etc/my.cnf.ori 2>/dev/null
fi

sudo ln -s ${db_path}/conf-set/my.cnf /etc/my.cnf
#### mysql bin 파일 복사
if [ -e "/usr/bin/mysql" ] || [ -L "/usr/bin/mysql" ]; then
	sudo unlink /usr/bin/mysql
	sudo mv -f /usr/bin/mysql /usr/bin/mysql.ori 2>/dev/null
else
	sudo cp ${db_path}/bin/mysql /usr/bin/mysql
fi

if [ -e "/usr/bin/mysqld" ] || [ -L "/usr/bin/mysqld" ]; then
	sudo unlink /usr/bin/mysqld
	sudo mv -f /usr/bin/mysqld /usr/bin/mysqld.ori 2>/dev/null
else
	sudo cp ${db_path}/bin/mysqld /usr/bin/mysqld
fi

if [ -e "/usr/bin/mysqldump" ] || [ -L "/usr/bin/mysqldump" ]; then
	sudo unlink /usr/bin/mysqldump
	sudo mv -f /usr/bin/mysqldump /usr/bin/mysqldump.ori 2>/dev/null
else
	sudo cp ${db_path}/bin/mysqldump /usr/bin/mysqldump
fi

if [ -e "/usr/bin/mysqladmin" ] || [ -L "/usr/bin/mysqldump" ]; then
	sudo unlink /usr/bin/mysqladmin
	sudo mv -f /usr/bin/mysqladmin /usr/bin/mysqladmin.ori 2>/dev/null
else
	sudo cp ${db_path}/bin/mysqladmin /usr/bin/mysqladmin
fi
	
#### mariadb.service 지정 및 기동
sudo ln -s ${db_path}/conf-set/mariadb.service /usr/lib/systemd/system/mariadb.service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable mariadb
echo "#####DB setting done"
}


miso_install()
{
#### miso war 풀기
sudo cp -av ../miso_pack/${MISOWAR} ${miso_path}/webapps/${MISOWAR}
cd ${miso_path}/webapps;sudo ${install_path}/java/bin/jar -xvf ${miso_path}/webapps/${MISOWAR};cd -

#### system.properties설정값 복사
echo "####setting system.properties"
sudo cp ${miso_path}/webapps/WEB-INF/classes/properties/system.properties ${miso_path}/webapps/WEB-INF/classes/properties/system.properties.ori

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
sudo cp ${miso_path}/webapps/WEB-INF/classes/logback.properties ${miso_path}/webapps/WEB-INF/classes/logback.properties.ori
sudo sed -i -E 's/(LOG_LEVEL=).*/\1'${LOG_LEVEL}'/' ${miso_path}/webapps/WEB-INF/classes/logback.properties
sudo sed -i -E 's/(LOG_OUTPUT_TYPE=).*/\1'${LOG_TYPE}'/' ${miso_path}/webapps/WEB-INF/classes/logback.properties
sudo sed -i -E 's|(LOG_HOME=).*|\1'${LOG_PATH}'|' ${miso_path}/webapps/WEB-INF/classes/logback.properties

#세션 타입아웃 10으로 수정.
sudo cp ${miso_path}/webapps/WEB-INF/web.xml ${miso_path}/webapps/WEB-INF/web.xml.ori
sudo sed -i 's/<session-timeout>30<\/session-timeout>/<session-timeout>10<\/session-timeout>/g' ${miso_path}/webapps/WEB-INF/web.xml
echo "####setting miso log done"

# 소유권 수정
sudo chown -R ${SERV_USER}:${SERV_USER} ${miso_path}/webapps

#server.xml 내용 추가(디렉토리 내용)
echo "####setting miso server.xml"
sudo sed -i'' -r -e '/unpackWARs=/a\<Context path="/" docBase="'${miso_path}'/webapps" reloadable="true"/>' ${tomcat_path}/conf/server.xml
echo "####setting miso server.xml done"
}

make_query()
{
#### SQL 문 만들기
echo "####create sql query"
sudo touch 07.add.sql
db_setting_check
LOOPBACK=127.0.0.1
GRANTS=ALL
sudo chown -R ${SU_USER}:${SU_USER} 07.add.sql
sudo echo "CREATE DATABASE \`${DB_NAME}\` /*!40100 COLLATE 'utf8mb4_unicode_ci'*/;" > 07.add.sql
sudo echo "CREATE USER '${DB_USER}'@'${HOST_IP}' IDENTIFIED BY '${DB_PASSWD}';" >> 07.add.sql
sudo echo "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWD}';" >> 07.add.sql
if [ ${HOST_IP} != ${LOOPBACK} ]; then
	 sudo echo "CREATE USER '${DB_USER}'@'${LOOPBACK}' IDENTIFIED BY '${DB_PASSWD}';" >> 07.add.sql
fi

sudo echo "GRANT ${GRANTS} PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${HOST_IP}' IDENTIFIED BY '${DB_PASSWD}';" >> 07.add.sql
sudo echo "GRANT ${GRANTS} PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWD}';" >> 07.add.sql
if [ ${HOST_IP} != ${LOOPBACK} ]; then
	sudo echo "GRANT ${GRANTS} PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${LOOPBACK}' IDENTIFIED BY '${DB_PASSWD}';" >> 07.add.sql
fi

sudo sh -c 'echo "FLUSH PRIVILEGES;" >> 07.add.sql'
sudo sh -c 'echo "use "'${DB_NAME}' >> 07.add.sql'
sudo sh -c 'cat '${miso_path}'/webapps/WEB-INF/classes/database/mysql/MYSQL_DDL_2_Table.sql >> 07.add.sql'
sudo sh -c 'cat '${miso_path}'/webapps/WEB-INF/classes/database/mysql/MYSQL_DDL_3_PK.sql >> 07.add.sql'
sudo sh -c 'cat '${miso_path}'/webapps/WEB-INF/classes/database/mysql/MYSQL_DDL_5_INDEX.sql >> 07.add.sql'
sudo sh -c 'cat '${miso_path}'/webapps/WEB-INF/classes/database/mysql/MYSQL_DML_1_initData.sql >> 07.add.sql'
sudo sh -c 'cat '${miso_path}'/webapps/WEB-INF/classes/database/mysql/CODE_DML.sql >> 07.add.sql'
sudo sh -c 'cat '${miso_path}'/webapps/WEB-INF/classes/database/mysql/MENU_AUTH_DML.sql >> 07.add.sql'
sudo sh -c 'cat '${miso_path}'/webapps/WEB-INF/classes/database/mysql/MESSAGE_DML.sql >> 07.add.sql'
sudo sh -c 'cat '${miso_path}'/webapps/WEB-INF/classes/database/mysql/PROPERTY_DML.sql >> 07.add.sql'
sudo sh -c 'cat '${miso_path}'/webapps/WEB-INF/classes/database/mysql/MAIL_TEMPLATE_BOARD_DML.sql  >> 07.add.sql'
sudo sh -c 'echo " " >> 07.add.sql'

echo "####create sql query done"
}
source_query()
{
mysql -u root < 07.add.sql
mysqldump -u root ${DB_NAME} --single-transaction --triggers --routines > init_miso.sql
}
editorImage()
{
if [ ! -d "../miso_pack/namo" ]; then
	echo "namo(D) not exist"
	exit 0
fi
#war 안 namo plugin 파일 백업
sudo mv -f ${miso_path}/webapps/web/plugins/namo ${miso_path}/webapps/web/plugins/namo.ori
sudo cp -r ../miso_pack/namo ${miso_path}/webapps/web/plugins/namo

#websource/jsp , manage/jsp 백업
sudo cp -r ${miso_path}/webapps/web/plugins/namo/websource/jsp ${miso_path}/webapps/web/plugins/namo/websource/jsp.ori
sudo cp -r ${miso_path}/webapps/web/plugins/namo/manage/jsp ${miso_path}/webapps/web/plugins/namo/manage/jsp.ori

#UTF-8 수정
sudo find ${miso_path}/webapps/web/plugins/namo/websource/jsp -type f -name "*.jsp" -exec sed -i '/^</s/UTF-8\>/utf-8/g' {} +
sudo find ${miso_path}/webapps/web/plugins/namo/manage/jsp -type f -name "*.jsp" -exec sed -i '/^</s/UTF-8\>/utf-8/g' {} +

#세미콜론 분리
sudo find ${miso_path}/webapps/web/plugins/namo/websource/jsp -type f -name "*.jsp" -exec sed -i '/^</s/;charset=utf-8/; charset=utf-8/g' {} +
sudo find ${miso_path}/webapps/web/plugins/namo/manage/jsp -type f -name "*.jsp" -exec sed -i '/^</s/;charset=utf-8/; charset=utf-8/g' {} +

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
sudo firewall-cmd --permanent --zone=public --add-port=${HTTP}/tcp
sudo firewall-cmd --permanent --zone=public --add-port=${DB_PORT}/tcp
sudo firewall-cmd --reload
echo "####firewalld setting done"
}

miso_patch()
{
#file check
TEXT=$(cat ../patch/${MISOWAR}.md5)
HS_VL=$(md5sum ../patch/${MISOWAR} | awk '{print $1}')

if [ ! -e "../patch/${MISOWAR}" ]; then
	echo ${MISOWAR}" not exist"
	exit 0
elif [ ! -e "../patch/${MISOWAR}.md5" ]; then
	echo ${MISOWAR}".md5 not exist"	
	exit 0
elif [ ${TEXT} != ${HS_VL} ]; then
	echo " md5 text  : ${TEXT}"
	echo "hash value : ${HS_VL}"
	exit 0
else 
	echo ""
fi

last_version=$(ls -lr .. | grep patch_ | head -n 1 | awk '{print $9}')
checkf=$(diff ../patch/miso.core.web-2.0.war.md5 ../$last_version/miso.core.web-2.0.war.md5)
current_day=$(date '+%Y%m%d')
if [ -z "$checkp" ]; then
	echo "last version md5 same"
	mv ../patch ../patch_${current_day}
	exit 0
fi

#### tomcat 서비스 종료
sudo systemctl stop tomcat || true

#### webapps 백업
current_date=$(date '+%Y%m%d_%H%M')
sudo mv ${miso_path}/webapps ${miso_path}/webapps_${current_date}_bak

#### miso war 풀기
sudo mkdir -p ${miso_path}/webapps
sudo cp -av ../patch/${MISOWAR} ${miso_path}/webapps/${MISOWAR}
cd ${miso_path}/webapps;sudo ${install_path}/java/bin/jar -xvf ${MISOWAR};cd -

#### config, namo 교체
sudo cp ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/logback.properties ${miso_path}/webapps/WEB-INF/classes/logback.properties
sudo cp ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/properties/system.properties ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
sudo cp ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/properties/site.properties ${miso_path}/webapps/WEB-INF/classes/properties/site.properties
sudo rm -r ${miso_path}/webapps/web/plugins/namo 
sudo cp -arp ${miso_path}/webapps_${current_date}_bak/web/plugins/namo ${miso_path}/webapps/web/plugins/

#### 쿼리 생성
#sudo rm -rf ../patch/patch.sql
sudo touch ../patch/patch.sql

sudo cp ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/database/mysql/MYSQL_DDL_6_ALTER.sql ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/database/mysql/old_ALTER.sql
sudo cp ${miso_path}/webapps/WEB-INF/classes/database/mysql/MYSQL_DDL_6_ALTER.sql ${miso_path}/webapps/WEB-INF/classes/database/mysql/new_ALTER.sql
sudo sed -i '/^[[:space:]]*$/d' ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/database/mysql/old_ALTER.sql
sudo sed -i '/^[[:space:]]*$/d' ${miso_path}/webapps/WEB-INF/classes/database/mysql/new_ALTER.sql
oldline=$(sed -n '/./=' ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/database/mysql/old_ALTER.sql | tail -n 1)
newline=$(sed -n '/./=' ${miso_path}/webapps/WEB-INF/classes/database/mysql/new_ALTER.sql | tail -n 1)

if [ "$newline" -gt "$oldline" ]; then
    for (( i=oldline+1; i<=newline; i++ ))
    do
        sed -n "${i}p" ${miso_path}/webapps/WEB-INF/classes/database/mysql/new_ALTER.sql >> ../patch/patch.sql
    done
else
    echo "correct"
fi

printf "\n\n" >> ../patch/patch.sql
sudo sh -c 'cat '${miso_path}'/webapps/WEB-INF/classes/database/mysql/CODE_DML.sql  >> ../patch/patch.sql'
printf "\n\n" >> ../patch/patch.sql
sudo sh -c 'cat '${miso_path}'/webapps/WEB-INF/classes/database/mysql/MESSAGE_DML.sql  >> ../patch/patch.sql'
printf "\n\n" >> ../patch/patch.sql
sudo sh -c 'cat '${miso_path}'/webapps/WEB-INF/classes/database/mysql/PROPERTY_DML.sql  >> ../patch/patch.sql'

#### 소유권 지정
chown -R ${SERV_USER}:${SERV_USER} ${miso_path}/webapps

#### DB 백업
salt=$(printf $SERV_USER | md5sum | cut -c1-16)
DEC_VALUE=$(echo $DP_ENC | openssl enc -aes-256-cbc -a -d -S $salt -pbkdf2 -iter 100000 -pass pass:$MY_USER 2>/dev/null)
sudo mysqldump -u ${DB_USER} -p${DEC_VALUE} ${DB_NAME} --single-transaction --triggers --routines > ../patch/${DB_NAME}_${current_date}.sql

#### 패치쿼리 입력
sudo mysql -u ${DB_USER} -p${DEC_VALUE} ${DB_NAME} < ../patch/patch.sql

#### tomcat 기동
systemctl start tomcat || true

#### patch 파일 변경
mv ../patch ../patch_${current_day}
}

patchfile_del()
{
today=$(date +%Y%m%d)
threshold=$(date -d "$today -7 days" +%Y%m%d)

dirs=($(ls -lr .. | grep patch_ | awk '{print $9}'))
if [ "${#dirs[@]}" -le 1 ]; then
    return 0
fi

to_delete=()

for dir in "${dirs[@]}"; do
    dir_date=${dir#patch_}
    if [[ "$dir_date" < "$threshold" ]]; then
        to_delete+=("$dir")
    fi
done

if [ "${#to_delete[@]}" -eq 0 ]; then
    echo ""
else
    for del in "${to_delete[@]}"; do
        sudo rm -rf "$del"
    done
fi
}
webappsfile_del()
{
today=$(date +%Y%m%d)
threshold=$(date -d "$today -7 days" +%Y%m%d)

dirs=($(ls -lr ${miso_path} | grep webapps_ | awk '{print $9}'))
if [ "${#dirs[@]}" -le 1 ]; then
    return 0
fi

to_delete=()

for dir in "${dirs[@]}"; do
    tmp=${dir#webapps_}
    dir_date=${tmp%%_*}
    if [[ "$dir_date" < "$threshold" ]]; then
        to_delete+=("$dir")
    fi
done

if [ "${#to_delete[@]}" -eq 0 ]; then
    echo ""
else
    for del in "${to_delete[@]}"; do
        sudo rm -rf "$del"
    done
fi
}

web_passwd_init()
{
## root check
if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root" 
	exit 0
fi
##echo $1
if [ -z $1 ]; then
	echo "use >> $0 WEB_ID"
exit 0
fi

##find tomcat port
tomcat_port=$(lsof -i -P -n | grep $(ps -afN | grep $tomcat_path | awk '{print $2}') 2>/dev/null | grep LISTEN | cut -d ':' -f2 | awk '{print $1}')
passwd='' 
tomcat_port=($tomcat_port)
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

salt=$(printf $SERV_USER | md5sum | cut -c1-16)
DEC_VALUE=$(echo $DP_ENC | openssl enc -aes-256-cbc -a -d -S $salt -pbkdf2 -iter 100000 -pass pass:$MY_USER 2>/dev/null)


if [[ "$DB_IP" == "localhost" || "$DB_IP" == "127.0.0.1" ]]; then
	check_id=$($db_path/bin/mysql -u$DB_USER -p$DEC_VALUE $DB_NAME -Bse "select USER_ID from user where USER_ID='$1'" 2>/dev/null)
	if [ -z $check_id ]; then
		echo "###################################################"
		echo "check db_process or WEB_ID"
		echo "###################################################"
		exit 0
	fi
	mysql -u$DB_USER -p$DEC_VALUE $DB_NAME -Bse "update user set UPDATE_DT = now(), UPDATE_USER = null, PASSWORD = '$passwd', PWD_CHANGE_DT = null, ACCT_STATE_CD='U' where USER_ID = '$1'"
	echo "###################################################"
	echo "'$1' change passwd"
	echo "###################################################"
else
	echo "###################################################"
	echo "update $DB_NAME.user set UPDATE_DT = now(), UPDATE_USER = null, PASSWORD = '$passwd', PWD_CHANGE_DT = null, ACCT_STATE_CD='U' where USER_ID = '$1';"
	echo "###################################################"
fi

}

encoding()
{
read -p "insert plaintext : " ptxt
salt=$(printf $SERV_USER | md5sum | cut -c1-16)
ENC_VALUE=$(echo $ptxt | openssl enc -aes-256-cbc -a -S $salt -pbkdf2 -iter 100000 -pass pass:$MY_USER)
echo "Encrypted Value: ${ENC_VALUE}"
}
main()
{
	case "$1" in
		check)
			check_file
			;;
		install)
  			check_file&&check_user_serv&&check_user_db&&makedir&&
			install_java&&db_install&&tomcat_install&&
			miso_install&&DB_RUN&&make_query&&source_query&&tomcat_RUN&&
			firewalld_setting
			;;
		enc)
			encoding
			;;
		editor)
			editorImage
			;;
		filedownload)
			filedownload
			;;
		patch)
			patchfile_del&&miso_patch&&webappsfile_del
			;;
		help)
			echo " option = {}"
			;;
		*)
			echo "Usage: $0 {check|install|help}"
			exit 0
			;;
	esac
}

main "$@"
