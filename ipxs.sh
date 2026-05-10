#!/bin/bash

DB_FILE="/root/ip_limit.db"

clear

echo "========================================="
echo " Linux IP 上传限速管理"
echo "========================================="
echo ""

echo "当前网卡："
ip -o link show | awk -F': ' '{print $2}' | grep -v lo
echo ""

read -p "请输入要管理的网卡名（如 eth0）: " DEV

if [ -z "$DEV" ]; then
    echo "网卡不能为空"
    exit 1
fi

echo ""
echo "请选择操作："
echo "1) 添加限速规则（支持叠加 + 每IP限速，存在则替换）"
echo "2) 查询限速规则"
echo "3) 删除限速规则"
echo ""

read -p "请输入选项（1-3）: " ACTION

init_tc() {

    modprobe ifb >/dev/null 2>&1

    ip link add ifb0 type ifb 2>/dev/null

    ip link set ifb0 up

    tc qdisc show dev $DEV | grep "ingress" >/dev/null

    if [ $? -ne 0 ]; then

        tc qdisc add dev $DEV handle ffff: ingress

        tc filter add dev $DEV parent ffff: \
        protocol ip u32 match u32 0 0 \
        action mirred egress redirect dev ifb0

    fi

    tc qdisc show dev ifb0 | grep "htb 1:" >/dev/null

    if [ $? -ne 0 ]; then

        tc qdisc add dev ifb0 root handle 1: htb default 999

    fi
}

get_next_classid() {

    if [ ! -f "$DB_FILE" ] || [ ! -s "$DB_FILE" ]; then
        echo 10
        return
    fi

    LAST_ID=$(awk -F "|" '{print $4}' $DB_FILE | sort -n | tail -1)

    echo $((LAST_ID + 1))
}

add_rule() {

    init_tc

    while true; do

        echo ""

        read -p "请输入源IP或CIDR（如 192.168.1.10 或 10.0.0.0/24），输入 done 完成: " IP

        if [ "$IP" == "done" ]; then
            break
        fi

        read -p "请输入该IP的上传限速（如 1mbit、500kbit），直接输入数字（如 30）表示 30mbit: " SPEED

        if [[ "$SPEED" =~ ^[0-9]+$ ]]; then
            SPEED="${SPEED}mbit"
        fi

        OLD_RULE=$(grep "^$DEV|$IP|" $DB_FILE 2>/dev/null)

        if [ -n "$OLD_RULE" ]; then

            OLD_CLASSID=$(echo "$OLD_RULE" | awk -F "|" '{print $4}')

            tc class del dev ifb0 classid 1:$OLD_CLASSID 2>/dev/null

            tc filter del dev ifb0 parent 1: protocol ip handle $OLD_CLASSID fw 2>/dev/null

            iptables -t mangle -D PREROUTING -s $IP -j MARK --set-mark $OLD_CLASSID 2>/dev/null

            sed -i "\|^$DEV|$IP||d" $DB_FILE
        fi

        CLASS_ID=$(get_next_classid)

        iptables -t mangle -A PREROUTING -s $IP -j MARK --set-mark $CLASS_ID

        tc class add dev ifb0 parent 1: classid 1:$CLASS_ID htb rate $SPEED ceil $SPEED

        tc filter add dev ifb0 parent 1: protocol ip handle $CLASS_ID fw flowid 1:$CLASS_ID

        echo "$DEV|$IP|$SPEED|$CLASS_ID" >> $DB_FILE

        echo "✅ 已为 $IP 设置限速 $SPEED"

    done
}

show_rules() {

    echo ""

    if [ ! -f "$DB_FILE" ] || [ ! -s "$DB_FILE" ]; then
        echo "当前没有限速规则"
        exit 0
    fi

    echo "当前限速规则："
    echo "-----------------------------------------------------"

    INDEX=1

    while IFS="|" read -r RULE_DEV RULE_IP RULE_SPEED RULE_CLASSID; do

        if [ "$RULE_DEV" == "$DEV" ]; then

            echo "$INDEX) IP/CIDR: $RULE_IP | 限速: $RULE_SPEED | CLASSID: $RULE_CLASSID"

            INDEX=$((INDEX+1))
        fi

    done < $DB_FILE

    echo "-----------------------------------------------------"
}

delete_rule() {

    show_rules

    echo ""

    read -p "请输入要删除的序号: " NUM

    TARGET_LINE=$(grep "^$DEV|" $DB_FILE | sed -n "${NUM}p")

    if [ -z "$TARGET_LINE" ]; then
        echo "序号不存在"
        exit 1
    fi

    RULE_IP=$(echo "$TARGET_LINE" | awk -F "|" '{print $2}')
    RULE_CLASSID=$(echo "$TARGET_LINE" | awk -F "|" '{print $4}')

    tc class del dev ifb0 classid 1:$RULE_CLASSID 2>/dev/null

    tc filter del dev ifb0 parent 1: protocol ip handle $RULE_CLASSID fw 2>/dev/null

    iptables -t mangle -D PREROUTING -s $RULE_IP -j MARK --set-mark $RULE_CLASSID 2>/dev/null

    sed -i "\|^$DEV|$RULE_IP||d" $DB_FILE

    echo ""
    echo "✅ 已删除规则: $RULE_IP"
}

case $ACTION in

1)
    add_rule
    ;;

2)
    show_rules
    ;;

3)
    delete_rule
    ;;

*)
    echo "无效选项"
    ;;

esac
