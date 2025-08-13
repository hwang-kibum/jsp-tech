#!/bin/bash
cd "$(dirname "$0")"

java_path="/data/java"
TOMCATFILE="apache-tomcat-9.0.107.tar.gz"
editorImage_path="/data/miso/editorImage"
tomcat_path=""
tomcat_port=""
db_passwd="Wlfks@09!@#"
war=""
sql=""

check_path(){
tomcat_path="/data/$1"
tomcat_port="$2"
checking
}

checking()
{
	if [ -d "${tomcat_path}" ] || [ -L "${tomcat_path}" ]; then
		echo "tomcat_path already exist"
		exit 1
	fi
	checkport=$(ss -antp | grep -i listen | grep ":$tomcat_port\>")
	if [ ! -z "${checkport}" ]; then
		echo "tomcat_port alreay used"
		exit 1
	fi
	echo "checking done"
}

check_file ()
{
war="$1"
sql="$2"
}

tomcat_install()
{
sudo mkdir -p ${tomcat_path}
sudo tar -xzf ../tomcat/"${TOMCATFILE}"* -C ${tomcat_path} --strip-components=1 >/dev/null 2>&1
sudo tee ${tomcat_path}/bin/setenv.sh > /dev/null << EOF
LANG="ko_KR.utf8"
JAVA_HOME="${java_path}"
export JAVA_OPTS="-server -Djava.awt.headless=true -Dfile.encoding=UTF-8 -Xms512m -Xmx1024m -XX:MetaspaceSize=256m -XX:MaxMetaspaceSize=512m"
EOF
sudo cp -arp ${tomcat_path}/conf/server.xml ${tomcat_path}/conf/server.xml.ori
sudo sed -i'' -r -e '/unpackWARs=/a\<Context path="/editorImage" docBase="'${editorImage_path}'" reloadable="true"/>' ${tomcat_path}/conf/server.xml
sed -i 's/8080/'${tomcat_port}'/g' ${tomcat_path}/conf/server.xml
sed -i 's/8005/1'${tomcat_port}'/g' ${tomcat_path}/conf/server.xml
mv ${tomcat_path}/webapps/ROOT  ${tomcat_path}/webapps/ROOT_ori
mkdir ${tomcat_path}/webapps/ROOT
echo "tomcat install done"
}

was_copy(){
tar -xvf ../copyserver/"${war}" -C "${tomcat_path}/webapps/ROOT" --strip-components=1 >/dev/null 2>&1
## namo work
rm -rf ${tomcat_path}/webapps/ROOT/web/plugins/namo
cp -r ${editorImage_path}/namo_ori ${tomcat_path}/webapps/ROOT/web/plugins/namo
sed -i 's/8080/'${tomcat_port}'/g' ${tomcat_path}/webapps/ROOT/web/plugins/namo/websource/jsp/ImagePath.jsp

## log work
sed -i -E 's/(LOG_OUTPUT_TYPE=).*/\1console/' ${tomcat_path}/webapps/ROOT/WEB-INF/classes/logback.properties

## system.properties work
db_name=$(sed -n 's/^-- Host:.*Database: \(.*\)/\1/p' ../copyserver/${sql})
sed -i -E 's/(db.user=).*/\1root/g' ${tomcat_path}/webapps/ROOT/WEB-INF/classes/properties/system.properties
sed -i -E 's/(db.password=).*/\1Wlfks@09!@#/g' ${tomcat_path}/webapps/ROOT/WEB-INF/classes/properties/system.properties
sed -i -E 's#(db\.url=jdbc:mysql://)[^:/]+(:[0-9]+)?/#\1127.0.0.1:3306/#' ${tomcat_path}/webapps/ROOT/WEB-INF/classes/properties/system.properties
sed -i -E 's#(3306/)[^?]*#\1'${db_name}'#'
echo "was copy done"
}

db_copy(){
db_name=$(sed -n 's/^-- Host:.*Database: \(.*\)/\1/p' ../copyserver/${sql})
echo ${db_name}
db_exist=$(mysql -u root -p"${db_passwd}" -Bse "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${db_name}';")
if [[ "$db_exist" == "$db_name" ]]; then
    mysql -uroot -p${db_passwd} -Bse "drop database $db_name;"
fi

mysql -u root -p${db_passwd} -Bse "CREATE DATABASE \`${db_name}\` /*!40100 COLLATE 'utf8mb4_unicode_ci'*/;"
mysql -u root -p${db_passwd} ${db_name} < ../copyserver/${sql}
echo "db_copy done"
}

firewalld_setting()
{
sudo firewall-cmd --permanent --zone=public --add-port=${tomcat_port}/tcp
sudo firewall-cmd --reload
echo "firewalld setting done"
}

tomcat_run()
{
${tomcat_path}/bin/startup.sh
echo "tomcat run"

}

if [ "$#" -eq 2 ]; then
    check_path "$1" "$2"
	exit 0
elif [ "$#" -eq 4 ]; then
    check_path "$1" "$2" &&
	check_file "$3" "$4" &&
	tomcat_install &&
	was_copy  &&
	db_copy  &&
	firewalld_setting &&
	tomcat_run
	exit 0
else
    echo "지원하지 않는 인자 개수입니다. 2개 또는 4개를 입력하세요."
    exit 1
fi