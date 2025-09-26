#!/bin/bash

DB_user=root
DB_passwd=Wlfks@09!@#
DB_name=''
log_file=truncate.log

if [ "$#" -eq 1 ]; then
	DB_name=$1
else
	echo "use >> $0 db_name"
	exit 1
fi

except_table=(
"alarm"
"alarm_event"
"apply_docu_guidance"
"apply_docu_type"
"apprv_type"
"authority"
"auth_grade"
"code_dfn"
"code_group"
"holiday"
"menu"
"message"
"property"
"widget"
"widget_grade_map"
"daemon_type"
"alarm_receive"
"auth_menu_map"
"board_dfn"
"board_group"
"plan_type"
"mail_receive"
"namo_params"
"occupation_grade"
)
declare -A except_map
for t in "${except_table[@]}"; do
    except_map["$t"]=1
done

cat /dev/null > $log_file

current_date=$(date '+%Y%m%d_%H%M')
mysqldump -u ${DB_user} -p"${DB_passwd}" ${DB_name} > ${DB_name}_${current_date}.sql
if [ $? -ne 0 ]; then
    echo "mysqldump 실패: $DB_name"
    exit 1
fi

table_list=$(mysql -u ${DB_user} -p"${DB_passwd}" -N -B -e "
SELECT table_name
FROM information_schema.tables
WHERE table_schema = '${DB_name}';
")
total=$(echo "$table_list" | wc -l)   # 전체 테이블 개수
count=0

while IFS= read -r table; do
    count=$((count+1))
    echo "[$count / $total] checking table: $table"
    result=$(mysql -u ${DB_user} -p"${DB_passwd}" -N -B "$DB_name" -e "SELECT 1 FROM \`$table\` LIMIT 1;")
    if [ -n "$result" ]; then
		if [[ ${except_map["$table"]} ]]; then
			echo "$table 예외 테이블 " >> "$log_file"
			continue
		fi
	    mysql -u ${DB_user} -p"${DB_passwd}" -N -B "$DB_name" -e "TRUNCATE TABLE \`$table\`;"
        echo "$table 데이터 삭제" >> "$log_file"
    fi
done <<< "$table_list"

#### data insert ####
{
mysql -u "$DB_user" -p"$DB_passwd" "$DB_name" <<'EOF'
-- 기본 조직(계열사) 추가
INSERT INTO `afflt` (`AFFLT_ID`, `AFFLT_NM`, `LOGIN_PAGE`, `AFFLT_LOGO_IMG`, `AFFLT_SKIN`, `MAIL_SVR`, `MAIL_SVR_PORT`, `MAIL_SVR_ACCT`, `MAIL_SVR_ACCT_PWD`, `MAIL_SENDER`) VALUES
	('org_000001', '기본조직', NULL, NULL, 'bootstrap', NULL, NULL, NULL, NULL, NULL);

INSERT INTO `organization` (`ORG_ID`, `ORG_NM`, `P_ORG_ID`, `USE_YN`, `P_AFFLT_ID`, `ORD_NO`, `SYNC_YN`, `DEL_YN`, `IF_KEY`, `INSERT_DT`, `UPDATE_DT`, `DELETE_DT`, `INSERT_USER`, `UPDATE_USER`, `DELETE_USER`) VALUES
	('org_000001', '기본조직', NULL, 'Y', 'org_000001', 1, NULL, 'N', NULL, NOW(), NOW(), NULL, NULL, NULL, NULL);	
	
-- admin 계정 생성
INSERT INTO `user` (`USER_ID`, `PASSWORD`, `USER_NM`, `EMP_NO`, `ENGINEER_AUTH_YN`, `AUTH_ID`, `OCGD_ID`, `TEL_NO`, `MOBILE_NO`, `EMAIL`, `EMAIL_RECEIVE_YN`, `LAST_LOGIN_DT`, `PWD_CHANGE_DT`, `INVALID_LOGIN_CNT`, `SYNC_YN`, `ACCT_STATE_CD`, `ACCT_LOCK_REASON_CD`, `MEMO`, `INSERT_DT`, `UPDATE_DT`, `DELETE_DT`, `INSERT_USER`, `UPDATE_USER`, `DELETE_USER`) VALUES 
('admin', '$2a$10$.VxmK.W2GayH6RDBYGRATOGfsCsgaTOFbH1Nzk3Ibc07n..bf3i9O', '관리자', NULL, 'Y', 'AUTH_00003', NULL, NULL, NULL, NULL, 'Y', NOW(), NULL, 0, 'N', 'U', NULL, NULL, NOW(), NOW(), NULL, NULL, NULL, NULL);

-- admin 계정 계열사 추가
INSERT INTO `user_org_map` (`ORG_ID`, `USER_ID`, `RPRN_ORG_YN`, `AFFLT_ID`) VALUES ('org_000001', 'admin', 'Y', 'org_000001');


EOF
} 1>/dev/null 2>>"$log_file"

