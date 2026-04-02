#! /bin/bash
cd "$(dirname "$0")"
source 01.util_Install_latest
SCRIPTLOGFILE=miso_auto_patch.log
exec > >(tee -a "$SCRIPTLOGFILE") 2>&1
echo $DATE" is running" >> ${SCRIPTLOGFILE}

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

sudo systemctl stop tomcat || true
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


sudo touch ../patch/patch.sql

sudo cp ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/database/mysql/MYSQL_DDL_6_ALTER.sql ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/database/mysql/old_ALTER.sql
sudo cp ${miso_path}/webapps/WEB-INF/classes/database/mysql/MYSQL_DDL_6_ALTER.sql ${miso_path}/webapps/WEB-INF/classes/database/mysql/new_ALTER.sql
sudo sed -i '/^[[:space:]]*$/d' ${miso_path}/webapps_${current_date}_bak/WEB-INF/classes/database/mysql/old_ALTER.sql
sudo sed -i '/^[[:space:]]*$/d' ${miso_path}/webapps/WEB-INF/classes/database/mysql/new_ALTER.sql

sed -i '
s/\r//g                   # 개행처리
s/[[:space:]]\+/ /g       # 2개이상 공백 1개 치환
s/[[:space:]]*$//         # 마지막줄 공백제거
/^[[:space:]]*$/d         # 공백 줄 제거
' 1.sql


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
cat ${miso_path}/webapps/WEB-INF/classes/database/mysql/CODE_DML.sql  >> ../patch/patch.sql
printf "\n\n" >> ../patch/patch.sql
cat ${miso_path}/webapps/WEB-INF/classes/database/mysql/MESSAGE_DML.sql  >> ../patch/patch.sql
printf "\n\n" >> ../patch/patch.sql
cat ${miso_path}/webapps/WEB-INF/classes/database/mysql/PROPERTY_DML.sql  >> ../patch/patch.sql

chown -R ${SERV_USER}:${SERV_USER} ${miso_path}/webapps

salt=$(printf $SERV_USER | md5sum | cut -c1-16)
DEC_VALUE=$(echo $DP_ENC | openssl enc -aes-256-cbc -a -d -S $salt -pbkdf2 -iter 100000 -pass pass:$MY_USER 2>/dev/null)
sudo mysqldump -u ${DB_USER} -p${DEC_VALUE} ${DB_NAME} --single-transaction --triggers --routines > ../patch/${DB_NAME}_${current_date}.sql

sudo mysql -u ${DB_USER} -p${DEC_VALUE} ${DB_NAME} < ../patch/patch.sql

systemctl start tomcat || true

mv ../patch ../patch_${current_day}
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
