#!/bin/bash
TITLE="서버 모니터링 $(date +%Y-%m-%d)"
cd "$(dirname "$0")"
# host를 키로 user:password 저장
declare -A server_info=(
    ["1.2.3.4"]="root:password"
    ["3.4.5.6"]="login:passwd"
)

send_user="
lsm97@jiran.com
kbhwang@jiran.com
"
check_disk="
/
/app
/data
/home
"

for i in $check_disk; do
    option="${option}|${i}\$"
done
cat /dev/null > tmp.txt

for host in "${!server_info[@]}"; do
    user=$(echo "${server_info[$host]}" | cut -d: -f1)
    pass=$(echo "${server_info[$host]}" | cut -d: -f2)
    echo "============================" >> tmp.txt
    echo "[$host]" >> tmp.txt
    echo "============================" >> tmp.txt

    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$user@$host" 'exit' 2>/dev/null
    if [ $? != 0 ]; then
        echo "connect fail [$host]" >> tmp.txt
        continue
    fi
    result=$(sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$user@$host" \
        "
        echo '=== CPU ==='
        top -bn1 | grep 'Cpu(s)' | awk '{print $2}'
        echo '=== Memory ==='
        free -h | awk 'NR==2{print \$3\"/\"\$2}'
        echo '=== Disk ==='
        df -h | awk 'NR==1'
        df -hP | egrep 'Mounted on $option'
        " 2>&1 | tr -d '\r')
    echo "$result" >> tmp.txt
    echo "" >> tmp.txt
done
for user in $send_user; do
        cat tmp.txt |tr -d '\r'| mail -s "$TITLE" "$user"
done
