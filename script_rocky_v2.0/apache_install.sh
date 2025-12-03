#!/bin/bash
source 01.util_Install_latest
SCRIPTLOGFILE=apache_install.log
exec > >(tee -a "$SCRIPTLOGFILE") 2>&1
echo $DATE" is running" >> ${SCRIPTLOGFILE}

apache_file_check()
{
if [ ! -e "../apache/${pcre_file}" ]; then
	echo ${pcre_file}" not exist"
	exit 0
elif [ ! -e "../apache/${apr_file}" ]; then
	echo ${apr_file}" not exist"
	exit 0
elif [ ! -e "../apache/${apr_util_file}" ]; then
	echo ${apr_util_file}" not exist"
	exit 0
elif [ ! -e "../apache/${apache_file}" ]; then
	echo ${apache_file}" not exist"
	exit 0
else
	echo "apache file check done"
fi
}
local_repository_check()
{
yum list available >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "local repository done"
else
    echo "local repository check"
	exit 0
fi
}

rpmupdate()
{
mkdir rpmfile
cd rpmfile
dnf download --resolve gcc gcc-c++ make expat expat-devel openssl-devel pcre-devel httpd-devel autoconf libtool apr-util-devel  mod_ssl zlib zlib-devel 
dnf localinstall --disablerepo="*" --cacheonly *.rpm
cd -
}

makefile()
{
mkdir -p ${apache_path}/src/pcre
mkdir -p ${apache_path}/src/apr
mkdir -p ${apache_path}/src/apr-util
mkdir -p ${apache_path}/src/httpd
#pcre make
tar -zxvf ../apache/${pcre_file} -C ${apache_path}/src/pcre --strip-components=1
cd ${apache_path}/src/pcre
./configure --prefix=${apache_path}/pcre
make && make install
cd -

#apr make
tar -zxvf ../apache/${apr_file} -C ${apache_path}/src/apr --strip-components=1
cd ${apache_path}/src/apr
./configure --prefix=${apache_path}/apr
make && make install
cd -

#apr-util make
tar -zxvf ../apache/${apr_util_file} -C ${apache_path}/src/apr-util --strip-components=1
cd ${apache_path}/src/apr-util
./configure --prefix=${apache_path}/apr-util --with-apr=${apache_path}/apr --with-expat=/usr
make && make install
cd -

#httpd make
tar -xzvf ../apache/${apache_file} -C ${apache_path}/src/httpd --strip-components=1
cd ${apache_path}/src/httpd
./configure --prefix=${apache_path} --enable-mods-shared=all --enable-so --enable-rewrite --enable-ssl -with-ssl=/usr/bin/openssl --enable-modules=ssl --enable-modules=shared --enable-mpms-shared=all --with-apr=${apache_path}/apr --with-apr-util=${apache_path}/apr-util
make && make install 
cd -
#httpd.conf 수정
mkdir -p ${apache_path}/run
cp ${apache_path}/conf/httpd.conf ${apache_path}/conf/httpd.conf.ori
cat << EOF >> ${apache_path}/conf/httpd.conf
PidFile "${apache_path}/run/httpd.pid"
ServerName www.example.com:80
EOF

}

tomcat_connector()
{
mkdir -p ${apache_path}/src/tomcat_connector
tar -xzvf ../apache/${connector_file} -C ${apache_path}/src/tomcat_connector --strip-components=1

ln -s /usr/bin/libtool ${apache_path}/build/libtool
cd ${apache_path}/src/tomcat_connector/native
./configure --prefix=${apache_path}/tomcat_connector --with-apxs=${apache_path}/bin/apxs
make && make install
cd -

#httpd.conf 수정
cat << EOF >> ${apache_path}/conf/httpd.conf
LoadModule jk_module modules/mod_jk.so
Include conf/mod_jk.conf 
EOF

#mod_jk.conf 생성
sudo tee ${apache_path}/conf/mod_jk.conf > /dev/null << EOF
JkWorkersFile conf/workers.properties
JkShmFile run/mod_jk.shm
JkLogFile logs/mod_jk.log
JkLogLevel info
JkLogStampFormat "[%y %m %d %H:%M:%S] "
JkMount /* worker1
JkUnMount /*.css   worker1
JkUnMount /*.js    worker1
JkUnMount /*.png   worker1
JkUnMount /*.jpg   worker1
JkUnMount /*.jpeg  worker1
JkUnMount /*.gif   worker1
JkUnMount /*.svg   worker1
JkUnMount /*.webp  worker1
JkUnMount /*.ico   worker1
JkUnMount /*.woff  worker1
JkUnMount /*.woff2 worker1 
EOF

read -p "tomcat server ip ? >" tomcat_ip

#worker 파일생성
sudo tee ${apache_path}/conf/workers.properties > /dev/null << EOF
worker.list=worker1
worker.worker1.port=8009
worker.worker1.host=${tomcat_ip}
worker.worker1.type=ajp13

#worker.worker1.connect_timeout=5000
#worker.worker1.reply_timeout=60000
#worker.worker1.ping_mode=A
#worker.worker1.ping_timeout=10000
#worker.worker1.connection_pool_timeout=600
#worker.worker1.max_packet_size=65536

#<Connector protocol="AJP/1.3" address="0.0.0.0" port="8009" redirectPort="8443" maxParameterCount="1000" URIEncoding="UTF-8" enableLookups="false"
# server="server" secretRequired="false" packetSize="65536" maxThreads="400" acceptCount="200" ConnectionTimeout="30000" />
EOF

}

remove_src()
{
rm -rf ${apache_path}/src
}
makesystemfile()
{
sudo tee ${apache_path}/httpd.service > /dev/null << EOF
[Unit]
Description=Apache Service

[Service]
Type=forking
#EnvironmentFile=${apache_path}/bin/envvars
PIDFile=${apache_path}/run/httpd.pid
ExecStart=${apache_path}/bin/apachectl start
ExecReload=${apache_path}/bin/apachectl graceful
ExecStop=${apache_path}/bin/apachectl stop
KillSignal=SIGCONT
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

cp ${apache_path}/httpd.service /usr/lib/systemd/system/httpd.service

systemctl daemon-reload
systemctl enable httpd
systemctl start httpd

}
firewalld()
{
firewall-cmd --permanent --zone=public --add-port=80/tcp
firewall-cmd --reload
}


main()
{
	case "$1" in
		*)
			apache_file_check&&local_repository_check&&rpmupdate&&
			makefile&&tomcat_connector&&remove_src&&makesystemfile&&firewalld
			echo "##########################"
			echo "apache install done"
			echo "httpd.conf require web file"
			echo "##########################"
			cat ${apache_path}/conf/httpd.conf | grep -nA 1 ^DocumentRoot
			echo "##########################"
			echo ""
			;;
	esac
}

main "$@"