#! /bin/bash
cd "$(dirname "$0")"
source 01.util_Install_latest
SCRIPTLOGFILE=miso_auto_patch.log
exec > >(tee -a "$SCRIPTLOGFILE") 2>&1
echo $DATE" is running" >> ${SCRIPTLOGFILE}
############variable setting############
nexus_id=lsm97
nexus_pw=wlfks@09!
repository_path='http://10.52.251.103:8083/nexus/content/repositories/releases'
declare -a download_file=(
  "/miso_with_cms/content/repositories/releases/jiranjsp/miso.cms.web/2.0/miso.cms.web-2.0.war"
)
MISOWAR=miso.cms.web-2.0.war
########################################
dircheck()
{
    SRC="$1"
    [ -e "$SRC" ] || [ -L "$SRC" ] || return 0
    BACKUP="${SRC}_bak_$(date +%Y%m%d_%H%M)"
    sudo mv "$SRC" "$BACKUP" || return 1
}

filedownload()
{
sudo mkdir -p ../patch
for file in "${download_file[@]}"; do
    full_url="$repository_path/$file"
        filename=$(echo "${file}" | awk -F'/' '{print $NF}')
    codeckeck=$(sudo curl -u ${nexus_id}:${nexus_pw} -o /dev/null -s -w "%{http_code}" -I "${full_url}")
    echo "${file}"
        if [ "$codeckeck" = "200" ]; then
                curl -f -X GET -u ${nexus_id}:${nexus_pw} "${full_url}" -o ../patch/${filename}
        else
                echo "error $codeckeck"
                sudo rm -rf ../patch
        fi
done
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
        sudo rm -rf ../"$del"
    done
fi
}
miso_patch()
{
#sudo systemctl stop tomcat || true
${tomcat_path}/bin/shutdown.sh
current_date=$(date '+%Y%m%d_%H%M')
sudo mv ${miso_path}/webapps ${miso_path}/webapps_${current_date}_bak

sudo mkdir -p ${miso_path}/webapps
sudo cp -av ../patch/${MISOWAR} ${miso_path}/webapps/${MISOWAR}
cd ${miso_path}/webapps;sudo ${install_path}/java/bin/jar -xvf ${MISOWAR};cd -

sudo cp ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/logback.properties ${miso_path}/webapps/WEB-INF/classes/logback.properties
sudo cp ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/properties/system.properties ${miso_path}/webapps/WEB-INF/classes/properties/system.properties
sudo cp ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/properties/site.properties ${miso_path}/webapps/WEB-INF/classes/properties/site.properties
sudo rm -r ${miso_path}/webapps/web/plugins/namo 
sudo cp -arp ${miso_path}/webapps_${current_date}_bak/web/plugins/namo ${miso_path}/webapps/web/plugins/

dircheck ../patch/patch.sql
sudo touch ../patch/patch.sql

EXCLUDE_LIST="99 98"
for exclude in $EXCLUDE_LIST; do
	sudo cp ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/database/mysql/${exclude}_*.sql ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/database/mysql/${exclude}_old_ALTER.sql
	sudo cp ${miso_path}/webapps/WEB-INF/classes/database/mysql/${exclude}_*.sql ${miso_path}/webapps/WEB-INF/classes/database/mysql/${exclude}_new_ALTER.sql
	sed -i 's/\r//g; s/[[:space:]]\+/ /g; s/[[:space:]]*$//; /^[[:space:]]*$/d' ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/database/mysql/${exclude}_old_ALTER.sql
	sed -i 's/\r//g; s/[[:space:]]\+/ /g; s/[[:space:]]*$//; /^[[:space:]]*$/d' ${miso_path}/webapps/WEB-INF/classes/database/mysql/${exclude}_new_ALTER.sql
	oldline=$(sed -n '/./=' ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/database/mysql/${exclude}_old_ALTER.sql | tail -n 1)
	newline=$(sed -n '/./=' ${miso_path}/webapps/WEB-INF/classes/database/mysql/${exclude}_new_ALTER.sql | tail -n 1)
	if [ "$newline" -gt "$oldline" ]; then
		for (( i=oldline+1; i<=newline; i++ )); do
			sed -n "${i}p" ${miso_path}/webapps/WEB-INF/classes/database/mysql/${exclude}_new_ALTER.sql >> ../patch/patch.sql
		done
	else
		echo "correct"
	fi
done

chown -R ${SERV_USER}:${SERV_USER} ${miso_path}/webapps

salt=$(printf $SERV_USER | md5sum | cut -c1-16)
DEC_VALUE=$(echo $DP_ENC | openssl enc -aes-256-cbc -a -d -S $salt -pbkdf2 -iter 100000 -pass pass:$MY_USER 2>/dev/null)
sudo mysqldump -u ${DB_USER} -p${DEC_VALUE} ${DB_NAME} --single-transaction --triggers --routines > ../patch/${DB_NAME}_${current_date}.sql

sudo mysql -u ${DB_USER} -p${DEC_VALUE} ${DB_NAME} < ../patch/patch.sql

${tomcat_path}/bin/startup.sh

#systemctl start tomcat || true
#mv ../patch ../patch_${current_day}
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
        sudo rm -rf ${miso_path}/${del}
    done
fi
}

main()
{
	case "$1" in
		filedownload)
			filedownload
			;;
		  patch)
			patchfile_del&&miso_patch&&webappsfile_del
			;;
		*)
			echo "Usage: $0 {check|install|help}"
			exit 0	
			;;
        esac
}

main "$@"
