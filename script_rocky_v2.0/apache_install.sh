#!/bin/bash
start_time=$(date +%s)
cd "$(dirname "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source 01.util_Install_latest
SCRIPTLOGFILE=apache_install.log
exec > >(tee -a "$SCRIPTLOGFILE") 2>&1

# 색상 정의
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 로그 함수
log_info() {
    echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $1"
}

echo $DATE" is running" >> ${SCRIPTLOGFILE}
apache_path=''

apache_file_check()
{
    log_info "Checking apache files..."
    
    if [ ! -e "../apache/${pcre_file}" ]; then
        log_error "${pcre_file} not exist"
        exit 1
    elif [ ! -e "../apache/${apr_file}" ]; then
        log_error "${apr_file} not exist"
        exit 1
    elif [ ! -e "../apache/${apr_util_file}" ]; then
        log_error "${apr_util_file} not exist"
        exit 1
    elif [ ! -e "../apache/${apache_file}" ]; then
        log_error "${apache_file} not exist"
        exit 1
    else
        log_success "Apache file check completed"
    fi
}

local_repository_check()
{
    log_info "Checking local repository..."
    yum list available >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_success "Local repository check completed"
    else
        log_error "Local repository check failed"
        exit 1
    fi
}

rpmupdate()
{
    log_info "Installing required packages..."
    mkdir -p rpmfile
    cd rpmfile
    dnf -y install gcc gcc-c++ make expat expat-devel openssl-devel pcre-devel httpd-devel autoconf libtool apr-util-devel mod_ssl zlib zlib-devel > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log_success "Package installation completed"
    else
        log_error "Package installation failed"
        exit 1
    fi
    cd -
}

makefile()
{
    log_info "Creating build directories..."
    mkdir -p ${apache_path}/src/{pcre,apr,apr-util,httpd}
    mkdir -p ${apache_path}/logs/build
    
    # PCRE 빌드
    {
        log_info "PCRE: Extracting..."
        tar -zxf ../apache/${pcre_file} -C ${apache_path}/src/pcre --strip-components=1 2>&1 | grep -i error || true
        
        log_info "PCRE: Configuring..."
        cd ${apache_path}/src/pcre
        ./configure --prefix=${apache_path}/pcre CFLAGS="-O2" >> ${apache_path}/logs/build/pcre.log 2>&1
        
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            log_error "PCRE configure failed! Check ${apache_path}/logs/build/pcre.log"
            tail -20 ${apache_path}/logs/build/pcre.log
            exit 1
        fi
        
        log_info "PCRE: Building (using $(nproc) cores)..."
        make -j$(nproc) >> ${apache_path}/logs/build/pcre.log 2>&1 && \
        make install >> ${apache_path}/logs/build/pcre.log 2>&1
        
        if [ $? -eq 0 ]; then
            log_success "PCRE build completed"
        else
            log_error "PCRE build failed! Check ${apache_path}/logs/build/pcre.log"
            tail -20 ${apache_path}/logs/build/pcre.log
            exit 1
        fi
        cd -
    } &
    pcre_pid=$!

    # APR + APR-Util 빌드
    {
        log_info "APR: Extracting..."
        tar -zxf ../apache/${apr_file} -C ${apache_path}/src/apr --strip-components=1 2>&1 | grep -i error || true
        
        log_info "APR: Configuring..."
        cd ${apache_path}/src/apr
        ./configure --prefix=${apache_path}/apr CFLAGS="-O2" >> ${apache_path}/logs/build/apr.log 2>&1
        
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            log_error "APR configure failed! Check ${apache_path}/logs/build/apr.log"
            tail -20 ${apache_path}/logs/build/apr.log
            exit 1
        fi
        
        log_info "APR: Building (using $(nproc) cores)..."
        make -j$(nproc) >> ${apache_path}/logs/build/apr.log 2>&1 && \
        make install >> ${apache_path}/logs/build/apr.log 2>&1
        
        if [ $? -eq 0 ]; then
            log_success "APR build completed"
        else
            log_error "APR build failed! Check ${apache_path}/logs/build/apr.log"
            tail -20 ${apache_path}/logs/build/apr.log
            exit 1
        fi
        cd -

        log_info "APR-Util: Extracting..."
        tar -zxf ../apache/${apr_util_file} -C ${apache_path}/src/apr-util --strip-components=1 2>&1 | grep -i error || true
        
        log_info "APR-Util: Configuring..."
        cd ${apache_path}/src/apr-util
        ./configure --prefix=${apache_path}/apr-util --with-apr=${apache_path}/apr --with-expat=/usr CFLAGS="-O2" >> ${apache_path}/logs/build/apr-util.log 2>&1
        
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            log_error "APR-Util configure failed! Check ${apache_path}/logs/build/apr-util.log"
            tail -20 ${apache_path}/logs/build/apr-util.log
            exit 1
        fi
        
        log_info "APR-Util: Building (using $(nproc) cores)..."
        make -j$(nproc) >> ${apache_path}/logs/build/apr-util.log 2>&1 && \
        make install >> ${apache_path}/logs/build/apr-util.log 2>&1
        
        if [ $? -eq 0 ]; then
            log_success "APR-Util build completed"
        else
            log_error "APR-Util build failed! Check ${apache_path}/logs/build/apr-util.log"
            tail -20 ${apache_path}/logs/build/apr-util.log
            exit 1
        fi
        cd -
    } &
    apr_pid=$!

    # 모든 의존성 빌드 완료 대기
    log_info "Waiting for dependency builds to complete..."
    wait $pcre_pid $apr_pid
    
    if [ $? -ne 0 ]; then
        log_error "Dependency build failed!"
        exit 1
    fi
    
    log_success "All dependencies built successfully"

    # HTTPD 빌드
    log_info "HTTPD: Extracting..."
    tar -xzf ../apache/${apache_file} -C ${apache_path}/src/httpd --strip-components=1 2>&1 | grep -i error || true
    
    log_info "HTTPD: Configuring..."
    cd ${apache_path}/src/httpd
    ./configure --prefix=${apache_path} \
        --enable-mods-shared=all \
        --enable-so \
        --enable-rewrite \
        --enable-ssl \
        --with-ssl=/usr/bin/openssl \
        --enable-modules=ssl \
        --enable-modules=shared \
        --enable-mpms-shared=all \
        --with-apr=${apache_path}/apr \
        --with-apr-util=${apache_path}/apr-util \
        CFLAGS="-O2" >> ${apache_path}/logs/build/httpd.log 2>&1

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "HTTPD configure failed! Check ${apache_path}/logs/build/httpd.log"
        tail -20 ${apache_path}/logs/build/httpd.log
        exit 1
    fi

    log_info "HTTPD: Building (using $(nproc) cores, this may take a while)..."
    make -j$(nproc) >> ${apache_path}/logs/build/httpd.log 2>&1 && \
    make install >> ${apache_path}/logs/build/httpd.log 2>&1
    
    if [ $? -eq 0 ]; then
        log_success "HTTPD build completed"
    else
        log_error "HTTPD build failed! Check ${apache_path}/logs/build/httpd.log"
        tail -20 ${apache_path}/logs/build/httpd.log
        exit 1
    fi
    cd -

    # httpd.conf 수정
    log_info "Configuring httpd.conf..."
    mkdir -p ${apache_path}/run
    cp ${apache_path}/conf/httpd.conf ${apache_path}/conf/httpd.conf.ori
    cat << EOF >> ${apache_path}/conf/httpd.conf
PidFile "${apache_path}/run/httpd.pid"
ServerName www.example.com:80
EOF
    log_success "httpd.conf configured"
}

tomcat_connector()
{
    log_info "Building Tomcat connector..."
    mkdir -p ${apache_path}/src/tomcat_connector
    tar -xzf ../apache/${connector_file} -C ${apache_path}/src/tomcat_connector --strip-components=1 2>&1 | grep -i error || true

    ln -s /usr/bin/libtool ${apache_path}/build/libtool
    
    log_info "Tomcat Connector: Configuring..."
    cd ${apache_path}/src/tomcat_connector/native
    ./configure --prefix=${apache_path}/tomcat_connector --with-apxs=${apache_path}/bin/apxs >> ${apache_path}/logs/build/tomcat-connector.log 2>&1
    
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Tomcat connector configure failed!"
        tail -20 ${apache_path}/logs/build/tomcat-connector.log
        exit 1
    fi
    
    log_info "Tomcat Connector: Building..."
    make -j$(nproc) >> ${apache_path}/logs/build/tomcat-connector.log 2>&1 && \
    make install >> ${apache_path}/logs/build/tomcat-connector.log 2>&1
    
    if [ $? -eq 0 ]; then
        log_success "Tomcat connector built successfully"
    else
        log_error "Tomcat connector build failed!"
        tail -20 ${apache_path}/logs/build/tomcat-connector.log
        exit 1
    fi
    cd -

    # httpd.conf 수정
    log_info "Configuring mod_jk..."
    cat << EOF >> ${apache_path}/conf/httpd.conf
LoadModule jk_module modules/mod_jk.so
#Include conf/app.conf 
EOF

    # mod_jk.conf 생성 > app.conf 변경
    sudo tee ${apache_path}/conf/app.conf > /dev/null << EOF
JkWorkersFile conf/workers.properties
JkShmFile run/mod_jk.shm

JkLogFile logs/mod_jk.log
JkLogLevel info
JkLogStampFormat "[%y %m %d %H:%M:%S] "

<VirtualHost *:80>

    ServerName localhost
    DocumentRoot "/data/miso/webapps"

    <Directory "/data/miso/webapps">
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    DirectoryIndex index.jsp
    ErrorLog logs/app_error.log
    CustomLog logs/app_access.log combined

    JkMount /* worker1
	
    JkUnMount /web/*.css   worker1
    JkUnMount /web/*.js    worker1
    JkUnMount /web/*.png   worker1
    JkUnMount /web/*.jpg   worker1
    JkUnMount /web/*.jpeg  worker1
    JkUnMount /web/*.gif   worker1
    JkUnMount /web/*.svg   worker1

    ErrorLog logs/app_error.log
    CustomLog logs/app_access.log combined

</VirtualHost>
#Listen 0.0.0.0:443 https
#<VirtualHost *:443>
#    ServerName localhost
#    DocumentRoot "/data/miso/webapps"
#
#    <Directory "/data/miso/webapps">
#        Options FollowSymLinks
#        AllowOverride None
#        Require all granted
#    </Directory>
#
#    DirectoryIndex index.jsp
#    ErrorLog logs/app_error.log
#    CustomLog logs/app_access.log combined
#
#    JkMount /* worker1
#    JkUnMount /web/*.css   worker1
#    JkUnMount /web/*.js    worker1
#    JkUnMount /web/*.png   worker1
#    JkUnMount /web/*.jpg   worker1
#    JkUnMount /web/*.jpeg  worker1
#    JkUnMount /web/*.gif   worker1
#    JkUnMount /web/*.svg   worker1
#
#	SSLEngine on
#	SSLCertificateFile "/data/httpd/conf/ssl/jsp.pem"
#	SSLCertificateKeyFile "/data/httpd/conf/ssl/jsp.pem"
#	SSLCACertificateFile "/data/httpd/conf/ssl/root-chain.pem"
#	JkExtractSSL On
#	JkHTTPSIndicator HTTPS
#</VirtualHost>
EOF

    # worker 파일생성
    sudo tee ${apache_path}/conf/workers.properties > /dev/null << EOF
worker.list=worker1
worker.worker1.port=8009
worker.worker1.host=127.0.0.1
worker.worker1.type=ajp13

#worker.worker1.connect_timeout=5000
#worker.worker1.reply_timeout=60000
#worker.worker1.ping_mode=A
#worker.worker1.ping_timeout=10000
#worker.worker1.connection_pool_timeout=600
#worker.worker1.max_packet_size=65536

#<Connector protocol="AJP/1.3" address="0.0.0.0" port="8009" redirectPort="8443" maxParameterCount="1000" URIEncoding="UTF-8" enableLookups="false"
# server="server" secretRequired="false" packetSize="65536" maxThreads="400" acceptCount="200" ConnectionTimeout="30000" />

######################################################
#worker.list=loadbalancer

## Tomcat A 
#worker.tomcatA.type=ajp13
#worker.tomcatA.host=1.1.1.1
#worker.tomcatA.route=tomcatA
#worker.tomcatA.port=8009
#worker.tomcatA.lbfactor=1
#worker.tomcatA.socket_timeout=300
#worker.tomcatA.socket_keepalive=true
#worker.tomcatA.connection_pool_timeout=600
#worker.tomcatA.ping_mode=A
#worker.tomcatA.ping_timeout=10000
#worker.tomcatA.secret=ajptomcatA
#worker.tomcatA.max_packet_size=65536

## Tomcat B 
#worker.tomcatB.type=ajp13
#worker.tomcatB.host=1.1.1.2
#worker.tomcatB.route=tomcatB
#worker.tomcatB.port=8009
#worker.tomcatB.lbfactor=1
#worker.tomcatB.socket_timeout=300
#worker.tomcatB.socket_keepalive=true
#worker.tomcatB.connection_pool_timeout=600
#worker.tomcatB.ping_mode=A
#worker.tomcatB.ping_timeout=10000
#worker.tomcatB.secret=ajptomcatB
#worker.tomcatB.max_packet_size=65536

#worker.loadbalancer.type=lb
#worker.loadbalancer.balance_workers=tomcatA,tomcatB
#worker.loadbalancer.sticky_session=1
#worker.loadbalancer.sticky_session_force=0
#worker.loadbalancer.method=Request

#worker.loadbalancer.retries=3
#worker.loadbalancer.recovery_options=3

#<Connector protocol="AJP/1.3"
#address="0.0.0.0" port="8009" redirectPort="8443" maxParameterCount="1000"
#URIEncoding="UTF-8" enableLookups="false" server="server" secretRequired="true"
#secret="ajptomcatA" packetSize="65536" maxThreads="400" acceptCount="200" 
#connectionTimeout="610000" keepAliveTimeout="610000" />

######################################################
EOF
    log_success "mod_jk configured"
	
	sudo tee ${apache_path}/readme.txt > /dev/null << EOF
check http.conf < app.conf "#"check
check workers.properties < ajp "#" check
EOF
	
}

remove_src()
{
    log_info "Cleaning up source files..."
    rm -rf ${apache_path}/src
    log_success "Source files cleaned"
}

makesystemfile()
{
    log_info "Creating systemd service file..."
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
    log_success "Systemd service file created"
}

firewalld()
{
    log_info "Configuring firewall..."
    firewall-cmd --permanent --zone=public --add-port=80/tcp > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
    log_success "Firewall configured"
}

check_path()
{
    if [ "$#" -eq 1 ]; then
        apache_path=$1
    else
        log_error "Please input the installation path"
        exit 1
    fi

    if [[ ! "$apache_path" =~ ^/[^/]+ ]]; then
        log_error "DANGEROUS PATH: $apache_path"
        exit 1
    fi

    case "$apache_path" in
        "" | "/" | "." | ".." | "?" | "!" | "*")
            log_error "DANGEROUS PATH: $apache_path"
            exit 1
            ;;
    esac

    apache_path="${apache_path%/}"

    if [ "$apache_path" = "/" ]; then
        log_error "ROOT PATH BLOCKED"
        exit 1
    fi
    
    log_info "Installation path: ${apache_path}"
}

package()
{
    log_info "Creating package..."
    name=${apache_path//\//_}
    tar -czf httpd${name}.tar.gz -C "$(dirname "$apache_path")" "$(basename "$apache_path")" 2>&1 | grep -v "^tar:" || true
    
    if [ $? -eq 0 ]; then
        log_success "Package created: httpd${name}.tar.gz"
    else
        log_error "Package creation failed"
        exit 1
    fi
    
    rm -rf ${apache_path}
    echo "rm -rf ${SCRIPT_DIR}/httpd${name}.tar.gz" | at now + 5 minutes
    log_warn "Package will be auto-deleted in 5 minutes"
}

main()
{
    case "$1" in
        *)
            log_info "Apache installation started"
            echo "=========================================="
            
            check_path $1 && \
            apache_file_check && \
            local_repository_check && \
            rpmupdate && \
            makefile && \
            tomcat_connector && \
            remove_src && \
            makesystemfile && \
            package
            
            end_time=$(date +%s)
            elapsed=$((end_time - start_time))
            
            echo "=========================================="
            log_success "Apache installation completed!"
            log_info "Total elapsed time: ${elapsed} seconds ($((elapsed / 60))m $((elapsed % 60))s)"
            log_info "Build logs available in: ${apache_path}/logs/build/"
            echo "=========================================="
            ;;
    esac
}

main "$@"
